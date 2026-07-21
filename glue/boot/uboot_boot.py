#!/usr/bin/env python3
"""
Drive a one-shot custom-kernel boot on the Artosyn goggle, with zero flash risk.

Flow (all over the serial console):
  1. from the running stock Linux: set the U-Boot trigger (devmem TRIGGER_ADDR bit0)
     and watchdog-reset, then stop autoboot -> land at the U-Boot `=>` prompt.
  2. `loady` (YMODEM) the Image, DTB, and optional initramfs into RAM.
  3. `booti` them and capture the kernel's earlycon output.
Nothing is written to flash; a panic/hang reverts on the next power-cycle (the
trigger register is one-shot, so a cold boot returns to the stock slot).

  uboot_boot.py firstboot <Image> <dtb> [initramfs]   # full flow, prints the boot log
  uboot_boot.py uboot                                 # just drop to the => prompt and stop
  uboot_boot.py load <addr-hex> <file>                # YMODEM a file to addr (at the => prompt)
  uboot_boot.py boot <kaddr> <rd|-> <dtaddr> [secs]   # booti + stream the boot log
  uboot_boot.py cmd "<u-boot command>" [secs]         # send a command + stream output

Port from $ML_SERIAL / glue.env (glue/lib/serial_port.py). See
docs/guides/serial-and-debug-access.md (Bootloader recovery) + re/uboot/spl-boot-mode.md.

By default the serial boot log is captured but only the tail is printed.
Set ML_VERBOSE=1 to stream the full log live instead.
"""
import os
import sys
import time

import serial

sys.path.insert(0, os.path.join(os.path.dirname(__file__), os.pardir, 'lib'))
from serial_port import find_port

VERBOSE = os.environ.get('ML_VERBOSE', '0') == '1'

PORT = find_port()
BAUD = 1152000

# One-shot SPL "run full U-Boot" trigger (the reboot-reason flag, same as glue/boot/uboot-trigger.c)
TRIGGER_ADDR = 0x0A106138

# RAM load addresses (within kernel RAM, below the MMZ carveout, per the DTS reserved-memory node)
KADDR = 0x200a0000      # vendor kernel load addr (Image ~41 MiB -> ends ~0x23200000)
RDADDR = 0x26000000     # initramfs: clear of the kernel footprint, below the DTB
DTADDR = 0x28000000     # DTB high + clear of the (large) Image (vendor's 0x22080000 only fits a <~32 MiB kernel)

# Timeouts / pacing (seconds)
AUTOBOOT_TIMEOUT = 28   # window to catch the => prompt after reset
BOOT_CAPTURE_SECS = 40  # default post-boot log capture
SPAM_INTERVAL = 0.02    # how often to send a keystroke to stop autoboot

# YMODEM control bytes + framing
SOH = 0x01              # 128-byte block header
STX = 0x02              # 1024-byte block header
EOT = 0x04              # end of transmission
ACK = 0x06              # acknowledge
NAK = 0x15              # negative acknowledge
CRC = 0x43              # 'C' - receiver requests CRC mode
YMODEM_BLOCK = 1024     # data block size
YMODEM_PAD = 0x1A       # CPMEOF, pads the final short block


def log_quiet(message):
    pass


def log_print(message):
    print(message, flush=True)


def open_serial():
    return serial.Serial(PORT, BAUD, timeout=0.3)


def print_tail(buf, num_lines=40):
    """Quiet-mode fallback: the live stream wasn't printed, so show the last num_lines lines."""
    lines = buf.decode('latin1').splitlines()
    print('\n'.join(lines[-num_lines:]))


def capture(ser, duration):
    """Read from ser for `duration` seconds, streaming live if VERBOSE; return the buffer."""
    start = time.time()
    buf = bytearray()
    while time.time() - start < duration:
        data = ser.read(4096)
        if data:
            buf += data

            if VERBOSE:
                sys.stdout.buffer.write(data)
                sys.stdout.flush()

    return buf


def stream_command(ser, command, duration):
    """Send `command` at the => prompt, then capture its output for `duration` seconds."""
    print(command + " ...", flush=True)
    ser.reset_input_buffer()
    ser.write((command + "\r").encode())
    ser.flush()
    buf = capture(ser, duration)

    if not VERBOSE:
        print_tail(buf)

    return buf


def crc16(data):
    """XMODEM/YMODEM CRC-CCITT, poly 0x1021, init 0 (masked per byte, as the receiver expects)."""
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if (crc & 0x8000) else (crc << 1)

        crc &= 0xffff

    return crc


def _block(seq, data):
    """Frame a YMODEM block: STX (1024B) or SOH (128B) leader + seq bytes + 16-bit CRC."""
    leader = STX if len(data) == YMODEM_BLOCK else SOH
    head = bytes([leader, seq & 0xff, (~seq) & 0xff])
    checksum = crc16(data)
    return head + data + bytes([(checksum >> 8) & 0xff, checksum & 0xff])


def _wait(ser, want, timeout=10.0):
    """Read single bytes until one in `want` arrives or `timeout` elapses; return it or None."""
    start = time.time()
    while time.time() - start < timeout:
        byte = ser.read(1)
        if byte and byte[0] in want:
            return byte[0]

    return None


