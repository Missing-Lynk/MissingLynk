#!/usr/bin/env bash
# flash-kernel-b.sh - flash a kernel Image + dtb onto slot B (kernel1 + dtb1). Does ONLY the
# flash step, per glue/docs/flash-and-verify-slots.md "Step 2":
#
#   0. RAM-boot the CANDIDATE Image+dtb first, from files, with A still active - proves
#      the new kernel/dtb/slot-B-rootfs combo boots end to end with nothing flashed.
#      Example: ROOT_PASS=artosyn glue/boot/ram-boot.sh <Image> <dtb>
#      Do NOT proceed past a failure here.
#   1. glue/flash/flash-kernel-b.sh [Image] [dtb]   <- THIS SCRIPT (only writes mtd for kernel1/dtb1)
#   2. Verify the flash write, both by readback (this script does that itself, see below)
#      AND by RAM-booting the ACTUAL flashed bytes straight off kernel1/dtb1 (the
#      guide's "gold-standard alternative" - proves the on-flash copy is bootable, not
#      just byte-identical): ROOT_PASS=artosyn glue/boot/ram-boot-flashed-b.sh
#   3. Only then would you ever consider flipping the active slot - a separate,
#      deliberate action (glue/boot/flip-slot.sh b) this script does not take.
#
# This script must run while booted on slot A (stock vendor firmware). It refuses to run
# if the device answers as slot B (open Alpine) instead - never write a slot while it's
# the one actually running. It also refuses if kernel1/dtb1 don't resolve to mtd14/mtd16
# as expected, so a future partition-table change can't silently write the wrong thing.
#
# The kernel Image must be packed into the vendor's OTRA+uImage container before it can be
# flashed (see glue/flash/mkkernel.py); this script does that automatically, using kernel1's
# OWN current (pre-overwrite) bytes as the OTRA header template - the same convention
# glue/boot/ram-boot.sh uses by default. The dtb is written raw, no packing needed.
#
# native/mtdtool (this repo's static aarch64 raw-NAND writer) is not on the vendor rootfs,
# so it's pushed to the device first, same as glue/boot/flip-slot.sh.
#
# Usage:   glue/flash/flash-kernel-b.sh [Image] [dtb]   # default: the kernel build dir's artifacts
# Env:     DEVICE_IP (default 192.168.3.100)
#          BUILD_DIR (kernel build tree; default from kernel/scripts/pin.env)
#
# NOT RUN AUTOMATICALLY BY ANYTHING. Invoke by hand once you're ready for step 1.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

# Default to the reproducible kernel build's artifacts, like flash-rootfs-b.sh defaults to
# rootfs/build/rootfs.ubi. Override the whole build location with BUILD_DIR=, or pass an
# explicit Image/dtb as positional args. Only one board DTS exists (proxima-9311).
# shellcheck source=/dev/null
source "$REPO/kernel/scripts/pin.env" 2>/dev/null || true
BUILD_DIR="${BUILD_DIR:-${KERNEL_BUILD_DEFAULT:-}}"
IMG="${1:-$BUILD_DIR/linux/arch/arm64/boot/Image}"
DTB="${2:-$BUILD_DIR/linux/arch/arm64/boot/proxima-9311.dtb}"
[ -f "$IMG" ] && [ -f "$DTB" ] || {
    echo "usage: $0 [Image] [dtb]   (default: kernel build dir; override with args or BUILD_DIR=)" >&2
    echo "  Image: $IMG" >&2
    echo "  dtb:   $DTB" >&2
    exit 2
}

DEVICE_IP="${DEVICE_IP:-192.168.3.100}"
MTDTOOL="$REPO/native/mtdtool"
MKKERNEL="$HERE/mkkernel.py"
PY="$REPO/.venv/bin/python3"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

