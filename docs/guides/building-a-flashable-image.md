# Building a flashable slot image (.mlimg)

An `.mlimg` is one flashable bundle of a boot slot: everything a vendor slot carries except the SPL. It is a plain, inspectable tar built by `glue/flash/mlimg.py` and consumed on-device by `mlflash` ([`native/mlflash/README.md`](../../native/mlflash/README.md)). This guide covers building the bundle; flashing it is [below](#flashing-it-onto-a-slot).

## Quick build

From the repo root:

```
make image
```

This builds every component, captures the vendor slot blobs (once, device connected), then assembles and self-verifies the bundle at `mlimg-<device>-<version>.tar`.

## What the bundle contains

Five components plus a manifest:

- `uboot.bin`, `env.bin` — stock vendor bytes from your own dump (role `vendor`).
- `kernel.otra` — our kernel `Image`, already packed into the OTRA+uImage+LZ4 container (role `open`).
- `dtb.dtb` — our raw dtb (role `open`).
- `rootfs.ubi` — the open Alpine rootfs UBI image (role `open`).

Deliberately excluded (not slot-relative, so not part of any slot image): `usr_data` / `usr_log` (the shared, persistent `/usrdata` store that must survive a reflash), and `vendor`, `factory`, `spl*`, `gpt*`.

## Vendor blobs (`firmware/bin/`)

The build needs stock `uboot` + `env` + an OTRA template (a stock `kernel` partition dump) from your own device. Capture them once:

```
missinglynk dump-partitions --dest firmware/bin
```

That writes each small partition to `firmware/bin/P1_GND/<mtdN>-<name>.bin` (no `--full`: the ~45 MB `userapp` volumes are not part of an image). `mlimg build` searches `firmware/bin/` recursively, so nothing is copied or renamed. `firmware/bin/` is git-ignored (proprietary vendor bytes) and is a transient capture directory.

Blob resolution prefers the slot-A (`*0`) dumps. Slot A is never written, so its bytes are always stock and the built image is reproducible regardless of what is on slot B (whose `*1` kernel may be one of our own builds). `make image` skips the dump when blobs are already present, so a rebuild after the first capture needs no device.

## Manual equivalent of `make image`

```
make kernel
make rootfs
missinglynk dump-partitions --dest firmware/bin
python glue/flash/mlimg.py build
```

Override any input explicitly: `--build-dir`, `--image`, `--dtb`, `--rootfs`, `--blobs-dir`, `--uboot`, `--env`, `--otra-template`, `--device`, `--version`, `-o`.

## Verify

`mlimg build` verifies every component hash as it assembles. Re-check an existing bundle at any time:

```
python glue/flash/mlimg.py inspect mlimg-<device>-<version>.tar   # host
mlflash --inspect mlimg-<device>-<version>.tar                    # on-device (same digests)
```

## Output

`mlimg-<device>-<version>.tar` at the repo root, git-ignored (it embeds vendor bytes and is not redistributable). Given the same device dump and the same component builds, the bundle is content-reproducible; only the manifest's `build_time` varies.

## Flashing it onto a slot

The bundle is written on-device by `mlflash`, the standalone slot flasher. It runs on the goggle itself under either userspace, writes only the inactive slot, and re-verifies every component. Full command reference, the preflight checks, and the slot-safety guarantees are in [`native/mlflash/README.md`](../../native/mlflash/README.md); the safe order is:

1. Build `mlflash` (`native/build.sh`) and copy it plus the `.mlimg` onto the goggle.
2. `mlflash --dry-run <image.mlimg>` — the on-device preflight (running-vs-GPT slot agreement, board identity, component hashes). No writes.
3. `mlflash --flash <image.mlimg>` — writes the inactive slot and reads it back to verify. Does not flip the active slot.
4. `make flashboot` — prove the flashed slot boots (SPL aside) by booting its kernel/dtb/rootfs with the current slot still active.
5. `mlflash --flip` — only after the flashboot proves the slot boots, set it active. Making an unproven slot active is HARD RULE 2; slot A stays the untouched BootROM-recovery keystone until then.
