#!/usr/bin/env bash
# au-cvisp-framelock.sh - arm the CVISP ring once per frame, the vendor's actual cadence.
#
# First light is established (au-cvisp-firstlight.sh): CVISP writes YUV planes to DRAM, luma
# 0x01 and both chroma planes 0x7f, against a control run that got nothing on the same
# addresses. What is not established is whether it sustains.
#
# au-cvisp-rotate.sh drove the queue through debugfs in bursts of five and only ever saw slot 1
# written. That test cannot answer the question: `echo 5 > queue` rotates five times in
# microseconds, so slots 2 to 4 were armed and superseded long before a 60 Hz frame could land
# in them, and every burst left slot 0 armed. It cannot distinguish a one-slot hardware queue
# from a missing completion path.
#
# This run arms exactly one slot per VIF frame start, which is what the vendor does, and marks
# slots 1, 2 and 3 so the outcome is unambiguous:
#
#   all three overwritten  -> CVISP sustains, the burst timing was the whole problem
#   only slot 1            -> it genuinely stops after the first armed buffer
#
# If it is the second, the next target is NOT a CVISP register. Codex established that the
# vendor's completion path never touches this register map: cvisp_device_irq_process takes its
# status from an event struct and cvisp_dispatch_irq only walks heap objects. The candidate is
# the generic IRQ service protocol, where the kernel handler disables the IRQ and userspace must
# re-enable it, and a missed re-enable wedges further completions with no register operation at
# all. Do not respond to a stall here by poking status offsets in the 0x08e map: there is no
# safe offset and a wrong read hangs the SoC.
#
# Also pulls the slot 1 luma plane so the picture can be looked at rather than inferred.
#
# Usage: glue/camera/au-cvisp-framelock.sh
# Env: AU_IP (192.168.3.102), AU_PASS (libre), BULK (1475), WATCH (8), TP (0).
#
# TP is the sensor test pattern: 0 off, 2 colour bars. Nothing sets exposure or gain on this
# stack, so a correct capture is black and a black frame cannot be told from a broken one by
# eye. A generated pattern takes the optics and the exposure out of the question. The register
# is inferred from the SMIA map, so the driver reads it back and says whether it took; watch
# for that line rather than judging the image.
#
# Do not copy this script elsewhere to tweak it: HERE/REPO resolve from its own location, so a
# copy outside glue/camera finds no ssh-opts.sh and stages nothing, and the CGU probe then reads
# empty and aborts as though the gate were clear.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/ssh-opts.sh"

AU_IP="${AU_IP:-192.168.3.102}"
AU_PASS="${AU_PASS:-libre}"
BULK="${BULK:-1475}"
WATCH="${WATCH:-8}"
TP="${TP:-0}"
# Extra nt99235 module args, e.g. MODARGS="dump_smia=1" or MODARGS="exposure=..."
MODARGS="${MODARGS:-}"
KD="$REPO/kernel/build/kernel-repro-6.18.36/linux/drivers/media/artosyn"
OUT="$REPO/out/au-cvisp"

# Y planes of ring slots 1, 2, 3. Slot 0 is what setup arms, so it proves nothing about
# sustained operation. Slot 1 goes first so --dump takes it.
# Ring slot 1, all three planes. Comparing Y against U and V is what separates
# "the colour is there and only luma collapsed" from "the data never arrived".
S1=0x2834c000
S2=0x2856a000
S3=0x285f3000

au()   { sshpass -p "$AU_PASS" ssh "${SSH_OPTS_LEGACY[@]}" root@"$AU_IP" "$@"; }
push() { sshpass -p "$AU_PASS" ssh "${SSH_OPTS_LEGACY[@]}" root@"$AU_IP" \
	         "cat > /tmp/$2; chmod +x /tmp/$2" < "$1"; }

mkdir -p "$OUT"

echo "=== staging (tmpfs is wiped by every power cycle) ==="
for m in nt99235 ar-csi2 ar-vif ar-isp ar-cvisp; do push "$KD/$m.ko" "$m.ko"; done
push "$REPO/native/build/ml-regdump" ml-regdump
push "$REPO/native/build/ml-v4l2grab" ml-v4l2grab
push "$REPO/native/build/ml-isploop" ml-isploop
au 'cd /tmp && md5sum ar-cvisp.ko ml-isploop | cut -c1-12'

au "cat > /tmp/fl.sh <<'EOS'
#!/bin/sh
R=/tmp/ml-regdump

for m in ar_cvisp ar_isp ar_vif ar_csi2 nt99235; do rmmod \$m 2>/dev/null || true; done

