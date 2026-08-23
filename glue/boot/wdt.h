/**
 * @file wdt.h
 * @brief Shared watchdog-reset primitive for the Artosyn boot helpers.
 *
 * reboot()/kernel restart is unreliable on this SoC, so fire_watchdog() hard-resets it through the
 * DesignWare watchdog: shorten the armed timeout, then take away whatever was feeding the counter.
 * Header-only (static functions) so each helper stays a single self-contained -static binary with
 * no extra link step. Shared by wdt-reset.c and uboot-trigger.c, which sets the SPL reboot-reason
 * flag first and then fires the same reset.
 *
 * Shortening the timeout is the vendor's own reboot: `ar_wdt_service -t 1` asks for a one-second
 * timeout through WDIOC_SETTIMEOUT on /dev/watchdog0, stock's reboot script then kills the feeder,
 * and the board goes down in about 2 s.
 *
 * Two values are ruled out by measurement. TOP index 0, 65536 counts, left the SoC dark twice with
 * no USB and no ping, recoverable only by removing power, so DWWDT_TOP_INDEX_MIN floors every path
 * far above it. And closing /dev/watchdog with the magic 'V' clears the active flag, after which
 * the watchdog core pets the timer itself and the board never resets, so no path here does that.
 * `rc-service ml-watchdog stop` ends the same way and is not a reset step.
 *
 * dw_wdt builds its timeout table from the rate the DT declares, DWWDT_DT_CLOCK_HZ, so a
 * WDIOC_SETTIMEOUT request selects a ladder entry against that table. The rate the counter really
 * ticks at is measured from CCVR: on the air unit it read 23,999,766 Hz, so the two agree and the
 * ladder periods below are the true ones.
 *
 * Ordering is the safety question once the period is single-digit seconds: sync() runs to
 * completion before anything arms, because the counter reloads at the arming step and everything
 * after it runs inside the new period.
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
#include <time.h>
#include <unistd.h>

#define MAP_SIZE 0x1000u              /* one 4K page (the mmap window) */

/* DesignWare watchdog: register byte offsets, then the values read and poked. */
#define DWWDT_BASE            0x01600000u
#define DWWDT_CR              0x00    /* control register */
#define DWWDT_TORR            0x04    /* timeout range register */
#define DWWDT_CCVR            0x08    /* current counter value */
#define DWWDT_CRR             0x0c    /* counter restart register */
#define DWWDT_CR_ENABLE_RESET 0x01u   /* enable, response mode 0 = system reset */
#define DWWDT_CRR_KICK        0x76u   /* restart-counter magic, reloads from TORR */
#define DWWDT_TORR_TOP_MASK   0x0fu   /* the ladder index lives in the low nibble */

/* The board synthesises the standard 2^(16+i) timeout ladder (snps,watchdog-tops in the DTS).
 * Index 11 is 2^27 counts, 5.59 s at the measured 24 MHz, several times the one second the
 * vendor's own reboot asks for.
 */
#define DWWDT_TOP_INDEX_RESET          0x0bu
#define DWWDT_TOP_INDEX_MIN            0x08u
#define DWWDT_TOP_INDEX_MAX            0x0du

/* Used only when the watchdog is found disarmed and something has to arm it: the index the kernel
 * programs for the running feeder, and therefore the one this hardware is known to boot through.
 */
#define DWWDT_TOP_INDEX_KNOWN_BOOTABLE 0x0eu

/* What the DTS declares for this block, and therefore the rate dw_wdt's own timeout table is
 * built from. A WDIOC_SETTIMEOUT request is interpreted against that table, not against the rate
 * the counter is measured to tick at.
 */
#define DWWDT_DT_CLOCK_HZ 24000000u

/**
 * @brief Process exit status.
 *
 * The caller needs to tell "a reset is on its way" from "nothing is coming", which is not the same
 * question as whether everything went to plan. flip-slot.sh reads these as $?, so the values are a
 * contract across the language boundary and are spelled out rather than left to declaration order.
 */
