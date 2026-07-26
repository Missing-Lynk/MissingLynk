#!/usr/bin/env python3
"""
Pack/unpack the goggle kernel partition container.

The stock kernel partition (mtd13/mtd14) is three layers:
  1. OTRA 64B
  2. u-boot legacy uImage 64B, comp=lz4, load/entry 0x200a0000
  3. LZ4-frame Image
The active U-Boot env `bootm`s this (mmc read -> 0x30000000 -> bootm), LZ4-decompressing
the arm64 Image to 0x200a0000; the dtb is loaded raw to 0x22080000. See
kernel/README.md ("U-Boot / boot constraints"). To boot a kernel we build, we must reproduce this container.

LZ4 is the ONLY compression this tool packs: a flashed slot boots via SPL Falcon, whose
decompressor is LZ4-only (kernel/README.md, docs/reference/open-firmware-bsp.md). Other
uImage codecs (gzip/lzma) would not boot on this hardware, so they are not offered.

OTRA header (little-endian), decoded from stock kernel0/kernel1:
  +0x00 "OTRA"            +0x0c load addr (0x200a0000)
  +0x10 payload size padded to 256B
  +0x20 a per-image checksum we have NOT identified (upper half constant 0x168a across
        both slots; not crc32 of any obvious range). SETTLED 2026-06-26 by the M-A RAM
        boot: bootm does NOT validate this field; it only checks the uImage CRCs
        ("Verifying Checksum ... OK"), and our container (with +0x20 templated from a
        stock dump, payload completely different) decompressed and booted. We still
        template +0x20 from a stock dump for shape; it is not load-bearing for bootm.

uImage (legacy, big-endian) fields are computed correctly (header CRC32 + data CRC32),
so the layer bootm checks is sound.

LZ4 frame: U-Boot's decompressor requires INDEPENDENT blocks (it rejects linked blocks
with -93 = -EPROTONOSUPPORT). Python's lz4.frame defaults to linked, so pack() forces
block_linked=False and matches the vendor frame exactly (FLG=0x64, BD=0x70: blockIndep=1,
contentChksum=1, contentSize=0, 4 MiB blocks). This was the last blocker to M-A.

Usage:
  mkkernel.py unpack <kernel-part.bin> <out-Image>
  mkkernel.py pack   <Image> <out-kernel-part.bin> --otra-template <stock-kernel-part.bin>
  mkkernel.py size   <Image>                     # packed size + kernel-slot margin (exit 1 if over)
  mkkernel.py verify <stock-kernel-part.bin>     # round-trip self-test
"""
import sys
import os
import re
import functools
import struct
import zlib
import argparse
import tempfile
import lz4.frame

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # this file is glue/flash/

# Board config (device-specific; adjust per target).
LOAD = 0x200A0000          # kernel load/entry address; SPL Falcon LZ4-decompresses the Image to here.
NAME = b'Sirius'           # uImage name field (32B, informational; the vendor uses "Sirius").
DEFAULT_SLOT_SIZE = 0x600000   # kernel-slot size assumed when no device profile can be read; see kernel_slot_size().

# Fixed container + uImage protocol constants (U-Boot include/image.h; not configurable). Each IH_*
# names one byte in the 32B legacy uImage header (os / arch / type / comp), so the boot chain accepts
# the image as a Linux arm64 kernel. comp is LZ4 only (the one format SPL Falcon can decompress).
OTRA_MAGIC = b'OTRA'       # Artosyn's 64B outer header that wraps the uImage in a flash slot.
UIMG_MAGIC = 0x27051956    # U-Boot legacy uImage magic (image.h IH_MAGIC), big-endian header.
IH_OS_LINUX = 5            # os field: Linux.
IH_ARCH_ARM64 = 22         # arch field: ARM64 (aarch64).
IH_TYPE_KERNEL = 2         # type field: OS kernel image.
IH_COMP_LZ4 = 5            # comp field: LZ4 frame.


def active_device():
    """Name of the device this invocation targets: $DEVICE, else the .device selection."""
    device = os.environ.get('DEVICE')
    if device:
        return device.strip()

    try:
        with open(os.path.join(REPO, '.device')) as selection:
            return selection.read().strip()
    except OSError:
        return ''


def mtdparts_partition_size(mtdparts, want):
    """
    Size in bytes of the named partition in a U-Boot mtdparts table, or None if absent.

    The table is "<mtd-id>:<size>[@<offset>](<name>),..."; sizes are bytes, optionally with a
    k/K/m/M/g/G suffix. Only sizes are needed here; glue/lib/device.sh's mtdparts_partition also
    derives each entry's implicit offset, which nothing on this side asks for.
    """
    multipliers = {'k': 1024, 'm': 1024 * 1024, 'g': 1024 * 1024 * 1024}
    for size_text, name in re.findall(r'([0-9]+[kKmMgG]?)(?:@[^(]*)?\(([^)]*)\)',
                                      mtdparts.split(':', 1)[-1]):
        if name != want:
            continue

        suffix = size_text[-1].lower()
        if suffix in multipliers:
            return int(size_text[:-1]) * multipliers[suffix]

        return int(size_text)

    return None


