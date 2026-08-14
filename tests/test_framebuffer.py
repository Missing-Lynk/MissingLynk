"""
Framebuffer geometry, ARGB4444 decode, and the fetch window the `dd` command asks for.

The decode and the row arithmetic are the parts that fail silently: a wrong stride or page offset
still produces a plausible PNG, just of the wrong pixels. The sysfs reads and the `dd` are served
by FakeGoggle, so this needs no device.
"""
from __future__ import annotations

import numpy as np
import pytest

from missinglynk import framebuffer
from missinglynk.framebuffer import FbGeometry, decode_argb4444

from .conftest import FakeGoggle

# The goggle's real fb0: 1920 visible px on a 2048 px stride, 3 stacked 1080-row pages.
WIDTH = 1920
STRIDE_PX = 2048
PAGE_HEIGHT = 1080


@pytest.fixture
def fb_goggle(goggle: FakeGoggle) -> FakeGoggle:
    goggle.add_file("/sys/class/graphics/fb0/virtual_size", b"1920,3240\n")
    goggle.add_file("/sys/class/graphics/fb0/bits_per_pixel", b"16\n")
    goggle.add_file("/sys/class/graphics/fb0/stride", b"4096\n")
    return goggle


# --- geometry ---

def test_geometry_derives_the_byte_stride_and_page_height() -> None:
    geometry = FbGeometry(width=WIDTH, height=3240, stride_px=STRIDE_PX, bpp=16)

    assert geometry.stride_bytes == 4096
    assert geometry.page_height == PAGE_HEIGHT


def test_read_geometry_parses_the_sysfs_files(fb_goggle: FakeGoggle) -> None:
    geometry = framebuffer.read_geometry(fb_goggle)

    assert (geometry.width, geometry.height) == (WIDTH, 3240)
    assert geometry.stride_px == STRIDE_PX
    assert geometry.bpp == 16


def test_read_geometry_fails_loudly_without_the_stride(goggle: FakeGoggle) -> None:
    """Without the stride the fetch size is a guess; a wrong guess silently shears the image."""
    goggle.add_file("/sys/class/graphics/fb0/virtual_size", b"1920,3240\n")
    goggle.add_file("/sys/class/graphics/fb0/bits_per_pixel", b"16\n")

    with pytest.raises(RuntimeError, match="stride"):
        framebuffer.read_geometry(goggle)


# --- decode ---

def make_raw(pixels: list[int], stride_px: int, height: int) -> bytes:
    """Pack `pixels` as the first values of each row of a stride_px-wide, height-row buffer."""
    buffer = np.zeros(stride_px * height, dtype="<u2")
    buffer[:len(pixels)] = pixels
    return buffer.tobytes()


def test_decode_expands_each_nibble_to_a_full_byte() -> None:
    """0xF must decode to 255, not 240, or white is never white."""
    raw = make_raw([0x0FFF, 0x0F00, 0x00F0, 0x000F, 0x0000], stride_px=8, height=1)
    rgb = decode_argb4444(raw, width=5, height=1, stride_px=8)

    assert rgb.shape == (1, 5, 3)
    assert list(rgb[0, 0]) == [255, 255, 255]
    assert list(rgb[0, 1]) == [255, 0, 0]
    assert list(rgb[0, 2]) == [0, 255, 0]
    assert list(rgb[0, 3]) == [0, 0, 255]
    assert list(rgb[0, 4]) == [0, 0, 0]


def test_decode_ignores_the_alpha_nibble() -> None:
    """The alpha nibble varies with what drew the overlay; it must not tint the RGB."""
    opaque = decode_argb4444(make_raw([0xF123], 4, 1), width=1, height=1, stride_px=4)
    transparent = decode_argb4444(make_raw([0x0123], 4, 1), width=1, height=1, stride_px=4)

    assert np.array_equal(opaque, transparent)


def test_decode_drops_the_stride_padding() -> None:
    """Columns past the visible width are padding; keeping them would skew every row."""
    raw = make_raw([0x0F00, 0x000F, 0x00F0, 0x0FFF], stride_px=2, height=2)
    rgb = decode_argb4444(raw, width=1, height=2, stride_px=2)

    assert rgb.shape == (2, 1, 3)
    assert list(rgb[0, 0]) == [255, 0, 0]
    assert list(rgb[1, 0]) == [0, 255, 0]


def test_decode_rejects_a_short_buffer() -> None:
    """A truncated transfer must raise, not decode garbage into the tail of the image."""
    with pytest.raises(ValueError, match="short framebuffer"):
        decode_argb4444(make_raw([0], 8, 1), width=8, height=4, stride_px=8)


