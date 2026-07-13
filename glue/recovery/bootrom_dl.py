#!/usr/bin/env python3
"""Artosyn/Proxima BootROM UART recovery downloader (0x55-frame protocol, RE'd from bootrom-0x0.bin).

Absolute last resort (see RECOVERY.md): drive the mask BootROM over the 3 debug-UART wires when
nothing else boots. Spam ASCII "0123456" during the cold V1.4 menu -> the ROM replies 'Y', then it
accepts 16-byte-header frames that write RAM/MMIO:
  [55 52 | len(2LE) | addr(8LE) | pcsum | 00 00 | hcsum] + payload
  pcsum = sum(payload) & 0xff @+12 ; hcsum = sum(hdr[0:15]) & 0xff @+15.
  commit: len==4 & addr 4-aligned -> 32-bit poke *addr=payload ; else memcpy(addr, payload, len).
  ACK 'Y' after the header, 'Y' again after the payload ('N' on bad checksum). len==0 terminates:
  the ROM then validates the .GMI image at 0x100040 and jumps to *(u32*)0x100058.

Modes:
  --gmi <bin> <load_hex>   wrap a bare-metal payload as a .GMI and run it (the PROVEN path, e.g.
                           payload/flash_writer.bin @0x111000 to rewrite gpt0). Watches @115200.
  --test                   one harmless poke, to confirm the frame protocol is live.

Power-cycle the goggle ONCE right after starting (to catch the brief BootROM menu window).
"""
from __future__ import annotations

import os
import sys
import time

import serial

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, os.pardir, 'lib'))
sys.path.insert(0, _HERE)
from serial_port import find_port
import gmi

LOAD = 0x110000            # --test poke address (harmless RAM)
MAXPAY = 0xFF0             # max payload bytes per frame


def build_header(addr: int, payload: bytes) -> bytes:
    n = len(payload)
    h = bytearray(16)
    h[0] = 0x55
    h[1] = 0x52
    h[2] = n & 0xff
    h[3] = (n >> 8) & 0xff
    for i in range(8):
        h[4 + i] = (addr >> (8 * i)) & 0xff

    h[12] = sum(payload) & 0xff
    h[15] = sum(h[0:15]) & 0xff

    return bytes(h)


def enter_download(s: serial.Serial, secs: float = 45) -> bool:
    print("spamming '0123456' -- power-cycle the goggle ONCE now", flush=True)
    t = time.time()
    while time.time() - t < secs:
        s.write(b'0123456')
        d = s.read(64)
        if d and 0x59 in d:
            print(f"@{time.time()-t:.1f}s 'Y' -- inside download mode", flush=True)

            return True

    print("no 'Y' -- timing missed the menu, retry", flush=True)
    return False


def send_frame(s: serial.Serial, addr: int, payload: bytes, label: str = "", quiet: bool = False) -> bool:
    s.reset_input_buffer()
    s.write(build_header(addr, payload))
    a = s.read(1)                       # ACK is a single 'Y' (or 'N')
    if not payload:
        if not quiet:
            print(f"  {label}: hdr -> {a!r}", flush=True)

        return b'Y' in a

    s.write(payload)
    b = s.read(1)
    ok = (b'Y' in a) and (b'Y' in b)
    if not ok or not quiet:
        print(f"  {label}: hdr {a!r} / payload({len(payload)}) {b!r}  {'OK' if ok else 'FAIL'}", flush=True)

    return ok


def watch(s: serial.Serial, secs: float) -> bytes:
    """Stream serial to stdout for `secs`, mapping non-printables to '.'; return the raw bytes."""
    s.timeout = 0.1
    buf = b''
    t = time.time()
    while time.time() - t < secs:
        try:
            d = s.read(4000)
        except Exception:
            break

        if d:
            buf += d
            sys.stdout.write(bytes(c if (32 <= c < 127 or c in (10, 13)) else 0x2e for c in d).decode('ascii', 'replace'))
            sys.stdout.flush()

    return buf


def run_gmi(s: serial.Serial, body_path: str, load_addr: int) -> None:
    with open(body_path, 'rb') as f:
        body = f.read()

    hdr, body = gmi.build_gmi(body, load_addr)
    print(f"GMI: {len(body)}B body -> {load_addr:#x}, header -> 0x100040", flush=True)
    if not send_frame(s, 0x100040, hdr, "gmi-hdr"):
        print("header NACK -- abort", flush=True)
        return

    off = 0
    nf = 0
    while off < len(body):
        chunk = body[off:off + MAXPAY]
        if not send_frame(s, load_addr + off, chunk, f"body@{off:#x}", quiet=True):
            print(f"  body@{off:#x} NACK", flush=True)

        off += len(chunk)
        nf += 1
        if nf % 16 == 0 or off >= len(body):
            print(f"  ... {off:#x}/{len(body):#x}", flush=True)

    print("terminator -> validate + jump; watching @115200 (payload keeps BootROM baud) (live, 20s):", flush=True)
    s.reset_input_buffer()
    s.write(build_header(0, b''))
    s.flush()
    buf = watch(s, 20)
    print(f"\n--- done ({len(buf)} bytes) ---", flush=True)


def main() -> None:
    if '--gmi' not in sys.argv and '--test' not in sys.argv:
        sys.exit(__doc__)

    s = serial.Serial(find_port(), 115200, timeout=0.2, write_timeout=2.0)
    if not enter_download(s):
        s.close()
        return

    s.timeout = 0.6

    if '--gmi' in sys.argv:
        i = sys.argv.index('--gmi')
        run_gmi(s, sys.argv[i + 1], int(sys.argv[i + 2], 16))
    else:
        send_frame(s, LOAD, bytes([0xDD, 0xCC, 0xBB, 0xAA]), "poke-test")

    s.close()


if __name__ == '__main__':
    main()