typedef enum {
    WDT_EXIT_RESET_COMING = 0,  /**< success; on a reset run, a reset is on its way */
    WDT_EXIT_NO_RESET     = 1,  /**< nothing was armed and nothing is coming */
    WDT_EXIT_USAGE        = 2,  /**< the command line was not understood */
} wdt_exit;

/** @brief Command-line options shared by the helpers. */
struct wdt_options {
    unsigned int top_index;      /**< ladder index to arm */
    int is_status_only;          /**< report and exit, arming nothing */
};

/** @brief Map one page covering @p base from an open /dev/mem, or MAP_FAILED. */
static inline volatile uint32_t *map_page(int fd, off_t base)
{
    return (volatile uint32_t *)mmap(0, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, base);
}

/**
 * @brief Measure the rate the counter actually ticks at, from two timed CCVR reads.
 *
 * Measured 23,999,766 Hz on the air unit, matching the 24 MHz the DTS declares. Resets have been
 * observed landing about 1.5x later than that rate predicts, so whatever explains the gap, it is
 * not the clock. Reads no more than the counter, and arms nothing.
 *
 * @return ticks per second, or 0 when the counter reloaded inside the sample window (a feeder
 *         pinged, or the period elapsed) and the delta therefore says nothing.
 */
static inline unsigned int watchdog_measure_tick_rate_hz(volatile uint32_t *watchdog_registers)
{
    if (watchdog_registers == MAP_FAILED) {
        return 0;
    }

    /* A feeder ping reloads the counter and makes one window's delta meaningless. Pings arrive
     * every few seconds and the window is a fifth of one, so retrying clears it.
     */
    for (int attempt = 0; attempt < 3; attempt++) {
        const struct timespec sample_window = { 0, 200000000L };
        struct timespec start_time;
        struct timespec end_time;

        clock_gettime(CLOCK_MONOTONIC, &start_time);
        uint32_t first_count = watchdog_registers[DWWDT_CCVR / 4];
        nanosleep(&sample_window, NULL);
        uint32_t second_count = watchdog_registers[DWWDT_CCVR / 4];
        clock_gettime(CLOCK_MONOTONIC, &end_time);

        if (second_count >= first_count) {
            continue;
        }

        double elapsed_seconds = (double)(end_time.tv_sec - start_time.tv_sec)
                               + (double)(end_time.tv_nsec - start_time.tv_nsec) / 1000000000.0;
        if (elapsed_seconds <= 0.0) {
            continue;
        }

        return (unsigned int)((double)(first_count - second_count) / elapsed_seconds);
    }

    return 0;
}

/** @brief Whole seconds one ladder index runs for at @p tick_rate_hz, or 0 if the rate is unknown. */
static inline unsigned int watchdog_period_seconds(unsigned int top_index, unsigned int tick_rate_hz)
{
    if (tick_rate_hz == 0) {
        return 0;
    }

    return (unsigned int)(((uint64_t)1 << (16 + top_index)) / tick_rate_hz);
}

/**
 * @brief The WDIOC_SETTIMEOUT request that selects @p top_index.
 *
 * dw_wdt truncates each ladder entry to whole seconds and picks the first entry at or above the
 * request, so the request is the truncated period of the wanted index, computed against the rate
 * the driver believes rather than the measured one.
 *
 * @return the request in seconds, or 0 for an index the driver cannot be asked for (its entry
 *         truncates to zero, where a request of 0 would select the bottom of the ladder).
 */
static inline unsigned int watchdog_driver_request_seconds(unsigned int top_index)
{
    return watchdog_period_seconds(top_index, DWWDT_DT_CLOCK_HZ);
}

/**
 * @brief Find the process holding /dev/watchdog open.
 *
 * The watchdog core admits a single opener, so once a feeder has the device no other process can
 * arm it through the driver. Both units run one, so this is the usual case rather than the
 * exception. Walks /proc/<pid>/fd looking for a link back to either spelling of the node.
 *
 * @return the holder's pid, or 0 when nothing holds it.
 */
