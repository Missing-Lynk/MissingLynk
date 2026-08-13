#!/usr/bin/env python3
"""Recover the two tiles' HEVC elementary streams from a vph-pcap capture.

Reassembles IP fragments, strips the 36-byte VPH header and the 4-byte tail magic, and writes one
.265 per ChnIndex. Reports what it had to discard, because an access unit missing a fragment is
exactly the kind of thing that shows up as a corrupt block on screen and must not be confused with
one the encoder produced that way.

Usage: vph-es.py capture.pcap outdir
"""
import struct
import sys
from collections import defaultdict
from pathlib import Path

VPH_MAGIC = 0x12345678
VPH_TAIL = 0x87654321
VPH_HDR = 36


def packets(path):
    """Yield the IP payload of every record in a LINKTYPE_RAW pcap."""
    data = Path(path).read_bytes()
    if len(data) < 24:
        return

    magic, = struct.unpack_from("<I", data, 0)
    if magic != 0xA1B2C3D4:
        raise SystemExit(f"{path}: not a little-endian pcap (magic {magic:#x})")

    # 24 is the standard global header. Captures from vph-pcap before 2026-08-13 wrote 20, which
    # shifts every record. A shifted record length still looks plausible, so decide on the payload:
    # this is LINKTYPE_RAW, so the first byte after a correct record header is an IPv4 nibble.
    off = None
    for candidate in (24, 20):
        if len(data) < candidate + 16:
            continue
        first = data[candidate + 16]
        if (first >> 4) == 4 and (first & 0x0F) >= 5:
            off = candidate
            break

    if off is None:
        raise SystemExit(f"{path}: no IPv4 payload at a 24- or 20-byte global header")
    while off + 16 <= len(data):
        _, _, incl, _ = struct.unpack_from("<IIII", data, off)
        off += 16
        if off + incl > len(data):
            break
        yield data[off:off + incl]
        off += incl


def reassemble(path):
    """Yield complete UDP payloads, reassembling IPv4 fragments by (src, dst, id, proto)."""
    frags = defaultdict(dict)      # key -> {offset: payload}
    last = {}                      # key -> total length once the final fragment is seen
    stats = {"ipv4": 0, "udp": 0, "incomplete": 0}

    for pkt in packets(path):
        if len(pkt) < 20 or (pkt[0] >> 4) != 4:
            continue

        ihl = (pkt[0] & 0x0F) * 4
        total_len, ident, flags_frag, proto = (
            struct.unpack_from(">H", pkt, 2)[0],
            struct.unpack_from(">H", pkt, 4)[0],
            struct.unpack_from(">H", pkt, 6)[0],
            pkt[9],
        )
        if proto != 17:            # UDP only
            continue

        stats["ipv4"] += 1
        more = bool(flags_frag & 0x2000)
        frag_off = (flags_frag & 0x1FFF) * 8
        payload = pkt[ihl:total_len]
        key = (pkt[12:16], pkt[16:20], ident)

        frags[key][frag_off] = payload
        if not more:
            last[key] = frag_off + len(payload)

        if key not in last:
            continue

        # Walk the fragments in order; a gap means the capture missed one.
        want, chunks = 0, []
        for off in sorted(frags[key]):
            if off != want:
                break
            chunks.append(frags[key][off])
            want += len(frags[key][off])

        if want != last[key]:
            continue

        datagram = b"".join(chunks)
        del frags[key], last[key]
        stats["udp"] += 1

        if len(datagram) > 8:
            yield datagram[8:]     # strip the UDP header

    stats["incomplete"] = len(frags)
    print(f"# ipv4 udp-fragments={stats['ipv4']} datagrams={stats['udp']} "
          f"never-completed={stats['incomplete']}", file=sys.stderr)


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)

    cap, outdir = sys.argv[1], Path(sys.argv[2])
    outdir.mkdir(parents=True, exist_ok=True)

    streams = defaultdict(bytearray)
    counts = defaultdict(int)
    idrs = defaultdict(int)
    bad = 0

    for payload in reassemble(cap):
        if len(payload) < VPH_HDR + 4:
            bad += 1
            continue

        magic, stream_len, chn, idr, frame_id = struct.unpack_from("<IIIII", payload, 0)
        if magic != VPH_MAGIC:
            bad += 1
            continue

        tail_at = VPH_HDR + stream_len
        if tail_at + 4 > len(payload):
            print(f"# truncated: chn {chn} frame {frame_id} says {stream_len} B, "
                  f"have {len(payload) - VPH_HDR}", file=sys.stderr)
            bad += 1
            continue

        tail, = struct.unpack_from("<I", payload, tail_at)
        if tail != VPH_TAIL:
            print(f"# bad tail: chn {chn} frame {frame_id} tail {tail:#x}", file=sys.stderr)
            bad += 1
            continue

        streams[chn] += payload[VPH_HDR:tail_at]
        counts[chn] += 1
        idrs[chn] += bool(idr)

    for chn in sorted(streams):
        path = outdir / f"tile{chn}.265"
        path.write_bytes(bytes(streams[chn]))
        print(f"{path}: {counts[chn]} access units, {idrs[chn]} IDR, {len(streams[chn])} B")

    if bad:
        print(f"# {bad} datagram(s) unusable - a corrupt block in a frame decoded from this "
              f"capture may be the capture's fault, not the encoder's", file=sys.stderr)


if __name__ == "__main__":
    main()
