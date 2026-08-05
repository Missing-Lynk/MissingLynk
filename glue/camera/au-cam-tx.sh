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

# One access unit goes in one UDP datagram, so the per-frame ceiling is a hard protocol limit and
# VBV is the lever that sets it: a window in milliseconds permits vbv_ms * bitrate / 8000 bytes.
# Derived from BITRATE rather than fixed, because a value that is safe at one bitrate is not at
# another. 3/4 of the exact ceiling leaves room for the header overhead the window does not model.
UDP_PAYLOAD_MAX=65507
VPH_HEADER=36
VPH_TAIL=4
AU_LIMIT=$(( UDP_PAYLOAD_MAX - VPH_HEADER - VPH_TAIL ))
VBV_MAX=$(( AU_LIMIT * 8000 * 3 / 4 / BITRATE ))
[ "$VBV_MAX" -lt 10 ] && VBV_MAX=10
[ "$VBV_MAX" -gt 3000 ] && VBV_MAX=3000
VBV="${VBV:-$VBV_MAX}"

BIN="$REPO/userspace/gstreamer/build/static/ml-air-video"
DBG=/sys/kernel/debug/ar-cvisp

[ -x "$BIN" ] || { echo "missing $BIN (run userspace/gstreamer/scripts/build-static.sh)" >&2; exit 1; }

[ "$SAMPLE" -ge 1 ] || { echo "SAMPLE must be at least 1 (every rate below divides by it)" >&2; exit 1; }
[ "$SECS" -gt "$SAMPLE" ] || { echo "SECS must exceed SAMPLE, or the run ends mid-window" >&2; exit 1; }

echo "=== preconditions ==="

if ! sshg 'lsmod | grep -q "^ar_cvisp "' </dev/null
then
	echo "ar_cvisp is not loaded: run CVDEPTH=3 glue/camera/au-v4l2-chain.sh first" >&2
	exit 1
fi

DEPTH=$(sshg 'cat /sys/module/ar_cvisp/parameters/depth' </dev/null | tr -d '\r\n')
if [ "${DEPTH:-0}" -lt 3 ]
then
	echo "cvisp depth is ${DEPTH:-unknown}, this needs 3: run CVDEPTH=3 glue/camera/au-v4l2-chain.sh" >&2
	exit 1
fi

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

# A live instance means this boot's usable encoder pair is already spent. pgrep/pkill -f match
# their own command line on this busybox, so ask killall what it would find instead.
if sshg "killall -0 ml-air-video 2>/dev/null" </dev/null
then
	echo >&2
	echo "ml-air-video is already running on the air unit." >&2
	echo "  Its encoder instance pair is this boot's only usable one, so starting a second" >&2
	echo "  encodes garbage or watchdogs the firmware. Reboot and re-run." >&2
	exit 1
fi

# The node index depends on probe order, so it is read rather than assumed. v4l2-ctl is not on
# the slim rootfs; the driver's own vdev name is in sysfs and is what identifies the node.
# shellcheck disable=SC2016  # runs on the device, must not expand here
NODE="${NODE:-$(sshg 'for p in /sys/class/video4linux/video*
do
	[ "$(cat "$p/name" 2>/dev/null)" = ar-cvisp ] || continue
	echo "/dev/${p##*/}"
	break
done' </dev/null | tr -d '\r\n')}"

if [ -z "$NODE" ]
then
	echo "could not find the ar-cvisp video node; set NODE=/dev/videoN" >&2
	exit 1
fi

echo "  node $NODE, cvisp depth $DEPTH"
sshg "grep MemTotal /proc/meminfo; cat /sys/kernel/debug/dma_coherent/* 2>/dev/null | grep -E 'base|pages|free'" </dev/null

# wave5 cannot be hot-swapped: probing loads firmware into the VPU, and a second probe without a
# hardware reset returns -16 and leaves the codec unbound for the rest of the boot. The module
# must already be in the booted rootfs, so this only verifies and refuses to produce a number
# against the wrong binary.
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
		echo "module and wave5 cannot be reloaded warm."
		exit 2
	fi
fi

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
ENV_ARGS="$ENV_ARGS ML_AIR_ENC=\"v4l2h265enc output-io-mode=dmabuf-import"
ENV_ARGS="$ENV_ARGS extra-controls=\\\"controls,video_gop_size=$GOP,frame_level_rate_control_enable=1"
ENV_ARGS="$ENV_ARGS,video_bitrate=$BITRATE,video_bitrate_mode=1"
ENV_ARGS="$ENV_ARGS,hevc_minimum_qp_value=$MINQP,hevc_maximum_qp_value=$MAXQP"
ENV_ARGS="$ENV_ARGS,hevc_i_frame_qp_value=$IQP"
ENV_ARGS="$ENV_ARGS,h264_mb_level_rate_control=$MBRC"
ENV_ARGS="$ENV_ARGS,vbv_buffer_size=$VBV\\\"\""

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

# A dropped ssh returns an empty sample, and shell arithmetic reads empty as 0, which would
# present the whole lifetime counter as one window's traffic. Every sample is checked.
require_num() {
	case "$2" in
	'' | *[!0-9]*)
		echo "$1 came back as '$2': the counter read failed" >&2
		exit 1
		;;
	esac
}

cvisp_sample() {
	CV=$(sshg "cat $DBG/completions; cat $DBG/drops" </dev/null | tr -d '\r')
	CV_DONE=$(echo "$CV" | sed -n 1p)
	CV_DROP=$(echo "$CV" | sed -n 2p)
	require_num "cvisp completions" "$CV_DONE"
	require_num "cvisp drops" "$CV_DROP"
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

echo
echo "=== encoder health ==="
sshg "dmesg | grep -iE 'watchdog|syserr|enc instance|PIC_RUN|vdi pool|cvisp' | tail -15" </dev/null

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
