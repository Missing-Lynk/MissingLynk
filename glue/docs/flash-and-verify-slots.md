# Flashing and verifying an A/B slot safely (the untainted-A ladder)

This is a general method for putting a new component (rootfs, kernel, dtb, bootloader) onto a device that has two boot slots (call them A and B), without risking a brick. It applies to any such device. The commands shown are the concrete instance for the BetaFPV VR04 / Artosyn Proxima-9311; map the partition numbers, tool names, and credentials to your own hardware.

The rule the whole method exists to enforce: **one slot (A) stays a known-good image that you never touch, so the device is always recoverable**, and **nothing becomes the active boot slot until it has been proven to boot end to end from RAM first**. Recovering a bad image on the *active* slot needs a bootloader drop or a low-level recovery writer; recovering when A is intact and active is a one-line "set active slot to A" plus reset.

Prerequisite: you need a known-good slot A to begin with. Establishing one from the vendor image is a separate one-time procedure, see [glue/docs/first-setup-known-good-slot.md](first-setup-known-good-slot.md). This guide assumes that baseline already exists.

## The two inviolable rules

1. **Never write slot A's partitions.** A's bootloader, kernel, dtb, rootfs, and env stay byte-for-byte as they were. An intact slot A is the keystone: a low-level recovery path can always restore A-active, but only while A is untouched.
2. **Never make B the active slot until B's boot is proven end to end** (bootloader to kernel to userspace to reachable, for example over SSH or serial). Prove it by RAM-boot with **A still active**, which always falls back to the known-good A on any failure and commits nothing. Flip only after end-to-end proof.

Rule 1 means you can always recover; rule 2 means you rarely have to.

## What your device needs for this method

The ladder assumes four capabilities. Most A/B devices have all four in some form:

1. **Boot a kernel + dtb from RAM without flashing.** This is the verifier. The rootfs can come from flash (the slot you are testing) while only the kernel and dtb live in RAM. On the VR04 this is `glue/boot/ram-boot.sh`, which packs the `Image` into the vendor container, drops to U-Boot, `loady`s the dtb and container over the UART bridge, and `bootm`s.
2. **Flash an individual slot's partitions.** On the VR04: `native/mtdtool write <mtd> <image>` for the raw partitions (kernel, dtb, bootloader, env) and `ubiupdatevol` for the UBI rootfs.
3. **Set the active slot.** On the VR04: `mtdtool setslot /dev/mtd5 a|b` (flips one GPT attribute bit; touches only the `gpt0` partition).
4. **A recovery backstop** for when the device will not come up at all. On the VR04: the BootROM UART writer in `glue/recovery/RECOVERY.md`.

If your device is missing capability 1 (RAM-boot), you can still flash to B and verify by power-cycle, but you lose the no-commit safety, so be correspondingly more conservative.

## Slot and partition map

Each slot owns its own copy of every boot component. There is also one small region that records which slot is active (a GPT attribute bit, a boot flag, an eMMC boot-partition selector, depending on the device). That pointer is the only shared thing you ever write.

Example, VR04 (one SPI-NAND device split into 20 partitions; the whole device is `mtd0` with the partitions as `mtd1`..`mtd20`; the authoritative full MTD map is in [docs/reference/open-firmware-bsp.md](../../docs/reference/open-firmware-bsp.md)). **Always re-confirm the numbers on the live device with `cat /proc/mtd` before any write; do not trust this table blindly.**

| Component | Slot A (never write) | Slot B (write target) |
|---|---|---|
| kernel   | `kernel0` = mtd13 | `kernel1` = mtd14 |
| dtb      | `dtb0`    = mtd15 | `dtb1`    = mtd16 |
| rootfs   | `userapp0`= mtd17 | `userapp1`= mtd18 |
| bootloader | `uboot0` = mtd11 | `uboot1`  = mtd12 |
| env      | `env0`    = mtd9  | `env1`    = mtd10 |
| active-slot pointer | `gpt0` = mtd5 (the only shared partition ever written) | |

On the VR04 the SPL Falcon loader reads the pointer, loads `kernel<slot>` plus `dtb<slot>`, and rewrites the kernel cmdline `ubi.mtd=` to point root at `userapp<slot>` (mtd17 for A, mtd18 for B). Your device's loader will have its own equivalent selection logic.

A note on reboots: on many embedded devices a plain `reboot` is a no-op (no working software reset path). The reliable reset is often the watchdog. On the VR04, on the open Alpine use `glue/boot/wdt-reset`; on stock use `sync; ar_wdt_service -t 1 & sleep 1; killall ar_wdt_service`.

## Step 0: confirm A is the recoverable keystone

