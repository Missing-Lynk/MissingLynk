#!/usr/bin/env python3
"""
Generate flasher/internal/devconf/devices.json from the existing device
manifests (devices/<name>/device.mk) and rootfs profiles
(rootfs/devices/<name>/board.conf). The flasher embeds this JSON and parses it
at init, so the binary stays self-contained while the source of truth for open
slot IPs remains board.conf.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
OUT = REPO / "flasher" / "internal" / "devconf" / "devices.json"


def parse_shell_style(path: Path) -> dict[str, str]:
    """Read KEY="value" / KEY=value lines (comments stripped)."""
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line or "=" not in line:
            continue

        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"')

    return values


def main() -> int:
    devices_dir = REPO / "devices"
    rootfs_dir = REPO / "rootfs" / "devices"

    devices: list[dict[str, str]] = []

    for device_dir in sorted(devices_dir.iterdir()):
        if not device_dir.is_dir():
            continue

        name = device_dir.name
        mk = device_dir / "device.mk"
        conf = rootfs_dir / name / "board.conf"
        if not mk.exists() or not conf.exists():
            print(f"skip {name}: missing device.mk or board.conf", file=sys.stderr)
            continue

        product = parse_shell_style(mk).get("DEV_PRODUCT")
        gadget_ip = parse_shell_style(conf).get("GADGET_IP")

        if not product or not gadget_ip:
            print(f"skip {name}: DEV_PRODUCT={product!r} GADGET_IP={gadget_ip!r}", file=sys.stderr)
            continue

        devices.append({
            "product": product,
            "open_ip": gadget_ip,
        })

    if not devices:
        print("error: no device configs found", file=sys.stderr)
        return 1

    OUT.write_text(json.dumps(devices, indent=2) + "\n")
    print(f"wrote {OUT} ({len(devices)} device(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
