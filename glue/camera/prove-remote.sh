#!/bin/sh
# prove-remote.sh - the device half of au-prove-camera.sh, staged to /tmp/prove.sh and run there.
#
# Runs on the air unit under busybox ash, not on the host. au-prove-camera.sh pushes it and
# invokes it as `<env> /tmp/prove.sh <test_pattern> <name> <cycle>`.
#
# Every knob arrives as an environment variable, set by the host at invocation:
#   insmod arguments  USE_IRQ TABLES SEED GAMMA_CURVE DRC_PROFILE COMPANDER LSC STATS CCM
#                     CCM_BANK DE3D BULK BLC BLC_GAIN CVDEPTH EXPO GAIN
#   register windows  ISP_WINDOWS, a space-separated list read from isp-windows.list
#   stage selectors   WATCH ESWEEP SWEEP_COLOUR LSCPOKE HDRPOKE SWITCH_TP V4L2CAP V4L2MARK
#
# None of these have defaults here on purpose: an unset one means the host did not pass it, and
# an insmod argument silently becoming empty is worth a failure rather than a wrong capture.
# $1 = test pattern value (2 = colour bars, 0 = off, live scene)
R=/tmp/ml-regdump
TP=$1
NAME=$2
CYC=$3
WATCH=${WATCH:-1}
# Sweep captures are luma-only by default: /tmp is a 32 MB tmpfs and three planes cost 5.4 MB
# per step, so a long sweep silently truncates its last capture. One plane costs 2.2 MB.
ALL3='--plane 0x28014000 --plane 0x28232000 --plane 0x282bb000'
if [ -n "${SWEEP_COLOUR:-}" ]; then
	PLANES=$ALL3
else
	PLANES='--plane 0x28014000'
fi

fail() {
	echo "FAILED: $1"
	echo '--- kernel log ---'
	dmesg | grep -i -E 'nt99235|ar.isp|ar.vif|ar.csi2|cvisp' | tail -25
	# Leave nothing running and nothing loaded, so the next attempt starts clean.
	for p in /proc/[0-9]*; do
		c=$(cat "$p"/comm 2>/dev/null)
		case "$c" in
		ml-v4l2grab|ml-isploop) kill -9 "${p#/proc/}" 2>/dev/null ;;
		esac
	done
	exit 1
}

# Stage 1: start from nothing. Kill by /proc comm, because busybox pkill -x is unreliable and
# -f matches this script itself.
for p in /proc/[0-9]*; do
	c=$(cat "$p"/comm 2>/dev/null)
	case "$c" in
	ml-v4l2grab|ml-isploop) echo "  killing stale $c"; kill -9 "${p#/proc/}" 2>/dev/null ;;
	esac
done
sleep 1
for m in ar_cvisp ar_isp ar_vif ar_csi2 nt99235; do
	rmmod $m 2>/dev/null
done
for m in ar_cvisp ar_isp ar_vif ar_csi2 nt99235; do
	lsmod | grep -q "^$m " && fail "$m would not unload, something still holds it"
done
echo '  stage 1 ok: nothing loaded'

# Stage 1b: the camera CGU leaves. Nothing sets these on a fresh boot, and without them the ISP
# and VIF clocks are wrong: their registers read back zero, no frame ever starts, and the whole
# chain looks broken for a reason that has nothing to do with the sensor. The gate check first,
# because programming a leaf whose parent gate is closed is how the SoC gets hung.
G=$($R 0x0a104014 1 | cut -d' ' -f2)
case $G in
*[13579bdf]???) : ;;
*) fail "cgu 0x0a104014=$G, gate bit12 is CLEAR" ;;
esac
$R -w 0x0a10400c 0x13001300 >/dev/null || fail 'cgu 0x0a10400c'
$R -w 0x0a104010 0x02001300 >/dev/null || fail 'cgu 0x0a104010'
$R -w 0x0a104020 0x10001103 >/dev/null || fail 'cgu 0x0a104020'
$R -w 0x0a10401c 0x02011201 >/dev/null || fail 'cgu 0x0a10401c'
$R -w 0x0a104044 0x01001000 >/dev/null || fail 'cgu 0x0a104044'
echo '  stage 1b ok: camera clocks programmed'

# Read-only pre-flight. Our replay points the ISP at the VENDOR's physical addresses and then
# pulses 0x0014 to fetch them, but never fills them. DDR survives a RAM-boot, so if the vendor
# camera ran in slot A before we booted, its real tuning tables are still resident and the ISP
# inherits working ones. If it did not, the ISP fetches whatever is in those pages. This records
# which case we are in, so picture quality can be correlated with it instead of guessed at.
for spec in gamma:0x2b2ec600:4096 compander:0x2b2e0c00:7680 drc:0x2b2e9200:2048; do
	nm=$(echo $spec | cut -d: -f1)
	ad=$(echo $spec | cut -d: -f2)
	ct=$(echo $spec | cut -d: -f3)
	/tmp/ml-lutfill "$ad" "$ct" save:/tmp/pre_"$nm".bin >/dev/null 2>&1
done
echo '  stage 1c ok: tuning pages captured for residency check'

