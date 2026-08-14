#!/usr/bin/env bash
# gg-validate-session.sh - drive the outstanding goggle receive-path checks in one powered window.
#
# Closes what plans/goggle-linkd-validation.md still owes after the 2026-08-14 session: the GET_PAIR
# arm of item 1, the session-start IDR burst of item 4, item 6's SetTranParm re-assert, and item 7's
# liveness gate. Those four want mutually incompatible link states - two need the link DOWN at the
# start, two need it up - so the ordering here is the whole point of the script. Running them as
# separate sessions costs four air-unit power cycles instead of one.
#
# Everything the goggle does is read-only except two commands: `ml-rfcmd bind 0`, which is the
# dry-run form (chip-runtime only, reverted by a power cycle, mlm.h:325), and one ml-linkd restart
# under its own pidfile. No flashing, no binary swap, no module reload.
#
# The air unit is NOT driven from here - it has no daemon to drive and its bind button is physical.
# The script stops at each point where the operator has to act and waits, so the powered time is
# spent on the checks rather than on deciding what to do next.
#
# Usage:
#   glue/capture/gg-validate-session.sh [outdir]      # default: gg-validate-<pid> under the cwd
#
# Env: GG_IP (default 192.168.3.101), GG_PASS (libre), AIR_IP (default 10.0.0.100).
#
# Exit status: 0 if every phase produced its capture, 1 if a phase could not run. The verdicts are
# printed per phase and the raw pcaps are kept, because the judgement is worth re-deriving offline.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/ssh-opts.sh"

DEVICE_IP="${GG_IP:-192.168.3.101}"
PASS="${GG_PASS:-libre}"
AIR_IP="${AIR_IP:-10.0.0.100}"
OUT="${1:-gg-validate-$$}"
RFCMD=/usr/local/bin/ml-rfcmd          # not on a non-interactive ssh PATH; always call it by path
PCAP=/tmp/vph-pcap
FAIL=0

mkdir -p "$OUT"