command -v sshpass >/dev/null || { echo "sshpass not installed" >&2; exit 1; }
[ -x "$PY" ]       || { echo "missing $PY" >&2; exit 1; }
[ -f "$MKKERNEL" ] || { echo "missing $MKKERNEL" >&2; exit 1; }

# Legacy-crypto Dropbear on the vendor (slot A) system - see docs/guides/serial-and-debug-access.md.
. "$(dirname "$0")/../lib/ssh-opts.sh"
SSHOPTS=("${SSH_OPTS_LEGACY[@]}")
sshv() { sshpass -p artosyn ssh "${SSHOPTS[@]}" root@"$DEVICE_IP" "$@"; }

echo "[*] checking $DEVICE_IP is booted on slot A (stock vendor)..."
if ! sshv true 2>/dev/null; then
    if sshpass -p libre ssh -o ConnectTimeout=6 "${SSH_OPTS_LIBRE[@]}" root@"$DEVICE_IP" true 2>/dev/null; then
        echo "refusing: $DEVICE_IP is on slot B (open Alpine), not slot A." >&2
        echo "  Run: glue/boot/flip-slot.sh a   (then re-run this script once it's back up)" >&2
        exit 1
    fi
    echo "cannot SSH to $DEVICE_IP as root/artosyn - is it booted and on slot A?" >&2
    exit 1
fi
echo "[+] confirmed: slot A (root/artosyn)"

# Locate kernel1/dtb1 by NAME, never trust hardcoded mtd numbers.
K_MTD="$(sshv 'grep -m1 "\"kernel1\"" /proc/mtd' | cut -d: -f1)"
D_MTD="$(sshv 'grep -m1 "\"dtb1\"" /proc/mtd' | cut -d: -f1)"
[ -n "$K_MTD" ] || { echo "no kernel1 partition found in /proc/mtd on $DEVICE_IP" >&2; exit 1; }
[ -n "$D_MTD" ] || { echo "no dtb1 partition found in /proc/mtd on $DEVICE_IP" >&2; exit 1; }
echo "[*] kernel1 (slot B kernel) = /dev/$K_MTD"
echo "[*] dtb1    (slot B dtb)    = /dev/$D_MTD"

# Guard rail: never let these resolve to the slot-A partitions under any circumstance.
K0_MTD="$(sshv 'grep -m1 "\"kernel0\"" /proc/mtd' | cut -d: -f1)"
D0_MTD="$(sshv 'grep -m1 "\"dtb0\"" /proc/mtd' | cut -d: -f1)"
[ "$K_MTD" != "$K0_MTD" ] || { echo "refusing: kernel1 resolved to the same mtd as kernel0 ($K_MTD)" >&2; exit 1; }
[ "$D_MTD" != "$D0_MTD" ] || { echo "refusing: dtb1 resolved to the same mtd as dtb0 ($D_MTD)" >&2; exit 1; }

# --- OTRA template: kernel1's own current bytes (read-only, before we overwrite it) -----
echo "[*] pulling kernel1's current bytes as the OTRA header template..."
sshv "cat /dev/$K_MTD" > "$SCRATCH/kernel1-template.bin" 2>/dev/null
[ "$(head -c4 "$SCRATCH/kernel1-template.bin")" = "OTRA" ] \
    || { echo "kernel1 readback has no OTRA magic - unexpected, aborting." >&2; exit 1; }

# --- pack ----------------------------------------------------------------------------
echo "[*] packing $IMG into the OTRA container..."
"$PY" "$MKKERNEL" pack "$IMG" "$SCRATCH/kernel1-container.bin" \
    --otra-template "$SCRATCH/kernel1-template.bin"
"$PY" "$MKKERNEL" size "$IMG" \
    || { echo "refusing: packed Image does not fit the 6 MiB kernel slot" >&2; exit 1; }

