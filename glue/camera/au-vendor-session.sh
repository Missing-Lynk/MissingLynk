#!/usr/bin/env bash
# au-vendor-session.sh - the one-flip vendor capture session.
#
# READ-ONLY on the device: registers, process memory and DRAM are read, nothing is written, no
# module is loaded, no slot is touched. Must run on stock slot A with the vendor camera actually
# STREAMING, which on the air unit means the goggle is powered and the link is up: ar_lowdelay
# runs from boot but leaves the whole pipeline unconfigured until then, and every ISP bank reads
# zero in that state (see the young-boot note in plans/vendor-boot-shopping-list.md).
#
# Stages are independent and selectable, because the air unit auto-powers-off and overheats:
#   1  live AE structures (process heap, maps, exposure table)     no scene requirement
#   2  full register snapshot via au-snapshot-vendor.sh            no scene requirement
#   3  dpc payload banks                                           no scene requirement
#   4  ladder breath (i2c gain+exposure, rnr, blc, lnr, de3d)      run once per light level
#   5  LTM page and statistics buffers, same scene                 no scene requirement
#   6  saturated point: breath plus heap dump                      needs the lens covered
#   7  AE convergence trace                                        needs lens cover then uncover
#
# Stages 1 to 5 are proven by the 2026-08-02 session. Stages 6 and 7 have never run.
#
# Usage: glue/camera/au-vendor-session.sh [stage ...]        default: 1 2 3 5
# Env:   AU_IP (192.168.3.100), AU_PASS (artosyn), TAG (label for stage 4 light levels)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/../lib/ssh-opts.sh"

AU_IP="${AU_IP:-192.168.3.100}"
AU_PASS="${AU_PASS:-artosyn}"
TAG="${TAG:-light1}"
OUT="$REPO/out/au-vendor-session"

au() { sshpass -p "$AU_PASS" ssh "${SSH_OPTS_LEGACY[@]}" root@"$AU_IP" "$@"; }

mkdir -p "$OUT"

echo "=== gate: stock slot A, pipeline actually streaming ==="
KREL="$(au 'uname -r' 2>/dev/null)" || { echo "cannot reach $AU_IP as root/$AU_PASS"; exit 1; }
case "$KREL" in
4.9.*) echo "  kernel $KREL: stock slot A" ;;
*)     echo "  kernel $KREL is not the stock vendor kernel; this must run on slot A"; exit 1 ;;
esac

for t in ml-regdump ml-i2cprobe
do
	sshpass -p "$AU_PASS" ssh "${SSH_OPTS_LEGACY[@]}" root@"$AU_IP" \
		"cat > /tmp/$t; chmod +x /tmp/$t" < "$REPO/native/build/$t" || {
		echo "  cannot stage $t"; exit 1; }
done

# The frame counter is the only honest liveness signal: ar_lowdelay runs whether or not the
# sensor is delivering, and a zero bank is indistinguishable from a bad read without it.
FC0="$(au '/tmp/ml-regdump 0x088701f8 1' 2>/dev/null | awk 'NR==1{print $2}')"
sleep 2
FC1="$(au '/tmp/ml-regdump 0x088701f8 1' 2>/dev/null | awk 'NR==1{print $2}')"
if [ "0x${FC0:-0}" = "0x${FC1:-0}" ]
then
	echo "  VIF frame counter is not advancing ($FC0 -> $FC1): the pipeline is NOT streaming."
	echo "  Power the goggle and bring the link up, then re-run. Nothing read."
	exit 1
fi
echo "  frame counter $FC0 -> $FC1: streaming"

PID="$(au 'ps | grep -v grep | grep ar_lowdelay' 2>/dev/null | awk '{print $1}')"
echo "  ar_lowdelay pid $PID"

STAGES="${*:-1 2 3 5}"
echo "  stages: $STAGES"
echo

run_stage() {
case "$1" in

1)
	echo "=== stage 1: live AE structures ==="
	# The AE algorithm object, its 0x9680 state block (holding the generated exposure table at
	# +0x68 with the count at +4) and the 85080-byte algorithm input are all bfm_malloc'd, so
	# they live in the process heap. Take the whole heap; offsets are resolved off-device.
	au "cat /proc/$PID/maps" > "$OUT/maps-live.txt"
	HEAP="$(awk '/\[heap\]/{split($1,a,"-"); print a[1], a[2]}' "$OUT/maps-live.txt")"
	# shellcheck disable=SC2086  # word splitting is the point: base and limit into $1 and $2.
	set -- $HEAP
	SKIP=$(( 0x$1 / 4096 ))
	CNT=$(( (0x$2 - 0x$1) / 4096 ))
	echo "  heap 0x$1-0x$2, $CNT pages"
	au "dd if=/proc/$PID/mem bs=4096 skip=$SKIP count=$CNT 2>/dev/null" > "$OUT/heap-live.bin"
	ls -l "$OUT/heap-live.bin"
	;;

2)
	echo "=== stage 2: full register snapshot ==="
	bash "$HERE/au-snapshot-vendor.sh" > "$OUT/snapshot-live.log" 2>&1
	tail -3 "$OUT/snapshot-live.log"
	;;

3)
	echo "=== stage 3: dpc payload banks ==="
	# hdf-061: the thresholds are bytes inside a register image isp_memcpy'd into the bank head,
	# plus a defect LUT of up to 2239 words. Read both generously rather than the 20 words the
	# old capture took.
	au '/tmp/ml-regdump 0x08c00c00 128; echo "--- lut"; /tmp/ml-regdump 0x08c00e00 128' \
		> "$OUT/dpc-banks.txt" 2>&1
	head -5 "$OUT/dpc-banks.txt"
	;;

