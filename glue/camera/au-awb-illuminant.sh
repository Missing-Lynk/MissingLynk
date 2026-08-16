#!/usr/bin/env bash
# au-awb-illuminant.sh - the AWB second-illuminant capture, and the replayed-row discriminator.
#
#   ILLUM=daylight glue/camera/au-awb-illuminant.sh
#   ILLUM=warm     glue/camera/au-awb-illuminant.sh
#
# Shopping-list items 4 and 5 in one breath, on the STREAMING VENDOR, slot A. Strictly read
# only: nothing is written, no module is loaded, no slot is touched. The only device-side files
# are one static tool and the output, both under /tmp.
#
# Run it twice at clearly different colour temperatures and keep the light LEVEL as close as the
# scene allows. Level is the variable of a different capture; mixing the two gives a pair that
# cannot separate a colour response from a luminance one, which is why the two captures we
# already hold cannot seed this oracle.
#
# What each half is for:
#
#   AWB (item 4). wb 0x5000, ccm1 0x3400 and the LSC group-selection state are the AWB family's
#   outputs. The algorithm itself is a pure estimator, mapped by kernel/scripts/isp/awb-map.py
#   and writing no registers of its own, so these banks are where its result becomes visible.
#   Two colour points bracket the interpolation the same way two abscissae bracket a ladder.
#
#   ANSWERED, on four captures spanning warm lamp, cold lamp and daylight: none of them move.
#   awbs_stats bit 0 of 0x6c00 is clear, its bank is bit-identical in all four, and so are wb,
#   ccm1 and lsc. The vendor ships AWB gated off. Re-running this is a regression check, not an
#   open question.
#
#   The discriminator (item 5). cfa, cnf, acm, qgg and cm/cm2 in the same breath as the AWB
#   rows. Two of those are now a prediction rather than a question: plans/isp-cfa-cnf.md derives
#   cfa and cnf from the blob and says that at a blending abscissa the vendor reads 0x08ac..0x08d4
#   as zero and 0x0868 as 0x2dc6c0 where a pinned replay writes the record-0 values. Twelve
#   registers decide it.
#
# The AE state is captured alongside because the abscissa every ladder is keyed on is an AE
# product: without it, a row that moved cannot be attributed to colour rather than to gain.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/au-camera.sh"

# Slot A is the vendor. au_stock_slot_a repoints the transport at it; without this the script
# would read our own stack and prove nothing about the vendor's AWB.
au_stock_slot_a

ILLUM="${ILLUM:?set ILLUM to a label for this light, e.g. daylight or warm}"
OUT="${OUT:-$REPO/out/au-awb}"
mkdir -p "$OUT"
DST="$OUT/$ILLUM.txt"

if [ -e "$DST" ]; then
	echo "refusing: $DST exists; move it aside or pick another ILLUM label" >&2
	exit 1
fi

echo "=== slot A at $DEVICE_IP, illuminant '$ILLUM' ==="
sshg 'cat /proc/uptime; uname -r'
device_push "$REPO/native/build/ml-regdump"

# One heredoc, so every window is read from one process in as close to one instant as the
# device allows. The AWB gains and the rows that are supposed to follow them must come from the
# same frame state or the pair cannot be compared.
sshg "cat > /tmp/awb.sh <<'EOS'
#!/bin/sh
OUT=/tmp/awb.txt
: > \$OUT

# The front-end gate first: without incoming video every bank below is a stale state, and a
# capture that does not say so reads like a measurement.
echo \"GATE-BEFORE \$(/tmp/ml-regdump 0x088701f0 1 | cut -d' ' -f2)\" >> \$OUT

dump() {
  echo \"SECTION \$1\" >> \$OUT
  /tmp/ml-regdump \$2 \$3 >> \$OUT
}

# --- item 4: the AWB family ---
dump wb            0x08c05000 16
dump ccm1          0x08c03400 32
dump cm2           0x08c04800 32
dump ccm2          0x08c03800 32
dump lsc           0x08c04c00 32
dump hdr_lsc       0x08c01dd0 32
dump awbs_stats    0x08c06c00 32

# --- item 5: the replayed-row discriminator ---
dump cfa           0x08c00800 54
dump cnf           0x08c03c64 16
dump acm           0x08c07600 4
dump qgg           0x08c07230 8
dump cm            0x08c04834 8

# --- the abscissa these are keyed on, so a moved row can be attributed ---
dump rnr_ladder    0x08c01808 12
dump control       0x08c00000 8

echo \"GATE-AFTER \$(/tmp/ml-regdump 0x088701f0 1 | cut -d' ' -f2)\" >> \$OUT
echo CAPTURE-DONE
EOS
chmod +x /tmp/awb.sh; /tmp/awb.sh"

device_pull /tmp/awb.txt "$DST"

echo
grep -E '^GATE-' "$DST" || true
echo "sections: $(grep -c '^SECTION' "$DST")   lines: $(wc -l < "$DST")"
echo "saved: $DST"

if ! grep -q 'GATE-BEFORE 0784043c' "$DST"; then
	echo
	echo "WARNING: the VIF front end was not measuring incoming video during this capture."
	echo "Nothing downstream of it can be interpreted, including every AWB row above."
fi

# Counted by globbing rather than parsing ls: a nullglob-less shell leaves the pattern itself in
# the array when nothing matches, so the explicit -e test is what makes an empty directory read 0.
have=0
for f in "$OUT"/*.txt; do
	[ -e "$f" ] && have=$((have + 1))
done

if [ "$have" -lt 2 ]; then
	echo
	echo "One illuminant captured. The oracle needs two at clearly different colour"
	echo "temperatures; re-run with ILLUM set to the other light before changing anything."
fi
