#!/usr/bin/env bash
# au-tone-test.sh - measure the AEC trigger scalar's producer on the air unit.
#
# The claim under test is that the scalar gamma, DRC, cm and cm2 key on is the exposure-table index
# the current luma would need to reach its target, not the index AE actually settled on. The two
# agree within a couple of counts whenever AE is converged, so only a saturated scene separates
# them: with the lens covered the table pins at its last entry and the scalar keeps climbing.
#
# Entirely air-unit local. It reads ml-aed's decisions and the driver's tone_scalar parameter, and
# needs neither the RF link nor the goggle, so a stuck downlink cannot invalidate it.
#
# The device side runs from a script file rather than an ssh command line: an earlier session lost a
# run to $(...) expanding on the host instead of the target.
#
# Usage: glue/camera/au-tone-test.sh [seconds]
# Env: AU (192.168.3.102), PASS (libre), OUT dir.
set -uo pipefail

AU="${AU:-192.168.3.102}"
PASS="${PASS:-libre}"
SECS="${1:-120}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${OUT:-$REPO/out/au-tone-test}"
TUNING=/lib/firmware/artosyn/nt99235-tuning-preview-fpv.bin

SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
         -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa
         -o Ciphers=+aes128-cbc -o ConnectTimeout=8)

au() { timeout 60 sshpass -p "$PASS" ssh "${SSHOPTS[@]}" "root@$AU" "$@" 2>/dev/null; }

mkdir -p "$OUT"

if [ "$(au 'echo ok')" != ok ]; then
  echo "air unit $AU not reachable" >&2
  exit 1
fi

echo "=== staging ==="
au 'cat > /tmp/ml-aed; chmod +x /tmp/ml-aed' < "$REPO/userspace/build/ml-aed"
if [ "$(au 'md5sum /tmp/ml-aed' | cut -d' ' -f1)" != "$(md5sum "$REPO/userspace/build/ml-aed" | cut -d' ' -f1)" ]; then
  echo "pushed ml-aed does not match the host copy" >&2
  exit 1
fi
echo "  ml-aed staged and hash-matched"

# The whole device side in one file, so nothing is expanded by the host shell.
cat > "$OUT/on-device.sh" <<'DEVEOF'
#!/bin/sh
# Runs on the air unit. $1 = seconds to sample.
SECS="$1"
TUNING=/lib/firmware/artosyn/nt99235-tuning-preview-fpv.bin
SCALAR=/sys/module/ar_isp/parameters/tone_scalar

rc-service ml-air-ae stop >/dev/null 2>&1
killall ml-aed 2>/dev/null
sleep 1

/tmp/ml-aed --start-index 317 --tone --verbose --tuning "$TUNING" \
    > /tmp/tone.log 2>&1 &
AED=$!
sleep 3

echo "uptime_s,tone_scalar,exp_index,luma,target,settle"
i=0
while [ "$i" -lt "$SECS" ]; do
    UP=$(cut -d' ' -f1 /proc/uptime)
    S=$(cat $SCALAR)
    L=$(tail -1 /tmp/tone.log)
    # "seq N luma L target T index I step S settle C"
    LUMA=$(echo "$L" | sed -n 's/.* luma \([0-9.]*\) .*/\1/p')
    TGT=$(echo "$L" | sed -n 's/.* target \([0-9]*\) .*/\1/p')
    IDX=$(echo "$L" | sed -n 's/.* index \([0-9]*\) .*/\1/p')
    SET=$(echo "$L" | sed -n 's/.* settle \([0-9]*\).*/\1/p')
    echo "$UP,$((S / 256)),$IDX,$LUMA,$TGT,$SET"
    i=$((i + 1))
    sleep 1
done

kill "$AED" 2>/dev/null
killall ml-aed 2>/dev/null
sleep 1
echo -1 > $SCALAR
rc-service ml-air-ae start >/dev/null 2>&1
DEVEOF

au 'cat > /tmp/tone-test.sh; chmod +x /tmp/tone-test.sh' < "$OUT/on-device.sh"

echo "=== ceiling ==="
au "grep -c . $TUNING >/dev/null 2>&1; cat /sys/module/ar_isp/parameters/tone_scalar"

echo "=== sampling ${SECS}s ==="
echo "    COVER THE LENS once sampling starts, hold ~40 s, then uncover."
timeout $((SECS + 90)) sshpass -p "$PASS" ssh "${SSHOPTS[@]}" "root@$AU" \
    "/tmp/tone-test.sh $SECS" 2>/dev/null | tee "$OUT/sweep.csv"

au 'cat /tmp/tone.log' > "$OUT/aed.log" 2>/dev/null
au 'rm -f /tmp/ml-aed /tmp/tone-test.sh /tmp/tone.log'

echo
echo "=== wrote $OUT/sweep.csv and $OUT/aed.log ==="
