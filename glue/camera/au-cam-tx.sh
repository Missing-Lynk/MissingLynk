#!/usr/bin/env bash
# au-cam-tx.sh - the camera feeding the two wave5 encoders with no copy, measured at the source.
#
# Runs ml-air-video with ML_AIR_CAMERA set, which drives the CVISP capture node directly and hands
# each frame to both encoders as gst_memory_share() views at the tile's row offset. Nothing copies
# pixel data, so the ceiling is the encoders and the link rather than one A53 moving 6 MB a frame.
#
# The number this exists to produce is the pair (completions, drops) from the CVISP node, sampled
# twice SAMPLE seconds apart while the run is live. A pass is completions at the sensor rate with
# drops at zero. Those are driver-side counters, so they are immune to anything ml-air-video might
# be miscounting about itself, which is why they and not the process's own log decide the result.
#
# Preconditions this refuses without, because each costs a battery to discover:
#   the ISP tuning blob is up   run glue/camera/au-v4l2-chain.sh (CVDEPTH=3) first; the modules
#                               auto-load at boot, so lsmod passing does NOT mean the chain is
#                               configured, and an unconfigured ISP produces garbage that encodes
#                               and decodes cleanly with every counter reading healthy
#   ar_cvisp depth is 3         at depth 1 the block re-arms a buffer under the encoder's read
#   the pool holds 8 buffers    needs the resized cvisp-cma; at 17 MiB REQBUFS caps at 5 and the
#                               consumer starves the rotation instead of pipelining with it
#   wave5.ko matches the build  the module cannot be reloaded warm, so a mismatch means a reboot
#
# ONE ENCODER INSTANCE PAIR PER BOOT. Instances after the first pair watchdog or encode garbage,
# so this refuses if ml-air-video is already running rather than silently spending the pair.
#
# TWO INSTANCES ARE CURRENTLY BROKEN on the camera source. The second encoder opened wedges with
# WAVE5_SYSERR_WATCHDOG_TIMEOUT on its first picture, reproducibly and identically whether the
# encoder configuration is vendor parity or the one validated at 60 fps on synthetic content, so
# the QP floor and the HVS constants are both exonerated. The same tile encodes 1187 frames at a
# sustained 60 fps as the only instance, so the geometry is fine too. Use ML_AIR_ONLY=0 or =1 to
# stay single-instance until that is resolved. See plans/air-video-frame-rate-and-latency.md.
#
# TX=1 sends to the goggle on 10.0.0.1:10001 and leaves the process running so the panel keeps
# showing the picture. Without it the run is encode-only and ends after SECS.
#
# Usage: glue/camera/au-cam-tx.sh
# Env: NODE (auto-detected ar-cvisp node), FPS (60), SECS (25), SAMPLE (5), TX (unset), ONLY, COPY,
#      BUFS (8), INFLIGHT (3), BITRATE (5000000 per tile), GOP (0), MINQP (0), MAXQP (51),
#      IQP (30), MBRC (1), VBV (derived), DUMP.
#      Target: the active device profile.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/../lib/au-camera.sh"

FPS="${FPS:-60}"
SECS="${SECS:-25}"
SAMPLE="${SAMPLE:-5}"
BUFS="${BUFS:-8}"
INFLIGHT="${INFLIGHT:-3}"
BITRATE="${BITRATE:-5000000}"
GOP="${GOP:-0}"
MBRC="${MBRC:-1}"
MINQP="${MINQP:-0}"
MAXQP="${MAXQP:-51}"
IQP="${IQP:-30}"

# Sets AU_LIMIT and VBV: one access unit goes in one UDP datagram, and VBV is the lever that
# holds a frame under that ceiling.
au_derive_vbv "$BITRATE"

BIN="$REPO/userspace/gstreamer/build/static/ml-air-video"
DBG=/sys/kernel/debug/ar-cvisp

