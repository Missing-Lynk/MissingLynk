"""
The stage-8 heap extractor: page geometry, pointer walk, and the CLI on a synthetic heap.

A real frozen dump is a capture artifact and is not in the repository, so the heap here is
built to spec: noise that cannot satisfy the page geometry, one well-formed page, and one
pointer to it sitting at the ltm_ctx output slot, which is how the extractor is expected to
find the context.
"""

from __future__ import annotations

import importlib.util
import struct
import subprocess
import sys
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "kernel" / "scripts" / "isp" / "ltm-frozen-extract.py"

pytestmark = pytest.mark.skipif(not SCRIPT.exists(), reason="kernel submodule not checked out")

HEAP_BASE = 0x50C000
PAGE_OFF = 0x8000
CTX_OFF = 0x40000


def load_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("ltm_frozen_extract", SCRIPT)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    return mod


def make_page() -> bytes:
    """64 tiles of the identity ramp i * 8, the shape ltm_page_b.bin validated."""
    tile = struct.pack("<128H", *(i * 8 for i in range(128)))
    assert len(tile) == 0x100

    return tile * 64


def make_heap(mod: ModuleType) -> bytearray:
    heap = bytearray(b"\xff" * 0x50000)
    heap[PAGE_OFF:PAGE_OFF + mod.PAGE_SIZE] = make_page()
    ptr_off = CTX_OFF + mod.CTX_OUTPUT_OFF
    heap[ptr_off:ptr_off + 8] = struct.pack("<Q", HEAP_BASE + PAGE_OFF)
    # Recognisable input-window fields at ltm_ctx+1320.
    win = CTX_OFF + mod.CTX_INPUT_OFF
    heap[win:win + 8] = struct.pack("<2I", 0x11111111, 0x22222222)

    return heap


def test_page_geometry() -> None:
    mod = load_module()
    heap = bytes(make_heap(mod))

    assert mod.is_page_at(heap, PAGE_OFF)
    assert not mod.is_page_at(heap, PAGE_OFF + 8)
    assert not mod.is_page_at(heap, 0)


def test_find_pages_and_pointers() -> None:
    mod = load_module()
    heap = bytes(make_heap(mod))

    assert mod.find_pages(heap) == [PAGE_OFF]
    assert mod.find_pointers(heap, HEAP_BASE, PAGE_OFF) == [CTX_OFF + mod.CTX_OUTPUT_OFF]
    assert mod.find_pointers(heap, HEAP_BASE, PAGE_OFF + 0x100) == []


def test_a_torn_page_is_rejected() -> None:
    """One non-monotonic sample anywhere kills the page, which is the tear signature."""
    mod = load_module()
    heap = make_heap(mod)
    bad = PAGE_OFF + 37 * mod.STRIDE + 64 * 2
    heap[bad:bad + 2] = struct.pack("<H", 0)

    assert mod.find_pages(bytes(heap)) == []


def test_cli_writes_page_and_ctx(tmp_path: Path) -> None:
    mod = load_module()
    dump = tmp_path / "ltm-frozen-1.bin"
    dump.write_bytes(bytes(make_heap(mod)))
    maps = tmp_path / "ltm-frozen-maps.txt"
    maps.write_text(
        f"{HEAP_BASE:x}-{HEAP_BASE + 0x50000:x} rw-p 00000000 00:00 0          [heap]\n")

    run = subprocess.run(
        [sys.executable, str(SCRIPT), str(dump), "--maps", str(maps)],
        capture_output=True, text=True, check=True)

    assert f"page 0: offset {PAGE_OFF:#x}" in run.stdout
    assert f"ltm_ctx candidate {CTX_OFF:#x}" in run.stdout
    page = tmp_path / "ltm-frozen-1.page0.bin"
    assert page.read_bytes() == make_page()
    ctx = tmp_path / "ltm-frozen-1.ctx0.txt"
    assert "11111111 22222222" in ctx.read_text()


def test_no_page_exits_nonzero(tmp_path: Path) -> None:
    dump = tmp_path / "ltm-frozen-1.bin"
    dump.write_bytes(b"\xff" * 0x20000)
    maps = tmp_path / "maps.txt"
    maps.write_text(f"{HEAP_BASE:x}-{HEAP_BASE + 0x20000:x} rw-p 00000000 00:00 0  [heap]\n")

    run = subprocess.run(
        [sys.executable, str(SCRIPT), str(dump), "--maps", str(maps)],
        capture_output=True, text=True)

    assert run.returncode != 0
    assert "no well-formed LTM page" in run.stderr