static inline pid_t find_watchdog_holder(void)
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

            /* Both spellings reach the same device: the open rootfs feeder opens /dev/watchdog,
             * the vendor's libhal_wdt opens /dev/watchdog0, and this helper runs on either slot.
             */
            if (strcmp(link_target, "/dev/watchdog") == 0
                || strcmp(link_target, "/dev/watchdog0") == 0) {
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
 * @brief Whether @p pid is in state T, from field 3 of /proc/<pid>/stat.
 *
 * Worth confirming before the timeout is shortened: the feeder pings every few seconds and each
 * ping reloads the counter with whatever TORR holds, so a feeder that survived the signal would
 * reload before a short period ends and no reset would arrive.
 */
static inline int is_process_stopped(pid_t pid)
{
    char stat_path[64];
    snprintf(stat_path, sizeof stat_path, "/proc/%d/stat", (int)pid);

    FILE *stat_file = fopen(stat_path, "r");
    if (!stat_file) {
        return 0;
    }

    char stat_line[512];
    char *line = fgets(stat_line, sizeof stat_line, stat_file);
    fclose(stat_file);

    if (!line) {
        return 0;
    }

    /* The comm field is parenthesised and may itself contain spaces, so the state character is the
     * first non-space after the last ')'.
     */
    char *after_comm = strrchr(stat_line, ')');
    if (!after_comm) {
        return 0;
    }

    after_comm++;
    while (*after_comm == ' ') {
        after_comm++;
    }

    return *after_comm == 'T';
}

/**
 * @brief Wait up to a second for @p pid to show as stopped.
 *
 * SIGSTOP is delivered asynchronously: the target has to be scheduled before it transitions, so a
 * single read straight after the kill still sees it running. Measured on the air unit, where that
 * read reported the feeder alive and the board then reset on its own once the signal landed.
 *
 * @return 1 once the process reads as stopped, 0 if it never did.
 */
static inline int wait_for_process_stopped(pid_t pid)
{
    const struct timespec poll_interval = { 0, 10000000L };

    for (int attempt = 0; attempt < 100; attempt++) {
        if (is_process_stopped(pid)) {
            return 1;
        }

        nanosleep(&poll_interval, NULL);
    }

    return 0;
}

/** @brief Arm the counter at @p top_index by register write, reloading it so the period applies. */
static inline void arm_by_register(volatile uint32_t *watchdog_registers, unsigned int top_index)
{
    watchdog_registers[DWWDT_TORR / 4] = top_index | (top_index << 4);
    watchdog_registers[DWWDT_CR / 4]   = DWWDT_CR_ENABLE_RESET;
    watchdog_registers[DWWDT_CRR / 4]  = DWWDT_CRR_KICK;
}

/**
 * @brief The ladder index currently programmed, read back from TORR.
 *
 * @param watchdog_registers must be mapped. There is no out-of-band value to report a failed
 *        mapping with: every index the register can hold is a real one, so a sentinel would
 *        collide with an armed state rather than stand apart from it.
 */
static inline unsigned int watchdog_armed_top_index(volatile uint32_t *watchdog_registers)
{
    return watchdog_registers[DWWDT_TORR / 4] & DWWDT_TORR_TOP_MASK;
}

/**
 * @brief Print what the watchdog is doing right now and arm nothing.
 *
 * Reads the registers, measures the tick rate, and reports the watchdog core's own view from
 * sysfs. Safe on a live board: it writes no register and holds no fd.
 */
static inline wdt_exit report_watchdog_status(const char *tag)
{
    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        perror("open /dev/mem");
        return WDT_EXIT_NO_RESET;
    }

    volatile uint32_t *watchdog_registers = map_page(mem_fd, DWWDT_BASE);
    if (watchdog_registers == MAP_FAILED) {
        perror("mmap dw-wdt");
        return WDT_EXIT_NO_RESET;
    }

    unsigned int tick_rate_hz = watchdog_measure_tick_rate_hz(watchdog_registers);

    printf("%s: CR=0x%08x TORR=0x%08x CCVR=%u\n", tag,
           watchdog_registers[DWWDT_CR / 4],
           watchdog_registers[DWWDT_TORR / 4],
           watchdog_registers[DWWDT_CCVR / 4]);
    printf("%s: armed TOP index %u, enabled=%u\n", tag,
           watchdog_armed_top_index(watchdog_registers),
           watchdog_registers[DWWDT_CR / 4] & DWWDT_CR_ENABLE_RESET);

    if (tick_rate_hz == 0) {
        printf("%s: tick rate not measurable (the counter reloaded inside the sample window)\n",
               tag);
    } else {
        printf("%s: tick rate %u Hz measured; DT declares %u Hz\n", tag,
               tick_rate_hz, DWWDT_DT_CLOCK_HZ);

        for (unsigned int top_index = DWWDT_TOP_INDEX_MIN; top_index <= DWWDT_TOP_INDEX_MAX;
             top_index++) {
            printf("%s:   TOP %2u = %u s measured, %u s as the driver computes it\n", tag,
                   top_index,
                   watchdog_period_seconds(top_index, tick_rate_hz),
                   watchdog_driver_request_seconds(top_index));
        }
    }

    /* The watchdog core's own view, which is what the health sweeps read. */
    static const char *const sysfs_attributes[] = { "timeout", "timeleft", "state", "bootstatus" };
    for (size_t i = 0; i < sizeof sysfs_attributes / sizeof sysfs_attributes[0]; i++) {
        char attribute_path[128];
        snprintf(attribute_path, sizeof attribute_path, "/sys/class/watchdog/watchdog0/%s",
                 sysfs_attributes[i]);

        FILE *attribute_file = fopen(attribute_path, "r");
        if (!attribute_file) {
            continue;
        }

        char value[64] = "";
        if (fgets(value, sizeof value, attribute_file)) {
            value[strcspn(value, "\n")] = '\0';
            printf("%s: sysfs %s=%s\n", tag, sysfs_attributes[i], value);
        }

        fclose(attribute_file);
    }

    pid_t holder_pid = find_watchdog_holder();
    printf("%s: /dev/watchdog holder pid %d\n", tag, (int)holder_pid);

    return WDT_EXIT_RESET_COMING;
}

