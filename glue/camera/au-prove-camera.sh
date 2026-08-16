#!/usr/bin/env bash
# au-prove-camera.sh - prove the camera works, and prove nothing else.
#
# Captures two frames and renders both to PNG: the sensor's colour-bar test pattern, which has
# known content and does not depend on optics or lighting, and a live frame of whatever the lens
# is pointed at.
#
# A plain run stages nothing beyond the modules and the tuning file. The ISP experiment knobs
# (BLOCK3D, GAMMA, SWEEP, REARM, LSCPOKE, HDRPOKE) are staged by stage_isp_experiments in
# glue/lib/isp-experiment.sh, which is where their documentation now lives; unset, it clears
# each artifact so a previous run cannot bleed into this one. Their device-side half is still
# in the prove.sh heredoc below, so this remains one entry point rather than two. Separating
# it needs the 18 host variables that heredoc interpolates at push time turned into passed
# environment, which is a change to the script that runs on hardware.
#
# Every stage is gated. The reason is specific: a previous run let an orphaned ml-v4l2grab hold
# the capture node, which made rmmod fail silently, so later bring-ups ran on stale half-rebound
# modules and produced black frames that looked like real measurements. Worse, the script then
# continued into the ISP arm and ml-isploop with no live pixel domain, and VIF reads in that
# state hard-hang the SoC into a watchdog reset to slot A.
#
# So: if the graph does not bind, or the video node is missing, or the grabber dies, this stops
# BEFORE anything touches VIF or the ISP, and prints the kernel log instead. A failure here
# costs a message, not a battery pull.
#
# It also kills and verifies the grabber on the way out, so it never leaves the orphan that
# started the whole problem.
#
# Usage: glue/camera/au-prove-camera.sh
# Env: EXPO (1123), GAIN (0x2f), BULK (1475). Target: the active device profile, AU_IP /
#      AU_PASS override.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/au-camera.sh"
# shellcheck source=../lib/isp-experiment.sh
. "$HERE/../lib/isp-experiment.sh"

EXPO="${EXPO:-1123}"
GAIN="${GAIN:-0x2f}"
BULK="${BULK:-1475}"
# ar-isp coefficient-table levers, passed straight through to the module.
#   TABLES=1  own the gamma and DRC DMA buffers instead of arming the vendor's
#   SEED=1    seed the owned buffers from the vendor's inherited pages first, so the regions we
#             cannot generate (gamma page 1 and its 0x1000..0x3fff tail) keep working
#   GAMMA_CURVE / DRC_PROFILE   which tuning-file entry to build, -1 to leave the page alone
#   COMPANDER=1  own the compander page too and fill it from the carried template. It has no
#             tuning-file source and no runtime generator: the vendor installs the same bytes
#             on every unit, so there is nothing to select and no seed path.
#   LSC=1     own the LSC page and generate its lens-shading grid from the tuning file. Only
#             region A is generated; the scene-adaptive half has no stored source and follows
#             SEED, so LSC=1 SEED=0 runs the block on shading with no adaptation at all.
#
# The useful runs, in order, one bring-up each:
#   TABLES=0                          today's behaviour, the control
#   TABLES=1 SEED=1                   only the addresses move, content unchanged
#   TABLES=1 SEED=1 GAMMA_CURVE=3 DRC_PROFILE=3   generated content, unknown regions inherited
#   TABLES=1 SEED=0                   nothing inherited: the cold-boot-honest case
TABLES="${TABLES:-1}"
SEED="${SEED:-1}"
GAMMA_CURVE="${GAMMA_CURVE:-3}"
DRC_PROFILE="${DRC_PROFILE:-4}"
COMPANDER="${COMPANDER:-1}"
LSC="${LSC:-1}"
# STATS=1 allocates the AE statistics buffers here and points the RRO engines and the raw
# histogram at them instead of the vendor's. Only holds while the per-frame ISP cycle is off:
# that cycle re-arms the vendor's addresses, so a run with --isp-cycle silently reverts it.
STATS="${STATS:-1}"
# CCM=1 installs the colour matrix from the tuning file into ccm1 after the register prefix.
# It matters more than it looks: the replay carries the vendor's runtime matrix, but at setup
# entry 1718, so any BULK below that leaves ccm1 at the identity the earlier entries wrote.
# Every bring-up before this one ran with colour correction off for exactly that reason.
# CCM_BANK picks the illuminant bank, 0 to 3; 0 is the one the vendor was traced writing.
CCM="${CCM:-1}"
CCM_BANK="${CCM_BANK:-0}"
# BLC=1 generates black level correction from the tuning file instead of leaving the constants
# the CVISP late table carries. BLC_GAIN is the sensor gain it blends for, in the tuning file's
# ladder units: 187 is the vendor's traced operating point and reproduces its registers exactly.
# The stage recomputes with gain on the vendor, so this becomes an AE input rather than a knob.
BLC="${BLC:-1}"
BLC_GAIN="${BLC_GAIN:-187}"
# Frame ticks the CVISP capture node holds a buffer before handing it back. 2 is measured
# sufficient; 1 is the open question, and worth settling because it returns a buffer to a pool
# that only holds five. Run it with V4L2MARK=1: too low shows up as bottom rows coming back
# still carrying the marker.
CVDEPTH="${CVDEPTH:-2}"
# DE3D=1 allocates de3d's three working buffers instead of leaving it writing the vendor's
# memory. Sizes are bounds derived from the vendor's own packing, not measured extents, and
# the third has no bound above it at all; see ar-isp-tables.c. Unlike the other levers this one can
# change the picture, because de3d starts from an empty history rather than an inherited one.
DE3D="${DE3D:-1}"
# Complete frames from the VIF frame-done interrupt instead of the polling work item. Off by
# default because the acknowledge behaviour is unconfirmed and the line is level triggered.
USE_IRQ="${USE_IRQ:-1}"
# Capture window in seconds. The one clean frame of the day was a 1 s grab; 4 s grabs are
# crushed on the same configuration, and this system is documented as giving different answers
# at 1 s and 4 s. Keep this at 1 unless deliberately probing the drift.
WATCH="${WATCH:-1}"
# Modules are read from the staged module tree, which is what the build actually installs.
# The in-tree drivers/media/artosyn directory is a sync target and is left without objects,
# so reading from it silently stages whatever a previous build happened to leave behind.
KD="$REPO/kernel/build/kernel-repro-6.18.36/ml-modules/rootfs/lib/modules/6.18.36/kernel"
OUT="$REPO/out/au-prove"

