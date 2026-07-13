#!/usr/bin/env bash
# flash-rootfs-b.sh - flash the Alpine open rootfs (rootfs/build/rootfs.ubi) onto slot B's rootfs
# partition (userapp1). Does ONLY the flash step; this is the "flash rootfs" step of a
# 4-step safe-bring-up plan, the others are separate, existing tools:
#
#   1. flip to A     glue/boot/flip-slot.sh a        (so B's UBI volume is inactive/unmounted,
#                                                     safe to reformat; also the fallback if
#                                                     RAM-boot below never happens)
#   2. flash rootfs  glue/flash/flash-rootfs-b.sh   <- THIS SCRIPT (only writes mtd18 = userapp1)
#   3. fall to uboot glue/boot/drop-to-uboot.sh      (interrupt autoboot to the `=>` prompt)
#   4. RAM-boot      glue/boot/ram-boot.sh <Image> <dtb>   (root=ubi:rootfs, ubi.mtd=18 by
#                                                     default - boots the freshly-flashed B
#                                                     from RAM; A stays active until this is
#                                                     proven, per the A/B slot safety rules)
# Only after step 4 boots clean would you ever consider `flip-slot.sh b` to make B active -
# a separate, deliberate action this script does not take.
#
# Why this can't reuse userspace/libre/deploy/flash-kit/flash-b.sh: that script targets the OTHER
# (vendor-squashfs) project and writes with `ubiupdatevol` into an already-existing UBI
# volume. This rootfs is a fresh UBI image (autoresize volume, built by rootfs/build.sh) and
# needs `ubiformat`, which reformats the whole UBI device from scratch. Vendor BusyBox has no
# ubiformat, but the vendor rootfs conveniently ships a real aarch64 one at /etc/ubiformat
# (used internally by artosyn_upgrade), so slot A can flash slot B with no extra binary push.
#
# This script must run while booted on slot A (stock vendor firmware). It refuses to run if
# the device answers as slot B (open Alpine) instead - reformatting the live-mounted rootfs
# out from under itself would be catastrophic. It also refuses if `userapp1` isn't mtd18, so
# a future partition-table change can't silently make it write the wrong thing.
#
# Usage:   glue/flash/flash-rootfs-b.sh [path/to/rootfs.ubi]     # default: rootfs/build/rootfs.ubi
# Env:     DEVICE_IP (default 192.168.3.100)
#
# NOT RUN AUTOMATICALLY BY ANYTHING. Invoke by hand once you're ready for step 2.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
IMG="${1:-$REPO/rootfs/build/rootfs.ubi}"
DEVICE_IP="${DEVICE_IP:-192.168.3.100}"
REMOTE_STAGE="/tmp/rootfs.ubi"

[ -f "$IMG" ] || { echo "rootfs image not found: $IMG (run rootfs/build.sh first)" >&2; exit 1; }
command -v sshpass >/dev/null || { echo "sshpass not installed" >&2; exit 1; }

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

# Locate userapp1 by NAME, never trust a hardcoded mtd number.
TARGET_MTD="$(sshv 'grep -m1 "\"userapp1\"" /proc/mtd' | cut -d: -f1)"
[ -n "$TARGET_MTD" ] || { echo "no userapp1 partition found in /proc/mtd on $DEVICE_IP" >&2; exit 1; }
echo "[*] userapp1 (slot B rootfs) = /dev/$TARGET_MTD"

# Guard rail: never let this become mtd17/userapp0 (slot A) under any circumstance.
A_MTD="$(sshv 'grep -m1 "\"userapp0\"" /proc/mtd' | cut -d: -f1)"
if [ "$TARGET_MTD" = "$A_MTD" ]; then
    echo "refusing: userapp1 resolved to the same mtd as userapp0 ($TARGET_MTD) - aborting." >&2
    exit 1
fi

sshv 'test -x /etc/ubiformat' \
    || { echo "no /etc/ubiformat on the vendor rootfs - unexpected, aborting." >&2; exit 1; }

echo "[*] staging $(basename "$IMG") ($(stat -c%s "$IMG") bytes) to $DEVICE_IP:$REMOTE_STAGE..."
# Dropbear has no SFTP subsystem, stream over a plain ssh channel (cat).
cat "$IMG" | sshv "cat > $REMOTE_STAGE"
# The vendor BusyBox has no `stat` applet (docs/reference/hardware-overview.md); use `wc -c`.
REMOTE_SIZE="$(sshv "wc -c < $REMOTE_STAGE" 2>/dev/null | tr -d '[:space:]')"
[ -n "$REMOTE_SIZE" ] || REMOTE_SIZE=0
[ "$REMOTE_SIZE" = "$(stat -c%s "$IMG")" ] \
    || { echo "staged size mismatch (local $(stat -c%s "$IMG") vs remote $REMOTE_SIZE)" >&2; exit 1; }
echo "[+] staged, size verified"

echo "[*] ubiformat /dev/$TARGET_MTD (userapp1, slot B) - this is the ONLY partition written..."
sshv "/etc/ubiformat /dev/$TARGET_MTD -f $REMOTE_STAGE -y"
sshv "rm -f $REMOTE_STAGE"

echo
echo "[+] slot B rootfs flashed. Slot A is still active and untouched."
echo "    Next: glue/boot/drop-to-uboot.sh, then glue/boot/ram-boot.sh <Image> <dtb>"
echo "    to RAM-boot and prove B before ever flipping the active slot to it."
