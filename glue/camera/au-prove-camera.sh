#!/usr/bin/env bash
# au-prove-camera.sh - prove the camera works, and prove nothing else.
#
# Captures two frames and renders both to PNG: the sensor's colour-bar test pattern, which has
# known content and does not depend on optics or lighting, and a live frame of whatever the lens
# is pointed at. Nothing here configures tone tables, pokes registers or runs an experiment.
#
# Every stage is gated. The reason is specific: a previous run let an orphaned ml-v4l2grab hold
# /dev/video2, which made rmmod fail silently, so later bring-ups ran on stale half-rebound
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
# Env: AU_IP, AU_PASS, EXPO (1123), GAIN (0x2f), BULK (1475).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/ssh-opts.sh"

AU_IP="${AU_IP:-192.168.3.102}"
AU_PASS="${AU_PASS:-libre}"
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
DRC_PROFILE="${DRC_PROFILE:-3}"
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
# DE3D=1 allocates de3d's three working buffers instead of leaving it writing the vendor's
# memory. Sizes are bounds derived from the vendor's own packing, not measured extents, and
# the third has no bound above it at all; see ar-isp.c. Unlike the other levers this one can
# change the picture, because de3d starts from an empty history rather than an inherited one.
DE3D="${DE3D:-1}"
# Complete frames from the VIF frame-done interrupt instead of the polling work item. Off by
# default because the acknowledge behaviour is unconfirmed and the line is level triggered.
USE_IRQ="${USE_IRQ:-0}"
# Capture window in seconds. The one clean frame of the day was a 1 s grab; 4 s grabs are
# crushed on the same configuration, and this system is documented as giving different answers
# at 1 s and 4 s. Keep this at 1 unless deliberately probing the drift.
WATCH="${WATCH:-1}"
# Modules are read from the staged module tree, which is what the build actually installs.
# The in-tree drivers/media/artosyn directory is a sync target and is left without objects,
# so reading from it silently stages whatever a previous build happened to leave behind.
KD="$REPO/kernel/build/kernel-repro-6.18.36/ml-modules/rootfs/lib/modules/6.18.36/kernel"
OUT="$REPO/out/au-prove"

au()   { sshpass -p "$AU_PASS" ssh "${SSH_OPTS_LEGACY[@]}" root@"$AU_IP" "$@"; }
push() { sshpass -p "$AU_PASS" ssh "${SSH_OPTS_LEGACY[@]}" root@"$AU_IP" \
	         "cat > /tmp/$2; chmod +x /tmp/$2" < "$1"; }
# Write to a temporary and move only on success. A plain `> "$2"` truncates the destination
# before the remote cat runs, so a missing or unreadable source DESTROYS the previous result.
# That is not hypothetical: the sweep runs, which never create live_b3d.*, silently zeroed the
# planes of the earlier capture that first showed the fixed image.
pull() {
	if sshpass -p "$AU_PASS" ssh "${SSH_OPTS_LEGACY[@]}" root@"$AU_IP" "cat '$1'" > "$2.part" 2>/dev/null && [ -s "$2.part" ]
	then
		mv -f "$2.part" "$2"
		return 0
	fi
	rm -f "$2.part"
	return 1
}

mkdir -p "$OUT"

echo "=== staging ==="
for m in nt99235 ar-csi2 ar-vif ar-isp ar-cvisp
do
	push "$KD/$m.ko" "$m.ko" || exit 1
done
for t in ml-regdump ml-v4l2grab ml-isploop ml-lutfill ml-i2cprobe
do
	push "$REPO/native/build/$t" "$t" || exit 1
done

# The vendor tuning file, verbatim. ar-isp loads it through request_firmware and generates the
# gamma and DRC pages from it; without it the driver still owns the buffers but can only seed
# them from whatever the vendor left in DRAM. It is proprietary, so it is not in the repository:
# this is the copy `missinglynk dump-firmware` pulled off a stock unit.
TUNING="${TUNING:-$REPO/out/air-gather/vendor-root/usr/usrdata/tunning/nt99235_tuning_preview_fpv.bin}"
if [ -s "$TUNING" ]
then
	push "$TUNING" "nt99235-tuning-preview-fpv.bin" || exit 1
	echo "  staged tuning file, $(stat -c %s "$TUNING") bytes"
else
	echo "  NO tuning file at $TUNING: ar-isp will seed, not generate"
	au 'rm -f /tmp/nt99235-tuning-preview-fpv.bin' </dev/null 2>/dev/null || true
fi

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
	push "$OUT/block3d.txt" "block3d.txt" || exit 1
	echo "  staged BLOCK3D=$BLOCK3D: $(wc -l < "$OUT/block3d.txt") register writes"
else
	au 'rm -f /tmp/block3d.txt' </dev/null 2>/dev/null || true
fi

# GAMMA=<file> injects a captured vendor gamma table into the ISP's gamma buffer before the
# ISP is armed, so the fetch pulse picks it up. The device script switches on the file being
# present, which avoids quoting a flag through the heredoc. Absent GAMMA, the stale file is
# removed so a previous run's injection cannot silently persist into this one.
if [ -n "${GAMMA:-}" ]
then
	[ -s "$GAMMA" ] || { echo "GAMMA=$GAMMA is missing or empty"; exit 1; }
	push "$GAMMA" "gamma.bin" || exit 1
	echo "  gamma injection armed from $GAMMA"
else
	au 'rm -f /tmp/gamma.bin'
fi

