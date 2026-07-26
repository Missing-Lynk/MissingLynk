# MissingLynk

**Open firmware and tooling for Artosyn "ArtLynk"-based FPV devices.**

> DISCLAIMER: Only continue if you know what you are doing. I take no responsibility for any damage or bricked devices. The process is well tested and revertible, but you have been warned.

MissingLynk replaces the closed vendor stack on ArtLynk-based FPV devices with an open, reproducible one: **mainline kernel, Alpine rootfs, GStreamer video pipeline, RF link daemon, and on-screen HUD**. Hardware-validated end to end. Fully reversible: the stock firmware remains untouched in slot A. Project overview: [organization README](https://github.com/Missing-Lynk).

The platform (Proxima-9311 SoC + AR8030 RF link) spans both ends of the link across many brands: **receivers** (goggles, HDMI-out receiver boxes) and **transmitters** (air units / VTXs). Reference devices are the BetaFPV VR04 HD goggle and its matching air unit; most of the stack should carry over to other ArtLynk-based hardware.

This repo is the **entry point**: the `missinglynk` CLI, host-side device tooling (flash, RAM-boot, recovery), and every component repo pinned as a git submodule. A tag here reproduces the exact state of the whole system.

**Slot A / slot B.** The device has two independent firmware banks, and the vendor's own updates alternate between them - so which bank a stock device is currently running depends on its update history. This project treats one bank as the untouched stock keystone (**slot A**, the `*0` partitions - never written) and builds the open stack into the other (**slot B**, the `*1` partitions - the only thing ever written, made active only once proven to boot). That split is what makes everything reversible. The steps below assume the device is booted on stock slot A; confirm that before fetching blobs or flashing.

## What you need

- **An ArtLynk-based FPV device**, validated on the BetaFPV VR04 HD goggle and its matching air unit.
- **A USB-C data cable.** The device enumerates as a USB-ethernet gadget; all SSH/network access runs over it.
- **A USB-UART serial adapter supporting 1152000 baud** - **optional**. You only need it to bring up the full open slot-B stack (Part 2) or to recover a device. The console runs at this non-standard rate; use an **FT232RL**, or an RP2040 running `pico-uart-bridge` as a fallback. A CP2102 is capped at 1 Mbaud and will not work. Wiring: [`docs/guides/serial-and-debug-access.md`](docs/guides/serial-and-debug-access.md).
- **A Linux host with docker** (arm64 emulation via qemu binfmt) for the cross-builds.

## Repository layout

Clone **with submodules**:

```sh
git clone --recurse-submodules git@github.com:Missing-Lynk/MissingLynk.git missinglynk
cd missinglynk
```

**Component repositories** (git submodules):

| Path | Repo | What it is |
|------|------|-----------|
| `kernel/` | [ml-kernel](https://github.com/Missing-Lynk/ml-kernel) | Mainline arm64 kernel build, Artosyn modules, and BSP documentation. |
| `userspace/` | [ml-userspace](https://github.com/Missing-Lynk/ml-userspace) | Open on-device programs: GStreamer pipeline, `ml-linkd` RF daemon, HUD/menu, `ml-ledd`, and the `mlm.h` wire contract. |
| `rootfs/` | [ml-rootfs](https://github.com/Missing-Lynk/ml-rootfs) | Open slot-B Alpine rootfs: build pipeline, skeleton, boot services. |
| `android/` | [ml-android](https://github.com/Missing-Lynk/ml-android) | Android app that tethers to the goggle and restreams the feed. |
| `datasheets/` | [ml-datasheets](https://github.com/Missing-Lynk/ml-datasheets) | Unofficial hardware reference: SoC, RF link, carrier board. |

**This repository:**

| Path | What |
|------|------|
| `missinglynk/` | Cross-platform Python CLI: identify, fetch-blobs, screenshot, dump-firmware, component framework. |
| `tests/` | Unit tests for the Python CLI; no device needed (`make check-python`). |
| `devices/` | Per-device profiles; `make list-devices` shows them, `make setup DEVICE=<name>` selects the target. |
| `glue/` | Host-side device scripts: networking, U-Boot/serial, RAM-boot, slot-B flashers, slot flip, recovery. |
| `native/` | On-device tools (vendor-glibc): `fbtext`, `minidhcpd`, `mtdtool`, `mlmenu`, `mlflash`, `air-qpower`, `ml-rfcmd`. |
| `flasher/` | Host-side flashing GUI (`ml-flasher`, Go); writes slot B over USB. |
| `firmware/` | Patch tooling that regenerates patched binaries from your own dump (vendor binaries **never distributed**). |
| `assets/` | Splash screen, OSD fonts. |
| `docs/` | Cross-cutting reference + guides ([`docs/README.md`](docs/README.md)). |
| `Makefile` | Build front door; sequences the component builds. |

## Quickstart, toolchain + open slot-B bring-up

Stand up the toolchain on a fresh Linux host, build the open slot-B stack, then flash and boot it. Part 2's manual from-source bring-up needs the serial adapter for the RAM-boot safety check before committing; the flasher GUI flashes a known-good image without serial (see Part 2).

### Part 1, host toolchain + builds (no serial needed)

**Step 0, install prerequisites.** Commands assume a Debian-based system; package names may vary on your distro.

```sh
sudo apt update
sudo apt install -y git docker.io qemu-user-static binfmt-support curl python3 mtd-utils fakeroot openssl
```

Let your user run docker without sudo (log out and back in afterwards, or run `newgrp docker`):

```sh
sudo usermod -aG docker "$USER"
```

Install uv (Python project tool) and load it into the current shell (or open a new one):

```sh
curl -LsSf https://astral.sh/uv/install.sh | sh
source $HOME/.local/bin/env
```

The rootfs build runs on the host and needs `mkfs.ubifs`/`ubinize` (`mtd-utils`), `fakeroot`, and `openssl`; all other builds are containerized. Part 2 additionally needs `sshpass`.

Verify the setup. The container should report `aarch64`, and `uv --version` should print a version:

```sh
docker run --rm --platform=linux/arm64 alpine uname -m
uv --version
```

**Step 1, clone with submodules.**

```sh
git clone --recurse-submodules git@github.com:Missing-Lynk/MissingLynk.git missinglynk
cd missinglynk
```

**Step 2, Python package.**
Create venv, install dependencies and activate it:

```sh
uv venv
uv pip install -e .
source .venv/bin/activate
missinglynk --help
```

**Step 3, host networking (reach the goggle).** One-time: stop NetworkManager from flushing the static IP on the USB-ethernet gadget.

```sh
sudo install -m644 glue/net/99-artosyn-unmanaged.conf /etc/NetworkManager/conf.d/
sudo systemctl reload NetworkManager
```

Then, with the goggle powered and plugged into USB: `net-up.sh` assigns `192.168.3.222/24` to the host side (re-run after every goggle reboot; the gadget re-randomizes its MAC each boot). `identify` must then name the unit (e.g. `goggle (P1_GND)`), proving the link works:

```sh
glue/net/net-up.sh
missinglynk identify
```

Details: [`glue/docs/host-network-setup.md`](glue/docs/host-network-setup.md).

**Step 4, fetch the vendor blobs from your device.** The open stack needs the AR8030 RF firmware + configs and the Wave521C codec firmware (`chagall`). The device must be booted on **stock slot A**.

```sh
missinglynk fetch-blobs
```

The blobs land in `firmware/bin/slot-a/` and stay local. `fetch-blobs` selects the right manifest per unit (goggle `gnd` vs air-unit `sky`), md5-verifies every transfer, and stages `chagall` where the wave5 driver expects it. `--all` additionally fetches dev/RE extras (vendor MPI libs) the open runtime does not need.

**Step 5, build everything.** The repo-root `Makefile` is the single front door; nothing here touches the device. `make` builds native tools, userspace programs, kernel + modules, and the slot-B rootfs, in that order.

**`make setup DEVICE=<name>` selects the target device.** Run it once before building; every later build, flash, and boot command then uses the selected profile automatically. There is no default: a device-dependent target with no device set fails with a pointer to this step rather than guessing. `make list-devices` lists the profiles (`betafpv-vr04-goggle`, `betafpv-vr04-air`, ...) and points you to `make setup`.

```sh
make list-devices                       # see the available device profiles
make setup DEVICE=betafpv-vr04-goggle   # required: no default, selects the target device
make
```

Or build parts individually (order matters, modules need the kernel, rootfs bakes in the modules and userspace binaries):

- `make native`: the vendor-glibc device tools (`fbtext`, `minidhcpd`, `mtdtool`, `mlmenu`, `mlflash`, `air-qpower`, `ml-rfcmd`)
- `make userspace`: the on-device programs, including the standalone fully-static `ml-pipeline` (no SD card, no plugin registry)
- `make kernel`: reproducible arm64 `Image` + out-of-tree Artosyn modules
- `make rootfs`: the lean `slim` Alpine slot-B rootfs, produces `rootfs/build/rootfs-<device>.ubi` (bakes in the modules); `make rootfs-dev` for the `dev` flavor (adds SSH + scp + strace/tcpdump)

Notes:

- The kernel build tree defaults to `build/` inside the kernel submodule; override with `BUILD_DIR=/path make kernel`. The first run builds the container and fetches the pinned kernel source (`make kernel ARGS=-v` to stream).
- Re-runs don't re-download (pinned inputs are sha256-checked). `make fast` = incremental kernel + modules dev loop; NOT reproducible, do a plain `make kernel` before flashing.
- `mtdtool` (from `make native`) is the on-device raw-NAND writer / slot flipper used in Part 2.
- `make flasher` builds the host-side flashing GUI; `make umtprd` builds the MTP-over-USB recordings gadget. Both are kept out of `make all` (they need Docker + network).
- `make check-python` lints and unit-tests the Python CLI. No device, no Docker; run it before sending a change that touches `missinglynk/` ([python-tooling.md](docs/guides/python-tooling.md)).
- Per-part details: [`kernel/`](kernel/), [`rootfs/`](rootfs/), [`userspace/gstreamer/`](userspace/gstreamer/).

**Checkpoint.** Built + fetched: `firmware/bin/slot-a/`, kernel `Image` + dtb + modules, `rootfs/build/rootfs-<device>.ubi`, native tools, the static `ml-pipeline`. This is as far as a machine without serial access goes.

### Part 2, flash + verify + flip to slot B

> **Just want the open firmware on your device?** Use the flasher GUI (`make flasher`, then run `ml-flasher`). It flashes a known-good image, only ever writes the **inactive** slot (so the running firmware is never at risk), verifies by readback, and offers "Flash only" (write without committing) plus a one-click slot switch. No serial needed. The manual chain below is the from-source / developer path.

Do NOT start the manual chain without the debug UART wired up ([`docs/guides/serial-and-debug-access.md`](docs/guides/serial-and-debug-access.md)) and the A/B safety ladder read ([`glue/docs/flash-and-verify-slots.md`](glue/docs/flash-and-verify-slots.md)). Flashing runs over USB, but the mandatory RAM-boot verification uses the serial console. Nothing becomes the active slot until it is proven to boot end-to-end from RAM.

The device must be booted from stock slot A; the flash scripts verify this automatically and refuse otherwise, pointing you to `glue/boot/flip-slot.sh a`. Each step below is a `make` target that uses your `make setup` device, so there are no paths to fill in by hand:

1. Flash the slot-B rootfs only (writes `userapp1`, never `userapp0` = slot A; uses `rootfs/build/rootfs-<device>.ubi` for the active device):

   ```sh
   make flash-rootfs
   ```

2. RAM-boot verify with A still active (**serial**). This boots the built kernel against the new B rootfs, commits nothing, and falls back to A on any failure:

   ```sh
   make ramboot
   ```

3. Flash the slot-B kernel + dtb (writes `kernel1`/`dtb1` only, verifies by readback), then RAM-boot the flashed `kernel1`/`dtb1` as the gold-standard check (**serial**):

   ```sh
   make flash-kernel
   make flashboot
   ```

4. ONLY after every check above is green, flip the active slot to B (writes `gpt0` only, then watchdog-resets). This one stays a deliberate, explicit command - there is no `make` shortcut for it:

   ```sh
   glue/boot/flip-slot.sh b
   ```

Each `make` target wraps the matching `glue/` script (`flash-rootfs-b.sh`, `ram-boot.sh`, `flash-kernel-b.sh`, `ram-boot-flashed-b.sh`); call those directly if you need to pass explicit paths.

Revert any time: `glue/boot/flip-slot.sh a` (slot A is untouched) + reset. Ultimate backstop if the device will not boot: the BootROM UART writer, `glue/recovery/RECOVERY.md`.

### Appendix, the RTSP overlay on stock firmware (optional)

An early proof-of-concept, kept for completeness and separate from the open stack this project is built around; it changes nothing in Parts 1-2. The stock firmware has a latent RTSP server, enabled by two one-instruction patches to `ar_lowdelay` and shipped as a stock-slot-A overlay (no slot-B flash, fully reversible, display unaffected): `rtsp://192.168.3.100:554/venc8/stream` delivers H.265 / 1080p / ~60 fps. While `rtsp` is enabled, SD-card DVR recording cannot run; `missinglynk disable rtsp` restores it.

Dump `ar_lowdelay`, apply the patches, build the native helpers (if not already done in Step 5), install the boot hook, and enable the component; the stream is live after a power-cycle:

```sh
missinglynk dump-firmware
python3 firmware/patches/apply-patches.py
make native
missinglynk install
missinglynk enable rtsp
```

Full revert: `missinglynk uninstall` + power-cycle. Consuming the stream: [`docs/guides/consuming-the-stream.md`](docs/guides/consuming-the-stream.md). The same stock-slot component framework also toggles `dhcp` (a USB host auto-gets an address) and `ecm` (expose the gadget as CDC-ECM for Android), plus a couple of other early overlays; see [`docs/guides/python-tooling.md`](docs/guides/python-tooling.md).

## Access facts

- Goggle USB-ethernet gadget: **`192.168.3.101`**, host uses **`192.168.3.222/24`**.
- SSH: **Dropbear, root / `artosyn`**, LEGACY crypto only (see `missinglynk/connection.py`).
- Stock rootfs `/` is **read-only squashfs**; `/usrdata` is writable & persistent (ubifs).

## Notes

- **Never publish the contents of `firmware/bin/`** (proprietary). The repos carry only original tooling, docs, and patch definitions; patched binaries are regenerated from your own dump.
- **The stock rootfs is never modified.** Stock-slot changes live in `/usrdata/missinglynk/` behind a boot hook that preserves stock SSH/USB. Full revert: `missinglynk uninstall` + power-cycle. See [`docs/guides/device-changes-and-revert.md`](docs/guides/device-changes-and-revert.md).
- Rooting/patching your device is at your own risk. Everything here is reversible.

## Support this project

Everything here is free and open. If it saved you time or got video flowing off your goggles, you can [buy me a coffee](https://buymeacoffee.com/stylesuxx).

If you have not bought the hardware yet, using my affiliate links supports the project at no additional cost to you: [VR04 HD goggle](https://betafpv.com/products/vr04-hd-fpv-goggles?sca_ref=32531.dWkE1zfXkb), [P1 air unit](https://betafpv.com/products/p1-air-unit-hd-vtx?sca_ref=32531.dWkE1zfXkb), [Meteor75 Pro HD kit](https://betafpv.com/products/meteor75-pro-hd-fpv-kit?sca_ref=32531.dWkE1zfXkb).

## Affiliation & legal

Independent, unofficial project. **Not affiliated with, authorized, sponsored, or endorsed by BetaFPV, Artosyn, KAP, or any related company.** "BetaFPV", "Artosyn", "ArtLynk", and other product or company names are trademarks of their respective owners, used here only nominatively to identify the hardware this project interoperates with.

This is reverse engineering for **interoperability and repair on hardware the author owns**, and is fully reversible. **No proprietary firmware or vendor binaries are distributed**: the repos carry only original documentation, original tooling, and patch definitions you apply to a dump from your own device. Provided as-is, no warranty; use at your own risk.
