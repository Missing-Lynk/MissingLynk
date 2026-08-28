#!/usr/bin/env bash
# latency-matrix.sh - measure display latency across the four encoder configurations, one boot.
#
# Display latency is what the panel shows; recording and the RTSP restream sit beside it and both
# feed the same wave5 encoder instance, so the interesting question is what each costs the display.
# The four states are the 2x2 of them:
#
#   base    recording off, restream off   the display-only floor
#   rec     recording on,  restream off   the encoder plus the file writer and the SD card
#   stream  recording off, restream on    the encoder with no file branch
#   both    recording on,  restream on    what a flight with the companion app connected runs
#
# Legs run back to back on one boot and one air-unit session, because the phase the pacing servo
# settles on is per pipeline generation and does not survive a restart, so legs from different
# boots are not comparable to each other.
#
# The restream is measured with a client attached. An enabled restream with nobody pulling it still
# runs the encoder but sends nothing, which is not the configuration anyone flies, so this refuses
# to record a stream leg unless a client is connected. Start one on the host first, on the receiver
# rig or with any RTSP consumer:
#
#   ffplay -fflags nobuffer rtsp://<goggle>:554/venc8/stream
#
# PREREQ:
#   - goggle reachable at DEVICE_IP as root/ROOT_PASS, air unit powered and passing video
#   - glue/capture/latency-baseline.sh has armed the measurement knobs
#   - an SD card mounted at /mnt/sdcard for the recording legs
#   - ml-rec on the device understands `rtsp on|off` (userspace ae2ba7d or later)
#
# Usage:
#   glue/capture/latency-matrix.sh
#   SECS=120 LEGS="base rec" glue/capture/latency-matrix.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

SECS="${SECS:-90}"
LEGS="${LEGS:-base rec stream both}"
SETTLE="${SETTLE:-12}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# shellcheck source=../lib/ssh-opts.sh
. "$HERE/../lib/ssh-opts.sh"

MLREC="${MLREC:-/usrdata/missinglynk/ml-rec}"

# Recording is a toggle, the restream an idempotent set, so recording has to be read before it can
# be driven. MLM_STATE_F_RTSP reports the restream, but the pipeline's own log is the only reading
# available from a shell, so use the file handle instead: a recording pipeline holds one open.
rec_is_on() {
    sshg 'p=$(pgrep ml-pipeline | tail -1)
          [ -n "$p" ] && ls -l /proc/$p/fd 2>/dev/null | grep -q "/mnt/sdcard/.*\.mp4"' </dev/null
}

set_rec() {   # <on|off>
    local want="$1"
    if rec_is_on; then
        [ "$want" = on ] && return 0
    else
        [ "$want" = off ] && return 0
    fi

    sshg "$MLREC toggle" </dev/null >/dev/null 2>&1
    sleep 3
}

set_rtsp() {  # <on|off>
    sshg "$MLREC rtsp $1" </dev/null >/dev/null 2>&1 || {
        echo "ml-rec has no rtsp subcommand on this device; push a newer one" >&2
        return 1
    }
}

client_attached() {
    sshg 'ss -tn 2>/dev/null | grep -q ":554 " || netstat -tn 2>/dev/null | grep -q ":554 .*ESTAB"' </dev/null
}

leg_state() {  # <leg> -> "<rec> <rtsp>"
    case "$1" in
        base)   echo "off off" ;;
        rec)    echo "on off"  ;;
        stream) echo "off on"  ;;
        both)   echo "on on"   ;;
        *)      echo "" ;;
    esac
}

RUN="$REPO/out/latency-matrix/$STAMP"
mkdir -p "$RUN"
echo "writing $RUN"

for leg in $LEGS; do
    state="$(leg_state "$leg")"
    if [ -z "$state" ]; then
        echo "unknown leg '$leg', expected one of base rec stream both" >&2
        exit 2
    fi

    # shellcheck disable=SC2086  # two words, deliberately split
    set -- $state
    want_rec="$1" want_rtsp="$2"

    echo
    echo "=== leg $leg (recording $want_rec, restream $want_rtsp)"
    set_rtsp "$want_rtsp" || exit 1
    set_rec "$want_rec"
    sleep "$SETTLE"

    if [ "$want_rtsp" = on ] && ! client_attached; then
        echo "no RTSP client connected; a stream leg with nobody pulling measures the wrong thing" >&2
        echo "start one, then re-run with LEGS=\"$leg ...\"" >&2
        set_rtsp off
        set_rec off
        exit 1
    fi

    if [ "$want_rec" = on ] && ! rec_is_on; then
        echo "recording did not start (SD card mounted?)" >&2
        set_rtsp off
        set_rec off
        exit 1
    fi

    SECS="$SECS" OUT="$RUN/$leg" "$HERE/goggle-latency-capture.sh" || exit 1
done

echo
echo "=== restoring recording off, restream off"
set_rec off
set_rtsp off

echo
"$HERE/pace-curve.py" "$RUN"/*/ml-pipeline.log
echo
"$HERE/latency-compare.py" "$RUN"/*/ 2>/dev/null || true
echo
echo "legs in $RUN"
