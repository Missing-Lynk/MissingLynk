# Adding a device

The build and bring-up are data-driven by a device name `<name>`. Adding a device means creating a few per-device files under that name; the toolchain (`make`, the kernel/rootfs builds, `ram-boot`, the flashers) reads them. No toolchain code changes are needed. `betafpv-vr04-goggle` and `betafpv-vr04-air` are the worked examples to copy from.

Select the active device once with `make setup DEVICE=<name>` (persisted to `.device`); every subsequent `make kernel` / `rootfs` / `image` / `flash-rootfs` / `ramboot` then targets it. A command-line `DEVICE=<name>` overrides for a one-off.

## The files

### 1. `devices/<name>/device.mk` (required) - the manifest

Single source of truth for identity, capabilities, and build pointers. The root `Makefile` does `include devices/$(DEVICE)/device.mk`; the Python CLI and Go flasher read the same file. Format is plain `KEY = VALUE`, no quotes (the tooling parser is a trivial split).

- **Identity:** `DEV_NAME` (= `<name>`), `DEV_VENDOR`, `DEV_MODEL`, `DEV_CLASS` (`goggle` | `vrx` | `air`).
- **On-device identity** (the flasher whitelist / `.mlimg` target triple, from the unit's `sdk_version.json` / `product/config.json`): `DEV_PRODUCT`, `DEV_HW_VERSION`, `DEV_FW_VERSION`, `DEV_BOARD_TYPE`, `DEV_RF_ROLE`.
- **Capabilities** - composable booleans (0/1); they gate the `ml-hud` `-D` defines and document the hardware. A unit can set any combination: `DEV_HAS_DISPLAY`, `DEV_HAS_CAMERA`, `DEV_HAS_KEYPAD` (adc-keys ladder), `DEV_HAS_GPIO_KEYS` (discrete gpio-keys), `DEV_HAS_BUZZER`, `DEV_HAS_LED`, `DEV_HAS_SD`, `DEV_HAS_DVR`, `DEV_HAS_FC_LINK`.
- **Build pointers:** `DEV_DTB` (built `.dtb` basename; must match the DTS below), `DEV_UI_BOARD` (the `ml-hud` board-HAL name, empty if the device has no UI), `DEV_MLIMG_TARGET`.
- **RAM-boot load map** (required; `ram-boot.sh` refuses without it): `DEV_KADDR`, `DEV_RDADDR`, `DEV_DTADDR` - the `loady` addresses for the OTRA container / initramfs / dtb. Place them in usable DRAM, above the decompressed kernel (lands at `0x200a0000`) and below the device's `mmz` reserved-memory carveout.

### 2. `kernel/devices/<name>/` (required) - kernel DTS + config set

- `<board>.dts` - the device tree. Its compiled name must equal `DEV_DTB` (`<board>.dtb`).
- `fragments` - one config-fragment basename per line, in order; each resolves to `kernel/configs/<name>.config`. They merge on top of the universal base (`configs/artosyn.config` then `configs/trim.config`). Include the fragments for this device's peripherals (e.g. `display`, `input`, `codec`, `camera`) and omit the rest.

Built by `BOARD=<name> kernel/scripts/build.sh` (the `make kernel` target passes `BOARD=$(DEVICE)`).

### 3. `rootfs/devices/<name>/` (required) - rootfs profile + overlay

- `board.conf` - the rootfs profile, shell-sourced by `rootfs/build.sh`. Every var is required; the build fails fast if one is missing.
  - Identity / USB-gadget addressing: `HOSTNAME`, `ROOT_PASS`, `USB_PRODUCT`, `GADGET_IP`, `GADGET_CIDR`, `HOST_GW`, `DEV_MAC`, `HOST_MAC`. Pick the next free device index NN and derive all three from it: `GADGET_IP=192.168.3.(100+NN)`, `DEV_MAC=EE:EE:<NN as 4 bytes>`, `HOST_MAC=AA:AA:<NN as 4 bytes>`. All devices share one subnet and coexist on the host's `br-artosyn` bridge (`glue/net/net-up.sh` enslaves any gadget interface, no per-device host config); the fixed `HOST_MAC` gives a stable interface name encoding NN. `glue/lib/device.sh` resolves `DEVICE_IP` from `GADGET_IP`, so the glue toolchain follows automatically. Optionally add the new address to the reachability report list in `net-up.sh`.
  - `HAS_SD` - `1` if the board has a microSD slot; gates the MTP gadget function (and by convention the SD-dependent services).
  - UBI / NAND geometry: `PARTITION` (the slot-B target, resolved by NAME on the device), `PARTITION_PEBS`, `PEB_SIZE`, `MIN_IO`, `SUBPAGE`, `LEB_SIZE`, `MAX_LEB_COUNT`.
- `overlay/` - the device-specific rootfs tree, laid over the shared `rootfs/skeleton/`.
  - `etc/init.d/<service>` - device-specific OpenRC services (e.g. `ml-display`, `ml-hud`, `ml-video`, `ml-ledd`, `ml-chime`, `ml-sdcard`). `rootfs/scripts/make-rootfs.sh` symlinks each into the correct runlevel only if it is present, so a device ships only the services it has. The shared `usb-gadget` and `dropbear` come from the skeleton and are always wired.
  - `etc/modules-load.d/ml.conf` - kernel modules to force-load at boot (those with no DT coldplug or that need parameters).

### 4. `userspace/ml-hud/src/hal/board_<DEV_UI_BOARD>.c` (UI devices only)

Only for a device that runs `ml-hud` (has a display). It implements the `board.h` profile struct - input device node, keymap, battery ADC node, SD mount, board class, and which optional peripherals exist. Set `DEV_UI_BOARD` in the manifest to the `<name>` used here. Air units (no UI) leave `DEV_UI_BOARD` empty and skip this file.

## Checklist

- [ ] `devices/<name>/device.mk` (identity, capabilities, `DEV_DTB`, `DEV_MLIMG_TARGET`, load map)
- [ ] `kernel/devices/<name>/<board>.dts` + `kernel/devices/<name>/fragments`
- [ ] `rootfs/devices/<name>/board.conf` + `rootfs/devices/<name>/overlay/`
- [ ] `userspace/ml-hud/src/hal/board_<DEV_UI_BOARD>.c` (only if the device has a UI)
- [ ] `make setup DEVICE=<name>` prints the expected identity, then `make kernel` / `rootfs` build
