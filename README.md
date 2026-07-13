# MissingLynk

**Open firmware and tooling for Artosyn "ArtLynk"-based FPV devices - the wrapper repo.**

> DISCLAIMER: Only continue if you know what you are doing. I do not take responsibility for any damage, bricked devices or any other tears. The process is quite simple, well tested and revertible. But one never knows - you have been warned!

MissingLynk replaces the closed vendor stack on ArtLynk-based FPV devices with an open, reproducible one: **mainline kernel, Alpine rootfs, GStreamer video pipeline, RF link daemon, and on-screen HUD** - hardware-validated end to end (RF downlink decode-to-display at 1080p60, zero-copy) and fully revertible: the stock firmware stays intact in slot A. Project overview: [organization README](https://github.com/Missing-Lynk).

The platform (Proxima-9311 SoC + AR8030 RF link) spans both ends of the link and many brands: **receivers** (goggles with built-in displays, receiver boxes with HDMI out) and **transmitters** (air units / VTXs with their various cameras). The reference devices are the BetaFPV VR04 HD goggle and its matching air unit; the BSP, RF link work, and most of the stack carry over to other ArtLynk-based hardware.

This repo is the **entry point**: the cross-platform `missinglynk` CLI, the host-side device tooling (flash, RAM-boot, recovery), and every component repo pinned as a git submodule - a tag here reproduces the exact state of the whole system.

## What you need

- **An ArtLynk-based FPV device.** Everything here is validated on the BetaFPV VR04 HD goggle and its matching air unit.
- **A USB-C data cable.** The device enumerates as a USB-ethernet gadget; all SSH/network access runs over it.
- **A USB-UART serial adapter that supports 1152000 baud** - only needed to flash and boot-verify the open stack (quickstart Part 2). The console runs at this non-standard rate and not every adapter can reach it: go for an **FT232RL**; an RP2040 board running `pico-uart-bridge` works as a fallback if you have one lying around. A CP2102 is hard-capped at 1 Mbaud and will not work. Wiring and details: [`docs/guides/serial-and-debug-access.md`](docs/guides/serial-and-debug-access.md).
- **A Linux host with docker** (arm64 emulation via qemu binfmt) for the cross-builds.

## Repository layout

Clone **with submodules**:

```sh
git clone --recurse-submodules git@github.com:Missing-Lynk/MissingLynk.git missinglynk
cd missinglynk
```

The component repos, mounted as submodules:

| Path | Repo | What it is |
|------|------|-----------|
| `kernel/` | [ml-kernel](https://github.com/Missing-Lynk/ml-kernel) | reproducible mainline arm64 kernel build + out-of-tree Artosyn modules + BSP docs |
| `userspace/` | [ml-userspace](https://github.com/Missing-Lynk/ml-userspace) | the open on-device programs: GStreamer video pipeline, `ml-linkd` RF link daemon, HUD/menu, `ml-ledd`, the shared `mlm.h` wire contract |
| `rootfs/` | [ml-rootfs](https://github.com/Missing-Lynk/ml-rootfs) | the open slot-B Alpine rootfs: build pipeline, skeleton, boot services (the swappable distro layer) |
| `android/` | [ml-android](https://github.com/Missing-Lynk/ml-android) | the Android app that tethers to the goggle and restreams the flight feed |
| `docs/reference/datasheets/` | [ml-datasheets](https://github.com/Missing-Lynk/ml-datasheets) | unofficial hardware reference: Proxima-9311 SoC, AR8030 RF link, carrier board |

What lives directly in this repo:

| path | what |
|------|------|
| `missinglynk/` | cross-platform Python package (paramiko + numpy/Pillow); CLI `missinglynk` (identify, fetch-blobs, screenshot, dump-firmware, component framework) |
| `glue/` | host-side device scripts: host networking (`net/`: `net-up.sh`, NetworkManager keyfile), U-Boot/serial primitives, RAM-boots, slot-B flashers, slot flip, BootROM recovery (`glue/recovery/RECOVERY.md`), dev loops |
| `native/` | small on-device tools built with the vendor-glibc toolchain: `fbtext`, `minidhcpd`, `mtdtool`, `mlmenu` |
| `firmware/` | patch tooling that reproduces patched binaries from your own firmware dump (vendor binaries are **never distributed**) |
| `assets/` | splash screen, OSD fonts |
| `docs/` | cross-cutting reference + guides, and the annotated index ([`docs/README.md`](docs/README.md)) pointing into every repo's docs |
| `Makefile` | the build front door: sequences the component builds in order |
| `STATUS.md` | where the project is right now |

## Quickstart, toolchain + open slot-B bring-up

Stand up the toolchain on a fresh Linux host, build the open slot-B stack, then flash and boot it on the device. Hardware: see [What you need](#what-you-need); Part 2 requires the serial adapter, without it stop after Part 1. **Proprietary vendor firmware is not distributed** - you fetch it from your own device in Step 4.

### Part 1, host toolchain + builds (no serial needed)

**Step 0, install prerequisites.** This guide is based on a Debian-based system; the exact package names and dependencies may vary on your distro.

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

Verify the setup: the container run must print `aarch64` (proves arm64 emulation is registered) and `uv --version` must report a version:

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

Then, with the goggle powered and plugged into USB: `net-up.sh` assigns `192.168.3.222/24` to the host side (re-run it after every goggle reboot, the gadget re-randomizes its MAC each boot); `identify` must then name the unit (e.g. `goggle (P1_GND)`), which proves the whole link works:

```sh
glue/net/net-up.sh
missinglynk identify
```

Details: [`glue/docs/host-network-setup.md`](glue/docs/host-network-setup.md).

**Step 4, fetch the vendor blobs from your device.** The open stack needs the AR8030 RF firmware + configs and the Wave521C codec firmware (`chagall`). The device must be booted on **stock slot A**.

```sh
missinglynk fetch-blobs
```

The blobs land in `firmware/bin/slot-a/` and stay local. `fetch-blobs` selects the right manifest per unit (goggle `gnd` vs air-unit `sky`), md5-verifies every transfer, and stages `chagall` where the wave5 driver expects it. `missinglynk fetch-blobs --all` additionally fetches dev/RE extras (vendor MPI libs) that the open runtime does not need.

**Step 5, build everything.** One front door, the repo-root `Makefile`; nothing here touches the device. Builds kernel, modules, rootfs, native tools, and the static gst pipeline, in order.

```sh
make
```

Or build parts individually (order matters, modules need the kernel, rootfs bakes in the modules and userspace binaries):

- `make kernel`: reproducible arm64 `Image` (`make kernel ARGS=verify` builds twice and compares sha256)
- `make modules`: out-of-tree Artosyn modules, staged depmod'd under the kernel build dir
- `make rootfs`: dev-flavor Alpine slot-B rootfs, produces `rootfs/build/rootfs.ubi` (bakes in the modules)
- `make native`: `fbtext`, `minidhcpd`, `mtdtool`, `mlmenu`
- `make gst`: the standalone fully-static `ml-pipeline` (no SD card, no plugin registry)

Notes:

- The kernel build tree defaults to `build/` inside the kernel submodule; override with `BUILD_DIR=/path make kernel`. The first run builds the container and fetches the pinned kernel source (`make kernel ARGS=-v` to stream).
- Re-runs don't re-download (pinned inputs are sha256-checked). `make fast` = incremental kernel + modules dev loop; NOT reproducible, do a plain `make kernel` before flashing.
- `make rootfs` builds the `dev` flavor (SSH + scp + strace/tcpdump). For the lean production image, use `FLAVOR=slim make rootfs`.
- `mtdtool` (from `make native`) is the on-device raw-NAND writer / slot flipper used in Part 2.
- Per-part details: [`kernel/`](kernel/), [`rootfs/`](rootfs/), [`userspace/gstreamer/`](userspace/gstreamer/).

**Checkpoint.** Built + fetched: `firmware/bin/slot-a/`, kernel `Image` + dtb + modules, `rootfs/build/rootfs.ubi`, the native tools, the static `ml-pipeline`. This is as far as a machine without serial access goes. Do not flip to slot B without the RAM-boot proof of Part 2 (a bad active-slot B once bricked a unit).

### Part 2, flash + verify + flip to slot B (requires serial access)

Do NOT start this without the debug UART wired up ([`docs/guides/serial-and-debug-access.md`](docs/guides/serial-and-debug-access.md)) and having read the A/B safety ladder ([`glue/docs/flash-and-verify-slots.md`](glue/docs/flash-and-verify-slots.md)). Slot A is never written; nothing becomes the active slot until it is proven to boot end-to-end from RAM.

The chain, with the goggle on stock slot A (root/`artosyn`):

1. Flash the slot-B rootfs only (writes `userapp1`, never `userapp0` = slot A; uses `rootfs/build/rootfs.ubi` by default):

   ```sh
   glue/flash/flash-rootfs-b.sh
   ```

2. RAM-boot verify with A still active. This boots a trusted kernel against the new B rootfs, commits nothing, and falls back to A on any failure:

   ```sh
   glue/boot/ram-boot.sh <Image> <dtb>
   ```

3. Flash the slot-B kernel + dtb (writes `kernel1`/`dtb1` only, verifies by readback), then RAM-boot the flashed `kernel1`/`dtb1` as the gold-standard check:

   ```sh
   glue/flash/flash-kernel-b.sh <Image> <dtb>
   glue/boot/ram-boot-flashed-b.sh
   ```

4. ONLY after every check above is green, flip the active slot to B (writes `gpt0` only, then watchdog-resets):

   ```sh
   glue/boot/flip-slot.sh b
   ```

Revert any time: `glue/boot/flip-slot.sh a` (slot A is untouched) + reset. Ultimate backstop if the device will not boot: the BootROM UART writer, `glue/recovery/RECOVERY.md`.

### Appendix, the RTSP overlay on stock firmware (optional)

The stock firmware has a latent RTSP server, enabled by two one-instruction patches to `ar_lowdelay`, shipped as a stock-slot-A overlay (no slot-B flash, fully reversible, display unaffected): `rtsp://192.168.3.100:554/venc8/stream` delivers H.265 / 1080p / ~60 fps. Independent of Parts 1-2.

While `rtsp` is enabled, SD-card DVR recording does not work (the two cannot run at the same time); `missinglynk disable rtsp` restores recording.

Dump `ar_lowdelay` from your device, apply the patches, build the native helpers (if not already done in Step 5), then install the boot hook and enable the component; the stream is live after a power-cycle:

```sh
missinglynk dump-firmware
python3 firmware/patches/apply-patches.py
make native
missinglynk install
missinglynk enable rtsp
```

Full revert: `missinglynk uninstall` + power-cycle. Consuming the stream: [`docs/guides/consuming-the-stream.md`](docs/guides/consuming-the-stream.md). The component framework also ships `indicator` (on-screen HUD) and `dhcp` (DHCP on `usb0`); see [`docs/guides/python-tooling.md`](docs/guides/python-tooling.md).

## Access facts

- Goggle USB-ethernet gadget: **`192.168.3.100`**, host uses **`192.168.3.222/24`**.
- SSH: **Dropbear, root / `artosyn`**, LEGACY crypto only (see `missinglynk/connection.py`).
- Stock rootfs `/` is **read-only squashfs**; `/usrdata` is writable & persistent (ubifs).

## Notes

- **Never publish the contents of `firmware/bin/`** (proprietary). The repos carry only original tooling, docs, and patch definitions; patched binaries are regenerated from your own dump.
- **The stock rootfs is never modified.** Stock-slot changes live in `/usrdata/missinglynk/` behind a boot hook that preserves stock SSH/USB; full revert is `missinglynk uninstall` + power-cycle. The open stack lives entirely in slot B; slot A stays bone-stock. See [`docs/guides/device-changes-and-revert.md`](docs/guides/device-changes-and-revert.md).
- Rooting/patching your device is at your own risk. Everything here is reversible.

## Support this project

This project is the result of countless late nights of reverse engineering, bricked-and-recovered hardware, serial-console archaeology, and more patience than I knew I had. Everything here is free and open, but if it saved you time, taught you something, or got video flowing off your goggles, you can [buy me a coffee](https://buymeacoffee.com/stylesuxx) - it genuinely helps keep work like this going.

## Affiliation & legal

This is an independent, unofficial project. It is **not affiliated with, authorized, sponsored, or endorsed by BetaFPV, Artosyn, KAP, or any related company.** "BetaFPV", "Artosyn", "ArtLynk", and other product or company names are trademarks of their respective owners, used here only nominatively to identify the hardware this project interoperates with.

The work here is reverse engineering for **interoperability and repair on hardware the author owns**, and is fully reversible. **No proprietary firmware or vendor binaries are distributed**: the repos carry only original documentation, original tooling, and patch definitions that you apply to a dump made from your own device. Provided as-is, with no warranty; use at your own risk.

Licensing is per repo: this wrapper and [ml-android](https://github.com/Missing-Lynk/ml-android) are **MPL-2.0** ([`LICENSE`](LICENSE)), the on-device stack ([ml-userspace](https://github.com/Missing-Lynk/ml-userspace), [ml-rootfs](https://github.com/Missing-Lynk/ml-rootfs)) is **GPL-3.0**, [ml-kernel](https://github.com/Missing-Lynk/ml-kernel) is **GPL-2.0** (Linux-derived), and [ml-datasheets](https://github.com/Missing-Lynk/ml-datasheets) is **CC-BY-SA-4.0**. The proprietary vendor firmware and binaries are not covered by any of these licenses.
