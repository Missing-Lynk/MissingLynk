#!/usr/bin/env bash
# au-vendor-darkframe.sh - grab a dark frame out of the streaming vendor's CVISP ring.
#
# Shopping-list item: a vendor dark frame with WRITTEN chroma, for the ring-contour and
# chroma-neutrality comparisons against our own ring. Must be taken from a vendor that is
# streaming, with the lens covered, so the frame is dark because the scene is dark and not
# because nothing was ever written there. A post-mortem read of a stopped pipeline returns
# whatever the last run left in DRAM, which has passed for a good frame before.
#
# READ-ONLY on the device: reads the plane base registers, reads DRAM through /dev/mem, and
# writes nothing. No module is loaded and no slot is touched. Stock slot A only.
#
# Two grabs a couple of seconds apart, because a single grab cannot tell a live ring from a
# stale one. If the two differ, the ring is being written while we read it. If they are
# identical, say so loudly: the frame is residue and the capture is worthless.
#
# The ring geometry is deliberately not assumed here. The plane pointers are read live and a
# generous span covering all of them is pulled verbatim; stride and plane layout are settled
# offline, where a wrong guess costs nothing.
#
# Usage: glue/camera/au-vendor-darkframe.sh [--words N] [--out DIR]
# Env: AU_IP / AU_PASS override the target (default: stock slot A, 192.168.3.100 / artosyn).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/au-camera.sh"

au_stock_slot_a

WORDS=auto
OUT="$REPO/out/au-vendor-darkframe"
while [ $# -gt 0 ]; do
	case "$1" in
	--words) WORDS="$2"; shift 2 ;;
	--out)   OUT="$2";   shift 2 ;;
	*) echo "usage: $0 [--words N] [--out DIR]" >&2; exit 2 ;;
	esac
done
mkdir -p "$OUT"

echo "=== gate: stock slot A, camera streaming ==="
KREL="$(sshg 'uname -r' 2>/dev/null)" || { echo "cannot reach $DEVICE_IP as root/$PASS"; exit 1; }
case "$KREL" in
4.9.*) echo "  kernel $KREL: stock slot A" ;;
*)     echo "  kernel $KREL is not the stock vendor kernel; this must run on slot A"; exit 1 ;;
esac
sshg 'ps | grep -v grep | grep -q ar_lowdelay' || {
	echo "  ar_lowdelay is not running: the ring is not being written, so any frame read now"
	echo "  is residue from a previous run. Nothing read."
	exit 1
}
echo "  ar_lowdelay running: the ring is live"

device_push "$REPO/native/build/ml-regdump" 2>/dev/null
device_push "$REPO/native/build/ml-lutfill" 2>/dev/null

# The plane bases, live. 0x8098 is the ring base the capture node owns; the descriptor plane
# pointers move per boot, so they are read now rather than taken from an earlier session.
echo
echo "=== live plane pointers ==="
sshg "/tmp/ml-regdump 0x08e08000 128" > "$OUT/cvisp-8000.txt" 2>/dev/null
python3 - "$OUT/cvisp-8000.txt" <<'PY' | tee "$OUT/planes.txt"
import re, sys, pathlib
words = {}
for line in pathlib.Path(sys.argv[1]).read_text(errors="replace").split("\n"):
    m = re.match(r"\+0x([0-9a-f]+):\s+(.*)", line.strip())
    if not m:
        continue
    off = int(m.group(1), 16)
    for k, w in enumerate(m.group(2).split()):
        words[0x8000 + off + 4 * k] = int(w, 16)

# A plane base is a page-aligned pointer into the vendor carveout. The alignment is what
# separates a real base from 0x3ffffc00, the value the unused ports carry: it sits inside
# the carveout range but lands mid-page, so an address test alone accepts it and stretches
# the span across the whole of DRAM.
SENTINEL = 0x3ffffc00
live = {o: v for o, v in sorted(words.items())
        if 0x20000000 <= v < 0x40000000 and v % 0x1000 == 0 and v != SENTINEL}
unused = sorted({v for v in words.values() if v == SENTINEL})
for off, val in live.items():
    print(f"{off:#06x} -> {val:#010x}")
if unused:
    print(f"({sum(1 for v in words.values() if v == SENTINEL)} pointers hold the unused-port "
          f"sentinel {SENTINEL:#010x} and are ignored)")
if live:
    bases = sorted(live.values())
    lo, hi = bases[0], bases[-1]
    gaps = [b - a for a, b in zip(bases, bases[1:])]
    # The last plane has no following base to bound it. Every plane is at most the largest
    # gap between two consecutive bases, so that is the smallest span that cannot truncate
    # it without assuming a stride the capture is meant to establish.
    tail = max(gaps) if gaps else 0
    for a, b in zip(bases, bases[1:]):
        print(f"gap {b - a}")
    print(f"base {lo:#010x}")
    print(f"span {hi - lo + tail}")
PY

BASE="$(awk '/^base/ { print $2 }' "$OUT/planes.txt")"
SPAN="$(awk '/^span/ { print $2 }' "$OUT/planes.txt")"
if [ -z "$BASE" ]; then
	echo "no live plane pointers found; the ring is not configured. Nothing read."
	exit 1
fi

# The span already reaches past the last plane base by the largest inter-base gap, so it
# covers every plane whole. An explicit --words wins.
if [ "$WORDS" = auto ]; then
	WORDS=$(( SPAN / 4 ))
fi
BYTES=$((WORDS * 4))
echo
echo "  dumping $BYTES bytes from $BASE"

# One grab has to fit in the device's /tmp; it is pulled and removed before the next.
FREEK="$(sshg 'df -k /tmp | awk "NR==2 { print \$4 }"' 2>/dev/null)"
if [ -n "$FREEK" ] && [ "$FREEK" -lt $((BYTES / 1024 + 1024)) ]; then
	echo "  /tmp has ${FREEK}K free, which is not enough for a ${BYTES}-byte grab."
	echo "  Re-run with a smaller --words. Nothing read."
	exit 1
fi
echo "  /tmp has ${FREEK:-unknown}K free"

grab() {
	local tag="$1"
	echo "  grab $tag ..."
	sshg "/tmp/ml-lutfill $BASE $WORDS save:/tmp/darkframe.bin" </dev/null >/dev/null 2>&1 || {
		echo "  grab $tag failed"; return 1; }
	device_pull "/tmp/darkframe.bin" "$OUT/darkframe-$tag.bin" 2>/dev/null || {
		echo "  pull $tag failed"; return 1; }
	sshg "rm -f /tmp/darkframe.bin" </dev/null >/dev/null 2>&1
	echo "  grab $tag -> $OUT/darkframe-$tag.bin"
}

echo
echo "=== two grabs, to tell a live ring from residue ==="
grab a || exit 1
sleep 3
grab b || exit 1

echo
echo "=== liveness ==="
if cmp -s "$OUT/darkframe-a.bin" "$OUT/darkframe-b.bin"; then
	echo "  THE TWO GRABS ARE IDENTICAL."
	echo "  Byte-for-byte equal three seconds apart means the ring is not being written and"
	echo "  this is residue, not a frame. Do not use it. Check the pipeline is actually live."
	exit 1
fi
DIFFB="$(cmp -l "$OUT/darkframe-a.bin" "$OUT/darkframe-b.bin" 2>/dev/null | wc -l)"
echo "  the two grabs differ in $DIFFB of $BYTES bytes: the ring is live"

echo
echo "=== saved to $OUT ==="
ls -l "$OUT"
