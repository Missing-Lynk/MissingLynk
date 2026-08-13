#!/usr/bin/env python3
"""Run the vendor goggle's IDR acceptance check against an HEVC elementary stream.

A vendor receiver does not parse the start of an IDR access unit, it compares twelve bytes of it
against hard-coded values. `AR_LDRT_RX_VDEC_RecvStreamCheck` in `libldrt_pipeline.so` (disassembly
at 0x1fa9c..0x1fb10) tests, in order:

    [0..3]   == 00 00 00 01    start code
    [4]      == 0x40           NAL 32, VPS: the first NAL of the AU must be the VPS
    [5]      == 0x01
    [39..42] == 00 00 00 01    second start code, so the VPS must be exactly 35 bytes
    [43]     == 0x42           NAL 33, SPS
    [44]     == 0x01

On any mismatch it logs `Parser IDR Stream Error`, calls `AR_LDRT_RX_VdecSendAttrReset` and drops
the frame, so the receiver never accepts the stream and re-requests an IDR forever. Our own goggle
imposes none of this, which is why a stream that fails here still plays perfectly on our own link
and the failure is invisible without a vendor receiver.

The check is byte-positional, so anything that shifts the head fails it: an access-unit delimiter
ahead of the VPS (the wave5 default, and the defect this script was written for), a 3-byte start
code, or a VPS of any length other than 35.

Usage:
    check-idr-head.py FILE.h265 [FILE.h265 ...]

Exit status is 1 if any file fails, so it can gate a bench run.
"""
import sys

# offset, required value. Ordered as the disassembly tests them.
CHECKS = [
    (0, 0x00), (1, 0x00), (2, 0x00), (3, 0x01),
    (4, 0x40), (5, 0x01),
    (39, 0x00), (40, 0x00), (41, 0x00), (42, 0x01),
    (43, 0x42), (44, 0x01),
]

NAL_NAMES = {32: "VPS", 33: "SPS", 34: "PPS", 35: "AUD", 39: "PREFIX_SEI", 19: "IDR_W_RADL"}


def au_start(data):
    """Offset of the IDR access unit. Our dumps begin at it; a capture may not."""
    if data[:4] == b"\x00\x00\x00\x01":
        return 0

    return data.find(b"\x00\x00\x00\x01")


def describe(buf, off):
    """Name the NAL whose header byte sits at off, for a failure that explains itself."""
    if off + 1 >= len(buf):
        return "past end of stream"

    nal = (buf[off] >> 1) & 0x3F

    return NAL_NAMES.get(nal, f"NAL {nal}")


def check_file(path):
    with open(path, "rb") as fh:
        data = fh.read(1 << 16)

    start = au_start(data)
    if start < 0:
        print(f"{path}: no start code found")
        return False

    buf = data[start:start + 64]
    if len(buf) < 45:
        print(f"{path}: stream shorter than the 45 bytes the check reads")
        return False

    failures = [(off, want) for off, want in CHECKS if buf[off] != want]

    print(f"{path} (AU at 0x{start:x})")
    print("  " + " ".join(f"{b:02x}" for b in buf[:48]))

    if not failures:
        print("  PASS: all 12 byte checks, a vendor receiver accepts this IDR")
        return True

    for off, want in failures:
        note = ""
        if off in (4, 43):
            note = f"  (found {describe(buf, off)})"
        print(f"  FAIL byte[{off}] = 0x{buf[off]:02x}, required 0x{want:02x}{note}")

    # The single most common cause, worth naming rather than leaving to be rediscovered.
    if buf[4] == 0x46:
        print("  cause: an access-unit delimiter precedes the VPS. Set"
              " V4L2_CID_MPEG_VIDEO_AU_DELIMITER to 0; wave5 defaults it to 1.")

    return False


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip())
        return 2

    ok = True
    for path in argv[1:]:
        try:
            ok &= check_file(path)
        except OSError as err:
            print(f"{path}: {err}")
            ok = False
        print()

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
