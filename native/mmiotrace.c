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
 * Build: shared, PIC, glibc (see native/build.sh). Use:
 *   LD_PRELOAD=/tmp/mmiotrace.so MMIOTRACE_OUT=/tmp/mmio.log \
 *   MMIOTRACE_LO=0x08800000 MMIOTRACE_HI=0x08880fff <vendor camera command>
 * MMIOTRACE_LO/HI (optional) restrict logging to a physical window; default logs
 * every /dev/mem store. Reads never fault, so only writes are traced.
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
#include <ucontext.h>
#include <unistd.h>

/** Largest number of distinct /dev/mem mappings tracked at once. */
#define MAX_MAPS 64

struct traced_map {
	uintptr_t ro_base;	/**< base of the app's read-only mapping */
	size_t len;		/**< mapping length */
	uint64_t phys;		/**< physical base (the mmap offset argument) */
	volatile uint8_t *rw;	/**< read-write alias of the same physical range */
};

static struct traced_map g_maps[MAX_MAPS];
static int g_map_count;
static int g_mem_fd = -1;	/**< our own O_RDWR handle on /dev/mem, for aliases */
static int g_arsys_fd = -1;	/**< our own O_RDWR handle on /dev/ar_sys */
static int g_log_fd = -1;
static uint64_t g_lo, g_hi = ~0ull;	/**< physical logging window */
static uint64_t g_seq;			/**< global write order counter */
static int g_installed;
static int g_nomem;			/**< MMIOTRACE_NOMEM: don't trap /dev/mem stores
					 * via mprotect+SIGSEGV (which interrupts the
					 * app's blocking ioctls with -ERESTARTSYS and
					 * crashes realtime daemons); rely on the clean
					 * /dev/ar_sys ioctl hook only. */

/* Real libc entry points, resolved lazily to avoid our own wrappers. */
static void *(*real_mmap)(void *, size_t, int, int, int, off_t);
static int (*real_open)(const char *, int, ...);
static int (*real_openat)(int, const char *, int, ...);
static int (*real_ioctl)(int, unsigned long, ...);
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

	for (i = digits - 1; i >= 0; i--)
		buf[(*pos)++] = h[(n >> (i * 4)) & 0xf];
}

static void put_str(char *buf, int *pos, const char *s)
{
	while (*s)
		buf[(*pos)++] = *s++;
}

/** One trace line. Only async-signal-safe calls (write). */
static void log_write(uint64_t phys, uint64_t val, int width, int decoded)
{
	char buf[96];
	int p = 0;

	if (g_log_fd < 0)
		return;
	if (phys < g_lo || phys > g_hi)
		return;

	put_str(buf, &p, "w");
	put_hex(buf, &p, g_seq++, 6);
	put_str(buf, &p, decoded ? " w" : " ?");
	put_hex(buf, &p, (uint64_t)(width * 8), 2);
	put_str(buf, &p, " pa=0x");
	put_hex(buf, &p, phys, 8);
	put_str(buf, &p, " val=0x");
	put_hex(buf, &p, val & (width >= 8 ? ~0ull : ((1ull << (width * 8)) - 1)), 8);
	buf[p++] = '\n';
	(void)write(g_log_fd, buf, p);
}

/* -- init ------------------------------------------------------------------- */

static void resolve(void)
{
	if (!real_mmap)
		real_mmap = dlsym(RTLD_NEXT, "mmap");
	if (!real_open)
		real_open = dlsym(RTLD_NEXT, "open");
	if (!real_openat)
		real_openat = dlsym(RTLD_NEXT, "openat");
	if (!real_ioctl)
		real_ioctl = dlsym(RTLD_NEXT, "ioctl");
	if (!real_sigaction)
		real_sigaction = dlsym(RTLD_NEXT, "sigaction");
	if (!real_signal)
		real_signal = dlsym(RTLD_NEXT, "signal");
}

