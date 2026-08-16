#!/usr/bin/env python3
"""
Decode and encode the recovered dynamic portion of an Artosyn DRC DMA page.

The vendor DRC packer at libmpp_service.so:0x1a4200 updates two 0x800-byte
banks at DMA offsets 0x000 and 0x800.  Each bank has 128 16-byte records.
Each record carries three unsigned 20-bit lanes, consuming only its first ten
bytes; bytes 10..15 are preinitialised tuning data and are deliberately left
unchanged by the runtime packer.  Consecutive records overlap: record *i* is
`[sample[2i], sample[2i+1], sample[2i+2]]`, so one bank encodes a 257-sample
curve, not 384 independent samples.

This is an exact implementation of the bit writes at 0x1a44a0..0x1a450c:

    lane0 = word0[19:0]
    lane1 = word0[31:20] | word1[7:0] << 12
    lane1 duplicate = word1[27:8]
    lane2 = word1[31:28] | halfword2[15:0] << 4

The input source banks are 257 little-endian u32 samples (0x404 bytes) each.
They are vendor runtime staging data, not direct slices of the tuning blob.
The remaining 0x1000 bytes of the full 0x2000 page are not written by this
packer and remain outside this codec's recovered contract.

Usage:
    drc-codec.py dump <page>             inspect both dynamic banks
    drc-codec.py verify <page>           validate lane1 redundancy
    drc-codec.py match <page> <blob> <profile-count>
                                         find a neutral-strength blob profile
    drc-codec.py pack <template> <a> <b> <out>
                                         replace the two dynamic banks
"""

import pathlib
import struct
import sys
from collections.abc import Sequence

_ISP = pathlib.Path(__file__).resolve().parents[2] / "kernel" / "scripts" / "isp"
sys.path.insert(0, str(_ISP))
from blob_layout import Layout  # noqa: E402  (imported after the sys.path bootstrap)

_LAY = Layout.load()

PAGE_SIZE = 0x2000
BANK_SIZE = 0x800
RECORD_SIZE = 16
RECORDS = BANK_SIZE // RECORD_SIZE
LANES_PER_RECORD = 3
DECODED_LANES_PER_BANK = RECORDS * LANES_PER_RECORD
SOURCE_SAMPLES_PER_BANK = RECORDS * 2 + 1
SOURCE_BANK_SIZE = SOURCE_SAMPLES_PER_BANK * 4
LANE_MAX = (1 << 20) - 1
PROFILE_SIZE = _LAY["drc_profiles"].stride
PROFILE_TABLE_OFFSET = _LAY["drc_profiles"].offset


def _require_exact_length(data: bytes, expected: int, description: str) -> None:
    if len(data) != expected:
        raise ValueError(f"{description} must be 0x{expected:x} bytes, got 0x{len(data):x}")


def decode_bank(data: bytes, base: int) -> list[int]:
    """Return its 384 stored lanes and verify redundant lane1 fields."""
    _require_exact_length(data, PAGE_SIZE, "DRC page")
    lanes = []
    for record in range(RECORDS):
        offset = base + record * RECORD_SIZE
        word0, word1 = struct.unpack_from("<II", data, offset)
        halfword2 = struct.unpack_from("<H", data, offset + 8)[0]
        lane0 = word0 & LANE_MAX
        lane1 = ((word0 >> 20) & 0xFFF) | ((word1 & 0xFF) << 12)
        lane1_duplicate = (word1 >> 8) & LANE_MAX
        lane2 = ((word1 >> 28) & 0xF) | (halfword2 << 4)
        if lane1 != lane1_duplicate:
            raise ValueError(
                f"bank 0x{base:x}, record {record}: lane1 overlap "
                f"0x{lane1:x} != 0x{lane1_duplicate:x}"
            )

        lanes.extend((lane0, lane1, lane2))

    return lanes


def decode_source_bank(data: bytes, base: int) -> list[int]:
    """Recover the 257-sample source curve and verify record-to-record overlap."""
    lanes = decode_bank(data, base)
    samples = lanes[:LANES_PER_RECORD]
    for record in range(1, RECORDS):
        first, _middle, last = lanes[record * LANES_PER_RECORD:(record + 1) * LANES_PER_RECORD]
        if first != samples[-1]:
            raise ValueError(
                f"bank 0x{base:x}, record {record}: curve overlap "
                f"0x{first:x} != 0x{samples[-1]:x}"
            )

        samples.extend((_middle, last))

    return samples


