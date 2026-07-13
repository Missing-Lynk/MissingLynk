#!/usr/bin/env python3
"""
Serial recon helper for the goggle console via the RP2040 pico-uart-bridge.

Bridge: the pico-uart-bridge UART0 = the by-id -if00 CDC interface (GP0 TX / GP1 RX,
pico-uart-bridge v3.1); auto-detected below, its /dev/ttyACMx number is not stable.
Console baud: BootROM 115200, then U-Boot + Linux 1152000.

  console.py monitor [secs] [baud]              # just log incoming
  console.py send "<cmd>" [baud] [wait]         # send cmd+CR, print reply (Linux shell or U-Boot prompt)
  console.py catch [secs] [key]                 # reboot from the shell, spam <key> to break U-Boot autoboot, log it
"""
from __future__ import annotations

import serial
import time
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), os.pardir, 'lib'))
from serial_port import find_port


PORT = find_port()


def open_port(baud: int | str) -> serial.Serial:
    return serial.Serial(PORT, int(baud), timeout=0.05)


def monitor(secs: float | str = 10, baud: int | str = 1152000) -> None:
    ser = open_port(baud)
    start = time.time()
    while time.time() - start < float(secs):
        data = ser.read(4096)
        if data:
            sys.stdout.buffer.write(data)
            sys.stdout.flush()

    ser.close()


def send(cmd: str, baud: int | str = 1152000, wait: float | str = 2.0) -> None:
    ser = open_port(baud)
    ser.reset_input_buffer()

    # wake the askfirst getty so the cmd is seen
    ser.write(b'\r')
    time.sleep(0.4)

    ser.reset_input_buffer()
    ser.write(cmd.encode() + b'\r')

    start = time.time()
    reply = bytearray()
    while time.time() - start < float(wait):
        data = ser.read(4096)
        if data:
            reply += data

    ser.close()
    sys.stdout.buffer.write(reply)


def listen(secs: float | str = 30, key: str | bytes = '', baud: int | str = 115200) -> None:
    """
    Passively capture at `baud` (default 115200 for the cold-boot BootROM), optionally
    spamming `key` to try to hold the BootROM menu. No reboot -- YOU power-cycle the goggle
    during the window. Logs raw bytes to stdout.
    """
    key_bytes = key.encode() if isinstance(key, str) else key
    ser = open_port(int(baud))
    ser.reset_input_buffer()
    start = time.time()
    last_send = 0.0
    while time.time() - start < float(secs):
        data = ser.read(4096)
        if data:
            sys.stdout.buffer.write(data)                  # stream live, no buffering
            sys.stdout.flush()

        if key_bytes:
            now = time.time()
            if now - last_send > 0.01:
                ser.write(key_bytes)                       # spam "any key" to stop autoboot
                last_send = now

    ser.close()


def enter(secs: float | str = 40, key: str | bytes = '2', baud: int | str = 115200, spam_window: float | str = 1.8) -> None:
    """
    Catch the BootROM menu and select an option. Waits for boot output to start
    (you cold power-cycle), then spams `key` (e.g. '2' for uart) for `spam_window`
    seconds to pick the menu item, then STOPS spamming and just streams the result
    (so it doesn't flood whatever mode we entered). Streams live at `baud`.
    """
    key_bytes = key.encode() if isinstance(key, str) else key
    ser = open_port(int(baud))
    ser.reset_input_buffer()
    start = time.time()
    last_send = 0.0
    first_output = None
    while time.time() - start < float(secs):
        data = ser.read(4096)
        if data:
            if first_output is None:
                first_output = time.time()
            sys.stdout.buffer.write(data)
            sys.stdout.flush()

        if first_output is not None and (time.time() - first_output) < float(spam_window):
            now = time.time()
            if now - last_send > 0.02:
                ser.write(key_bytes)
                last_send = now

    ser.close()


def catch(secs: float | str = 14, key: str | bytes = ' ', capture_baud: int | str = 115200) -> None:
    """
    Force a watchdog reset (sent at the 1152000 Linux-shell baud), then capture at
    `capture_baud` while spamming `key` to interrupt the boot. Normal boot is SPL Falcon
    (SPL->kernel, no full U-Boot), so the catchable entry is the BootROM menu @115200;
    pass 1152000 as the third arg to watch SPL/Linux instead. Logs raw bytes to stdout.
    """
    key_bytes = key.encode() if isinstance(key, str) else key
    # Phase 1: send the reset over the live 1152000 shell. Plain reboot/-f are no-ops
    # (sysrq out); force the PMIC watchdog (arm 1s, stop petting) -> hardware reset.
    ser = open_port(1152000)
    ser.reset_input_buffer()
    ser.write(b'\r')                                   # clear any partial line first
    ser.write(b'sync; /usr/bin/ar_wdt_service -t 1 >/dev/null 2>&1 & sleep 1; killall ar_wdt_service\r')
    ser.flush()
    ser.close()

    # Phase 2: reopen at the capture baud BEFORE the ~2s watchdog fires; read+spam, stream live.
    ser = open_port(int(capture_baud))
    start = time.time()
    last_send = 0.0
    while time.time() - start < float(secs):
        data = ser.read(4096)
        if data:
            sys.stdout.buffer.write(data)
            sys.stdout.flush()

        now = time.time()
        if now - last_send > 0.02:
            ser.write(key_bytes)
            last_send = now

    ser.close()


if __name__ == '__main__':
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)

    commands = {'monitor': monitor, 'listen': listen, 'enter': enter, 'send': send, 'catch': catch}
    commands[args[0]](*args[1:])