[ -x "$BIN" ] || { echo "missing $BIN (run userspace/gstreamer/scripts/build-static.sh)" >&2; exit 1; }

[ "$SAMPLE" -ge 1 ] || { echo "SAMPLE must be at least 1 (every rate below divides by it)" >&2; exit 1; }
[ "$SECS" -gt "$SAMPLE" ] || { echo "SECS must exceed SAMPLE, or the run ends mid-window" >&2; exit 1; }

echo "=== preconditions ==="

au_require_cvisp 3

# The modules being loaded proves nothing: the rootfs auto-loads them at boot, so `lsmod` passes on
# a unit whose chain was never brought up. What au-v4l2-chain.sh actually adds is the vendor tuning
# blob, which ar-isp turns into its gamma and DRC pages. Without it the ISP runs unconfigured and
# every frame is horizontal-streak garbage that still encodes and decodes perfectly, so nothing
# downstream reports a fault and the run looks like a codec bug. Measured that way once already.
FWPATH=$(sshg 'cat /sys/module/firmware_class/parameters/path 2>/dev/null' </dev/null | tr -d '\r\n')
if ! sshg "[ -f ${FWPATH:-/lib/firmware}/artosyn/nt99235-tuning-preview-fpv.bin ]" </dev/null
then
	echo >&2
	echo "the ISP tuning blob is not where the driver looks for it" >&2
	echo "  firmware_class.path is '${FWPATH:-unset}' and artosyn/nt99235-tuning-preview-fpv.bin" >&2
	echo "  is not under it, so ar-isp is running unconfigured and the picture will be garbage" >&2
	echo "  no matter what the counters say." >&2
	echo >&2
	echo "  Run: CVDEPTH=3 glue/camera/au-v4l2-chain.sh" >&2
	exit 1
fi

# A live instance means this boot's usable encoder pair is already spent.
au_refuse_air_video_running

NODE="${NODE:-$(au_find_cvisp_node)}"

if [ -z "$NODE" ]
then
	echo "could not find the ar-cvisp video node; set NODE=/dev/videoN" >&2
	exit 1
fi

echo "  node $NODE, cvisp depth $AU_CVISP_DEPTH"
sshg "grep MemTotal /proc/meminfo; cat /sys/kernel/debug/dma_coherent/* 2>/dev/null | grep -E 'base|pages|free'" </dev/null

au_ensure_wave5

echo
echo "=== staging ==="
device_push "$BIN" || exit 1
sshg "chmod +x /tmp/ml-air-video"

ENV_ARGS="ML_AIR_CAMERA=$NODE ML_AIR_FPS=$FPS ML_AIR_BUFS=$BUFS ML_AIR_INFLIGHT=$INFLIGHT"
ENV_ARGS="$ENV_ARGS ML_AIR_VERBOSE=1"
# EXTRA_ENV goes to the remote process verbatim, for one-off diagnostics that do not
# deserve a flag of their own (GST_DEBUG above all). /tmp is tmpfs on a 118 MiB box, so a
# high GST_DEBUG level wants a short SECS or the log fills the filesystem the dump uses.
ENV_ARGS="$ENV_ARGS ${EXTRA_ENV:-}"
# The camera path drives the encoders through V4L2 directly, because gstv4l2 takes the source
# bytesperline from the caps and so describes the 2048-pitch capture buffer as 1920. That path
# cannot read the gst element string below, so the same knobs go over as plain env.
ENV_ARGS="$ENV_ARGS ML_AIR_BITRATE=$BITRATE ML_AIR_GOP=$GOP ML_AIR_MINQP=$MINQP"
ENV_ARGS="$ENV_ARGS ML_AIR_MAXQP=$MAXQP ML_AIR_IQP=$IQP ML_AIR_MBRC=$MBRC"

if [ -n "${ONLY:-}" ]
then
	ENV_ARGS="$ENV_ARGS ML_AIR_ONLY=$ONLY"
fi

