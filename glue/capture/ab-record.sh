#!/usr/bin/env bash
# ab-record.sh - record one leg of a vendor-versus-open image comparison on the goggle's DVR.
#
# The comparison this feeds: point the same camera at the same scene under the same light, once
# with a stock vendor air unit and once with ours, and record both through the SAME goggle. The
# goggle decodes the downlink and re-encodes it for the DVR, so both legs carry an identical
# receive and re-encode path and everything that differs between the two files came from the air
# side. That is the whole point of recording on our goggle rather than pulling frames off each air
# unit with different tooling.
#
# The air side is the ISP configuration, the AE loop AND the encoder bitrate. The vendor derives
# its bitrate from live RF throughput and re-applies it whenever the MCS changes; ours is fixed.
# A leg recorded at a higher air bitrate carries more detail into the goggle's re-encode, which
# reads as a sharpness or noise difference in the report. The downlink rate is therefore measured
# over each recording window and written to the leg's metadata, so the two legs can be checked for
# a bitrate difference before their pixels are compared.
#
# Nothing is written on the air unit and no air-unit tooling is staged, so the vendor leg runs
# against a bone-stock unit exactly as it ships. The goggle side stages one small helper (ml-rec,
# the same control message the HUD's record button sends) and, only when the HUD has OSD burn-in
# enabled, edits settings.json and restarts ml-hud. The original settings are restored on exit,
# including on a failed run.
#
# OSD burn-in must be off for both legs: a burnt-in overlay puts high-contrast synthetic pixels in
# every frame, which contaminates every sharpness, histogram and noise statistic the analysis
# computes. The recording format is pinned with `ml-rec res` so the menu setting cannot silently
# change geometry between the two legs.
#
# The stack identity of the air unit is OPERATOR-ASSERTED. This script cannot see which slot the
# air unit booted, so `vendor` and `open` are labels you supply and the metadata file records them
# as asserted, not measured. Mislabelling the two legs inverts every conclusion; check the air
# unit before the run, not after.
#
# Usage: glue/capture/ab-record.sh <vendor|open> [--secs N] [--res 1080|720] [--fps 60|30]
#                                                [--note "text"] [--out DIR]
# Env: GOGGLE_IP / GOGGLE_PASS override the goggle address (default: the goggle device profile).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

# The goggle is the recorder whatever the active device profile is set to, because the air unit is
# the thing under test and `make setup DEVICE=betafpv-vr04-air` is the normal state during camera
# work. An explicit GOGGLE_IP still wins.
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

LEG="${1:-}"
case "$LEG" in
vendor|open) shift ;;
*)
    echo "usage: $0 <vendor|open> [--secs N] [--res 1080|720] [--fps 60|30] [--note TEXT] [--out DIR]" >&2
    echo "  vendor = the air unit is on stock slot A; open = the air unit is on our slot B" >&2
    exit 2
    ;;
esac

SECS=30
RES=1080
FPS=60
NOTE=""
OUT="$REPO/out/au-ab"

while [ $# -gt 0 ]; do
    case "$1" in
    --secs) SECS="$2"; shift 2 ;;
    --res)  RES="$2";  shift 2 ;;
    --fps)  FPS="$2";  shift 2 ;;
    --note) NOTE="$2"; shift 2 ;;
    --out)  OUT="$2";  shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$SECS" in *[!0-9]*|"") echo "--secs must be a positive integer" >&2; exit 2 ;; esac
case "$RES" in 1080|720) ;; *) echo "--res must be 1080 or 720" >&2; exit 2 ;; esac
case "$FPS" in 60|30) ;; *) echo "--fps must be 60 or 30" >&2; exit 2 ;; esac
[ "$SECS" -gt 0 ] || { echo "--secs must be a positive integer" >&2; exit 2; }

SETTINGS=/usrdata/hud/settings.json
LOG=/var/log/ml-pipeline.log
DEST="$OUT/$LEG"
MLREC="$REPO/userspace/gstreamer/build/bin/ml-rec"

command -v sshpass >/dev/null || { echo "sshpass is not installed" >&2; exit 1; }
mkdir -p "$DEST"

echo "=== gate: goggle at $DEVICE_IP ==="
sshg true </dev/null || { echo "cannot reach root@$DEVICE_IP" >&2; exit 1; }
sshg 'pidof ml-pipeline >/dev/null' </dev/null || {
    echo "ml-pipeline is not running: there is no receive path to record" >&2
    exit 1
}
KREL="$(sshg 'uname -r' </dev/null)"
echo "  kernel $KREL, ml-pipeline up"

