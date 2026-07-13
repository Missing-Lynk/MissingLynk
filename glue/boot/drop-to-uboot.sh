#!/usr/bin/env bash
# drop-to-uboot.sh - get the goggle to the U-Boot `=>` prompt, hands-off, from either slot
# (open slot-B Alpine root/libre by default, or stock slot-A with ROOT_PASS=artosyn).
#
# Deploys the prebuilt `uboot-trigger` (sets the SPL reboot-reason flag, then watchdog-resets),
# fires it without blocking on the SSH that drops at reset, and catches U-Boot's autoboot on
# the serial.
#
# Env overrides: DEVICE_IP (192.168.3.100), ROOT_PASS (libre; use "artosyn" from slot A).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$(dirname "$0")/../lib/ssh-opts.sh"   # provides sshg + the DEVICE_IP/PASS defaults

# Resolve the console port here so a missing ML_SERIAL fails before the SSH deploy, not mid-run.
CONSOLE_PORT="$("$ROOT/.venv/bin/python3" "$HERE/../lib/serial_port.py")" || exit 1

BIN="$HERE/../build/uboot-trigger"
[ -x "$BIN" ] || { echo "[!] $BIN missing; build it first: make -C $HERE/.."; exit 1; }

# /tmp is tmpfs on both slots, a safe dir to stage and exec the helper.
STAGE=/tmp

echo "[*] deploying to $DEVICE_IP:$STAGE (cat-over-ssh; dropbear has no SFTP)..."
if ! cat "$BIN" | sshg "cat >$STAGE/uboot-trigger && chmod +x $STAGE/uboot-trigger"; then
  echo "[!] deploy failed - is the goggle up and reachable at $DEVICE_IP as root/$PASS?"; exit 1
fi

echo "[*] firing trigger (flag + watchdog reset -> SPL -> U-Boot)..."
sshg "$STAGE/uboot-trigger" >/dev/null 2>&1 &
TRIG=$!

echo "[*] catching U-Boot on serial (spamming Enter, <=35s)..."
"$ROOT/.venv/bin/python3" -u "$HERE/wait-for-serial.py" '=>' --timeout 35 --send '\r' --baud 1152000 --port "$CONSOLE_PORT"
rc=$?
kill "$TRIG" 2>/dev/null

if [ "$rc" -eq 0 ]; then
  echo "[*] U-Boot ready (at the => prompt)."
else
  echo "[!] did not reach U-Boot. Re-run (the wdt fire can race), or fall back to the stock-A path."
fi

exit "$rc"