# --- fetch window ---

def fetch_with(goggle: FakeGoggle, **kwargs) -> str:
    """Run fetch() against a zero-filled buffer and return the dd command it issued."""
    rows = 3240 if kwargs.get("full") else PAGE_HEIGHT
    goggle.canned("dd if=/dev/fb0", b"\x00" * (4096 * rows))
    framebuffer.fetch(goggle, progress=False, **kwargs)

    return next(command for command in goggle.commands if command.startswith("dd "))


def test_fetch_reads_a_whole_page_by_default(fb_goggle: FakeGoggle) -> None:
    command = fetch_with(fb_goggle)

    assert "bs=4096" in command
    assert "skip=0" in command
    assert f"count={PAGE_HEIGHT}" in command


def test_fetch_skips_to_the_requested_page(fb_goggle: FakeGoggle) -> None:
    command = fetch_with(fb_goggle, page=2)

    assert f"skip={2 * PAGE_HEIGHT}" in command
    assert f"count={PAGE_HEIGHT}" in command


def test_fetch_transfers_only_the_rows_a_region_needs(fb_goggle: FakeGoggle) -> None:
    """The point of the region path: a small crop must not pull the whole 13 MB buffer."""
    command = fetch_with(fb_goggle, region=(100, 200, 300, 400))

    assert "skip=200" in command
    assert "count=400" in command


def test_fetch_offsets_a_region_by_the_page(fb_goggle: FakeGoggle) -> None:
    command = fetch_with(fb_goggle, page=1, region=(0, 50, 100, 10))

    assert f"skip={PAGE_HEIGHT + 50}" in command
    assert "count=10" in command


def test_fetch_crops_columns_after_the_transfer(fb_goggle: FakeGoggle) -> None:
    fb_goggle.canned("dd if=/dev/fb0", b"\x00" * (4096 * 400))
    rgb = framebuffer.fetch(fb_goggle, region=(100, 200, 300, 400), progress=False)

    assert rgb.shape == (400, 300, 3)


def test_fetch_clamps_a_region_that_runs_off_the_page(fb_goggle: FakeGoggle) -> None:
    """An over-wide crop is clamped to the panel rather than reading past the visible area."""
    fb_goggle.canned("dd if=/dev/fb0", b"\x00" * (4096 * PAGE_HEIGHT))
    rgb = framebuffer.fetch(fb_goggle, region=(0, 0, 9999, 9999), progress=False)

    assert rgb.shape == (PAGE_HEIGHT, WIDTH, 3)


def test_fetch_full_reads_every_page(fb_goggle: FakeGoggle) -> None:
    command = fetch_with(fb_goggle, full=True)

    assert "skip=0" in command
    assert "count=3240" in command


def test_fetch_rejects_a_page_outside_the_buffer(fb_goggle: FakeGoggle) -> None:
    with pytest.raises(ValueError, match="page must be"):
        framebuffer.fetch(fb_goggle, page=framebuffer.PAGE_COUNT, progress=False)


# --- DRM plane path (open stack) ---

PLANE_LIST = (
    b"plane=33 crtc=35 kind=primary fb=58 format=YU12 width=4 height=2 size=12 "
    b"pitch0=4 offset0=0 pitch1=2 offset1=8 pitch2=2 offset2=10\n"
    b"plane=38 crtc=35 kind=overlay fb=49 format=AR12 width=4 height=2 size=16 "
    b"pitch0=8 offset0=0\n"
)


@pytest.fixture
def drm_goggle(goggle: FakeGoggle) -> FakeGoggle:
    """A device driven through DRM, with ml-fbdump already staged."""
    goggle.add_file("/dev/dri/card0", b"")
    goggle.add_file(framebuffer.FBDUMP_REMOTE, b"binary")
    goggle.canned("--list", PLANE_LIST)
    return goggle


def test_plane_line_parses_every_plane_of_a_multi_planar_format() -> None:
    plane = framebuffer._parse_plane_line(PLANE_LIST.decode().splitlines()[0])

    assert plane is not None
    assert (plane.plane_id, plane.kind, plane.fourcc) == (33, "primary", "YU12")
    assert plane.pitches == {0: 4, 1: 2, 2: 2}
    assert plane.offsets == {0: 0, 1: 8, 2: 10}


def test_plane_line_ignores_noise() -> None:
    assert framebuffer._parse_plane_line("ml-fbdump: universal planes unavailable") is None


def test_list_planes_returns_them_in_scanout_order(drm_goggle: FakeGoggle) -> None:
    planes = framebuffer.list_planes(drm_goggle)

    assert [p.kind for p in planes] == ["primary", "overlay"]


