"""
MissingLynk component framework: deploy our tooling to the goggle and toggle
individual components on/off.

Model
-----
- `install`   - copy all our files into /usrdata/missinglynk and arm the boot hook.
- `uninstall` - remove everything (full revert to stock).
- `set_enabled(name, on)` - flip a component in the on-device config file.
- `status`    - show what's installed / enabled / live.

Each component is an entry in COMPONENTS. Enabling/disabling only edits
/usrdata/missinglynk/config (a shell-sourceable file). At boot, our start.sh
sources that config and applies whatever is enabled, then runs the stock boot
UNMODIFIED. So with nothing enabled the boot is effectively stock, and because
start.sh always reaches `exec run.sh`, USB networking + SSH always come up even
if a component is broken (see docs/06).

Boot safety
-----------
run.sh runs /usrdata/run_dbg.sh at its very top (when /usrdata/buildtime matches
/usr/usrdata/buildtime), then exits. So our hook (run_dbg.sh) applies the enabled
components and then runs the stock boot body, copied verbatim from run.sh, which
brings up the USB gadget (usb0 = SSH-over-USB), servicemanager, and ar_lowdelay
exactly as stock. The hook stays in place across boots (persistent, no re-arm).
The only change to the live boot is a bind-mount of ar_lowdelay (rtsp), which
cannot affect USB/SSH; a broken component only affects that component. Recovery if
the hook ever fails: SSH in and `uninstall` (dropbear comes up via /etc/init.d
independently), or the physical UART (docs/08).
"""
from __future__ import annotations

import hashlib
import os
import re
import shlex
from dataclasses import dataclass

from . import GOGGLE_IP
from .connection import Goggle
from .progress import printer

# Device paths
ML_DIR: str = "/usrdata/missinglynk"
ML_BIN: str = f"{ML_DIR}/bin"
CONFIG: str = f"{ML_DIR}/config"
START_SH: str = f"{ML_DIR}/start.sh"
RUN_DBG: str = "/usrdata/run_dbg.sh"
BUILDTIME: str = "/usrdata/buildtime"
STOCK_BUILDTIME: str = "/usr/usrdata/buildtime"
RUN_SH: str = "/usr/usrdata/run.sh"

# snapshot of what start.sh actually applied this boot (in /tmp, cleared on reboot);
# status diffs the live config against it to flag pending (needs-reboot) changes.
APPLIED: str = "/tmp/missinglynk.applied"

# USB gadget / networking (for the ecm component)
GADGET: str = "/sys/kernel/config/usb_gadget/g1"   # built by usb_gadget_configfs.sh at boot
GOGGLE_MASK: str = "255.255.255.0"

# stable locally-administered MACs so the host's interface name stops changing each boot
ECM_DEV_ADDR: str = "02:00:00:00:00:01"    # goggle (gadget) side
ECM_HOST_ADDR: str = "02:00:00:00:00:02"   # host (phone/PC) side

# DHCP hands out a different address per gadget mode, so the leased IP tells you at a
# glance which mode the goggle is in (.123 = RNDIS, .124 = CDC-ECM).
DHCP_OFFER_RNDIS: str = "192.168.3.123"
DHCP_OFFER_ECM: str = "192.168.3.124"

# Local artifact paths (repo-relative)
_ROOT: str = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATCHED_LOCAL: str = os.path.join(_ROOT, "firmware", "bin", "ar_lowdelay.rtsp-patched2")
FBTEXT_LOCAL: str = os.path.join(_ROOT, "native", "fbtext")
MINIDHCPD_LOCAL: str = os.path.join(_ROOT, "native", "minidhcpd")
MLMENU_LOCAL: str = os.path.join(_ROOT, "native", "mlmenu", "mlmenu")

# the open menu binary is ~1.5M, too big for /usrdata (1.8M, shared and near-full), so it is
# staged on the SD card and copied to tmpfs at boot, then bind-mounted over the stock UI app.
SD_MENU_BIN: str = "/tmp/sdcard/missinglynk/libre-menu"
TMP_MENU: str = "/tmp/libre-menu"
MENU_TARGET: str = "/usr/bin/test_uidesign"

