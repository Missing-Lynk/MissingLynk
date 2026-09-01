# Flashing the BetaFPV VR04 HD air unit

The air unit (`betafpv-vr04-air`, product `P1_SKY`) can be flashed with the same A/B-slot safety model as the goggle: slot A stays untouched, slot B receives the open firmware, and you prove it boots before making B the active slot.

Two paths are supported:

1. **Scripted first flash** — flash only the open kernel + rootfs to slot B, leaving the vendor's slot-B uboot/env intact. No air-unit vendor blobs need to be captured first.
2. **Full `.mlimg` bundle** — used by `ml-flasher`. Requires capturing the air unit's slot-A vendor blobs (uboot0/env0/kernel0) once.

## USB-gadget addresses

| State | Goggle | Air unit |
|-------|--------|----------|
| Stock / unflashed | `192.168.3.100` | `192.168.3.100` |
| Open slot B | `192.168.3.101` | `192.168.3.102` |

The host side is `192.168.3.222/24` on `br-artosyn`.

## Scripted first flash (recommended for the first try)

This path does **not** need the air's vendor uboot/env captured. It flashes only our kernel/dtb and rootfs to slot B and relies on the vendor uboot1/env1 that is already there.

```sh
make setup DEVICE=betafpv-vr04-air
make kernel
make flash-kernel     # writes kernel1/dtb1
make flash-rootfs     # writes userapp1
make flashboot        # RAM-boot the flashed slot-B kernel; A stays active
# If flashboot boots cleanly and the device is reachable:
glue/boot/flip-slot.sh b   # user-driven manual step
```

`make flashboot` is the proof step: it boots the flashed kernel1/dtb1/rootfs while slot A is still the active slot, so a bad build is recoverable by a simple power cycle.

## Full `.mlimg` bundle for `ml-flasher`

### 1. Capture the air unit's vendor blobs

Connect the air unit in its **stock slot A** and dump the partitions:

```sh
uv run missinglynk dump-partitions --dest firmware/bin
```

This writes `firmware/bin/P1_SKY/` with files like `mtd11-uboot0.bin`, `mtd9-env0.bin`, and `mtd13-kernel0.bin` (the OTRA template).

### 2. Build the image

```sh
make image DEVICE=betafpv-vr04-air
```

The build now scopes vendor blobs to `firmware/bin/P1_SKY/`. If only goggle blobs (`firmware/bin/P1_GND/`) are present, the build fails loudly instead of silently embedding goggle bytes.

### 3. Inspect the bundle

```sh
uv run python glue/flash/mlimg.py inspect mlimg-P1_SKY-*.tar
```

Confirm:

- `target_device: P1_SKY`
- `uboot_source` and `env_source` point under `firmware/bin/P1_SKY/`
- kernel container is `OTRA+uImage OK`
- rootfs fits the 45 MiB userapp slot

### 4. Flash with `ml-flasher`

```sh
./flasher/build/ml-flasher
```

The GUI now recognizes the air unit and will:

- connect at `192.168.3.100` (stock) or `192.168.3.102` (open slot B)
- check the slot state before offering the file picker, and refuse unless the unit is running slot A with the GPT agreeing and every slot-B partition resolving
- stage the image on a card if one is mounted, otherwise in `/tmp`, which it accepts only when the free space there covers the image plus a 20 MiB margin. The air unit stages in `/tmp`, and the bundle is stored compressed to fit: about 19 MB against the roughly 53 MiB free, where an uncompressed bundle was refused.
- flash slot B, then reboot to `192.168.3.102`

## Recovery

Slot A is never written by any of these steps. If the open slot B does not boot:

- Power-cycle the device to boot back into stock slot A.
- If even that fails, use BootROM UART recovery per `glue/recovery/RECOVERY.md`.

## What changed to enable this

- `glue/flash/mlimg.py` scopes vendor-blob search to `firmware/bin/<device>/`.
- `Makefile` passes `--blobs-dir firmware/bin/$(DEV_MLIMG_TARGET)` and only skips `image-blobs` when the current device's blobs exist.
- `flasher/internal/whitelist/whitelist.go` whitelists `P1_SKY`.
- `flasher/internal/flow/flow.go` no longer hardcodes goggle-only checks; it probes all known open-slot IPs and falls back to `/tmp` staging when no card is mounted.
- `glue/flash/mlimg.py` stores the rootfs component gzip-compressed and `native/mlflash` inflates it as it streams into `ubiformat`, which is what brings the bundle inside the air unit's `/tmp`.
