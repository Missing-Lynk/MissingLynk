"""
Fetch and decode the goggle's display, on either firmware stack.

The two stacks put the picture in different places, so this module probes for the one in front of
it and takes the matching path:

**Vendor (`/dev/fb0`)** is a single ARGB4444 OSD overlay; the camera video is a separate hardware
layer that never appears in it. The buffer (`virtual_size` 1920x3240, `yres` 1080) is 3 stacked
1920x1080 pages, triple-buffered, and the visible OSD is in the displayed page, so page 0 is the
default. Rows are fetched with `dd`, so a default capture moves far less than the whole 13.3 MB.

**Open (DRM planes)** has no fb0. The video composite is scanned out on the primary plane as a
YUV420 (`YU12`) dmabuf and the HUD's OSD sits on an ARGB4444 (`AR12`) overlay plane, so a faithful
screenshot is the two composited in plane order. `native/ml-fbdump` enumerates and dumps them on
the device; this side decodes and composes, which is why the open path returns the video as well
as the OSD while the vendor path can only ever return the OSD.

Pixel formats. ARGB4444 is like ffmpeg's `rgb444le`: a little-endian u16 is (msb) 4A 4R 4G 4B
(lsb), and each 4-bit channel expands to 8-bit by replication (n*17, so 0xF -> 255 = true white).
The alpha nibble is dropped on the vendor path, which has nothing to compose against, and used as
the blend mask on the open path. YU12 is planar Y, then U, then V at half resolution in both axes.
Cross-platform: numpy + Pillow, no ffmpeg.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field

import numpy as np
from numpy.typing import NDArray
from PIL import Image

from .connection import Goggle
from .progress import ProgressCb, printer

# crop / region geometry: (x, y, w, h)
Region = tuple[int, int, int, int]

# the vendor buffer is 3 stacked full-screen pages (triple-buffered, see docstring)
PAGE_COUNT: int = 3

# where the DRM dumper is staged on the device; /tmp is exec-allowed tmpfs on the open rootfs
FBDUMP_REMOTE: str = "/tmp/ml-fbdump"


# --------------------------------------------------------------------------------------------
# pixel decoding
# --------------------------------------------------------------------------------------------

def decode_argb4444(raw: bytes, width: int, height: int, stride_px: int,
                    with_alpha: bool = False) -> NDArray[np.uint8]:
    """Decode ARGB4444 to RGB (or RGBA when `with_alpha`), cropping the stride padding away."""
    pixels: NDArray[np.uint16] = np.frombuffer(raw, dtype="<u2")
    needed: int = stride_px * height
    if pixels.size < needed:
        raise ValueError(f"short framebuffer: {pixels.size} u16 < {needed} expected")

    pixels = pixels[:needed].reshape(height, stride_px)[:, :width]
    red: NDArray[np.uint8] = ((pixels >> 8) & 0xF).astype(np.uint8) * 17
    green: NDArray[np.uint8] = ((pixels >> 4) & 0xF).astype(np.uint8) * 17
    blue: NDArray[np.uint8] = (pixels & 0xF).astype(np.uint8) * 17
    if not with_alpha:
        return np.dstack([red, green, blue])

    alpha: NDArray[np.uint8] = ((pixels >> 12) & 0xF).astype(np.uint8) * 17

    return np.dstack([red, green, blue, alpha])


def decode_yuv420(raw: bytes, width: int, height: int,
                  pitches: tuple[int, int, int],
                  offsets: tuple[int, int, int]) -> NDArray[np.uint8]:
    """Decode planar YU12 to RGB via BT.601, honouring each plane's own pitch and offset."""
    buf: NDArray[np.uint8] = np.frombuffer(raw, dtype=np.uint8)

    def plane(index: int, w: int, h: int) -> NDArray[np.uint8]:
        pitch, start = pitches[index], offsets[index]
        end: int = start + pitch * h
        if buf.size < end:
            raise ValueError(f"short plane {index}: {buf.size} B < {end} expected")

        return buf[start:end].reshape(h, pitch)[:, :w]

    luma: NDArray[np.int32] = plane(0, width, height).astype(np.int32)
    # chroma is quarter-size; repeat each sample over its 2x2 luma block
    u: NDArray[np.int32] = plane(1, width // 2, height // 2).astype(np.int32)
    v: NDArray[np.int32] = plane(2, width // 2, height // 2).astype(np.int32)
    u = np.repeat(np.repeat(u, 2, axis=0), 2, axis=1)[:height, :width]
    v = np.repeat(np.repeat(v, 2, axis=0), 2, axis=1)[:height, :width]

    c: NDArray[np.int32] = luma - 16
    d: NDArray[np.int32] = u - 128
    e: NDArray[np.int32] = v - 128
    red: NDArray[np.int32] = (298 * c + 409 * e + 128) >> 8
    green: NDArray[np.int32] = (298 * c - 100 * d - 208 * e + 128) >> 8
    blue: NDArray[np.int32] = (298 * c + 516 * d + 128) >> 8

    return np.dstack([np.clip(red, 0, 255), np.clip(green, 0, 255),
                      np.clip(blue, 0, 255)]).astype(np.uint8)


def compose_over(base: NDArray[np.uint8], overlay: NDArray[np.uint8]) -> NDArray[np.uint8]:
    """Alpha-composite an RGBA overlay onto an RGB base, both the same size."""
    alpha: NDArray[np.float32] = (overlay[:, :, 3].astype(np.float32) / 255.0)[:, :, None]
    blended: NDArray[np.float32] = (overlay[:, :, :3].astype(np.float32) * alpha
                                    + base.astype(np.float32) * (1.0 - alpha))

    return blended.round().clip(0, 255).astype(np.uint8)


# --------------------------------------------------------------------------------------------
# vendor stack: /dev/fb0
# --------------------------------------------------------------------------------------------

@dataclass
class FbGeometry:
    width: int      # visible width (1920)
    height: int     # full buffer height (3240 = 3 stacked 1080-row pages, triple-buffered)
    stride_px: int  # padded line width in pixels (2048)
    bpp: int        # bits per pixel (16)

    @property
    def stride_bytes(self) -> int:
        return self.stride_px * (self.bpp // 8)

    @property
    def page_height(self) -> int:
        return self.height // PAGE_COUNT


def read_geometry(goggle: Goggle) -> FbGeometry:
    virtual_size: str = goggle.read_file("/sys/class/graphics/fb0/virtual_size").decode().strip()
    width, height = (int(x) for x in virtual_size.replace(",", " ").split()[:2])
    bpp: int = int(goggle.read_file("/sys/class/graphics/fb0/bits_per_pixel").decode().strip())
    try:
        stride_bytes: int = int(
            goggle.read_file("/sys/class/graphics/fb0/stride").decode().strip())
        stride_px: int = stride_bytes // (bpp // 8)
    except Exception as e:
        raise RuntimeError(
            "could not read /sys/class/graphics/fb0/stride; cannot size the fetch") from e

    return FbGeometry(width=width, height=height, stride_px=stride_px, bpp=bpp)


def fetch_fb0(goggle: Goggle, page: int = 0, region: Region | None = None,
              full: bool = False, progress: bool = True) -> NDArray[np.uint8]:
    """
    Pull a region of fb0 via `dd` and return a decoded RGB array.

    `page` selects one of the PAGE_COUNT stacked full-screen pages (0 = the displayed one).
    `region` = (x, y, w, h) within that page; only rows [y, y+h) are transferred, then columns
    [x, x+w) are kept. `region=None` fetches the whole page. `full=True` fetches the entire raw
    buffer (all pages), ignoring `page` and `region`.
    """
    geometry: FbGeometry = read_geometry(goggle)
    if geometry.bpp != 16:
        raise RuntimeError(
            f"fb0 is {geometry.bpp} bpp, and this path decodes the vendor OSD's ARGB4444. "
            "On a DRM display capture the planes instead (see has_drm_scanout).")

    if full:
        first_row, row_count, x, w = 0, geometry.height, 0, geometry.width
        label: str = "fetch fb0 (full buffer)"
    else:
        if not 0 <= page < PAGE_COUNT:
            raise ValueError(f"page must be 0..{PAGE_COUNT - 1}")
        x, y, w, h = (0, 0, geometry.width, geometry.page_height) if region is None else region
        w = min(w, geometry.width - x)
        h = min(h, geometry.page_height - y)
        first_row, row_count = page * geometry.page_height + y, h
        label = f"fetch fb0 (page {page})"

    expected: int = row_count * geometry.stride_bytes
    command: str = (f"dd if=/dev/fb0 bs={geometry.stride_bytes} "
                    f"skip={first_row} count={row_count} 2>/dev/null")
    progress_cb: ProgressCb | None = printer(label) if progress else None
    raw: bytes = goggle.read_stream(command, expected_bytes=expected, on_progress=progress_cb)
    rgb: NDArray[np.uint8] = decode_argb4444(raw, geometry.width, row_count, geometry.stride_px)

    return rgb[:, x:x + w]


# --------------------------------------------------------------------------------------------
# open stack: DRM planes via ml-fbdump
# --------------------------------------------------------------------------------------------

@dataclass
class DrmPlane:
    plane_id: int
    kind: str                  # primary / overlay / cursor
    fourcc: str                # YU12, AR12, ...
    width: int
    height: int
    size: int
    pitches: dict[int, int] = field(default_factory=dict)
    offsets: dict[int, int] = field(default_factory=dict)

    @property
    def stride_px(self) -> int:
        """Padded line width in pixels, for the packed 16-bpp formats."""
        return self.pitches.get(0, self.width * 2) // 2


def _parse_plane_line(line: str) -> DrmPlane | None:
    fields: dict[str, str] = {}
    for token in line.split():
        key, _, value = token.partition("=")
        if value:
            fields[key] = value

    if "plane" not in fields or "format" not in fields:
        return None

    plane = DrmPlane(plane_id=int(fields["plane"]), kind=fields.get("kind", "unknown"),
                     fourcc=fields["format"], width=int(fields["width"]),
                     height=int(fields["height"]), size=int(fields["size"]))
    for index in range(4):
        if f"pitch{index}" in fields:
            plane.pitches[index] = int(fields[f"pitch{index}"])
            plane.offsets[index] = int(fields.get(f"offset{index}", 0))

    return plane


def stage_fbdump(goggle: Goggle, local_path: str | None = None) -> str:
    """
    Put ml-fbdump on the device and return its remote path.

    /tmp is a tmpfs wiped by every power cycle, so this re-stages when needed rather than
    assuming a previous session left it there.
    """
    _, _, status = goggle.run(f"test -x {FBDUMP_REMOTE}")
    if status == 0:
        return FBDUMP_REMOTE

    if local_path is None:
        repo: str = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        local_path = os.path.join(repo, "native", "build", "ml-fbdump")

    try:
        with open(local_path, "rb") as handle:
            binary: bytes = handle.read()
    except OSError as e:
        raise RuntimeError(
            f"ml-fbdump not built at {local_path}; run `make native` (it is in BRINGUP_TOOLS)"
        ) from e

    goggle.write_file(FBDUMP_REMOTE, binary)
    goggle.run(f"chmod +x {FBDUMP_REMOTE}")

    return FBDUMP_REMOTE


def list_planes(goggle: Goggle) -> list[DrmPlane]:
    """The active scanout planes, in DRM plane order (primary first, overlays above it)."""
    remote: str = stage_fbdump(goggle)
    out, err, status = goggle.run(f"{remote} --list")
    if status != 0:
        raise RuntimeError(f"ml-fbdump --list failed: {err.decode(errors='replace').strip()}")

    planes: list[DrmPlane] = []
    for line in out.decode(errors="replace").splitlines():
        plane = _parse_plane_line(line)
        if plane is not None:
            planes.append(plane)

    return planes


def _decode_plane(plane: DrmPlane, raw: bytes) -> NDArray[np.uint8]:
    """One plane's bytes as RGB (primary) or RGBA (overlay), by its DRM fourcc."""
    if plane.fourcc == "YU12":
        return decode_yuv420(raw, plane.width, plane.height,
                             (plane.pitches.get(0, plane.width),
                              plane.pitches.get(1, plane.width // 2),
                              plane.pitches.get(2, plane.width // 2)),
                             (plane.offsets.get(0, 0), plane.offsets.get(1, 0),
                              plane.offsets.get(2, 0)))

    if plane.fourcc in ("AR12", "AB12", "XR12"):
        return decode_argb4444(raw, plane.width, plane.height, plane.stride_px,
                               with_alpha=plane.fourcc[0] == "A")

    raise RuntimeError(f"plane {plane.plane_id}: unsupported DRM format {plane.fourcc}")


def fetch_drm(goggle: Goggle, region: Region | None = None, progress: bool = True,
              planes: list[DrmPlane] | None = None) -> NDArray[np.uint8]:
    """
    Dump every active plane, decode each by its own format, and compose them bottom-up.

    `planes` accepts a listing the caller already has, so probing which stack this is does not
    cost a second enumeration round trip.
    """
    remote: str = stage_fbdump(goggle)
    if planes is None:
        planes = list_planes(goggle)

    if not planes:
        raise RuntimeError("no active DRM planes; is the display up?")

    frame: NDArray[np.uint8] | None = None
    for plane in planes:
        label: str = f"fetch plane {plane.plane_id} ({plane.kind}, {plane.fourcc})"
        progress_cb: ProgressCb | None = printer(label) if progress else None
        raw: bytes = goggle.read_stream(f"{remote} --dump {plane.plane_id}",
                                        expected_bytes=plane.size, on_progress=progress_cb)
        decoded: NDArray[np.uint8] = _decode_plane(plane, raw)

        if frame is None:
            # the bottom-most plane is the base; an overlay arriving first loses its alpha
            frame = decoded[:, :, :3] if decoded.shape[2] == 4 else decoded
        elif decoded.shape[2] == 4:
            frame = compose_over(frame, decoded)
        else:
            frame = decoded

    assert frame is not None
    if region is not None:
        x, y, w, h = region
        frame = frame[y:y + h, x:x + w]

    return frame


# --------------------------------------------------------------------------------------------
# dispatch
# --------------------------------------------------------------------------------------------

def drm_scanout(goggle: Goggle) -> list[DrmPlane]:
    """
    The active DRM planes, or an empty list when this device is not driven through DRM.

    The presence of /dev/fb0 does not decide which path to take: the open stack's kernel builds
    fbdev emulation, so it grows an fb0 of its own (1920x1080 XRGB8888) that is not what the
    compositor scans out, and reading it yields a stale or blank frame rather than the picture on
    the panel. An active plane is the signal that DRM owns the display, so that is what gets
    asked, and the answer doubles as the listing the capture then works from.
    """
    _, _, status = goggle.run("test -e /dev/dri/card0")
    if status != 0:
        return []

    try:
        return list_planes(goggle)
    except RuntimeError:
        return []


def fetch(goggle: Goggle, page: int = 0, region: Region | None = None,
          full: bool = False, progress: bool = True) -> NDArray[np.uint8]:
    """Capture the display, taking whichever path this device's stack provides."""
    planes: list[DrmPlane] = drm_scanout(goggle)
    if planes:
        return fetch_drm(goggle, region=region, progress=progress, planes=planes)

    return fetch_fb0(goggle, page=page, region=region, full=full, progress=progress)


def capture(goggle: Goggle, out_path: str, page: int = 0,
            region: Region | None = None, full: bool = False,
            progress: bool = True) -> str:
    rgb: NDArray[np.uint8] = fetch(goggle, page=page, region=region, full=full,
                                   progress=progress)
    Image.fromarray(rgb, "RGB").save(out_path)

    return out_path
