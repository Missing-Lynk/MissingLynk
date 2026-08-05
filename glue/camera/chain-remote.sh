#!/bin/sh
# chain-remote.sh - the device half of au-v4l2-chain.sh, staged to /tmp/chain.sh and run there.
#
# Loads the camera modules and opens the CVISP capture node, with nothing driving debugfs, so
# STREAMON has to bring the whole chain up on its own. That is what a stock v4l2src needs.
#
# Every knob arrives as an environment variable set by the host at invocation:
#   EXPO GAIN            sensor exposure and analogue gain
#   DE3D_GAIN LNR_GAIN RNR_GAIN   ISP ladder abscissas, Q8
#   CVDEPTH              ar-cvisp ring depth; EMPTY means pass no depth= at all, so the run
#                        tests the driver's own default
#   FRAMES               how many frames the grabber asks for
set -u
fail() { echo "FAILED: $1"; exit 1; }

# Same load order the proven harness uses: it is the order the media graph was shown to bind in.
for m in ar-cvisp ar-isp ar-vif ar-csi2 nt99235; do
	rmmod $m 2>/dev/null
done

# The camera CGU leaves.
#
# These do NOT belong here. Each leaf carries a parent mux and a gate in one register half, and
# clk-ar9311-cgu registers the camera leaves gate-only, so clk_prepare_enable sets the gate and
# leaves the mux where the boot left it. The ISP and VIF then run from the wrong parent: their
# registers read back zero and no frame ever starts, which looks like a dead sensor.
#
# Two ways of writing them, because which one works decides how the driver should do it.
#
# rmw, the default, rewrites ONLY the fields the clock driver models: sel and gate, one
# read-modify-write per half, which is exactly what clk_set_parent and clk_prepare_enable would
# emit. If the chain comes up under this, the driver can own the clocks with no device tree
# change and no reflash.
#
# full writes the whole register with the literal values au-prove-camera.sh stage 1b uses.
# Those carry bits the driver's model does not describe, bits[6:0] on the two MIPI leaves, and
# the header states these leaves have no dividers. Dumping the registers before either write
# says whether the boot already sets those bits, in which case rmw preserves them anyway.
# none, the default, writes nothing: clk-ar9311-cgu installs the vendor's parent and divider
# for the camera leaves at probe, on a board that declares a camera. The other two modes are
# kept for bisecting that against what the harness used to do by hand.
CGU_MODE=${CGU_MODE:-none}

G=$(/tmp/ml-regdump 0x0a104014 1 | cut -d' ' -f2)
case $G in
*[13579bdf]???) : ;;
*) fail "cgu 0x0a104014=$G, gate bit12 is CLEAR" ;;
esac

# Read before anything here writes, which on a kernel that owns these is AFTER clk-ar9311-cgu
# installed the vendor pairs at probe. Under CGU_MODE=none the six leaves should already read
# the vendor's sel and divider with their gates still off, the consumers having gated their own.
echo '  cgu leaves before this script writes:'
for a in 0x0a10400c 0x0a104010 0x0a10401c 0x0a104020 0x0a104044; do
	echo "    $a $(/tmp/ml-regdump $a 1 | awk '/^\+/{print $2}')"
done

# Clear both halves' sel and gate, leave every other bit as found.
CGU_FIELDS=0x17001700

cgu_rmw() {
	cur=$(/tmp/ml-regdump "$1" 1 | awk '/^\+/{print $2}')
	[ -n "$cur" ] || fail "cgu read $1"
	new=$(printf '%08x' $(( (0x$cur & ~CGU_FIELDS) | $2 )))
	/tmp/ml-regdump -w "$1" 0x"$new" >/dev/null || fail "cgu write $1"
}

if [ "$CGU_MODE" = none ]; then
	:
elif [ "$CGU_MODE" = full ]; then
	/tmp/ml-regdump -w 0x0a10400c 0x13001300 >/dev/null || fail 'cgu 0x0a10400c'
	/tmp/ml-regdump -w 0x0a104010 0x02001300 >/dev/null || fail 'cgu 0x0a104010'
	/tmp/ml-regdump -w 0x0a104020 0x10001103 >/dev/null || fail 'cgu 0x0a104020'
	/tmp/ml-regdump -w 0x0a10401c 0x02011201 >/dev/null || fail 'cgu 0x0a10401c'
	/tmp/ml-regdump -w 0x0a104044 0x01001000 >/dev/null || fail 'cgu 0x0a104044'
