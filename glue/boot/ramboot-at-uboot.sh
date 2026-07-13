#!/usr/bin/env bash
# ramboot-at-uboot.sh - RAM-boot a kernel when the device is ALREADY sitting at the U-Boot
# `=>` prompt. Unlike ram-boot.sh (which starts from Linux: SSH preflight, pull OTRA template,
# drop to U-Boot), this does ONLY the loady + bootm. Use it when you dropped to U-Boot by hand.
#
# IMPORTANT: your serial terminal MUST be closed first. The serial bridge is single-access;
# this script opens the port, and if your terminal still holds it the loady silently does
# nothing ("multiple access on port").
#
# Usage: ramboot-at-uboot.sh [-v] <container.bin> <dtb> [bootargs]
#   <container.bin> = an Image already packed into the OTRA container:
#                     glue/flash/mkkernel.py pack <Image> <container.bin> --otra-template <kernelN>
#   -v/--verbose (or ML_VERBOSE=1) streams the full serial boot log instead of just its tail.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/uboot.sh"   # provides ub + ML_BOOTARGS_DEFAULT

export ML_VERBOSE="${ML_VERBOSE:-0}"
args=()
for a in "$@"; do
  case "$a" in
    -v|--verbose) ML_VERBOSE=1 ;;
    *) args+=("$a") ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"

KBIN="${1:-}"; DTB="${2:-}"
{ [ -f "$KBIN" ] && [ -f "$DTB" ]; } || { echo "usage: $0 [-v] <container.bin> <dtb> [bootargs]"; exit 2; }
KADDR="${KADDR:-0x24000000}"; DTADDR="${DTADDR:-0x28000000}"
BOOTARGS="${3:-${BOOTARGS:-$ML_BOOTARGS_DEFAULT}}"

echo "[*] CLOSE your serial terminal before running this (single-access serial port)."
echo "[*] probing U-Boot (you should see its 'version' banner below):"
probe="$(ub cmd "version" 4 2>&1)"
printf '%s\n' "$probe"
if ! printf '%s' "$probe" | grep -qiE "U-Boot|=>"; then
  echo "[!] no U-Boot response on $("$ML_UBOOT_PY" "$HERE/../lib/serial_port.py" 2>/dev/null || echo '?')."
  echo "    -> Is your serial terminal fully CLOSED? Is the device still at the => prompt?"
  echo "    -> Is ML_SERIAL / glue.env pointing at the right port?"
  exit 1
fi

echo "[*] U-Boot is responding. loady dtb -> $DTADDR ..."
ub load "$DTADDR" "$DTB"

echo "[*] loady container -> $KADDR (~4 min over serial)..."
ub load "$KADDR" "$KBIN"

echo "[*] setenv bootargs + bootm (streaming boot log)..."
ub cmd "setenv bootargs $BOOTARGS" 4 >/dev/null
ub cmd "bootm $KADDR - $DTADDR" 110

echo "[*] done. If it booted, reconnect SSH. Nothing was flashed."
