#!/usr/bin/env python3
"""
Wait for a substring to appear on a serial console, optionally spamming a key meanwhile.

Generic "catch a prompt" helper: opens a serial port, repeatedly writes `send` (e.g. Enter,
to interrupt a bootloader's autoboot) while reading, and stops as soon as `needle` appears
in the accumulated buffer or `timeout` elapses. Prints a RESULT line and a sanitized tail of
the last bytes seen (control bytes replaced with '.'), then exits 0 if found, 2 if not - so
callers can drive it from a shell one-liner.

Port resolution: --port if given, else the shared glue resolver (glue/lib/serial_port.py:
$ML_SERIAL, or glue/glue.env).

  wait-for-serial.py <needle> [--timeout SECS] [--send BYTES] [--baud BAUD] [--port PORT]
  wait-for-serial.py "=>" --timeout 35 --send $'\\r' --baud 1152000

`needle` and `--send` are Python string literals decoded with `backslashreplace`
unescaping (so "\\r" on the command line becomes a real CR byte).
"""
from __future__ import annotations

import argparse
import os
import sys
import time

import serial

sys.path.insert(0, os.path.join(os.path.dirname(__file__), os.pardir, "lib"))
from serial_port import find_port

READ_CHUNK = 300        # bytes to try to read per poll
POLL_TIMEOUT = 0.15     # serial read timeout; also paces the send-spam loop
TAIL_CHARS = 160        # how much trailing output to report on a timeout

# Failure-tail sanitizing: keep tab/newline/CR and printable ASCII (bytes 9..126) so the
# tail stays readable; replace other control and high bytes with '.'.
KEEP_LOW, KEEP_HIGH, DOT = 9, 127, ord(".")


def _unescape(s: str) -> bytes:
    return s.encode().decode("unicode_escape").encode("latin1")


def _readable_tail(buf: bytes) -> str:
    """Last TAIL_CHARS bytes of `buf`, non-printable bytes shown as '.'."""
    tail = buf[-TAIL_CHARS:]
    return bytes(c if KEEP_LOW <= c < KEEP_HIGH else DOT for c in tail).decode("ascii", "replace")


def wait_for(
    needle: bytes,
    timeout: float = 35.0,
    send: bytes = b"\r",
    baud: int = 115200,
    port: str | None = None,
) -> tuple[bool, str]:
    """
    Spam `send` while reading at `baud` until `needle` is seen or `timeout` elapses.

    Returns (found, tail): tail is the last TAIL_CHARS chars seen (see _readable_tail).
    """
    with serial.Serial(port or find_port(), baud, timeout=POLL_TIMEOUT) as s:
        deadline = time.time() + timeout
        buf = b""
        found = False
        while time.time() < deadline:
            s.write(send)
            buf += s.read(READ_CHUNK)

            if needle in buf:
                found = True
                break

    return found, _readable_tail(buf)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("needle", help="substring to wait for (Python string-escape syntax)")
    ap.add_argument("--timeout", type=float, default=35.0)
    ap.add_argument("--send", default="\\r", help="bytes to spam each read cycle (default: CR)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--port", default=None, help="serial port (default: $ML_SERIAL or glue.env)")
    args = ap.parse_args()

    needle = _unescape(args.needle)
    send = _unescape(args.send)
    found, tail = wait_for(needle, timeout=args.timeout, send=send, baud=args.baud, port=args.port)

    if found:
        print("[=] RESULT: FOUND %r" % needle)
    else:
        print("[=] RESULT: NOT FOUND %r (timeout)" % needle)
        print("[=] tail:", repr(tail))

    sys.exit(0 if found else 2)


if __name__ == "__main__":
    main()
