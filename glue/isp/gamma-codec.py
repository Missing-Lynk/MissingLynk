#!/usr/bin/env python3
"""Decode and encode the ISP gamma table's packed page format.

Format recovered by Codex from the vendor packer at libmpp_service.so:0x1951a8 and confirmed
here by an exact round-trip against the live hardware dump.

The first 0x1000 bytes of the 0x4000 allocation are two independent 0x800 pages. Each page is
128 records of 16 bytes holding four unsigned 12-bit samples, so 512 samples per page. The
surplus bits are redundant overlap fields the hardware also reads, so an encoder has to write
them or the table is malformed:

    sample[4i+0] =  word0        & 0xfff
    sample[4i+1] = (word0 >> 12) & 0xfff
    sample[4i+2] = (word1 >> 16) & 0xfff
    sample[4i+3] = (word2 >>  8) & 0xfff

    word0[31:24] = sample[4i+1][7:0]
    word1[15:0]  = sample[4i+1][11:8] | sample[4i+2] << 4
    word2[7:0]   = sample[4i+3] >> 4
    word2[31:20] = the NEXT record's sample[0]
    word3        = 0

Only the first page is repacked by the vendor at runtime. Bytes 0x1000..0x3fff are retained
tuning data in a different layout and must be copied through untouched, never synthesized.

Usage:
    gamma-codec.py dump <file>                  print both decoded curves
    gamma-codec.py verify <file>                round-trip test, proves the codec
    gamma-codec.py build <src> <dst> <gain>     rescale both pages by a gamma exponent
    gamma-codec.py fromblob <blob> <dst> [index] [base] [gain]
                                                generate page 0 from the tuning blob
"""

import struct
import sys
from collections.abc import Sequence

PAGE = 0x800
RECORDS = 128
SAMPLES = 512


def decode_page(data: bytes, base: int) -> list[int]:
    out = []
    for i in range(RECORDS):
        w0, w1, w2, _w3 = struct.unpack_from("<4I", data, base + i * 16)
        out.append(w0 & 0xFFF)
        out.append((w0 >> 12) & 0xFFF)
        out.append((w1 >> 16) & 0xFFF)
        out.append((w2 >> 8) & 0xFFF)

    return out


def encode_page(samples: Sequence[int], tail: int = 0) -> bytes:
    """Pack 512 samples. `tail` is the last record's forward field, the sample AFTER the page.

    That field is not cosmetic: the hardware interpolates the curve's top segment towards it,
    so leaving it zero maps the brightest inputs to black. A bring-up with it zeroed wrapped
    every highlight in the frame. `fromblob` derives it from the curve; `build` carries the
    original through, which is why the default here is only safe for a round-trip test.
    """
    assert len(samples) == SAMPLES
    buf = bytearray(PAGE)
    for i in range(RECORDS):
        s0, s1, s2, s3 = (samples[4 * i + k] & 0xFFF for k in range(4))
        # The next record's first sample is mirrored into word2's top field.
        nxt = samples[4 * (i + 1)] & 0xFFF if i + 1 < RECORDS else tail & 0xFFF
        w0 = s0 | (s1 << 12) | ((s1 & 0xFF) << 24)
        # word1's top nibble is a fifth overlap field, sample[4i+3]'s low nibble. Codex's
        # decode did not need it; an encoder does, and it holds for all 128 records.
        w1 = ((s1 >> 8) & 0xF) | (s2 << 4) | (s2 << 16) | ((s3 & 0xF) << 28)
        w2 = (s3 >> 4) | (s3 << 8) | (nxt << 20)
        struct.pack_into("<4I", buf, i * 16, w0 & 0xFFFFFFFF, w1 & 0xFFFFFFFF, w2 & 0xFFFFFFFF, 0)

    return bytes(buf)


