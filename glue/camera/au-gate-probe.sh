#!/usr/bin/env bash
# au-gate-probe.sh - read the per-stage gate oracle and the gain-keyed rnr bank on slot B.
#
#   glue/camera/au-gate-probe.sh                 gates only
#   RNR_GAIN=3200 glue/camera/au-gate-probe.sh   also re-latch the ladders at that abscissa
#
# Two questions, one bring-up. The debugfs `gates` node prints every stage's gate register
# beside what the tuning file asks for, which is the parity oracle the gate recovery exists to
# be checked against. The rnr dump answers whether the bank the applier writes lands: the
# ladder at +0x08 and the tail at +0x38 are written by one straight-line block, so a run where
# only one of them arrives is a fact about the hardware and not about the packer.
#
# Slot B only. The capture modules are reloaded, because the drivers latch their clock leaf
# settings at probe and a CGU prologue applied after probe leaves the VIF front end dead.
#
# The stream has to be running before the ISP is configured: the block reports its measured
# input geometry only while the receiver delivers, and the gate registers of a stage that never
# saw a frame read zero either way, which is exactly the reading that cannot be interpreted.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/au-camera.sh"

OUT="${OUT:-$REPO/out/au-gates}"
mkdir -p "$OUT"
KD="$REPO/kernel/build/kernel-repro-6.18.36/linux/drivers/media/artosyn"
RNR_GAIN="${RNR_GAIN:-}"

echo "=== slot B at $DEVICE_IP ==="
sshg 'cat /proc/uptime; uname -r'

echo "=== staging ==="
device_push "$REPO/native/build/ml-regdump"
device_push "$REPO/native/build/ml-v4l2grab"
for m in nt99235 ar-csi2 ar-vif ar-isp ar-cvisp; do
	device_push "$KD/$m.ko"
done

# ar_cvisp first: it holds a reference on ar_isp, so with it loaded the rmmod of ar_isp fails
# and the probe runs against the module already on the device.
echo "=== reload with the CGU prologue ==="
sshg "for m in ar_cvisp ar_isp ar_vif ar_csi2 nt99235; do rmmod \$m 2>/dev/null || true; done"
sshg "lsmod | grep -qE '^(ar_cvisp|ar_isp|ar_vif|ar_csi2|nt99235) ' && { echo 'ABORT: capture modules still loaded'; exit 1; } || true"
sshg "true
    /tmp/ml-regdump -w 0x0a10400c 0x13001300 >/dev/null
    V=\$(/tmp/ml-regdump 0x0a104010 4 | awk '{print \$2}')
    /tmp/ml-regdump -w 0x0a104010 \$(printf '0x%08x' \$(( (0x\$V & 0xffff0000) | 0x1300 ))) >/dev/null
    P=\$(/tmp/ml-regdump 0x0a104020 4 | awk '{print \$2}')
    /tmp/ml-regdump -w 0x0a104020 \$(printf '0x%08x' \$(( (0x\$P & 0xffff0000) | 0x1103 ))) >/dev/null
    insmod /tmp/nt99235.ko; insmod /tmp/ar-csi2.ko; insmod /tmp/ar-vif.ko; insmod /tmp/ar-isp.ko
    insmod /tmp/ar-cvisp.ko
    sleep 1"

sshg "test -e /sys/kernel/debug/ar-isp/gates || { echo 'ABORT: no gates node, the deployed ar-isp.ko predates it'; exit 1; }"

sshg "cat > /tmp/probe.sh <<'EOS'
#!/bin/sh
# The capture node number is not fixed: a fresh module load can put wave5-enc where cvisp was.
VID=\$(dmesg | sed -n 's/.*cvisp.*capture on video\([0-9]*\).*/\1/p' | tail -1)
[ -n \"\$VID\" ] || { echo 'ABORT: no cvisp capture node announced in dmesg'; exit 1; }

/tmp/ml-v4l2grab -d /dev/video\$VID -o /tmp/f.raw -n 400 -t 120 >/tmp/g.out 2>&1 &
echo \$! > /tmp/grab.pid
sleep 3
kill -0 \$(cat /tmp/grab.pid) 2>/dev/null || { echo 'ABORT: grab died'; head -3 /tmp/g.out; exit 1; }

echo 1 > /sys/kernel/debug/ar-isp/configure
sleep 1

echo \"GATE-FRONTEND \$(/tmp/ml-regdump 0x088701f0 1 | cut -d' ' -f2)\"

echo 'SECTION gates'
cat /sys/kernel/debug/ar-isp/gates

if [ -n '$RNR_GAIN' ]; then
  echo 'SECTION rnr-before'
  echo \"ladder 0x1808\"; /tmp/ml-regdump 0x08c01808 12
  echo \"tail   0x1838\"; /tmp/ml-regdump 0x08c01838 22

  echo '$RNR_GAIN' > /sys/module/ar_isp/parameters/rnr_gain
  echo 1 > /sys/kernel/debug/ar-isp/ladders

  echo 'SECTION rnr-after'
  echo \"ladder 0x1808\"; /tmp/ml-regdump 0x08c01808 12
  echo \"tail   0x1838\"; /tmp/ml-regdump 0x08c01838 22
fi

kill \$(cat /tmp/grab.pid) 2>/dev/null || true
echo PROBE-DONE
EOS
chmod +x /tmp/probe.sh; /tmp/probe.sh" | tee "$OUT/probe.txt"

echo
echo "saved: $OUT/probe.txt"