# escape hatch: hold BACK at power-on to skip MissingLynk for one boot (temporary
# stock boot; config is untouched so the next boot is normal). Detected by reading the
# adc-keys voltage ladder directly on ADC channel 0: BACK pulls it to ~400mV (window
# below), idle is 0mV and the neighbours are bind=200 and record=600, so the window
# isolates BACK. The ADC read is instant and reflects the held button immediately (no
# input-driver polling delay), so it works the moment the hook runs at boot.
SKIP_ADC: str = "/sys/bus/iio/devices/adc/in_voltage0_input"
SKIP_LABEL: str = "BACK"
SKIP_MV_MIN: int = 300
SKIP_MV_MAX: int = 500

# HUD layout / timing
HUD_X: int = 40
HUD_Y: int = 40
HUD_TITLE_PX: int = 40
HUD_LIST_PX: int = 28
OSD_APP: str = "test_uidesign"   # the goggle UI app; draw the HUD once it is up
INDICATOR_SETTLE: int = 6        # wait this long after the UI app appears, for it to finish
                                 # its initial paints, so a single draw isn't overdrawn
INDICATOR_REPEAT: int = 2        # a couple of draws (1s apart) as light insurance


@dataclass
class Component:
    name: str
    summary: str
    default_on: bool

    # files to deploy into ML_BIN: (local_path, remote_basename)
    files: list[tuple[str, str]]

    # if set, bind-mount ML_BIN/<basename> over <target> at boot: (basename, target)
    bind_mount: tuple[str, str] | None = None

    # if set, launch ML_BIN/<basename> as a background daemon AFTER the boot body
    # (so usb0 etc. are up); the basename of a binary in bin/
    daemon: str | None = None

    # if True, re-present the USB gadget as CDC-ECM after the boot body (see _gen_hook)
    gadget_ecm: bool = False

    # label shown in the HUD list (None = not listed, e.g. the indicator itself)
    hud_label: str | None = None
    build_hint: str = ""


COMPONENTS: list[Component] = [
    Component(
        name="rtsp",
        summary="RTSP video server on :554 (patched ar_lowdelay)",
        default_on=False,
        files=[(PATCHED_LOCAL, "ar_lowdelay.patched")],
        bind_mount=("ar_lowdelay.patched", "/usr/bin/ar_lowdelay"),
        hud_label="RTSP",
        build_hint="dump a stock ar_lowdelay then run firmware/patches/apply-patches.py",
    ),
    Component(
        name="menu",
        summary="open libre-menu as the goggle UI (staged on the SD, bind-mounted over test_uidesign)",
        default_on=True,
        files=[],   # staged to the SD (see SD_MENU_BIN), not /usrdata; the hook copies + binds it
        build_hint="build with userspace/libre/build-device.sh, then push to the SD",
    ),
    Component(
        name="indicator",
        summary="on-screen MissingLynk HUD listing enabled components",
        default_on=True,
        files=[(FBTEXT_LOCAL, "fbtext")],
        build_hint="build it with native/build.sh",
    ),
    Component(
        name="dhcp",
        summary="DHCP server (a USB host auto-gets 192.168.3.123); pairs with ecm for phones",
        default_on=False,
        files=[(MINIDHCPD_LOCAL, "minidhcpd")],
        daemon="minidhcpd",
        hud_label="DHCP",
        build_hint="build it with native/build.sh",
    ),
    Component(
        name="ecm",
        summary="USB gadget as CDC-ECM not RNDIS (Android binds it natively; needs a USB-OTG adapter)",
        default_on=False,
        files=[],
        gadget_ecm=True,
        hud_label="ECM",
    ),
]

# Always-installed binaries that are not components. The on-goggle menu (mlmenu) is
# the control surface: launched on every normal boot and not disableable, so you can never
# strand yourself with no way to re-enable things from the goggle. A BACK-held recovery
# boot still skips it (and everything else), staying fully stock.
ALWAYS_FILES: list[tuple[str, str]] = [(MLMENU_LOCAL, "mlmenu")]
ALWAYS_BUILD_HINT: str = "build it with native/build.sh"


def _component(name: str) -> Component:
    for component in COMPONENTS:
        if component.name == name:
            return component

    raise ValueError(f"unknown component {name!r}; known: {[c.name for c in COMPONENTS]}")