def encode_bank(template: bytes, base: int, samples: Sequence[int]) -> bytes:
    """Apply vendor-equivalent lane writes to one bank, retaining bytes 10..15."""
    _require_exact_length(template, PAGE_SIZE, "DRC page template")
    if len(samples) != SOURCE_SAMPLES_PER_BANK:
        raise ValueError(
            f"DRC source bank needs {SOURCE_SAMPLES_PER_BANK} samples, got {len(samples)}"
        )

    out = bytearray(template)
    for record in range(RECORDS):
        lane0, lane1, lane2 = samples[record * 2:record * 2 + LANES_PER_RECORD]
        if any(lane < 0 or lane > LANE_MAX for lane in (lane0, lane1, lane2)):
            raise ValueError(f"bank 0x{base:x}, record {record}: lane outside 20-bit range")

        offset = base + record * RECORD_SIZE
        word0, word1 = struct.unpack_from("<II", out, offset)
        word0 = (word0 & 0xFFF00000) | lane0
        word0 = (word0 & 0x000FFFFF) | ((lane1 & LANE_MAX) << 20)
        word1 = (word1 & 0xFFFFFF00) | (lane1 >> 12)
        word1 = (word1 & 0xF00000FF) | ((lane1 & LANE_MAX) << 8)
        word1 = (word1 & 0x0FFFFFFF) | ((lane2 & LANE_MAX) << 28)
        struct.pack_into("<IIH", out, offset, word0 & 0xFFFFFFFF, word1 & 0xFFFFFFFF, lane2 >> 4)

    return bytes(out)


def read_source(path: str) -> list[int]:
    with open(path, "rb") as handle:
        data = handle.read()

    _require_exact_length(data, SOURCE_BANK_SIZE, "DRC source bank")
    return list(struct.unpack(f"<{SOURCE_SAMPLES_PER_BANK}I", data))


def profile_banks(blob: bytes, profile_index: int) -> tuple[list[int], list[int]]:
    """Return the two raw profile windows used when DRC strength is neutral (50)."""
    base = PROFILE_TABLE_OFFSET + profile_index * PROFILE_SIZE
    end = base + 0x404 + SOURCE_BANK_SIZE
    if end > len(blob):
        raise ValueError(f"profile {profile_index} lies beyond the tuning blob")

    first = struct.unpack_from(f"<{SOURCE_SAMPLES_PER_BANK}I", blob, base)
    second = struct.unpack_from(f"<{SOURCE_SAMPLES_PER_BANK}I", blob, base + 0x404)

    return list(first), list(second)


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2

    command, page_path = sys.argv[1:3]
    with open(page_path, "rb") as handle:
        page = handle.read()

    try:
        if command in ("dump", "verify"):
            regenerated = page
            for bank in range(2):
                lanes = decode_bank(page, bank * BANK_SIZE)
                regenerated = encode_bank(
                    regenerated, bank * BANK_SIZE, decode_source_bank(page, bank * BANK_SIZE)
                )
                print(
                    f"bank {bank}: {SOURCE_SAMPLES_PER_BANK}-sample curve; first 12: "
                    + " ".join(f"0x{lane:05x}" for lane in lanes[:12])
                )

            if command == "verify":
                if regenerated != page:
                    print("error: decoder/encoder did not round-trip the page", file=sys.stderr)
                    return 1
                print("both dynamic banks have valid 20-bit overlap fields and round-trip exactly")

            return 0

        if command == "pack":
            if len(sys.argv) != 6:
                print("pack needs: <template> <source-bank-a> <source-bank-b> <out>")
                return 2

            # page_path is intentionally the template to keep the command spelling compact.
            source_a = read_source(sys.argv[3])
            source_b = read_source(sys.argv[4])
            out = encode_bank(page, 0, source_a)
            out = encode_bank(out, BANK_SIZE, source_b)
            with open(sys.argv[5], "wb") as handle:
                handle.write(out)

            print(f"wrote {sys.argv[5]}: dynamic banks replaced; 0x1000..0x1fff retained")
            return 0

        if command == "match":
            if len(sys.argv) != 5:
                print("match needs: <page> <blob> <profile-count>")
                return 2

            profile_count = int(sys.argv[4], 0)
            with open(sys.argv[3], "rb") as handle:
                blob = handle.read()

            captured = (decode_source_bank(page, 0), decode_source_bank(page, BANK_SIZE))
            best = (-1, -1)

            for index in range(profile_count):
                candidate = profile_banks(blob, index)
                matches = sum(
                    actual == expected
                    for actual_bank, expected_bank in zip(captured, candidate, strict=True)
                    for actual, expected in zip(actual_bank, expected_bank, strict=True)
                )

                if matches > best[1]:
                    best = (index, matches)

                if matches == SOURCE_SAMPLES_PER_BANK * 2:
                    print(f"profile {index}: exact neutral-strength match")
                    return 0

            print(
                f"no exact neutral-strength match; best profile {best[0]} "
                f"matches {best[1]} of {SOURCE_SAMPLES_PER_BANK * 2} samples"
            )

            return 1

    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