# COPY=0|1 feeds that tile by copying out of the capture buffer instead of sharing it, so the two
# encoder instances stop reading overlapping ranges of one allocation. The isolation test for the
# second-instance watchdog, and the fallback if the firmware cannot take aliased source windows.
if [ -n "${COPY:-}" ]
then
	ENV_ARGS="$ENV_ARGS ML_AIR_COPY=$COPY"
fi
au_enc_controls_env

DUMPDIR="${DUMPDIR:-/dev/shm}"
if [ -n "${DUMP:-}" ]
then
	ENV_ARGS="$ENV_ARGS ML_AIR_DUMP=$DUMPDIR/cam"
fi

if [ -z "${TX:-}" ]
then
	ENV_ARGS="$ENV_ARGS ML_AIR_NOTX=1"
else
	echo
	echo "=== RF pre-flight ==="
	au_require_rf_link
fi

echo
echo "=== $FPS fps, ${BITRATE} bit/s/tile, $BUFS capture buffers, $INFLIGHT in flight ==="
echo "=== vbv $VBV ms permits $(( VBV * BITRATE / 8000 )) B/AU, datagram limit $AU_LIMIT B ==="
echo "=== qp $MINQP..$MAXQP, i-frame qp $IQP, mbrc $MBRC, gop $GOP ==="

sshg "cd /tmp && setsid env $ENV_ARGS ./ml-air-video >/tmp/cam-tx.log 2>&1 </dev/null &
	sleep 6
	echo launched" </dev/null

cvisp_sample() {
	CV=$(sshg "cat $DBG/completions; cat $DBG/drops" </dev/null | tr -d '\r')
	CV_DONE=$(echo "$CV" | sed -n 1p)
	CV_DROP=$(echo "$CV" | sed -n 2p)
	au_require_num "cvisp completions" "$CV_DONE"
	au_require_num "cvisp drops" "$CV_DROP"
}

echo
echo "=== cvisp counters over $SAMPLE s ==="
cvisp_sample
D0="$CV_DONE"
X0="$CV_DROP"
sleep "$SAMPLE"
cvisp_sample

printf 'completions %s/s\n' "$(( (CV_DONE - D0) / SAMPLE ))"
printf 'drops       %s/s\n' "$(( (CV_DROP - X0) / SAMPLE ))"
printf 'sum         %s/s  (the sensor rate; completions should be all of it)\n' \
	"$(( (CV_DONE - D0 + CV_DROP - X0) / SAMPLE ))"

echo
echo "=== letting it run the rest of $SECS s ==="
sleep "$(( SECS - SAMPLE ))"

echo
echo "=== cam-tx.log ==="
sshg "tail -20 /tmp/cam-tx.log" </dev/null

au_encoder_health

if [ -n "${DUMP:-}" ]
then
	echo
	echo "=== dumps ==="
	mkdir -p "$REPO/out/au-cam-tx"
	sshg "ls -la $DUMPDIR/cam_tile*.h265" </dev/null

	# Deleted only after a pull that worked. A run that produced nothing usable is exactly the
	# run whose bitstream is worth keeping, and the device side survives until the next boot.
	pulled=1
	for f in 0 1
	do
		if ! device_pull "$DUMPDIR/cam_tile$f.h265" "$REPO/out/au-cam-tx/cam_tile$f.h265"
		then
			echo "  tile $f did not come back; leaving $DUMPDIR/cam_tile$f.h265 on the device" >&2
			pulled=0
		fi
	done

	if [ "$pulled" = 1 ]
	then
		sshg "rm -f $DUMPDIR/cam_tile*.h265" </dev/null
	fi

	ls -la "$REPO/out/au-cam-tx/"
fi

if [ -z "${TX:-}" ]
then
	sshg "killall ml-air-video 2>/dev/null; sleep 1; echo stopped" </dev/null
else
	echo
	echo "ml-air-video is still running on the air unit. Stop it with: killall ml-air-video"
fi