static void find_map(uintptr_t addr, struct traced_map **out, size_t *off)
{
	int i;

	*out = NULL;
	for (i = 0; i < g_map_count; i++) {
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
	if ((insn & 0x7fc00000u) == 0x29000000u ||	/* STP signed offset */
	    (insn & 0x7fc00000u) == 0x29800000u ||	/* STP pre-index    */
	    (insn & 0x7fc00000u) == 0x28800000u) {	/* STP post-index   */
		unsigned opc = insn >> 30;
		int w = opc ? 8 : 4;
		unsigned rt2 = (insn >> 10) & 0x1f;
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
	case 1:
		*(volatile uint8_t *)dst = (uint8_t)val;
		break;
	case 2:
		*(volatile uint16_t *)dst = (uint16_t)val;
		break;
	case 8:
		*(volatile uint64_t *)dst = val;
		break;
	default:
		*(volatile uint32_t *)dst = (uint32_t)val;
		break;
	}
	(void)fault;
	uc->uc_mcontext.pc += 4;
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
		if (g_old_segv.sa_flags & SA_SIGINFO)
			g_old_segv.sa_sigaction(sig, si, ctx);
		else if (g_old_segv.sa_handler == SIG_DFL ||
			 g_old_segv.sa_handler == SIG_IGN)
			_exit(139);
		else
			g_old_segv.sa_handler(sig);
		return;
	}
	insn = *(uint32_t *)uc->uc_mcontext.pc;
	decode_store(insn, uc, fault, m, off);
}

static void install(void)
{
	struct sigaction sa;
	const char *e;

	if (g_installed)
		return;
	g_installed = 1;

	e = getenv("MMIOTRACE_OUT");
	g_log_fd = open(e ? e : "/tmp/mmio.log",
			O_WRONLY | O_CREAT | O_APPEND, 0644);
	if ((e = getenv("MMIOTRACE_LO")))
		g_lo = strtoull(e, NULL, 0);
	if ((e = getenv("MMIOTRACE_HI")))
		g_hi = strtoull(e, NULL, 0);
	if ((e = getenv("MMIOTRACE_NOMEM")) && *e && *e != '0')
		g_nomem = 1;

	/* In NOMEM mode nothing is trapped, so the SIGSEGV handler is never needed;
	 * installing it would only risk swallowing a genuine app fault.
	 */
	if (g_nomem)
		return;

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
	if (signum != SIGSEGV || g_nomem)
		return real_sigaction(signum, act, oldact);
	if (oldact)
		*oldact = g_old_segv;
	if (act)
		g_old_segv = *act;
	return 0;
}

void (*signal(int signum, void (*handler)(int)))(int)
{
	resolve();
	if (signum != SIGSEGV || g_nomem)
		return real_signal(signum, handler);

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
	if (!path)
		return 0;
	if (strcmp(path, "/dev/mem") == 0)
		return 1;
	if (strcmp(path, "/dev/ar_sys") == 0)
		return 2;
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
	if (fd >= 0 && fd < (int)sizeof(g_devtype))
		g_devtype[fd] = classify_dev(path);
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
	if (fd >= 0 && fd < (int)sizeof(g_devtype))
		g_devtype[fd] = classify_dev(path);
	return fd;
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset)
{
	void *ret;

	resolve();
	ret = real_mmap(addr, len, prot, flags, fd, offset);
	if (ret == MAP_FAILED)
		return ret;
	/* NOMEM: leave every mapping fully writable and untrapped - capture comes
	 * solely from the /dev/ar_sys ioctl hook, which needs no page faults.
	 */
	if (g_nomem)
		return ret;
	if (fd < 0 || fd >= (int)sizeof(g_devtype) || !g_devtype[fd])
		return ret;
	if (!(prot & PROT_WRITE) || g_map_count >= MAX_MAPS)
		return ret;

	install();
	/* Open a read-write alias handle on the same device the app mapped, so the
	 * fault handler can perform the trapped store against real hardware.
	 */
	int alias_fd;

	if (g_devtype[fd] == 2) {
		if (g_arsys_fd < 0)
			g_arsys_fd = real_open("/dev/ar_sys", O_RDWR | O_SYNC);
		alias_fd = g_arsys_fd;
	} else {
		if (g_mem_fd < 0)
			g_mem_fd = real_open("/dev/mem", O_RDWR | O_SYNC);
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
			uint64_t map_hi = (uint64_t)offset + len;	/* exclusive */
			uint64_t win_hi = (g_hi == ~0ull) ? map_hi : g_hi + 1;
			uint64_t plo = g_lo > map_lo ? g_lo : map_lo;
			uint64_t phi = win_hi < map_hi ? win_hi : map_hi;

			if (plo < phi) {
				long pg = sysconf(_SC_PAGESIZE);
				uint64_t a = plo & ~((uint64_t)pg - 1);		/* align down */
				uint64_t b = (phi + pg - 1) & ~((uint64_t)pg - 1); /* align up */
				if (b > map_hi)
					b = map_hi;
				uintptr_t va = (uintptr_t)ret + (a - map_lo);
				mprotect((void *)va, (size_t)(b - a), PROT_READ);
			}
		}
	}
	return ret;
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
	}
	return real_ioctl(fd, request, arg);
}
