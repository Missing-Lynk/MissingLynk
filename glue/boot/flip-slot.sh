#!/usr/bin/env bash
# flip-slot.sh - flip the Artosyn device's active A/B boot slot and reboot into it.
#
# Runs from the host against the live device over SSH. It deploys the static mtdtool +
# wdt-reset helpers, flips the gpt0 active bit with mtdtool, VERIFIES the new active slot by
# reading gpt0 back and parsing it on the host (glue/flash/gpt_setactive.py), and only then
# fires a watchdog reset so the SPL Falcon-boots the freshly selected slot. It never writes
# any slot DATA partition, only gpt0; flipping to a stock slot A is always a safe fallback.
#
# Usage:   flip-slot.sh a|b
# Env:     DEVICE_IP (active device, from board.conf)
#          SRC_PASS  (root password of the CURRENTLY running slot; auto-detected if unset:
#                     tries "libre" = open Alpine, then "artosyn" = stock)
#          NO_RESET=1 to flip + verify only, without rebooting.
#
# After it reboots: slot B (open Alpine) auto-recovers its host IP via the autonet udev rule
# (deadbeef gadget). Slot A (stock) uses a random-MAC rndis gadget, so bring the host link up
# with glue/net/net-up.sh and SSH as root/artosyn to confirm.
set -euo pipefail

TARGET="${1:-}"
case "$TARGET" in
    a|A) TARGET=a ;;
    b|B) TARGET=b ;;
    *)
        echo "usage: $0 a|b" >&2
        exit 2
        ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
MTDTOOL="$REPO/native/build/mtdtool"
WDTRESET="$HERE/../build/wdt-reset"
GPTPARSE="$REPO/glue/flash/gpt_setactive.py"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

. "$(dirname "$0")/../lib/ssh-opts.sh"   # provides sshg + device_ssh (+ DEVICE_IP default)

if [ ! -x "$MTDTOOL" ]; then
    echo "missing $MTDTOOL" >&2
    exit 1
fi

if [ ! -f "$GPTPARSE" ]; then
    echo "missing $GPTPARSE" >&2
    exit 1
fi

if [ ! -x "$WDTRESET" ]; then
    echo "missing $WDTRESET; build it first: make -C $HERE/.." >&2
    exit 1
fi

# Reach whichever slot is running.
#
# The two slots answer at different ADDRESSES, not merely with different passwords: the open slot
# at the unit's own gadget IP from board.conf, stock at $ML_STOCK_IP. Probing passwords against a
# single address therefore fails outright whenever the running slot is the other one, which is
# every flip that starts from stock. ensure_device_reachable probes both and retargets DEVICE_IP
# and PASS, which is what the RAM-boot scripts already rely on. SRC_PASS still forces a password.
[ -n "${SRC_PASS:-}" ] && PASS="$SRC_PASS"
ensure_device_reachable || exit 1
echo "[*] connected to $DEVICE_IP (root/$PASS)"

# Where to stage the static helpers: the open Alpine's /tmp lives on the (often near-full)
# UBIFS rootfs, so use its tmpfs /run; stock A has no writable /run, so /tmp.
case "$PASS" in
    libre) STAGE=/run ;;
    *)     STAGE=/tmp ;;
esac

# Deploy the static helpers (dropbear has no SFTP -> cat over ssh)
echo "[*] deploying mtdtool + wdt-reset to $STAGE..."
device_push_as "$MTDTOOL"  "$STAGE/mtdtool"
device_push_as "$WDTRESET" "$STAGE/wdt-reset"

# Locate gpt0 by name (mtd index varies with kernel partition layout)
GPTMTD="$(sshg 'grep -m1 "\"gpt0\"" /proc/mtd | cut -d: -f1')"
if [ -z "$GPTMTD" ]; then
    echo "no gpt0 partition found in /proc/mtd" >&2
    exit 1
fi
echo "[*] gpt0 = /dev/$GPTMTD"

# Read gpt0 off the device to a local file; show it; and pull the active slot letter (a/b).
read_gpt()    { device_pull "/dev/$GPTMTD" "$1"; }
show_gpt()    { python3 "$GPTPARSE" "$1" | sed 's/^/    /'; }
active_slot() { python3 "$GPTPARSE" "$1" | sed -n 's/^active slot: \([AB]\).*/\1/p' | tr 'AB' 'ab'; }

read_gpt "$SCRATCH/before.bin"
echo "[*] current GPT:"
show_gpt "$SCRATCH/before.bin"
CUR="$(active_slot "$SCRATCH/before.bin")"
echo "[*] current active slot: ${CUR:-unknown}, target: $TARGET"
if [ "$CUR" = "$TARGET" ]; then
    echo "[=] already on slot $TARGET; nothing to flip."
    exit 0
fi

# Flip + verify before any reset
echo "[*] flipping active slot to $TARGET..."
sshg "$STAGE/mtdtool setslot /dev/$GPTMTD $TARGET"
read_gpt "$SCRATCH/after.bin"
echo "[*] re-reading gpt0 to verify:"
show_gpt "$SCRATCH/after.bin"
NEW="$(active_slot "$SCRATCH/after.bin")"
if [ "$NEW" != "$TARGET" ]; then
    echo "[!] verification FAILED: gpt0 still reports '$NEW', not '$TARGET'. NOT resetting." >&2
    exit 1
fi
echo "[+] verified: gpt0 active slot is now $TARGET (only gpt0 was written)."

if [ "${NO_RESET:-}" = "1" ]; then
    echo "[=] NO_RESET set; flip done. Power-cycle or run $STAGE/wdt-reset to boot slot $TARGET."
    exit 0
fi

# Fire the reset, then decide from whether the device is still there.
#
# The helper does not return when the reset lands: the SoC goes down under it. What ssh makes of
# that varies, so the exit status alone is not proof. It reports 255 once keepalives notice the
# dead transport, but a reset measured on the air unit instead left ssh blocked until `timeout`
# killed it at 90 s. Reachability is the ground truth; the status only distinguishes the cases
# where the board survived.
RESET_WAIT="${RESET_WAIT:-120}"

echo "[*] firing watchdog reset; SPL will boot slot $TARGET..."
reset_status=0
device_ssh_timeout "$RESET_WAIT" "$STAGE/wdt-reset" || reset_status=$?

if ! device_ssh_timeout 10 true >/dev/null 2>&1; then
    echo "[+] device went down for reset. It will come up on slot $TARGET."
elif [ "$reset_status" -eq 0 ]; then
    echo "[+] the shortened period did not arm, but the feeder is stopped and the counter is"
    echo "    unfed, so the reset is still on its way. It will come up on slot $TARGET."
else
    echo "[!] still reachable and wdt-reset armed nothing (status $reset_status)." >&2
    echo "    gpt0 already points at $TARGET: power-cycle to boot it." >&2
    exit 1
fi

if [ "$TARGET" = a ]; then
    echo "    Slot A is stock: run glue/net/net-up.sh, then SSH root/artosyn."
else
    echo "    Slot B is open Alpine: autonet should restore the host IP; SSH root/libre."
fi
exit 0
