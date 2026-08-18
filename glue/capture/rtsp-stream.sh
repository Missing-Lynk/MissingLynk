#!/usr/bin/env bash
# rtsp-stream.sh - turn the goggle's RTSP restream on or off, and report what it is doing.
#
# ml-pipeline serves the DVR encoder's elementary stream at rtsp://<goggle>:554/venc8/stream while
# dvr.rtsp_stream is on. The setting is the intent and MLM_STATE_F_RTSP is the actual state: the
# HUD reconciles the two at 1 Hz, so an MLM_CMD_RTSP sent by hand is undone within a second unless
# the setting agrees with it. That is why this edits the setting rather than sending the command.
#
# dvr.record_osd is edited alongside it because the burn-in gate treats the restream as the
# recording's twin (hud.c burn_tick): with record_osd on, the HUD burns OSD glyphs into every
# composite the restream carries, which puts high-contrast synthetic pixels into any measurement
# made from the recording.
#
# Both are read once at HUD startup, so ml-hud is stopped across the edit and started after it.
# Stopping first also removes the race where the running HUD persists its own copy over the edit.
#
# This is stateless on purpose: `set` writes exactly what it is given and `status` reports exactly
# what is there, so a caller that wants the old values back reads them first and writes them back.
#
#   glue/capture/rtsp-stream.sh status
#   glue/capture/rtsp-stream.sh on                  # sugar for: set true false
#   glue/capture/rtsp-stream.sh set false true      # put a caller's saved values back
#
# Env: GOGGLE_IP / GOGGLE_PASS override the goggle address (default: the goggle device profile).
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

SETTINGS=/usrdata/hud/settings.json
LOG=/var/log/ml-pipeline.log

usage() {
    echo "usage: $0 status" >&2
    echo "       $0 on" >&2
    echo "       $0 set <rtsp_stream true|false> <record_osd true|false>" >&2
    exit 2
}

# read_setting <section> <key> - the stored value, or "absent". Parsed host-side so a missing
# section is not confused with a false value.
read_setting() {
    local section="$1" key="$2"

    sshg "cat $SETTINGS 2>/dev/null" </dev/null | python3 -c '
import json
import sys

section, key = sys.argv[1], sys.argv[2]
raw = sys.stdin.read()

try:
    doc = json.loads(raw) if raw.strip() else {}
except json.JSONDecodeError:
    print("unparseable")
    sys.exit(0)

value = doc.get(section, {}).get(key) if isinstance(doc.get(section), dict) else None
print("absent" if value is None else ("true" if value else "false"))
' "$section" "$key"
}

# serving - the codec the pipeline last announced, or empty when it is not serving. The log line
# is the pipeline's own report that the server came up, which a TCP connect to 554 is not: the
# port answers while the encoder is still being started, and it also answers after a teardown.
serving_codec() {
    sshg "grep 'RTSP serving' $LOG 2>/dev/null | tail -1" </dev/null \
        | sed -n 's/.*(\([a-z0-9]*\)).*/\1/p'
}

# write_settings <rtsp> <osd> - rewrite the file through a JSON parse, so an absent key is created
# rather than silently skipped by a sed that matched nothing.
write_settings() {
    local rtsp="$1" osd="$2" tmp
    tmp="$(mktemp)"

    if ! device_pull "$SETTINGS" "$tmp" 2>/dev/null; then
        echo '{}' > "$tmp"
        echo "  $SETTINGS is absent or empty; writing a fresh one"
    fi

    python3 -c '
import json
import sys

path, rtsp, osd = sys.argv[1], sys.argv[2] == "true", sys.argv[3] == "true"

with open(path) as handle:
    raw = handle.read()

doc = json.loads(raw) if raw.strip() else {}

if not isinstance(doc.get("dvr"), dict):
    doc["dvr"] = {}

doc["dvr"]["rtsp_stream"] = rtsp
doc["dvr"]["record_osd"] = osd

with open(path, "w") as handle:
    json.dump(doc, handle, indent="\t")
    handle.write("\n")
' "$tmp" "$rtsp" "$osd"

    device_push_as "$tmp" "$SETTINGS"
    rm -f "$tmp"
}

CMD="${1:-}"
[ -n "$CMD" ] || usage

sshg true </dev/null || { echo "cannot reach root@$DEVICE_IP" >&2; exit 1; }

case "$CMD" in
status)
    CODEC="$(serving_codec)"
    echo "rtsp_stream=$(read_setting dvr rtsp_stream)"
    echo "record_osd=$(read_setting dvr record_osd)"
    echo "serving=$([ -n "$CODEC" ] && echo yes || echo no)"
    echo "codec=${CODEC:-unknown}"
    ;;
on|set)
    if [ "$CMD" = on ]; then
        RTSP=true
        OSD=false
    else
        RTSP="${2:-}"
        OSD="${3:-}"
        case "$RTSP" in true|false) ;; *) usage ;; esac
        case "$OSD" in true|false) ;; *) usage ;; esac
    fi

    if [ "$(read_setting dvr rtsp_stream)" = "$RTSP" ] \
       && [ "$(read_setting dvr record_osd)" = "$OSD" ]; then
        echo "already rtsp_stream=$RTSP record_osd=$OSD; not restarting ml-hud"
    else
        echo "setting rtsp_stream=$RTSP record_osd=$OSD"
        sshg "rc-service ml-hud stop >/dev/null 2>&1" </dev/null || true
        write_settings "$RTSP" "$OSD"
        sshg "rc-service ml-hud start >/dev/null 2>&1" </dev/null || true
    fi

    if [ "$RTSP" = true ]; then
        # The HUD asserts the setting on its reconcile tick, then the pipeline starts the encoder.
        # Both are fast, but neither is instant, and a recorder that connects too early gets a
        # refused connection rather than a short file.
        for _ in $(seq 20); do
            CODEC="$(serving_codec)"
            [ -n "$CODEC" ] && break
            sleep 1
        done
        [ -n "${CODEC:-}" ] || {
            echo "the pipeline never announced 'RTSP serving'; see $LOG on the goggle" >&2
            exit 1
        }
        echo "serving rtsp://$DEVICE_IP:554/venc8/stream ($CODEC)"
    fi
    ;;
*)
    usage
    ;;
esac
