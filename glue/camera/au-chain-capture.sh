#!/usr/bin/env bash
# au-chain-capture.sh - capture the whole capture chain, sensor to ISP, for A/B comparison.
#
#   SLOT=a  glue/camera/au-chain-capture.sh     streaming vendor, slot A, READ ONLY
#   SLOT=b  glue/camera/au-chain-capture.sh     our open stack, slot B
#
# Capture slot A first: it is the reference, and every conclusion about slot B is only as good
# as the baseline it is compared against. Diff with glue/camera/au-chain-diff.py.
#
# Slot A is strictly read only. Nothing is written to the device, no module is loaded, no slot
# is touched. The only device-side files are two static tools and the output, all under /tmp.
#
# Slot B applies the CGU prologue and reloads the capture modules first, because the drivers
# latch their clock leaf settings at probe: a prologue applied after probe leaves the VIF front
# end dead (0x1f0 reads 0) and the whole capture is then worthless.
#
# Every VIF read happens inside the capture window. VIF reads with the AXI clock gated
# hard-hang the SoC into a watchdog reset to slot A.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/au-camera.sh"

# Slot B's address comes from the device profile, slot A's from au_stock_slot_a.
SLOT="${SLOT:-a}"
case "$SLOT" in
	a) au_stock_slot_a; TAG=slotA ;;
	b) TAG=slotB ;;
	*) echo "SLOT must be a or b" >&2; exit 1 ;;
esac

OUT="${OUT:-$REPO/out/au-chain}"
mkdir -p "$OUT"
DST="$OUT/$TAG.txt"
KD="$REPO/kernel/build/kernel-repro-6.18.36/linux/drivers/media/artosyn"
ISP_PAGES="00 08 0c 18 1c 1d 1e 1f 28 2e 30 34 38 3c 3d 48 4c 50 58 60 64 65 6c 6d 70 72 74 75 76"

echo "=== $TAG at $DEVICE_IP ==="
sshg 'cat /proc/uptime; uname -r'

echo "=== staging read tools ==="
device_push "$REPO/native/build/ml-regdump"
device_push "$REPO/native/build/ml-i2cprobe"
device_push_as "$HERE/nt99235-regs.list" /tmp/sns.list

if [ "$SLOT" = b ]; then
	echo "=== slot B: CGU prologue, then a fresh module load ==="
	device_push "$KD/nt99235.ko"
	device_push "$KD/ar-csi2.ko"
	device_push "$KD/ar-vif.ko"
	device_push "$KD/ar-isp.ko"
	device_push "$REPO/native/build/ml-v4l2grab"
	# One at a time and in dependency order: busybox rmmod aborts the whole command on the
	# first name it cannot remove, and ar_isp is not loaded at boot. A failed rmmod leaves the
	# modules probed, so the CGU prologue lands after probe and the front end comes up dead.
	sshg "for m in ar_isp ar_vif ar_csi2 nt99235; do rmmod \$m 2>/dev/null || true; done"
	sshg "lsmod | grep -qE '^(ar_vif|ar_csi2|nt99235) ' && { echo 'ABORT: capture modules still loaded'; exit 1; } || true"
	sshg "true
	    /tmp/ml-regdump -w 0x0a10400c 0x13001300 >/dev/null
	    V=\$(/tmp/ml-regdump 0x0a104010 4 | awk '{print \$2}')
	    /tmp/ml-regdump -w 0x0a104010 \$(printf '0x%08x' \$(( (0x\$V & 0xffff0000) | 0x1300 ))) >/dev/null
	    P=\$(/tmp/ml-regdump 0x0a104020 4 | awk '{print \$2}')
	    /tmp/ml-regdump -w 0x0a104020 \$(printf '0x%08x' \$(( (0x\$P & 0xffff0000) | 0x1103 ))) >/dev/null
	    insmod /tmp/nt99235.ko; insmod /tmp/ar-csi2.ko; insmod /tmp/ar-vif.ko; insmod /tmp/ar-isp.ko
	    sleep 1; ls -l /dev/video2 >/dev/null"
fi

# The capture runs entirely on the device and writes a file there, so a dropped ssh session
# truncates nothing. Only the finished file is fetched.
sshg "cat > /tmp/cap.sh <<'EOS'
#!/bin/sh
OUT=/tmp/cap.txt
: > \$OUT

if [ '$SLOT' = b ]; then
  /tmp/ml-v4l2grab -d /dev/video2 -o /tmp/f.raw -n 400 -t 120 >/tmp/g.out 2>&1 &
  echo \$! > /tmp/grab.pid
  sleep 3
  kill -0 \$(cat /tmp/grab.pid) 2>/dev/null || { echo 'ABORT: grab died'; exit 1; }
  echo 1 > /sys/kernel/debug/ar-isp/configure
  sleep 1
fi

# Front-end gate first and last: it must read 0x0784043c for the capture to mean anything.
echo \"GATE-BEFORE \$(/tmp/ml-regdump 0x088701f0 1 | cut -d' ' -f2)\" >> \$OUT

echo 'SECTION sensor' >> \$OUT
while read r; do
  [ -n \"\$r\" ] || continue
  echo \"\$r \$(/tmp/ml-i2cprobe 0 0x1a \$r 2>/dev/null | tail -1)\" >> \$OUT
done < /tmp/sns.list

echo 'SECTION vif' >> \$OUT
/tmp/ml-regdump 0x08870000 256 >> \$OUT

echo 'SECTION csi-wrapper' >> \$OUT
/tmp/ml-regdump 0x08880000 64 >> \$OUT
echo 'SECTION csi-core0' >> \$OUT
/tmp/ml-regdump 0x08880400 128 >> \$OUT
echo 'SECTION csi-core1' >> \$OUT
/tmp/ml-regdump 0x08880800 128 >> \$OUT

for p in $ISP_PAGES; do
  echo \"SECTION isp-\$p\" >> \$OUT
  /tmp/ml-regdump 0x08c0\${p}00 64 >> \$OUT
done

echo \"GATE-AFTER \$(/tmp/ml-regdump 0x088701f0 1 | cut -d' ' -f2)\" >> \$OUT

if [ '$SLOT' = b ]; then
  kill \$(cat /tmp/grab.pid) 2>/dev/null || true
fi
echo CAPTURE-DONE
EOS
chmod +x /tmp/cap.sh; /tmp/cap.sh"

device_pull /tmp/cap.txt "$DST"

echo
grep -E '^GATE-' "$DST" || true
echo "sections: $(grep -c '^SECTION' "$DST")   lines: $(wc -l < "$DST")"
echo "saved: $DST"
if ! grep -q 'GATE-BEFORE 0784043c' "$DST"; then
	echo
	echo "WARNING: the VIF front end was not measuring incoming video during this capture."
	echo "The link was not delivering, so nothing downstream of it can be interpreted."
fi
