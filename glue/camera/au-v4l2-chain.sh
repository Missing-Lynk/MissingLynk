#!/usr/bin/env bash
# au-v4l2-chain.sh - open the CVISP capture node and nothing else.
#
# The camera stack is brought up by writing debugfs in a fixed order: start the sensor and the
# VIF input path, arm the ISP, configure CVISP, then read frames. au-prove-camera.sh does that,
# and everything measured so far has gone through it. This script tests the opposite: load the
# modules and open the video node, with nothing driving debugfs at all. STREAMON is expected to
# bring the whole chain up on its own, which is what a stock v4l2src needs.
#
# Deliberately separate from au-prove-camera.sh rather than a mode inside it. That script gates
# every stage against a half-bound pipeline because VIF reads with a dead pixel domain hard-hang
# the SoC; those gates read debugfs and drive the chain themselves, which is exactly what is
# being removed here. Keeping the two apart leaves the proven path untouched when this one is
# wrong.
#
# Failure here is cheap: the modules load, the open fails or the grabber times out, and nothing
# has touched VIF or the ISP outside the driver's own ordered sequence.
#
# Usage: glue/camera/au-v4l2-chain.sh
# Env: AU_IP, AU_PASS, FRAMES (200), EXPO, GAIN
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/ssh-opts.sh"

AU_IP="${AU_IP:-192.168.3.102}"
AU_PASS="${AU_PASS:-libre}"
EXPO="${EXPO:-1123}"
GAIN="${GAIN:-0x2f}"
FRAMES="${FRAMES:-200}"
KD="$REPO/kernel/build/kernel-repro-6.18.36/ml-modules/rootfs/lib/modules/6.18.36/kernel"
OUT="$REPO/out/au-prove"

au()   { sshpass -p "$AU_PASS" ssh "${SSH_OPTS_LEGACY[@]}" root@"$AU_IP" "$@"; }
push() { sshpass -p "$AU_PASS" ssh "${SSH_OPTS_LEGACY[@]}" root@"$AU_IP" \
	         "cat > /tmp/$2; chmod +x /tmp/$2" < "$1"; }
pull() {
	if sshpass -p "$AU_PASS" ssh "${SSH_OPTS_LEGACY[@]}" root@"$AU_IP" "cat '$1'" > "$2.part" 2>/dev/null &&
	   [ -s "$2.part" ]
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
push "$REPO/native/build/ml-v4l2grab" ml-v4l2grab || exit 1
push "$REPO/native/build/ml-regdump" ml-regdump || exit 1

# The vendor tuning file, verbatim. ar-isp generates its gamma and DRC pages from it.
TUNING="${TUNING:-$REPO/out/air-gather/vendor-root/usr/usrdata/tunning/nt99235_tuning_preview_fpv.bin}"
if [ -s "$TUNING" ]
then
	push "$TUNING" "nt99235-tuning-preview-fpv.bin" || exit 1
else
	echo "  no tuning file at $TUNING: ar-isp will seed, not generate"
fi

REMOTE="#!/bin/sh
set -u
fail() { echo \"FAILED: \$1\"; exit 1; }

# Same load order the proven harness uses: it is the order the media graph was shown to bind in.
for m in ar-cvisp ar-isp ar-vif ar-csi2 nt99235
do
	rmmod \$m 2>/dev/null
done

# The camera CGU leaves, exactly as au-prove-camera.sh stage 1b writes them.
#
# These do NOT belong here. Each write sets a leaf's parent mux at bits[10:8] as well as its
# gate at bit12, and clk-ar9311-cgu registers the camera leaves gate-only, so
# clk_prepare_enable in the drivers sets the gate and leaves the mux at whatever the boot left.
# Without the mux the ISP and VIF clocks run from the wrong parent: their registers read back
# zero and no frame ever starts, which looks like a dead sensor.
#
# So this is a placeholder for making the leaves' parent mux settable and naming the parents in
# the device tree, after which the clock framework programs them at probe and this goes away.
# It is reproduced here so the rest of the self bring-up can be tested meanwhile.
G=\$(/tmp/ml-regdump 0x0a104014 1 | cut -d' ' -f2)
case \$G in
*[13579bdf]???) : ;;
*) fail \"cgu 0x0a104014=\$G, gate bit12 is CLEAR\" ;;
esac
/tmp/ml-regdump -w 0x0a10400c 0x13001300 >/dev/null || fail 'cgu 0x0a10400c'
/tmp/ml-regdump -w 0x0a104010 0x02001300 >/dev/null || fail 'cgu 0x0a104010'
/tmp/ml-regdump -w 0x0a104020 0x10001103 >/dev/null || fail 'cgu 0x0a104020'
/tmp/ml-regdump -w 0x0a10401c 0x02011201 >/dev/null || fail 'cgu 0x0a10401c'
/tmp/ml-regdump -w 0x0a104044 0x01001000 >/dev/null || fail 'cgu 0x0a104044'
echo '  camera clocks programmed (harness stage 1b, see comment)'