4)
	echo "=== stage 4: ladder breath, tag $TAG ==="
	# One breath, nothing in between: the abscissa solve needs every stage read at the same
	# operating point. Two runs at light levels far enough apart to land in different bands.
	# shellcheck disable=SC2016  # expansion happens in the device shell, not this one.
	au 'I=/tmp/ml-i2cprobe; R=/tmp/ml-regdump
	echo "--- sensor exposure 0x0202"; $I 0 0x1a 0x0202 -n 4
	echo "--- sensor gain 0x0205";     $I 0 0x1a 0x0205 -n 4
	echo "--- isp rnr 0x1808";         $R 0x08c01808 16
	echo "--- cvisp blc 0x4200";       $R 0x08e04200 32
	echo "--- isp lnr 0x3cc8";         $R 0x08c03cc8 88
	echo "--- isp de3d 0x2e00";        $R 0x08c02e00 56' > "$OUT/breath-$TAG.txt" 2>&1
	grep -A2 "sensor gain" "$OUT/breath-$TAG.txt" | head -4
	echo "  wrote $OUT/breath-$TAG.txt"
	;;

5)
	echo "=== stage 5: LTM page, LSC region B, statistics, same scene ==="
	# The DMA page addresses are in the ISP's own registers; read the register, then the DRAM it
	# points at. Pairing each page with the statistics of the SAME frame is what makes these
	# oracles rather than snapshots.
	# shellcheck disable=SC2016  # expansion happens in the device shell, not this one.
	au 'R=/tmp/ml-regdump
	echo "--- ltm page ptr 0x2808";  $R 0x08c02808 2
	echo "--- lsc page ptr 0x4c34";  $R 0x08c04c34 4
	echo "--- rro_stats 0x6400";     $R 0x08c06400 64
	echo "--- rgb_hist 0x5c00";      $R 0x08c05c00 64
	echo "--- raw_hist 0x6000";      $R 0x08c06000 64
	echo "--- awbs 0x6c00";          $R 0x08c06c00 64' > "$OUT/pages-and-stats.txt" 2>&1
	head -4 "$OUT/pages-and-stats.txt"
	;;

6)
	echo "=== stage 6: AE saturated point, lens COVERED and held ==="
	# The third abscissa point. At full cover the AE saturates (gain code 0x5f observed), which
	# is the operating point the older vendor captures were taken at, so this is what makes the
	# old and new capture sets directly comparable.
	# shellcheck disable=SC2016  # expansion happens in the device shell, not this one.
	au 'I=/tmp/ml-i2cprobe; R=/tmp/ml-regdump
	echo "--- sensor exposure 0x0202"; $I 0 0x1a 0x0202 -n 4
	echo "--- sensor gain 0x0205";     $I 0 0x1a 0x0205 -n 4
	echo "--- isp rnr 0x1808";         $R 0x08c01808 16
	echo "--- cvisp blc 0x4200";       $R 0x08e04200 32
	echo "--- isp lnr 0x3cc8";         $R 0x08c03cc8 88
	echo "--- isp de3d 0x2e00";        $R 0x08c02e00 56' > "$OUT/breath-covered.txt" 2>&1
	SKIP=$(( 0x50c000 / 4096 ))
	CNT=$(( (0x1b90000 - 0x50c000) / 4096 ))
	au "dd if=/proc/$PID/mem bs=4096 skip=$SKIP count=$CNT 2>/dev/null" > "$OUT/heap-covered.bin"
	ls -l "$OUT/heap-covered.bin"
	;;

7)
	echo "=== stage 7: AE convergence trace, 90 s ==="
	echo "  Keep the lens COVERED now. UNCOVER it when this prints 'UNCOVER NOW'."
	# The only capture that pins the control-law dynamics as measurement rather than
	# disassembly: damping, step limit, settle behaviour and decision cadence all fall out of
	# how gain and exposure move between two steady states.
	#
	# Two earlier attempts were lost, and both failures are designed out here. The first ran
	# unpaced and burned 400 samples in 5.5 s, recording one steady state before the operator
	# could act. The second paced correctly but had no in-band prompt, so the transition never
	# happened before the battery died. So: pace explicitly, print the cue from inside the run,
	# and write each sample through so a truncated run still yields everything up to the cut.
	{
		# shellcheck disable=SC2016  # expansion happens in the device shell, not this one.
	au 'I=/tmp/ml-i2cprobe; R=/tmp/ml-regdump
		i=0
		while [ $i -lt 180 ]
		do
			if [ $i -eq 40 ]; then echo "MARK uncover"; fi
			echo "t=$(cut -d" " -f1 /proc/uptime)"
			$I 0 0x1a 0x0202 -n 2
			$I 0 0x1a 0x0206 -n 1
			$R 0x08c01808 1
			usleep 500000 2>/dev/null || sleep 1
			i=$((i+1))
		done' &
		AUPID=$!
		sleep 21
		echo "  >>> UNCOVER NOW and point at the light <<<"
		wait $AUPID
	} > "$OUT/converge-trace.txt" 2>&1 &
	TRACE=$!
	sleep 21
	echo "  >>> UNCOVER NOW and point at the light <<<"
	wait $TRACE
	grep -c "^t=" "$OUT/converge-trace.txt"
	;;

*)
	echo "unknown stage $1"
	;;
esac
echo
}

for s in $STAGES
do
	run_stage "$s"
done

echo "=== session output in $OUT ==="
ls -l "$OUT"