def ymodem_send(ser, name, data, log=log_quiet):
    if _wait(ser, (CRC,), 15) is None:
        raise RuntimeError("receiver never sent 'C' (loady not ready)")

    header = (name.encode() + b'\x00' + str(len(data)).encode() + b'\x00').ljust(128, b'\x00')
    ser.write(_block(0, header))

    if _wait(ser, (ACK,)) is None:
        raise RuntimeError("header block not ACKed")

    if _wait(ser, (CRC,)) is None:
        raise RuntimeError("no 'C' after header")

    seq = 1
    offset = 0
    total_len = len(data)
    total_blocks = (total_len + YMODEM_BLOCK - 1) // YMODEM_BLOCK
    while offset < total_len:
        chunk = data[offset:offset + YMODEM_BLOCK]
        if len(chunk) < YMODEM_BLOCK:
            chunk = chunk + bytes([YMODEM_PAD]) * (YMODEM_BLOCK - len(chunk))

        block = _block(seq, chunk)
        for _attempt in range(8):                 # resend on NAK or silence
            ser.write(block)
            if _wait(ser, (ACK, NAK), 6) == ACK:
                break
        else:
            raise RuntimeError(f"block {seq} (offset {offset}/{total_len}) failed after 8 tries")

        blocks_done = offset // YMODEM_BLOCK + 1
        if blocks_done % 2000 == 0:
            log(f"  {blocks_done}/{total_blocks} blocks ({offset * 100 // total_len}%)")

        seq = (seq + 1) & 0xff
        offset += YMODEM_BLOCK

    ser.write(bytes([EOT]))

    if _wait(ser, (ACK, NAK), 5) == NAK:
        ser.write(bytes([EOT]))
        _wait(ser, (ACK,), 5)

    if _wait(ser, (CRC,), 5) is not None:         # end-of-batch null header
        ser.write(_block(0, bytes(128)))
        _wait(ser, (ACK,), 5)


def to_uboot(ser, log=log_quiet):
    """From stock Linux: arm the trigger, watchdog-reset, stop autoboot -> `=>`."""
    ser.reset_input_buffer()
    ser.write(b'\r')                              # wake the shell
    time.sleep(0.3)

    ser.reset_input_buffer()
    ser.write(f'/sbin/devmem {TRIGGER_ADDR:#x} 32 1\r'.encode())
    time.sleep(0.6)

    log("trigger set; watchdog reset...")
    ser.write(b'sync; /usr/bin/ar_wdt_service -t 1 >/dev/null 2>&1 & sleep 1; killall ar_wdt_service\r')
    ser.flush()

    start = time.time()
    buf = bytearray()
    last_spam = 0.0
    while time.time() - start < AUTOBOOT_TIMEOUT:
        data = ser.read(512)
        if data:
            buf += data

        now = time.time()
        if now - last_spam > SPAM_INTERVAL:
            # spam to stop autoboot
            ser.write(b' ')
            last_spam = now

        if b'=>' in bytes(buf[-6:]):
            time.sleep(0.4)
            ser.reset_input_buffer()
            log("at U-Boot prompt")

            return True

    return False


def loady(ser, addr, path, log=log_quiet):
    with open(path, 'rb') as f:
        data = f.read()

    log(f"loady {addr:#x} <- {os.path.basename(path)} ({len(data)} bytes)")
    ser.reset_input_buffer()
    ser.write(f"loady {addr:#x}\r".encode())
    ymodem_send(ser, os.path.basename(path), data, log)
    time.sleep(0.3)

    ser.reset_input_buffer()


def firstboot(image, dtb, initrd=None, kaddr=KADDR, dtaddr=DTADDR, rdaddr=RDADDR):
    ser = open_serial()
    if not to_uboot(ser, log_print):
        log_print("FAILED to reach U-Boot prompt")
        ser.close()
        return

    loady(ser, dtaddr, dtb, log_print)            # small DTB first: fail-fast pipeline check
    if initrd:
        loady(ser, rdaddr, initrd, log_print)     # initramfs (~1 MB): boot to a shell, not panic

    loady(ser, kaddr, image, log_print)           # then the big Image (~8 min @1152000)
    if initrd:
        ramdisk_arg = f"{rdaddr:#x}:{os.path.getsize(initrd):#x}"
    else:
        ramdisk_arg = "-"

    buf = stream_command(ser, f"booti {kaddr:#x} {ramdisk_arg} {dtaddr:#x}", BOOT_CAPTURE_SECS)
    ser.close()

    text = buf.decode('latin1')
    alive = any(marker in text for marker in ('MISSINGLYNK', 'Linux version', 'Booting Linux'))
    print(f"\n=== boot {'LOOKS ALIVE' if alive else 'no kernel output (check)'} ===")


def cmd_uboot():
    ser = open_serial()
    print("reached =>" if to_uboot(ser, log_print) else "FAILED")
    ser.close()


def cmd_firstboot(args):
    initrd = args[3] if len(args) > 3 else None
    firstboot(args[1], args[2], initrd)


def cmd_load(args):
    ser = open_serial()
    loady(ser, int(args[1], 16), args[2], log_print)
    ser.close()


def cmd_boot(args):
    duration = float(args[4]) if len(args) > 4 else BOOT_CAPTURE_SECS
    ser = open_serial()
    stream_command(ser, f"booti {args[1]} {args[2]} {args[3]}", duration)
    ser.close()


def cmd_run(args):
    duration = float(args[2]) if len(args) > 2 else BOOT_CAPTURE_SECS
    ser = open_serial()
    stream_command(ser, args[1], duration)
    ser.close()


if __name__ == '__main__':
    args = sys.argv[1:]
    command = args[0] if args else 'uboot'
    if command == 'uboot':
        cmd_uboot()
    elif command == 'firstboot':
        cmd_firstboot(args)
    elif command == 'load':
        cmd_load(args)
    elif command == 'boot':
        cmd_boot(args)
    elif command == 'cmd':
        cmd_run(args)
    else:
        print(__doc__)
