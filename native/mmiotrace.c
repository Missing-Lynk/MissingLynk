/**
 * @file mmiotrace.c
 * @brief LD_PRELOAD MMIO write-tracer for the Artosyn vendor camera stack (aarch64).
 *
 * The vendor programs the VIF/CSI blocks by mmap-ing /dev/mem and storing to the
 * mapped pages (libmpp_service camera_map_phy_addr). A register dump cannot see
 * write ORDER or transient set-then-clear pulses. This shim records every store:
 * it wraps mmap of /dev/mem, keeps the returned mapping PROT_READ, and on each
 * store fault (SIGSEGV on the read-only page) decodes the AArch64 store, logs
 * "physical address = value" in program order, then performs the store through a
 * separate read-write alias of the same physical memory so the vendor runs on.
 *
 * It also wraps ioctl to log the /dev/ar_sys register-write path (magic 0xc018410f,
 * struct {u64 addr, u32 val, ...}) that the VIN HAL uses.
 *
 * MMIOTRACE_READS additionally traces loads: the window is mapped PROT_NONE so
 * reads fault too, and the handler decodes the load, fetches the value through the
 * alias, writes it into the faulting register and resumes. Loads appear as
 * "r"-prefixed lines sharing the write sequence counter, so a poll loop is visible
 * as what it is. A load form the decoder does not know is not guessed at: the
 * mapping is dropped back to PROT_READ and read tracing ends there, because
 * delivering a wrong value into a register would corrupt the vendor silently.
 *
 * MMIOTRACE_TIME appends " t=<ns>" (CLOCK_MONOTONIC) to every line, which is what
 * separates a poll that spun for milliseconds from one that returned immediately.
 *
 * Build: shared, PIC, glibc (see native/build.sh). Use:
 *   LD_PRELOAD=/tmp/mmiotrace.so MMIOTRACE_OUT=/tmp/mmio.log \
 *   MMIOTRACE_LO=0x08800000 MMIOTRACE_HI=0x08880fff <vendor camera command>
 * MMIOTRACE_LO/HI (optional) restrict logging to a physical window; default logs
 * every /dev/mem store.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>

/** Largest number of distinct /dev/mem mappings tracked at once. */
#define MAX_MAPS 64

struct traced_map {
    uintptr_t ro_base;  /**< base of the app's read-only mapping */
    size_t len;         /**< mapping length */
    uint64_t phys;              /**< physical base (the mmap offset argument) */
    volatile uint8_t *rw;       /**< read-write alias of the same physical range */
    uintptr_t prot_va;  /**< start of the sub-range we mprotect-ed */
    size_t prot_len;    /**< length of that sub-range, 0 if none */
};

static struct traced_map g_maps[MAX_MAPS];
static int g_map_count;
static int g_mem_fd = -1;       /**< our own O_RDWR handle on /dev/mem, for aliases */
static int g_arsys_fd = -1;     /**< our own O_RDWR handle on /dev/ar_sys */
static int g_log_fd = -1;
static uint64_t g_lo, g_hi = ~0ull;     /**< physical logging window */
static uint64_t g_skip_lo = 1, g_skip_hi;       /**< physical range to leave untrapped */
static int g_ioctl_census;              /**< MMIOTRACE_IOCTL_CENSUS: log unknown ar_sys requests */
#define MAX_SEEN 32
static unsigned long g_seen[MAX_SEEN];
static unsigned g_seen_count;
static uint64_t g_seq;                  /**< global write order counter */
static int g_installed;
static int g_reads;                     /**< MMIOTRACE_READS: trap loads as well as stores */
static int g_time;                      /**< MMIOTRACE_TIME: append a monotonic timestamp */
static int g_nomem;                     /**< MMIOTRACE_NOMEM: don't trap /dev/mem stores
                     * via mprotect+SIGSEGV (which interrupts the
                     * app's blocking ioctls with -ERESTARTSYS and
                     * crashes realtime daemons); rely on the clean
                     * /dev/ar_sys ioctl hook only. */

/* Real libc entry points, resolved lazily to avoid our own wrappers. */
static void *(*real_mmap)(void *, size_t, int, int, int, off_t);
static int (*real_open)(const char *, int, ...);
static int (*real_openat)(int, const char *, int, ...);
static int (*real_ioctl)(int, unsigned long, ...);
static int (*real_munmap)(void *, size_t);
static int (*real_sigaction)(int, const struct sigaction *, struct sigaction *);
static void (*(*real_signal)(int, void (*)(int)))(int);