# SWEEP="<file> <file> ...": inside the single good bring-up, load each gamma table in turn and
# capture a frame for each. This is the only way to compare more than one curve per boot, since
# only the first bring-up after a RAM-boot writes to DRAM. Files are numbered so the device-side
# glob keeps the order given here.
au 'rm -f /tmp/sw_*.bin'
SWEEP_NAMES=""
if [ -n "${SWEEP:-}" ]
then
	i=0
	for f in $SWEEP
	do
		[ -s "$f" ] || { echo "SWEEP entry $f is missing or empty"; exit 1; }
		i=$((i + 1))
		tag="$(printf '%02d_%s' "$i" "$(basename "$f" .bin)")"
		push "$f" "sw_$tag.bin" || exit 1
		SWEEP_NAMES="$SWEEP_NAMES sw_$tag"
		echo "  sweep $i armed: $f"
	done
fi

# REARM=<file>: after the sweep, load this table and re-run the full ISP replay rather than
# pulsing the fetch bits. Runs last, so it cannot cost an earlier capture.
au 'rm -f /tmp/rearm.bin'
if [ -n "${REARM:-}" ]
then
	[ -s "$REARM" ] || { echo "REARM=$REARM is missing or empty"; exit 1; }
	push "$REARM" "rearm.bin" || exit 1
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

# The device script goes over stdin, not as an ssh argument. It outgrew the command-line
# limit once the sweep stages were added, and the failure mode was a broken pipe during
# staging followed by "prove.sh: not found", which reads like a device fault and is not.
PROVE="#!/bin/sh
# \$1 = test pattern value (2 = colour bars, 0 = off, live scene)
R=/tmp/ml-regdump
TP=\$1
NAME=\$2
CYC=\$3
WATCH=\${WATCH:-1}
# Sweep captures are luma-only by default: /tmp is a 32 MB tmpfs and three planes cost 5.4 MB
# per step, so a long sweep silently truncates its last capture. One plane costs 2.2 MB.
ALL3='--plane 0x28014000 --plane 0x28232000 --plane 0x282bb000'
if [ -n \"\${SWEEP_COLOUR:-}\" ]
then PLANES=\"\$ALL3\"
else PLANES='--plane 0x28014000'
fi

fail() {
	echo \"FAILED: \$1\"
	echo '--- kernel log ---'
	dmesg | grep -i -E 'nt99235|ar.isp|ar.vif|ar.csi2|cvisp' | tail -25
	# Leave nothing running and nothing loaded, so the next attempt starts clean.
	for p in /proc/[0-9]*
	do
		c=\$(cat \$p/comm 2>/dev/null)
		case \"\$c\" in ml-v4l2grab|ml-isploop) kill -9 \${p#/proc/} 2>/dev/null ;; esac
	done
	exit 1
}

# Stage 1: start from nothing. Kill by /proc comm, because busybox pkill -x is unreliable and
# -f matches this script itself.
for p in /proc/[0-9]*
do
	c=\$(cat \$p/comm 2>/dev/null)
	case \"\$c\" in
	ml-v4l2grab|ml-isploop) echo \"  killing stale \$c\"; kill -9 \${p#/proc/} 2>/dev/null ;;
	esac
done
sleep 1
for m in ar_cvisp ar_isp ar_vif ar_csi2 nt99235
do
	rmmod \$m 2>/dev/null
done
for m in ar_cvisp ar_isp ar_vif ar_csi2 nt99235
do
	lsmod | grep -q \"^\$m \" && fail \"\$m would not unload, something still holds it\"
done
echo '  stage 1 ok: nothing loaded'

# Stage 1b: the camera CGU leaves. Nothing sets these on a fresh boot, and without them the ISP
# and VIF clocks are wrong: their registers read back zero, no frame ever starts, and the whole
# chain looks broken for a reason that has nothing to do with the sensor. The gate check first,
# because programming a leaf whose parent gate is closed is how the SoC gets hung.
G=\$(\$R 0x0a104014 1 | cut -d' ' -f2)
case \$G in
*[13579bdf]???) : ;;
*) fail \"cgu 0x0a104014=\$G, gate bit12 is CLEAR\" ;;
esac
\$R -w 0x0a10400c 0x13001300 >/dev/null || fail 'cgu 0x0a10400c'
\$R -w 0x0a104010 0x02001300 >/dev/null || fail 'cgu 0x0a104010'
\$R -w 0x0a104020 0x10001103 >/dev/null || fail 'cgu 0x0a104020'
\$R -w 0x0a10401c 0x02011201 >/dev/null || fail 'cgu 0x0a10401c'
\$R -w 0x0a104044 0x01001000 >/dev/null || fail 'cgu 0x0a104044'
echo '  stage 1b ok: camera clocks programmed'

# Read-only pre-flight. Our replay points the ISP at the VENDOR's physical addresses and then
# pulses 0x0014 to fetch them, but never fills them. DDR survives a RAM-boot, so if the vendor
# camera ran in slot A before we booted, its real tuning tables are still resident and the ISP
# inherits working ones. If it did not, the ISP fetches whatever is in those pages. This records
# which case we are in, so picture quality can be correlated with it instead of guessed at.
for spec in gamma:0x2b2ec600:4096 compander:0x2b2e0c00:7680 drc:0x2b2e9200:2048
do
	nm=\$(echo \$spec | cut -d: -f1)
	ad=\$(echo \$spec | cut -d: -f2)
	ct=\$(echo \$spec | cut -d: -f3)
	/tmp/ml-lutfill \$ad \$ct save:/tmp/pre_\$nm.bin >/dev/null 2>&1
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
if [ -f /tmp/gamma.bin ]
then
	if /tmp/ml-lutfill 0x2b2ec600 4096 load:/tmp/gamma.bin >/dev/null 2>&1
	then echo '  stage 1d ok: vendor gamma injected at 0x2b2ec600'
	else echo '  stage 1d FAILED: gamma not injected'
	fi
