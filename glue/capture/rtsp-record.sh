#!/usr/bin/env bash
# rtsp-record.sh - record the goggle's RTSP restream onto the host, headless and time-bounded.
#
# Why this and not glue/capture/ab-record.sh: the DVR path starts and stops the goggle's encoder
# per leg, writes to the SD card, and has to be pulled back over the gadget link afterwards. The
# restream's tee branch is permanent, so recording here starts nothing on the goggle and changes
# nothing between legs of a comparison. The bytes are the goggle's original encode, muxed with no
# re-encode, so the file is what the encoder produced.
#
# What it is not: the restream carries the COMPOSITE, which is the decoded downlink after the
# goggle re-encodes it. That is the same path for every leg, so a comparison is valid, but it is
# not the air unit's own bitstream. Use ab-record.sh when the question is about the DVR itself.
#
# The stream has to be up already: run `glue/capture/rtsp-stream.sh on` once around a multi-leg
# session rather than paying an ml-hud restart per leg.
#
# Usage: glue/capture/rtsp-record.sh [--secs N] [--out FILE] [--note TEXT]
# Env: GOGGLE_IP / GOGGLE_PASS override the goggle address; NOWINDOW is implied (always headless).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

# shellcheck disable=SC2034  # DEVICE and ROOT_PASS are read by device.sh / ssh-opts.sh below.
DEVICE="${GOGGLE_DEVICE:-betafpv-vr04-goggle}"
if [ -n "${GOGGLE_IP:-}" ]; then
    DEVICE_IP="$GOGGLE_IP"
fi
if [ -n "${GOGGLE_PASS:-}" ]; then
    # shellcheck disable=SC2034  # read by ssh-opts.sh when it freezes PASS.
    ROOT_PASS="$GOGGLE_PASS"
fi
# shellcheck source=/dev/null
. "$REPO/glue/lib/ssh-opts.sh"

SECS=30
OUT=""
NOTE=""

while [ $# -gt 0 ]; do
    case "$1" in
    --secs) SECS="$2"; shift 2 ;;
    --out)  OUT="$2";  shift 2 ;;
    --note) NOTE="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$SECS" in *[!0-9]*|"") echo "--secs must be a positive integer" >&2; exit 2 ;; esac
[ "$SECS" -gt 0 ] || { echo "--secs must be a positive integer" >&2; exit 2; }
[ -n "$OUT" ] || OUT="$REPO/out/rtsp/goggle-$(date -u +%Y%m%dT%H%M%SZ).mp4"

command -v gst-launch-1.0 >/dev/null || { echo "gst-launch-1.0 is not installed" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"

# H.265 only, and checked rather than assumed. ML_DVR_CODEC can select H.264, but nothing ships
# that way, so this refuses the case instead of carrying a second pipeline for it: recording an
# H.264 stream through an h265 depayloader produces a valid MP4 with no frames in it, and that
# failure is indistinguishable from a dead link. The announcement doubles as the check that the
# server is actually up.
LOG=/var/log/ml-pipeline.log
CODEC="$(sshg "grep 'RTSP serving' $LOG 2>/dev/null | tail -1" </dev/null \
         | sed -n 's/.*(\([a-z0-9]*\)).*/\1/p')"

# The serving line lives in a tmpfs log that ml-logd truncates when /var/log fills, so its absence
# does not mean the server is down: the :554 listener is the ground truth, and the codec rides the
# pipeline's ML_DVR_CODEC (unset = the h265 default).
if [ -z "$CODEC" ]; then
    # shellcheck disable=SC2016  # $pid and $c expand on the goggle, inside the remote shell
    CODEC="$(sshg 'netstat -tln 2>/dev/null | grep -q ":554 " || exit 0
                   pid=$(pgrep ml-pipeline | head -1)
                   c=$(tr "\0" "\n" < /proc/$pid/environ 2>/dev/null | sed -n "s/^ML_DVR_CODEC=//p")
                   echo ${c:-h265}' </dev/null | tr -d "\r\n ")"
fi

if [ -z "$CODEC" ]; then
    echo "the goggle is not serving the restream: run glue/capture/rtsp-stream.sh on first" >&2
    exit 1
fi

if [ "$CODEC" != h265 ]; then
    echo "the pipeline is serving $CODEC; this records H.265 only" >&2
    exit 1
fi

URL="rtsp://$DEVICE_IP:554/venc8/stream"
echo "=== recording ${SECS}s from $URL (h265) ==="

# protocols=tcp: the gadget link drops UDP under load and a lost packet costs a whole frame.
# config-interval=-1 repeats the parameter sets ahead of every keyframe, so the file opens on any
# decoder regardless of where the recording started relative to the stream's own IDR cadence.
#
# timeout -s INT delivers the interrupt gst-launch -e turns into an EOS, which is what writes the
# MP4 index. Killing it any other way leaves a file no decoder will open, so the -k grace period
# is a backstop for a hung EOS rather than the normal path.
set +e
timeout -s INT -k 10 "$SECS" \
    gst-launch-1.0 -e \
        rtspsrc location="$URL" latency=0 protocols=tcp \
        ! rtph265depay \
        ! h265parse config-interval=-1 \
        ! mp4mux \
        ! filesink location="$OUT" \
    > "${OUT%.*}.gst.log" 2>&1
RC=$?
set -e

# 124 is the interrupt landing on schedule, which is the normal end of a timed leg. Anything else
# means gst-launch stopped on its own, so the leg is short and the log says why.
if [ "$RC" -ne 124 ] && [ "$RC" -ne 0 ]; then
    echo "  gst-launch exited $RC before the leg was up; see ${OUT%.*}.gst.log" >&2
fi

if [ ! -s "$OUT" ]; then
    echo "no recording was produced; see ${OUT%.*}.gst.log" >&2
    exit 1
fi

# A file that exists is not a file with frames in it: a refused or stalled connection still leaves
# an MP4 header behind. Packets rather than decoded frames, so this stays fast on a long leg.
PKTS=0
if command -v ffprobe >/dev/null 2>&1; then
    PKTS="$(ffprobe -v error -select_streams v:0 -count_packets \
            -show_entries stream=nb_read_packets -of csv=p=0 "$OUT" 2>/dev/null | tr -d '\r,')"
    PKTS="${PKTS:-0}"
fi

SIZE="$(stat -c %s "$OUT")"
echo "  $OUT, $SIZE bytes, $PKTS packets (gst exit $RC)"

# 30 fps is half the nominal rate: enough headroom for a slow start and a dropped tail, low enough
# that a stalled leg still fails rather than being reported as a capture.
MIN=$((SECS * 30))
if [ "$PKTS" -gt 0 ] && [ "$PKTS" -lt "$MIN" ]; then
    echo "  only $PKTS packets for ${SECS}s: the stream stalled or started late" >&2
    exit 1
fi

META="${OUT%.*}.meta.txt"
{
    echo "source: $URL ($CODEC)"
    echo "recorded: $(date -u +%Y%m%dT%H%M%SZ), ${SECS}s"
    echo "note: $NOTE"
    echo "goggle: $DEVICE_IP"
    echo "file: $OUT ($SIZE bytes, $PKTS packets)"
    echo "record_osd at capture: $(sshg "grep -o '\"record_osd\":[[:space:]]*[a-z]*' /usrdata/hud/settings.json 2>/dev/null | awk '{print \$2}'" </dev/null || true)"
} > "$META"
echo "  $META"