/* Per-fd MMIO device class: 0 none, 1 /dev/mem, 2 /dev/ar_sys. */
static char g_devtype[4096];

/* -- async-signal-safe hex logging ------------------------------------------ */

/** Append 'n' as fixed-width hex into buf at *pos. */
static void put_hex(char *buf, int *pos, uint64_t n, int digits)
{
    static const char h[] = "0123456789abcdef";
    int i;

    for (i = digits - 1; i >= 0; i--) {
        buf[(*pos)++] = h[(n >> (i * 4)) & 0xf];
    }
}

static void put_str(char *buf, int *pos, const char *s)
{
    while (*s) {
        buf[(*pos)++] = *s++;
    }
}

/**
 * One trace line. Only async-signal-safe calls (write, clock_gettime).
 * 'kind' is 'w' for a store or 'r' for a load; both share g_seq so the log is in
 * true program order across the two.
 */
static void log_access(char kind, uint64_t phys, uint64_t val, int width, int decoded)
{
    char buf[128];
    int p = 0;

    if (g_log_fd < 0) {
        return;
    }

    if (phys < g_lo || phys > g_hi) {
        return;
    }

    buf[p++] = kind;
    put_hex(buf, &p, g_seq++, 6);
    buf[p++] = ' ';
    buf[p++] = decoded ? kind : '?';
    put_hex(buf, &p, (uint64_t)(width * 8), 2);
    put_str(buf, &p, " pa=0x");
    put_hex(buf, &p, phys, 8);
    put_str(buf, &p, " val=0x");
    put_hex(buf, &p, val & (width >= 8 ? ~0ull : ((1ull << (width * 8)) - 1)), 8);
    if (g_time) {
        struct timespec ts;

        clock_gettime(CLOCK_MONOTONIC, &ts);
        put_str(buf, &p, " t=");
        put_hex(buf, &p, (uint64_t)ts.tv_sec * 1000000000ull +
                 (uint64_t)ts.tv_nsec, 12);
    }
    buf[p++] = '\n';
    (void)write(g_log_fd, buf, p);
}

static void log_write(uint64_t phys, uint64_t val, int width, int decoded)
{
    log_access('w', phys, val, width, decoded);
}

/**
 * A free-standing marker line, for events that are not a register access.
 * 'insn' is appended so an unsupported form can be identified and added rather
 * than guessed at from the surrounding writes.
 */
static void log_note(const char *text, uint32_t insn)
{
    char buf[96];
    int p = 0;

    if (g_log_fd < 0) {
        return;
    }

    put_str(buf, &p, "# ");
    put_str(buf, &p, text);
    put_str(buf, &p, " 0x");
    put_hex(buf, &p, insn, 8);
    buf[p++] = '\n';
    (void)write(g_log_fd, buf, p);
}

/* -- init ------------------------------------------------------------------- */

static void resolve(void)
{
    if (!real_mmap) {
        real_mmap = dlsym(RTLD_NEXT, "mmap");
    }

    if (!real_open) {
        real_open = dlsym(RTLD_NEXT, "open");
    }

    if (!real_openat) {
        real_openat = dlsym(RTLD_NEXT, "openat");
    }

    if (!real_ioctl) {
        real_ioctl = dlsym(RTLD_NEXT, "ioctl");
    }

    if (!real_munmap) {
        real_munmap = dlsym(RTLD_NEXT, "munmap");
    }

    if (!real_sigaction) {
        real_sigaction = dlsym(RTLD_NEXT, "sigaction");
    }

    if (!real_signal) {
        real_signal = dlsym(RTLD_NEXT, "signal");
    }
}

static void find_map(uintptr_t addr, struct traced_map **out, size_t *off)
{
    *out = NULL;

    for (int i = 0; i < g_map_count; i++) {
        if (addr >= g_maps[i].ro_base &&
            addr < g_maps[i].ro_base + g_maps[i].len) {
            *out = &g_maps[i];
            *off = addr - g_maps[i].ro_base;
            return;
        }
    }
}

/* -- store decode + fault handler ------------------------------------------- */

