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
# Usage: glue/camera/au-enc-bench.sh
# Env: MODE (sustain), TIERS (static,bars,noise), SECS (10), FPS (60), RING (8), TX (unset),
#      BITRATE (5000000 per tile), GOP (65535), ONLY, DUMP. Target: the active device profile.
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
# Per-tile CBR, defaulting to the vendor's own operating point.
#
# The vendor air unit does not take a configured bitrate: AR_8030_TX_GetBitRate derives it from
# live RF MCS as throughput * Ar803xThroutputRate * cfg, capped at ArMaxBitRate, and returns the
# 8000 kbit/s default when throughput reads zero (captured cfg_transmedium.json: ratio 0.7, cap
# 20000). HW-observed, the air encodes about 3926 kbit/s per tile, which is that 8000 default
# across two tiles. So 4 Mbit/s per tile is vendor parity and 10 Mbit/s per tile is the cap.
# The recorder's 10 Mbit/s is a different system and not a reference for this path.
BITRATE="${BITRATE:-4000000}"
GOP="${GOP:-65535}"
BIN="$REPO/userspace/gstreamer/build/static/ml-air-video"

[ -x "$BIN" ] || { echo "missing $BIN (run userspace/gstreamer/scripts/build-static.sh)" >&2; exit 1; }

echo "=== staging ==="
sshg "rm -f /tmp/ml-air-video; lsmod | grep -q '^wave5' || echo 'WARNING: wave5 not loaded'"
device_push "$BIN" || exit 1
sshg "chmod +x /tmp/ml-air-video"

# wave5 cannot be hot-swapped. It is not the first instance open that blocks a reload, it is the
# probe: probing loads firmware into the VPU, and a second probe without a hardware reset returns
# -16 from vpu_init_with_bitcode, leaving the codec unbound for the rest of the boot. Measured the
# hard way. The driver must therefore already be in the rootfs when the kernel boots, so this only
# verifies and refuses to produce a number against the wrong binary.
KO="$REPO/kernel/build/kernel-repro-6.18.36/ml-modules/rootfs/lib/modules/6.18.36/kernel/wave5.ko"
DEV_KO=/lib/modules/6.18.36/kernel/wave5.ko

if [ -f "$KO" ]
then
	WANT=$(md5sum "$KO" | cut -d' ' -f1)
	HAVE=$(sshg "md5sum $DEV_KO 2>/dev/null | cut -d' ' -f1" </dev/null | tr -d '\r\n')

	if [ "$WANT" != "$HAVE" ]
	then
		echo "$DEV_KO is not the build under test; installing it"
		echo "  device $HAVE"
		echo "  build  $WANT"
		device_push "$KO" || exit 1
		sshg "cp /tmp/wave5.ko $DEV_KO && sync && md5sum $DEV_KO"
		echo
		echo "installed into the rootfs. REBOOT and re-run: the running kernel still has the old"
		echo "module and wave5 cannot be reloaded warm (probe loads firmware; a second probe"
		echo "returns -16 and unbinds the codec for the rest of the boot)."
		exit 2
	fi
fi

sshg "grep -q 'vdec' /proc/modules 2>/dev/null; ls /dev/video* 2>&1 | head -3"

ENV_ARGS="ML_AIR_BENCH=$TIERS ML_AIR_BENCH_SECS=$SECS ML_AIR_RING=$RING ML_AIR_FPS=$FPS"
ENV_ARGS="$ENV_ARGS ML_AIR_ENC=\"v4l2h265enc output-io-mode=dmabuf-import"
ENV_ARGS="$ENV_ARGS extra-controls=\\\"controls,video_gop_size=$GOP,frame_level_rate_control_enable=1"
ENV_ARGS="$ENV_ARGS,video_bitrate=$BITRATE,video_bitrate_mode=1\\\"\""

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

if [ -n "${ONLY:-}" ]
then
	ENV_ARGS="$ENV_ARGS ML_AIR_ONLY=$ONLY"
fi

if [ -n "${DUMP:-}" ]
then
	ENV_ARGS="$ENV_ARGS ML_AIR_DUMP=$DUMPDIR/bench"
fi

if [ -z "${TX:-}" ]
then
	ENV_ARGS="$ENV_ARGS ML_AIR_NOTX=1"
fi

# Each tier costs SECS, plus bring-up and the inter-tier ring rewrite; the process ends itself
# when the last tier does, so the timeout is a backstop and not the normal exit.
NTIERS=$(echo "$TIERS" | tr ',' '\n' | wc -l)
LIMIT=$(( NTIERS * (SECS + 5) + 30 ))

echo "=== $MODE: $NTIERS tier(s), $SECS s each, $FPS fps declared, ${BITRATE} bit/s/tile, ring $RING ==="
sshg "cd /tmp && timeout $LIMIT env $ENV_ARGS ./ml-air-video >/tmp/bench.log 2>&1; echo \"exit \$?\"" </dev/null

echo
echo "=== bench.log ==="
sshg "cat /tmp/bench.log"

if [ -n "${DUMP:-}" ]
then
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

echo
echo "=== encoder health ==="
sshg "dmesg | grep -iE 'watchdog|syserr|enc instance|PIC_RUN|vdi pool' | tail -15"