else
	echo '  stage 1d skipped: no /tmp/gamma.bin, running on resident gamma'
fi

# Stage 1e: the tuning file has to be on the firmware search path before ar-isp probes. The
# rootfs is not the place for it during a bring-up, so point the loader at tmpfs, which is where
# the push landed anyway. Moved rather than copied: /tmp is 32 MB.
if [ -f /tmp/nt99235-tuning-preview-fpv.bin ]
then
	mkdir -p /tmp/fw/artosyn
	mv /tmp/nt99235-tuning-preview-fpv.bin /tmp/fw/artosyn/
	if echo -n /tmp/fw > /sys/module/firmware_class/parameters/path 2>/dev/null
	then echo '  stage 1e ok: tuning file on the firmware search path'
	else echo '  stage 1e FAILED: no firmware_class path parameter, ar-isp will seed instead'
	fi
else
	echo '  stage 1e skipped: no tuning file, ar-isp will seed instead of generate'
fi

# Stage 2: load, aborting on the first failure rather than continuing on stale state.
insmod /tmp/nt99235.ko exposure=$EXPO gain=$GAIN test_pattern=\$TP || fail 'insmod nt99235'
# ar-isp is spelled out rather than looped because it is the only one with run-time levers
# worth steering from here. The ORDER IS THE ORIGINAL ONE and matters: it is the order the
# media graph was proven to bind in.
insmod /tmp/ar-csi2.ko || fail 'insmod ar-csi2'
# ar-vif defaults to completing frames by polling. The interrupt line is level triggered and a
# handler that fails to clear the source wedges the machine, so USE_IRQ=1 is an experiment with
# a working fallback, not a setting to leave on until an acknowledge is confirmed.
insmod /tmp/ar-vif.ko use_irq=$USE_IRQ || fail 'insmod ar-vif'
insmod /tmp/ar-isp.ko tables=$TABLES seed=$SEED gamma_curve=$GAMMA_CURVE drc_profile=$DRC_PROFILE \
	compander=$COMPANDER lsc=$LSC stats=$STATS ccm=$CCM ccm_bank=$CCM_BANK de3d=$DE3D \
	|| fail 'insmod ar-isp'
insmod /tmp/ar-cvisp.ko blc=$BLC blc_gain=$BLC_GAIN || fail 'insmod ar-cvisp'
sleep 1
echo '  stage 2 ok: modules loaded'

# Stage 3: the graph must have bound. No video node means the subdev never attached, and every
# later stage would be operating on a dead pipeline.
[ -e /dev/video2 ] || fail 'no /dev/video2, the media graph did not bind'
echo '  stage 3 ok: /dev/video2 exists'