def _extract_body(run_sh: str) -> str:
    """
    Return run.sh's boot body: everything after its own run_dbg.sh check. Our
    hook runs this verbatim, so the stock boot (usb gadget = usb0/SSH, ar_lowdelay,
    servicemanager) stays faithful even though run_dbg.sh runs in run.sh's place.
    """
    marker: str = 'echo "run normal..."'
    if marker not in run_sh:
        raise RuntimeError(f"cannot parse {RUN_SH} (no 'run normal' marker)")

    body: str = run_sh.split(marker, 1)[1].split("\n", 2)[2]  # drop the '' and 'fi' lines
    for need in ("usb_gadget_configfs", "ar_lowdelay", "servicemanager"):
        if need not in body:
            raise RuntimeError(f"refusing to build hook: boot body missing {need!r}")

    return body


_TEMPLATE_DIR: str = os.path.join(os.path.dirname(os.path.abspath(__file__)), "templates")


def _render_template(name: str, values: dict[str, object]) -> str:
    """
    Fill a templates/ shell file: replace each @KEY@ with values[KEY] (single
    pass, so substituted content is never re-scanned). Unknown keys raise.
    """
    with open(os.path.join(_TEMPLATE_DIR, name), "r") as f:
        text: str = f.read()

    def substitute(match: re.Match[str]) -> str:
        key: str = match.group(1)
        if key not in values:
            raise KeyError(f"template {name}: no value for @{key}@")

        return str(values[key])

    return re.sub(r"@([A-Z][A-Z0-9_]*)@", substitute, text)


def _gen_hook(body: str) -> str:
    """
    Render templates/boot-hook.sh: the static shell lives there; only the
    per-component lines are generated here.
    """
    defaults: str = "\n".join(
        f"    {component.name}={'on' if component.default_on else 'off'}"
        for component in COMPONENTS)

    bind_mounts: str = "\n".join(
        f'[ "${component.name}" = on ] && mount -o bind "$ML/bin/{component.bind_mount[0]}" '
        f'{component.bind_mount[1]} 2>/dev/null'
        for component in COMPONENTS if component.bind_mount)

    hud_lines: str = "\n".join(
        f'            if [ "${component.name}" = on ]; then "$ML/bin/fbtext" '
        f'"- {component.hud_label}" $x $y {HUD_LIST_PX}; y=$((y + {HUD_LIST_PX + 6})); fi'
        for component in COMPONENTS if component.hud_label)

    snapshot: str = "\n".join(
        f'echo "{component.name}=${component.name}" {">" if i == 0 else ">>"} {APPLIED}'
        for i, component in enumerate(COMPONENTS))

    # baseline: every component off (used when the boot is skipped via the escape hatch)
    off_init: str = "\n".join(f"{component.name}=off" for component in COMPONENTS)

    # background daemons launched AFTER the boot body (so the gadget netdev exists).
    # minidhcpd auto-detects the active interface and offers a mode-dependent address
    # (so the lease reveals whether the goggle is in RNDIS or ECM mode).
    daemon_lines: list[str] = []
    for component in COMPONENTS:
        if not component.daemon:
            continue

        if component.daemon == "minidhcpd":
            daemon_lines.append(
                f'if [ "${component.name}" = on ]; then\n'
                f'    offer={DHCP_OFFER_RNDIS}\n'
                f'    [ "$ecm" = on ] && offer={DHCP_OFFER_ECM}\n'
                f'    setsid "$ML/bin/{component.daemon}" auto "$offer" >/dev/null 2>&1 &\n'
                f'fi')
        else:
            daemon_lines.append(
                f'[ "${component.name}" = on ] && setsid "$ML/bin/{component.daemon}" '
                f'>/dev/null 2>&1 &')

    # ecm component: re-present the gadget as CDC-ECM after the body (Android binds it)
    ecm_block: str = ""
    ecm_components: list[Component] = [c for c in COMPONENTS if c.gadget_ecm]
    if ecm_components:
        ecm_block = _render_template("ecm-switch.sh", {
            "NAME": ecm_components[0].name,
            "GADGET": GADGET,
            "ECM_DEV_ADDR": ECM_DEV_ADDR,
            "ECM_HOST_ADDR": ECM_HOST_ADDR,
            "GOGGLE_IP": GOGGLE_IP,
            "GOGGLE_MASK": GOGGLE_MASK,
        })

    return _render_template("boot-hook.sh", {
        "RUN_SH": RUN_SH,
        "ML_DIR": ML_DIR,
        "SKIP_LABEL": SKIP_LABEL,
        "SKIP_ADC": SKIP_ADC,
        "SKIP_MV_MIN": SKIP_MV_MIN,
        "SKIP_MV_MAX": SKIP_MV_MAX,
        "OFF_INIT": off_init,
        "DEFAULTS": defaults,
        "SNAPSHOT": snapshot,
        "BIND_MOUNTS": bind_mounts,
        "SD_MENU_BIN": SD_MENU_BIN,
        "TMP_MENU": TMP_MENU,
        "MENU_TARGET": MENU_TARGET,
        "OSD_APP": OSD_APP,
        "INDICATOR_SETTLE": INDICATOR_SETTLE,
        "INDICATOR_REPEAT": INDICATOR_REPEAT,
        "HUD_X": HUD_X,
        "HUD_Y": HUD_Y,
        "HUD_TITLE_PX": HUD_TITLE_PX,
        "HUD_TITLE_STEP": HUD_TITLE_PX + 16,
        "HUD_LINES": hud_lines,
        "BOOT_BODY": body,
        "ECM_BLOCK": ecm_block,
        "DAEMONS": "\n".join(daemon_lines),
    })


