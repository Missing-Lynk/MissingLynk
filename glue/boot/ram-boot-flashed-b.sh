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
# A's U-Boot (uboot0) is minimal - no partition names, so read by raw offset on spi-nand0. The
# offsets come from the active device's partition table (DEV_MTDPARTS in devices/<name>/device.mk).
#
# Usage:   ram-boot-flashed-b.sh [bootargs]
# Env:     DEVICE_IP (active device, from board.conf), ROOT_PASS (libre; artosyn from slot A),
#          KADDR (0x24000000), DTADDR (0x28000000).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/ssh-opts.sh"   # provides sshg + the DEVICE_IP/PASS defaults
. "$HERE/../lib/device.sh"     # resolves DEVICE -> DEV_KADDR/DTADDR
. "$HERE/../lib/uboot.sh"

KADDR="${KADDR:-$DEV_KADDR}"      # kernel1 RAM load addr
DTADDR="${DTADDR:-$DEV_DTADDR}"   # dtb1 RAM load addr
[ -n "$KADDR" ] && [ -n "$DTADDR" ] || {
  echo "[!] no load map for device '$DEVICE' - set DEV_KADDR/DEV_DTADDR in devices/$DEVICE/device.mk" >&2
  exit 1; }
# kernel1/dtb1 flash offsets and sizes, derived from the device's partition table rather than
# restated, so a device with a different layout needs no edit here.
KERNEL1_GEOMETRY="$(mtdparts_partition kernel1 || true)"
DTB1_GEOMETRY="$(mtdparts_partition dtb1 || true)"
[ -n "$KERNEL1_GEOMETRY" ] && [ -n "$DTB1_GEOMETRY" ] || {
  echo "[!] no kernel1/dtb1 in device '$DEVICE' partition table - set DEV_MTDPARTS in devices/$DEVICE/device.mk" >&2
  exit 1; }
read -r KERNEL1_OFFSET KERNEL1_SIZE <<<"$KERNEL1_GEOMETRY"
read -r DTB1_OFFSET DTB1_SIZE <<<"$DTB1_GEOMETRY"

# No mem= here. An earlier version appended mem=148m to guard against a stale dtb1 whose
# memory node claimed 1 GiB, on the reasoning that it was a no-op against the truthful
# 256-MiB node. It is not a no-op: the camera carveouts sit at 0x28000000..0x2d000000, so
# a 148 MiB view (ending 0x29400000) puts isp-cma and vif-cma outside RAM entirely and cuts
# cvisp-cma in half, while mmz (48 MiB), the surviving cvisp-cma (26 MiB) and CONFIG_CMA's
# 56 MiB still come off the top. That leaves "Memory: 5656K/151552K available" and the
# kernel OOM-kills itself in chr_dev_init before reaching userspace; U-Boot then falls back
# to slot A. Measured on the console 2026-08-05.
#
# The stale-dtb1 hazard it guarded against is covered by flash-kernel-b.sh, which writes
# dtb1 alongside kernel1 and verifies both by readback. Pass BOOTARGS explicitly to override.
BOOTARGS="${1:-${BOOTARGS:-$ML_BOOTARGS_DEFAULT}}"

[ -x "$ML_UBOOT_PY" ] || { echo "[!] missing $ML_UBOOT_PY"; exit 1; }

echo "[*] checking $DEVICE_IP is reachable as root/$PASS..."
ensure_device_reachable || exit 1

drop_to_uboot_retry || exit 1

echo "[*] mtd read kernel1 ($KERNEL1_OFFSET, $KERNEL1_SIZE) -> $KADDR ..."
ub cmd "mtd read spi-nand0 $KADDR $KERNEL1_OFFSET $KERNEL1_SIZE" 20 | tail -10

echo "[*] mtd read dtb1 ($DTB1_OFFSET, $DTB1_SIZE) -> $DTADDR ..."
ub cmd "mtd read spi-nand0 $DTADDR $DTB1_OFFSET $DTB1_SIZE" 10 | tail -10

echo "[*] setenv bootargs + bootm..."
ub cmd "setenv bootargs $BOOTARGS" 4 >/dev/null
ub cmd "bootm $KADDR - $DTADDR" 110 | tail -20
echo "[+] bootm issued (see serial tail above). gpt0 was never touched; a reset/power-cycle returns to the actual active slot (normally A)."
