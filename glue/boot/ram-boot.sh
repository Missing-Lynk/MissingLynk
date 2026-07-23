#!/usr/bin/env bash
# ram-boot.sh - RAM-boot an arbitrary kernel Image + dtb on the goggle, zero flash.
#
# Wraps the OTRA/bootm recipe (this U-Boot REJECTS a raw `booti` of an arm64 Image with
# "magic error!", so the Image is packed into the vendor OTRA + legacy-uImage(lz4) container
# and booted with `bootm`). Nothing is written to flash; bootargs hardcode ubi.mtd=18
# (userapp1 = slot B), so the RAM kernel always mounts slot B's rootfs, and a reset/power-cycle
# returns to whatever slot is actually flashed active (unchanged either way).
#
# Works from EITHER slot: the open slot-B Alpine (root/libre, default) or stock slot-A
# (ROOT_PASS=artosyn).
#
# Usage:   ram-boot.sh [-v] <Image> <dtb> [bootargs]
# -v/--verbose (or ML_VERBOSE=1) streams the full serial boot log instead of just its tail.
# Example: ram-boot.sh path/to/arch/arm64/boot/Image path/to/arch/arm64/boot/proxima-9311.dtb
#
# Preconditions:
#   - The goggle is up and reachable at DEVICE_IP, on either slot (see ROOT_PASS below).
#   - The USB-serial bridge is connected (drop-to-uboot + loady run over it).
#
# Env overrides: DEVICE_IP (192.168.3.100), ROOT_PASS (libre; artosyn from slot A),
#   KADDR (0x24000000 container), DTADDR (0x28000000 dtb), BOOTARGS (default = open cmdline +
#   the full mtdparts, which bootm needs because the dtb carries none), OTRA_TEMPLATE (kernelN
#   container to copy the OTRA header from; default: read from slot-B kernel1), INITRAMFS
#   (unset = boot the flashed rootfs; set to a cpio.gz = boot that instead, e.g.
#   kernel/initramfs/build/initramfs.cpio.gz for the bare-kernel busybox shell),
#   RDADDR (0x26000000 initramfs load addr, between the container and the dtb).
set -euo pipefail

export ML_VERBOSE="${ML_VERBOSE:-0}"
args=()
for a in "$@"; do
  case "$a" in
    -v|--verbose) ML_VERBOSE=1 ;;
    --initramfs) WANT_INITRAMFS=1 ;;
    *) args+=("$a") ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"