# Stage 1d: optional gamma injection. Measurement showed our stack already inherits the
# vendor's real compander (byte-identical) and DRC body across a RAM-boot, and that only
# gamma differs, because the vendor regenerates it from 3A. This overwrites gamma with a
# captured vendor curve so the tone chain runs on known-good data end to end.
#
# The write is plain DRAM through /dev/mem, no hardware access, and 0x2b2ec600 sits above the
# kernel's capped memory, so it cannot corrupt anything the kernel owns. It happens before
# insmod so nothing has fetched the table yet.
if [ -f /tmp/gamma.bin ]; then
	if /tmp/ml-lutfill 0x2b2ec600 4096 load:/tmp/gamma.bin >/dev/null 2>&1; then
		echo '  stage 1d ok: vendor gamma injected at 0x2b2ec600'
	else
		echo '  stage 1d FAILED: gamma not injected'
	fi
else
	echo '  stage 1d skipped: no /tmp/gamma.bin, running on resident gamma'
fi

# Stage 1e: the tuning file has to be on the firmware search path before ar-isp probes. The
# rootfs is not the place for it during a bring-up, so point the loader at tmpfs, which is where
# the push landed anyway. Moved rather than copied: /tmp is 32 MB.
if [ -f /tmp/nt99235-tuning-preview-fpv.bin ]; then
	mkdir -p /tmp/fw/artosyn
	mv /tmp/nt99235-tuning-preview-fpv.bin /tmp/fw/artosyn/
	# shellcheck disable=SC3037  # busybox ash, the only shell this runs under, implements echo -n
	if echo -n /tmp/fw > /sys/module/firmware_class/parameters/path 2>/dev/null; then
		echo '  stage 1e ok: tuning file on the firmware search path'
	else
		echo '  stage 1e FAILED: no firmware_class path parameter, ar-isp will seed instead'
	fi
else
	echo '  stage 1e skipped: no tuning file, ar-isp will seed instead of generate'
fi

# Stage 2: load, aborting on the first failure rather than continuing on stale state.
insmod /tmp/nt99235.ko exposure="$EXPO" gain="$GAIN" test_pattern="$TP" || fail 'insmod nt99235'
# ar-isp is spelled out rather than looped because it is the only one with run-time levers
# worth steering from here. The ORDER IS THE ORIGINAL ONE and matters: it is the order the
# media graph was proven to bind in.
insmod /tmp/ar-csi2.ko || fail 'insmod ar-csi2'
# Interrupt completion is the default and the vendor's own mode on both blocks;
# both handlers are validated at frame rate. USE_IRQ=0 falls back to polling for
# debugging, which also leaves the W1C status words observable between polls.
insmod /tmp/ar-vif.ko use_irq="$USE_IRQ" || fail 'insmod ar-vif'
insmod /tmp/ar-isp.ko tables="$TABLES" seed="$SEED" gamma_curve="$GAMMA_CURVE" drc_profile="$DRC_PROFILE" \
	compander="$COMPANDER" lsc="$LSC" stats="$STATS" ccm="$CCM" ccm_bank="$CCM_BANK" de3d="$DE3D" \
	setup_entries="$BULK" use_irq="$USE_IRQ" || fail 'insmod ar-isp'
insmod /tmp/ar-cvisp.ko blc="$BLC" blc_gain="$BLC_GAIN" depth="$CVDEPTH" || fail 'insmod ar-cvisp'
sleep 1
echo '  stage 2 ok: modules loaded'

# Stage 3: the graph must have bound. ar-vif has no video node of its own any more, so the node
# to find is the CVISP one, by name rather than by number: probe order decides which /dev/videoN
# it lands on. No node means the media graph did not bind and every later stage would be
# operating on a dead pipeline.
NODE=''
for d in /sys/class/video4linux/video*; do
	[ -r "$d/name" ] || continue
	if [ "$(cat "$d"/name)" = 'ar-cvisp' ]; then
		NODE=/dev/$(basename "$d")
		break
	fi
done
[ -n "$NODE" ] || fail 'no video node named ar-cvisp, the media graph did not bind'
echo "  stage 3 ok: capture node $NODE"

# Stage 4: bring the chain up, then hand the output queue back.
#
# STREAMON on the node starts the sensor, the VIF input path and the ISP, in that order, and
# waits for a frame event before touching the ISP. That replaces both the old grabber on
# /dev/video2 and the configure_upto plus arm that stage 5 used to write by hand.
#
# It streams briefly and stops. STREAMOFF puts the vendor's fixed ring back under the block
# while leaving the chain running, which is what the /dev/mem captures below need: they read the
# vendor's slot addresses, and those are only live when the node is not streaming.
/tmp/ml-v4l2grab -d "$NODE" -q -n 8 -t 15 >/tmp/g.out 2>&1
GP=''
if grep -q 'delivered [1-9]' /tmp/g.out; then
	echo "  stage 4: chain up, $(grep -o 'delivered .*' /tmp/g.out)"
else
	echo '--- bring-up output ---'
	cat /tmp/g.out
	fail 'the node delivered no frame, the chain did not come up'