/**
 * Decode the AArch64 store at 'pc'. A fault on a PROT_READ page is always a
 * store, so we only need the source register and width. Handles the scaled
 * unsigned-offset STR family, STUR, and STP; anything else falls back to a
 * 32-bit store of Rt (logged as undecoded so it is visible in the trace).
 */
static void decode_store(uint32_t insn, ucontext_t *uc, uintptr_t fault,
             struct traced_map *m, size_t off)
{
    unsigned size = insn >> 30;
    int width = 1 << size;
    unsigned rt = insn & 0x1f;
    uint64_t val;
    int decoded = 1;
    volatile uint8_t *dst = m->rw + off;

    /* STP (store pair): opc[31:30]=00/10, bits[29:23]=1010xx0, L bit22=0. */
    unsigned stp = insn & 0x7fc00000u;

    if (stp == 0x29000000u ||  /* STP signed offset */
        stp == 0x29800000u ||  /* STP pre-index    */
        stp == 0x28800000u) {  /* STP post-index   */
        unsigned opc = insn >> 30;
        int w = opc ? 8 : 4;
        unsigned rt2 = (insn >> 10) & 0x1f;
        unsigned rn = (insn >> 5) & 0x1f;
        int imm7 = (int)((insn >> 15) & 0x7f);
        uint64_t v1 = (rt == 31) ? 0 : uc->uc_mcontext.regs[rt];
        uint64_t v2 = (rt2 == 31) ? 0 : uc->uc_mcontext.regs[rt2];
        volatile uint8_t *d = m->rw + off;

        log_write(m->phys + off, v1, w, 1);
        log_write(m->phys + off + w, v2, w, 1);
        if (w == 8) {
            *(volatile uint64_t *)d = v1;
            *(volatile uint64_t *)(d + 8) = v2;
        } else {
            *(volatile uint32_t *)d = (uint32_t)v1;
            *(volatile uint32_t *)(d + 4) = (uint32_t)v2;
        }
        uc->uc_mcontext.pc += 4;

        /* The pre- and post-index forms write the new address back to the base
         * register; the signed-offset form does not. The store itself is right
         * either way, because off comes from the faulting address, but skipping
         * the writeback leaves the app's base stale and every later access
         * through it lands somewhere else. imm7 is signed and scaled by the
         * access width. Rn 31 is SP here, not the zero register.
         */
        if (stp != 0x29000000u) {
            if (imm7 & 0x40) {
                imm7 -= 0x80;
            }

            if (rn == 31) {
                uc->uc_mcontext.sp += (int64_t)imm7 * w;
            } else {
                uc->uc_mcontext.regs[rn] += (int64_t)imm7 * w;
            }
        }

        return;
    }

    /* Scaled unsigned-offset store: bits[29:24]=111001, opc[23:22]=00. */
    if ((insn & 0x3f400000u) == 0x39000000u) {
        /* size/width/rt already extracted */
    } else if ((insn & 0x3f600c00u) == 0x38000000u) {
        /* STUR unscaled: bits[29:24]=111000, [21]=0, [11:10]=00. */
    } else {
        /* Unknown store form: assume 32-bit of Rt so the app survives. */
        width = 4;
        decoded = 0;
    }

    val = (rt == 31) ? 0 : uc->uc_mcontext.regs[rt];
    log_write(m->phys + off, val, width, decoded);

    switch (width) {
    case 1: {
        *(volatile uint8_t *)dst = (uint8_t)val;
    } break;

    case 2: {
        *(volatile uint16_t *)dst = (uint16_t)val;
    } break;

    case 8: {
        *(volatile uint64_t *)dst = val;
    } break;

    default: {
        *(volatile uint32_t *)dst = (uint32_t)val;
    } break;
    }
    (void)fault;
    uc->uc_mcontext.pc += 4;
}

/**
 * Is this a load? On a PROT_NONE page either class can fault, so the direction
 * has to come from the encoding rather than from the fault. Bits[29:27] name the
 * family: 111 is load/store register, 101 is load/store pair. Direction is then
 * opc bits[23:22] (00 stores, 01 zero-extending load, 10/11 sign-extending) or,
 * for the pair forms, the L bit 22.
 *
 * SIMD variants are deliberately reported as loads even though they cannot be
 * serviced: the caller must untrap rather than fall through to the store path,
 * which would write a register value into the device.
 */
