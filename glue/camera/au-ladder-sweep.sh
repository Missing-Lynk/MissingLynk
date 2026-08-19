#!/usr/bin/env bash
# au-ladder-sweep.sh - the gain-keyed ladder gate sweep, checked in so no stage gets skipped again.
#
# The 2026-08-18 gate boot was driven by hand: the abscissa was written to the *_gain module
# parameters and latched through the `ladders` node, and the run validated cfa, de3d, rnr and cnf
# at eight abscissas. lnr was silently absent, because a hand-driven sweep wrote four parameters
# and left lnr_gain at -1, which makes ladder_banks print "parameter -1, bank left replayed" and
# produce no comparisons for the stage. Nothing failed, so nobody noticed until the parity ledger
# counted columns (plans/isp-vendor-parity.md, current front item 3).
#
# This harness writes ALL FIVE gains (rnr, lnr, de3d, cfa, cnf) at every abscissa and then treats
# a skipped stage as a hard failure: any "parameter -1" line in ladder_banks aborts the run. The
# optional trigger sweep drives cm_trigger/cm2_trigger the same way on their own 0-550 axis, which
# is what would have caught CM2_RECIP1 sitting at a never-moved trigger during the first gate boot.
#
# The AE daemon owns these parameters, so it is stopped for the sweep and restarted on exit, and
# the parameters it drives are saved up front and restored exactly, so a run leaves the unit as it
# found it instead of relying on the next battery pull.
#
# Default abscissas are the eight from the 2026-08-18 gate boot: three band gaps where the
# soft-float blend executes (3938, 3395, 11422), two in-band verbatim points (5788, 16276), the
# cold band (256) and both clamps (1, 65535). Q8 linear gain throughout.
#
# Usage: glue/camera/au-ladder-sweep.sh [--q8 "N N ..."] [--trigger "N N ..."] [--out DIR] [--dry-run]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

Q8_LIST="3938 3395 11422 5788 16276 256 1 65535"
TRIGGER_LIST="240 305"
SWEEP_TRIGGERS=1
OUT=""
DRY=0

while [ $# -gt 0 ]; do
    case "$1" in
    --q8)         Q8_LIST="$2";      shift 2 ;;
    --trigger)    TRIGGER_LIST="$2"; shift 2 ;;
    --no-trigger) SWEEP_TRIGGERS=0;  shift ;;
    --out)        OUT="$2";          shift 2 ;;
    --dry-run)    DRY=1;             shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

for v in $Q8_LIST; do
    case "$v" in *[!0-9]*|"") echo "--q8 values must be non-negative integers: '$v'" >&2; exit 2 ;; esac
done
for v in $TRIGGER_LIST; do
    case "$v" in *[!0-9]*|"") echo "--trigger values must be non-negative integers: '$v'" >&2; exit 2 ;; esac
done
[ -n "$OUT" ] || OUT="$REPO/out/au-ladder-sweep/$(date -u +%Y%m%dT%H%M%SZ)"

AU_IP="${AU_IP:-192.168.3.102}"
AU_PASS="${AU_PASS:-libre}"

PARAMS=/sys/module/ar_isp/parameters
GAINS="rnr_gain lnr_gain de3d_gain cfa_gain cnf_gain"
TRIGGERS="cm_trigger cm2_trigger"
LADDERS=/sys/kernel/debug/ar-isp/ladders
BANKS=/sys/kernel/debug/ar-isp/ladder_banks

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

SAVED_PARAMS=""
RESTORED=0
STOPPED_AE=0