mkdir -p "$OUT"

echo "=== staging ==="
for m in nt99235 ar-csi2 ar-vif ar-isp ar-cvisp; do
	device_push "$KD/$m.ko" || exit 1
done

for t in ml-regdump ml-v4l2grab ml-isploop ml-lutfill ml-i2cprobe; do
	device_push "$REPO/native/build/$t" || exit 1
done

# The vendor tuning file, verbatim. ar-isp loads it through request_firmware and generates the
# gamma and DRC pages from it; without it the driver still owns the buffers but can only seed
# them from whatever the vendor left in DRAM. It is proprietary, so it is not in the repository:
# this is the copy `missinglynk dump-firmware` pulled off a stock unit.
TUNING="${TUNING:-$REPO/out/air-gather/vendor-root/usr/usrdata/tunning/nt99235_tuning_preview_fpv.bin}"
if [ -s "$TUNING" ]; then
	device_push_as "$TUNING" "/tmp/nt99235-tuning-preview-fpv.bin" || exit 1
	echo "  staged tuning file, $(stat -c %s "$TUNING") bytes"
else
	echo "  NO tuning file at $TUNING: ar-isp will seed, not generate"
	sshg 'rm -f /tmp/nt99235-tuning-preview-fpv.bin' </dev/null 2>/dev/null || true
fi

# The optional experiment artifacts: BLOCK3D, GAMMA, SWEEP, REARM, LSCPOKE and HDRPOKE.
# None is set in an ordinary run, and the helper clears each one's device-side file when it
# is not, so a leftover cannot join the next bring-up. Sets SWEEP_NAMES.
stage_isp_experiments "$HERE" "$OUT"

# The register windows stage 5c dumps, shared with au-snapshot-vendor.sh so the two dumps stay
# diffable. Passed to the device script as environment, like the other host variables.
ISP_WINDOWS="$(grep -v '^#' "$HERE/isp-windows.list" | tr '\n' ' ')"

# The device half is a file of its own, staged here. It goes over stdin rather than as an ssh
# argument: it outgrew the command-line limit once the sweep stages were added, and the failure
# mode was a broken pipe during staging followed by "prove.sh: not found", which reads like a
# device fault and is not. device_push_as sends it the same way.
device_push_as "$HERE/prove-remote.sh" /tmp/prove.sh || exit 1

# The insmod arguments and register windows prove-remote.sh reads. Built here so the invocation
# below stays readable. ISP_WINDOWS is quoted because it is a space-separated list the device
# script re-splits; the rest are scalars.
PROVE_ENV="USE_IRQ=$USE_IRQ TABLES=$TABLES SEED=$SEED GAMMA_CURVE=$GAMMA_CURVE"
PROVE_ENV="$PROVE_ENV DRC_PROFILE=$DRC_PROFILE COMPANDER=$COMPANDER LSC=$LSC STATS=$STATS"
PROVE_ENV="$PROVE_ENV CCM=$CCM CCM_BANK=$CCM_BANK DE3D=$DE3D BULK=$BULK BLC=$BLC"
PROVE_ENV="$PROVE_ENV BLC_GAIN=$BLC_GAIN CVDEPTH=$CVDEPTH EXPO=$EXPO GAIN=$GAIN"
PROVE_ENV="$PROVE_ENV ISP_WINDOWS='$ISP_WINDOWS'"

