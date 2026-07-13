#!/usr/bin/env python3
"""
Read or flip the active A/B boot slot in an Artosyn `gpt0` partition image.

The Artosyn U-Boot picks the boot slot from the GPT: each partition entry's 8-byte
Attributes field uses **bit 47 (0x0000800000000000) = active**. For each dual pair
(`env0/1`, `uboot0/1`, `kernel0/1`, `dtb0/1`, `userapp0/1`) it boots the member with bit 47
set. Singletons (`vendor`, `factory`, `usr_data`, `usr_log`) keep bit 47 set always. There
is no standalone U-Boot command to flip this (the vendor only does it inside a full signed
`artosyn_upgrade`), so this tool does it directly and fixes the GPT CRC32s.

  python3 glue/flash/gpt_setactive.py <gpt0-image>            # show current slot
  python3 glue/flash/gpt_setactive.py <gpt0-image> a|b -o OUT # write a flipped image

Only `gpt0` carries the table on these units (`gpt1` is erased/unused). Writing the result
back to the gpt0 NAND partition needs flash_erase + nandwrite (not on the device by default)
or the U-Boot console; do that with UART standby. This tool only edits the image file.
"""
import struct
import sys
import zlib

ACTIVE_BIT = 1 << 47
PAIRS = ["env", "uboot", "kernel", "dtb", "userapp"]   # dual A/B partitions (suffix 0/1)

LBA_SIZE = 512           # GPT sector size; the entry array starts at entries_lba * LBA_SIZE
GUID_SIZE = 16           # partition-type GUID; an all-zero GUID marks an unused entry slot
ENTRY_MIN_SIZE = 128     # bytes; also where the utf-16 name field ends

# GPT header field offsets, measured from the "EFI PART" signature.
HDR_SIZE_OFF = 12         # u32 header byte length (its CRC covers exactly this many bytes)
HDR_CRC_OFF = 16          # u32 header CRC32 (computed with this field zeroed)
HDR_ENTRIES_LBA_OFF = 72  # u64 LBA of the partition-entry array
HDR_ENTRY_COUNT_OFF = 80  # u32 number of entries
HDR_ENTRY_SIZE_OFF = 84   # u32 size of each entry
HDR_ARRAY_CRC_OFF = 88    # u32 CRC32 of the whole entry array

# Partition-entry field offsets, measured from the entry start.
ENTRY_ATTRS_OFF = 48      # u64 attributes (bit 47 = active)
ENTRY_NAME_OFF = 56       # utf-16-le name, running to ENTRY_MIN_SIZE


def _u32(data: bytes, offset: int) -> int:
    return struct.unpack("<I", data[offset:offset + 4])[0]


def _u64(data: bytes, offset: int) -> int:
    return struct.unpack("<Q", data[offset:offset + 8])[0]


def _find_header(data: bytes) -> int:
    header_off = data.find(b"EFI PART")
    if header_off < 0:
        raise SystemExit("no GPT header (EFI PART) found; not a gpt0 image?")

    return header_off


def parse(data: bytes) -> tuple:
    """Locate the GPT and its entries.

    Returns (header_off, header_size, array_off, entry_count, entry_size, entries), where
    entries maps a partition name -> (entry_off, attributes).
    """
    header_off = _find_header(data)
    header_size = _u32(data, header_off + HDR_SIZE_OFF)
    entries_lba = _u64(data, header_off + HDR_ENTRIES_LBA_OFF)
    entry_count = _u32(data, header_off + HDR_ENTRY_COUNT_OFF)
    entry_size = _u32(data, header_off + HDR_ENTRY_SIZE_OFF)
    array_off = entries_lba * LBA_SIZE
    entries = {}
    for index in range(entry_count):
        entry_off = array_off + index * entry_size
        entry = data[entry_off:entry_off + entry_size]
        if len(entry) < ENTRY_MIN_SIZE or entry[0:GUID_SIZE] == b"\x00" * GUID_SIZE:
            continue

        attributes = _u64(entry, ENTRY_ATTRS_OFF)
        name = entry[ENTRY_NAME_OFF:ENTRY_MIN_SIZE].decode("utf-16-le").split("\x00")[0]
        entries[name] = (entry_off, attributes)

    return header_off, header_size, array_off, entry_count, entry_size, entries


