"""
Reader for the per-device manifests (`devices/<name>/device.mk`), the single source of truth
for device identity/capabilities/pointers. See plans/device-hal.md.

The manifests are make-native `KEY = VALUE` (so the root Makefile can `include` them); here we
parse the same files at runtime rather than duplicating their data in Python. No generated code.
"""
from __future__ import annotations

import re
from pathlib import Path

# repo root = the parent of this package dir (missinglynk/ lives at <repo>/missinglynk/).
_REPO_ROOT: Path = Path(__file__).resolve().parent.parent
_DEVICES_DIR: Path = _REPO_ROOT / "devices"


def _parse_mk(path: Path) -> dict[str, str]:
    """Parse a device.mk into a {KEY: VALUE} dict (make KEY = VALUE, '#' comments stripped)."""
    out: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line: str = raw.split("#", 1)[0].strip()   # drop inline/full-line comments
        if not line or "=" not in line:
            continue

        key, _, val = line.partition("=")
        out[key.strip()] = val.strip()

    return out


def load_manifests() -> dict[str, dict[str, str]]:
    """Return {device-name: {DEV_*: value}} for every devices/<name>/device.mk. Empty if none."""
    manifests: dict[str, dict[str, str]] = {}
    if not _DEVICES_DIR.is_dir():
        return manifests

    for mk in sorted(_DEVICES_DIR.glob("*/device.mk")):
        manifests[mk.parent.name] = _parse_mk(mk)

    return manifests


def _short_product(product: str) -> str | None:
    """The short unit id (P1_GND / P1_SKY) inside a full product_version (P1_GND_VR04 -> P1_GND)."""
    m = re.search(r"P1_(?:GND|SKY)", product or "")
    return m.group(0) if m else None


def role_map() -> dict[str, str]:
    """
    {short-product-id: rf-role} built from the manifests, e.g. {"P1_GND": "gnd", "P1_SKY": "air"}.

    Keyed on the SHORT id (what firmware.identify() returns from the on-device grep), derived from
    each manifest's DEV_PRODUCT; the role is DEV_RF_ROLE.
    """
    out: dict[str, str] = {}
    for m in load_manifests().values():
        short = _short_product(m.get("DEV_PRODUCT", ""))
        role = m.get("DEV_RF_ROLE", "")
        if short and role:
            out[short] = role

    return out
