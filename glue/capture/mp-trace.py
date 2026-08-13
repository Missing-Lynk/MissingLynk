#!/usr/bin/env python3
"""Print the :10000 message plane from a vph-pcap capture as a timeline.

One line per datagram: relative time, direction, message type, and the fields that matter for the
standby and power handshake. Written to answer ordering questions - when the goggle's StbAck arrives
relative to the air's work-mode report and the air's own 5 s silence window - which a log without
timestamps cannot.

Usage: mp-trace.py capture.pcap [air_ip]
"""
import struct
import sys
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
        ts_sec, ts_usec, incl, _ = struct.unpack_from("<IIII", data, off)
        off += 16
        if off + incl > len(data):
            break
        yield ts_sec + ts_usec / 1e6, data[off:off + incl]
        off += incl


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)

    cap = sys.argv[1]
    air_ip = sys.argv[2] if len(sys.argv) > 2 else "10.0.0.100"
    base = None
    last = None

    for ts, pkt in records(cap):
        if len(pkt) < 28 or (pkt[0] >> 4) != 4 or pkt[9] != 17:
            continue

        ihl = (pkt[0] & 0x0F) * 4
        src = ".".join(str(b) for b in pkt[12:16])
        dst = ".".join(str(b) for b in pkt[16:20])
        sport, dport = struct.unpack_from(">HH", pkt, ihl)
        if 10000 not in (sport, dport):
            continue

        # Both ends must be the sdio0 pair. A capture carries a few malformed packets with nonsense
        # addresses (~40 in 1627 observed); counting those as ground-side traffic is how the goggle
        # first appeared to be chattier than it is.
        if src not in (air_ip, GROUND_IP) or dst not in (air_ip, GROUND_IP):
            continue

        body = pkt[ihl + 8:]
        if len(body) < 20:
            continue

        msg_type, = struct.unpack_from("<I", body, 0)
        if base is None:
            base = ts

        gap = f"+{ts - last:6.3f}" if last is not None else "      "
        last = ts
        arrow = "air->gnd" if src == air_ip else "gnd->air"
        name = MP_TYPES.get(msg_type, f"type 0x{msg_type:02x}")

        extra = ""
        if msg_type == 0x12 and len(body) >= 24:                 # SetStandbyMode
            mode, = struct.unpack_from("<I", body, 20)
            extra = f"  work_mode={mode}"
        elif msg_type == 0x0A and len(body) >= 20 + 0x71:        # SetLdCfg
            extra = (f"  power={body[20 + 0x68]} dBm"
                     f"  standby@0x70={body[20 + 0x70]}")
        elif msg_type == 0x0D and len(body) >= 29:               # SetTranParm
            extra = f"  power={body[20]} dBm  standby={body[28]}"

        print(f"{ts - base:8.3f} {gap}  {arrow}  {name}{extra}")

    if base is None:
        print("# no :10000 datagrams in this capture", file=sys.stderr)


if __name__ == "__main__":
    main()