static int insn_is_load(uint32_t insn)
{
    unsigned family = (insn >> 27) & 7;

    if (family == 5) { /* pair */
        return (insn >> 22) & 1;
    }

    if (family == 7) { /* register */
        return ((insn >> 22) & 3) != 0;
    }

    return 0;
}

/**
 * Can decode_load service this form? Only the variants with no writeback: a
 * pre/post-index load also updates its base register, which the handler does not
 * emulate, so servicing one would leave the vendor's pointer stale.
 */
static int load_serviceable(uint32_t insn)
{
    unsigned family = (insn >> 27) & 7;

    if (insn & (1u << 26)) { /* SIMD/FP */
        return 0;
    }

    if (family == 5) {
        if ((insn >> 30) == 1) { /* LDPSW: 4 bytes, signed */
            return 0;
        }
        return ((insn >> 23) & 3) == 2;                 /* signed offset only */
    }

    if (family == 7) {
        unsigned class = (insn >> 24) & 3;

        if (class == 1) { /* scaled unsigned offset */
            return 1;
        }

        if (class == 0 && !((insn >> 21) & 1) && !((insn >> 10) & 3)) {
            return 1;                           /* LDUR unscaled */
        }

        if (class == 0 && ((insn >> 21) & 1) && ((insn >> 10) & 3) == 2) {
            return 1;                           /* register offset: no writeback,
                                                 * and the fault already gives us
                                                 * the resolved address */
        }
    }

    return 0;
}

/** Place a loaded value into Xt, honouring the encoding's extension. */
static void put_reg(ucontext_t *uc, unsigned rt, uint64_t val, int width, unsigned opc)
{
    if (rt == 31) { /* XZR: the result is discarded */
        return;
    }

    if (opc == 2 || opc == 3) {                 /* sign-extending load */
        unsigned bits = width * 8;
        uint64_t sign = 1ull << (bits - 1);

        val = (val ^ sign) - sign;
        if (opc == 3) { /* ...to a W register */
            val &= 0xffffffffull;
        }
    }
    uc->uc_mcontext.regs[rt] = val;
}

static uint64_t alias_read(volatile uint8_t *src, int width)
{
    switch (width) {
    case 1: {
        return *(volatile uint8_t *)src;
    } break;

    case 2: {
        return *(volatile uint16_t *)src;
    } break;

    case 8: {
        return *(volatile uint64_t *)src;
    } break;

    default: {
        return *(volatile uint32_t *)src;
    } break;
    }
}

/**
 * Decode and service the AArch64 load at 'pc'. Returns 0 if the form is not one
 * we can service, in which case the caller must stop trapping reads rather than
 * invent a value: a wrong register result would corrupt the vendor with no trace.
 */
static int decode_load(uint32_t insn, ucontext_t *uc, struct traced_map *m, size_t off)
{
    unsigned size = insn >> 30;
    int width = 1 << size;
    unsigned rt = insn & 0x1f;
    unsigned opc = (insn >> 22) & 3;
    volatile uint8_t *src = m->rw + off;
    uint64_t val;

    if (!load_serviceable(insn)) {
        return 0;
    }

    /* LDP: opc[31:30] gives 4- or 8-byte elements, and two registers load. */
    if (((insn >> 27) & 7) == 5) {
        int w = (insn >> 30) ? 8 : 4;
        unsigned rt2 = (insn >> 10) & 0x1f;
        uint64_t v1 = alias_read(src, w);
        uint64_t v2 = alias_read(src + w, w);

        log_access('r', m->phys + off, v1, w, 1);
        log_access('r', m->phys + off + w, v2, w, 1);
        put_reg(uc, rt, v1, w, 1);
        put_reg(uc, rt2, v2, w, 1);
        uc->uc_mcontext.pc += 4;

        return 1;
    }

    /* Remaining serviceable forms are the register ones, where size[31:30] gives
     * the access width and opc[23:22] the extension. A sign-extending 32-bit load
     * (LDRSW, size 2 opc 2) still reads 4 bytes; put_reg widens it.
     */
    val = alias_read(src, width);
    log_access('r', m->phys + off, val, width, 1);
    put_reg(uc, rt, val, width, opc);
    uc->uc_mcontext.pc += 4;

    return 1;
}