# The clock is inherited, not asserted: the vendor never enables it and the boot leaves the
# gate set. Verify that before any CVISP access, because inheriting a gate that is not there
# hangs the SoC on the first read.
G=\$(\$R 0x0a104014 1 | cut -d' ' -f2)
echo \"  [1] cgu 0x0a104014 = \$G\"
case \$G in
*[13579bdf]???) echo '      gate bit12 SET, safe to inherit' ;;
*) echo '      gate bit12 CLEAR -- ABORTING, first CVISP access would hang'; exit 1 ;;
esac

\$R -w 0x0a10400c 0x13001300 >/dev/null
\$R -w 0x0a104010 0x02001300 >/dev/null
\$R -w 0x0a104020 0x10001103 >/dev/null
\$R -w 0x0a10401c 0x02011201 >/dev/null
\$R -w 0x0a104044 0x01001000 >/dev/null

insmod /tmp/nt99235.ko test_pattern=$TP $MODARGS
insmod /tmp/ar-csi2.ko
insmod /tmp/ar-vif.ko
insmod /tmp/ar-isp.ko
insmod /tmp/ar-cvisp.ko
sleep 1

echo '  [2] first CVISP read, clock inherited'
head -3 /sys/kernel/debug/ar-cvisp/regs
echo '      survived'

echo '  [3] receiver live'
/tmp/ml-v4l2grab -d /dev/video2 -o /tmp/f.raw -n 6000 -t 300 >/tmp/g.out 2>&1 &
GP=\$!
sleep 3

echo '  [4] ISP + CVISP configure'
echo $BULK > /sys/kernel/debug/ar-isp/configure_upto
echo 1 > /sys/kernel/debug/ar-isp/arm
sleep 2
echo 1 > /sys/kernel/debug/ar-cvisp/configure
sleep 1

echo '  [4b] sensor log (test pattern readback + SMIA caps land at stream-on)'
dmesg | grep -iE 'test pattern|smia:' | tail -25

echo '  [5] frame-locked rotation, one slot armed per frame start'
/tmp/ml-isploop $WATCH --cvisp --dump /tmp/pl --plane $S1 --plane $S2 --plane $S3

kill \$GP 2>/dev/null
EOS
chmod +x /tmp/fl.sh"

au "/tmp/fl.sh"

echo
echo "=== fetching slot 1 luma plane ==="
# Not scp: neither stack has an sftp subsystem. See AGENTS.md, "Working on a live device".
for i in 0 1 2; do au "cat /tmp/pl.$i" > "$OUT/pl.$i"; done
ls -l "$OUT"/pl.[012]

if [ -s "$OUT/pl.0" ]; then
	echo
	echo "=== luma histogram, ACTIVE REGION ONLY ==="
	# The line stride is 2048 for a 1920-wide plane, so each line carries 128 bytes of
	# padding. Histogramming the whole buffer counts that padding, and the padding holds
	# stale DDR content: CVISP does not write it, the markers never sampled it (they sit at
	# 4096-byte spacing, which is column 0 of every other row), and DDR survives a RAM-boot
	# with the vendor's last frame intact. Counting it once produced a confident "the plane
	# is structured" verdict on a frame that is uniformly black. Only the active columns say
	# anything about what CVISP wrote.
	python3 - "$OUT/pl.0" "$OUT/pl.1" "$OUT/pl.2" <<'PY'
import collections
import sys

STRIDE, WIDTH = 2048, 1920

data = open(sys.argv[1], 'rb').read()
rows = len(data) // STRIDE
active = collections.Counter()
pad = collections.Counter()
for r in range(rows):
	base = r * STRIDE
	active.update(data[base:base + WIDTH])
	pad.update(data[base + WIDTH:base + STRIDE])

n = sum(active.values())
print(f"{len(data)} bytes, {rows} rows at stride {STRIDE}")
print(f"active {WIDTH} cols: {n} bytes, {len(active)} distinct values")
for val, cnt in active.most_common(8):
	print(f"  0x{val:02x}  {cnt:9d}  {100.0 * cnt / n:5.1f}%")
print(f"padding: {len(pad)} distinct values (stale DDR, not written by CVISP)")

if len(active) == 1:
	print(f"UNIFORM: the whole active frame is 0x{next(iter(active)):02x}. CVISP wrote, but")
	print("there is no picture. Sensor exposure and gain are unset on the open stack, so a")
	print("flat black frame is the expected next problem, not a CVISP failure.")
elif active.most_common(1)[0][1] > 0.98 * n:
	print("NEARLY UNIFORM: not a picture; suspect exposure rather than the writer.")
else:
	print("STRUCTURED: the active region varies, which is what a real frame looks like.")
PY
fi

echo
echo ">>> slots 1, 2 and 3 all overwritten means CVISP sustains and the burst timing was the fault."
echo ">>> only slot 1 means it genuinely stops; go after the IRQ service path, NOT CVISP registers."