Before touching anything, establish that A is known-good and is the active fallback.

1. Confirm the active slot is A. Example, VR04: `cat /proc/cmdline` shows `ubi.mtd=17` (= `userapp0` = slot A).
2. Confirm A holds a trusted image (you have not modified A since establishing it, see the first-setup guide). If unsure, fix that first; A must be trustworthy.
3. **Prove the fallback**: with A active, power-cycle. It must come back to A on its own. This is the safety net every later step relies on, so verify it now.

From here on, A is the thing you never touch and always return to.

## Step 1: flash the slot-B rootfs, verify it from RAM

Goal: prove a new rootfs boots, using a known-good kernel and dtb from RAM, before committing any kernel change.

1. Make sure slot B is idle (you are not running from it). Stage the rootfs image on the device.
2. Flash **only** B's rootfs partition. Re-check `/proc/mtd` first; A's rootfs is never an argument. Example, VR04 (rootfs is a UBI volume on `userapp1` = mtd18):

       ubiattach -m 18 -d 1 /dev/ubi_ctrl
       ubiupdatevol /dev/ubi1_0 /tmp/<rootfs>.img
       ubidetach -d 1 /dev/ubi_ctrl

   (or `glue/flash/flash-rootfs-b.sh`, which wraps this with guards). The active slot is still A.
3. **Verify from RAM**: boot a trusted kernel + dtb from RAM against the newly flashed slot-B rootfs, and confirm it reaches userspace and is reachable. Example, VR04: `glue/boot/ram-boot.sh <known-good Image> <known-good dtb>` (it mounts root from the slot-B rootfs). If it fails, the rootfs is the problem; reset (falls back to A) and fix it. Nothing was flipped.

## Step 2: flash the slot-B kernel and dtb, verify the flashed copies from RAM

Goal: prove the new kernel and dtb boot, and prove the flashed bytes are good, before flipping.

1. **RAM-boot the candidate first**, before flashing. Example, VR04: `glue/boot/ram-boot.sh <new Image> <new dtb>`. This proves the new kernel, dtb, and slot-B rootfs boot end to end with nothing written to flash. Do not proceed past a failure here.
2. Flash kernel and dtb to **slot B only**. Re-check `/proc/mtd`; A's kernel and dtb are never arguments. Example, VR04 (kernel must be packed into the bootable container first):

       glue/flash/mkkernel.py pack <new Image> kernel1.img --otra-template <a kernelN readback>
       mtdtool write /dev/mtd14 kernel1.img       # kernel1, erases then programs
       mtdtool write /dev/mtd16 <new dtb>          # dtb1

3. **Verify the flash write**; do not assume it took. Read the partitions back and compare to what you wrote (a sha256 of the readback, trimmed to the image length, against the artifact). Because the image was already RAM-proven in step 2.1 and the readback matches, the flashed copy is proven good. The gold-standard alternative is to RAM-boot the exact readback bytes (`loady` the kernel and dtb partition readbacks and `bootm` them); on the VR04 `ram-boot.sh` currently packs a raw `Image`, so today that flashed-copy check is the readback-hash compare above.

The active slot is **still A** throughout step 2. A power-cycle still returns to the known-good A.

## Step 3: flip to B (only after every check above is green)

Now, and only now, make B the boot slot. Example, VR04:

    mtdtool setslot /dev/mtd5 b        # flips the active-slot pointer to B

Power-cycle (a real cold boot) and confirm B comes up autonomously: bootloader to kernel to userspace to reachable. This is the same end-to-end state you already proved from RAM, now from flash and self-booting.

## Recovery and revert

- **A is active, B is bad** (steps 0 to 2, the normal case): just reset. The loader boots the still-active A. Nothing to undo.
- **You flipped to B and B is bad** (step 3 went wrong): get to the bootloader and set the slot back to A. Example, VR04: `glue/boot/drop-to-uboot.sh` drops to U-Boot, or run `mtdtool setslot /dev/mtd5 a` from any shell you can still reach, then reset.
- **The device will not come up at all**: use the lowest-level recovery your device has. Example, VR04: the serial console can set the slot (docs/guides/serial-and-debug-access.md), and the ultimate backstop is the BootROM UART flash-writer in `glue/recovery/RECOVERY.md`, which restores A-active. This only works because slot A was never written, which is the entire point of rules 1 and 2.

## The non-negotiables (recap)

- Slot A's partitions are **never** a write target. Re-check the number or name against the live device every time; if it does not match what you expect, stop and do not guess.
- The only writes in normal flashing are B's rootfs, kernel, dtb, and the active-slot pointer.
- RAM-boot proves it with A active and commits nothing. Flip only after end-to-end proof. When in doubt, do not flip.