/**
 * Give up on read tracing for one mapping: restore PROT_READ over the range we
 * protected so the faulting load re-executes and succeeds. Stores keep faulting,
 * so the write trace continues uninterrupted.
 */
static void untrap_reads(struct traced_map *m, uint32_t insn)
{
    if (m->prot_len) {
        mprotect((void *)m->prot_va, m->prot_len, PROT_READ);
    }

    log_note("read tracing disabled: unsupported load form", insn);
}

static struct sigaction g_old_segv;

static void segv_handler(int sig, siginfo_t *si, void *ctx)
{
    ucontext_t *uc = ctx;
    uintptr_t fault = (uintptr_t)si->si_addr;
    struct traced_map *m;
    size_t off;
    uint32_t insn;

    find_map(fault, &m, &off);
    if (!m) {
        /* Not our page: restore the previous handler and let it crash. */
        if (g_old_segv.sa_flags & SA_SIGINFO) {
            g_old_segv.sa_sigaction(sig, si, ctx);
        } else if (g_old_segv.sa_handler == SIG_DFL ||
                   g_old_segv.sa_handler == SIG_IGN) {
            _exit(139);
        } else {
            g_old_segv.sa_handler(sig);
        }
        return;
    }
    insn = *(uint32_t *)uc->uc_mcontext.pc;

    if (g_reads && insn_is_load(insn)) {
        if (!decode_load(insn, uc, m, off)) {
            untrap_reads(m, insn);
        }
        return;
    }
    decode_store(insn, uc, fault, m, off);
}

static void install(void)
{
    struct sigaction sa;
    const char *e;

    if (g_installed) {
        return;
    }
    g_installed = 1;

    e = getenv("MMIOTRACE_OUT");
    g_log_fd = open(e ? e : "/tmp/mmio.log",
            O_WRONLY | O_CREAT | O_APPEND, 0644);

    if ((e = getenv("MMIOTRACE_LO"))) {
        g_lo = strtoull(e, NULL, 0);
    }

    if ((e = getenv("MMIOTRACE_HI"))) {
        g_hi = strtoull(e, NULL, 0);
    }

    if ((e = getenv("MMIOTRACE_NOMEM")) && *e && *e != '0') {
        g_nomem = 1;
    }

    if ((e = getenv("MMIOTRACE_READS")) && *e && *e != '0') {
        g_reads = 1;
    }

    if ((e = getenv("MMIOTRACE_TIME")) && *e && *e != '0') {
        g_time = 1;
    }

    if ((e = getenv("MMIOTRACE_IOCTL_CENSUS")) && *e && *e != '0') {
        g_ioctl_census = 1;
    }

    if ((e = getenv("MMIOTRACE_SKIP_LO"))) {
        g_skip_lo = strtoull(e, NULL, 0);
    }

    if ((e = getenv("MMIOTRACE_SKIP_HI"))) {
        g_skip_hi = strtoull(e, NULL, 0);
    }

    /* In NOMEM mode nothing is trapped, so the SIGSEGV handler is never needed;
     * installing it would only risk swallowing a genuine app fault.
     */
    if (g_nomem) {
        return;
    }

    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = segv_handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    real_sigaction(SIGSEGV, &sa, &g_old_segv);
}

/* The vendor app installs its OWN SIGSEGV handler (crash reporter) after startup.
 * If that replaced ours, the first store to a trapped PROT_READ page would reach
 * the app's handler as a genuine crash and abort the process (empty trace, dead
 * daemon - the failure observed on hardware). Intercept SIGSEGV (de)registration:
 * keep OUR handler in the kernel, and record the app's intended handler into
 * g_old_segv so segv_handler chains real faults (not on our pages) to it.
 */
int sigaction(int signum, const struct sigaction *act, struct sigaction *oldact)
{
    resolve();
    if (signum != SIGSEGV || g_nomem) {
        return real_sigaction(signum, act, oldact);
    }

    if (oldact) {
        *oldact = g_old_segv;
    }

    if (act) {
        g_old_segv = *act;
    }

    return 0;
}

