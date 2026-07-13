#!/usr/bin/env python3
"""
Build a minimal valid .GMI image (Artosyn BootROM) wrapping an aarch64 code blob.

Recipe RE'd + simulation-verified from glue/recovery/bootrom-0x0.bin (validator 0x1de0 / 0x1cc0),
valid when secure-boot is OFF (efuse 0x240000 bit21 == 0, the stock state - the SPL carries no
signature sections). The 0x40-byte header is:
  +0x00 magic 0x494d4711 | +0x04 0x00400001 (hi16 = header length 0x40) | +0x08 header word-sum
  +0x0c 1 | +0x10 0x00010039 | +0x18 load_addr(=entry, in [0x110000,0x1fffff]) | +0x1c body size
  +0x20..0x2c 0 (no sig sections) | +0x30 0x00020280 | +0x34/+0x38 = 64-bit additive sum of body qwords | +0x3c 0
  +0x08 = sum of the 16 header u32 with word[2] (i.e. +0x08 itself) treated as 0, mod 2^32.
Body must be a multiple of 8 (qword sum); load_addr + size <= 0x1fffff.
"""
from __future__ import annotations

import struct
import sys

GMI_MAGIC = 0x494D4711
HDR_SIZE = 0x40                  # header length; also encoded in the hi16 of FLAGS
HDR_WORDS = HDR_SIZE // 4        # 16 u32 words
QWORD = 8                        # body is summed and padded in 8-byte words
U32_MASK = 0xFFFFFFFF
U64_MASK = 0xFFFFFFFFFFFFFFFF

LOAD_MIN = 0x110000              # payload must load into [LOAD_MIN, LOAD_MAX)
LOAD_MAX = 0x200000
FILE_BODY_OFF = 0x200            # in the on-disk image the body follows the header at this offset

# Header field offsets.
MAGIC_OFF = 0x00
FLAGS_OFF = 0x04
HDR_SUM_OFF = 0x08               # sum of the 16 header words with this word itself zeroed
WORD_0C_OFF = 0x0C
WORD_10_OFF = 0x10
LOAD_ADDR_OFF = 0x18
BODY_SIZE_OFF = 0x1C
WORD_30_OFF = 0x30
BODY_SUM_LO_OFF = 0x34           # low/high halves of the 64-bit additive sum of the body qwords
BODY_SUM_HI_OFF = 0x38
HDR_SUM_WORD = HDR_SUM_OFF // 4  # index (2) of the self word excluded from the header sum

# Fixed header words, mirrored from the stock SPL .GMI header. The validator does not
# checksum-gate these, but stock uses exactly these values.
FLAGS = 0x00400001               # hi16 = HDR_SIZE (0x40)
WORD_0C = 0x00000001
WORD_10 = 0x00010039
WORD_30 = 0x00020280


def build_gmi(body: bytes, load_addr: int) -> tuple[bytes, bytes]:
    if len(body) % QWORD:
        body = body + b'\x00' * (QWORD - len(body) % QWORD)

    size = len(body)
    if not (LOAD_MIN <= load_addr and load_addr + size <= LOAD_MAX):
        raise ValueError("load_addr/size out of [0x110000,0x1fffff]")

    body_sum = sum(struct.unpack_from('<Q', body, i)[0] for i in range(0, size, QWORD)) & U64_MASK

    header = bytearray(HDR_SIZE)
    for off, value in (
        (MAGIC_OFF, GMI_MAGIC),
        (FLAGS_OFF, FLAGS),
        (WORD_0C_OFF, WORD_0C),
        (WORD_10_OFF, WORD_10),
        (WORD_30_OFF, WORD_30),
        (LOAD_ADDR_OFF, load_addr),
        (BODY_SIZE_OFF, size),
        (BODY_SUM_LO_OFF, body_sum & U32_MASK),
        (BODY_SUM_HI_OFF, (body_sum >> 32) & U32_MASK),
    ):
        struct.pack_into('<I', header, off, value)

    header_words = list(struct.unpack_from(f'<{HDR_WORDS}I', header, 0))
    header_words[HDR_SUM_WORD] = 0
    struct.pack_into('<I', header, HDR_SUM_OFF, sum(header_words) & U32_MASK)

    return bytes(header), body


def _selftest() -> None:
    header, _ = build_gmi(bytes.fromhex('5f2003d5ffffff17'), 0x111000)

    def field(off: int) -> int:
        return struct.unpack_from('<I', header, off)[0]

    assert field(BODY_SUM_LO_OFF) == 0xd503205f, hex(field(BODY_SUM_LO_OFF))
    assert field(BODY_SUM_HI_OFF) == 0x17ffffff, hex(field(BODY_SUM_HI_OFF))
    assert field(HDR_SUM_OFF) == 0x36a47a32, hex(field(HDR_SUM_OFF))
    print("gmi selftest OK -- matches RE-verified test vector (+08=%#x +34=%#x +38=%#x)"
          % (field(HDR_SUM_OFF), field(BODY_SUM_LO_OFF), field(BODY_SUM_HI_OFF)))


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'selftest':
        _selftest()
    elif len(sys.argv) == 4:  # gmi.py <body.bin> <load_hex> <out.gmi>  (file: hdr@0, body@0x200)
        with open(sys.argv[1], 'rb') as f:
            body = f.read()

        header, padded_body = build_gmi(body, int(sys.argv[2], 16))
        image = header + b'\x00' * (FILE_BODY_OFF - len(header)) + padded_body
        with open(sys.argv[3], 'wb') as f:
            f.write(image)

        print(f"wrote {sys.argv[3]}: hdr {len(header)}B + body {len(padded_body)}B  load={sys.argv[2]}")
    else:
        print("usage: gmi.py selftest | gmi.py <body.bin> <load_hex> <out.gmi>")