say()  { printf '\n=== %s ===\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# Wait for the operator, who is the only one who can power the air unit or press its bind button.
prompt() {
    printf '\n>>> %s\n>>> press ENTER when done: ' "$*"
    read -r _
}

# The device side never judges; it measures and the host decides. Same split as gg-health.sh.
pull_and_count() {
    local remote="$1" local_name="$2"
    device_pull "$remote" "$OUT/$local_name" >/dev/null 2>&1 || return 1
    python3 "$HERE/mp-count.py" "$OUT/$local_name" "$AIR_IP"
}

say "preflight"
if ! sshg true 2>/dev/null; then
    echo "cannot reach the goggle at $DEVICE_IP as root/$PASS" >&2
    exit 1
fi
note "goggle reachable at $DEVICE_IP"

# vph-pcap is a static-pie aarch64 build in glue/build; push it once and reuse across phases.
if [ ! -x "$HERE/../build/vph-pcap" ]; then
    echo "missing $HERE/../build/vph-pcap - build it first (glue/Makefile)" >&2
    exit 1
fi
device_push "$HERE/../build/vph-pcap" /tmp || exit 1
note "vph-pcap staged at $PCAP"

sshg "test -x $RFCMD" || { echo "no $RFCMD on the goggle" >&2; exit 1; }
note "ml-rfcmd present"

# ---------------------------------------------------------------------------
# Phase 1 - GET_PAIR (item 1's last arm) and the session-start IDR burst (item 4).
#
# Both need the link DOWN when the capture starts, which is why they are first and share one
# capture. bind is refused outright while an air unit is connected (ml-rx-bind.c:111), and the
# burst only exists at a session start, so a capture that begins after association can never see
# it. The air must be in ITS pair mode for a GET_PAIR reply to come back at all - a bind with no
# peer times out without exercising the arm, which would look like a pass and prove nothing.
# ---------------------------------------------------------------------------
say "phase 1: bind arm + session-start IDR burst (air unit OFF to begin)"
prompt "power the air unit DOWN and confirm the goggle shows no link (LED breathing red)"

note "starting a 180 s capture BEFORE the link forms"
sshg "$PCAP -i sdio0 -p 10000 -s 180 -w /tmp/p1.pcap >/tmp/p1.log 2>&1 &" || FAIL=1
sleep 2

note "requesting a dry-run bind (chip-runtime only; a power cycle reverts it)"
prompt "put the air unit in PAIR mode now (bind button, short press <=2 s per air-bind-button-gpio42)"
sshg "$RFCMD bind 0"
note "waiting out the pair window"
sleep 25

sshg 'grep -E "bind|pair" /var/log/ml-linkd.log | tail -6' | tee "$OUT/p1-bind.txt"
note "expect BINDING then BIND_OK/BIND_FAIL. 'bind refused: an air unit is connected' means the"
note "air was still associated, so the arm did NOT run - power it down and redo this phase."

prompt "now power the air unit UP normally and let it associate"
note "letting the capture run out so the session start is inside it"
sleep 95

say "phase 1 results"
pull_and_count /tmp/p1.pcap p1.pcap | tee "$OUT/p1-counts.txt"
note "item 4 burst: a NON-ZERO IDR_REQUEST count here is the PASS - it is the burst before video"
note "confirms. Zero means the capture missed the session start, not that the gate failed."

# ---------------------------------------------------------------------------
# Phase 2 - item 6, the SetTranParm re-assert after an ml-linkd restart.
#
# Baseline first, because the whole finding is a before/after difference. The restart uses the
# service's own pidfile and polls to zero instances: two ml-linkd on /dev/artosyn_sdio wedge the
# RF chip permanently, and that is the one irreversible mistake available in this script.
# ---------------------------------------------------------------------------
say "phase 2: SetTranParm re-assert across an ml-linkd restart (item 6)"
note "baseline capture, 30 s, before touching anything"
sshg "$PCAP -i sdio0 -p 10000 -s 30 -w /tmp/p2a.pcap 2>&1 | tail -1"
pull_and_count /tmp/p2a.pcap p2a.pcap | tee "$OUT/p2a-counts.txt"

note "restarting ml-linkd under its pidfile"
sshg 'set -e
CH=$(cat /usrdata/missinglynk/rf-channel 2>/dev/null)
start-stop-daemon --stop --pidfile /run/ml-linkd.pid 2>/dev/null || true
n=0
while grep -qx ml-linkd /proc/[0-9]*/comm 2>/dev/null; do
    n=$((n+1))
    [ $n -gt 100 ] && { echo "REFUSING: ml-linkd still present after 10 s"; exit 1; }
    usleep 100000 2>/dev/null || sleep 1
done
echo "zero ml-linkd instances confirmed after $n polls"
ML_OPEN_CHNIDX="$CH" start-stop-daemon --start --background --make-pidfile \
    --pidfile /run/ml-linkd.pid --exec /usr/local/bin/ml-linkd \
    --stdout /var/log/ml-linkd.log --stderr /var/log/ml-linkd.log
sleep 5
echo "instances now: $(grep -lx ml-linkd /proc/[0-9]*/comm 2>/dev/null | wc -l)"' \
    | tee "$OUT/p2-restart.txt" || FAIL=1

note "letting the link re-form, then capturing 30 s again"
sleep 25
sshg "$PCAP -i sdio0 -p 10000 -s 30 -w /tmp/p2b.pcap 2>&1 | tail -1"
pull_and_count /tmp/p2b.pcap p2b.pcap | tee "$OUT/p2b-counts.txt"
note "item 6 verdict: SetTranParm (0x0d) non-zero in the baseline and ZERO after the restart"
note "CONFIRMS the defect. Non-zero in both means the HUD latch self-heals and item 6 closes."

# ---------------------------------------------------------------------------
# Phase 3 - item 7, the liveness gate. Needs the air powered and its telemetry alive while the
# video source specifically stops, which is why it cannot be folded into phase 1's power cycle.
# ---------------------------------------------------------------------------
say "phase 3: liveness gate with the video source stopped (item 7)"
note "ml-linkd is not verbose, so read the gate from the wire and the pipeline, not the log"
prompt "stop ONLY the video source on the air unit, leaving it powered and its telemetry flowing"
note "watching for the video-stall watch (MEDIA_STALL_MS = 6 s) for 40 s"
sshg 'for i in $(seq 8); do
    echo "t=$((i*5))s rx_bytes=$(cat /sys/class/net/sdio0/statistics/rx_bytes)"
    sleep 5
done
echo "--- link events ---"
grep -E "stalled|TX LOST|TX unit|no :10000" /var/log/ml-linkd.log | tail -5' | tee "$OUT/p3-liveness.txt"
note "item 7 verdict: an rx_bytes delta that goes flat and a 'video datagrams stalled' event within"
note "about 6 s is the PASS. Flat bytes with NO event reproduces the 2026-08-10 state."

say "done"
note "artefacts in $OUT/"
prompt "the air unit can be powered down"
exit $FAIL