/**
 * @brief Wait out the armed period, and describe the silence if the board is still here.
 *
 * Reached only once something is armed and unfed, so a reset is due. Returning at all means it did
 * not come.
 *
 * @param is_feeder_stopped whether a feeder was stopped on the way in.
 * @return the exit status the caller should return.
 */
static inline wdt_exit wait_for_reset(const char *tag, unsigned int armed_top_index,
                                      unsigned int tick_rate_hz, int is_feeder_stopped)
{
    unsigned int period_seconds = watchdog_period_seconds(armed_top_index, tick_rate_hz);

    /* Twice the period covers the gap between what the counter predicts and when the reset has
     * actually landed. The fallback covers an unmeasurable tick rate, where the armed period is
     * not known at all and only the longest plausible one is safe to wait.
     */
    unsigned int wait_seconds = period_seconds ? period_seconds * 2 + 10 : 90;

    printf("%s: armed TOP index %u, reset expected within %u s...\n", tag, armed_top_index,
           wait_seconds);
    fflush(stdout);
    sleep(wait_seconds);

    if (is_feeder_stopped) {
        fprintf(stderr, "%s: armed at TOP %u with the feeder stopped and no reset came;\n"
                        "%s: the watchdog is not resetting this SoC\n",
                tag, armed_top_index, tag);
    } else {
        fprintf(stderr, "%s: armed at TOP %u and no reset came (watchdog inoperative?)\n",
                tag, armed_top_index);
    }

    return WDT_EXIT_NO_RESET;
}

/**
 * @brief Fire the watchdog and hard-reset the SoC.
 *
 * Three ways in, tried in order:
 *   1. A feeder holds /dev/watchdog, which is the usual case on both units: SIGSTOP it so nothing
 *      reloads the counter behind us, then shorten the period by register write. Its fd stays open
 *      and unclosed, so nothing can disarm the counter.
 *   2. Nothing holds the device: ask the driver for the shorter timeout, then close without 'V'.
 *      The DTS gives the watchdog no reset control, so dw_wdt_stop() cannot disarm the counter; the
 *      core logs "watchdog did not stop!", pings once, and leaves the device active.
 *   3. The counter is not armed at all: arm it at the index this hardware is known to boot through.
 *
 * @param tag prefixes the progress lines (the caller's program name).
 * @param top_index the ladder index to arm.
 * @return WDT_EXIT_RESET_COMING when a reset is on its way, WDT_EXIT_NO_RESET when none is; on the
 *         ordinary success it never returns, because the SoC resets underneath it.
 */
