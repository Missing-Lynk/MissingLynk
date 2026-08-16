"""
Guard `kernel/scripts/isp/blob-layout.toml`, the one place a tuning-blob offset is written down.

These check the mapping's internal consistency and its agreement with the kernel's defines, with
no blob present. Checks that need bytes live in kernel/scripts/isp/check-blob-layout.py.
"""

import importlib.util
import re
import sys
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parents[1]
ISP = ROOT / "kernel" / "scripts" / "isp"
DRIVER = ROOT / "kernel" / "overlay" / "drivers" / "media" / "artosyn"
GENERATED = DRIVER / "vendor-tables" / "ar-isp-blob.h"

pytestmark = pytest.mark.skipif(
    not (ISP / "blob-layout.toml").exists(), reason="kernel submodule not checked out"
)


def load_layout_module() -> ModuleType:
    path = ISP / "blob_layout.py"
    spec = importlib.util.spec_from_file_location("blob_layout", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["blob_layout"] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def layout() -> object:
    return load_layout_module().Layout.load()


def kernel_blob_defines() -> dict[str, int]:
    """Absolute blob offsets the driver defines, excluding strides and header displacements.

    Only *_BLOB_* names qualify: AR_ISP_HDR_SIZE and AR_ISP_TABLE_HDR* are register-space and
    AR_ISP_VENDOR_HDR_LSC_PHYS is a physical address.
    """
    skip = ("STRIDE", "BANKS_USED", "ILLUMINANTS", "ENTRIES", "CURVES", "PROFILES", "BANK1",
            "BANK_STRIDE")
    out: dict[str, int] = {}
    for header in DRIVER.glob("*.h"):
        for name, value in re.findall(
            r"#define\s+(AR_ISP_\w*_BLOB_\w*)\s+(0x[0-9a-fA-F]+)", header.read_text()
        ):
            if any(k in name for k in skip):
                continue

            out[name] = int(value, 16)

    return out


def test_layout_loads_and_is_populated(layout) -> None:
    assert len(layout) >= 71
    assert layout.size == 0xD6C58
    assert set(layout.sensors) == {"nt99235", "sc231", "sc2210"}


def test_no_section_runs_past_the_end(layout) -> None:
    for section in layout:
        assert section.end <= layout.size, f"{section.name} ends at {section.end:#x}"


def test_every_offset_is_word_aligned(layout) -> None:
    """Every offset and stride in the file is 4-byte aligned."""
    for section in layout:
        assert section.offset % 4 == 0, f"{section.name} at {section.offset:#x}"
        if section.stride is not None and section.kind != "record_array":
            assert section.stride % 4 == 0, f"{section.name} stride {section.stride:#x}"


def test_sized_kinds_carry_what_they_need(layout) -> None:
    for section in layout:
        if section.kind in ("record_array", "payload", "page"):
            assert section.count and section.stride, f"{section.name} needs count and stride"
        elif section.kind in ("array", "bands"):
            assert section.count and section.elem, f"{section.name} needs count and elem"
        elif section.kind == "opaque":
            assert section.length, f"{section.name} needs a length"


def test_kernel_defines_all_appear_in_the_layout(layout) -> None:
    """Every absolute blob offset the driver hardcodes is in the mapping."""
    missing = {
        name: value
        for name, value in kernel_blob_defines().items()
        if not layout.at(value)
    }
    assert not missing, "kernel defines absent from blob-layout.toml: " + ", ".join(
        f"{n}={v:#x}" for n, v in sorted(missing.items())
    )


def test_relative_header_fields_resolve_to_absolute_offsets(layout) -> None:
    """C builds 0x79e0 from a base plus a displacement, so a grep for it finds nothing."""
    assert layout["rnr_header"].field_offset("mode") == 0x79E0
    assert layout["rnr_header"].field_offset("count") == 0x79E4
    assert [s.name for s in layout.at(0x79E0)] == ["rnr_header"]


def test_anchors_are_ascending_and_cover_every_gate(layout) -> None:
    offsets = [off for _, off in layout.anchors()]
    assert offsets == sorted(offsets)
    assert len(set(offsets)) == len(offsets)
    for gate in layout.gates():
        assert gate.offset in offsets, f"{gate.name} is not an anchor"


def test_the_ae_block_is_present(layout) -> None:
    """The six sections ml-aed reads."""
    assert layout["ae_exposure_table"].offset == 0xB6524
    assert layout["ae_exposure_table"].count == 366
    assert layout["ae_exposure_table"].size == 366 * 8
    for name in ("ae_target_curve", "ae_zone_weights", "ae_damping", "ae_tolerance",
                 "ae_log_ladder"):
        assert name in layout


def test_sections_have_unique_names(layout) -> None:
    names = [s.name for s in layout]
    assert len(names) == len(set(names))


def test_generated_header_matches_the_layout() -> None:
    """Catches a hand edit to ar-isp-blob.h, or a layout change without a regenerate."""
    import subprocess

    result = subprocess.run(
        [sys.executable, str(ISP / "gen-blob-header.py"), "--check"],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_userspace_header_matches_the_layout() -> None:
    """ml-aed lives in another repo and carries a generated copy of the AE offsets."""
    import subprocess

    result = subprocess.run(
        [sys.executable, str(ISP / "gen-blob-header.py"), "--userspace", "--check"],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_ml_aed_bakes_no_tuning_values() -> None:
    """No ml-aed build artifact carries a value the blob owns."""
    aed = ROOT / "userspace" / "ml-aed"
    if not aed.exists():
        pytest.skip("userspace submodule not checked out")

    assert not (aed / "ml-aed-exptable.h").exists(), "the baked exposure table is back"

    # Comments are stripped: they quote the vendor's numbers without using them.
    source = (aed / "ml-aed-core.h").read_text() + (aed / "ml-aed-core.c").read_text()
    code = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    for baked in ("77.893997", "AE_TOLERANCE", "AE_LOG_LADDER", "AE_DAMPING"):
        assert baked not in code, f"{baked} is baked into ml-aed again"


def test_no_stage_header_redefines_a_generated_macro() -> None:
    """One definition per offset. `--check` enforces it too; this names the offender."""
    generated = set(
        re.findall(r"#define\s+(AR_ISP_\w+)", GENERATED.read_text())
    ) - {"AR_ISP_BLOB_H"}
    assert generated, "ar-isp-blob.h defines nothing; it was not generated"

    for header in list(DRIVER.glob("*.h")) + list((DRIVER / "vendor-tables").glob("*.h")):
        if header == GENERATED:
            continue

        clash = generated & set(re.findall(r"#define\s+(AR_ISP_\w+)", header.read_text()))
        assert not clash, f"{header.name} redefines {sorted(clash)}"


# Three places name the tuning file and must agree: board.conf stages it, the DTB tells ar-isp
# what to request, the init script tells ml-aed what to read.

BOARD = ROOT / "rootfs" / "devices" / "betafpv-vr04-air"
DTS = ROOT / "kernel" / "devices" / "betafpv-vr04-air" / "proxima-9311-air.dts"


def board_tuning_name() -> str:
    conf = (BOARD / "board.conf").read_text()
    match = re.search(r'^ISP_TUNING_NAME="([^"]+)"', conf, re.M)
    assert match, "board.conf has no ISP_TUNING_NAME"

    return match.group(1)


@pytest.mark.skipif(not BOARD.exists() or not DTS.exists(), reason="submodules not checked out")
def test_dtb_property_matches_the_staged_firmware_name() -> None:
    """ar-isp request_firmware()s what the DTB names."""
    match = re.search(r'artosyn,tuning-firmware\s*=\s*"([^"]+)"', DTS.read_text())
    assert match, "the air DTS does not set artosyn,tuning-firmware"
    assert match.group(1) == f"artosyn/{board_tuning_name()}"


@pytest.mark.skipif(not BOARD.exists(), reason="rootfs submodule not checked out")
def test_init_script_tuning_path_matches_the_staged_firmware_name() -> None:
    """ml-aed reads its AE constants from the path the init script passes."""
    init = (BOARD / "overlay" / "etc" / "init.d" / "ml-air-ae").read_text()
    match = re.search(r"^TUNING=(\S+)", init, re.M)
    assert match, "the ml-air-ae init script does not set TUNING"
    assert match.group(1) == f"/lib/firmware/artosyn/{board_tuning_name()}"


@pytest.mark.skipif(not BOARD.exists(), reason="rootfs submodule not checked out")
def test_board_config_does_not_restate_the_blob_size() -> None:
    """The size is a property of the file format; it lives in the layout."""
    assert "ISP_TUNING_SIZE=" not in (BOARD / "board.conf").read_text()


# ---------------------------------------------------------------------------
# The layout is only a single source while every consumer reads it. This is the guard: a script
# that hardcodes an offset the layout already names has forked the mapping.
# ---------------------------------------------------------------------------

SCRIPT_DIRS = (ROOT / "kernel" / "scripts" / "isp", ROOT / "glue" / "isp")

# Below this, an offset collides with register displacements and struct field sizes that have
# nothing to do with the blob.
MIN_OFFSET = 0x1000


def code_hex_literals(path: Path) -> set[int]:
    """Hex literals in code, with comments and string literals removed.

    Prose citing an offset is a record of how it was recovered, not a second definition of it.
    """
    import io
    import tokenize

    out: set[int] = set()
    with path.open("rb") as fh:
        for tok in tokenize.tokenize(io.BytesIO(fh.read()).readline):
            if tok.type == tokenize.NUMBER and tok.string.lower().startswith("0x"):
                out.add(int(tok.string, 16))

    return out


@pytest.mark.skipif(not SCRIPT_DIRS[0].exists(), reason="kernel submodule not checked out")
def test_no_script_hardcodes_an_offset_the_layout_names(layout) -> None:
    named: dict[int, str] = {}
    for section in layout:
        named.setdefault(section.offset, section.name)
        for field in section.fields:
            named.setdefault(section.field_offset(field), f"{section.name}.{field}")

    offenders: dict[str, list[str]] = {}
    for directory in SCRIPT_DIRS:
        if not directory.exists():
            continue

        for script in sorted(directory.glob("*.py")):
            if script.name == "blob_layout.py":
                continue

            source = script.read_text()
            if "blob_layout" in source:
                continue

            hits = sorted(
                v for v in code_hex_literals(script) if v >= MIN_OFFSET and v in named
            )
            if hits:
                offenders[script.name] = [f"{v:#x} is {named[v]}" for v in hits]

    assert not offenders, "scripts carrying their own copy of a layout offset: " + "; ".join(
        f"{name} ({', '.join(hits)})" for name, hits in sorted(offenders.items())
    )
