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
# runs the encoder but sends nothing, which is not the configuration anyone flies. The server only
# exists while the restream is enabled, so a client cannot be started ahead of the leg; this runs
# its own for the duration of each restream leg and stops it afterwards.
#
# The client pulls with -c copy, so the host never decodes. That keeps a host without H.265 support
# usable and keeps host decode off the critical path, where it could throttle the pull and make the
# goggle look better than it is. What is being measured is the goggle's egress, not the playback.
#
# PREREQ:
#   - goggle reachable at DEVICE_IP as root/ROOT_PASS, air unit powered and passing video
#   - glue/capture/latency-baseline.sh has armed the measurement knobs
#   - an SD card mounted at /mnt/sdcard for the recording legs
#   - ffmpeg on the host, for the restream legs' client
#
# The DVR codec is whatever ml-video launched with: the /usrdata/missinglynk/dvr-h264 flag file
# selects H.264, its absence H.265 (ml-video-up, mlp-record.c ML_DVR_CODEC). It is read at
# ml-pipeline startup, so changing it needs an ml-video restart and therefore a new pipeline
# generation. Compare codecs by the rec-minus-base delta within each generation, never by
# rx2flip across them: the settled panel phase is per generation and offsets every absolute
# number. The run records which codec was live in codec.txt.
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
CLIENT_TRIES="${CLIENT_TRIES:-6}"
HUD_SETTINGS="${HUD_SETTINGS:-/usrdata/hud/settings.json}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# shellcheck source=../lib/ssh-opts.sh
. "$HERE/../lib/ssh-opts.sh"

MLREC="${MLREC:-/usrdata/missinglynk/ml-rec}"

# Recording is a toggle, the restream an idempotent set, so recording has to be read before it can
# be driven. MLM_STATE_F_RTSP reports the restream, but the pipeline's own log is the only reading
# available from a shell, so use the file handle instead: a recording pipeline holds one open.
rec_is_on() {
    # shellcheck disable=SC2016  # $p expands on the device, not here
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

# The HUD owns the restream. hud.c rtsp_tick reconciles the pipeline's MLM_STATE_F_RTSP against
# the dvr.rtsp_stream setting on every tick, so a direct MLM_CMD_RTSP is reverted within a second,
# tearing the encoder down under any client that was still attaching. Drive the setting instead.
# settings.c loads the file once at startup and never re-reads it, so the HUD is restarted to pick
# the change up. Legs are ordered so the two restream legs are adjacent and this costs one restart.
rtsp_setting() {
    sshg "cat '$HUD_SETTINGS' 2>/dev/null" </dev/null | "$HERE/hud-setting.py" read
}

set_rtsp() {  # <on|off>
    local want="$1" cur i

    cur="$(rtsp_setting)"
    if [ "$cur" = "$want" ]; then
        return 0
    fi

    device_pull "$HUD_SETTINGS" "$WORK/settings.json" 2>/dev/null || echo '{}' >"$WORK/settings.json"
    "$HERE/hud-setting.py" write "$want" <"$WORK/settings.json" >"$WORK/settings.new" || return 1
    mv "$WORK/settings.new" "$WORK/settings.json"
    device_push_as "$WORK/settings.json" "$HUD_SETTINGS" || return 1

    echo "    dvr.rtsp_stream = $want, restarting ml-hud"
    sshg 'rc-service ml-hud restart >/dev/null 2>&1' </dev/null

    for i in $(seq 15); do
        sleep 1
        if sshg 'pgrep ml-hud >/dev/null' </dev/null; then
            return 0
        fi
    done

    echo "ml-hud did not come back after the settings change" >&2
    return 1
}

client_attached() {
    sshg 'ss -tn 2>/dev/null | grep -q ":554 " || netstat -tn 2>/dev/null | grep -q ":554 .*ESTAB"' </dev/null
}

CLIENT_PID=""

# start_client - pull the restream for the duration of a leg. Interleaved over TCP so the pull
# shares the one connection the :554 check looks for, and -c copy so no decoder is involved.
start_client() {
    [ -n "$CLIENT_PID" ] && return 0

    local i
    for i in $(seq "$CLIENT_TRIES"); do
        ffmpeg -nostdin -loglevel warning -rtsp_transport tcp \
               -i "rtsp://$DEVICE_IP:554/venc8/stream" -c copy -f null - \
               >"$RUN/rtsp-client.log" 2>&1 &
        CLIENT_PID=$!

        sleep 4
        if kill -0 "$CLIENT_PID" 2>/dev/null && client_attached; then
            echo "    rtsp client pulling (attempt $i, pid $CLIENT_PID)"
            return 0
        fi

        stop_client
    done

    echo "rtsp client never held the stream over $CLIENT_TRIES attempts:" >&2
    sed 's/^/    /' "$RUN/rtsp-client.log" >&2
    return 1
}

stop_client() {
    [ -n "$CLIENT_PID" ] || return 0

    kill "$CLIENT_PID" 2>/dev/null
    wait "$CLIENT_PID" 2>/dev/null
    CLIENT_PID=""
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
WORK="$(mktemp -d)"
cleanup() { stop_client; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

sshg 'if [ -f /usrdata/missinglynk/dvr-h264 ]; then echo h264; else echo h265; fi
      if [ -s /usrdata/missinglynk/dvr-bitrate ]; then cat /usrdata/missinglynk/dvr-bitrate; else echo 0; fi' \
    </dev/null | tr '\n' ' ' >"$RUN/codec.txt" || echo "unknown 0" >"$RUN/codec.txt"
echo "dvr codec: $(cat "$RUN/codec.txt")(bitrate 0 = fixed QP)"
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

    if [ "$want_rtsp" = on ]; then
        start_client || { set_rtsp off; set_rec off; exit 1; }
    else
        stop_client
    fi

    set_rec "$want_rec"
    sleep "$SETTLE"

    if [ "$want_rtsp" = on ] && ! client_attached; then
        echo "the rtsp client dropped during settle; the leg would measure an idle restream" >&2
        echo "see $RUN/rtsp-client.log" >&2
        stop_client
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

    # Sampled alongside the capture, not after it: a loaded leg that costs latch wait rather than
    # decode time is a scheduling question, and which thread held the core has to be read from the
    # same seconds the latency marks came from.
    "$HERE/thread-cpu.sh" "$SECS" "$RUN/$leg-threads.csv" &
    threads_pid=$!

    SECS="$SECS" OUT="$RUN/$leg" "$HERE/goggle-latency-capture.sh" || exit 1
    wait "$threads_pid" 2>/dev/null
done

echo
echo "=== restoring recording off, restream off"
stop_client
set_rec off
set_rtsp off

echo
"$HERE/pace-curve.py" "$RUN"/*/ml-pipeline.log
echo
"$HERE/latency-compare.py" "$RUN"/*/ 2>/dev/null || true
echo
echo "legs in $RUN"
