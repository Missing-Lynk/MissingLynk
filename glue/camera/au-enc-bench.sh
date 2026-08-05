#!/usr/bin/env bash
# au-enc-bench.sh - encoder and RF throughput ceiling, with no camera in the picture.
#
# Runs ml-air-video's benchmark mode: a ring of frames rendered once into dma-heap buffers at
# startup, then resubmitted to the two wave5 encoder instances with no source pipeline, no copy
# and no per-frame CPU work at all. That isolates the encode and transmit path from the capture
# path, so the ceiling can be measured before cvisp-cma is resized for the zero-copy work.
#
# Needs nothing loaded but wave5. No camera modules, no chain bring-up, no debugfs.
#
# The three tiers run back to back inside ONE process, on one encoder instance pair, because
# instances after the first pair in a boot watchdog or encode garbage. They differ only in ring
# content, which is rewritten in place between tiers:
#   static  identical frames; every block codes as skip. Bounds the plumbing, nothing else.
#   bars    scrolled colour bars plus a per-frame dither. The deciding number.
#   detail  low-passed noise texture, per-band opposing motion. Worst-case RATE.
#   noise   full entropy. Worst-case SURVIVAL: pass is that the encoder keeps producing frames
#           at all. Currently FAILS (VLC_BUF_FULL wedges the instance permanently).
#
# None of those four is watchable, and that is inherent. The ring holds pool_n fixed images and
# the feeder takes whichever buffer came back first, so the phase hops instead of advancing and
# the two tiles land on unrelated phases, leaving a mismatched seam. By eye it reads as
# corruption. Judge them by the counters.
#
#   scroll  the tier to LOOK at. Renders every frame with the phase from the shared frame
#           counter, so motion is continuous and both tiles agree at the seam. A full CPU pass
#           per frame per tile, so it caps near 17 fps and measures nothing.
#
# ONE ROW PER BATTERY. Bitrate and frame rate are baked into the encoder at instance open: the
# wave5 firmware has an OPT_CHANGE_PARAM opcode but the driver never issues it, so neither can be
# swept inside a run. Combined with one usable instance pair per boot, a boot yields exactly one
# (bitrate, fps, mode) point. Content tiers are free, because they are only buffer contents.
# Record every result in userspace/docs/air-video-benchmark.md; re-running to fill a gap is
# expensive.
#
# MODE=sustain paces at FPS and answers "does it hold". MODE=max resubmits as fast as buffers
# return and answers "how far does it go"; in max mode FPS is still what the encoder is told the
# rate is, which biases its rate-control model but not the throughput being measured.
#
# TX=1 transmits to the goggle on 10.0.0.1:10001 instead of encoding into the void, and adds a
# `tx N/s` column. It needs the goggle up, associated and displaying. Mind the link budget: the
# RF downlink carries about 8 Mbit/s total, so at 60 fps only static (0.02) and detail (about
# 3.9 per tile, 7.8 total) fit. bars is 12.6 total and noise 74, both of which measure what the
# link discards rather than what the path carries.
#
# Usage: glue/camera/au-enc-bench.sh
# Env: MODE (sustain), TIERS (static,bars,noise), SECS (10), FPS (60), RING (8), TX (unset),
#      BITRATE (5000000 per tile), GOP (0), MINQP (0), MAXQP (51), IQP (30), MBRC (1),
#      VBV (derived),
#      ONLY, DUMP.
#      Target: the active device profile.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/au-camera.sh"

# noise runs LAST and stays in the default set. It is not a rate measurement: it is the
# regression test for the VLC_BUF_FULL wedge, and its pass criterion is that the encoder keeps
# producing frames, not that it produces them quickly. Dropping it because it fails would be
# removing the only reliable reproducer of an open defect. Last, because a wedge ends the run and
# would take the other tiers' data with it.
TIERS="${TIERS:-static,bars,detail,noise}"
SECS="${SECS:-10}"
FPS="${FPS:-60}"
RING="${RING:-8}"
# Per-tile CBR at the vendor's own configured rate.
#
# AR_LOWDELAY_RtspVencInit opens the channel as H.265 CBR at 5000 kbit/s with gop=0. That is a
# blob-measured value, and it agrees with the wire: the vendor capture averages 11154 B per access
# unit, which at 60 fps is 5.35 Mbit/s.
#
# It supersedes the earlier 4 Mbit/s figure, which was inferred indirectly from
# AR_8030_TX_GetBitRate returning its 8000 kbit/s default across two tiles when RF throughput
# reads zero. That describes the link budget, not what the encoder is told. ArMaxBitRate caps at
# 10 Mbit/s per tile. The recorder's 10 Mbit/s is a different system and not a reference here.
BITRATE="${BITRATE:-5000000}"
# Vendor parity: u32Gop=0, one IDR at stream start and P-frames thereafter. The driver's control
# range is 0 to 2047, so the 65535 this used to pass could never be accepted; the driver default
# of 0 applied instead, which happened to be right for the wrong reason.
GOP="${GOP:-0}"
# CU-level rate control. Off by default in the driver, and one control enables mb_level_rc,
# cu_level_rc and hvs_qp together: per-CTU QP adaptation inside a frame. This is what holds a
# frame to its byte budget when part of it is hard.
#
# Vendor parity, established: AR_MPI_VENC_GetRcParam returns s32CuOrMbLevelRcEnable = 1 and
# s32HvsQPEnable = 1 as the H.265 CBR defaults, and ar_lowdelay overwrites neither. The aggregate
# control is coarser than the vendor's three fields, but every field it sets matches.
MBRC="${MBRC:-1}"
# Per-frame size levers, because one access unit must fit one UDP datagram. Over the limit,
# vph_build refuses and ml-air-video discards the frame (counted as `oversize`).
#
# VBV is the lever that actually sets the ceiling. The driver's 1000 ms default at 1 Mbit/s
# allows 125000 B, which is exactly the 125985 and 127413 maxima measured on hardware. Sets
# AU_LIMIT and VBV.
au_derive_vbv "$BITRATE"
# QP clamps. The vendor's are u32MinIQp/u32MinPQp/u32MinBQp = 0 and u32MaxIQp/u32MaxPQp/u32MaxBQp
# = 51, all eight offsets read out of the SetRcParam call. Mainline expresses them only as the
# aggregate HEVC_MIN_QP/HEVC_MAX_QP pair, which works here because the vendor uses the same value
# for I, P and B on each side. MAXQP already matches the driver default; MINQP does not, and the
# driver's 8 is what let rate control pin flat content at the floor and overshoot the target 1.6x
# on `bars`.
#
# Raising MINQP shapes the stream better than the vendor does, so it is not the default: this is a
# parity harness, and a deviation that measures well is still a deviation. plans/beyond-vendor-
# backlog.md holds the case for a floor above 0.
#
# IQP defaults to the driver's own 30 and is a knob, not a setting. It maps to wave_param.intra_qp,
# which CBR overrides with initial_rc_qp = -1; the vendor's s32FirstFrameStartQp is -1 too.
MINQP="${MINQP:-0}"
MAXQP="${MAXQP:-51}"
IQP="${IQP:-30}"
BIN="$REPO/userspace/gstreamer/build/static/ml-air-video"

