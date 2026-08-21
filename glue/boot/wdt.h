/**
 * @file wdt.h
 * @brief Shared watchdog-reset primitive for the Artosyn goggle boot helpers.
 *
 * reboot()/kernel restart is unreliable on this SoC, so fire_watchdog() hard-resets it through
 * the DesignWare watchdog: leave the counter armed and stop feeding it. Header-only (static
 * functions) so each helper stays a single self-contained -static binary with no extra link
 * step. Shared by wdt-reset.c (reset only) and uboot-trigger.c (which sets the reboot-reason
 * flag first, then fires the same reset).
 *
 * The timeout the counter is armed with is the whole safety question. The kernel starts feeding
 * the watchdog at driver probe (CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED), a few seconds into boot,
 * so a timeout shorter than SPL plus that probe leaves the SoC unable to boot far enough to feed
 * it. Measured on the goggle: a reset armed at TOP index 0 (65536 counts at 24 MHz = 2.73 ms)
 * never comes back, panel dark and USB silent, and only removing power recovers it. Armed at the
 * timeout the running system already uses, the same reset reboots cleanly every time.
 *
 * So this file never shortens the timeout. It resets by taking the feeder away and letting the
 * armed counter run out, which costs up to one timeout period (about 45 s with the goggle's
 * `watchdog -T 30`) and is the same path a kernel hang takes.
 */
#ifndef ML_WDT_H
#define ML_WDT_H

#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/watchdog.h>
#include <unistd.h>

#define MAP_SIZE 0x1000u              /* one 4K page (the mmap window) */

/* DesignWare watchdog: register byte offsets, then the values read and poked. */
#define DWWDT_BASE            0x01600000u
#define DWWDT_CR              0x00    /* control register */
#define DWWDT_TORR            0x04    /* timeout range register */
#define DWWDT_CCVR            0x08    /* current counter value */
#define DWWDT_CRR             0x0c    /* counter restart register */
#define DWWDT_CR_ENABLE_RESET 0x01u   /* enable, response mode 0 = system reset */
#define DWWDT_CRR_KICK        0x76u   /* restart-counter magic (start it) */

/* The board synthesises the standard 2^(16+i) timeout ladder (snps,watchdog-tops in the DTS)
 * against a 24 MHz reference. Index 14 is 2^30 counts, about 44.7 s: what the kernel programs
 * for the running `watchdog -T 30` and therefore the one value this hardware is known to boot
 * through. Used only when the watchdog is found disarmed and something has to arm it.
 */
#define DWWDT_TOP_INDEX_KNOWN_BOOTABLE 0x0eu
#define DWWDT_REFERENCE_HZ             24000000u

/** @brief Map one page covering @p base from an open /dev/mem, or MAP_FAILED. */
static volatile uint32_t *map_page(int fd, off_t base)
{
    return (volatile uint32_t *)mmap(0, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, base);
}

/**
 * @brief Seconds the armed counter still has to run, from CCVR.
 * @return remaining whole seconds, or 0 if the registers could not be read.
 */
static unsigned int watchdog_seconds_remaining(volatile uint32_t *watchdog_registers)
{
    if (watchdog_registers == MAP_FAILED) {
        return 0;
    }

    return watchdog_registers[DWWDT_CCVR / 4] / DWWDT_REFERENCE_HZ;
}

/**
 * @brief Find the process holding /dev/watchdog open.
 *
 * The watchdog core admits a single opener, so once a feeder has the device no other process
 * can arm it through the driver. Walks /proc/<pid>/fd looking for the link back to the node.
 *
 * @return the holder's pid, or 0 when nothing holds it.
 */
static pid_t find_watchdog_holder(void)
{
    DIR *proc_dir = opendir("/proc");
    if (!proc_dir) {
        return 0;
    }

    pid_t holder_pid = 0;
    struct dirent *proc_entry;
    while (!holder_pid && (proc_entry = readdir(proc_dir))) {
        if (proc_entry->d_name[0] < '0' || proc_entry->d_name[0] > '9') {
            continue;
        }

        /* Sized for the longest name readdir can hand back, so the formats cannot truncate. */
        char fd_dir_path[sizeof proc_entry->d_name + 16];
        snprintf(fd_dir_path, sizeof fd_dir_path, "/proc/%s/fd", proc_entry->d_name);

        DIR *fd_dir = opendir(fd_dir_path);
        if (!fd_dir) {
            continue;
        }

        struct dirent *fd_entry;
        while ((fd_entry = readdir(fd_dir))) {
            char fd_path[sizeof fd_dir_path + sizeof fd_entry->d_name + 2];
            char link_target[128];

            snprintf(fd_path, sizeof fd_path, "%s/%s", fd_dir_path, fd_entry->d_name);
            ssize_t link_length = readlink(fd_path, link_target, sizeof link_target - 1);
            if (link_length <= 0) {
                continue;
            }

            link_target[link_length] = '\0';
            if (strcmp(link_target, "/dev/watchdog") == 0) {
                holder_pid = (pid_t)atoi(proc_entry->d_name);
                break;
            }
        }

        closedir(fd_dir);
    }

    closedir(proc_dir);

    return holder_pid;
}