mkdir -p /tmp/fw/artosyn
[ -f /tmp/nt99235-tuning-preview-fpv.bin ] && \\
	cp /tmp/nt99235-tuning-preview-fpv.bin /tmp/fw/artosyn/
echo -n /tmp/fw > /sys/module/firmware_class/parameters/path 2>/dev/null

insmod /tmp/nt99235.ko exposure=$EXPO gain=$GAIN || fail 'insmod nt99235'
insmod /tmp/ar-csi2.ko || fail 'insmod ar-csi2'
insmod /tmp/ar-vif.ko || fail 'insmod ar-vif'
insmod /tmp/ar-isp.ko || fail 'insmod ar-isp'
insmod /tmp/ar-cvisp.ko || fail 'insmod ar-cvisp'
sleep 1
echo '  modules loaded'

# Nothing below writes debugfs. If the chain does not come up, it is the driver's doing.
NODE=''
for d in /sys/class/video4linux/video*
do
	[ -r \"\$d/name\" ] || continue
	if [ \"\$(cat \$d/name)\" = 'ar-cvisp' ]
	then
		NODE=/dev/\$(basename \$d)
		break
	fi
done
[ -n \"\$NODE\" ] || fail 'no video node named ar-cvisp'
echo \"  capture node \$NODE\"

# Rate first, contents second. -q returns buffers without a CPU pass over them, which is what a
# consumer importing the dmabuf does; reading them costs more than a frame period because these
# buffers are uncached.
if /tmp/ml-v4l2grab -d \$NODE -q -n $FRAMES -t 10 >/tmp/c1.out 2>&1
then
	grep -E 'interface|allocated|current|delivered' /tmp/c1.out | sed 's/^/    /'
	echo '  rate pass ok'
else
	echo '  rate pass FAILED'
	cat /tmp/c1.out
fi

rm -f /tmp/chain.0 /tmp/chain.1 /tmp/chain.2
if /tmp/ml-v4l2grab -d \$NODE -o /tmp/chain -n 4 -t 10 >/tmp/c2.out 2>&1
then
	grep -E 'frame |wrote|delivered' /tmp/c2.out | sed 's/^/    /'
	echo '  capture ok'
else
	echo '  capture FAILED'
	cat /tmp/c2.out
fi

for c in rotations completions drops
do
	[ -r /sys/kernel/debug/ar-cvisp/\$c ] && echo \"    cvisp \$c: \$(cat /sys/kernel/debug/ar-cvisp/\$c)\"
done
[ -r /sys/kernel/debug/ar-vif/irq_events ] && \\
	echo \"    vif irq_events: \$(cat /sys/kernel/debug/ar-vif/irq_events)\"
[ -r /sys/kernel/debug/ar-isp/irq_stats_events ] && \\
	echo \"    isp stats-events: \$(cat /sys/kernel/debug/ar-isp/irq_stats_events)\"

echo '  --- driver log ---'
dmesg | grep -iE 'ar-cvisp|ar-vif|ar-isp|nt99235' | tail -25
exit 0
"

echo
echo "=== self bring-up: modules only, no debugfs ==="
printf '%s\n' "$REMOTE" | au 'cat > /tmp/chain.sh; chmod +x /tmp/chain.sh' || exit 1
au '/tmp/chain.sh'

echo
echo "=== rendering ==="
for p in 0 1 2
do
	pull "/tmp/chain.$p" "$OUT/chain.$p" || echo "  no plane $p"
done
au 'rm -f /tmp/chain.0 /tmp/chain.1 /tmp/chain.2' </dev/null 2>/dev/null || true
python3 "$HERE/planes2png.py" "$OUT/chain" "$OUT/chain" || true