# --- stage mtdtool + payloads ---------------------------------------------------------
[ -x "$MTDTOOL" ] || { echo "missing $MTDTOOL (run native/build.sh first)" >&2; exit 1; }
STAGE=/tmp
echo "[*] deploying mtdtool + payloads to $DEVICE_IP:$STAGE..."
cat "$MTDTOOL" | sshv "cat >$STAGE/mtdtool && chmod +x $STAGE/mtdtool"
cat "$SCRATCH/kernel1-container.bin" | sshv "cat >$STAGE/kernel1-container.bin"
cat "$DTB" | sshv "cat >$STAGE/dtb1.bin"

# The vendor BusyBox has no `stat` applet (docs/reference/hardware-overview.md); use `wc -c`.
remote_size() { sshv "wc -c < $1" 2>/dev/null | tr -d '[:space:]'; }
K_LOCAL_SIZE="$(wc -c < "$SCRATCH/kernel1-container.bin" | tr -d '[:space:]')"
D_LOCAL_SIZE="$(wc -c < "$DTB" | tr -d '[:space:]')"
[ "$(remote_size "$STAGE/kernel1-container.bin")" = "$K_LOCAL_SIZE" ] \
    || { echo "kernel container staged size mismatch" >&2; exit 1; }
[ "$(remote_size "$STAGE/dtb1.bin")" = "$D_LOCAL_SIZE" ] \
    || { echo "dtb staged size mismatch" >&2; exit 1; }
echo "[+] staged, sizes verified"

# --- flash: kernel1 then dtb1, slot B ONLY --------------------------------------------
echo "[*] mtdtool erase+write /dev/$K_MTD (kernel1, slot B)..."
sshv "$STAGE/mtdtool erase /dev/$K_MTD && $STAGE/mtdtool write /dev/$K_MTD $STAGE/kernel1-container.bin"
echo "[*] mtdtool erase+write /dev/$D_MTD (dtb1, slot B)..."
sshv "$STAGE/mtdtool erase /dev/$D_MTD && $STAGE/mtdtool write /dev/$D_MTD $STAGE/dtb1.bin"

# --- verify by readback ---------------------------------------------------------------
# glue/docs/flash-and-verify-slots.md: sha256 of the readback, trimmed to the image
# length, against the artifact. mtdN char device readback is ECC-corrected.
echo "[*] verifying by readback (sha256, trimmed to image length)..."
K_LOCAL_SHA="$(sha256sum "$SCRATCH/kernel1-container.bin" | cut -d' ' -f1)"
D_LOCAL_SHA="$(sha256sum "$DTB" | cut -d' ' -f1)"
K_REMOTE_SHA="$(sshv "head -c $K_LOCAL_SIZE /dev/$K_MTD | sha256sum" | cut -d' ' -f1)"
D_REMOTE_SHA="$(sshv "head -c $D_LOCAL_SIZE /dev/$D_MTD | sha256sum" | cut -d' ' -f1)"
[ "$K_LOCAL_SHA" = "$K_REMOTE_SHA" ] || { echo "kernel1 readback sha256 MISMATCH: local=$K_LOCAL_SHA remote=$K_REMOTE_SHA" >&2; exit 1; }
[ "$D_LOCAL_SHA" = "$D_REMOTE_SHA" ] || { echo "dtb1 readback sha256 MISMATCH: local=$D_LOCAL_SHA remote=$D_REMOTE_SHA" >&2; exit 1; }
echo "[+] readback verified: kernel1 and dtb1 match exactly what was packed/pushed."

sshv "rm -f $STAGE/mtdtool $STAGE/kernel1-container.bin $STAGE/dtb1.bin"

echo
echo "[+] slot B kernel + dtb flashed and verified (readback sha256 match). Slot A is still active and untouched."
echo "    Next: RAM-boot the ACTUAL FLASHED bytes straight off kernel1/dtb1 to prove them end to end:"
echo "      ROOT_PASS=artosyn glue/boot/ram-boot-flashed-b.sh"
echo "    Only after that succeeds would you flip the active slot: glue/boot/flip-slot.sh b"