/**
 * @brief Fire the watchdog and hard-reset the SoC.
 *
 * Three ways in, tried in order, all of which leave the armed timeout alone:
 *   1. Nothing holds /dev/watchdog: open it, close without the magic 'V'. CONFIG_WATCHDOG_NOWAYOUT
 *      is set, so the core keeps the counter armed and the reset follows.
 *   2. A feeder holds it: SIGSTOP the feeder. Its fd stays open and unclosed, so nothing can stop
 *      the counter, and it runs out.
 *   3. The counter is not armed at all: arm it by raw register write at the timeout index the
 *      running system uses.
 *
 * @param tag prefixes the progress lines (the caller's program name).
 * @return 1 only if none of the three reset the SoC; on success it never returns.
 */
static int fire_watchdog(const char *tag)
{
    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    volatile uint32_t *watchdog_registers = MAP_FAILED;
    if (mem_fd >= 0) {
        watchdog_registers = map_page(mem_fd, DWWDT_BASE);
    }

    unsigned int is_armed = 0;
    unsigned int wait_seconds = 60;
    if (watchdog_registers != MAP_FAILED) {
        is_armed = watchdog_registers[DWWDT_CR / 4] & DWWDT_CR_ENABLE_RESET;
        /* Twice the counter's own estimate. Measured on the goggle, the reset lands noticeably
         * later than the raw count predicts (89 s on the counter, about 136 s to the reset), so
         * a margin below 2x reports failure while the reset is still coming. */
        wait_seconds = watchdog_seconds_remaining(watchdog_registers) * 2 + 10;
        printf("%s: watchdog enabled=%u, TORR=0x%02x, ~%u s on the counter\n", tag, is_armed,
               watchdog_registers[DWWDT_TORR / 4] & 0xffu,
               watchdog_seconds_remaining(watchdog_registers));
        fflush(stdout);
    }

    /* 1. driver path, only available when no feeder holds the device */
    int watchdog_fd = open("/dev/watchdog", O_WRONLY);
    if (watchdog_fd >= 0) {
        ioctl(watchdog_fd, WDIOC_KEEPALIVE, 0);
        printf("%s: armed via /dev/watchdog, closing without 'V'; resetting in ~%u s...\n",
               tag, wait_seconds);
        fflush(stdout);
        sync();
        close(watchdog_fd);
        sleep(wait_seconds);
    }

    /* 2. a feeder holds it: stop the feeder rather than the counter */
    pid_t holder_pid = find_watchdog_holder();
    if (holder_pid > 0) {
        printf("%s: pid %d holds /dev/watchdog; SIGSTOP, resetting in ~%u s...\n",
               tag, (int)holder_pid, wait_seconds);
        fflush(stdout);
        sync();
        kill(holder_pid, SIGSTOP);
        sleep(wait_seconds);
    }

    /* 3. nothing is armed, so arm it at the index this hardware boots through */
    if (!is_armed && watchdog_registers != MAP_FAILED) {
        printf("%s: watchdog was disarmed; arming at TOP 0x%02x...\n",
               tag, DWWDT_TOP_INDEX_KNOWN_BOOTABLE);
        fflush(stdout);
        sync();
        watchdog_registers[DWWDT_TORR / 4] = DWWDT_TOP_INDEX_KNOWN_BOOTABLE;
        watchdog_registers[DWWDT_CR / 4]   = DWWDT_CR_ENABLE_RESET;
        watchdog_registers[DWWDT_CRR / 4]  = DWWDT_CRR_KICK;
        sleep(wait_seconds);
    }

    fprintf(stderr, "%s: did NOT reset (watchdog inoperative?)\n", tag);

    return 1;
}

#endif /* ML_WDT_H */
