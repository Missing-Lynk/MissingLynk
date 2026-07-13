# First setup: establishing a known-good slot A

This is the one-time procedure behind [glue/docs/flash-and-verify-slots.md](flash-and-verify-slots.md). The goal is to put a trusted vendor image onto one boot slot (call it A), prove it boots, make it active, and then freeze it. From then on A is never written again except for recovery, and all experiments happen on slot B where they can always fall back to A.

This applies to any device with two boot slots. The commands shown are the concrete instance for the BetaFPV VR04 / Artosyn Proxima-9311; map the partition numbers, tool names, vendor updater, and credentials to your own hardware.

**This is the only time writing slot A is sanctioned**, and the one write that, if wrong, leaves no clean fallback. Have your lowest-level recovery path ready before you start (for the VR04, the BootROM UART writer in `glue/recovery/RECOVERY.md`).

## Why a frozen known-good slot

A two-slot device is recoverable because one slot is always trustworthy. If both slots drift from known-good, a bad flash can leave nothing to fall back to, and you are into low-level recovery (serial, JTAG, or a BootROM writer). Pinning slot A to a clean vendor image once and never touching it again makes every later mistake on B a one-line revert instead of a recovery session.

## Step 1: flash a known-good vendor firmware

Use the vendor's official updater to flash a known-good stable release, by their documented procedure (USB updater, SD-card update, or configurator, whatever your device uses). Pick a version you know boots cleanly, not necessarily the newest.

Example, VR04: the known-good BetaFPV/Artosyn release is **`1.0.44.rel`**; flash it with the official update tool.

Then reboot and confirm it boots correctly and reports the expected version. Do not continue until the device is up and healthy on the freshly flashed image.

## Step 2: find which slot the vendor wrote

Vendor updaters on A/B devices typically write the **inactive** slot and then flip the active pointer to it. So after a successful update you are usually running the new image on whichever slot was previously inactive, which may or may not be the one you want as your keystone.

Determine the currently active slot. Example, VR04: `cat /proc/cmdline` and read the rootfs selector (`ubi.mtd=17` = slot A, `ubi.mtd=18` = slot B), or read the active-slot pointer directly.

Pick a convention for which slot is your permanent keystone. This guide uses A. Now compare:

- **The good image is already on A and A is active:** you are nearly done. Skip to step 4 (verify), then step 5 (freeze).
- **The good image is on B (the updater wrote and activated B), and A is older or unknown:** clone the good slot onto A in step 3 so A becomes the keystone.

## Step 3: clone the good slot onto A (only if needed)

If the good image is on B, clone it onto A so A becomes the keystone. This is the **one sanctioned write to slot A**, so treat it with maximum care and have your recovery path ready before you start.

The full component-by-component procedure (raw-partition readback and write, the filesystem-aware rootfs copy, the bad-block caveats, and per-component verification) is in [glue/docs/clone-a-slot.md](clone-a-slot.md). Clone with **B as the source and A as the target**, and verify every component by readback as you go. This is the slot you cannot afford to get wrong, so if any component does not match, stop and redo it.

## Step 4: RAM-boot the A image and confirm it works

Before you make A active, prove A's image boots, from RAM, so nothing is committed yet.

Boot A's kernel and dtb from RAM with the rootfs coming from A's rootfs partition, and confirm it reaches userspace and behaves correctly. Example, VR04: drop to the bootloader (`glue/boot/drop-to-uboot.sh`), `loady` A's kernel and dtb (the `kernel0`/`dtb0` readbacks), and `bootm` with the cmdline pointing root at A's rootfs (`ubi.mtd=17`). The device should come up on the vendor image exactly as in step 1.

If it does not boot from RAM, do not flip. Fix the clone (step 3) and re-verify.

## Step 5: flip to A and freeze it

Make A the active slot and cold-boot it. Example, VR04: `mtdtool setslot /dev/mtd5 a`, then a watchdog reset / power-cycle. Confirm A self-boots the vendor image to a healthy state.

Slot A is now your known-good keystone. **Freeze it.** From here on:

- Never write A's partitions again (see the two inviolable rules in [glue/docs/flash-and-verify-slots.md](flash-and-verify-slots.md)).
- Do all experiments on slot B, proving each change from RAM with A active before flipping, per that guide.
- If anything ever goes wrong, set the active slot back to A and reset.

## Recap

1. Flash a known-good vendor firmware with the official updater (VR04: `1.0.44.rel`); reboot; confirm it boots and reports the right version.
2. Find which slot it landed on and which is active.
3. If the good image is on B and A is not trustworthy, clone B onto A component by component, verifying every readback (the one sanctioned write to A).
4. RAM-boot A to confirm it works, with nothing committed.
5. Flip to A, confirm it self-boots, and freeze it. All future work happens on B.
