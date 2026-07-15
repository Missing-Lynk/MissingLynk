/*
 * air-qpower.c - read the AIR unit's APPLIED RF/camera settings out of the running ar_lowdelay.
 *
 * The air (ar_lowdelay `-t 1`, TX) exposes NO binder reader for applied params: its `ar_lowdelay_tx`
 * service is an argv-string console with setters only (docs/reference/mid-api.md). The applied values
 * live in a calloc(0x200) "sysctrl handle" struct on the heap, written by SetTranParm/SetLdCfg:
 *
 *   handle + 0x00   char  hardware version string "V1.%d"  <- signature we scan for
 *   handle + 0x20   char  software version string  ("1.0.44.rel"-class)
 *   handle + 0x118  u8    TX power level (0x05/0x0e/0x14/0x17 = 3/25/100/200 mW)
 *   handle + 0x120  u8    standby (u8StandbyModeEn)
 *   handle + 0xb0.. 0xC0  SetLdCfg camera/ISP block: +0x02 u16 saturation, +0x14 rotation, +0x43 u8 roi
 *
 * The .bss pointer slot that holds this struct's address is at a build-specific VA (the air runs a
 * different ar_lowdelay build than our decompile - md5 differs), so instead of a hard-coded address we
 * SCAN the process heap for the struct by its version-string signature - robust to any firmware build.
 *
 * These values are RAM-only: the air does NOT persist them; the goggle re-pushes SetTranParm/SetLdCfg
 * every association. So this reads back what the goggle last commanded and the air actually stored -
 * the way to verify our settings take. Run on the air over ml-tcprelay :8822 (root, read-only).
 *
 * RE: re/ghidra ar_lowdelay SetTranParm @00448b78 / SetLdCfg @004487a0 / SetSoftHardwareVer.
 * Build: static aarch64 (native/build.sh). Run on the air: ./air-qpower [pid]
 */
#include <ctype.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define HANDLE_LEN     0x200
#define OFF_HWVER      0x00
#define OFF_SWVER      0x20
#define OFF_LDCFG      0xb0
#define LDCFG_LEN      0xc0
#define OFF_POWER      0x118
#define OFF_STANDBY    0x120

static const char *power_mw(int v)
{
    switch (v) {
        case 0x05: return "3 mW";
        case 0x0e: return "25 mW";
        case 0x14: return "100 mW";
        case 0x17: return "200 mW";
        default:   return "(unmapped)";
    }
}

static int find_pid(const char *name)
{
    DIR *d = opendir("/proc");
    if (d == NULL) {
        return 0;
    }

    struct dirent *e;
    int found = 0;
    while ((e = readdir(d)) != NULL && found == 0) {
        if (!isdigit((unsigned char) e->d_name[0])) {
            continue;
        }

        char path[64], comm[64];
        snprintf(path, sizeof path, "/proc/%s/comm", e->d_name);
        int fd = open(path, O_RDONLY);
        if (fd < 0) {
            continue;
        }

        ssize_t n = read(fd, comm, sizeof comm - 1);
        close(fd);
        if (n <= 0) {
            continue;
        }

        comm[n] = '\0';
        if (comm[n - 1] == '\n') {
            comm[n - 1] = '\0';
        }
        if (strcmp(comm, name) == 0) {
            found = atoi(e->d_name);
        }
    }

    closedir(d);
    return found;
}

/* [heap] range from /proc/<pid>/maps (start/end); -1 if not found. */
static int heap_range(int pid, uint64_t *start, uint64_t *end)
{
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/maps", pid);
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return -1;
    }

    char line[256];
    int ok = -1;
    while (fgets(line, sizeof line, f) != NULL) {
        if (strstr(line, "[heap]") != NULL) {
            if (sscanf(line, "%llx-%llx", (unsigned long long *) start,
                       (unsigned long long *) end) == 2) {
                ok = 0;
            }
            break;
        }
    }

    fclose(f);
    return ok;
}

/* True if buf is a NUL-terminated, printable version string: starts with a digit, has a '.'. */
static int looks_version(const uint8_t *buf, int len)
{
    if (!isdigit(buf[0])) {
        return 0;
    }

    int dot = 0;
    for (int i = 0; i < len; i++) {
        if (buf[i] == '\0') {
            return dot && i >= 3;
        }
        if (!isprint(buf[i])) {
            return 0;
        }
        if (buf[i] == '.') {
            dot = 1;
        }
    }
    return 0;
}

