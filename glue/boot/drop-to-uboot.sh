#!/usr/bin/env bash
# drop-to-uboot.sh - get the goggle to the U-Boot `=>` prompt, hands-off, from either slot
# (open slot-B Alpine root/libre by default, or stock slot-A with ROOT_PASS=artosyn).
#
# Deploys the prebuilt `uboot-trigger` (sets the SPL reboot-reason flag, then watchdog-resets),
# opens the serial catcher and waits for it to be listening, then fires the trigger without
# blocking on the SSH that drops at reset.
#
# Env overrides: DEVICE_IP (active device, from board.conf), ROOT_PASS (libre; use "artosyn" from slot A).
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
if ! device_push_as "$BIN" "$STAGE/uboot-trigger"; then
  echo "[!] deploy failed - is the goggle up and reachable at $DEVICE_IP as root/$PASS?"; exit 1
fi

# The catcher starts BEFORE the trigger, and the trigger waits until it is listening.
#
# uboot-trigger shortens the armed period, so the reset lands seconds after it runs rather than
# most of a minute later, and there is no longer enough slack to hide a venv Python importing
# pyserial and opening the port. Statement order alone would not be a guarantee; the LISTENING
# line on the catcher's stderr is.
CATCH_LOG="$(mktemp)"
trap 'rm -f "$CATCH_LOG"' EXIT

echo "[*] catching U-Boot on serial (spamming Enter, <=90s)..."
"$ROOT/.venv/bin/python3" -u "$HERE/wait-for-serial.py" '=>' --timeout 90 --send '\r' \
    --baud 1152000 --port "$CONSOLE_PORT" 2>"$CATCH_LOG"  &
CATCHER=$!

waited=0
while [ "$waited" -lt 100 ] && ! grep -q LISTENING "$CATCH_LOG" 2>/dev/null; do
  sleep 0.1
  waited=$((waited + 1))
done

if ! grep -q LISTENING "$CATCH_LOG" 2>/dev/null; then
  echo "[!] the catcher did not open $CONSOLE_PORT within 10s; not firing the trigger." >&2
  kill "$CATCHER" 2>/dev/null
  exit 1
fi

echo "[*] firing trigger (flag + watchdog reset -> SPL -> U-Boot)..."
sshg "$STAGE/uboot-trigger" >/dev/null 2>&1 &
TRIG=$!

wait "$CATCHER"
rc=$?
kill "$TRIG" 2>/dev/null
cat "$CATCH_LOG" >&2

if [ "$rc" -eq 0 ]; then
  echo "[*] U-Boot ready (at the => prompt)."
else
  echo "[!] did not reach U-Boot. Re-run (the wdt fire can race), or fall back to the stock-A path."
fi

exit "$rc"