@functools.lru_cache(maxsize=None)
def kernel_slot_size():
    """
    Size of the active device's kernel partition; a flashed container must fit it.

    Read from DEV_MTDPARTS in devices/<device>/device.mk, the same table glue/lib/uboot.sh puts
    on the RAM-boot cmdline. Falls back to DEFAULT_SLOT_SIZE (with a warning) when there is no
    device selection or no table, so packing for a RAM-boot still works outside a set-up tree.
    """
    device = active_device()
    manifest = os.path.join(REPO, 'devices', device, 'device.mk')
    if device and os.path.exists(manifest):
        with open(manifest) as source:
            match = re.search(r'^DEV_MTDPARTS\s*=\s*([^#\n]*)', source.read(), re.MULTILINE)
        if match:
            size = mtdparts_partition_size(match.group(1).strip(), 'kernel1')
            if size is not None:
                return size

    print(f"WARNING: no kernel1 partition for device '{device or '(none selected)'}'; assuming "
          f"{DEFAULT_SLOT_SIZE // (1024 * 1024)} MiB. Run: make setup DEVICE=<name>", file=sys.stderr)

    return DEFAULT_SLOT_SIZE


def parse_uimage(data):
    (magic, hcrc, timestamp, size, load, ep, dcrc, os_, arch, typ, comp) = struct.unpack('>IIIIIIIBBBB', data[:32])
    name = data[32:64].split(b'\x00')[0]
    return dict(magic=magic, hcrc=hcrc, time=timestamp, size=size, load=load, ep=ep, dcrc=dcrc,
                os=os_, arch=arch, type=typ, comp=comp, name=name)


def build_uimage_header(payload, name=NAME, load=LOAD, ep=LOAD, timestamp=0, comp=IH_COMP_LZ4):
    dcrc = zlib.crc32(payload) & 0xffffffff
    header = struct.pack(
        '>IIIIIIIBBBB',
        UIMG_MAGIC, 0, timestamp, len(payload), load, ep, dcrc,
        IH_OS_LINUX, IH_ARCH_ARM64, IH_TYPE_KERNEL, comp)
    header += name[:31].ljust(32, b'\x00')
    hcrc = zlib.crc32(header) & 0xffffffff

    return header[:4] + struct.pack('>I', hcrc) + header[8:]


def unpack(part_path, out_image):
    data = open(part_path, 'rb').read()
    offset = 0
    if data[:4] == OTRA_MAGIC:
        offset = 0x40

    uimage = parse_uimage(data[offset:offset + 64])
    assert uimage['magic'] == UIMG_MAGIC, 'no uImage magic (after OTRA strip)'
    payload = data[offset + 64:offset + 64 + uimage['size']]
    assert (zlib.crc32(payload) & 0xffffffff) == uimage['dcrc'], 'uImage data CRC mismatch'
    if uimage['comp'] == IH_COMP_LZ4:
        image = lz4.frame.decompress(payload)
    elif uimage['comp'] == 0:
        image = payload
    else:
        raise SystemExit(f"unsupported comp={uimage['comp']} (this tool only handles LZ4)")

    assert image[56:60] == b'ARM\x64', 'decompressed payload is not an arm64 Image'
    open(out_image, 'wb').write(image)
    print(f"unpacked: comp={uimage['comp']} name={uimage['name']!r} load=0x{uimage['load']:08x} "
          f"Image={len(image)} bytes -> {out_image}")

    return data, offset, uimage, image


def build_otra(payload_len, template):
    if template:
        header = bytearray(open(template, 'rb').read(0x40))
        assert header[:4] == OTRA_MAGIC, 'template has no OTRA header'
    else:
        header = bytearray(0x40)
        header[:4] = OTRA_MAGIC

    struct.pack_into('<I', header, 0x0c, LOAD)
    padded = (payload_len + 255) // 256 * 256
    struct.pack_into('<I', header, 0x10, padded)
    # +0x20 left as template's value; see module docstring.
    return bytes(header)


def build_container(image, otra_template=None, timestamp=0):
    """Compress `image` bytes and wrap them in the uImage + OTRA container. Returns (blob, payload)."""
    if image[56:60] != b'ARM\x64':
        print('WARNING: input does not have arm64 Image magic at +56', file=sys.stderr)

    # Match the vendor's LZ4 frame exactly (FLG=0x64, BD=0x70): U-Boot's decompressor
    # requires INDEPENDENT blocks (block_linked=False); linked blocks fail with -93.
    payload = lz4.frame.compress(image, block_linked=False, store_size=False,
                                 content_checksum=True, compression_level=12,
                                 block_size=lz4.frame.BLOCKSIZE_MAX4MB)  # HC; U-Boot decodes it the same
    uimg = build_uimage_header(payload, timestamp=timestamp, comp=IH_COMP_LZ4)
    otra = build_otra(len(uimg) + len(payload), otra_template)

    return otra + uimg + payload, payload