void (*signal(int signum, void (*handler)(int)))(int)
{
    resolve();
    if (signum != SIGSEGV || g_nomem) {
        return real_signal(signum, handler);
    }

    void (*prev)(int) = (g_old_segv.sa_flags & SA_SIGINFO)
                ? NULL : g_old_segv.sa_handler;

    memset(&g_old_segv, 0, sizeof(g_old_segv));
    g_old_segv.sa_handler = handler;

    return prev;
}

__attribute__((constructor)) static void ctor(void)
{
    resolve();
    install();
}

/* -- wrappers --------------------------------------------------------------- */

static int classify_dev(const char *path)
{
    if (!path) {
        return 0;
    }

    if (strcmp(path, "/dev/mem") == 0) {
        return 1;
    }

    if (strcmp(path, "/dev/ar_sys") == 0) {
        return 2;
    }

    return 0;
}

int open(const char *path, int flags, ...)
{
    mode_t mode = 0;
    int fd;

    resolve();
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, int);
        va_end(ap);
    }

    fd = real_open(path, flags, mode);
    if (fd >= 0 && fd < (int)sizeof(g_devtype)) {
        g_devtype[fd] = classify_dev(path);
    }

    return fd;
}

int openat(int dirfd, const char *path, int flags, ...)
{
    mode_t mode = 0;
    int fd;

    resolve();
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, int);
        va_end(ap);
    }

    fd = real_openat(dirfd, path, flags, mode);
    if (fd >= 0 && fd < (int)sizeof(g_devtype)) {
        g_devtype[fd] = classify_dev(path);
    }

    return fd;
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset)
{
    void *ret;

    resolve();
    ret = real_mmap(addr, len, prot, flags, fd, offset);
    if (ret == MAP_FAILED) {
        return ret;
    }

    /* NOMEM: leave every mapping fully writable and untrapped - capture comes
     * solely from the /dev/ar_sys ioctl hook, which needs no page faults.
     */
    if (g_nomem) {
        return ret;
    }

    if (fd < 0 || fd >= (int)sizeof(g_devtype) || !g_devtype[fd]) {
        return ret;
    }

    if (!(prot & PROT_WRITE) || g_map_count >= MAX_MAPS) {
        return ret;
    }

    install();
    /* Open a read-write alias handle on the same device the app mapped, so the
     * fault handler can perform the trapped store against real hardware.
     */
    int alias_fd;

    if (g_devtype[fd] == 2) {
        if (g_arsys_fd < 0) {
            g_arsys_fd = real_open("/dev/ar_sys", O_RDWR | O_SYNC);
        }
        alias_fd = g_arsys_fd;
    } else {
        if (g_mem_fd < 0) {
            g_mem_fd = real_open("/dev/mem", O_RDWR | O_SYNC);
        }
        alias_fd = g_mem_fd;
    }
    if (alias_fd >= 0) {
        void *alias = real_mmap(NULL, len, PROT_READ | PROT_WRITE,
                    MAP_SHARED, alias_fd, offset);
        if (alias != MAP_FAILED) {
            g_maps[g_map_count].ro_base = (uintptr_t)ret;
            g_maps[g_map_count].len = len;
            g_maps[g_map_count].phys = (uint64_t)offset;
            g_maps[g_map_count].rw = alias;
            g_map_count++;
            /* Trap the app's stores by making the mapping read-only - but ONLY
             * over the [g_lo,g_hi] physical window. The vendor maps ALL of
             * /dev/mem (~256 MiB, offset 0) in one shot and drives every media
             * block through it; trapping the whole thing would fault on codec
             * and display stores too and choke the realtime daemon. Protecting
             * just the intersection with our logging window confines faults to
             * the camera-path blocks (VIF/CSI/ISP). find_map still resolves any
             * faulting address in the full mapping, so nothing else is needed.
             */
            uint64_t map_lo = (uint64_t)offset;
            uint64_t map_hi = (uint64_t)offset + len;   /* exclusive */
            uint64_t win_hi = (g_hi == ~0ull) ? map_hi : g_hi + 1;
            uint64_t plo = g_lo > map_lo ? g_lo : map_lo;
            uint64_t phi = win_hi < map_hi ? win_hi : map_hi;

            if (plo < phi) {
                long pg = sysconf(_SC_PAGESIZE);
                uint64_t a = plo & ~((uint64_t)pg - 1);         /* align down */
                uint64_t b = (phi + pg - 1) & ~((uint64_t)pg - 1); /* align up */
                if (b > map_hi) {
                    b = map_hi;
                }

                uintptr_t va = (uintptr_t)ret + (a - map_lo);
                /* PROT_NONE also faults loads, which is the only way to see
                 * the vendor's polls; PROT_READ traps stores alone.
                 */
                int prot = g_reads ? PROT_NONE : PROT_READ;

                /* An exclusion range leaves one span untrapped inside a wide
                 * window. The vendor maps all 256 MiB of register space in one
                 * call, so a whole-space window is the only way to find writes
                 * outside the blocks we already know; but trapping the encoder
                 * corrupts it and the video pipeline dies before the camera is
                 * ever programmed. Protect either side of the skip instead.
                 *
                 * untrap_reads restores PROT_READ over the union, so do not use
                 * a skip range together with MMIOTRACE_READS.
                 */
                if (g_skip_lo <= g_skip_hi && g_skip_hi >= a && g_skip_lo < b) {
                    uint64_t s_lo = g_skip_lo & ~((uint64_t)pg - 1);
                    uint64_t s_hi = (g_skip_hi + pg) & ~((uint64_t)pg - 1);

                    if (a < s_lo) {
                        mprotect((void *)va, (size_t)(s_lo - a), prot);
                    }

                    if (s_hi < b) {
                        mprotect((void *)((uintptr_t)ret + (s_hi - map_lo)),
                        (size_t)(b - s_hi), prot);
                    }
                } else {
                    mprotect((void *)va, (size_t)(b - a), prot);
                }

                g_maps[g_map_count - 1].prot_va = va;
                g_maps[g_map_count - 1].prot_len = (size_t)(b - a);
            }
        }
    }

    return ret;
}

