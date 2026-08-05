#!/usr/bin/env bash
# au-v4l2-chain.sh - open the CVISP capture node and nothing else.
#
# The camera stack is brought up by writing debugfs in a fixed order: start the sensor and the
# VIF input path, arm the ISP, configure CVISP, then read frames. au-prove-camera.sh does that,
# and everything measured so far has gone through it. This script tests the opposite: load the
# modules and open the video node, with nothing driving debugfs at all. STREAMON is expected to
# bring the whole chain up on its own, which is what a stock v4l2src needs.
#
# Deliberately separate from au-prove-camera.sh rather than a mode inside it. That script gates
# every stage against a half-bound pipeline because VIF reads with a dead pixel domain hard-hang
# the SoC; those gates read debugfs and drive the chain themselves, which is exactly what is
# being removed here. Keeping the two apart leaves the proven path untouched when this one is
# wrong.
#
# Failure here is cheap: the modules load, the open fails or the grabber times out, and nothing
# has touched VIF or the ISP outside the driver's own ordered sequence.
#
# Usage: glue/camera/au-v4l2-chain.sh
# Env: FRAMES (200), EXPO, GAIN. Target: the active device profile, AU_IP / AU_PASS override.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/au-camera.sh"

EXPO="${EXPO:-1123}"
GAIN="${GAIN:-0x2f}"
FRAMES="${FRAMES:-200}"
# Unset means: pass no depth= at all, so the run tests the driver's own default.
CVDEPTH="${CVDEPTH:-}"
# ISP ladder abscissas, Q8 (256 = 1.0). 3938 (15.38, the vendor dark-capture
# abscissa) is the validated indoor operating point for all three ladders;
# the AE loop will drive these per frame eventually.
DE3D_GAIN="${DE3D_GAIN:-3938}"
LNR_GAIN="${LNR_GAIN:-3938}"
RNR_GAIN="${RNR_GAIN:-3938}"
KD="$REPO/kernel/build/kernel-repro-6.18.36/ml-modules/rootfs/lib/modules/6.18.36/kernel"
OUT="$REPO/out/au-prove"

mkdir -p "$OUT"

echo "=== staging ==="
for m in nt99235 ar-csi2 ar-vif ar-isp ar-cvisp; do
	device_push "$KD/$m.ko" || exit 1
done
device_push "$REPO/native/build/ml-v4l2grab" || exit 1
device_push "$REPO/native/build/ml-regdump" || exit 1
device_push "$REPO/native/build/ml-3a" || exit 1

# The vendor tuning file, verbatim. ar-isp generates its gamma and DRC pages from it.
TUNING="${TUNING:-$REPO/out/air-gather/vendor-root/usr/usrdata/tunning/nt99235_tuning_preview_fpv.bin}"
if [ -s "$TUNING" ]; then
	device_push_as "$TUNING" "/tmp/nt99235-tuning-preview-fpv.bin" || exit 1
else
	echo "  no tuning file at $TUNING: ar-isp will seed, not generate"
fi

# The device half is a file of its own. Its knobs go over as environment rather than being
# interpolated into the script text, so it stays a real file that shellcheck can read.
device_push_as "$HERE/chain-remote.sh" /tmp/chain.sh || exit 1
CHAIN_ENV="EXPO=$EXPO GAIN=$GAIN DE3D_GAIN=$DE3D_GAIN LNR_GAIN=$LNR_GAIN"
CHAIN_ENV="$CHAIN_ENV RNR_GAIN=$RNR_GAIN FRAMES=$FRAMES CVDEPTH='$CVDEPTH'"
sshg "$CHAIN_ENV /tmp/chain.sh"

echo
echo "=== rendering ==="
for p in 0 1 2; do
	device_pull "/tmp/chain.$p" "$OUT/chain.$p" || echo "  no plane $p"
done
sshg 'rm -f /tmp/chain.0 /tmp/chain.1 /tmp/chain.2' </dev/null 2>/dev/null || true
python3 "$HERE/planes2png.py" "$OUT/chain" "$OUT/chain" || true