/* Scan the heap for the sysctrl handle: "V<digit>." at +0x00 AND a version string at +0x20. */
static uint64_t find_handle(int fd, uint64_t start, uint64_t end)
{
    const size_t CHUNK = 256 * 1024;
    uint8_t *buf = malloc(CHUNK);
    if (buf == NULL) {
        return 0;
    }

    uint64_t handle = 0;
    for (uint64_t a = start; a < end && handle == 0; a += CHUNK) {
        size_t want = (end - a < CHUNK) ? (size_t) (end - a) : CHUNK;
        if (pread(fd, buf, want, (off_t) a) != (ssize_t) want) {
            continue;   /* unreadable window: skip */
        }

        for (size_t o = 0; o + 3 < want; o++) {
            if (buf[o] != 'V' || !isdigit(buf[o + 1]) || buf[o + 2] != '.') {
                continue;
            }

            uint8_t ver[16];
            if (pread(fd, ver, sizeof ver, (off_t) (a + o + OFF_SWVER)) != (ssize_t) sizeof ver) {
                continue;
            }
            if (looks_version(ver, sizeof ver)) {
                handle = a + o;   /* +0x00 = "V1.x", +0x20 = sw version -> struct base */
                break;
            }
        }
    }

    free(buf);
    return handle;
}

int main(int argc, char **argv)
{
    int pid = argc > 1 ? atoi(argv[1]) : find_pid("ar_lowdelay");
    if (pid <= 0) {
        fprintf(stderr, "air-qpower: ar_lowdelay not found (pass its pid as arg)\n");
        return 1;
    }

    char path[64];
    snprintf(path, sizeof path, "/proc/%d/mem", pid);
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "air-qpower: open %s: run as root\n", path);
        return 1;
    }

    uint64_t hstart = 0, hend = 0;
    if (heap_range(pid, &hstart, &hend) != 0) {
        fprintf(stderr, "air-qpower: no [heap] mapping for pid %d\n", pid);
        close(fd);
        return 1;
    }

    uint64_t handle = find_handle(fd, hstart, hend);
    if (handle == 0) {
        fprintf(stderr, "air-qpower: sysctrl handle not found in heap (0x%llx-0x%llx) - "
                        "ar_lowdelay not fully up?\n",
                (unsigned long long) hstart, (unsigned long long) hend);
        close(fd);
        return 1;
    }

    char hwver[16] = {0}, swver[32] = {0};
    uint8_t power = 0, standby = 0, ldcfg[LDCFG_LEN];
    pread(fd, hwver, sizeof hwver - 1, (off_t) (handle + OFF_HWVER));
    pread(fd, swver, sizeof swver - 1, (off_t) (handle + OFF_SWVER));
    pread(fd, &power, 1, (off_t) (handle + OFF_POWER));
    pread(fd, &standby, 1, (off_t) (handle + OFF_STANDBY));
    pread(fd, ldcfg, LDCFG_LEN, (off_t) (handle + OFF_LDCFG));
    close(fd);

    printf("ar_lowdelay pid=%d  sysctrl handle=0x%llx  (hw %s / sw %s)\n",
           pid, (unsigned long long) handle, hwver, swver);
    printf("  TX power    : 0x%02x  (%s)\n", power, power_mw(power));
    printf("  standby     : %u\n", standby);
    printf("  rotation    : %u\n", (unsigned) (ldcfg[0x14] | (ldcfg[0x15] << 8)));
    printf("  saturation  : %u\n", (unsigned) (ldcfg[0x02] | (ldcfg[0x03] << 8)));
    printf("  roi_enable  : %u\n", ldcfg[0x43]);
    printf("  SetLdCfg block (handle+0xb0, 0xC0 bytes):\n");
    for (int i = 0; i < LDCFG_LEN; i += 16) {
        printf("    +0x%02x:", i);
        for (int j = 0; j < 16 && i + j < LDCFG_LEN; j++) {
            printf(" %02x", ldcfg[i + j]);
        }
        printf("\n");
    }
    return 0;
}