# Stage 4: the sensor must actually be streaming before anything reads VIF.
rm -f /tmp/f.raw
/tmp/ml-v4l2grab -d /dev/video2 -o /tmp/f.raw -n 6000 -t 300 >/tmp/g.out 2>&1 &
GP=\$!
sleep 3
kill -0 \$GP 2>/dev/null || { echo '--- grabber output ---'; cat /tmp/g.out; fail 'grabber died, sensor is not streaming'; }
# Alive is not the same as delivering. On a second bring-up the grabber blocks forever waiting
# for a buffer that never completes, and a liveness-only check calls that success, so every
# later stage runs against a pipeline that is not producing frames.
#
# Gate on the raw file, not on the grabber's log: its stdout is fully buffered when redirected,
# so the log stays empty until the process exits and an empty log proves nothing. The grabber
# writes its output file on the first frame, so that file existing IS a delivered frame.
if [ ! -s /tmp/f.raw ]
then
	# Diagnose before failing. The grabber still holds the stream, so the VIF clock is live
	# and these reads are in the one window where they are safe. 0x17c and 0x184 are the W1C
	# completion statuses the poll path waits on, 0x1b0 the block status, 0x020 the armed
	# view address. All zero on 0x17c means the view DMA never signalled a done.
	echo '  --- VIF window, mid-stream, for diffing against the vendor ---'
	echo '--- vif +0x0000 (256 words) ---'
	\$R 0x08870000 256
	echo '--- vif +0x0300 (64 words) ---'
	\$R 0x08870300 64
	# A missing raw frame does NOT mean the pipeline is dead. The bypass view backing
	# /dev/video2 has never completed a buffer on any run, and the vendor holds that view in
	# reset and streams through the ISP path instead, so requiring a delivered V4L2 buffer
	# gates every bring-up on a path that has never worked and blocks all later stages.
	#
	# What this gate actually has to establish is narrower: that the pixel domain is LIVE, so
	# that reading VIF and the ISP below cannot hard-hang the SoC. VIF +0x17c bit 24 is a
	# frame event on the ISP path, and nothing in our sequence acknowledges it before now, so
	# a non-zero read means frames are being produced.
	# POLL, do not sample once. A single read is racy in both directions: this register is
	# an event flag, the read itself may clear it, and the camera is documented as
	# time-dependent, so one look at t+3s can miss a pipeline that is running perfectly.
	# A single-sample version of this gate failed a first bring-up whose VIF counters were
	# advancing normally, which cost a boot.
	ev=0
	i=0
	while [ \$i -lt 16 ]
	do
		v=\$(\$R 0x0887017c 1 | awk '/^\\+/{print \$2}')
		if [ -n \"\$v\" ] && [ \$(( 0x\$v & 0x01000000 )) -ne 0 ]
		then
			ev=\$v
			break
		fi
		i=\$(( i + 1 ))
		sleep 1
	done
	if [ \"\$ev\" != 0 ]
	then
		echo \"  stage 4: NO raw buffer (bypass view never completes) but VIF 0x17c = 0x\$ev\"
		echo \"           frame event seen after \$i s, so the pixel domain is live: continuing.\"
	else
		fail 'no raw buffer AND no VIF frame event in 16 s: pipeline is dead'
	fi
else
	echo \"  stage 4 ok: streaming, raw frame \$(wc -c < /tmp/f.raw) bytes\"
fi

# Stage 4b: our own sensor registers, read while streaming. The sensor is powered down when the
# stream stops, so i2c reads fail outside this window; that is why this cannot be a post-run
# check. Comparing against the vendor's dump decides whether the 271 registers the vendor holds
# non-zero and our mode table never writes are vendor writes we are missing, or power-on
# defaults. Read-only: the -n form, since a bare fourth argument WRITES.
if [ -x /tmp/ml-i2cprobe ]
then
	: > /tmp/oursensor.txt
	for pg in 0x0000 0x0100 0x0200 0x0300 0x0400 0x0500 0x0600 0x0800 0x0c00 0x3000 0x3100 0x3200 0x3300 \
	          0x3500 0x3600 0x3a00 0x8000 0x8200 0x8300 0x8500 0x8700 0x9000
	do
		/tmp/ml-i2cprobe 0 0x1a \$pg -n 256 >> /tmp/oursensor.txt 2>/dev/null
	done
	echo \"  stage 4b ok: \$(grep -c '= 0x' /tmp/oursensor.txt) sensor registers read\"
fi

dump_windows() {
	for spec in \\
		isp:0x08c00000:0x0000:64    isp:0x08c00000:0x0800:322 \\
		isp:0x08c00000:0x1800:512   isp:0x08c00000:0x2400:16 \\
		isp:0x08c00000:0x4000:64 \\
		isp:0x08c00000:0x2800:64    isp:0x08c00000:0x2e00:1032 \\
		isp:0x08c00000:0x4800:576   isp:0x08c00000:0x5800:28 \\
		isp:0x08c00000:0x6000:384   isp:0x08c00000:0x6c00:704 \\
		cvisp:0x08e00000:0x8000:64  cvisp:0x08e00000:0x4600:16 \\
		cvisp:0x08e00000:0x4000:256 cvisp:0x08e00000:0x4400:64 \\
		cvisp:0x08e00000:0x4700:16 \\
		vif:0x08870000:0x0000:256   vif:0x08870000:0x0300:64 \\
		csi2:0x08880000:0x0400:64   csi2:0x08880000:0x0800:64 \\
		cgu:0x0a104000:0x0000:32
	do
		blk=\${spec%%:*}
		rest=\${spec#*:}
		base=\${rest%%:*}
		rest=\${rest#*:}
		off=\${rest%%:*}
		cnt=\${rest##*:}
		echo \"--- \$blk +\$off (\$cnt words) ---\"
		\$R \$(printf '0x%x' \$(( base + off ))) \$cnt
	done
}

echo '  csi-2 core0 mid-stream:'
/tmp/ml-regdump 0x08880400 4

# Stage 5: only now is it safe to touch the ISP and VIF.
echo $BULK > /sys/kernel/debug/ar-isp/configure_upto || fail 'configure_upto'
echo 1 > /sys/kernel/debug/ar-isp/arm || fail 'isp arm'
sleep 2
echo 1 > /sys/kernel/debug/ar-cvisp/configure || fail 'cvisp configure'
sleep 1

# Whose buffers is the block actually reading? The replay arms the vendor's addresses and
# ar-isp republishes its own over them, so this is the one read that says which of the two
# won. Vendor pages are 0x2b2e____; ours come out of the isp_cma pool at 0x2a0_____.
echo '  coefficient descriptors (gamma x3, drc, compander):'
\$R 0x08c00030 1
\$R 0x08c00040 1
\$R 0x08c00050 1
\$R 0x08c00060 1
\$R 0x08c00020 1

# ml-isploop drives the CVISP ring from its own table, so frames land in ITS slots, not at the
# plane the driver programmed. These three are slot 1: luma, then the two chroma planes. Passing
# only the luma address is why the first run came back greyscale, since --plane replaces the
# whole dump list rather than adding to it.
echo \"  cvisp control (expect 0x00800806):\"
\$R 0x08e08000 1

if [ \"\$CYC\" = cycle ]
then
	EXTRA=--isp-cycle
else
	EXTRA=
fi
/tmp/ml-isploop \$WATCH --cvisp \$EXTRA --dump /tmp/\$NAME \\
	--plane 0x28014000 --plane 0x28232000 --plane 0x282bb000 \\
	>/tmp/il 2>&1 || { cat /tmp/il; fail 'capture'; }
grep -E 'cycles driven|markers overwritten' /tmp/il
echo \"  stage 5 ok: captured \$NAME\"

# Stage 5c: our own ISP, CVISP, VIF, CSI-2 and CGU windows, read MID-STREAM and POST-ARM.
#
# Both halves of that matter, and getting the order wrong wastes a boot. It must be mid-stream,
# because the grabber still holds the pixel domain live and VIF reads with a gated clock hang the
# SoC. It must also be AFTER stage 5's configure_upto and arm: run before them, this dumps an
# ISP we have not configured yet, and 601 registers read zero that our replay is about to fill.
# The resulting diff then looks catastrophic and means nothing.
#
# The window list is byte-for-byte the one au-snapshot-vendor.sh uses against slot A. It must
# stay identical or the two dumps cannot be diffed.
dump_windows > /tmp/ourisp.txt 2>/dev/null
echo \"  stage 5c ok: \$(grep -c '^+0x' /tmp/ourisp.txt) register lines read mid-stream, post-arm\"

# Stage 5d: the 0x3d60-0x3e1c curve-bank experiment. Runs only when the host staged the file.
#
# Deliberately AFTER the baseline capture and the register dump, so a single bring-up gives a
# before and an after of the same scene under the same light. A boot buys one bring-up, so an
# experiment that needs a comparison has to carry its own control.
if [ -f /tmp/block3d.txt ] && ! grep -q '^GROUP' /tmp/block3d.txt
then
	n=0
	while read -r addr val
	do
		[ -n \"\$addr\" ] || continue
		/tmp/ml-regdump -w \"\$addr\" \"\$val\" >/dev/null 2>&1 && n=\$(( n + 1 ))
	done < /tmp/block3d.txt
	echo \"  stage 5d: wrote \$n registers into the 0x3d60-0x3e1c bank\"

	# Read the bank back before capturing. If these are shadowed or commit-gated rather than
	# direct, the writes will not stick, and an unchanged image would then prove nothing about
	# the bank and everything about the write path.
	echo '  bank readback (isp +0x3d60, 48 words):'
	\$R 0x08c03d60 48

	sleep 1
	if /tmp/ml-isploop \$WATCH --cvisp --dump /tmp/\${NAME}_b3d \\
		--plane 0x28014000 --plane 0x28232000 --plane 0x282bb000 \\
		>/tmp/il_b3d 2>&1
	then
		grep -E 'markers overwritten' /tmp/il_b3d | sed 's/^/    /'
		echo \"  stage 5d ok: captured \${NAME}_b3d\"
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
if grep -q '^GROUP' /tmp/block3d.txt 2>/dev/null
then
	lumamean() {
		dd if=\"\$1\" bs=2048 skip=536 count=8 2>/dev/null \\
			| od -An -tu1 -v \\
			| awk '{ for (i = 1; i <= NF; i++) { s += \$i; n++ } } END { if (n) printf \"%.1f\", s / n }'
	}
	measure() {
		rm -f /tmp/sw.0
		/tmp/ml-isploop 1 --cvisp --dump /tmp/sw --plane 0x28014000 >/tmp/il_sw 2>&1
		mk=\$(grep -c 'markers overwritten, first' /tmp/il_sw)
		if [ -s /tmp/sw.0 ]
		then
			echo \"  group \$1: luma mean \$(lumamean /tmp/sw.0)  (planes written: \$mk)\"
		else
			echo \"  group \$1: NO CAPTURE\"
		fi
	}

	measure baseline
	grp=
	while read -r a b
	do
		if [ \"\$a\" = GROUP ]
		then
			[ -n \"\$grp\" ] && measure \"\$grp\"
			grp=\$b
			continue
		fi
		[ -n \"\$a\" ] && /tmp/ml-regdump -w \"\$a\" \"\$b\" >/dev/null 2>&1
	done < /tmp/block3d.txt
	[ -n \"\$grp\" ] && measure \"\$grp\"
	rm -f /tmp/sw.0
fi

# Stage 5b: exposure and gain sweep, run BEFORE the gamma sweep so it cannot be contaminated
# by a deliberately broken table left loaded by it.
#
# The decoded vendor gamma is a healthy curve: it already lifts 12.5% input to 34% output. A
# frame that is still 90% black through a curve like that points at the signal reaching the
# ISP, not at the curve. exposure and gain are 0644 module params with an apply callback, so
# they can be swept live. Sensor I2C only, no VIF or ISP register is touched.
for es in \$ESWEEP
do
	ex=\$(echo \$es | cut -d: -f1)
	gn=\$(echo \$es | cut -d: -f2)
	echo \$ex > /sys/module/nt99235/parameters/exposure 2>/dev/null || { echo \"  expo \$es: write failed\"; continue; }
	echo \$gn > /sys/module/nt99235/parameters/gain 2>/dev/null || { echo \"  expo \$es: gain write failed\"; continue; }
	sleep 1
	# Read the values back off the sensor. A module parameter that was accepted but never
	# reached the chip looks identical to a setting the sensor ignored. Note the -n form:
	# a bare fourth argument to ml-i2cprobe WRITES that value.
	if [ -x /tmp/ml-i2cprobe ]
	then
		echo \"    sensor: exposure\" \$(/tmp/ml-i2cprobe 0 0x1a 0x0202 -n 2 2>/dev/null | cut -d= -f2 | tr -d ' \\n') \
		     \"gain\" \$(/tmp/ml-i2cprobe 0 0x1a 0x0206 -n 1 2>/dev/null | cut -d= -f2 | tr -d ' ')
	fi
	if /tmp/ml-isploop \$WATCH --cvisp --dump /tmp/\${NAME}_e\${ex}_g\${gn} \\
		\$PLANES \\
		>/tmp/il_e\$ex 2>&1
	then
		echo \"  expo \$ex gain \$gn:\" \$(grep -c 'markers overwritten' /tmp/il_e\$ex) 'planes written'
	else
		echo \"  expo \$ex gain \$gn: CAPTURE FAILED\"
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
for f in /tmp/sw_*.bin
do
	[ -e \"\$f\" ] || continue
	sw=\$(basename \$f .bin)
	if ! kill -0 \$GP 2>/dev/null
	then
		echo \"  sweep \$sw: SKIPPED, grabber is gone so the pipeline is dead\"
		continue
	fi
	if ! /tmp/ml-lutfill 0x2b2ec600 4096 load:\$f >/dev/null 2>&1
	then
		echo \"  sweep \$sw: LOAD FAILED, skipped\"
		continue
	fi
	# Prove the write landed. A sweep that silently failed to change the buffer would look
	# exactly like a sweep the hardware ignored, and those need different fixes.
	echo \"    buffer now:\" \$(\$R 0x2b2ec600 2 | cut -d: -f2)
	# The vendor's runtime gamma update is a descriptor REPUBLISH followed by a commit write,
	# not a pulse. Its AEC path packs a new page into the same buffer, then rewrites the same
	# physical address into all three descriptor address words and sets the commit bits. It
	# never clears them: they are write-to-trigger and the hardware clears them on completion,
	# which is why a live vendor read of 0x0014 shows them already back at zero.
	#
	# An earlier sweep pulsed set-then-clear and saw no effect, because clearing the bits
	# immediately cancelled the fetch it had just asked for.
	\$R -w 0x08c00030 0x2b2ec600 >/dev/null 2>&1
	\$R -w 0x08c00040 0x2b2ec600 >/dev/null 2>&1
	\$R -w 0x08c00050 0x2b2ec600 >/dev/null 2>&1
	EN=\$(\$R 0x08c00014 1 | cut -d' ' -f2)
	\$R -w 0x08c00014 \$(printf '0x%x' \$((0x\$EN | 0x0e))) >/dev/null 2>&1
	echo \"    republished, commit 0x\$EN|0x0e, now\" \$(\$R 0x08c00014 1 | cut -d' ' -f2)
	sleep 1
	if /tmp/ml-isploop \$WATCH --cvisp --dump /tmp/\${NAME}_\$sw \\
		\$PLANES \\
		>/tmp/il_\$sw 2>&1
	then
		n=\$(grep -c 'markers overwritten' /tmp/il_\$sw)
		echo \"  sweep \$sw: \$n planes written\"
		# ml-isploop can exit 0 having captured nothing, which reads as a table with no effect
		# when it is really a failed capture. Show the log instead of letting it pass quietly.
		[ \"\$n\" = 0 ] && sed 's/^/    /' /tmp/il_\$sw
		grep -E 'markers overwritten' /tmp/il_\$sw | sed 's/^/    /'
	else
		echo \"  sweep \$sw: CAPTURE FAILED\"
		cat /tmp/il_\$sw
	fi
done

# Stage 7: the heavier trigger, run LAST so a failure costs nothing already captured. If the
# 0x0014 pulse does not re-fetch the table either, re-running the full ISP replay will, since
# that is what loaded it in the first place. Mid-stream re-arm may disturb the pipeline, which
# is precisely why it is the final step.
if [ -f /tmp/rearm.bin ]
then
	/tmp/ml-lutfill 0x2b2ec600 4096 load:/tmp/rearm.bin >/dev/null 2>&1
	if echo 1 > /sys/kernel/debug/ar-isp/arm 2>/dev/null
	then
		sleep 2
		if /tmp/ml-isploop \$WATCH --cvisp --dump /tmp/\${NAME}_rearm \\
			--plane 0x28014000 --plane 0x28232000 --plane 0x282bb000 \\
			>/tmp/il_rearm 2>&1
		then
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
if [ -r /sys/kernel/debug/ar-isp/stats ]
then
	head -1 /sys/kernel/debug/ar-isp/stats | sed 's/^/    /'
	tail -1 /sys/kernel/debug/ar-isp/stats | sed 's/^/    /'
else
	echo '    no debugfs stats node (stats=0, or ar-isp did not probe)'
fi
dmesg | grep -E 'stats: rro' | tail -1 | sed 's/^/    /'
# Raw grid, from the address the driver printed, so this follows our allocation instead of a
# hardcoded vendor address. ml-lutfill counts words: 0x1200 words is the 0x4800 extent.
RRO=\$(dmesg | grep -oE 'stats: rro 0x[0-9a-f]+' | tail -1 | sed 's/.*0x/0x/')
if [ -n \"\$RRO\" ]
then
	/tmp/ml-lutfill \$RRO 0x1200 save:/tmp/rro_raw.bin >/dev/null 2>&1 &&
		echo \"    saved raw zone grid from \$RRO\"
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
if [ \"\$LSCPOKE\" = 1 ]
then
	# 0x1a0 words is 0x680 bytes, the register-proven fetch length. Save first: this is the
	# only copy of what the vendor computed for this scene, and it is not reproducible from
	# the tuning file.
	/tmp/ml-lutfill 0x2b2e8600 0x1a0 save:/tmp/lsc_pre.bin >/dev/null 2>&1
	/tmp/ml-lutfill 0x2b2e8600 0x1a0 const:0x00000000 >/dev/null 2>&1
	echo '  stage 8: LSC page zeroed, valid bit before/after:'
	\$R 0x08c04c3c 1
	/tmp/ml-regdump -w 0x08c04c3c 1 >/dev/null 2>&1
	\$R 0x08c04c3c 1
	sleep 1
	# \$PLANES, not all three: this is a yes/no question and /tmp is a 32 MB tmpfs. The
	# marker check still runs on whatever planes are passed, which is what makes an
	# unchanged image trustworthy here rather than possibly just a stale frame.
	if /tmp/ml-isploop \$WATCH --cvisp --dump /tmp/\${NAME}_lsc \\
		\$PLANES \\
		>/tmp/il_lsc 2>&1
	then
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
if [ \"\$HDRPOKE\" = 1 ]
then
	/tmp/ml-lutfill 0x2b2e0a00 0x80 save:/tmp/gtm2_pre.bin >/dev/null 2>&1
	/tmp/ml-lutfill 0x2b2e0a00 0x80 const:0x00000000 >/dev/null 2>&1
	echo '  stage 9: GTM2 payload zeroed, valid bit before/after:'
	\$R 0x08c01c60 1
	/tmp/ml-regdump -w 0x08c01c60 1 >/dev/null 2>&1
	\$R 0x08c01c60 1
	sleep 1
	if /tmp/ml-isploop \$WATCH --cvisp --dump /tmp/\${NAME}_gtm2 \\
		\$PLANES \\
		>/tmp/il_gtm2 2>&1
	then
		echo '  stage 9 ok: captured after the poke'
		grep -E 'markers overwritten' /tmp/il_gtm2 | sed 's/^/    /'
	else
		echo '  stage 9: capture failed after the poke'
		cat /tmp/il_gtm2
	fi
	/tmp/ml-lutfill 0x2b2e0a00 0x80 load:/tmp/gtm2_pre.bin >/dev/null 2>&1
	/tmp/ml-regdump -w 0x08c01c60 1 >/dev/null 2>&1
fi

# Always clean up the grabber, and verify it is gone. The orphan left by an earlier run is what
# blocked rmmod and silently invalidated everything after it.
kill \$GP 2>/dev/null
sleep 1
kill -0 \$GP 2>/dev/null && kill -9 \$GP 2>/dev/null
sleep 1
kill -0 \$GP 2>/dev/null && echo '  WARNING: grabber still alive, next run will start dirty'
exit 0"
printf '%s\n' "$PROVE" | au 'cat > /tmp/prove.sh; chmod +x /tmp/prove.sh' || exit 1

# Only the FIRST bring-up after a boot writes to DRAM; every later one re-reads the frame the
# first one left. So a boot buys exactly one trustworthy capture, and RUNS selects which.
#   RUNS="0:live:nocycle"        one live frame
#   RUNS="2:testpattern:nocycle" one pattern frame
for run in ${RUNS:-"2:testpattern:nocycle" "0:live:nocycle" "0:live2:nocycle"}
do
	tp="${run%%:*}"
	rest="${run#*:}"
	name="${rest%%:*}"
	cyc="${run##*:}"
	echo
	echo "=== capture: $name (test_pattern=$tp, $cyc) ==="
	if ! au "WATCH=$WATCH ESWEEP='${ESWEEP:-}' SWEEP_COLOUR='${SWEEP_COLOUR:-}' LSCPOKE='${LSCPOKE:-0}' HDRPOKE='${HDRPOKE:-0}' /tmp/prove.sh $tp $name $cyc"
	then
		echo ">>> $name FAILED, stopping. Nothing touched VIF or the ISP."
		exit 1
	fi
	for p in 0 1 2
	do
		pull "/tmp/$name.$p" "$OUT/$name.$p" 2>/dev/null || true
	done
	ESWEEP_NAMES=""
	for es in ${ESWEEP:-}
	do
		ESWEEP_NAMES="$ESWEEP_NAMES e${es%%:*}_g${es##*:}"
	done
	for sw in $ESWEEP_NAMES $SWEEP_NAMES
	do
		for p in 0 1 2
		do
			pull "/tmp/${name}_$sw.$p" "$OUT/${name}_$sw.$p" 2>/dev/null || true
		done
		# /tmp is a 32 MB tmpfs and each capture is about 5.4 MB, so a sweep of more than
		# five steps fills it. The failure is silent and looks exactly like a capture that
		# had no effect: the last plane comes back zero-length. Free each one once it is off
		# the device.
		au "rm -f /tmp/${name}_$sw.[012]" </dev/null 2>/dev/null || true
		python3 "$HERE/planes2png.py" "$OUT/${name}_$sw" "$OUT/${name}_$sw" || true
	done
	for t in gamma compander drc
	do
		pull "/tmp/pre_$t.bin" "$OUT/pre_$t.bin" 2>/dev/null || true
	done
	# The LSC page as the vendor computed it for this scene. hdf-037 established it has no
	# static source: it is built at runtime from stats, so this capture is the only form of
	# it we can hold, and the open driver carries a captured page rather than generating one.
	if [ "${LSCPOKE:-0}" = 1 ]
	then
		pull "/tmp/lsc_pre.bin" "$OUT/lsc_pre.bin" 2>/dev/null || true
	fi
	# Stage 7b's artifacts. Unconditional: that stage is passive and always runs, so gating
	# these on a poke lever loses them silently, which is how the first run lost both.
	pull "/tmp/rro_raw.bin" "$OUT/rro_raw.bin" 2>/dev/null || true
	pull "/tmp/lut3d.bin" "$OUT/lut3d.bin" 2>/dev/null || true
	pull "/tmp/ltm_page.bin" "$OUT/ltm_page_${SCENE:-a}.bin" 2>/dev/null || true
	if [ "${HDRPOKE:-0}" = 1 ]
	then
		pull "/tmp/gtm2_pre.bin" "$OUT/gtm2_pre.bin" 2>/dev/null || true
	fi
	pull "/tmp/oursensor.txt" "$REPO/out/au-snapshot/ours-sensor-full.txt" 2>/dev/null || true
	# Mid-stream register windows, for the live-against-live diff. Small, so unlike the raw
	# frame this pull is reliable over the RF link.
	pull "/tmp/ourisp.txt" "$REPO/out/au-snapshot/ours-registers-live.txt" 2>/dev/null || true
	if [ -n "${BLOCK3D:-}" ]
	then
		for p in 0 1 2
		do
			pull "/tmp/${name}_b3d.$p" "$OUT/${name}_b3d.$p" 2>/dev/null || true
		done
		au "rm -f /tmp/${name}_b3d.[012]" </dev/null 2>/dev/null || true
		python3 "$HERE/planes2png.py" "$OUT/${name}_b3d" "$OUT/${name}_b3d" || true
		pull "/tmp/ourisp_b3d.txt" "$REPO/out/au-snapshot/ours-registers-live-b3d.txt" 2>/dev/null || true
	fi
	if [ -s "$REPO/out/au-snapshot/ours-registers-live.txt" ]
	then
		echo "  pulled mid-stream registers: $(grep -c '^+0x' "$REPO/out/au-snapshot/ours-registers-live.txt") lines"
	else
		echo "  WARNING: mid-stream register pull came back EMPTY"
	fi
	# The grabber's output would be RAW BAYER from the VIF bypass view (SRGGB12), pre-ISP.
	# Every pull of it so far has come back zero bytes, and it is 4 MB over a flaky RF link,
	# so "empty here" has never distinguished "the view delivered nothing" from "the transfer
	# failed". Record the DEVICE-side size first, which is one line and always survives.
	rawsz=$(au "wc -c < /tmp/f.raw 2>/dev/null || echo -1" </dev/null 2>/dev/null | tr -d ' \r')
	echo "  raw bypass frame, device-side size: ${rawsz:-unknown} bytes"
	pull "/tmp/f.raw" "$OUT/$name-raw.bayer" 2>/dev/null || true
	if [ "${rawsz:-0}" -gt 0 ] && [ ! -s "$OUT/$name-raw.bayer" ]
	then
		echo "  NOTE: the frame EXISTS on the device but the pull returned nothing."
		echo "        The bypass view is then not dead, and hdf-028's conclusion needs revisiting."
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
	python3 - "$OUT" "$HERE/../isp" <<'PYE'
import importlib.util, os, struct, sys
out, isp = sys.argv[1], sys.argv[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(isp, name + "-codec.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


print("  tuning pages the vendor left resident, before this bring-up:")
for nm, size in (("gamma", 0x4000), ("compander", 0x7800), ("drc", 0x2000)):
    f = os.path.join(out, "pre_" + nm + ".bin")
    if not os.path.exists(f) or os.path.getsize(f) < size:
        print(f"    {nm:<10} missing")
        continue
    data = open(f, "rb").read()[:size]
    if nm == "gamma":
        curves = load("gamma").curves(data)
        mono = [all(c[i] >= c[i - 1] for i in range(1, len(c))) for c in curves]
        print(f"    {nm:<10} page 0 max {max(curves[0]):4d} monotonic {mono[0]}, "
              f"page 1 max {max(curves[1]):4d} monotonic {mono[1]}")
    elif nm == "drc":
        try:
            banks = [load("drc").decode_source_bank(data, b) for b in (0, 0x800)]
            print(f"    {nm:<10} two {len(banks[0])}-sample curves, overlap fields valid")
        except ValueError as err:
            print(f"    {nm:<10} does NOT decode as a DRC page: {err}")
    else:
        words = struct.unpack(f"<{size // 4}I", data)
        print(f"    {nm:<10} {size} bytes, {words.count(0)} zero words "
              f"(no decoder: the generator is not recovered)")
PYE
	python3 "$HERE/planes2png.py" "$OUT/$name" "$OUT/$name" || true
done

echo
echo "=== movement check: two live captures in the same configuration ==="
if [ -s "$OUT/live.0" ] && [ -s "$OUT/live2.0" ]
then
	if cmp -s "$OUT/live.0" "$OUT/live2.0"
	then
		echo "  IDENTICAL -> frames are NOT updating"
	else
		python3 - "$OUT/live.0" "$OUT/live2.0" <<'PYE'
import sys
a=open(sys.argv[1],'rb').read(); b=open(sys.argv[2],'rb').read()
n=min(len(a),len(b))
diff=sum(1 for i in range(0,n,997) if a[i]!=b[i])
print(f"  DIFFER -> frames are updating ({100.0*diff/(n//997+1):.1f}% of sampled bytes changed)")
PYE
	fi
else
	echo "  one of the live captures is missing"
fi

echo
echo "=== switch check: does the image follow the sensor setting? ==="
if [ -s "$OUT/testpattern.0" ] && [ -s "$OUT/live.0" ]
then
	if cmp -s "$OUT/testpattern.0" "$OUT/live.0"
	then
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