# Only the FIRST bring-up after a boot writes to DRAM; every later one re-reads the frame the
# first one left. So a boot buys exactly one trustworthy capture, and RUNS selects which.
#   RUNS="0:live:nocycle"        one live frame
#   RUNS="2:testpattern:nocycle" one pattern frame
for run in ${RUNS:-"2:testpattern:nocycle" "0:live:nocycle" "0:live2:nocycle"}; do
	tp="${run%%:*}"
	rest="${run#*:}"
	name="${rest%%:*}"
	cyc="${run##*:}"
	echo
	echo "=== capture: $name (test_pattern=$tp, $cyc) ==="
	if ! sshg "$PROVE_ENV WATCH=$WATCH ESWEEP='${ESWEEP:-}' SWEEP_COLOUR='${SWEEP_COLOUR:-}' LSCPOKE='${LSCPOKE:-0}' HDRPOKE='${HDRPOKE:-0}' SWITCH_TP='${SWITCH_TP:-}' V4L2CAP='${V4L2CAP:-}' V4L2MARK='${V4L2MARK:-}' /tmp/prove.sh $tp $name $cyc"; then
		echo ">>> $name FAILED, stopping. Nothing touched VIF or the ISP."
		exit 1
	fi

	for p in 0 1 2; do
		device_pull "/tmp/$name.$p" "$OUT/$name.$p" 2>/dev/null || true
	done

	ESWEEP_NAMES=""
	for es in ${ESWEEP:-}; do
		ESWEEP_NAMES="$ESWEEP_NAMES e${es%%:*}_g${es##*:}"
	done

	for sw in $ESWEEP_NAMES $SWEEP_NAMES; do
		for p in 0 1 2; do
			device_pull "/tmp/${name}_$sw.$p" "$OUT/${name}_$sw.$p" 2>/dev/null || true
		done

		# /tmp is a 32 MB tmpfs and each capture is about 5.4 MB, so a sweep of more than
		# five steps fills it. The failure is silent and looks exactly like a capture that
		# had no effect: the last plane comes back zero-length. Free each one once it is off
		# the device.
		sshg "rm -f /tmp/${name}_$sw.[012]" </dev/null 2>/dev/null || true
		python3 "$HERE/planes2png.py" "$OUT/${name}_$sw" "$OUT/${name}_$sw" || true
	done

	for t in gamma compander drc; do
		device_pull "/tmp/pre_$t.bin" "$OUT/pre_$t.bin" 2>/dev/null || true
	done

	# The LSC page as the vendor computed it for this scene. hdf-037 established it has no
	# static source: it is built at runtime from stats, so this capture is the only form of
	# it we can hold, and the open driver carries a captured page rather than generating one.
	if [ "${LSCPOKE:-0}" = 1 ]; then
		device_pull "/tmp/lsc_pre.bin" "$OUT/lsc_pre.bin" 2>/dev/null || true
	fi

	# Stage 7b's artifacts. Unconditional: that stage is passive and always runs, so gating
	# these on a poke lever loses them silently, which is how the first run lost both.
	device_pull "/tmp/rro_raw.bin" "$OUT/rro_raw.bin" 2>/dev/null || true
	device_pull "/tmp/lut3d.bin" "$OUT/lut3d.bin" 2>/dev/null || true
	device_pull "/tmp/ltm_page.bin" "$OUT/ltm_page_${SCENE:-a}.bin" 2>/dev/null || true
	if [ "${HDRPOKE:-0}" = 1 ]; then
		device_pull "/tmp/gtm2_pre.bin" "$OUT/gtm2_pre.bin" 2>/dev/null || true
	fi

	device_pull "/tmp/oursensor.txt" "$REPO/out/au-snapshot/ours-sensor-full.txt" 2>/dev/null || true

	# Mid-stream register windows, for the live-against-live diff. Small, so unlike the raw
	# frame this pull is reliable over the RF link.
	device_pull "/tmp/ourisp.txt" "$REPO/out/au-snapshot/ours-registers-live.txt" 2>/dev/null || true
	if [ -n "${BLOCK3D:-}" ]; then
		for p in 0 1 2; do
			device_pull "/tmp/${name}_b3d.$p" "$OUT/${name}_b3d.$p" 2>/dev/null || true
		done

		sshg "rm -f /tmp/${name}_b3d.[012]" </dev/null 2>/dev/null || true
		python3 "$HERE/planes2png.py" "$OUT/${name}_b3d" "$OUT/${name}_b3d" || true
		device_pull "/tmp/ourisp_b3d.txt" "$REPO/out/au-snapshot/ours-registers-live-b3d.txt" 2>/dev/null || true
	fi

	if [ -s "$REPO/out/au-snapshot/ours-registers-live.txt" ]; then
		echo "  pulled mid-stream registers: $(grep -c '^+0x' "$REPO/out/au-snapshot/ours-registers-live.txt") lines"
	else
		echo "  WARNING: mid-stream register pull came back EMPTY"
	fi

	# What the vendor left at its own addresses, which the driver may seed from.
	#
	# This used to score each page by zero fraction and monotonicity and call all three
	# "garbage". That was wrong, and it was wrong about correct data: the compander figures
	# it printed are byte-identical to the vendor's prepacked constant, and the DRC and gamma
	# pages decode exactly as tuning-file entries. These are packed multi-lane formats, so a
	# correct table is neither mostly zero nor monotonic read as a flat u32 array, and both
	# scores measured the packing rather than the content.
	#
	# It now decodes instead of guessing. Absent a decode it says so rather than judging.
	python3 "$HERE/tuning-residency.py" "$OUT"
	python3 "$HERE/planes2png.py" "$OUT/$name" "$OUT/$name" || true

	# The capture taken through the CVISP video node, if V4L2CAP asked for one.
	# Rendered with the same script as every other capture: the node's plane
	# sizes carry the vendor's slot tails, which are longer than stride x height,
	# and planes2png.py crops rather than assuming an exact length.
	if [ -n "${V4L2CAP:-}" ]; then
		for p in 0 1 2; do
			device_pull "/tmp/${name}_v4l2.$p" "$OUT/${name}_v4l2.$p" 2>/dev/null || true
		done

		sshg "rm -f /tmp/${name}_v4l2.[012]" </dev/null 2>/dev/null || true
		python3 "$HERE/planes2png.py" "$OUT/${name}_v4l2" "$OUT/${name}_v4l2" || true
		if [ -s "$OUT/$name.0" ] && [ -s "$OUT/${name}_v4l2.0" ]; then
			if cmp -s "$OUT/$name.0" "$OUT/${name}_v4l2.0"; then
				echo "  node check: IDENTICAL to the /dev/mem capture -> suspect a stale read, not a node frame"
			else
				echo "  node check: DIFFERS from the /dev/mem capture, as two frames of a live scene should"
			fi
		fi
	fi

	# The mid-stream pattern switch, if SWITCH_TP asked for one. Same bring-up,
	# so this pair is directly comparable: same optics, same ISP state, only the
	# sensor's pattern generator changed between them.
	if [ -n "${SWITCH_TP:-}" ]; then
		for p in 0 1 2; do
			device_pull "/tmp/${name}_sw.$p" "$OUT/${name}_sw.$p" 2>/dev/null || true
		done
		sshg "rm -f /tmp/${name}_sw.[012]" </dev/null 2>/dev/null || true
		python3 "$HERE/planes2png.py" "$OUT/${name}_sw" "$OUT/${name}_sw" || true
		if [ -s "$OUT/$name.0" ] && [ -s "$OUT/${name}_sw.0" ]; then
			if cmp -s "$OUT/$name.0" "$OUT/${name}_sw.0"; then
				echo "  switch check: IDENTICAL -> the second grab is stale, not a new frame"
			else
				echo "  switch check: DIFFER -> both grabs are real frames from one bring-up"
			fi
		fi
	fi
done

echo
echo "=== movement check: two live captures in the same configuration ==="
if [ -s "$OUT/live.0" ] && [ -s "$OUT/live2.0" ]; then
	if cmp -s "$OUT/live.0" "$OUT/live2.0"; then
		echo "  IDENTICAL -> frames are NOT updating"
	else
		python3 "$HERE/frame-movement.py" "$OUT/live.0" "$OUT/live2.0"
	fi
else
	echo "  one of the live captures is missing"
fi

echo
echo "=== switch check: does the image follow the sensor setting? ==="
if [ -s "$OUT/testpattern.0" ] && [ -s "$OUT/live.0" ]; then
	if cmp -s "$OUT/testpattern.0" "$OUT/live.0"; then
		echo "  IDENTICAL -> the switch did NOT take effect in the output"
	else
		echo "  DIFFER -> pattern and live produce different frames"
	fi
fi

echo
echo "=== PNGs in $OUT ==="
ls -l "$OUT"/*.png 2>/dev/null
echo
echo ">>> Colour bars in the test pattern prove sensor, CSI-2, VIF, ISP and CVISP end to end."
echo ">>> The live frame then shows what the optics see. Judge by the image, not by the mean."
