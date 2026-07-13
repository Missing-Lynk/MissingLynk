# Cloning a boot slot

How to make one boot slot (the target) hold the same image as another (the source), component by component. This is a reusable operation: seeding a known-good slot A from a vendor-flashed slot B (see [glue/docs/first-setup-known-good-slot.md](first-setup-known-good-slot.md)), duplicating a proven slot, or repairing a slot whose image got damaged.

This applies to any device with two boot slots. The commands shown are the concrete instance for the BetaFPV VR04 / Artosyn Proxima-9311; map the partition numbers and tool names to your own hardware.

## The one rule that prevents corruption

**Clone component by component with filesystem-aware and MTD-aware tools. Never do a blind whole-device or whole-partition byte copy.** On raw NAND the bad-block layout differs between partitions, and a filesystem like UBI keeps internal metadata tied to the volume it lives in, so a raw `dd` of a UBI volume (or of any partition that has bad blocks) onto a different partition produces a corrupt result that may appear to write fine and then fail to mount or boot. Copy each component with the tool that understands its format.

## Before you start

- **Know your direction.** Decide clearly which slot is the source (trusted, read-only here) and which is the target (overwritten). Getting them backwards overwrites the wrong slot. Re-confirm the partition numbers on the live device (example, VR04: `cat /proc/mtd`) and write the source-to-target mapping down before touching anything.
- **Mind the target.** If the target is your keystone slot A, this is the **one sanctioned exception** to "never write slot A" (see the rules in [glue/docs/flash-and-verify-slots.md](flash-and-verify-slots.md)). Treat it as the most careful flash in the device's life and have your lowest-level recovery ready first (example, VR04: `glue/recovery/RECOVERY.md`). If the target is slot B, it is a normal B write.
- **Do not clone the active-slot pointer.** The pointer (a GPT attribute bit, boot flag, or eMMC boot-partition selector, depending on the device) is the slot *selector*, not slot *content*. It is per-device, not per-slot data; you set it separately when you actually want to switch slots, not as part of a clone.

## What to clone

A slot's image is the set of boot components it owns. Generically: bootloader, kernel, dtb (if separate), env, and rootfs. Clone all of them so the target is a complete, bootable copy.

Example, VR04 source-to-target mapping (cloning B to A; reverse the columns to clone A to B; the authoritative full MTD map is in [docs/reference/open-firmware-bsp.md](../../docs/reference/open-firmware-bsp.md)). **Re-verify against `cat /proc/mtd`.**

| Component | Slot A partition | Slot B partition |
|---|---|---|
| bootloader | `uboot0` = mtd11 | `uboot1` = mtd12 |
| kernel | `kernel0` = mtd13 | `kernel1` = mtd14 |
| dtb | `dtb0` = mtd15 | `dtb1` = mtd16 |
| env | `env0` = mtd9 | `env1` = mtd10 |
| rootfs | `userapp0` = mtd17 | `userapp1` = mtd18 |

## Cloning the raw partitions (bootloader, kernel, dtb, env)

These are flat partitions: read the source out to a file, then write the file to the target with the MTD-aware writer, then verify by readback.

Example, VR04 (kernel, B to A; repeat for dtb, bootloader, env):

    dd if=/dev/mtd14 of=/tmp/kernel.bin                 # read source (kernel1)
    mtdtool write /dev/mtd13 /tmp/kernel.bin            # write target (kernel0): erases then programs
    # verify: sha256 of /dev/mtd13 (trimmed to the image length) must equal sha256 of /tmp/kernel.bin

Bad-block caveat: reading an MTD character device with `dd` returns ECC-corrected data and works for partitions with no bad blocks. If a partition has bad blocks, use the bad-block-aware tools (`nanddump` to read, `nandwrite` to write) instead, so the bad-block markers are honored. The MTD-aware writer aborts rather than silently corrupting if it hits a bad block in the target.

## Cloning the rootfs (filesystem image, not a block copy)

The rootfs is a filesystem on top of the partition (on the VR04, a UBI volume), so copy it with the filesystem's own tools. The simplest and safest route is to flash the target's rootfs from the same rootfs image the source was built from, if you have it, exactly the rootfs-flash in [glue/docs/flash-and-verify-slots.md](flash-and-verify-slots.md), just aimed at the target slot.

If you must clone live from the source slot, read the source volume out to an image with the UBI tools, then write it onto the target volume. Example, VR04 (read `userapp1` = mtd18, write `userapp0` = mtd17): attach the source UBI device, read its volume to an image, detach; then attach the target, `ubiupdatevol` the image onto the target volume, detach. Do not `dd` the UBI volume across partitions.

## Verify the clone before you rely on it

A readback hash per component proves the bytes landed. The end-to-end proof is to boot the cloned slot.

- **Per component:** readback the target partition and compare its hash to the source file you wrote.
- **End to end:** RAM-boot the target slot's kernel + dtb with the rootfs coming from the target's rootfs partition, and confirm it reaches userspace.

> Example, VR04: drop to the bootloader (`glue/boot/drop-to-uboot.sh`), `loady` the target's kernel and dtb readbacks, and `bootm` with the cmdline pointing root at the target's rootfs. Nothing is committed by a RAM-boot, so this is safe to do before any slot flip.

Only after the clone boots from RAM should you set the active slot to it (if that was the goal). Setting the active slot is a separate step, not part of the clone, see [glue/docs/flash-and-verify-slots.md](flash-and-verify-slots.md).
