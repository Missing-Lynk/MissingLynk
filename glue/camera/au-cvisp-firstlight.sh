#!/usr/bin/env bash
# au-cvisp-firstlight.sh - does CVISP write frames to DRAM?
#
# CVISP is the block at 0x08e00000. In the vendor's design it, not the ISP, is what writes
# frames out, which is why an ISP configured to match the vendor register for register,
# demonstrably receiving pixels, still produced nothing. We have never written one of its
# registers.
#
# The experiment: bring the capture chain up as usual, configure the ISP as usual, then
# configure CVISP from the recovered tables and watch its output ring. The setup table ends
# with the vendor's staged enable and leaves ring set 0 armed, so a first frame needs no
# rotation.
#
# TWO HAZARDS, both deliberate and both worth reading before running this.
#
# 1. The clock. cgu_rsz_clk is identified from the vendor clock table, not from the trace,
#    which contains no CGU write for this block. If it is the wrong leaf, the first register
#    access hangs the SoC into a watchdog reset back to slot A, exactly as gated VIF reads
#    do. That is why the driver reads nothing at probe and why step 4 below reads `regs`
#    on its own, before anything else, as a deliberate first touch. If the session dies
#    there, the clock is the answer and the run cost nothing else.
#
# 2. The buffers. The ring covers 0x28014000..0x2902c000, which the DTB now reserves no-map
#    as cvisp_cma. vif_cma MOVED to 0x2c000000 to make room. Running this against an older
#    DTB points a DMA writer at live kernel memory.
#
# Run 2 is the control: same everything, CVISP left alone. Markers surviving in run 2 and
# gone in run 1 is CVISP writing, and is first light.
#
# Usage: glue/camera/au-cvisp-firstlight.sh
# Env: AU_IP (192.168.3.102), AU_PASS (libre), BULK (1475), WATCH (10).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/ssh-opts.sh"

AU_IP="${AU_IP:-192.168.3.102}"
AU_PASS="${AU_PASS:-libre}"
BULK="${BULK:-1475}"
WATCH="${WATCH:-10}"
KD="$REPO/kernel/build/kernel-repro-6.18.36/linux/drivers/media/artosyn"

# Ring set 0, from ar_cvisp_ring[0] in ar-cvisp-defaults.h.
PY=0x28014000
PU=0x28232000
PV=0x282bb000

au()   { sshpass -p "$AU_PASS" ssh "${SSH_OPTS_LEGACY[@]}" root@"$AU_IP" "$@"; }
push() { sshpass -p "$AU_PASS" ssh "${SSH_OPTS_LEGACY[@]}" root@"$AU_IP" \
	         "cat > /tmp/$2; chmod +x /tmp/$2" < "$1"; }

echo "=== staging (tmpfs is wiped by every power cycle) ==="
for m in nt99235 ar-csi2 ar-vif ar-isp ar-cvisp; do push "$KD/$m.ko" "$m.ko"; done
push "$REPO/native/build/ml-regdump"  ml-regdump
push "$REPO/native/build/ml-v4l2grab" ml-v4l2grab
push "$REPO/native/build/ml-isploop"  ml-isploop
au 'cd /tmp && md5sum ar-cvisp.ko ml-isploop | cut -c1-12'

# Confirm the running DTB has the reservation before pointing a DMA writer at it.
echo "=== reserved ranges on the device ==="
au 'ls /proc/device-tree/reserved-memory/ 2>/dev/null | tr "\n" " "; echo'

au "cat > /tmp/cvisp.sh <<'EOS'
#!/bin/sh
# \$1 = mode: cvisp | control
R=/tmp/ml-regdump
MODE=\$1

for m in ar_cvisp ar_isp ar_vif ar_csi2 nt99235; do rmmod \$m 2>/dev/null || true; done

# Measured vendor CGU state. The last two are the gates we had been missing; the PLL pair
# (0x0a108098 / 0x0a108410) is deliberately NOT copied, it removes the frame starts.
\$R -w 0x0a10400c 0x13001300 >/dev/null
\$R -w 0x0a104010 0x02001300 >/dev/null
\$R -w 0x0a104020 0x10001103 >/dev/null
\$R -w 0x0a10401c 0x02011201 >/dev/null
\$R -w 0x0a104044 0x01001000 >/dev/null

insmod /tmp/nt99235.ko
insmod /tmp/ar-csi2.ko
insmod /tmp/ar-vif.ko
insmod /tmp/ar-isp.ko
insmod /tmp/ar-cvisp.ko
sleep 1

# [4] First deliberate touch of the block. If cgu_rsz_clk is the wrong leaf, the SoC hangs
# here and the watchdog takes it back to slot A. Nothing after this line runs, which is the
# point: the failure is unambiguous and cheap.
echo '  [4] first CVISP register read'
cat /sys/kernel/debug/ar-cvisp/regs
echo '      survived, clock leaf is right'

echo '  [5] receiver live'
/tmp/ml-v4l2grab -d /dev/video2 -o /tmp/f.raw -n 3000 -t 300 >/tmp/g.out 2>&1 &
G=\$!
sleep 3

echo '  [6] ISP configure'
echo $BULK > /sys/kernel/debug/ar-isp/configure_upto
echo 1 > /sys/kernel/debug/ar-isp/arm
sleep 2

if [ \"\$MODE\" = cvisp ]; then
	echo '  [7] CVISP configure (setup + late)'
	echo 1 > /sys/kernel/debug/ar-cvisp/configure
	sleep 1
	cat /sys/kernel/debug/ar-cvisp/regs
else
	echo '  [7] control: CVISP left unconfigured'
fi

# Markers go on CVISP ring set 0, NOT the ISP planes. The default addresses in ml-isploop
# are the ISP's and are the wrong target here.
/tmp/ml-isploop $WATCH --no-cycle --plane $PY --plane $PU --plane $PV
kill \$G 2>/dev/null
EOS
chmod +x /tmp/cvisp.sh"

for mode in cvisp control; do
	echo
	echo "############ $mode ############"
	au "/tmp/cvisp.sh $mode"
done

echo
echo ">>> markers overwritten under 'cvisp' but intact under 'control' is CVISP writing frames."
echo ">>> DDR survives a RAM-boot and the vendor's last frame persists, so a marker that was"
echo ">>> never rewritten is the only trustworthy negative. That is what the control run is for."
