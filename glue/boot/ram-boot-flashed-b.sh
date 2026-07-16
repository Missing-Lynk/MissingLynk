#!/usr/bin/env bash
# ram-boot-flashed-b.sh - RAM-boot slot B's already-flashed kernel1 + dtb1 straight from
# flash, leaving the active slot pointer untouched. One-shot: nothing is written (gpt0 is
# never touched), so a power-cycle returns to whichever slot GPT bit-47 marks active.
#
# Unlike ram-boot.sh (which YMODEMs Image+dtb from the host over serial, ~4 min), this reads
# the bytes already on flash (kernel1/dtb1, written by glue/flash/flash-kernel-b.sh) into RAM
# via U-Boot `mtd read` - two flash reads + a bootm, seconds not minutes.
#
# Precondition: kernel1/dtb1 already hold a bootable kernel, and the device is reachable to
# drop to U-Boot (either slot; ROOT_PASS as usual).
#
# Flash offsets are fixed by this device's static mtdparts layout. A's U-Boot (uboot0) is
# minimal - no partition names, so read by raw offset on spi-nand0.
#
# Usage:   ram-boot-flashed-b.sh [bootargs]
# Env:     DEVICE_IP (192.168.3.100), ROOT_PASS (libre; artosyn from slot A),
#          KADDR (0x24000000), DTADDR (0x28000000).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$(dirname "$0")/../lib/ssh-opts.sh"   # provides sshg + the DEVICE_IP/PASS defaults
. "$(dirname "$0")/../lib/uboot.sh"

KADDR="${KADDR:-0x24000000}"      # kernel1 RAM load addr
DTADDR="${DTADDR:-0x28000000}"    # dtb1 RAM load addr
KERNEL1_OFFSET=0x1040000          # kernel1 flash offset (fixed by the mtdparts layout)
KERNEL1_SIZE=0x600000             # 6 MiB
DTB1_OFFSET=0x16a0000             # dtb1 flash offset
DTB1_SIZE=0x60000                 # 384 KiB

# This script boots whatever is FLASHED in kernel1/dtb1, which may predate the
# truthful-256-MiB memory node in the DTS. Append mem=148m to the default args:
# harmless with a new DTB (identical truncation), and it stops a stale 1 GiB-node
# dtb1 from letting the kernel run into nonexistent RAM.
BOOTARGS="${1:-${BOOTARGS:-$ML_BOOTARGS_DEFAULT mem=148m}}"

[ -x "$ML_UBOOT_PY" ] || { echo "[!] missing $ML_UBOOT_PY"; exit 1; }

echo "[*] checking $DEVICE_IP is reachable as root/$PASS..."
sshg true 2>/dev/null || { echo "[!] cannot SSH $DEVICE_IP as root/$PASS - is the goggle up and reachable (set ROOT_PASS=artosyn if starting from slot A)?"; exit 1; }

drop_to_uboot_retry || exit 1

echo "[*] mtd read kernel1 ($KERNEL1_OFFSET, $KERNEL1_SIZE) -> $KADDR ..."
ub cmd "mtd read spi-nand0 $KADDR $KERNEL1_OFFSET $KERNEL1_SIZE" 20 | tail -10

echo "[*] mtd read dtb1 ($DTB1_OFFSET, $DTB1_SIZE) -> $DTADDR ..."
ub cmd "mtd read spi-nand0 $DTADDR $DTB1_OFFSET $DTB1_SIZE" 10 | tail -10

echo "[*] setenv bootargs + bootm..."
ub cmd "setenv bootargs $BOOTARGS" 4 >/dev/null
ub cmd "bootm $KADDR - $DTADDR" 110 | tail -20
echo "[+] bootm issued (see serial tail above). gpt0 was never touched; a reset/power-cycle returns to the actual active slot (normally A)."
