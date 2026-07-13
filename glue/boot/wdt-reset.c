/* wdt-reset - hard-reset the open Artosyn goggle so SPL boots the ACTIVE slot.
 *
 * Unlike uboot-trigger.c, this does NOT set the reboot-reason flag, so the SPL
 * Falcon-boots whichever slot gpt0 marks active (use this after `mtdtool setslot`
 * to land on the freshly selected slot). The watchdog reset itself is the shared
 * fire_watchdog() from wdt.h.
 *
 * Static + self-contained so it runs on EITHER slot: the stock vendor rootfs (A) and the
 * open Alpine rootfs (B), which has no `devmem` and no ar_wdt_service. It does not
 * return on success (the watchdog resets the SoC).
 */
#include "wdt.h"

int main(void) {
    sync();
    return fire_watchdog("wdt-reset");
}
