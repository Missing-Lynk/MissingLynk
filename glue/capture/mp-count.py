#!/usr/bin/env python3
"""Count :10000 message types in a vph-pcap capture, without dropping anything.

The counterpart to mp-trace.py, which prints a readable timeline but filters hard: mp-trace keeps
only datagrams whose src AND dst are both in (air_ip, 10.0.0.1), with air_ip defaulting to
10.0.0.100. That filter is right for reading a session as a story and wrong for answering "did
message X ever go out", because a peer on another address, or a malformed header, drops the exact
packet under test and the absence looks like a clean negative.

So this counts everything and reports what it excluded and why, which is what a negative result
needs to be believable. Confirming that the goggle has STOPPED sending something (an IDR request,
a SetTranParm) is the case this exists for.

Usage: mp-count.py capture.pcap [air_ip]
"""
import struct
import sys
from collections import Counter
from pathlib import Path

GROUND_IP = "10.0.0.1"

MP_TYPES = {
    0x01: "MEDIA_PARAMS_REQUEST",
    0x02: "MEDIA_PARAMS_REPLY",
    0x03: "IDR_REQUEST",
    0x09: "AIR_STATUS_A",
    0x0A: "SetLdCfg",
    0x0C: "SetCameraInfo",
    0x0D: "SetTranParm",
    0x10: "MSP",
    0x11: "AIR_STATUS_B",
    0x12: "SetStandbyMode",
    0x15: "SetScaleMode",
    0x1B: "STB_EVENT_ACK",
}


def records(path):
    data = Path(path).read_bytes()
    magic, = struct.unpack_from("<I", data, 0)
    if magic != 0xA1B2C3D4:
        raise SystemExit(f"{path}: not a little-endian pcap")

    off = 24
    if len(data) > 40 and (data[40] >> 4) != 4 and (data[36] >> 4) == 4:
        off = 20        # short global header written by early vph-pcap builds

    while off + 16 <= len(data):
        _sec, _usec, incl, _orig = struct.unpack_from("<IIII", data, off)
        off += 16
        if off + incl > len(data):
            break
        yield data[off:off + incl]
        off += incl


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)

    cap = sys.argv[1]
    air_ip = sys.argv[2] if len(sys.argv) > 2 else "10.0.0.100"

    on_types = Counter()        # both endpoints on the sdio0 pair: these are real messages
    off_types = Counter()       # anything else: header garbage that still parses to a type
    off_pairs = Counter()
    skipped = Counter()
    total = 0

    for pkt in records(cap):
        total += 1
        if len(pkt) < 28 or (pkt[0] >> 4) != 4 or pkt[9] != 17:
            skipped["not-ipv4-udp"] += 1
            continue

        ihl = (pkt[0] & 0x0F) * 4
        src = ".".join(str(b) for b in pkt[12:16])
        dst = ".".join(str(b) for b in pkt[16:20])
        sport, dport = struct.unpack_from(">HH", pkt, ihl)
        if 10000 not in (sport, dport):
            skipped["not-port-10000"] += 1
            continue

        body = pkt[ihl + 8:]
        if len(body) < 20:
            skipped["short-body"] += 1
            continue

        msg_type, = struct.unpack_from("<I", body, 0)
        if src in (air_ip, GROUND_IP) and dst in (air_ip, GROUND_IP):
            on_types[msg_type] += 1
        else:
            off_types[msg_type] += 1
            off_pairs[(src, dst)] += 1

    on_total = sum(on_types.values())
    off_total = sum(off_types.values())
    print(f"total packets: {total}   on-subnet: {on_total}   off-subnet: {off_total}")

    print("\nmessage types, ON-SUBNET (authoritative)")
    for msg_type, count in sorted(on_types.items()):
        print(f"  0x{msg_type:02x}  {MP_TYPES.get(msg_type, '?'):<22} {count}")

    if off_types:
        print("\nmessage types, OFF-SUBNET - NOT REAL, header garbage that still parses.")
        print("Counting these as traffic is how the goggle first looked chattier than it is.")
        for msg_type, count in sorted(off_types.items()):
            print(f"  0x{msg_type:02x}  {MP_TYPES.get(msg_type, '?'):<22} {count}")

    print("\nthe counts the plan's items are read off (on-subnet only):")
    for name, wanted in (("IDR_REQUEST", 0x03), ("SetCameraInfo", 0x0C),
                         ("SetTranParm", 0x0D), ("SetStandbyMode", 0x12)):
        noise = off_types.get(wanted, 0)
        warn = f"   (+{noise} off-subnet, ignore)" if noise else ""
        print(f"  {name:<16} {on_types.get(wanted, 0)}{warn}")

    print("\nA ZERO above is trustworthy: nothing on :10000 was dropped before typing, so an absent")
    print("message really was never sent. A NON-ZERO should be confirmed against mp-trace.py, which")
    print("shows direction and time and will not count header garbage.")

    if off_pairs:
        print(f"\noff-subnet source/dest pairs ({len(off_pairs)} distinct, all singletons if malformed):")
        for (src, dst), count in off_pairs.most_common(5):
            print(f"  {src:>15} -> {dst:<15} {count}")
        if len(off_pairs) > 5:
            print(f"  ... and {len(off_pairs) - 5} more")

    if skipped:
        print("\nexcluded before typing:")
        for reason, count in skipped.most_common():
            print(f"  {reason}: {count}")


if __name__ == "__main__":
    main()
