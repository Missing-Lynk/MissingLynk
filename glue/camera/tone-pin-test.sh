#!/usr/bin/env bash
# tone-pin-test.sh - does a rebuilt tone page reach the pixels? Three legs, pinned, no AE.
#
# The open question on the tone selector is not whether the driver builds the right page: that is
# byte-exact against the shipped builders at 15 of 15 scalars. It is whether the ISP consumes the
# buffer at all, which no register readback can answer because gamma and DRC are DMA tables.
#
# Earlier attempts drove the selection from the AE, which forced a scene several stops brighter
# than the bench so the AE-chosen scalar would leave the band the tone-off legs pin. That
# requirement was an artifact, not a constraint: `gamma_curve` and `drc_profile` pin one entry
# each with no blend, and pinning 2/3 builds byte-for-byte the page that scalar 240 builds. So the
# comparison runs at any brightness, and the AE is not involved.
#
# It is stopped outright for the run. With exposure frozen the only thing changing between legs is
# the tone page, which removes the dominant term from the drift floor that buried the last reading.
#
#   leg A  gamma_curve 3, drc_profile 4   the shipped default
#   leg B  gamma_curve 2, drc_profile 3   the page scalar 240 builds
#   leg C  gamma_curve 3, drc_profile 4   null control, identical to A
#
# The arm is `echo 2`, not 1. The driver skips a rebuild when the selection has not moved and
# tracks that by the scalar, which a pin sweep never touches (ar-isp-main.c ar_isp_tone_set:
# `val > 1` forces). Arming with 1 here would leave every leg serving leg A's page and produce a
# null that means nothing, which is the same shape as the two void results this test replaces.
#
# Each leg records the md5 of the pages the hardware is actually fetching, so the run proves its
# own independent variable moved before any pixel is analysed: A and C must match, B must differ.
# That check is on-device and costs nothing, and it fails loudly rather than silently passing.
#
# Usage: glue/camera/tone-pin-test.sh [--secs N] [--out DIR] [--dry-run]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

SECS=15
OUT=""
DRY=0

while [ $# -gt 0 ]; do
    case "$1" in
    --secs)    SECS="$2"; shift 2 ;;
    --out)     OUT="$2";  shift 2 ;;
    --dry-run) DRY=1;     shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$SECS" in *[!0-9]*|"") echo "--secs must be a positive integer" >&2; exit 2 ;; esac
[ "$SECS" -gt 0 ] || { echo "--secs must be a positive integer" >&2; exit 2; }
[ -n "$OUT" ] || OUT="$REPO/out/tone-pin/$(date -u +%Y%m%dT%H%M%SZ)"

AU_IP="${AU_IP:-192.168.3.102}"
AU_PASS="${AU_PASS:-libre}"

GAMMA_P=/sys/module/ar_isp/parameters/gamma_curve
DRC_P=/sys/module/ar_isp/parameters/drc_profile
SCALAR_P=/sys/module/ar_isp/parameters/tone_scalar
ARM=/sys/kernel/debug/ar-isp/tone
DBG=/sys/kernel/debug/ar-isp

# au <cmd...> - run a command on the air unit as root. In --dry-run it prints instead, so the whole
# sequence including the restore path can be walked without a device on the bench.
au() {
    if [ "$DRY" = 1 ]; then
        echo "    [dry] au: $*" >&2
        return 0
    fi
    sshpass -p "$AU_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=8 root@"$AU_IP" "$@" </dev/null
}

SAVED_GAMMA=""
SAVED_DRC=""
RESTORED=0
STOPPED_AE=0

# Put the unit back the way it was found, on every exit path including a failed leg or a ^C. The
# pins and the AE service are both process-lifetime state, so an aborted run that skipped this
# leaves the next session metering against a pinned tone page and wondering why.
restore() {
    [ "$RESTORED" = 1 ] && return 0
    RESTORED=1

    echo
    echo "restoring the unit"

    if [ -n "$SAVED_GAMMA" ] && [ -n "$SAVED_DRC" ]; then
        au "echo $SAVED_GAMMA > $GAMMA_P; echo $SAVED_DRC > $DRC_P; echo 2 > $ARM" \
            || echo "  WARNING: could not restore the pins (unit gone?)" >&2
        echo "  pins back to gamma_curve $SAVED_GAMMA, drc_profile $SAVED_DRC"
    fi

    # Only if this run stopped it. A preflight failure exits before the freeze, and claiming a
    # restart that never happened is how a report ends up describing a unit it did not leave behind.
    if [ "$STOPPED_AE" = 1 ]; then
        au "rc-service ml-air-ae start >/dev/null 2>&1" \
            || echo "  WARNING: could not restart ml-air-ae (unit gone?)" >&2
        echo "  ml-air-ae restarted"
    fi
}
trap restore EXIT INT TERM

echo "=== preflight ==="

