# glue

Host-side tooling that talks to the physical device. This is the layer that ties the otherwise independent parts (kernel, rootfs, menu) together: it takes their build artifacts and pushes, flashes, or boots them on the goggle over the network or serial. Nothing here builds a component; each part builds itself and glue deploys and drives it.

The distinction from a part's own `scripts/`: a part's build scripts run entirely on the host and never touch a device, and device-side payloads (scripts that run on the goggle, like `kernel/modules/load.sh`) ship with their part. Glue is specifically the host-side scripts that reach out and act on a device.

## Groups

The groups talk to the device in **different boot states, with different credentials** (except `net/`, which is pure host-side setup):

- `net/` runs entirely on the **host**, no device contact: it assigns the static IP (or DHCP) and the NetworkManager exclusion that bring the USB-ethernet link up, so the other groups can reach the device.
- `flash/` and `fetch/` run while the device is booted on **stock slot A** (root / `artosyn`), flash because you never write a slot while it's the one running, fetch because the vendor blobs (and the boot-generated RF config) only exist there. All three scripts refuse to run if the device answers as slot B.
- `dev/` assumes the device is on the **open slot-B Alpine** (root / `libre`).
- `boot/` works from **either slot** (each script probes or takes `ROOT_PASS`), because getting to U-Boot and flipping slots are exactly the operations that cross the slot boundary.
- `recovery/` needs **no OS at all**, it drives the mask BootROM over the 3 debug-UART wires, the last resort when the device won't boot.

Env convention: `DEVICE_IP` (default `192.168.3.100`) selects the target device. `ROOT_PASS` overrides the password where a script's default doesn't match the booted slot.

Serial setup (one-time): the `boot/`, `dev/`, and `recovery/` serial steps need the console port in `ML_SERIAL`. Copy `glue.env.example` to `glue.env` (git-ignored) and set it to the USB-serial adapter's stable by-id path, e.g. `ML_SERIAL=/dev/serial/by-id/usb-Raspberry_Pi_Pico_..._-if00` (list yours with `ls /dev/serial/by-id/`; prefer the by-id path over a bare `/dev/ttyACMx`, which renumbers across replugs). An inline `ML_SERIAL=...` in the environment overrides the file. Both the Python tools and the shell scripts resolve it the same way via `lib/serial_port.py`.

`make` (in `glue/`) builds the compiled aarch64 helpers (`uboot-trigger`, `wdt-reset`, `ml-rf-replay`) from the `.c` next to their scripts into the git-ignored `build/`; the `boot/` and `flash/` scripts expect them prebuilt, so run `make` first. The `recovery/payload/` bare-metal build is deliberately excluded, build it from `recovery/RECOVERY.md` when needed.

- `net/` host-side USB-ethernet bring-up (run first, so the other groups can reach the device).
  - `net-up.sh` assigns the static IP `192.168.3.222/24` to the `enx*` gadget interface (auto-detecting its per-boot name); `net-up-libre.sh` does the same for the open slot-B (CDC-ECM) side; `net-dhcp.sh` uses DHCP instead.
  - `99-artosyn-unmanaged.conf` the NetworkManager keyfile that marks `enx*` unmanaged so a manual IP sticks (see `docs/host-network-setup.md`).
- `lib/` shared helpers used by the scripts here (and by `../userspace/hud/tools/deploy.sh`).
  - `ssh-opts.sh` the canonical SSH client option arrays: `SSH_OPTS_LIBRE` (open slot-B sshd) and `SSH_OPTS_LEGACY` (superset adding the legacy algorithms the vendor Dropbear on stock slot A / the air unit needs; harmless against the open sshd).
  - `serial_port.py` resolves the console port from `ML_SERIAL` (environment or `glue.env`); Python tools import `find_port()`, shell scripts run it (`python3 lib/serial_port.py`) so both agree on one setting.
- `flash/` writes artifacts into a NAND slot on the device.
  - `flash-kernel-b.sh <Image> <dtb>` packs a kernel `Image` into the OTRA container and writes `kernel1`/`dtb1` (slot B only), verifying by readback. Refuses to run unless the device answers as slot A. See the flash ladder in `docs/flash-and-verify-slots.md` and the HARD RULES in `../CLAUDE.md`.
  - `flash-rootfs-b.sh [rootfs.ubi]` ubiformats `userapp1` (slot B rootfs only) with the open Alpine UBI image built by `../rootfs/build.sh` (default artifact path). Same slot-A-only refusal and by-name partition resolution as the kernel flasher.
  - `mkkernel.py` packs/unpacks a raw kernel `Image` into the vendor OTRA+uImage container (`pack`/`unpack`/`size`/`verify`); `flash-kernel-b.sh` and the `boot/` RAM-boot scripts call it. A pure host-side data transform, no device contact.
  - `gpt_setactive.py` reads/flips the active-slot bit (GPT bit 47) in a `gpt0` image and recomputes the CRCs; `boot/flip-slot.sh` uses it to verify a flip. Also a pure offline transform (the on-device equivalent is `../native/mtdtool setslot`).