[ -f "$MLREC" ] || {
    echo "$MLREC missing: build it with userspace/gstreamer/src/build.sh" >&2
    exit 1
}
device_push "$MLREC" /tmp >/dev/null

# ---- OSD burn-in off, restored on exit --------------------------------------------------------
# The HUD reads dvr.record_osd once at startup, so changing it needs a HUD restart. Only ml-hud is
# restarted; the pipeline and the RF link are left alone, because restarting those fragments CMA
# and costs the session.
BURN_WAS=""
restore_settings() {
    if [ "$BURN_WAS" = "true" ]; then
        echo "=== restoring dvr.record_osd=true ==="
        sshg "sed -i 's/\"record_osd\":[[:space:]]*[a-z]*/\"record_osd\":\ttrue/' $SETTINGS" </dev/null || true
        sshg "rc-service ml-hud restart >/dev/null 2>&1" </dev/null || true
    fi
}
trap restore_settings EXIT

BURN_WAS="$(sshg "grep -o '\"record_osd\":[[:space:]]*[a-z]*' $SETTINGS 2>/dev/null | awk '{print \$2}'" </dev/null || true)"
if [ "$BURN_WAS" = "true" ]; then
    echo "=== OSD burn-in is on; turning it off for the recording ==="
    sshg "sed -i 's/\"record_osd\":[[:space:]]*[a-z]*/\"record_osd\":\tfalse/' $SETTINGS" </dev/null
    sshg "rc-service ml-hud restart >/dev/null 2>&1" </dev/null
    sleep 4
else
    echo "  OSD burn-in already off (record_osd=${BURN_WAS:-absent})"
fi

# ---- downlink rate -------------------------------------------------------------------------------
# The air unit's encoder bitrate is part of what separates the two legs, so it has to be measured
# rather than assumed equal. The vendor derives its target from live RF throughput
# (AR_8030_TX_GetBitRate: throughput * Ar803xThroutputRate, capped at ArMaxBitRate, 8000 kbps when
# throughput reads zero) and re-applies it on every MCS change; ours is the fixed ML_AIR_BITRATE.
# Two legs recorded at different air bitrates differ in detail for that reason alone, which reads
# as a sharpness or noise difference in the report.
#
# Measured at the receiving interface's byte counter over the recording window, with the device's
# own uptime as the clock so the interval is measured rather than taken from --secs.
DOWNLINK_IF="${DOWNLINK_IF:-sdio0}"

downlink_sample() {
    sshg "cut -d' ' -f1 /proc/uptime; sed -n 's/.*${DOWNLINK_IF}://p' /proc/net/dev | awk '{print \$1}'" \
        </dev/null 2>/dev/null | tr '\n' ' '
}

# ---- record ------------------------------------------------------------------------------------
FROM="$(sshg "wc -l < $LOG" </dev/null)"

echo "=== recording ${SECS}s at ${RES}p${FPS}, leg '$LEG' ==="
sshg "/tmp/ml-rec res $RES $FPS && /tmp/ml-rec toggle" </dev/null

REC_LINE=""
for _ in $(seq 10); do
    REC_LINE="$(sshg "tail -n +$((FROM + 1)) $LOG | grep 'DVR recording' | head -1" </dev/null || true)"
    [ -n "$REC_LINE" ] && break
    sleep 1
done
[ -n "$REC_LINE" ] || { echo "recording did not start; see $LOG on the device" >&2; exit 1; }
echo "  $REC_LINE"

RX_START="$(downlink_sample)"

# Liveness by file growth rather than by the pipeline's frame counters: the rx= stats line is
# throttled to a ~30 s cadence, and the per-frame latraw path needs a pipeline restart to enable.
# A file that is not growing means no frames are arriving, and a recording of a frozen last frame
# looks like a valid capture until someone diffs it against the other leg.
REC_FILE="$(printf '%s\n' "$REC_LINE" | sed -n 's/.*-> \([^ ]*\).*/\1/p')"
if [ -n "$REC_FILE" ]; then
    S1="$(sshg "ls -l '$REC_FILE' 2>/dev/null | awk '{print \$5}'" </dev/null || echo 0)"
    sleep 4
    S2="$(sshg "ls -l '$REC_FILE' 2>/dev/null | awk '{print \$5}'" </dev/null || echo 0)"
    if [ "$(( ${S2:-0} - ${S1:-0} ))" -lt 100000 ]; then
        echo "  the recording grew by $(( ${S2:-0} - ${S1:-0} )) bytes in 4 s: video is not arriving" >&2
        sshg "/tmp/ml-rec toggle" </dev/null || true
        exit 1
    fi
    echo "  growing: +$(( ${S2:-0} - ${S1:-0} )) bytes in 4 s"
    sleep "$((SECS > 4 ? SECS - 4 : 1))"
