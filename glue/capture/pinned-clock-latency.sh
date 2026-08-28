#!/usr/bin/env bash
# pinned-clock-latency.sh - measure goggle latency at one or more pixel-clock rates, back to back
# on a single boot, against whatever source is feeding the goggle.
#
# The panel's refresh and the source's frame rate beat against each other at their difference, and
# that beat is what ml-pipeline reports as jud= and rep=. Measuring two clock rates across a reboot
# confounds that beat with scene content, decoder warm-up and air-link conditions; measuring them
# minutes apart on one boot does not. The leaf is a runtime knob
# (/sys/kernel/debug/ar9311_pixclk_rate), and the CGU ramps a rate change in ~0.05 % steps, one per
# frame interval, so a leg change costs about a second of settling and no reboot.
#
# Each leg records the evidence needed to tell a real difference from a clock that did not land:
# the leaf sampled throughout, and the DSI's INT_ST1 latch, read twice so a bit that re-arms is
# distinguishable from one latched once.
#
# PREREQ:
#   - goggle reachable at DEVICE_IP as root/ROOT_PASS, ml-video running, video actually flowing
#   - /usrdata/missinglynk/latstats and latraw exist (ml-video-up reads them at start)
#   - pacing OFF: with the servo running it walks the leaf off the set rate within seconds
#   - /tmp/ml-phypeek/ml-phypeek present for INT_ST1 (optional; the run notes its absence)
#
# Usage:
#   glue/capture/pinned-clock-latency.sh                      # 148500000, 153646640, 148500000
#   SECS=180 glue/capture/pinned-clock-latency.sh 148500000
#   glue/capture/pinned-clock-latency.sh 148500000 145964175
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

# The mode rate ar_vo_pipe_enable applies at CRTC enable. Every leg is restored to it on exit so an
# interrupted run never leaves the panel on a rate the DSI was not initialised for.
MODE_HZ=148500000
PIXCLK=/sys/kernel/debug/ar9311_pixclk_rate
PHYPEEK=/tmp/ml-phypeek/ml-phypeek
DSI_INT_ST1=0x88500c0

SECS="${SECS:-120}"
SETTLE="${SETTLE:-8}"
OUT_BASE="${OUT_BASE:-$REPO/out/pinned-clock-latency}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# shellcheck source=../lib/ssh-opts.sh
. "$HERE/../lib/ssh-opts.sh"
# shellcheck source=../lib/capture-identity.sh
. "$HERE/../lib/capture-identity.sh"

LEGS=("$@")
[ "${#LEGS[@]}" -gt 0 ] || LEGS=("$MODE_HZ" 153646640 "$MODE_HZ")

# Name the run by capture time then flashed build, so a listing is in order, so two runs of this script are comparable by directory
# name alone. Taken from the device: the goggle can be running an older bundle than the checkout.
# shellcheck disable=SC2016  # ML_VERSION is sourced and expanded on the device, in the remote shell
DEVICE_VERSION="$(sshg '. /etc/ml-release 2>/dev/null; echo "$ML_VERSION"' </dev/null 2>/dev/null |
                  tr -cd 'A-Za-z0-9._-')"
RUNDIR="${OUT:-$OUT_BASE/$STAMP-${DEVICE_VERSION:-unknown}}"

mkdir -p "$RUNDIR"
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$RUNDIR/run.log"; }

restore() {
    sshg "echo $MODE_HZ > $PIXCLK" </dev/null >/dev/null 2>&1
    log "restored the leaf to $MODE_HZ ($(sshg "cat $PIXCLK" </dev/null 2>/dev/null))"
}
trap restore EXIT INT TERM

# The servo overrides any rate written here, so a run with pacing armed measures the servo rather
# than the leg.
if sshg 'test -f /usrdata/missinglynk/pace' </dev/null 2>/dev/null; then
    echo "pacing is armed (/usrdata/missinglynk/pace); move it aside before measuring" >&2
    exit 1
fi

for f in latstats latraw; do
    sshg "test -f /usrdata/missinglynk/$f" </dev/null 2>/dev/null && continue
    echo "/usrdata/missinglynk/$f is absent; ml-pipeline emits no trace to measure" >&2
    echo "create it and restart ml-video, which is when ml-video-up reads it" >&2
    exit 1
done

HAVE_PEEK=0
sshg "test -x $PHYPEEK" </dev/null 2>/dev/null && HAVE_PEEK=1
[ "$HAVE_PEEK" = 1 ] || log "note: $PHYPEEK absent, INT_ST1 not sampled (/tmp is tmpfs; re-push it)"

# Not 2>&1: a failure here belongs on the console, not written into the artifact as though it were
# the identity. The header check catches a capture that produced nothing usable, which is worth
# stopping for - a run nobody can attribute to a build is not worth the air-unit battery.
if ! capture_identity "$REPO" > "$RUNDIR/identity.txt" ||
   ! grep -q 'host tree' "$RUNDIR/identity.txt"; then
    echo "could not record the run identity; fix that before measuring" >&2
    exit 1
fi

log "$SECS s per leg, ${#LEGS[@]} legs: ${LEGS[*]}"

for i in "${!LEGS[@]}"; do
    want="${LEGS[$i]}"
    leg="$RUNDIR/leg$((i + 1))-$want"
    mkdir -p "$leg"

    sshg "echo $want > $PIXCLK" </dev/null >/dev/null 2>&1
    sleep "$SETTLE"
    got=$(sshg "cat $PIXCLK" </dev/null 2>/dev/null)
    log "leg $((i + 1)): asked $want, leaf reads ${got:-unknown}"

    # Sample the leaf and the DSI latch for the whole leg, so a rate that drifted or an overrun
    # that fired midway is visible against the latency numbers rather than assumed absent.
    peek="echo na na"
    [ "$HAVE_PEEK" = 1 ] && peek="$PHYPEEK $DSI_INT_ST1; $PHYPEEK $DSI_INT_ST1"
    (
        printf 'epoch,pixclk_hz,int_st1_a,int_st1_b\n'
        while :; do
            read -r clk a b <<<"$(sshg "cat $PIXCLK; { $peek; } | sed -n 's/.*= \(0x[0-9a-f]*\).*/\1/p'" \
                </dev/null 2>/dev/null | tr '\n' ' ')"
            printf '%s,%s,%s,%s\n' "$(date +%s)" "${clk:-na}" "${a:-na}" "${b:-na}"
            sleep 10
        done
    ) > "$leg/clock.csv" &
    poller=$!

    OUT="$leg" SECS="$SECS" "$HERE/goggle-latency-capture.sh" >> "$RUNDIR/run.log" 2>&1
    rc=$?

    kill "$poller" 2>/dev/null
    wait "$poller" 2>/dev/null

    [ "$rc" -eq 0 ] || log "leg $((i + 1)): capture failed with $rc"

    # Fold what the leg's clock did into its own summary. Kept as scalars beside the latency
    # medians so one file answers both "what was the panel doing" and "what did that cost".
    ASKED="$want" CAPTURE="$leg" python3 "$HERE/summary-merge.py" || \
        log "leg $((i + 1)): could not merge the clock trace into summary.json"
done

log "artifacts in $RUNDIR"