- `fetch/` reads vendor blobs off the device.
  - `fetch-vendor-blobs.sh [dest]` pulls everything the open slot-B stack needs from a live stock slot A into `../firmware/bin/slot-a/` (git-ignored), mirroring device paths and md5-verifying each transfer: the AR8030 RF firmware + configs **including the boot-generated merged `bb_config_gnd.json.usr_cfg.json`** (which exists only on a running A, never in a partition dump), the Wave521C codec firmware (`chagall*.bin.gz`, decompressed and staged at the wave5 driver's `lib/firmware/cnm/` path), and the vendor MPI libs `ml-codec-probe` links against. `ar_lowdelay` + the RTSP RE libs stay with `missinglynk dump-firmware`.
- `dev/` developer inner-loop drivers and transfer primitives.
  - `kdev.sh` chains the kernel build (`../kernel/scripts/build.sh` + `../kernel/modules/build.sh`) and a RAM-boot (`boot/ram-boot.sh`) behind composable `--build`, `--build-fast`, and `--ramboot` flags.
  - `push.sh <file-or-dir> [more...]` streams files or directories to `/tmp` (a 32 MB exec-allowed tmpfs) on the slot-B Alpine over a plain SSH channel (the device has no scp/sftp); `DEST=` overrides the target dir.
- `boot/` U-Boot access, RAM-boots, and the slot flip, the safety-critical layer of the A/B ladder (`docs/flash-and-verify-slots.md`). All serial steps run over a USB-serial adapter (see `../docs/guides/serial-and-debug-access.md`) using the `ML_SERIAL` port from the serial setup above.
  - `drop-to-uboot.sh` gets the device to the U-Boot `=>` prompt hands-off: builds + deploys `uboot-trigger.c` (sets the SPL reboot-reason flag, then watchdog-resets), and catches the autoboot on serial with `wait-for-serial.py`.
  - `ram-boot.sh <Image> <dtb> [bootargs]` RAM-boots an arbitrary kernel with **zero flash writes**: packs the Image into the OTRA container (`../glue/flash/mkkernel.py`), drops to U-Boot, `loady`s dtb + container over serial (~4 min), `bootm`s. The proving step of the flash ladder; a reset falls back to the flashed active slot.
  - `ramboot-at-uboot.sh <container> <dtb>` just the `loady`+`bootm` half, for when the device already sits at the `=>` prompt.
  - `ram-boot-flashed-b.sh` RAM-boots the ALREADY-FLASHED `kernel1`/`dtb1` bytes via U-Boot `mtd read` (seconds, no serial transfer), the gold-standard verification of a slot-B flash before any flip.
  - `flip-slot.sh a|b` flips the active A/B slot: deploys `../native/mtdtool` + `wdt-reset.c`, writes only `gpt0`, verifies by readback (`flash/gpt_setactive.py`) before firing the watchdog reset. Guarded by the HARD RULES in `../CLAUDE.md`, never flip to an unproven B.
  - `uboot_boot.py` (drive the U-Boot prompt over serial: `load`/`cmd`/`uboot`), `console.py` (serial monitor/send/catch), and `wait-for-serial.py` (generic wait-for-substring; `--port` or the shared `ML_SERIAL`) are the serial primitives the above compose.
- `recovery/` the **absolute last-resort** BootROM UART flash-writer, recovers a device that won't boot at all (SPL won't drop to U-Boot, kernel/rootfs bricked), over only the 3 debug-UART wires at 115200. It works by driving the mask BootROM to run bare-metal code that rewrites NAND directly, and **only while slot A was never written** (the whole point of the HARD RULES in `../CLAUDE.md`). This is the RE'd nuclear option, not everyday tooling; the full chain and procedure are in **`recovery/RECOVERY.md`**.
  - `RECOVERY.md` the proven runbook (build the writer, de-risk with a read test, verify-gated write) plus the re-dump procedure for the ROM image.
  - `bootrom_dl.py` drives the BootROM `0x55`-frame RAM-write protocol (`--gmi <bin> <load_hex>` downloads + executes a payload); `gmi.py` wraps a payload in a valid `.GMI` image the ROM will `blr` to.
  - `payload/` the bare-metal aarch64 sources it downloads: `flash_writer.c` (erase/program/verify via the AR9301 qspi controller), `rw.c` (read-only probe), `entry.S`/`data.S`/`*.ld` (startup + the gpt0 image to write + link scripts).
  - `bootrom-0x0.bin` the 32 KB mask-ROM dump the protocol was derived from (git-ignored, proprietary; re-acquire per `RECOVERY.md`).

- `docs/` the procedure guides this tooling implements: `host-network-setup.md` (static IP + the NetworkManager gotcha), `first-setup-known-good-slot.md` (one-time: pin a trusted slot A), `flash-and-verify-slots.md` (the untainted-A flash + RAM-verify ladder), and `clone-a-slot.md` (component-by-component slot copy).

## Coupling note

The scripts here reach into sibling trees at runtime (`../kernel/scripts/pin.env`, `../rootfs/build/rootfs.ubi`, `../native/mtdtool`, `../userspace/...`, the repo-root `.venv`). Glue is the orchestrator: it assumes those sibling trees are checked out next to it, which the wrapper repo provides as submodules (`kernel/`, `rootfs/`, `userspace/`) alongside its own `native/` and `firmware/`.

## Related: `../userspace/gstreamer/`

The GStreamer stack (build the SD-card prefix, deploy it, run the pipelines) lives in [`userspace/gstreamer/`](../userspace/gstreamer/), not under glue, it is a component with its own device-side runtime, not just host tooling. Its `deploy.sh` follows the same conventions as `dev/` (open slot-B Alpine, root/`libre`, `DEVICE_IP`).