else
    sleep "$SECS"
fi

RX_END="$(downlink_sample)"
FROM="$(sshg "wc -l < $LOG" </dev/null)"
sshg "/tmp/ml-rec toggle" </dev/null

DOWNLINK="$(awk -v a="$RX_START" -v b="$RX_END" '
BEGIN {
    split(a, s, " "); split(b, e, " ");
    secs = e[1] - s[1]; bytes = e[2] - s[2];
    if (s[2] == "" || e[2] == "" || secs <= 0) {
        print "unavailable";
    } else if (bytes <= 0) {
        printf "0.00 Mbps over %.1f s (the counter did not advance)", secs;
    } else {
        printf "%.2f Mbps over %.1f s (%d bytes)", bytes * 8 / secs / 1000000, secs, bytes;
    }
}')"
echo "  downlink on $DOWNLINK_IF: $DOWNLINK"

STOP_LINE=""
for _ in $(seq 15); do
    STOP_LINE="$(sshg "tail -n +$((FROM + 1)) $LOG | grep 'DVR stopped' | head -1" </dev/null || true)"
    [ -n "$STOP_LINE" ] && break
    sleep 1
done
[ -n "$STOP_LINE" ] || { echo "no 'DVR stopped' line; the file may still be open" >&2; exit 1; }
echo "  $STOP_LINE"

FILE="$(echo "$STOP_LINE" | sed -n 's/.*-> \([^ ]*\).*/\1/p')"
[ -n "$FILE" ] || { echo "could not parse the recording path out of the stop line" >&2; exit 1; }
SIZE="$(sshg "ls -l '$FILE' 2>/dev/null | awk '{print \$5}'" </dev/null || echo 0)"
echo "  $FILE, $SIZE bytes on the device"

# ---- pull ---------------------------------------------------------------------------------------
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOCAL="$DEST/$LEG-$STAMP.$(basename "$FILE" | sed 's/.*\.//')"

echo "=== pulling ==="
device_pull "$FILE" "$LOCAL" || exit 1
echo "  $LOCAL"

# The SRT sidecar, when the HUD writes one, carries the telemetry that was on screen. Not used by
# the image analysis, but it dates and identifies the run, so it comes along when it exists.
SRT="${FILE%.*}.srt"
if sshg "test -f '$SRT'" </dev/null 2>/dev/null; then
    device_pull "$SRT" "${LOCAL%.*}.srt" >/dev/null 2>&1 && echo "  ${LOCAL%.*}.srt"
fi

# ---- provenance ----------------------------------------------------------------------------------
META="${LOCAL%.*}.meta.txt"
{
    echo "leg: $LEG (OPERATOR-ASSERTED, not measured by this script)"
    echo "recorded: $STAMP"
    echo "note: $NOTE"
    echo "goggle: $DEVICE_IP kernel $KREL"
    echo "format: ${RES}p${FPS}, dvr.record_osd was ${BURN_WAS:-absent}"
    echo "device file: $FILE ($SIZE bytes)"
    echo "local file: $LOCAL"
    echo
    echo "downlink during the recording: $DOWNLINK (interface $DOWNLINK_IF)"
    echo
    echo "--- link at the end of the run ---"
    sshg "grep -E 'rx=|rssi|snr' $LOG | tail -5" </dev/null 2>/dev/null || true
    echo
    echo "--- pipeline tail ---"
    sshg "tail -20 $LOG" </dev/null 2>/dev/null || true
} > "$META"
echo "  $META"

if command -v ffprobe >/dev/null 2>&1; then
    echo "=== ffprobe ==="
    ffprobe -hide_banner -loglevel error -show_entries \
        format=duration,bit_rate:stream=codec_name,width,height,avg_frame_rate,nb_frames \
        -of default=noprint_wrappers=1 "$LOCAL" || true
fi

echo
echo "leg '$LEG' captured. When both legs exist, compare them with:"
echo "  glue/capture/ab-image-diff.py $OUT/vendor/<file> $OUT/open/<file> -o $OUT/report"
