#!/usr/bin/env bash
# latency-publish.sh - promote a latency run from the out/ working area into docs/latency/.
#
# Captures are taken into out/, which is gitignored: an ml-pipeline log is ~500 kB per leg and there
# is no reason to carry one in the tree. What is worth keeping is small and is what a later run
# actually compares against: the parsed medians, the build and knobs the run was taken under, the
# rendered timeline, and the clock trace. Those are copied; the log stays where it was captured.
#
# The destination keeps the run's own directory name, which carries the build the goggle was
# running, so docs/latency/ reads as a history and glue/capture/latency-compare.py can tabulate the
# whole of it at once.
#
# Usage:
#   glue/capture/latency-publish.sh out/pinned-clock-latency/<run>
#   glue/capture/latency-publish.sh out/goggle-latency/*/
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DEST_BASE="${DEST_BASE:-$REPO/docs/latency}"

# The log is the primary artefact: summary.json, the timeline and every table are derived from it,
# and a published run whose log is gone can never be re-read with a question the summary did not
# anticipate. It is copied as plain text, not compressed: git zlib-compresses and deltas text in the
# packfile already, so a compressed member costs more space than the text it replaces and gives up
# grep, diff and review of the one file most worth reading.
#
# Beside it go the conditions the run was taken under, the timeline a person actually opens, and the
# conclusion drawn from it. Not published: the clock trace, whose scalars are folded into each leg's
# summary as pixclk_hz_* and dsi_int_st1; the run identity repeated per leg, when the legs share one
# boot; and the harness's own stdout, which only says whether the run completed.
#
# codec.txt rides along for latency-matrix runs: the DVR codec is read at ml-pipeline startup, so it
# is a property of the whole run rather than of a leg, and it is the condition that decides whether
# two runs' encoder deltas can be read against each other.
KEEP_RUN=(identity.txt metadata.txt RESULT.md codec.txt)
KEEP_CAPTURE=(summary.json goggle-latency-timeline.svg)
LOG=ml-pipeline.log

[ $# -gt 0 ] || { sed -n '2,20p' "$0"; exit 2; }

# publish_file <src> <dest>
publish_file() {
    mkdir -p "$(dirname "$2")"
    cp -p "$1" "$2"
}

status=0
for run in "$@"; do
    run="${run%/}"
    [ -d "$run" ] || { echo "not a directory: $run" >&2; status=1; continue; }

    dest="$DEST_BASE/$(basename "$run")"
    copied=0

    for name in "${KEEP_RUN[@]}"; do
        [ -f "$run/$name" ] || continue
        publish_file "$run/$name" "$dest/$name" && copied=$((copied + 1))
    done

    # Capture directories are the run root itself for a single capture, or one level down per leg.
    while IFS= read -r summary; do
        src_dir="$(dirname "$summary")"
        rel="${src_dir#"$run"}"
        rel="${rel#/}"
        out_dir="$dest${rel:+/$rel}"

        for name in "${KEEP_CAPTURE[@]}"; do
            [ -f "$src_dir/$name" ] || continue
            publish_file "$src_dir/$name" "$out_dir/$name" && copied=$((copied + 1))
        done

        if [ -f "$src_dir/$LOG" ]; then
            publish_file "$src_dir/$LOG" "$out_dir/$LOG" && copied=$((copied + 1))
        fi
    done < <(find "$run" -type f -name summary.json | sort)

    if [ "$copied" -eq 0 ]; then
        echo "$run: nothing to publish (no summary.json; was the capture rendered?)" >&2
        status=1
        continue
    fi
    echo "published $copied file(s) to $dest"
done

exit "$status"
