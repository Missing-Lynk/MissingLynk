# Python tooling (cross-platform)

`missinglynk` is a cross-platform (Windows/macOS/Linux) Python package for working with the goggle over its USB-ethernet link: capture the OSD framebuffer, and install/configure the on-device **component framework** (RTSP stream, on-screen indicator). It talks to the goggle entirely through **paramiko** (SSH) and decodes the framebuffer with **numpy + Pillow**, so no external host binaries are required.

The component binaries deployed onto the goggle (the patched `ar_lowdelay` and the native `fbtext`) are built separately, see "Build prerequisites" below.

## Setup (uv, recommended)

With [`uv`](https://docs.astral.sh/uv/), create a venv and install the package with its dependencies (paramiko, numpy, pillow). Use `uv sync` in place of `uv pip install -e .` to install reproducibly from the lockfile.

```sh
cd missinglynk
uv venv
uv pip install -e .
```

The `missinglynk` command lives inside the venv: either activate it and call `missinglynk ...` directly, or prefix each call with `uv run`. On Windows the activate script is `.venv\Scripts\activate`.

```sh
source .venv/bin/activate
uv run missinglynk screenshot
```

Plain venv fallback without uv (Windows activate path `.venv\Scripts\activate`):

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -e .
```

## Usage

Bring the link up first (host network setup, [glue/docs/host-network-setup.md](../../glue/docs/host-network-setup.md)). `screenshot` writes to the git-ignored `screenshots/` dir (default `missinglynk-<ts>.png`, the displayed 1920x1080 page); `-o` names the output, `--crop WxH+X+Y` selects a region, `--page 0|1|2` one of the 3 stacked pages (debugging), `--full` the whole raw buffer (slower). `dump-firmware` pulls the on-device binaries and libs for patching.

```sh
missinglynk screenshot
missinglynk screenshot -o menu
missinglynk screenshot --crop 1920x900+0+100
missinglynk screenshot --page 1
missinglynk screenshot --full
missinglynk dump-firmware
```

The component framework deploys the files and arms the boot hook (`install`, which enables nothing new), toggles individual components (`enable`/`disable`), reports state (`status`), or reverts everything to stock (`uninstall`). See [device-changes-and-revert.md](device-changes-and-revert.md).

```sh
missinglynk install
missinglynk enable rtsp
missinglynk disable indicator
missinglynk status
missinglynk uninstall
```

Access defaults are overridable per call, e.g. `missinglynk --ip 192.168.3.100 --password artosyn screenshot`.

## Components

| name | what | default |
|------|------|---------|
| `rtsp` | RTSP video server on `:554` via the patched `ar_lowdelay`; stream at `rtsp://192.168.3.100:554/venc8/stream` | **OFF** |
| `indicator` | on-screen "MissingLynk" HUD (top-left) listing the enabled components; rendered by the native `fbtext` binary using the goggle's own HarmonyOS TTF | **ON** |
| `dhcp` | DHCP server on `usb0` (the native `minidhcpd`), so a USB host (phone/PC) auto-gets `192.168.3.123` instead of needing a manual static IP. Launched after the boot body (once usb0 is up). The lease address encodes the USB mode: **`.123` = RNDIS** (this stock-overlay component), **`.124` = CDC-ECM** (the self-contained libre image). | **OFF** |

`enable`/`disable` only rewrite the on-device `config` file. The change takes effect **at the next power-cycle** (`status` flags it as `needs reboot to apply` until then); power-cycle after any `install` / `enable` / `disable` / `uninstall`.

### `status` output

`status` prints `MissingLynk: installed (boot hook armed)`, then per component its name, configured on/off, and a state:
- `active`, on and applied at the last boot;
- `inactive`, off and not applied;
- `needs reboot to apply`, config changed since the last boot.

When `rtsp` is active it also prints `stream URL: rtsp://192.168.3.100:554/venc8/stream`. (State is computed by diffing the live `config` against `/tmp/missinglynk.applied`, the boot snapshot, see [device-changes-and-revert.md](device-changes-and-revert.md).)

Only the rows the requested region needs are pulled from `/dev/fb0` via `dd` (the buffer is 3 stacked 1080-row pages, triple-buffered, see `framebuffer.py`), so the default one-page fetch transfers ~4.4 MB vs the 13.3 MB full buffer. A progress bar is shown on stderr (`-q` to silence).

## Build prerequisites

`install` does **not** build anything (the cross-compile needs docker); it preflights every artifact and **fails fast** with a build hint if any is missing. Build them first:

- **`native/fbtext`** (the `indicator` renderer, OSD TTF via the bundled `stb_truetype.h`) and **`native/minidhcpd`** (the `dhcp` component's DHCP server), both built by **`native/build.sh`** (docker arm64 `gcc:7`, glibc ≤ 2.25 to match the goggle). The BACK-hold escape hatch needs no binary; the hook reads the adc-keys voltage from sysfs directly (see [device-changes-and-revert.md](device-changes-and-revert.md)).
- **`firmware/bin/ar_lowdelay.rtsp-patched2`** (the `rtsp` binary), built by `python3 firmware/patches/apply-patches.py` (needs a stock `ar_lowdelay` dump, proprietary and git-ignored, see `firmware/bin/README.md`).

So `native/build.sh` + `apply-patches.py` (both one-off, unless the sources change), then `missinglynk install`.

## Cross-platform notes / gotchas

- **paramiko is pinned `>=3.5,<4`.** paramiko 4.x/5.x drop the algorithms the goggle's Dropbear requires (`diffie-hellman-group1-sha1` / `group14-sha1`, host key `ssh-rsa`); 3.5.x still implements them, and `connection.py` force-prepends them to the offered lists. On paramiko ≥4 you get a clear error telling you to pin 3.5.
- **This Dropbear has no SFTP subsystem**, so `write_file` streams bytes to `cat > path` over an exec channel rather than using SFTP.
- **Framebuffer decode is pure numpy/Pillow.** A 16-bit ARGB4444 pixel is expanded to RGB by nibble replication (`n*17`, so `0xF -> 255` = true white). See `framebuffer.py`.
- **Host networking is OS-specific** (assigning the static IP; the NetworkManager exclusion on Linux). The package assumes the link is already up (`192.168.3.100` reachable); see [glue/docs/host-network-setup.md](../../glue/docs/host-network-setup.md).
