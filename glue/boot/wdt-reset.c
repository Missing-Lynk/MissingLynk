/**
 * @file wdt-reset.c
 * @brief Hard-reset the open Artosyn unit so the SPL boots the ACTIVE slot.
 *
 * Unlike uboot-trigger.c, this does NOT set the reboot-reason flag, so the SPL Falcon-boots
 * whichever slot gpt0 marks active (use this after `mtdtool setslot` to land on the freshly
 * selected slot). The reset itself is the shared fire_watchdog() from wdt.h.
 *
 * Static and self-contained so it runs on either slot: the stock vendor rootfs, which has its own
 * ar_wdt_service, and the open rootfs, which has neither that nor devmem. On the ordinary success
 * it does not return, because the SoC resets underneath it.
 *
 * `--status` reports the watchdog and arms nothing, which is safe on a live board: it settles what
 * rate the counter really ticks at, and prints the same sysfs attributes the health sweeps read.
 */
#include "wdt.h"

int main(int argc, char **argv)
{
    struct wdt_options options;
    if (!has_valid_wdt_options(argc, argv, "wdt-reset", &options)) {
        return WDT_EXIT_USAGE;
    }

    if (options.is_status_only) {
        return report_watchdog_status("wdt-reset");
    }

    sync();

    return fire_watchdog("wdt-reset", options.top_index);
}