def curves(data: bytes) -> tuple[list[int], list[int]]:
    return decode_page(data, 0x000), decode_page(data, 0x800)


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 1

    cmd, src = sys.argv[1], sys.argv[2]
    with open(src, "rb") as handle:
        data = handle.read()

    if cmd == "dump":
        for n, c in enumerate(curves(data)):
            mono = all(c[i] >= c[i - 1] for i in range(1, len(c)))
            print(f"page {n}: {len(c)} samples, max {max(c)}, monotonic {mono}")
            print("  first 12:", c[:12])
            print("  every 64:", c[::64])

        return 0

    if cmd == "verify":
        ok = True
        for n in range(2):
            base = n * PAGE
            # The forward field of the last record cannot come from the samples, so a
            # round-trip has to take it from the page it is checking. Passing it is what
            # makes this an exact test rather than one with two known-bad bytes.
            tail = (struct.unpack_from("<I", data, base + (RECORDS - 1) * 16 + 8)[0] >> 20) & 0xFFF
            re_enc = encode_page(decode_page(data, base), tail)
            if re_enc == data[base:base + PAGE]:
                print(f"page {n}: round-trip EXACT")
            else:
                bad = sum(1 for a, b in zip(re_enc, data[base:base + PAGE], strict=True) if a != b)
                print(f"page {n}: round-trip differs in {bad} bytes")
                ok = False

        return 0 if ok else 1

    if cmd == "fromblob":
        # Generate the gamma table from the TUNING BLOB rather than from a captured buffer.
        #
        # Source proven by Codex from the vendor's dynamic gamma path: the alternate source is
        # *(record + 0x18) + 0x26b90 + (index << 14), i.e. an array of five 0x4000-byte curves
        # at blob offset 0x26b90. Confirmed here: live page 0 equals curve 3 decimated by 8,
        # with a maximum error of 5 counts out of 4090.
        #
        # Page 1 comes from the OTHER source in that path (record + 0x1f2a8), which is runtime
        # state we have not mapped to a blob offset, so it is carried through from the base
        # table unchanged. Bytes 0x1000..0x3fff likewise.
        # argv[2] is the blob, already read into `data` by main.
        dst = sys.argv[3]
        index = int(sys.argv[4], 0) if len(sys.argv) > 4 else 3
        base_path = sys.argv[5] if len(sys.argv) > 5 else None
        gain = float(sys.argv[6]) if len(sys.argv) > 6 else 1.0

        blob = data
        off = 0x26B90 + index * 0x4000
        curve = struct.unpack_from("<4096I", blob, off)
        samples = [curve[i * 8] & 0xFFF for i in range(SAMPLES)]
        # Decimation puts the last stored sample at entry 4088, so the sample after the page
        # lies past the decimated range. The vendor uses the curve's final entry, and matching
        # it reproduces the vendor's own forward field of 4093 on both captured curves.
        tail = curve[-1] & 0xFFF

        if gain != 1.0:
            top = max(samples) or 4095
            samples = [min(0xFFF, int(round(top * (v / top) ** gain))) for v in samples]

        for i in range(1, len(samples)):
            if samples[i] < samples[i - 1]:
                samples[i] = samples[i - 1]

        # A base table supplies page 1 and the retained 0x1000..0x3fff region. Without one those
        # are zero, which is not a table the hardware should be given.
        if base_path:
            with open(base_path, "rb") as handle:
                out = bytearray(handle.read())

            if len(out) != 0x4000:
                print("base table must be 0x4000 bytes")
                return 1
        else:
            print("warning: no base table given, page 1 and 0x1000..0x3fff will be zero")
            out = bytearray(0x4000)

        out[0:PAGE] = encode_page(samples, max(tail, samples[-1]))
        with open(dst, "wb") as handle:
            handle.write(bytes(out))

        print(f"wrote {dst} from blob curve {index} (offset 0x{off:06x}), gain {gain:.2f}")
        print("  first 8 samples:", samples[:8])

        return 0

    if cmd == "build":
        dst, gain = sys.argv[3], float(sys.argv[4])
        out = bytearray(data)
        for n in range(2):
            c = decode_page(data, n * PAGE)
            top = max(c) or 4095
            # Apply an exponent below 1 to lift the shadows, keeping the endpoints fixed so
            # the curve stays anchored at black and at the original peak.
            lifted = [min(0xFFF, int(round(top * (v / top) ** gain))) for v in c]
            for i in range(1, len(lifted)):
                if lifted[i] < lifted[i - 1]:
                    lifted[i] = lifted[i - 1]

            enc = bytearray(encode_page(lifted))
            # The final record's mirror field points past the page, so it cannot be derived
            # from the samples. Carry the original through rather than writing zero.
            o = (RECORDS - 1) * 16 + 8
            new = struct.unpack_from("<I", enc, o)[0]
            old = struct.unpack_from("<I", data, n * PAGE + o)[0]
            struct.pack_into("<I", enc, o, (new & 0x000FFFFF) | (old & 0xFFF00000))
            out[n * PAGE:(n + 1) * PAGE] = bytes(enc)

        with open(dst, "wb") as handle:
            handle.write(bytes(out))

        print(f"wrote {dst}, gain {gain:.2f}, {len(out)} bytes (0x1000..0x3fff copied through)")
        return 0

    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main())
