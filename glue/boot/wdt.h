/* wdt.h - shared watchdog-reset primitive for the Artosyn goggle boot helpers.
 *
 * reboot()/kernel restart is unreliable on this SoC, so fire_watchdog() hard-resets it the
 * way the vendor's ar_wdt_service does: open /dev/watchdog, set the shortest timeout, and
 * close WITHOUT the magic 'V' so the kernel leaves it armed and it fires; then a raw
 * DesignWare-watchdog register poke via /dev/mem as the fallback. Both paths reset the SoC,
 * so on success fire_watchdog() never returns.
 *
 * Header-only (static functions) so each helper stays a single self-contained -static binary
 * with no extra link step. Shared by wdt-reset.c (reset only) and uboot-trigger.c (which
 * sets the reboot-reason flag first, then fires the same reset).
 */
#ifndef ML_WDT_H
#define ML_WDT_H

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/watchdog.h>
#include <stdint.h>
#include <unistd.h>
#include <stdio.h>

#define MAP_SIZE 0x1000u              /* one 4K page (the mmap window) */

/* DesignWare watchdog: register byte offsets, then the values poked. */
#define DWWDT_BASE            0x01600000u
#define DWWDT_CR              0x00    /* control register */
#define DWWDT_TORR            0x04    /* timeout range register */
#define DWWDT_CRR             0x0c    /* counter restart register */
#define DWWDT_CR_ENABLE_RESET 0x1du   /* enable + system-reset response */
#define DWWDT_TORR_SHORTEST   0x00u   /* shortest timeout */
#define DWWDT_CRR_KICK        0x76u   /* restart-counter magic (start it) */

static volatile uint32_t *map_page(int fd, off_t base) {
    return (volatile uint32_t *)mmap(0, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, base);
}

/* Fire the watchdog and hard-reset the SoC. `tag` prefixes the progress lines (the caller's
 * program name). Returns 1 only if neither path reset the SoC (watchdog inoperative); on
 * success it never returns.
 */
static int fire_watchdog(const char *tag) {
    /* 1. driver path: shortest timeout, close without 'V' so the kernel keeps it armed */
    int watchdog_fd = open("/dev/watchdog", O_WRONLY);
    if (watchdog_fd >= 0) {
        int timeout_secs = 1;
        ioctl(watchdog_fd, WDIOC_SETTIMEOUT, &timeout_secs);   /* best effort (may clamp on "No valid TOPs") */
        ioctl(watchdog_fd, WDIOC_KEEPALIVE, 0);
        printf("%s: watchdog armed via /dev/watchdog; resetting...\n", tag);
        fflush(stdout);
        close(watchdog_fd);
        sleep(8);
    }

    /* 2. fallback: raw dw-wdt poke if the driver path did not reset in time */
    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
      perror("open /dev/mem");
      return 1;
    }

    printf("%s: driver path didn't reset; raw dw-wdt poke...\n", tag);
    fflush(stdout);
    volatile uint32_t *wdt_regs = map_page(mem_fd, DWWDT_BASE);
    if (wdt_regs != MAP_FAILED) {
        wdt_regs[DWWDT_TORR / 4] = DWWDT_TORR_SHORTEST;
        wdt_regs[DWWDT_CR / 4]   = DWWDT_CR_ENABLE_RESET;
        wdt_regs[DWWDT_CRR / 4]  = DWWDT_CRR_KICK;
    }
    sleep(5);

    fprintf(stderr, "%s: did NOT reset (watchdog inoperative?)\n", tag);
    return 1;
}

#endif /* ML_WDT_H */