fi
# Stage 4b: our own sensor registers, read while streaming. The sensor is powered down when the
# stream stops, so i2c reads fail outside this window; that is why this cannot be a post-run
# check. Comparing against the vendor's dump decides whether the 271 registers the vendor holds
# non-zero and our mode table never writes are vendor writes we are missing, or power-on
# defaults. Read-only: the -n form, since a bare fourth argument WRITES.
if [ -x /tmp/ml-i2cprobe ]; then
	: > /tmp/oursensor.txt
	for pg in 0x0000 0x0100 0x0200 0x0300 0x0400 0x0500 0x0600 0x0800 0x0c00 0x3000 0x3100 0x3200 0x3300 \
	          0x3500 0x3600 0x3a00 0x8000 0x8200 0x8300 0x8500 0x8700 0x9000; do
		/tmp/ml-i2cprobe 0 0x1a $pg -n 256 >> /tmp/oursensor.txt 2>/dev/null
	done
	echo "  stage 4b ok: $(grep -c '= 0x' /tmp/oursensor.txt) sensor registers read"
fi

dump_windows() {
	for spec in $ISP_WINDOWS; do
		blk=${spec%%:*}
		rest=${spec#*:}
		base=${rest%%:*}
		rest=${rest#*:}
		off=${rest%%:*}
		cnt=${rest##*:}
		echo "--- $blk +$off ($cnt words) ---"
		$R "$(printf '0x%x' $(( base + off )))" "$cnt"
	done
}

echo '  csi-2 core0 mid-stream:'
/tmp/ml-regdump 0x08880400 4

# Stage 5: only now is it safe to touch the ISP and VIF.
# The ISP and CVISP were configured by the node's STREAMON in stage 4; ar-isp applies
# setup_entries of the setup table, which is BULK, passed at insmod. Nothing to do here but let
# the pipeline settle before reading it.
sleep 1

# Whose buffers is the block actually reading? The replay arms the vendor's addresses and
# ar-isp republishes its own over them, so this is the one read that says which of the two
# won. Vendor pages are 0x2b2e____; ours come out of the isp_cma pool at 0x2a0_____.
echo '  coefficient descriptors (gamma x3, drc, compander):'
$R 0x08c00030 1
$R 0x08c00040 1
$R 0x08c00050 1
$R 0x08c00060 1
$R 0x08c00020 1

# ml-isploop drives the CVISP ring from its own table, so frames land in ITS slots, not at the
# plane the driver programmed. These three are slot 1: luma, then the two chroma planes. Passing
# only the luma address is why the first run came back greyscale, since --plane replaces the
# whole dump list rather than adding to it.
echo "  cvisp control (expect 0x00800806):"
$R 0x08e08000 1

# A quiet 3 s CPU sample while the whole pipeline streams and nothing else
# runs: the delta is the true streaming load (ISRs plus any driver work),
# since the frame path itself is hardware end to end. Fields: user nice
# system idle iowait irq softirq.
S0=$(head -1 /proc/stat)
sleep 3
S1=$(head -1 /proc/stat)
echo "  cpu streaming sample (3 s, 2 cpus, 100 Hz jiffies):"
echo "    t0: $S0"
echo "    t1: $S1"

if [ "$CYC" = cycle ]; then
	EXTRA=--isp-cycle
else
	EXTRA=
fi
/tmp/ml-isploop "$WATCH" --cvisp $EXTRA --dump /tmp/"$NAME" \
	--plane 0x28014000 --plane 0x28232000 --plane 0x282bb000 \
	>/tmp/il 2>&1 || { cat /tmp/il; fail 'capture'; }
grep -E 'cycles driven|markers overwritten' /tmp/il
echo "  stage 5 ok: captured $NAME"

# Stage 5b: switch the sensor's pattern generator and capture again, WITHOUT
# rebringing anything up.
#
# A warm re-bring-up never writes DRAM on this SoC (see the defect note in
# plans/done/au-b-pipeline-dead-20260802.md), which is what forced one capture per
# boot and made comparing a pattern against a live scene cost two boots. None of
# that is necessary: TEST_PATTERN_MODE is a plain 16-bit i2c register, 0x0600
# high and 0x0601 low, so it can be switched mid-stream. With the output ring
# rotating, the block keeps writing and the second grab gets genuinely fresh
# frames rather than a re-read of the first.
#
# SWITCH_TP is the value to switch TO: 0 live, 1 solid, 2 colour bars, 3 fade.
if [ -n "${SWITCH_TP:-}" ]; then
	/tmp/ml-i2cprobe 0 0x1a 0x0600 0 >/dev/null 2>&1
	/tmp/ml-i2cprobe 0 0x1a 0x0601 "$SWITCH_TP" >/dev/null 2>&1
	RB=$(/tmp/ml-i2cprobe 0 0x1a 0x0601 2>/dev/null)
	echo "  stage 5b: sensor pattern switched to $SWITCH_TP ($RB)"
	# Several frame periods, so the new content is fully through the ring
	# and no partially-written slot is sampled.
	sleep 2
	/tmp/ml-isploop "$WATCH" --cvisp $EXTRA --dump /tmp/"${NAME}"_sw \
		--plane 0x28014000 --plane 0x28232000 --plane 0x282bb000 \
		>/tmp/il_sw 2>&1 || { cat /tmp/il_sw; fail 'capture after switch'; }
	grep -E 'markers overwritten' /tmp/il_sw
	echo "  stage 5b ok: captured ${NAME}_sw after the switch"
fi

# Stage 5v: capture through the CVISP V4L2 node instead of /dev/mem.
#
# Everything above reads frames by mapping the vendor's five fixed ring addresses out of
# /dev/mem. This stage asks the block to write into videobuf2 buffers instead: STREAMON hands
# the output queue over, the per-frame tick walks the queued buffers rather than ar_cvisp_ring,
# and STREAMOFF puts the vendor ring back. So this runs AFTER the baseline capture on purpose,
# and the two are directly comparable: same bring-up, same scene, same ISP state, only the
# owner of the output queue differs.
#
# V4L2CAP is the number of frames to pull. The node is found by name rather than by number:
# ar-vif also registers one, and which of the two lands on which /dev/videoN depends on probe
# order.
#
# Note the node does NOT bring the chain up. The sensor, VIF and ISP are already streaming by
# the time this runs, which is the whole reason the old path stays intact in the same boot: if
# this stage fails, nothing before it has been disturbed.
if [ -n "${V4L2CAP:-}" ]; then
	NODE=''
	for d in /sys/class/video4linux/video*; do
		[ -r "$d/name" ] || continue
		if [ "$(cat "$d"/name)" = 'ar-cvisp' ]; then
			NODE=/dev/$(basename "$d")
			break
		fi
	done
	if [ -z "$NODE" ]; then
		echo '  stage 5v FAILED: no video node named ar-cvisp'
	else
		echo "  stage 5v: capture node $NODE"
		rm -f /tmp/"${NAME}"_v4l2.0 /tmp/"${NAME}"_v4l2.1 /tmp/"${NAME}"_v4l2.2
		# V4L2MARK=1 fills every buffer with a position-keyed pattern before queueing
		# it and reports what came back still holding it. That decides two things this
		# driver would otherwise be guessing: how many rows the block actually writes,
		# which is whether the vendor's per-slot plane extents are real geometry or
		# allocator padding, and whether a completed buffer is finished, which is
		# whether the hold depth is long enough. It costs more than a frame period per
		# frame, so it drops frames by design and its throughput numbers mean nothing.
		MARK=''
		[ -n "${V4L2MARK:-}" ] && MARK='-m'
		if /tmp/ml-v4l2grab -d "$NODE" $MARK -o /tmp/"${NAME}"_v4l2 -n "$V4L2CAP" -t 5 >/tmp/g4.out 2>&1; then
			grep -E 'interface|allocated|current|plane |frame |wrote|content|coverage|delivered' /tmp/g4.out | sed 's/^/    /'
			echo "  stage 5v ok: captured ${NAME}_v4l2 through the node"
		else
			echo '  stage 5v FAILED: grabber error'
			cat /tmp/g4.out
		fi

		# Rate pass. The capture above reads every byte of a frame twice, once to
		# histogram it and once to write it out, and these buffers are uncached: they
		# come from a no-map shared-dma-pool, so a CPU pass over a plane costs far more
		# than a frame period and the delivered rate measures the tool. -q cycles
		# buffers without touching their contents, which is what a consumer importing
		# the dmabuf into the encoder does, and separates the two.
		if /tmp/ml-v4l2grab -d "$NODE" -q -n 200 -t 5 >/tmp/g5.out 2>&1; then
			grep -E 'delivered' /tmp/g5.out | sed 's/^/    rate pass: /'
			for c in rotations completions drops; do
				[ -r /sys/kernel/debug/ar-cvisp/$c ] && \
					echo "    rate pass cvisp $c: $(cat /sys/kernel/debug/ar-cvisp/$c)"
			done
		else
			echo '  stage 5v: rate pass FAILED'
			cat /tmp/g5.out
		fi
		# rotations counts every tick that armed something, completions only the buffers
		# handed back, and drops the ticks that found nothing queued. completions well
		# below rotations means userspace is not requeueing fast enough, which is a
		# throughput problem and not a broken queue.
		for c in rotations completions drops; do
			[ -r /sys/kernel/debug/ar-cvisp/$c ] && \
				echo "    cvisp $c: $(cat /sys/kernel/debug/ar-cvisp/$c)"
		done
		# The driver's own account, which is where a missing capture pool shows
		# up: without cvisp_cma the buffers come from the default CMA instead,
		# which is ordinary kernel RAM and not where this DMA master should be
		# writing. That is a warning, not a probe failure, so it is only visible
		# here.
		dmesg | grep -i 'ar-cvisp\|cvisp:' | tail -6 | sed 's/^/    /'

		# Stage 5w: STREAMOFF has to put the vendor's ring back under the block, or
		# the tick is left pointing at buffers that have gone back to the allocator
		# and every capture path that is not the node reads a dead address. Nothing
		# in the run above exercises that, so it is checked here rather than assumed:
		# markers overwritten at the vendor's own slot means the ring is live again.
		/tmp/ml-isploop 1 --cvisp --dump /tmp/"${NAME}"_post \
			--plane 0x28014000 --plane 0x28232000 --plane 0x282bb000 \
			>/tmp/il_post 2>&1
		if grep -q 'markers overwritten' /tmp/il_post; then
			grep -E 'markers overwritten' /tmp/il_post | sed 's/^/    /'
			echo '  stage 5w: vendor ring re-armed after STREAMOFF'
		else
			echo '  stage 5w FAILED: no capture after STREAMOFF'
			cat /tmp/il_post
		fi
		rm -f /tmp/"${NAME}"_post.0 /tmp/"${NAME}"_post.1 /tmp/"${NAME}"_post.2
	fi
fi

# Stage 5c: our own ISP, CVISP, VIF, CSI-2 and CGU windows, read MID-STREAM and POST-ARM.
#
# Both halves of that matter, and getting the order wrong wastes a boot. It must be mid-stream,
# because the grabber still holds the pixel domain live and VIF reads with a gated clock hang the
# SoC. It must also be AFTER stage 5's configure_upto and arm: run before them, this dumps an
# ISP we have not configured yet, and 601 registers read zero that our replay is about to fill.
# The resulting diff then looks catastrophic and means nothing.
#
# The window list is glue/camera/isp-windows.list, the same file au-snapshot-vendor.sh reads
# against slot A, which is what keeps the two dumps diffable.
dump_windows > /tmp/ourisp.txt 2>/dev/null
echo "  stage 5c ok: $(grep -c '^+0x' /tmp/ourisp.txt) register lines read mid-stream, post-arm"

# ISP interrupt counters, meaningful only under USE_IRQ=1: events should track
# roughly three per frame and irq_seen0/1 name the observed sources.
if [ -r /sys/kernel/debug/ar-isp/irq_events ]; then
	echo "  isp irq: events $(cat /sys/kernel/debug/ar-isp/irq_events), stats-events $(cat /sys/kernel/debug/ar-isp/irq_stats_events), seen0 $(cat /sys/kernel/debug/ar-isp/irq_seen0), seen1 $(cat /sys/kernel/debug/ar-isp/irq_seen1)"
fi

# Statistics ping-pong. A flip count tracking the stats-event count says every
# frame's event rotated the halves. The grid must then read real luma rather
# than the not-yet-flipped placeholder a reader sees before the first flip.
if [ -r /sys/kernel/debug/ar-isp/stats_flips ]; then
	echo "  isp stats: flips $(cat /sys/kernel/debug/ar-isp/stats_flips)"
	echo "    grid: $(head -1 /sys/kernel/debug/ar-isp/stats 2>/dev/null)"
fi

# Stage 5d: the 0x3d60-0x3e1c curve-bank experiment. Runs only when the host staged the file.
#
# Deliberately AFTER the baseline capture and the register dump, so a single bring-up gives a
# before and an after of the same scene under the same light. A boot buys one bring-up, so an
# experiment that needs a comparison has to carry its own control.
if [ -f /tmp/block3d.txt ] && ! grep -q '^GROUP' /tmp/block3d.txt; then
	n=0
	while read -r addr val; do
		[ -n "$addr" ] || continue
		/tmp/ml-regdump -w "$addr" "$val" >/dev/null 2>&1 && n=$(( n + 1 ))
	done < /tmp/block3d.txt
	echo "  stage 5d: wrote $n registers into the 0x3d60-0x3e1c bank"

	# Read the bank back before capturing. If these are shadowed or commit-gated rather than
	# direct, the writes will not stick, and an unchanged image would then prove nothing about
	# the bank and everything about the write path.
	echo '  bank readback (isp +0x3d60, 48 words):'
	$R 0x08c03d60 48

	sleep 1
	if /tmp/ml-isploop "$WATCH" --cvisp --dump /tmp/"${NAME}"_b3d \
		--plane 0x28014000 --plane 0x28232000 --plane 0x282bb000 \
		>/tmp/il_b3d 2>&1; then
		grep -E 'markers overwritten' /tmp/il_b3d | sed 's/^/    /'
		echo "  stage 5d ok: captured ${NAME}_b3d"
	else
		echo '  stage 5d: capture failed after the block write'
		cat /tmp/il_b3d
	fi
	dump_windows > /tmp/ourisp_b3d.txt 2>/dev/null
fi

# Stage 5e: the page-by-page bisect, when the staged file carries GROUP markers.
#
# Applies one page of writes at a time and measures after each, so a single bring-up identifies
# which page carries the fix instead of spending one boot per page. Writes are cumulative, so
# the first group whose luma mean jumps is the culprit.
#
# The measurement is computed HERE rather than by pulling 21 frames over a flaky RF link. It
# samples 8 rows from the middle of the luma plane. Those rows include the 128 bytes of
# per-line padding, which is stale DDR, so about 6% of the sampled bytes are noise. That is
# irrelevant against the effect being looked for: the full write moved the mean from 97 to 184
# and dark pixels from 57% to 0%.
if grep -q '^GROUP' /tmp/block3d.txt 2>/dev/null; then
	lumamean() {
		dd if="$1" bs=2048 skip=536 count=8 2>/dev/null \
			| od -An -tu1 -v \
			| awk '{ for (i = 1; i <= NF; i++) { s += $i; n++ } } END { if (n) printf "%.1f", s / n }'
	}
	measure() {
		rm -f /tmp/sw.0
		/tmp/ml-isploop 1 --cvisp --dump /tmp/sw --plane 0x28014000 >/tmp/il_sw 2>&1
		mk=$(grep -c 'markers overwritten, first' /tmp/il_sw)
		if [ -s /tmp/sw.0 ]; then
			echo "  group $1: luma mean $(lumamean /tmp/sw.0)  (planes written: $mk)"
		else
			echo "  group $1: NO CAPTURE"
		fi
	}

	measure baseline
	grp=
	while read -r a b; do
		if [ "$a" = GROUP ]; then
			[ -n "$grp" ] && measure "$grp"
			grp=$b
			continue
		fi
		[ -n "$a" ] && /tmp/ml-regdump -w "$a" "$b" >/dev/null 2>&1
	done < /tmp/block3d.txt
	[ -n "$grp" ] && measure "$grp"
	rm -f /tmp/sw.0
fi

# Stage 5b: exposure and gain sweep, run BEFORE the gamma sweep so it cannot be contaminated
# by a deliberately broken table left loaded by it.
#
# The decoded vendor gamma is a healthy curve: it already lifts 12.5% input to 34% output. A
# frame that is still 90% black through a curve like that points at the signal reaching the
# ISP, not at the curve. exposure and gain are 0644 module params with an apply callback, so
# they can be swept live. Sensor I2C only, no VIF or ISP register is touched.
for es in $ESWEEP; do
	ex=$(echo "$es" | cut -d: -f1)
	gn=$(echo "$es" | cut -d: -f2)
	echo "$ex" > /sys/module/nt99235/parameters/exposure 2>/dev/null || { echo "  expo $es: write failed"; continue; }
	echo "$gn" > /sys/module/nt99235/parameters/gain 2>/dev/null || { echo "  expo $es: gain write failed"; continue; }
	sleep 1
	# Read the values back off the sensor. A module parameter that was accepted but never
	# reached the chip looks identical to a setting the sensor ignored. Note the -n form:
	# a bare fourth argument to ml-i2cprobe WRITES that value.
	if [ -x /tmp/ml-i2cprobe ]; then
		echo "    sensor: exposure" "$(/tmp/ml-i2cprobe 0 0x1a 0x0202 -n 2 2>/dev/null | cut -d= -f2 | tr -d ' \n')" \
		     "gain" "$(/tmp/ml-i2cprobe 0 0x1a 0x0206 -n 1 2>/dev/null | cut -d= -f2 | tr -d ' ')"
	fi
	# shellcheck disable=SC2086  # must split into separate --plane arguments
	if /tmp/ml-isploop "$WATCH" --cvisp --dump /tmp/"${NAME}"_e"${ex}"_g"${gn}" \
		$PLANES \
		>/tmp/il_e"$ex" 2>&1; then
		echo "  expo $ex gain $gn:" "$(grep -c 'markers overwritten' /tmp/il_e"$ex")" 'planes written'
	else
		echo "  expo $ex gain $gn: CAPTURE FAILED"
	fi
done

# Stage 6: gamma sweep INSIDE this bring-up. Only the first bring-up after a RAM-boot writes
# to DRAM, so a boot buys one capture, and testing one curve per boot is a terrible trade.
# The grabber is still alive here and the pipeline is still verified live, which is exactly the
# condition ml-isploop requires, so every sweep step is as safe as the stage-5 capture was.
#
# Each step only writes DRAM. No ISP register is touched. The vendor re-arms its table DMA
# addresses every frame, so a table changed in memory should be picked up without a fetch
# pulse. If every sweep step comes back identical, that assumption is wrong and the next boot
# should add a pulse of ISP 0x0014 bits 1-3 after each write.
for f in /tmp/sw_*.bin; do
	[ -e "$f" ] || continue
	sw=$(basename "$f" .bin)
	if ! kill -0 "$GP" 2>/dev/null; then
		echo "  sweep $sw: SKIPPED, grabber is gone so the pipeline is dead"
		continue
	fi
	if ! /tmp/ml-lutfill 0x2b2ec600 4096 load:"$f" >/dev/null 2>&1; then
		echo "  sweep $sw: LOAD FAILED, skipped"
		continue
	fi
	# Prove the write landed. A sweep that silently failed to change the buffer would look
	# exactly like a sweep the hardware ignored, and those need different fixes.
	# shellcheck disable=SC2046  # the 2-word regdump prints two lines; splitting keeps them on one echo
	echo "    buffer now:" $($R 0x2b2ec600 2 | cut -d: -f2)
	# The vendor's runtime gamma update is a descriptor REPUBLISH followed by a commit write,
	# not a pulse. Its AEC path packs a new page into the same buffer, then rewrites the same
	# physical address into all three descriptor address words and sets the commit bits. It
	# never clears them: they are write-to-trigger and the hardware clears them on completion,
	# which is why a live vendor read of 0x0014 shows them already back at zero.
	#
	# An earlier sweep pulsed set-then-clear and saw no effect, because clearing the bits
	# immediately cancelled the fetch it had just asked for.
	$R -w 0x08c00030 0x2b2ec600 >/dev/null 2>&1
	$R -w 0x08c00040 0x2b2ec600 >/dev/null 2>&1
	$R -w 0x08c00050 0x2b2ec600 >/dev/null 2>&1
	EN=$($R 0x08c00014 1 | cut -d' ' -f2)
	$R -w 0x08c00014 "$(printf '0x%x' $((0x$EN | 0x0e)))" >/dev/null 2>&1
	echo "    republished, commit 0x$EN|0x0e, now" "$($R 0x08c00014 1 | cut -d' ' -f2)"
	sleep 1
	# shellcheck disable=SC2086  # must split into separate --plane arguments
	if /tmp/ml-isploop "$WATCH" --cvisp --dump /tmp/"${NAME}"_"$sw" \
		$PLANES \
		>/tmp/il_"$sw" 2>&1; then
		n=$(grep -c 'markers overwritten' /tmp/il_"$sw")
		echo "  sweep $sw: $n planes written"
		# ml-isploop can exit 0 having captured nothing, which reads as a table with no effect
		# when it is really a failed capture. Show the log instead of letting it pass quietly.
		[ "$n" = 0 ] && sed 's/^/    /' /tmp/il_"$sw"
		grep -E 'markers overwritten' /tmp/il_"$sw" | sed 's/^/    /'
	else
		echo "  sweep $sw: CAPTURE FAILED"
		cat /tmp/il_"$sw"
	fi
done

# Stage 7: the heavier trigger, run LAST so a failure costs nothing already captured. If the
# 0x0014 pulse does not re-fetch the table either, re-running the full ISP replay will, since
# that is what loaded it in the first place. Mid-stream re-arm may disturb the pipeline, which
# is precisely why it is the final step.
if [ -f /tmp/rearm.bin ]; then
	/tmp/ml-lutfill 0x2b2ec600 4096 load:/tmp/rearm.bin >/dev/null 2>&1
	if echo 1 > /sys/kernel/debug/ar-isp/arm 2>/dev/null; then
		sleep 2
		if /tmp/ml-isploop "$WATCH" --cvisp --dump /tmp/"${NAME}"_rearm \
			--plane 0x28014000 --plane 0x28232000 --plane 0x282bb000 \
			>/tmp/il_rearm 2>&1; then
			echo '  stage 7 ok: re-armed and captured'
			grep -E 'markers overwritten' /tmp/il_rearm | sed 's/^/    /'
		else
			echo '  stage 7: capture failed after re-arm'
			cat /tmp/il_rearm
		fi
	else
		echo '  stage 7: re-arm write failed'
	fi
fi

# Stage 7b: are the AE statistics buffers ours, and is the hardware writing them?
#
# Passive: reads debugfs and dumps DRAM, poking nothing. It runs before the stages that zero
# pages on purpose, so a confounded statistics read cannot be blamed on one of those.
#
# The question is narrow. The RRO engines keep whatever address was last written to them, so a
# buffer that reads all zero means our address never took, or was overwritten. A non-zero count
# with a plausible frame mean means the hardware is writing memory we own, which is the whole
# point of stats=1.
#
# Also takes the two dumps queued by the parallel track: the LUT3D banks, to byte-verify them
# against the library templates, and the raw zone grid, which is worth far more in a
# deliberately non-uniform scene. Point the lens at a bright window and a dark corner.
echo '  stage 7b: AE statistics'
if [ -r /sys/kernel/debug/ar-isp/stats ]; then
	head -1 /sys/kernel/debug/ar-isp/stats | sed 's/^/    /'
	tail -1 /sys/kernel/debug/ar-isp/stats | sed 's/^/    /'
else
	echo '    no debugfs stats node (stats=0, or ar-isp did not probe)'
fi
dmesg | grep -E 'stats: rro' | tail -1 | sed 's/^/    /'
# Raw grid, from the address the driver printed, so this follows our allocation instead of a
# hardcoded vendor address. ml-lutfill counts words: 0x1200 words is the 0x4800 extent.
RRO=$(dmesg | grep -oE 'stats: rro 0x[0-9a-f]+' | tail -1 | sed 's/.*0x/0x/')
if [ -n "$RRO" ]; then
	/tmp/ml-lutfill "$RRO" 0x1200 save:/tmp/rro_raw.bin >/dev/null 2>&1 &&
		echo "    saved raw zone grid from $RRO"
fi
# LUT3D bank 0, 0x2a00 words. The module is disabled on the vendor, so this only byte-verifies
# the banks against the library templates; no live claim depends on it.
/tmp/ml-lutfill 0x2b3f8c00 0xa80 save:/tmp/lut3d.bin >/dev/null 2>&1 &&
	echo '    saved lut3d bank 0'
# The LTM coefficient page, 0x4000 = 0x1000 words, 64 tiles of a 128-sample u16 curve. The
# vendor recomputes this every frame rather than installing it, so this capture is scene
# dependent and only means something alongside a second one of a visibly different scene:
# comparing the two is what decides whether an open LTM has to compute or can ship a constant.
/tmp/ml-lutfill 0x2b2f8c00 0x1000 save:/tmp/ltm_page.bin >/dev/null 2>&1 &&
	echo '    saved ltm coefficient page'

# Stage 8: is the LSC page actually being fetched?
#
# The question this settles: our mid-stream dump and the vendor's agree on every word of the
# HDR and LSC register neighbourhoods except the valid bits, isp 0x1c60 and 0x4c3c, which read
# 0 on the vendor and 1 on ours. Read one way that is a self-clearing bit we caught before the
# fetch; read the other way our arm never completed and the block is running on whatever it had.
# A static register comparison cannot tell those apart, so perturb the page and look at the
# image: LSC's fetch length is 0x680, and 0x2b2e8600 is its live source.
#
# Runs LAST, after every capture that matters, because it deliberately corrupts a live table.
# Its own before-image is the stage 5 capture of the same scene.
if [ "$LSCPOKE" = 1 ]; then
	# 0x1a0 words is 0x680 bytes, the register-proven fetch length. Save first: this is the
	# only copy of what the vendor computed for this scene, and it is not reproducible from
	# the tuning file.
	/tmp/ml-lutfill 0x2b2e8600 0x1a0 save:/tmp/lsc_pre.bin >/dev/null 2>&1
	/tmp/ml-lutfill 0x2b2e8600 0x1a0 const:0x00000000 >/dev/null 2>&1
	echo '  stage 8: LSC page zeroed, valid bit before/after:'
	$R 0x08c04c3c 1
	/tmp/ml-regdump -w 0x08c04c3c 1 >/dev/null 2>&1
	$R 0x08c04c3c 1
	sleep 1
	# $PLANES, not all three: this is a yes/no question and /tmp is a 32 MB tmpfs. The
	# marker check still runs on whatever planes are passed, which is what makes an
	# unchanged image trustworthy here rather than possibly just a stale frame.
	# shellcheck disable=SC2086  # must split into separate --plane arguments
	if /tmp/ml-isploop "$WATCH" --cvisp --dump /tmp/"${NAME}"_lsc \
		$PLANES \
		>/tmp/il_lsc 2>&1; then
		echo '  stage 8 ok: captured after the poke'
		grep -E 'markers overwritten' /tmp/il_lsc | sed 's/^/    /'
	else
		echo '  stage 8: capture failed after the poke'
		cat /tmp/il_lsc
	fi
	# Put it back, AND re-arm, or the block keeps the zeroed page it already fetched and every
	# later stage silently measures a broken LSC on top of whatever it is testing. Restoring
	# DRAM alone is not enough: the fetch is what the valid bit triggers.
	/tmp/ml-lutfill 0x2b2e8600 0x1a0 load:/tmp/lsc_pre.bin >/dev/null 2>&1
	/tmp/ml-regdump -w 0x08c04c3c 1 >/dev/null 2>&1
	sleep 1
fi

# Stage 9: does GTM2's 512 bytes of content matter?
#
# GTM2 fetches 0x1000 from 0x2b2e0200 but only 0xa00 of that is its own: 0x000..0x7ff is zero
# and 0xa00.. is the compander table, which starts at 0x2b2e0c00 and is read because the fetch
# overruns. So GTM2's entire payload is the 512 bytes at 0x2b2e0a00, and those are the only
# bytes in the tone path with no static source anywhere: absent from libmpp_service.so, from
# the tuning blob, and from all 53 entries of the ISP-init template array.
#
# That leaves one question worth a boot: if zeroing them changes nothing, the driver can own
# the buffer with zeros and GTM2 stops being inherited without recovering anything. If it does
# change the image, the content matters and the RE has to continue.
#
# Runs after the LSC probe, last of everything, because it corrupts a live table.
if [ "$HDRPOKE" = 1 ]; then
	/tmp/ml-lutfill 0x2b2e0a00 0x80 save:/tmp/gtm2_pre.bin >/dev/null 2>&1
	/tmp/ml-lutfill 0x2b2e0a00 0x80 const:0x00000000 >/dev/null 2>&1
	echo '  stage 9: GTM2 payload zeroed, valid bit before/after:'
	$R 0x08c01c60 1
	/tmp/ml-regdump -w 0x08c01c60 1 >/dev/null 2>&1
	$R 0x08c01c60 1
	sleep 1
	# shellcheck disable=SC2086  # must split into separate --plane arguments
	if /tmp/ml-isploop "$WATCH" --cvisp --dump /tmp/"${NAME}"_gtm2 \
		$PLANES \
		>/tmp/il_gtm2 2>&1; then
		echo '  stage 9 ok: captured after the poke'
		grep -E 'markers overwritten' /tmp/il_gtm2 | sed 's/^/    /'
	else
		echo '  stage 9: capture failed after the poke'
		cat /tmp/il_gtm2
	fi
	/tmp/ml-lutfill 0x2b2e0a00 0x80 load:/tmp/gtm2_pre.bin >/dev/null 2>&1
	/tmp/ml-regdump -w 0x08c01c60 1 >/dev/null 2>&1
fi

# No grabber is left running: stage 4 streams briefly and exits, and every later capture opens
# the node for as long as it needs. The orphan that used to be left here is what blocked rmmod
# and silently invalidated everything after it, so check for one anyway rather than assume.
for pp in /proc/[0-9]*; do
	[ -r "$pp/comm" ] || continue
	case "$(cat "$pp"/comm 2>/dev/null)" in
	ml-v4l2grab|ml-isploop)
		echo "  WARNING: $(cat "$pp"/comm) still alive, next run will start dirty"
		kill -9 "${pp#/proc/}" 2>/dev/null
		;;
	esac
done
exit 0