IMG="${1:-}"; DTB="${2:-}"
[ -f "$IMG" ] && [ -f "$DTB" ] || { echo "usage: $0 [-v] [--initramfs] <Image> <dtb> [bootargs]"; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$(dirname "$0")/../lib/ssh-opts.sh"   # provides sshg + the DEVICE_IP/PASS defaults
. "$(dirname "$0")/../lib/device.sh"     # resolves DEVICE -> DEV_KADDR/RDADDR/DTADDR + PARTITION
. "$(dirname "$0")/../lib/uboot.sh"

# Load map from the device manifest (DEV_KADDR/RDADDR/DTADDR); env overrides for a one-off. No
# fallback: an incomplete manifest fails loudly rather than silently using another device's map.
KADDR="${KADDR:-$DEV_KADDR}"        # OTRA container (bootm decompresses Image to 0x200a0000)
DTADDR="${DTADDR:-$DEV_DTADDR}"     # dtb load addr (below the MMZ carveout)
RDADDR="${RDADDR:-$DEV_RDADDR}"     # initramfs load addr (only used with --initramfs)
[ -n "$KADDR" ] && [ -n "$DTADDR" ] && [ -n "$RDADDR" ] || {
  echo "[!] incomplete load map for device '$DEVICE' - set DEV_KADDR/DEV_RDADDR/DEV_DTADDR in" >&2
  echo "    devices/$DEVICE/device.mk (or pass KADDR=/RDADDR=/DTADDR= explicitly)" >&2
  exit 1; }

# Boot target: default = the flashed slot-B rootfs (ML_BOOTARGS_DEFAULT / ubi.mtd). --initramfs
# boots the bare busybox initramfs (kernel/initramfs/build/) instead, with a minimal cmdline.
INITRAMFS="${INITRAMFS:-}"
if [ "${WANT_INITRAMFS:-0}" = "1" ] && [ -z "$INITRAMFS" ]; then
  INITRAMFS="$ROOT/kernel/initramfs/build/initramfs.cpio.gz"
fi
if [ -n "${3:-}" ]; then
  BOOTARGS="$3"                                   # explicit positional bootargs
elif [ -z "${BOOTARGS:-}" ]; then
  if [ -n "$INITRAMFS" ]; then
    BOOTARGS="earlycon keep_bootcon ignore_loglevel console=ttyS0,1152000"
  else
    BOOTARGS="$ML_BOOTARGS_DEFAULT"
  fi
fi
PY="$ROOT/.venv/bin/python3"
MKKERNEL="$ROOT/glue/flash/mkkernel.py"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

[ -x "$PY" ]       || { echo "[!] missing $PY"; exit 1; }
[ -f "$MKKERNEL" ] || { echo "[!] missing $MKKERNEL"; exit 1; }
# arm64 Image magic "ARM\x64" at offset 0x38
if [ "$(xxd -s 0x38 -l 4 -p "$IMG")" != "41524d64" ]; then
  echo "[!] $IMG is not an arm64 Image (bad magic at 0x38)"; exit 1; fi
# dtb FDT magic d00dfeed
if [ "$(xxd -l 4 -p "$DTB")" != "d00dfeed" ]; then
  echo "[!] $DTB is not a flattened device tree (bad FDT magic)"; exit 1; fi
# optional initramfs: must exist and be a gzip (cpio.gz) - gzip magic 1f8b
if [ -n "$INITRAMFS" ]; then
  [ -f "$INITRAMFS" ] || { echo "[!] INITRAMFS=$INITRAMFS not found (build it: kernel/initramfs/build.sh)"; exit 1; }
  [ "$(xxd -l 2 -p "$INITRAMFS")" = "1f8b" ] || { echo "[!] $INITRAMFS is not a gzip cpio (bad magic)"; exit 1; }
fi
"$PY" "$HERE/../lib/serial_port.py" >/dev/null 2>&1 || echo "[!] WARNING: ML_SERIAL not set (glue/glue.env); serial steps will fail"
ensure_device_reachable || exit 1
echo "[*] target $DEVICE_IP reachable; Image $(stat -c%s "$IMG") B, dtb $(stat -c%s "$DTB") B"

TPL="${OTRA_TEMPLATE:-}"
if [ -z "$TPL" ]; then
  echo "[*] pulling slot-B kernel1 read-only as OTRA template..."
  KMTD="$(sshg 'grep -m1 "\"kernel1\"" /proc/mtd | cut -d: -f1')"
  [ -n "$KMTD" ] || { echo "[!] could not find kernel1 in /proc/mtd"; exit 1; }
  sshg "cat /dev/$KMTD" > "$SCRATCH/template.bin" 2>/dev/null
  TPL="$SCRATCH/template.bin"
fi
[ "$(xxd -l 4 -p "$TPL")" = "4f545241" ] || { echo "[!] OTRA template has no OTRA magic"; exit 1; }
echo "[*] packing Image into OTRA container..."
"$PY" "$MKKERNEL" pack "$IMG" "$SCRATCH/kernel.bin" --otra-template "$TPL" >/dev/null
echo "[*] container: $(stat -c%s "$SCRATCH/kernel.bin") B"

drop_to_uboot_retry || exit 1

echo "[*] loady dtb -> $DTADDR ..."
ub load "$DTADDR" "$DTB"

# bootm's ramdisk arg: `-` for none, or `addr:size` for a raw cpio.gz at RDADDR.
RDARG="-"
if [ -n "$INITRAMFS" ]; then
  echo "[*] loady initramfs -> $RDADDR ..."
  ub load "$RDADDR" "$INITRAMFS"
  RDARG="$RDADDR:$(printf '0x%x' "$(stat -c%s "$INITRAMFS")")"
  echo "[*] booting the initramfs ($INITRAMFS), NOT the flashed rootfs"
fi

echo "[*] loady container -> $KADDR (~4 min over serial)..."
ub load "$KADDR" "$SCRATCH/kernel.bin"

echo "[*] setenv bootargs + bootm..."
ub cmd "setenv bootargs $BOOTARGS" 4 >/dev/null
ub cmd "bootm $KADDR $RDARG $DTADDR" 110
echo "[+] bootm issued (see serial tail above). The active flashed slot is unchanged by this RAM boot; a reset/power-cycle returns to it."