# Put the unit back the way it was found, on every exit path including a failed point or a ^C.
# The gains and triggers are process-lifetime state the AE daemon normally owns; an aborted run
# that skipped this leaves the ladders pinned at the last sweep point until something rewrites
# them, and the restarted daemon only rewrites them on its next actuation.
restore() {
    [ "$RESTORED" = 1 ] && return 0
    RESTORED=1

    echo
    echo "restoring the unit"

    if [ -n "$SAVED_PARAMS" ]; then
        au "$SAVED_PARAMS echo 1 > $LADDERS" \
            || echo "  WARNING: could not restore the gain parameters (unit gone?)" >&2
        echo "  gain and trigger parameters restored"
    fi

    # Only if this run stopped it. A preflight failure exits before the stop, and claiming a
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

    au "test -e $LADDERS -a -e $BANKS" || {
        echo "$LADDERS or $BANKS is missing: this ar_isp has no ladder oracle, nothing to sweep" >&2
        exit 1
    }
    echo "ar-isp ladder nodes: present"

    for p in $GAINS $TRIGGERS; do
        au "test -e $PARAMS/$p" || { echo "$PARAMS/$p is missing" >&2; exit 1; }
    done
    echo "gain and trigger parameters: present"

    # Save before stopping the daemon: what is in the parameters right now is what the restore
    # puts back, whether the daemon or an operator put it there.
    SAVED_PARAMS="$(au "for p in $GAINS $TRIGGERS; do printf 'echo %s > $PARAMS/%s; ' \$(cat $PARAMS/\$p) \$p; done")"
    echo "saved: $SAVED_PARAMS"
else
    SAVED_PARAMS="(dry-run placeholder)"
fi

mkdir -p "$OUT"
echo "output: $OUT"

echo
echo "=== stopping the AE daemon ==="
# The daemon rewrites every parameter this sweep drives, on its own cadence; a point captured
# while it runs measures a race. Stop is idempotent, so a unit where it was not running is fine.
au "rc-service ml-air-ae stop >/dev/null 2>&1 || true"
STOPPED_AE=1
if [ "$DRY" = 0 ]; then
    au "pgrep ml-aed >/dev/null" && { echo "ml-aed still running after stop" >&2; exit 1; }
fi
echo "ml-air-ae stopped"

# judge <file> <label> - the per-point verdict on one captured ladder_banks dump.
#
# Three checks, each of which failed silently in some earlier run:
#   1. "parameter -1" means a stage was skipped: the exact defect this harness exists to prevent.
#   2. Every one of the five gain-keyed stages plus cm and cm2 must contribute comparison rows;
#      a stage whose tuning gate reads clear prints a skip line instead, which is reported but
#      not fatal, because that is the blob's decision and not the harness's.
#   3. The node's own trailing "N mismatches" count is the register verdict.
judge() {
    file="$1"
    label="$2"

    if grep -q 'parameter -1' "$file"; then
        echo "  FAILED at $label: a stage was left replayed:" >&2
        grep 'parameter -1' "$file" | sed 's/^/    /' >&2
        return 1
    fi

    for st in rnr lnr de3d cfa cnf cm cm2; do
        n=$(awk -v st="$st" '$1 == st && $2 ~ /^0x/ { c++ } END { print c + 0 }' "$file")
        if [ "$n" -eq 0 ]; then
            why=$(awk -v st="$st" '$1 == st && $2 !~ /^0x/ { $1 = ""; print; exit }' "$file")
            echo "  $label: $st contributed no comparisons (${why# })"
        else
            printf '  %s: %-4s %s registers\n' "$label" "$st" "$n"
        fi
    done

    tail -1 "$file"
}

echo
echo "=== gain sweep ==="
TOTAL_MISMATCHES=0
for q8 in $Q8_LIST; do
    echo
    echo "--- abscissa Q8 $q8 ($(awk -v q="$q8" 'BEGIN { printf "%.4f", q / 256 }')x) ---"

    cmd=""
    for p in $GAINS; do
        cmd="$cmd echo $q8 > $PARAMS/$p;"
    done
    au "$cmd echo 1 > $LADDERS"

    f="$OUT/banks-q8-$q8.txt"
    if [ "$DRY" = 1 ]; then
        echo "    [dry] capture $BANKS -> $f"
        continue
    fi
    au "cat $BANKS" > "$f"
    judge "$f" "q8 $q8"
    m=$(awk '/mismatches$/ { print $1 }' "$f" | tail -1)
    TOTAL_MISMATCHES=$((TOTAL_MISMATCHES + ${m:-0}))
done

if [ "$SWEEP_TRIGGERS" = 1 ]; then
    echo
    echo "=== trigger sweep (cm/cm2, 0-550 axis) ==="
    # The gains stay wherever the last point left them; cm and cm2 do not read them. Each trigger
    # point moves both stages together, the way ml-aed writes them.
    for t in $TRIGGER_LIST; do
        echo
        echo "--- trigger $t ---"
        au "echo $t > $PARAMS/cm_trigger; echo $t > $PARAMS/cm2_trigger; echo 1 > $LADDERS"

        f="$OUT/banks-trigger-$t.txt"
        if [ "$DRY" = 1 ]; then
            echo "    [dry] capture $BANKS -> $f"
            continue
        fi
        au "cat $BANKS" > "$f"
        judge "$f" "trigger $t"
        m=$(awk '/mismatches$/ { print $1 }' "$f" | tail -1)
        TOTAL_MISMATCHES=$((TOTAL_MISMATCHES + ${m:-0}))
    done
fi

echo
echo "=== verdict ==="
if [ "$DRY" = 1 ]; then
    echo "dry run: no device was touched"
else
    echo "total mismatches across all points: $TOTAL_MISMATCHES"
    echo "captures in $OUT"
    # The known vendor-parity asymmetry: de3d 0x2e90 is a corrected vendor defect
    # (plans/isp-vendor-parity.md rule 5), so a vendor-side capture would disagree there while
    # this node, which compares the driver against its own recomputation, must not. Any nonzero
    # count here is a real defect in the driver or the headers.
    [ "$TOTAL_MISMATCHES" -eq 0 ] || exit 1
fi