def _push(goggle: Goggle, local: str, remote: str) -> None:
    with open(local, "rb") as f:
        data: bytes = f.read()
    local_md5: str = hashlib.md5(data).hexdigest()
    quoted_remote: str = shlex.quote(remote)

    existing: list[str] = goggle.run(f"md5sum {quoted_remote} 2>/dev/null")[0].decode().split()
    if existing and existing[0] == local_md5:
        print(f"      {os.path.basename(remote)} (unchanged, skipped)")
        return

    goggle.write_file(remote, data, on_progress=printer(f"      {os.path.basename(remote)}"))
    goggle.run(f"chmod +x {quoted_remote}")
    uploaded: list[str] = goggle.run(f"md5sum {quoted_remote}")[0].decode().split()
    if not uploaded or uploaded[0] != local_md5:
        raise IOError(f"md5 mismatch after upload of {remote} (want {local_md5}, "
                      f"got {uploaded[0] if uploaded else 'no md5sum output'})")


def install(goggle: Goggle) -> None:
    missing: list[str] = []
    for component in COMPONENTS:
        for local, _ in component.files:
            if not os.path.isfile(local):
                missing.append(f"  {component.name}: {local}\n      ({component.build_hint})")

    for local, _ in ALWAYS_FILES:
        if not os.path.isfile(local):
            missing.append(f"  mlmenu: {local}\n      ({ALWAYS_BUILD_HINT})")

    if missing:
        raise FileNotFoundError("missing artifacts, build them first:\n" + "\n".join(missing))

    print(f"[1/5] staging files -> {ML_BIN}")
    goggle.run(f"mkdir -p {ML_BIN}")

    for component in COMPONENTS:
        for local, remote in component.files:
            _push(goggle, local, f"{ML_BIN}/{remote}")

    for local, remote in ALWAYS_FILES:
        _push(goggle, local, f"{ML_BIN}/{remote}")

    print("[2/5] matching buildtime (prevents /usrdata wipe)")
    goggle.run(f"cp {STOCK_BUILDTIME} {BUILDTIME}")
    if goggle.run(f"cmp -s {STOCK_BUILDTIME} {BUILDTIME} && echo OK")[0].strip() != b"OK":
        raise IOError("buildtime mismatch, aborting (would wipe /usrdata on boot)")

    print("[3/5] generating boot hook from run.sh")
    body: str = _extract_body(goggle.read_file(RUN_SH).decode(errors="replace"))
    # preserve existing component states across a re-install; new components get default
    try:
        existing: dict[str, str] = read_config(goggle)
    except Exception:
        existing = {}
    write_config(goggle, {
        component.name: existing.get(component.name,
                                     "on" if component.default_on else "off")
        for component in COMPONENTS})
    goggle.write_file(START_SH, _gen_hook(body).encode())

    print("[4/5] validating hook syntax")
    _, stderr, exit_status = goggle.run(f"sh -n {START_SH}")
    if exit_status != 0:
        goggle.run(f"rm -f {START_SH}")
        raise IOError("generated hook failed syntax check (not armed): "
                      + stderr.decode(errors="replace").strip())

    print("[5/5] arming boot hook")
    goggle.run(f"chmod +x {START_SH}; cp {START_SH} {RUN_DBG}; chmod +x {RUN_DBG}")

    enabled: list[str] = [component.name for component in COMPONENTS if component.default_on]
    print(f"\nInstalled. Enabled by default: {', '.join(enabled) or 'none'}.")
    print("Toggle with `missinglynk enable|disable <component>`, then POWER-CYCLE.")


