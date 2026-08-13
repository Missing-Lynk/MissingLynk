"""
.mlimg bundle assembly and per-device vendor-blob scoping.

The scoping is the safety-critical part: without it, an air-unit build with only
goggle blobs present would silently ship goggle uboot/env in a P1_SKY bundle.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "glue" / "flash"))

from mlimg import FORMAT_VERSION, MLIMG_COMPONENTS, resolve_blob  # noqa: E402


def test_python_bundle_layout_matches_native_flasher_allowlist() -> None:
    source = (REPO / "native" / "mlflash" / "src" / "mlimg.c").read_text()
    rows = re.findall(
        r'\{\s*"([^"]+)",\s*"([^"]+)",\s*"([^"]+)",\s*"([^"]+)",\s*"([^"]+)"\s*\}',
        source,
    )

    assert rows == [
        (component["name"], component["role"], component["target"], component["method"],
         component["file"])
        for component in MLIMG_COMPONENTS
    ]


def test_python_format_version_matches_native_flasher() -> None:
    header = (REPO / "native" / "mlflash" / "src" / "mlimg.h").read_text()
    match = re.search(r"^#define\s+MLIMG_FORMAT_VERSION\s+(\d+)$", header, re.MULTILINE)

    assert match is not None
    assert int(match.group(1)) == FORMAT_VERSION


def test_resolve_blob_prefers_explicit_path(tmp_path: Path) -> None:
    explicit = tmp_path / "my-uboot.bin"
    explicit.write_bytes(b"explicit")

    assert resolve_blob(str(explicit), str(tmp_path), ["*.bin"], "uboot") == str(explicit)


def test_resolve_blob_finds_first_matching_pattern(tmp_path: Path) -> None:
    (tmp_path / "env.bin").write_bytes(b"env")
    (tmp_path / "env0.bin").write_bytes(b"env0")

    # patterns are in order: "env.bin" wins over "*env0.bin"
    assert resolve_blob(None, str(tmp_path), ["env.bin", "*env0.bin"], "env").endswith("env.bin")


def test_resolve_blob_scopes_to_the_device_subdir(tmp_path: Path) -> None:
    """A P1_SKY build must not see P1_GND blobs in a sibling directory."""
    goggle_dir = tmp_path / "P1_GND"
    air_dir = tmp_path / "P1_SKY"
    goggle_dir.mkdir()
    air_dir.mkdir()
    (goggle_dir / "mtd11-uboot0.bin").write_bytes(b"goggle uboot")
    (air_dir / "mtd11-uboot0.bin").write_bytes(b"air uboot")

    found = resolve_blob(None, str(air_dir), ["uboot.bin", "*uboot0.bin", "*uboot1.bin"], "uboot")

    assert found == str(air_dir / "mtd11-uboot0.bin")


def test_resolve_blob_fails_loudly_when_device_blobs_missing(tmp_path: Path) -> None:
    """An air build with only goggle blobs must error, not grab the goggle's bytes."""
    goggle_dir = tmp_path / "P1_GND"
    air_dir = tmp_path / "P1_SKY"
    goggle_dir.mkdir()
    air_dir.mkdir()
    (goggle_dir / "mtd11-uboot0.bin").write_bytes(b"goggle uboot")

    with pytest.raises(SystemExit, match="uboot"):
        resolve_blob(None, str(air_dir), ["uboot.bin", "*uboot0.bin", "*uboot1.bin"], "uboot")


def test_resolve_blob_error_names_the_device_subdir(tmp_path: Path) -> None:
    air_dir = tmp_path / "P1_SKY"
    air_dir.mkdir()

    with pytest.raises(SystemExit, match=str(air_dir)):
        resolve_blob(None, str(air_dir), ["uboot.bin", "*uboot0.bin"], "uboot")