if [ "$DRY" = 0 ]; then
    ping -c 1 -W 2 "$AU_IP" >/dev/null 2>&1 || { echo "air unit $AU_IP is not up" >&2; exit 1; }
    echo "air unit $AU_IP: up"

    au "test -e $ARM" || { echo "$ARM is missing: ar_isp did not probe" >&2; exit 1; }
    echo "ar-isp debugfs: present"

    # The page dumps are this run's only control. Without them nothing on the unit can confirm the
    # rebuild fired, and a pin sweep that silently served one page is exactly how the two previous
    # results came back void. They landed in 75c97ac (2026-08-19), later than the flashed image, so
    # a unit flashed before that needs a rebuilt ar_isp.ko before this test means anything. Checked
    # here so that costs five seconds rather than a battery and three legs.
    au "test -e $DBG/gamma_page -a -e $DBG/drc_page" || {
        echo "$DBG/gamma_page and drc_page are missing." >&2
        echo "This kernel's ar_isp predates 75c97ac, so the run has no way to prove the page" >&2
        echo "rebuilt and a null from it would mean nothing. Rebuild ar_isp.ko first." >&2
        exit 1
    }
    echo "ar-isp page dumps: present"

    # The recorder needs the goggle serving already. Checked here rather than at the first leg, so
    # a dead restream costs no exposure freeze and no leg.
    timeout 30 "$REPO/glue/capture/rtsp-stream.sh" status >/dev/null 2>&1 \
        || { echo "goggle restream is not reachable: run glue/capture/rtsp-stream.sh on" >&2; exit 1; }
    echo "goggle restream: serving"
else
    echo "  [dry] skipping reachability, debugfs and restream checks"
fi

mkdir -p "$OUT"

echo
echo "=== freezing the air unit ==="

if [ "$DRY" = 0 ]; then
    SAVED_GAMMA="$(au "cat $GAMMA_P")"
    SAVED_DRC="$(au "cat $DRC_P")"
    SAVED_SCALAR="$(au "cat $SCALAR_P")"
else
    SAVED_GAMMA=3; SAVED_DRC=4; SAVED_SCALAR=-1
fi

echo "saved: gamma_curve $SAVED_GAMMA, drc_profile $SAVED_DRC, tone_scalar $SAVED_SCALAR"

if [ "$SAVED_SCALAR" != "-1" ]; then
    echo "tone_scalar is $SAVED_SCALAR, not -1: the pins are IGNORED while it is set." >&2
    echo "Something is driving the scalar (ml-aed drives tone by default now). Stop ml-air-ae first, or run it --no-tone." >&2
    exit 1
fi

au "rc-service ml-air-ae stop >/dev/null 2>&1 || true"
STOPPED_AE=1
sleep 1
FROZEN="$(au "tail -1 /var/log/ml-air-ae.log 2>/dev/null | sed -n 's/.*index \([0-9]*\).*/\1/p'" || true)"
echo "ml-air-ae stopped, exposure frozen at index ${FROZEN:-unknown}"
echo "${FROZEN:-unknown}" > "$OUT/frozen-index.txt"

# leg <name> <gamma_curve> <drc_profile>
leg() {
    local name="$1" g="$2" d="$3"

    echo
    echo "=== leg $name: gamma_curve $g, drc_profile $d ==="

    au "echo $g > $GAMMA_P; echo $d > $DRC_P; echo 2 > $ARM"

    local back_g back_d
    if [ "$DRY" = 0 ]; then
        back_g="$(au "cat $GAMMA_P")"
        back_d="$(au "cat $DRC_P")"
        [ "$back_g" = "$g" ] && [ "$back_d" = "$d" ] \
            || { echo "pin readback is $back_g/$back_d, wanted $g/$d" >&2; exit 1; }
    fi
    echo "  pins confirmed"

    # The pages the hardware is fetching, hashed on the unit. This is the run's own control: if
    # B's hash equals A's the independent variable never moved and no pixel analysis is worth
    # running, whatever the recordings look like.
    local hashes
    if [ "$DRY" = 0 ]; then
        hashes="$(au "md5sum $DBG/gamma_page $DBG/drc_page 2>/dev/null | awk '{print \$1}' | tr '\n' ' '")"
    else
        hashes="dry-gamma-$g dry-drc-$d"
    fi
    echo "$hashes" > "$OUT/leg-$name.pages"
    echo "  page md5: $hashes"

    sleep 2

    if [ "$DRY" = 0 ]; then
        "$REPO/glue/capture/rtsp-record.sh" --secs "$SECS" --out "$OUT/leg-$name.mp4" \
            --note "tone pin gamma_curve=$g drc_profile=$d"
    else
        echo "    [dry] rtsp-record.sh --secs $SECS --out $OUT/leg-$name.mp4"
        : > "$OUT/leg-$name.mp4"
    fi
    echo "  recorded $OUT/leg-$name.mp4"
}

leg A 3 4
leg B 2 3
leg C 3 4

restore

echo
echo "=== did the independent variable move? ==="

PA="$(cat "$OUT/leg-A.pages")"
PB="$(cat "$OUT/leg-B.pages")"
PC="$(cat "$OUT/leg-C.pages")"

echo "  A: $PA"
echo "  B: $PB"
echo "  C: $PC"
echo

VOID=0
[ "$PA" = "$PC" ] || { echo "  FAIL: A and C differ, so the null control is not a null." >&2; VOID=1; }
[ "$PA" != "$PB" ] || { echo "  FAIL: A and B are the same page. The rebuild did not happen." >&2; VOID=1; }

if [ "$VOID" = 1 ]; then
    echo
    echo "The recordings are not worth analysing. Do not publish a null from this run." >&2
    exit 1
fi

echo "  OK: A == C, and B differs from both. The pages moved as intended."
echo
echo "Now analyse, with C as the null control:"
echo "  glue/capture/ab-image-diff.py $OUT/leg-A.mp4 $OUT/leg-B.mp4 \\"
echo "      --null $OUT/leg-C.mp4 -o $OUT/report"