static inline wdt_exit fire_watchdog(const char *tag, unsigned int top_index)
{
    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    volatile uint32_t *watchdog_registers = MAP_FAILED;
    if (mem_fd >= 0) {
        watchdog_registers = map_page(mem_fd, DWWDT_BASE);
    }

    unsigned int is_armed = 0;
    unsigned int tick_rate_hz = 0;
    if (watchdog_registers != MAP_FAILED) {
        is_armed = watchdog_registers[DWWDT_CR / 4] & DWWDT_CR_ENABLE_RESET;
        tick_rate_hz = watchdog_measure_tick_rate_hz(watchdog_registers);
        printf("%s: enabled=%u, TOP index %u, tick rate %u Hz\n", tag, is_armed,
               watchdog_armed_top_index(watchdog_registers), tick_rate_hz);
        fflush(stdout);
    }

    /* The barrier. Everything below arms the counter or runs inside the shortened period, and none
     * of it writes to disk, so this is the last point at which a flush can complete.
     */
    sync();

    pid_t holder_pid = find_watchdog_holder();
    if (holder_pid > 0) {
        if (watchdog_registers == MAP_FAILED) {
            fprintf(stderr, "%s: pid %d holds /dev/watchdog and /dev/mem is unavailable, so the\n"
                            "%s: timeout cannot be shortened; nothing armed\n", tag, (int)holder_pid, tag);

            return WDT_EXIT_NO_RESET;
        }

        kill(holder_pid, SIGSTOP);

        /* Arm either way. A stopped feeder gives the shortened period; a feeder that somehow
         * survived the signal just keeps reloading the counter, which costs the reset but breaks
         * nothing, and wait_for_reset() then reports the silence. Returning here instead would be
         * the one genuinely misleading outcome: the signal is already sent, so the board may be
         * counting down unfed while the caller is told nothing was armed.
         */
        int is_feeder_stopped = wait_for_process_stopped(holder_pid);
        if (is_feeder_stopped) {
            printf("%s: pid %d holds /dev/watchdog and is stopped; arming TOP %u\n", tag,
                   (int)holder_pid, top_index);
        } else {
            printf("%s: pid %d holds /dev/watchdog and has not stopped; arming TOP %u anyway, but\n"
                   "%s: a feeder still pinging will reload the counter and hold the reset off\n",
                   tag, (int)holder_pid, top_index, tag);
        }
        fflush(stdout);
        arm_by_register(watchdog_registers, top_index);

        unsigned int armed_top_index = watchdog_armed_top_index(watchdog_registers);
        if (armed_top_index != top_index && is_feeder_stopped) {
            /* The write did not take, but the feeder is stopped, so the reset is still due at
             * whatever period was already programmed: say so now rather than sleeping out a
             * baseline the caller is already waiting through.
             */
            fprintf(stderr, "%s: TORR reads TOP %u, not the requested %u. Nothing is feeding the\n"
                            "%s: counter, so a reset is still due within %u s\n",
                    tag, armed_top_index, top_index, tag,
                    watchdog_period_seconds(armed_top_index, tick_rate_hz));

            return WDT_EXIT_RESET_COMING;
        }

        return wait_for_reset(tag, armed_top_index, tick_rate_hz, is_feeder_stopped);
    }

    int watchdog_fd = open("/dev/watchdog", O_WRONLY);
    if (watchdog_fd >= 0) {
        unsigned int request_seconds = watchdog_driver_request_seconds(top_index);

        if (request_seconds == 0 && watchdog_registers != MAP_FAILED) {
            /* The driver cannot be asked for this index: its ladder entry truncates to zero
             * seconds, and a zero request would select the bottom of the ladder.
             */
            printf("%s: TOP %u is below the driver's one-second resolution; arming by register\n",
                   tag, top_index);
            arm_by_register(watchdog_registers, top_index);
        } else {
            int timeout_seconds = (int)request_seconds;
            ioctl(watchdog_fd, WDIOC_SETTIMEOUT, &timeout_seconds);
            ioctl(watchdog_fd, WDIOC_GETTIMEOUT, &timeout_seconds);
            printf("%s: asked the driver for %u s, it reports %d s\n", tag, request_seconds,
                   timeout_seconds);

            /* A TORR write does not reload a running counter, so the shortened period only starts
             * here, at the ping.
             */
            ioctl(watchdog_fd, WDIOC_KEEPALIVE, 0);
        }

        printf("%s: closing /dev/watchdog without 'V' so it stays armed\n", tag);
        fflush(stdout);
        close(watchdog_fd);

        /* The driver picks the first ladder entry at or above the request, which can be a
         * neighbour of the wanted index. Any entry the tool can ask for resets the board, so this
         * is worth saying and not worth refusing over: wait at whatever landed. Without the
         * registers there is nothing to read it back from, so the request stands as the estimate.
         */
        unsigned int armed_top_index = top_index;
        if (watchdog_registers != MAP_FAILED) {
            armed_top_index = watchdog_armed_top_index(watchdog_registers);

            if (armed_top_index != top_index) {
                printf("%s: the driver armed TOP %u rather than %u; waiting at that period\n", tag,
                       armed_top_index, top_index);
            }
        }

        return wait_for_reset(tag, armed_top_index, tick_rate_hz, 0);
    }

    if (!is_armed && watchdog_registers != MAP_FAILED) {
        printf("%s: watchdog was disarmed; arming at the known-bootable TOP 0x%02x\n", tag,
               DWWDT_TOP_INDEX_KNOWN_BOOTABLE);
        fflush(stdout);
        arm_by_register(watchdog_registers, DWWDT_TOP_INDEX_KNOWN_BOOTABLE);

        return wait_for_reset(tag, watchdog_armed_top_index(watchdog_registers), tick_rate_hz, 0);
    }

    fprintf(stderr, "%s: no way in: /dev/watchdog is unavailable and /dev/mem could not be mapped\n",
            tag);

    return WDT_EXIT_NO_RESET;
}