def test_yuv420_decodes_a_known_colour() -> None:
    """Y=81 U=90 V=240 is BT.601 red; a swapped U/V plane would come back blue."""
    raw = bytes([81] * 8) + bytes([90] * 2) + bytes([240] * 2)
    rgb = framebuffer.decode_yuv420(raw, 4, 2, (4, 2, 2), (0, 8, 10))

    assert rgb.shape == (2, 4, 3)
    assert rgb[0, 0][0] > 200
    assert rgb[0, 0][1] < 60
    assert rgb[0, 0][2] < 60


def test_yuv420_rejects_a_short_buffer() -> None:
    with pytest.raises(ValueError, match="short plane"):
        framebuffer.decode_yuv420(b"\x00" * 4, 4, 2, (4, 2, 2), (0, 8, 10))


def test_argb4444_keeps_alpha_when_asked() -> None:
    """The overlay's alpha is the blend mask; dropping it would paste a black box over video."""
    rgba = decode_argb4444(make_raw([0xF00F, 0x000F], 2, 1), width=2, height=1, stride_px=2,
                           with_alpha=True)

    assert rgba.shape == (1, 2, 4)
    assert rgba[0, 0][3] == 255
    assert rgba[0, 1][3] == 0


def test_compose_leaves_the_base_where_the_overlay_is_transparent() -> None:
    base = np.full((1, 2, 3), 10, dtype=np.uint8)
    overlay = np.zeros((1, 2, 4), dtype=np.uint8)
    overlay[0, 0] = [255, 255, 255, 255]      # opaque white
    overlay[0, 1] = [255, 255, 255, 0]        # fully transparent

    composed = framebuffer.compose_over(base, overlay)

    assert list(composed[0, 0]) == [255, 255, 255]
    assert list(composed[0, 1]) == [10, 10, 10]


def test_fetch_composes_the_overlay_onto_the_primary(drm_goggle: FakeGoggle) -> None:
    drm_goggle.canned("--dump 33", bytes([81] * 8) + bytes([90] * 2) + bytes([240] * 2))
    # an overlay that is opaque white in its first pixel and transparent everywhere else
    overlay = np.zeros(8, dtype="<u2")
    overlay[0] = 0xFFFF
    drm_goggle.canned("--dump 38", overlay.tobytes())

    rgb = framebuffer.fetch(drm_goggle, progress=False)

    assert rgb.shape == (2, 4, 3)
    assert list(rgb[0, 0]) == [255, 255, 255]     # overlay won here
    assert rgb[0, 1][0] > 200                     # video shows through here


def test_fetch_prefers_drm_even_when_fbdev_emulation_exists(drm_goggle: FakeGoggle) -> None:
    """The open kernel grows an emulated fb0 that is not the scanout; DRM must still win."""
    drm_goggle.add_file("/sys/class/graphics/fb0/virtual_size", b"1920,1080\n")
    drm_goggle.add_file("/sys/class/graphics/fb0/bits_per_pixel", b"32\n")
    drm_goggle.add_file("/sys/class/graphics/fb0/stride", b"8192\n")
    drm_goggle.canned("--dump 33", bytes([81] * 8) + bytes([90] * 2) + bytes([240] * 2))
    drm_goggle.canned("--dump 38", b"\x00" * 16)

    framebuffer.fetch(drm_goggle, progress=False)

    assert not any(command.startswith("dd ") for command in drm_goggle.commands)


def test_fetch_falls_back_to_fb0_without_a_drm_node(fb_goggle: FakeGoggle) -> None:
    """Vendor firmware has no card0, so the capture must go through the OSD framebuffer."""
    fb_goggle.canned("dd if=/dev/fb0", b"\x00" * (4096 * PAGE_HEIGHT))

    framebuffer.fetch(fb_goggle, progress=False)

    assert any(command.startswith("dd ") for command in fb_goggle.commands)


def test_fb0_path_refuses_a_buffer_that_is_not_the_vendor_osd(goggle: FakeGoggle) -> None:
    """A 32-bpp fb0 is the emulated one; decoding it as ARGB4444 would return garbage."""
    goggle.add_file("/sys/class/graphics/fb0/virtual_size", b"1920,1080\n")
    goggle.add_file("/sys/class/graphics/fb0/bits_per_pixel", b"32\n")
    goggle.add_file("/sys/class/graphics/fb0/stride", b"8192\n")

    with pytest.raises(RuntimeError, match="bpp"):
        framebuffer.fetch_fb0(goggle, progress=False)
