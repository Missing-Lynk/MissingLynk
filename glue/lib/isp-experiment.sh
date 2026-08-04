#!/usr/bin/env bash
# isp-experiment.sh - stage the optional ISP experiment artifacts for a camera bring-up.
#
# Sourced, not run:
#   . "$(dirname "$0")/../lib/isp-experiment.sh"
#   stage_isp_experiments "$HERE" "$OUT"
#
# Every knob here is unset in an ordinary run, and every branch that stages something has an
# else that removes the device-side file. That is load bearing: the device script switches on
# the artifacts being present, so a leftover from an earlier run would silently join the next
# one. Clearing here is what keeps a plain bring-up plain.
#
# Sets SWEEP_NAMES in the caller, the ordered step names its capture loop pulls and renders.
#
# The device-side half of these experiments is still inside the prove.sh heredoc in
# glue/camera/au-prove-camera.sh, which remains the single entry point. Separating that half
# means converting the 18 host variables it interpolates at push time into passed environment,
# which rewrites the text that runs on hardware and needs a bring-up to validate. See
# plans/merge-cleanup.md section 2.

# stage_isp_experiments <camera script dir> <host output dir>
stage_isp_experiments() {
	local HERE="$1"
	local OUT="$2"

	# BLOCK3D writes the ISP 0x3d60-0x3e1c curve bank mid-stream and captures again, so one
	# bring-up yields a before and an after of the same scene.
	#
	# That bank is three 64-entry LUT curves whose bytes saturate at 0x40, unity in Q6. We leave
	# 0x3d80 upward at zero because `configure_upto` stops at setup entry 1475 and the table's own
	# copy of the bank starts at 1884. Raising the cutoff instead is NOT equivalent and is not safe:
	# the full table carries a different curve (only 32 of its 44 writes here match the vendor), and
	# it is separately recorded as breaking the geometry stage at 2082.
	#
	#   BLOCK3D=vendor   the vendor's live values over BLOCK3D_RANGE (default the curve bank)
	#   BLOCK3D=table    what raising the cutoff to 2082 would write, for comparison
	#   BLOCK3D=diff     EVERY differing ISP register, minus the unsafe ones. This is the decisive
	#                    run: if the picture still does not improve with our ISP matching the
	#                    vendor everywhere, the cause is not in the register file at all.
	#   BLOCK3D_RANGE=LO-HI   restrict vendor/table to a range, e.g. 0x2e00-0x2eff
	#
	# Values are derived here from the captured snapshots rather than hardcoded, so the file cannot
	# drift away from the dumps it was measured against.
	rm -f "$OUT/block3d.txt"
	if [ -n "${BLOCK3D:-}" ]
	then
		python3 "$HERE/gen-block3d.py" "${BLOCK3D}" ${BLOCK3D_RANGE:+"$BLOCK3D_RANGE"} > "$OUT/block3d.txt" || exit 1
		device_push "$OUT/block3d.txt" || exit 1
		echo "  staged BLOCK3D=$BLOCK3D: $(wc -l < "$OUT/block3d.txt") register writes"
	else
		sshg 'rm -f /tmp/block3d.txt' </dev/null 2>/dev/null || true
	fi

	# GAMMA=<file> injects a captured vendor gamma table into the ISP's gamma buffer before the
	# ISP is armed, so the fetch pulse picks it up. The device script switches on the file being
	# present, which avoids quoting a flag through the heredoc. Absent GAMMA, the stale file is
	# removed so a previous run's injection cannot silently persist into this one.
	if [ -n "${GAMMA:-}" ]
	then
		[ -s "$GAMMA" ] || { echo "GAMMA=$GAMMA is missing or empty"; exit 1; }
		device_push_as "$GAMMA" "/tmp/gamma.bin" || exit 1
		echo "  gamma injection armed from $GAMMA"
	else
		sshg 'rm -f /tmp/gamma.bin'
	fi

	# SWEEP="<file> <file> ...": inside the single good bring-up, load each gamma table in turn and
	# capture a frame for each. This is the only way to compare more than one curve per boot, since
	# only the first bring-up after a RAM-boot writes to DRAM. Files are numbered so the device-side
	# glob keeps the order given here.
	sshg 'rm -f /tmp/sw_*.bin'
	SWEEP_NAMES=""
	if [ -n "${SWEEP:-}" ]
	then
		i=0
		for f in $SWEEP
		do
			[ -s "$f" ] || { echo "SWEEP entry $f is missing or empty"; exit 1; }
			i=$((i + 1))
			tag="$(printf '%02d_%s' "$i" "$(basename "$f" .bin)")"
			device_push_as "$f" "/tmp/sw_$tag.bin" || exit 1
			SWEEP_NAMES="$SWEEP_NAMES sw_$tag"
			echo "  sweep $i armed: $f"
		done
	fi

	# REARM=<file>: after the sweep, load this table and re-run the full ISP replay rather than
	# pulsing the fetch bits. Runs last, so it cannot cost an earlier capture.
	sshg 'rm -f /tmp/rearm.bin'
	if [ -n "${REARM:-}" ]
	then
		[ -s "$REARM" ] || { echo "REARM=$REARM is missing or empty"; exit 1; }
		device_push_as "$REARM" "/tmp/rearm.bin" || exit 1
		SWEEP_NAMES="$SWEEP_NAMES rearm"
		echo "  re-arm step armed: $REARM"
	fi

	# LSCPOKE=1: zero the LSC DMA page mid-stream and re-arm its valid bit, to decide whether the
	# block is actually fetching. Registered here so the capture is pulled and rendered like any
	# other sweep step.
	if [ "${LSCPOKE:-0}" = 1 ]
	then
		SWEEP_NAMES="$SWEEP_NAMES lsc"
		echo "  LSC fetch probe armed"
	fi

	# HDRPOKE=1: zero GTM2's 512-byte payload and re-arm, to decide whether its content matters
	# at all. It is the only table in the tone path with no static source anywhere.
	if [ "${HDRPOKE:-0}" = 1 ]
	then
		SWEEP_NAMES="$SWEEP_NAMES gtm2"
		echo "  GTM2 payload probe armed"
	fi
}
