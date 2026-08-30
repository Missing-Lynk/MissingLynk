#!/usr/bin/env bash
# rtsp-watch.sh - watch the goggle's RTSP restream in a window on the host and record it at once.
#
# The sibling scripts cover the other two cases: rtsp-stream.sh turns the restream on and off, and
# rtsp-record.sh records it headless and time-bounded for a measurement leg. This one is for
# looking at the stream while it is captured, which is what aiming the air unit at the panel needs.
#
# The stream is tee'd after the depayloader: one branch decodes for the window, the other muxes the
# ORIGINAL bitstream to file, so the recording is the goggle's own encode and the window costs the
# file nothing. Recording here starts nothing on the goggle, unlike a DVR recording, which restarts
# the encoder.
#
# Usage: glue/capture/rtsp-watch.sh [--out FILE] [--secs N] [--codec h264|h265]
#   --secs bounds the run; without it, watch until Ctrl-C.
#   --out names the file; it is always written as MPEG-TS, so any other extension is corrected.
#   --codec must match the goggle's dvr.codec, which is h264 by default (mlp-record.c; the
#     dvr-h265 flag file is the opt-in). A mismatch fails as "failed delayed linking some pad of
#     GstRTSPSrc to some pad of GstRtpH26xDepay", because the depayloader is chosen here while the
#     codec is named by the SDP.
# Env: GOGGLE_IP / GOGGLE_PASS override the goggle address; NOWINDOW=1 records without a window.
#
# Ctrl-C (or --secs elapsing) becomes an EOS through gst-launch's -e, which is what writes the MP4
# index. Killing it any other way leaves a file with no index. `glue/capture/latency-read.py FILE`
# then reads the burned-in latency counter back out of the recording.
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

OUT=""
SECS=""
# Matches the goggle's own default (mlp-record.c records H.264 unless the dvr-h265 flag file is
# present), so the common case needs no argument.
CODEC="h264"

while [ $# -gt 0 ]; do
    case "$1" in
        --out)  OUT="$2"; shift 2 ;;
        --secs) SECS="$2"; shift 2 ;;
        --codec) CODEC="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^set -/p' "$0" | sed 's/^# \?//; s/^set -.*//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$CODEC" in
    h264|h265) ;;
    *) echo "--codec takes h264 or h265, not '$CODEC'" >&2; exit 2 ;;
esac

command -v gst-launch-1.0 >/dev/null || { echo "gst-launch-1.0 is not installed" >&2; exit 1; }

# Default alongside rtsp-record.sh's output rather than in the caller's directory: these files are
# tens of MB and the caller is usually the repo root.
[ -n "$OUT" ] || OUT="$REPO/out/rtsp/goggle-$(date -u +%Y%m%dT%H%M%SZ).ts"
URL="rtsp://$DEVICE_IP:554/venc8/stream"

# MPEG-TS always: aborting is the normal way this run ends, and TS carries its timing per packet,
# so a file cut mid-frame plays and decodes up to the cut. A name given with any other extension is
# corrected rather than honoured, because the file would be TS regardless and a wrong extension is
# how a capture ends up looking broken.
if [ "${OUT##*.}" != "ts" ]; then
    OUT="${OUT%.*}.ts"
fi

mkdir -p "$(dirname "$OUT")"

SINK=(autovideosink sync=false)
if [ -n "${NOWINDOW:-}" ]; then
    SINK=(fakesink)
fi

# protocols=tcp: the USB gadget link drops UDP under load and a lost packet costs a whole frame.
# config-interval=-1 repeats the parameter sets ahead of every keyframe, so the file opens on any
# decoder even though the capture starts mid-stream.
PIPELINE=(
    gst-launch-1.0 -e
    rtspsrc "location=$URL" latency=0 protocols=tcp
    ! "rtp${CODEC}depay"
    ! "${CODEC}parse" config-interval=-1
    ! tee name=t
    t. ! queue ! "avdec_${CODEC}" ! videoconvert ! "${SINK[@]}"
    t. ! queue ! "${CODEC}parse" ! mpegtsmux ! filesink "location=$OUT"
)

echo "goggle: $DEVICE_IP"
echo "url:    $URL"
echo "out:    $OUT"

# timeout -s INT delivers the interrupt gst-launch -e turns into an EOS, the same idiom
# rtsp-record.sh uses; without it a bounded run would leave the file unindexed.
if [ -n "$SECS" ]; then
    echo "stopping after ${SECS}s"
    timeout -s INT "$SECS" "${PIPELINE[@]}" || true
else
    echo "Ctrl-C to stop"
    "${PIPELINE[@]}" || true
fi

# The one remaining way to end up with nothing is the stream never serving, which looks identical
# to a successful run in a file browser. Name it here rather than leave an empty file behind.
SIZE=$(stat -c%s "$OUT" 2>/dev/null || echo 0)
if [ "$SIZE" -lt 1024 ]; then
    echo "[!] $OUT is ${SIZE} B: no video arrived." >&2
    echo "    The restream was not serving. Check glue/capture/rtsp-stream.sh status; a 503 with" >&2
    echo "    the stream nominally on means the goggle's encoder is wedged and needs a power cycle." >&2
    exit 1
fi

echo "[+] $OUT ($(( SIZE / 1024 )) KiB)"
echo "    It is H.265: players without HEVC support will refuse it even though it is valid."
echo "    mpv, VLC and glue/capture/latency-read.py all read it as-is."