def uninstall(goggle: Goggle) -> None:
    print("Removing all MissingLynk files...")
    goggle.run("killall -9 fbtext minidhcpd 2>/dev/null; true")
    goggle.run(f"rm -rf {ML_DIR}; rm -f {RUN_DBG} {BUILDTIME} {APPLIED}")
    print("Done. POWER-CYCLE to drop the live bind-mount and boot fully stock.")


def _parse_kv(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()

    return values


def read_config(goggle: Goggle) -> dict[str, str]:
    text: str = goggle.run(f"cat {CONFIG} 2>/dev/null")[0].decode(errors="replace")
    if not text.strip():
        raise RuntimeError("MissingLynk is not installed (no config); run `missinglynk install`")

    return _parse_kv(text)


def write_config(goggle: Goggle, config: dict[str, str]) -> None:
    lines: list[str] = ["# MissingLynk component config (managed by the CLI; sourced by start.sh)"]
    lines += [f"{name}={config.get(name, 'off')}"
              for name in (component.name for component in COMPONENTS)]
    goggle.write_file(CONFIG, ("\n".join(lines) + "\n").encode())


def set_enabled(goggle: Goggle, name: str, on: bool) -> None:
    component: Component = _component(name)
    config: dict[str, str] = read_config(goggle)
    config[name] = "on" if on else "off"
    write_config(goggle, config)

    print(f"{name} {'enabled' if on else 'disabled'} ({component.summary}).")
    print("POWER-CYCLE the goggle for it to take effect.")


def status(goggle: Goggle) -> str:
    if goggle.run(f"[ -d {ML_DIR} ] && echo yes")[0].strip() != b"yes":
        return "MissingLynk: not installed"

    config: dict[str, str] = read_config(goggle)
    applied: dict[str, str] = _parse_kv(
        goggle.run(f"cat {APPLIED} 2>/dev/null")[0].decode(errors="replace"))

    # the hook self-re-arms each boot, so its momentary absence right after boot is
    # normal; only a buildtime mismatch is a real problem (run.sh would wipe /usrdata).
    buildtime_ok: bool = goggle.run(
        f"cmp -s {STOCK_BUILDTIME} {BUILDTIME} && echo OK")[0].strip() == b"OK"

    lines: list[str] = ["MissingLynk: installed"]
    if not buildtime_ok:
        lines.append("  WARNING: buildtime mismatch; run.sh will wipe /usrdata on next "
                     "boot. Re-run `missinglynk install`.")

    for component in COMPONENTS:
        configured: str = config.get(component.name, "off")
        applied_state: str = applied.get(component.name, "off")
        if configured != applied_state:
            state = "[needs reboot to apply]"
        elif configured == "on":
            state = "[active]"
        else:
            state = "[inactive]"
        lines.append(f"  {component.name:<10} {configured:<3}  {state:<25} {component.summary}")

    # OBSOLETE: legacy mlmenu row (same label as the `menu` component above); slated
    # for removal together with the mlmenu/ALWAYS_FILES machinery.
    lines.append("  menu       on   [always on]               on-goggle menu (long-press RIGHT to open)")

    if applied.get("rtsp") == "on":
        lines.append(f"\nstream URL: rtsp://{goggle.ip}:554/venc8/stream")

    return "\n".join(lines)
