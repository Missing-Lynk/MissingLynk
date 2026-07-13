/* uboot-trigger - drop the Artosyn goggle to full U-Boot (from either slot).
 *
 * The SPL Falcon-boots the active slot UNLESS the sticky reboot-reason flag
 * (0x0A106138 bit0) is set, in which case it runs full U-Boot. That flag survives a
 * WATCHDOG reset but NOT a plain reboot()/kernel restart (which clears it), so this
 * sets the flag via /dev/mem and then fires the shared watchdog reset (wdt.h) that
 * preserves it -> the SPL runs full U-Boot instead of Falcon-booting the slot.
 *
 * Static + self-contained so it runs on EITHER slot: the stock vendor rootfs (A) and the
 * open Alpine rootfs (B), which has no `devmem` and no ar_wdt_service. It does not
 * return on success (the watchdog resets the SoC).
 */
#include "wdt.h"

/* Sticky reboot-reason flag: bit0 at REBOOT_REASON_BASE+OFF tells the SPL to run full U-Boot. */
#define REBOOT_REASON_BASE  0x0A106000u
#define REBOOT_REASON_OFF   0x138u
#define REBOOT_REASON_UBOOT 0x1u       /* bit0 = "SPL -> U-Boot" */

int main(void) {
    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
      perror("open /dev/mem");
      return 1;
    }

    /* set the reboot-reason flag (single 32-bit store, aligned) so the SPL runs full U-Boot */
    volatile uint32_t *reboot_reason = map_page(mem_fd, REBOOT_REASON_BASE);
    if (reboot_reason == MAP_FAILED) {
      perror("mmap reboot-reason");
      return 1;
    }

    reboot_reason[REBOOT_REASON_OFF / 4] |= REBOOT_REASON_UBOOT;
    msync((void *)reboot_reason, MAP_SIZE, MS_SYNC);
    printf("uboot-trigger: 0x0A106138 = 0x%08x\n", reboot_reason[REBOOT_REASON_OFF / 4]);
    fflush(stdout);
    sync();

    /* watchdog reset preserves the flag; reboot() would clear it */
    return fire_watchdog("uboot-trigger");
}
