#!/usr/bin/env python3
"""
pcap-to-rfdump.py - convert a captured RF session pcap into an .rfdump for the on-device replayer.

Reads an ml-sniff pcap (LINKTYPE_LINUX_SLL) of sdio0, extracts the air->goggle UDP datagrams
on the video port (:10001, IPv4 fragments reassembled) and optionally the telemetry/params
port (:10000), and writes them with their captured inter-packet timing as a flat record file
that glue/capture/ml-rf-replay.c plays back ON the goggle (to 127.0.0.1). Replaying from the
host is not supported: sustained host->goggle UDP over the USB gadget wedges it and cuts the
stream, which is why the replayer runs on the device.

Record format (all LE), per datagram: u32 delta_us (gap since previous), u16 dport, u16 len,
then len payload bytes.

Usage:
  pcap-to-rfdump.py capture.pcap session.rfdump               # video :10001 only
  pcap-to-rfdump.py capture.pcap session.rfdump --telemetry   # + :10000 stream
  pcap-to-rfdump.py capture.pcap session.rfdump --speed 2     # compress inter-packet gaps 2x

Pure stdlib. Reuses ml-rf-udp's SLL/IPv4/UDP parsers by import; carries its own pcap walker
because replay timing needs per-packet timestamps, which ml-rf-udp's read_pcap does not expose.
"""
import argparse
import importlib.util
import struct
import sys
from pathlib import Path

_p = Path(__file__).resolve().parents[2] / "libre" / "tools" / "ml-rf-udp" / "ml-rf-udp.py"
_spec = importlib.util.spec_from_file_location("mlrfudp", _p)
mlrfudp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mlrfudp)

AIR_IP = "10.0.0.100"
UDP_PROTO = 17


def read_pcap_ts(path):
    """Yield (ts_float, sll_frame) from a DLT_LINUX_SLL pcap (either endianness)."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 24:
        raise ValueError("file too short to be a pcap")
    magic = struct.unpack("<I", data[:4])[0]
    if magic in mlrfudp.PCAP_MAGICS:
        endian, _ = mlrfudp.PCAP_MAGICS[magic]
    else:
        magic = struct.unpack(">I", data[:4])[0]
        if magic not in mlrfudp.PCAP_MAGICS:
            raise ValueError("not a pcap")
        endian, _ = mlrfudp.PCAP_MAGICS[magic]
    network = struct.unpack(endian + "I", data[20:24])[0]
    if network != mlrfudp.DLT_LINUX_SLL:
        raise ValueError("expected LINKTYPE_LINUX_SLL (113), got %d" % network)
    off = 24
    while off + 16 <= len(data):
        ts, tus, caplen, _orig = struct.unpack(endian + "IIII", data[off:off + 16])
        off += 16
        if off + caplen > len(data):
            break
        yield ts + tus / 1e6, data[off:off + caplen]
        off += caplen


def collect(path, want_ports):
    """[(ts, dport, udp_payload)] for air->goggle UDP on want_ports, fragments reassembled.
    A reassembled datagram carries its FIRST fragment's timestamp."""
    out = []
    frags = {}   # (src,dst,proto,id) -> {"parts": {off: bytes}, "last_end": int|None, "ts": float}
    for ts, frame in read_pcap_ts(path):
        ethertype, l3 = mlrfudp.sll_payload(frame)
        if ethertype != 0x0800 or l3 is None:
            continue
        ip = mlrfudp.ipv4_parse(l3)
        if ip is None or ip["proto"] != UDP_PROTO or ip["src"] != AIR_IP:
            continue
        if ip["mf"] == 0 and ip["frag_off"] == 0:
            full, fts = ip["payload"], ts
        else:
            key = (ip["src"], ip["dst"], ip["proto"], ip["id"])
            slot = frags.setdefault(key, {"parts": {}, "last_end": None, "ts": ts})
            slot["parts"][ip["frag_off"]] = ip["payload"]
            if ip["mf"] == 0:
                slot["last_end"] = ip["frag_off"] + len(ip["payload"])
            if slot["last_end"] is None:
                continue
            buf = bytearray()
            nxt = 0
            ok = True
            for foff in sorted(slot["parts"]):
                if foff != nxt:
                    ok = False
                    break
                buf += slot["parts"][foff]
                nxt += len(slot["parts"][foff])
            if not ok or nxt < slot["last_end"]:
                continue
            full, fts = bytes(buf), slot["ts"]
            del frags[key]
        udp = mlrfudp.udp_parse(full)
        if udp is None:
            continue
        _sport, dport, payload = udp
        if dport in want_ports:
            out.append((fts, dport, payload))
    out.sort(key=lambda r: r[0])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pcap")
    ap.add_argument("out", help="output .rfdump for glue/capture/ml-rf-replay.c")
    ap.add_argument("--telemetry", action="store_true", help="also include :10000")
    ap.add_argument("--speed", type=float, default=1.0, help="inter-packet gap compression factor")
    args = ap.parse_args()

    ports = {10001}
    if args.telemetry:
        ports.add(10000)
    pkts = collect(args.pcap, ports)
    if not pkts:
        sys.exit("no matching air->goggle datagrams in the capture")
    n_video = sum(1 for _, p, _ in pkts if p == 10001)

    with open(args.out, "wb") as f:
        prev = pkts[0][0]
        for ts, dport, payload in pkts:
            delta_us = max(0, int((ts - prev) * 1e6 / args.speed))
            prev = ts
            f.write(struct.pack("<IHH", delta_us, dport, len(payload)))
            f.write(payload)
    print("[rf-replay] dumped %d datagrams (%d video), %.1fs span -> %s"
          % (len(pkts), n_video, pkts[-1][0] - pkts[0][0], args.out))


if __name__ == "__main__":
    main()