/** @brief Print the option summary both helpers share. */
static inline void wdt_print_usage(const char *tag)
{
    fprintf(stderr,
            "usage: %s [--top <%u..%u>] [--status]\n"
            "  --top     ladder index to arm (default %u; index, not seconds)\n"
            "  --status  report the watchdog and exit, arming nothing\n",
            tag, DWWDT_TOP_INDEX_MIN, DWWDT_TOP_INDEX_MAX, DWWDT_TOP_INDEX_RESET);
}

/**
 * @brief Parse the shared options.
 *
 * The index is floored at DWWDT_TOP_INDEX_MIN so the value that left the SoC dark cannot be
 * reached from a command line, and capped so a typo cannot arm a period longer than the baseline.
 *
 * @return whether @p options was filled in. This answers a different question from wdt_exit, so it
 *         deliberately does not share that type: there, zero means a reset is coming.
 */
static inline int has_valid_wdt_options(int argc, char **argv, const char *tag,
                                        struct wdt_options *options)
{
    options->top_index = DWWDT_TOP_INDEX_RESET;
    options->is_status_only = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--status") == 0) {
            options->is_status_only = 1;
            continue;
        }

        if (strcmp(argv[i], "--top") == 0 && i + 1 < argc) {
            char *end = NULL;
            long requested = strtol(argv[++i], &end, 0);

            if (!end || *end != '\0' || requested < DWWDT_TOP_INDEX_MIN
                || requested > DWWDT_TOP_INDEX_MAX) {
                fprintf(stderr, "%s: --top must be an index between %u and %u\n", tag,
                        DWWDT_TOP_INDEX_MIN, DWWDT_TOP_INDEX_MAX);

                return 0;
            }

            options->top_index = (unsigned int)requested;
            continue;
        }

        wdt_print_usage(tag);

        return 0;
    }

    return 1;
}

#endif /* ML_WDT_H */
