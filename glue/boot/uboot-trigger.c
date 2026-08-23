/**
 * @file uboot-trigger.c
 * @brief Drop the Artosyn unit to full U-Boot, from either slot.
 *
 * The SPL Falcon-boots the active slot UNLESS the sticky reboot-reason flag (0x0A106138 bit0) is
 * set, in which case it runs full U-Boot. That flag survives a WATCHDOG reset but not a plain
 * reboot()/kernel restart, which clears it, so this sets the flag through /dev/mem and then fires
 * the shared watchdog reset (wdt.h) that preserves it.
 *
 * Static and self-contained so it runs on either slot: the stock vendor rootfs, which has its own
 * ar_wdt_service, and the open rootfs, which has neither that nor devmem. On the ordinary success
 * it does not return, because the SoC resets underneath it.
 */
#include "wdt.h"

/* Sticky reboot-reason flag: bit0 at REBOOT_REASON_BASE+OFF tells the SPL to run full U-Boot. */
#define REBOOT_REASON_BASE  0x0A106000u
#define REBOOT_REASON_OFF   0x138u
#define REBOOT_REASON_UBOOT 0x1u       /* bit0 = "SPL -> U-Boot" */

int main(int argc, char **argv)
{
    struct wdt_options options;
    if (!has_valid_wdt_options(argc, argv, "uboot-trigger", &options)) {
        return WDT_EXIT_USAGE;
    }

    if (options.is_status_only) {
        fprintf(stderr, "uboot-trigger: --status belongs to wdt-reset; this tool only resets\n");

        return WDT_EXIT_USAGE;
    }

    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        perror("open /dev/mem");

        return WDT_EXIT_NO_RESET;
    }

    /* Set the reboot-reason flag (single 32-bit store, aligned) so the SPL runs full U-Boot. */
    volatile uint32_t *reboot_reason = map_page(mem_fd, REBOOT_REASON_BASE);
    if (reboot_reason == MAP_FAILED) {
        perror("mmap reboot-reason");

        return WDT_EXIT_NO_RESET;
    }

    reboot_reason[REBOOT_REASON_OFF / 4] |= REBOOT_REASON_UBOOT;
    msync((void *)reboot_reason, MAP_SIZE, MS_SYNC);
    printf("uboot-trigger: 0x0A106138 = 0x%08x\n", reboot_reason[REBOOT_REASON_OFF / 4]);
    fflush(stdout);
    sync();

    /* The watchdog reset preserves the flag; reboot() would clear it. */
    return fire_watchdog("uboot-trigger", options.top_index);
}