def show(data: bytes) -> None:
    *_, entries = parse(data)
    a_active = sum(1 for pair in PAIRS if entries.get(pair + "0", (0, 0))[1] & ACTIVE_BIT)
    b_active = sum(1 for pair in PAIRS if entries.get(pair + "1", (0, 0))[1] & ACTIVE_BIT)
    if a_active and not b_active:
        slot = "A"
    elif b_active and not a_active:
        slot = "B"
    else:
        slot = "MIXED/UNKNOWN"

    print(f"active slot: {slot}  (A-members active={a_active}/{len(PAIRS)}, B-members active={b_active}/{len(PAIRS)})")
    for name in sorted(entries):
        entry_off, attributes = entries[name]
        mark = "ACTIVE" if attributes & ACTIVE_BIT else "  -   "
        print(f"  {name:10s} {mark}  attr=0x{attributes:016x}")


def set_slot(data: bytes, target: str) -> bytes:
    if target not in ("a", "b"):
        raise SystemExit("target must be 'a' or 'b'")

    want_b = target == "b"
    header_off, header_size, array_off, entry_count, entry_size, entries = parse(data)
    out = bytearray(data)
    for pair in PAIRS:
        for suffix, is_b in (("0", False), ("1", True)):
            name = pair + suffix
            if name not in entries:
                continue

            entry_off, attributes = entries[name]
            if is_b == want_b:
                new_attributes = attributes | ACTIVE_BIT
            else:
                new_attributes = attributes & ~ACTIVE_BIT
            struct.pack_into("<Q", out, entry_off + ENTRY_ATTRS_OFF, new_attributes)

    # recompute the entry-array CRC32, then the header CRC32 (which is taken over the header
    # with its own CRC field zeroed)
    entry_array = bytes(out[array_off:array_off + entry_count * entry_size])
    struct.pack_into("<I", out, header_off + HDR_ARRAY_CRC_OFF, zlib.crc32(entry_array) & 0xFFFFFFFF)
    struct.pack_into("<I", out, header_off + HDR_CRC_OFF, 0)
    header_crc = zlib.crc32(bytes(out[header_off:header_off + header_size])) & 0xFFFFFFFF
    struct.pack_into("<I", out, header_off + HDR_CRC_OFF, header_crc)

    return bytes(out)


def verify_crcs(data: bytes) -> bool:
    header_off, header_size, array_off, entry_count, entry_size, _ = parse(data)
    stored_array_crc = _u32(data, header_off + HDR_ARRAY_CRC_OFF)
    array_ok = (zlib.crc32(data[array_off:array_off + entry_count * entry_size]) & 0xFFFFFFFF) == stored_array_crc
    stored_header_crc = _u32(data, header_off + HDR_CRC_OFF)
    header = bytearray(data[header_off:header_off + header_size])
    struct.pack_into("<I", header, HDR_CRC_OFF, 0)
    header_ok = (zlib.crc32(bytes(header)) & 0xFFFFFFFF) == stored_header_crc

    return array_ok and header_ok


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    path = sys.argv[1]
    with open(path, "rb") as f:
        data = f.read()

    if len(sys.argv) == 2:
        print(f"# {path}  (CRCs {'valid' if verify_crcs(data) else 'INVALID'})")
        show(data)
        return 0

    target = sys.argv[2].lower()
    out_path = None
    if "-o" in sys.argv:
        out_path = sys.argv[sys.argv.index("-o") + 1]

    new_data = set_slot(data, target)
    assert verify_crcs(new_data), "internal error: recomputed CRCs do not validate"

    print(f"# flipped to slot {target.upper()}; CRCs valid")
    show(new_data)

    if out_path:
        with open(out_path, "wb") as f:
            f.write(new_data)
        print(f"wrote {out_path} ({len(new_data)} bytes)")
    else:
        print("(no -o given; not written)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