else
	cgu_rmw 0x0a10400c 0x13001300	# isp sel 3 gate on, isp_hdr sel 3 gate on
	cgu_rmw 0x0a104010 0x02001300	# vif_axi sel 3 gate on, dla sel 2 gate off
	cgu_rmw 0x0a104020 0x10001100	# mipi_pcs sel 1 gate on, sd0_fix sel 0 gate on
	cgu_rmw 0x0a10401c 0x02001200	# mipi_csi_0 sel 2 gate on, mipi_csi_1 sel 2 gate off
	cgu_rmw 0x0a104044 0x01001000	# sensor_mclk0 sel 0 gate on, mclk1 sel 1 gate off
fi

echo "  camera clocks programmed ($CGU_MODE):"
for a in 0x0a10400c 0x0a104010 0x0a10401c 0x0a104020 0x0a104044; do
	echo "    $a $(/tmp/ml-regdump $a 1 | awk '/^\+/{print $2}')"
done

mkdir -p /tmp/fw/artosyn
[ -f /tmp/nt99235-tuning-preview-fpv.bin ] && \
	cp /tmp/nt99235-tuning-preview-fpv.bin /tmp/fw/artosyn/
# shellcheck disable=SC3037  # busybox ash, the only shell this runs under, implements echo -n
echo -n /tmp/fw > /sys/module/firmware_class/parameters/path 2>/dev/null

insmod /tmp/nt99235.ko exposure="$EXPO" gain="$GAIN" || fail 'insmod nt99235'
insmod /tmp/ar-csi2.ko || fail 'insmod ar-csi2'
insmod /tmp/ar-vif.ko || fail 'insmod ar-vif'
insmod /tmp/ar-isp.ko de3d_gain="$DE3D_GAIN" lnr_gain="$LNR_GAIN" rnr_gain="$RNR_GAIN" || fail 'insmod ar-isp'
insmod /tmp/ar-cvisp.ko ${CVDEPTH:+depth=$CVDEPTH} || fail 'insmod ar-cvisp'
sleep 1
echo '  modules loaded'

# Nothing below writes debugfs. If the chain does not come up, it is the driver's doing.
NODE=''
for d in /sys/class/video4linux/video*; do
	[ -r "$d/name" ] || continue
	if [ "$(cat "$d"/name)" = 'ar-cvisp' ]; then
		NODE=/dev/$(basename "$d")
		break
	fi
done
[ -n "$NODE" ] || fail 'no video node named ar-cvisp'
echo "  capture node $NODE"

# Rate first, contents second. -q returns buffers without a CPU pass over them, which is what a
# consumer importing the dmabuf does; reading them costs more than a frame period because these
# buffers are uncached.
if /tmp/ml-v4l2grab -d "$NODE" -q -n "$FRAMES" -t 10 >/tmp/c1.out 2>&1; then
	grep -E 'interface|allocated|current|delivered' /tmp/c1.out | sed 's/^/    /'
	echo '  rate pass ok'
else
	echo '  rate pass FAILED'
	cat /tmp/c1.out
fi

rm -f /tmp/chain.0 /tmp/chain.1 /tmp/chain.2
if /tmp/ml-v4l2grab -d "$NODE" -o /tmp/chain -n 4 -t 10 >/tmp/c2.out 2>&1; then
	grep -E 'frame |wrote|delivered' /tmp/c2.out | sed 's/^/    /'
	echo '  capture ok'
else
	echo '  capture FAILED'
	cat /tmp/c2.out
fi

for c in rotations completions drops; do
	[ -r /sys/kernel/debug/ar-cvisp/$c ] && echo "    cvisp $c: $(cat /sys/kernel/debug/ar-cvisp/$c)"
done
[ -r /sys/kernel/debug/ar-vif/irq_events ] && \
	echo "    vif irq_events: $(cat /sys/kernel/debug/ar-vif/irq_events)"
[ -r /sys/kernel/debug/ar-isp/irq_stats_events ] && \
	echo "    isp stats-events: $(cat /sys/kernel/debug/ar-isp/irq_stats_events)"

echo '  --- driver log ---'
dmesg | grep -iE 'ar-cvisp|ar-vif|ar-isp|nt99235' | tail -25
exit 0
