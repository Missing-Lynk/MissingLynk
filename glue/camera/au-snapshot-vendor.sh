#!/usr/bin/env bash
# au-snapshot-vendor.sh - capture the vendor's COMPLETE working camera configuration.
#
# READ-ONLY on the device: registers and memory are read, nothing is written, no module is
# loaded, no slot is touched. Must run on stock slot A while the vendor camera is streaming.
#
# The premise: we have spent a long time reconstructing the vendor's configuration from
# instruction traces and reverse engineering, when the finished configuration is sitting in
# registers on hardware that works. A snapshot of that end state can be diffed directly
# against our replay, which turns "what are we missing" into a list.
#
# It also gets us the tuning blob's payload without parsing the blob. The vendor generates its
# tables from the file at runtime; we cannot yet reproduce that transform, but we can read the
# GENERATED tables straight out of DRAM. That is the blob's effect in hardware form, and for a
# fixed sensor and mode it is all we need.
#
# Bounded to the register clusters our own driver already writes, so every address read is one
# we know is mapped. Reads are safe while the pipeline is live; the documented hang is reading
# a block whose clock is gated, which is why this refuses to run unless the camera is streaming.
#
# Usage: glue/camera/au-snapshot-vendor.sh
# Env: none. Targets stock slot A (192.168.3.100 / artosyn); AU_IP / AU_PASS override.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/au-camera.sh"

# Reads the vendor stack: slot A only.
au_stock_slot_a

OUT="$REPO/out/au-snapshot"

mkdir -p "$OUT"

echo "=== gate: stock slot A, camera streaming ==="
KREL="$(sshg 'uname -r' 2>/dev/null)" || { echo "cannot reach $DEVICE_IP as root/$PASS"; exit 1; }
case "$KREL" in
4.9.*) echo "  kernel $KREL: stock slot A" ;;
*)     echo "  kernel $KREL is not the stock vendor kernel; this must run on slot A"; exit 1 ;;
esac
sshg 'ps | grep -v grep | grep -q ar_lowdelay' || {
	echo "  ar_lowdelay is not running: the pipeline is not live, so register reads are unsafe"
	echo "  and any table pointer would be stale. Nothing read."
	exit 1
}
echo "  ar_lowdelay running: pipeline is live"

for t in ml-regdump ml-lutfill ml-i2cprobe
do
	device_push "$REPO/native/build/$t" 2>/dev/null || echo "  (optional tool $t not staged)"
done

# Register clusters. The ISP list is exactly the span our replay writes, derived from
# ar-isp-defaults.h, so each is known-mapped. The other blocks use the windows our drivers map.
echo
echo "=== register windows ==="
{
	for spec in \
		isp:0x08c00000:0x0000:64    isp:0x08c00000:0x0800:322 \
		isp:0x08c00000:0x1800:512   isp:0x08c00000:0x2400:16 \
		isp:0x08c00000:0x4000:64 \
		isp:0x08c00000:0x2800:64    isp:0x08c00000:0x2e00:1032 \
		isp:0x08c00000:0x4800:576   isp:0x08c00000:0x5800:28 \
		isp:0x08c00000:0x6000:384   isp:0x08c00000:0x6c00:704 \
		cvisp:0x08e00000:0x8000:64  cvisp:0x08e00000:0x4600:16 \
		cvisp:0x08e00000:0x4000:256 cvisp:0x08e00000:0x4400:64 \
		cvisp:0x08e00000:0x4700:16 \
		vif:0x08870000:0x0000:256   vif:0x08870000:0x0300:64 \
		csi2:0x08880000:0x0400:64   csi2:0x08880000:0x0800:64 \
		cgu:0x0a104000:0x0000:32
	do
		blk=${spec%%:*}; rest=${spec#*:}
		base=${rest%%:*}; rest=${rest#*:}
		off=${rest%%:*}; cnt=${rest##*:}
		echo "--- $blk +$off ($cnt words) ---"
		sshg "/tmp/ml-regdump \$(printf '0x%x' \$(( $base + $off ))) $cnt" 2>/dev/null
	done
} | tee "$OUT/registers.txt"

# Sensor state last: the i2c bus is shared with the running vendor stack, so a probe here is
# the one operation with any chance of disturbing it.
echo
echo "=== sensor registers over i2c ==="
sshg '/tmp/ml-i2cprobe 0 0x1a 0x0200 -n 12 2>/dev/null; /tmp/ml-i2cprobe 0 0x1a 0x0340 -n 4 2>/dev/null' \
	| tee "$OUT/sensor.txt" || echo "  (i2c probe unavailable, skipped)"

# Auto-discover every DMA table: any register holding what looks like a DRAM pointer into the
# vendor's carveout is a candidate, so this finds LSC, LUT3D, GTM2 and LTM without having to
# know their register offsets in advance.
echo
echo "=== discovering table pointers ==="
python3 - "$OUT" <<'PYE' > "$OUT/pointers.txt"
import re, sys, os
out = sys.argv[1]
txt = open(os.path.join(out, "registers.txt")).read()
block, base = None, 0
seen = {}
for line in txt.splitlines():
    m = re.match(r"--- (\w+) \+(0x[0-9a-f]+)", line)
    if m:
        block, base = m.group(1), int(m.group(2), 16)
        continue
    m = re.match(r"\+0x([0-9a-f]+):((?: [0-9a-f]{8})+)", line)
    if not m or block is None:
        continue
    off = base + int(m.group(1), 16)
    for i, w in enumerate(m.group(2).split()):
        v = int(w, 16)
        # The vendor's media carveout sits above the kernel's capped memory.
        if 0x28000000 <= v < 0x40000000:
            seen[(block, off + 4 * i)] = v
for (blk, off), v in sorted(seen.items()):
    print("%-6s +0x%04x  ->  0x%08x" % (blk, off, v))
print("\n%d candidate table pointers" % len(seen))
PYE
cat "$OUT/pointers.txt"

echo
echo "=== dumping the pointed-to buffers ==="
# Length is unknown per table, so take a generous fixed window; the real extent shows up as the
# point where content stops looking like a table. Better too much than a truncated table.
# Read the list up front. Every ssh in the loop body reads stdin, so a `while read ... done <
# file` loop loses its input to the first ssh and silently processes one entry.
mapfile -t PTRS < <(awk '$3 == "->" { print $1, $2, $4 }' "$OUT/pointers.txt")
for line in "${PTRS[@]}"
do
	# shellcheck disable=SC2086  # word splitting is the point: one dump line into three fields.
	set -- $line
	blk="$1"; off="$2"; addr="$3"
	nm="$(printf '%s_%s' "$blk" "${off#+}")"
	if sshg "/tmp/ml-lutfill $addr 8192 save:/tmp/tbl_$nm.bin" </dev/null >/dev/null 2>&1
	then
		device_pull "/tmp/tbl_$nm.bin" "$OUT/tbl_$nm.bin" 2>/dev/null && echo "  $nm from $addr"
	else
		echo "  $nm at $addr: unreadable, skipped"
	fi
done

echo
echo "=== saved to $OUT ==="
ls -l "$OUT"
echo
echo "Next: diff registers.txt against our replay to get the list of configuration differences."