/**
 * Drop the alias and the table slot when the app unmaps a traced range.
 *
 * Without this the table only ever grows: the app's mapping goes away, its slot
 * keeps a stale ro_base that find_map can match against a later unrelated
 * mapping at the same address, and once g_map_count reaches MAX_MAPS the mmap
 * wrapper stops tracing new mappings with no diagnostic. The alias VMA also
 * stays behind in a process we do not own.
 *
 * Only a whole-mapping unmap releases the slot. A partial unmap would leave the
 * alias describing a range the app no longer has, and splitting the entry is not
 * worth it for a case the vendor stack has never been seen to do; the entry is
 * kept and a note goes in the trace so it is visible rather than silent.
 */
int munmap(void *addr, size_t len)
{
    int i;

    resolve();

    for (i = 0; i < g_map_count; i++) {
        if ((uintptr_t)addr != g_maps[i].ro_base) {
            continue;
        }

        if (len < g_maps[i].len) {
            log_note("partial munmap of a traced mapping, slot kept", (uint32_t)len);
            break;
        }

        real_munmap((void *)g_maps[i].rw, g_maps[i].len);
        g_maps[i] = g_maps[g_map_count - 1];
        g_map_count--;
        break;
    }

    return real_munmap(addr, len);
}

/* /dev/ar_sys register-write path used by the VIN HAL: ioctl 0xc018410f with a
 * struct { u64 addr; u32 val; u32; u32; }. Log the write, then pass it through.
 */
int ioctl(int fd, unsigned long request, ...)
{
    void *arg;
    va_list ap;

    resolve();
    va_start(ap, request);
    arg = va_arg(ap, void *);
    va_end(ap);

    if (request == 0xc018410ful && arg) {
        struct { uint64_t addr; uint32_t val; uint32_t a, b; } *r = arg;

        log_write(r->addr, r->val, 4, 1);
    } else if (g_ioctl_census && fd >= 0 && fd < (int)sizeof(g_devtype) &&
           g_devtype[fd] == 2) {
        /* Every other request on an ar_sys fd. The known register-write magic is
         * one of many; a run that logs nothing through it has not established that
         * the vendor programs no registers this way, only that it does not use
         * that number. Logged once per distinct request.
         */
        unsigned i;

        for (i = 0; i < g_seen_count; i++) {
            if (g_seen[i] == request) {
                return real_ioctl(fd, request, arg);
            }
        }

        if (g_seen_count < MAX_SEEN) {
            g_seen[g_seen_count++] = request;
            log_note("ar_sys ioctl request", (uint32_t)request);
        }
    }
    return real_ioctl(fd, request, arg);
}