def slot_margin(blob_len):
    """Human summary of the packed container vs the device's kernel slot, plus a fits/does-not bool."""
    slot_size = kernel_slot_size()
    slot = f"{slot_size // (1024 * 1024)} MiB slot"
    percent = 100.0 * blob_len / slot_size
    free = slot_size - blob_len
    if free >= 0:
        return f"{blob_len:,} B = {percent:.1f}% of the {slot}, {free:,} B ({free // 1024} KiB) free", True

    over = -free
    return f"{blob_len:,} B = {percent:.1f}% of the {slot}, OVER by {over:,} B ({over // 1024} KiB)", False


def pack(image_path, out_path, otra_template=None, timestamp=0):
    image = open(image_path, 'rb').read()
    blob, payload = build_container(image, otra_template, timestamp)
    if not otra_template:
        print('WARNING: no --otra-template; OTRA +0x20 checksum is zeroed and may be '
              'rejected by bootm. Pass a stock dump as template.', file=sys.stderr)
    open(out_path, 'wb').write(blob)
    margin, fits = slot_margin(len(blob))
    print(f"packed: Image={len(image)} -> lz4={len(payload)} -> container={len(blob)} "
          f"bytes -> {out_path}")
    print(f"  slot fit: {margin}")
    if not fits:
        print("  NOTE: exceeds the kernel slot: fine for RAM-boot (loads to RAM), but "
              "will NOT fit kernel0/1 for flashing.", file=sys.stderr)


def size(image_path):
    """
    Report the packed size + slot margin without writing a file or needing a device/template.
    Returns whether the container fits the slot (the CLI exits non-zero when it does not, so this
    doubles as a pre-flash gate).
    """
    image = open(image_path, 'rb').read()
    blob, payload = build_container(image)
    margin, fits = slot_margin(len(blob))

    print(f"{image_path}")
    print(f"  Image {len(image):,} B -> lz4 {len(payload):,} B -> container {len(blob):,} B")
    print(f"  slot fit: {margin}")

    return fits


def verify(part_path):
    # The scratch files live in one temporary directory that is removed on the way out, including
    # when the round trip raises. tempfile.mktemp() only reserved a name - anything else on the
    # host could create that path between the call and the write - and left cleanup to the caller.
    with tempfile.TemporaryDirectory(prefix='mkkernel-verify-') as scratch_dir:
        extracted_path = os.path.join(scratch_dir, 'extracted.Image')
        image_path = os.path.join(scratch_dir, 'roundtrip.Image')
        container_path = os.path.join(scratch_dir, 'repacked.bin')

        data, _offset, uimage, image = unpack(part_path, extracted_path)
        # repack from the extracted Image and re-unpack; the round trip must recover it.
        with open(image_path, 'wb') as image_file:
            image_file.write(image)

        pack(image_path, container_path, otra_template=part_path)
        with open(container_path, 'rb') as container_file:
            repacked = container_file.read()

    uimage2 = parse_uimage(repacked[0x40:0x40 + 64])
    roundtrip_image = lz4.frame.decompress(repacked[0x80:0x80 + uimage2['size']])
    ok_fields = all(uimage2[k] == uimage[k] for k in ('magic', 'load', 'ep', 'os', 'arch', 'type', 'comp', 'name'))
    ok_image = roundtrip_image == image
    ok_otra = repacked[:0x40][:4] == OTRA_MAGIC and repacked[0x0c:0x10] == data[0x0c:0x10]

    print(f"round-trip: uImage fields {'OK' if ok_fields else 'FAIL'}, "
          f"Image identical {'OK' if ok_image else 'FAIL'}, OTRA shape {'OK' if ok_otra else 'FAIL'}")
    print(f"  stock container {len(data)}B, repacked {len(repacked)}B "
          f"(differ only by LZ4 stream + uImage time/CRC, expected)")

    return ok_fields and ok_image and ok_otra


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest='cmd', required=True)

    unpack_parser = subparsers.add_parser('unpack')
    unpack_parser.add_argument('part')
    unpack_parser.add_argument('out_image')

    pack_parser = subparsers.add_parser('pack')
    pack_parser.add_argument('image')
    pack_parser.add_argument('out')
    pack_parser.add_argument('--otra-template')

    size_parser = subparsers.add_parser('size')
    size_parser.add_argument('image')

    verify_parser = subparsers.add_parser('verify')
    verify_parser.add_argument('part')

    args = parser.parse_args()
    if args.cmd == 'unpack':
        unpack(args.part, args.out_image)
    elif args.cmd == 'pack':
        pack(args.image, args.out, args.otra_template)
    elif args.cmd == 'size':
        sys.exit(0 if size(args.image) else 1)
    elif args.cmd == 'verify':
        sys.exit(0 if verify(args.part) else 1)