[ -x "$BIN" ] || { echo "missing $BIN (run userspace/gstreamer/scripts/build-static.sh)" >&2; exit 1; }

echo "=== staging ==="
sshg "rm -f /tmp/ml-air-video; lsmod | grep -q '^wave5' || echo 'WARNING: wave5 not loaded'"
device_push "$BIN" || exit 1
sshg "chmod +x /tmp/ml-air-video"

au_ensure_wave5

sshg "grep -q 'vdec' /proc/modules 2>/dev/null; ls /dev/video* 2>&1 | head -3"

ENV_ARGS="ML_AIR_BENCH=$TIERS ML_AIR_BENCH_SECS=$SECS ML_AIR_RING=$RING ML_AIR_FPS=$FPS"
au_enc_controls_env

MODE="${MODE:-sustain}"

case "$MODE" in
sustain)
	;;
max)
	ENV_ARGS="$ENV_ARGS ML_AIR_BENCH_FREE=1"
	;;
*)
	echo "MODE must be sustain or max, got '$MODE'" >&2
	exit 1
	;;
esac

# ONLY=0|1 runs a single tile as the only encoder instance, which separates a per-tile defect
# from a two-instance interaction. DUMP writes the elementary streams for decoding, under DUMPDIR
# which defaults to /dev/shm because it is 63 MB against /tmp's 32. Size the run: a filled tmpfs
# stalls the pipeline and confounds the very throughput being measured. Budget for rate control
# NOT taking, which is the case that overruns.
DUMPDIR="${DUMPDIR:-/dev/shm}"

if [ -n "${ONLY:-}" ]; then
	ENV_ARGS="$ENV_ARGS ML_AIR_ONLY=$ONLY"
fi

if [ -n "${DUMP:-}" ]; then
	ENV_ARGS="$ENV_ARGS ML_AIR_DUMP=$DUMPDIR/bench"
fi

if [ -z "${TX:-}" ]; then
	ENV_ARGS="$ENV_ARGS ML_AIR_NOTX=1"
else
	echo "=== RF pre-flight ==="
	au_require_rf_link
fi

# Each tier costs SECS, plus bring-up and the inter-tier ring rewrite; the process ends itself
# when the last tier does, so the timeout is a backstop and not the normal exit.
NTIERS=$(echo "$TIERS" | tr ',' '\n' | wc -l)
LIMIT=$(( NTIERS * (SECS + 5) + 30 ))

echo "=== $MODE: $NTIERS tier(s), $SECS s each, $FPS fps declared, ${BITRATE} bit/s/tile, ring $RING ==="
echo "=== vbv $VBV ms permits $(( VBV * BITRATE / 8000 )) B/AU, datagram limit $AU_LIMIT B ==="
echo "=== qp $MINQP..$MAXQP, i-frame qp $IQP, mbrc $MBRC, gop $GOP ==="
sshg "cd /tmp && timeout $LIMIT env $ENV_ARGS ./ml-air-video >/tmp/bench.log 2>&1; echo \"exit \$?\"" </dev/null

echo
echo "=== bench.log ==="
sshg "cat /tmp/bench.log"

if [ -n "${DUMP:-}" ]; then
	echo
	echo "=== dumps ==="
	sshg "ls -la $DUMPDIR/bench_tile*.h265; df -h $DUMPDIR | tail -1"
	mkdir -p "$REPO/out/au-bench"
	for f in 0 1
	do
		device_pull "$DUMPDIR/bench_tile$f.h265" "$REPO/out/au-bench/bench_tile$f.h265" 2>/dev/null
	done
	sshg "rm -f $DUMPDIR/bench_tile*.h265"
fi

au_encoder_health
