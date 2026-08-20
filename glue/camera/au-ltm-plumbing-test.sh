#!/usr/bin/env bash
# au-ltm-plumbing-test.sh - prove the LTM double-buffered page-publish path on hardware.
#
# The driver (2026-08-20) publishes the LTM coefficient page double-buffered: `ar_isp_ltm_page_publish`
# fills the half the descriptor at 0x2808 does not name, then flips the descriptor to it. The
# default payload is a scene-safe identity ramp; a producer feeds a real page through the debugfs
# `ltm_page` node (write one whole 0x4000 page, committed on close; read returns the fetched half).
#
# This exercises that path with no producer and no algorithm: it reads the current page, feeds a
# distinct synthetic page, reads back, and checks three things the code promises:
#   1. the read-back page equals what was fed (the write landed),
#   2. the descriptor register 0x08c02808 moved by exactly 0x4000 (the half flipped),
#   3. a short feed (less than a whole page) is REJECTED and leaves the page unchanged (the
#      commit-on-close guard fires; the driver logs "ltm_page feed dropped").
#
# It is read-only w.r.t. the operating point: it does not touch the AE loop, exposure or any gain.
# The page it writes is synthetic and only affects local tone until the next configure, so restore
# feeds the identity ramp back at the end. Nothing persistent is written.
#
# Usage: glue/camera/au-ltm-plumbing-test.sh [--out DIR] [--dry-run]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

OUT=""
DRY=0

while [ $# -gt 0 ]; do
    case "$1" in
    --out)     OUT="$2"; shift 2 ;;
    --dry-run) DRY=1;    shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[ -n "$OUT" ] || OUT="$REPO/out/au-ltm-plumbing/$(date -u +%Y%m%dT%H%M%SZ)"

AU_IP="${AU_IP:-192.168.3.102}"
AU_PASS="${AU_PASS:-libre}"

DBG=/sys/kernel/debug/ar-isp
PAGE="$DBG/ltm_page"
PAGE_REG=0x08c02808
PAGE_SIZE=16384          # 0x4000

au() {
    if [ "$DRY" = 1 ]; then
        echo "    [dry] au: $*" >&2
        return 0
    fi
    sshpass -p "$AU_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=8 root@"$AU_IP" "$@" </dev/null
}

# Copy a local file to the device over ssh stdin (no scp on the slim rootfs; small file, so the
# dwc2 sustained-push hazard does not apply).
au_put() {
    if [ "$DRY" = 1 ]; then
        echo "    [dry] au_put: $1 -> $2" >&2
        return 0
    fi
    sshpass -p "$AU_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=8 root@"$AU_IP" "cat > $2" < "$1"
}

RESTORED=0
# shellcheck disable=SC2329  # invoked by the trap below, which 0.11.0 does not always see
restore() {
    [ "$RESTORED" = 1 ] && return 0
    RESTORED=1
    echo
    echo "restoring the identity page"
    # A configure rebuilds the identity page into both halves; the cheapest restore that does not
    # depend on this test's own synthetic file being intact is to re-feed the identity page we saved.
    if [ -f "$OUT/ident.bin" ]; then
        au_put "$OUT/ident.bin" /tmp/ltm-restore.bin \
            && au "cat /tmp/ltm-restore.bin > $PAGE; rm -f /tmp/ltm-restore.bin" \
            || echo "  WARNING: could not restore the identity page (unit gone?)" >&2
    fi
}
trap restore EXIT INT TERM

echo "=== preflight ==="
if [ "$DRY" = 0 ]; then
    ping -c 1 -W 2 "$AU_IP" >/dev/null 2>&1 || { echo "air unit $AU_IP is not up" >&2; exit 1; }
    au "test -e $PAGE" || {
        echo "$PAGE is missing: this ar_isp predates the LTM plumbing (2026-08-20)." >&2
        echo "Flash a rootfs with the rebuilt ar-isp.ko before this test means anything." >&2
        exit 1
    }
    echo "ltm_page node: present"
fi
mkdir -p "$OUT"

echo
echo "=== capture the current (identity) page and the descriptor ==="
au "cat $PAGE" > "$OUT/ident.bin" 2>/dev/null || true
REG0="$(au "/tmp/ml-regdump $PAGE_REG 1" 2>/dev/null | awk 'NR==1{print $2}')"
if [ "$DRY" = 0 ]; then
    sz=$(wc -c < "$OUT/ident.bin")
    echo "  page $sz bytes, descriptor 0x08c02808 = 0x$REG0"
    [ "$sz" -eq "$PAGE_SIZE" ] || { echo "  read-back is not a whole page ($sz != $PAGE_SIZE)" >&2; exit 1; }
fi

echo
echo "=== build a synthetic page distinct from identity ==="
# A steeper ramp: every tile maps sample i to min(i*16, 1023), which no identity tile produces.
python3 - "$OUT/synth.bin" <<'PY'
import struct, sys
tiles, samples, stride = 64, 128, 0x100
page = bytearray(64 * stride)
for t in range(tiles):
    for i in range(samples):
        v = min(i * 16, 1023)
        struct.pack_into("<H", page, t * stride + i * 2, v)
open(sys.argv[1], "wb").write(page)
PY
echo "  synth.bin $(wc -c < "$OUT/synth.bin") bytes"

echo
echo "=== feed the synthetic page, read back, check the flip ==="
au_put "$OUT/synth.bin" /tmp/ltm-synth.bin
au "cat /tmp/ltm-synth.bin > $PAGE"
au "cat $PAGE" > "$OUT/after.bin" 2>/dev/null || true
REG1="$(au "/tmp/ml-regdump $PAGE_REG 1" 2>/dev/null | awk 'NR==1{print $2}')"

echo
echo "=== short-feed guard: a 1024-byte feed must be rejected ==="
au "head -c 1024 /tmp/ltm-synth.bin > $PAGE 2>/dev/null || true"
au "cat $PAGE" > "$OUT/after-short.bin" 2>/dev/null || true
au "dmesg | tail -20 | grep 'ltm_page feed dropped'" > "$OUT/short-warn.txt" 2>/dev/null || true

echo
echo "=== verdict ==="
if [ "$DRY" = 1 ]; then
    echo "dry run: no device was touched"
    exit 0
fi

fail=0
# 1. read-back equals what was fed
if cmp -s "$OUT/synth.bin" "$OUT/after.bin"; then
    echo "  PASS: read-back equals the fed page"
else
    echo "  FAIL: read-back differs from the fed page"; fail=1
fi
# 2. read-back differs from the original identity page
if cmp -s "$OUT/ident.bin" "$OUT/after.bin"; then
    echo "  FAIL: page did not change (the write did nothing)"; fail=1
else
    echo "  PASS: page changed from identity"
fi
# 3. descriptor moved by exactly 0x4000 (the half flipped)
if [ -n "$REG0" ] && [ -n "$REG1" ]; then
    d=$(( 0x$REG1 - 0x$REG0 ))
    ad=${d#-}
    if [ "$ad" -eq "$PAGE_SIZE" ]; then
        echo "  PASS: descriptor flipped by 0x4000 (0x$REG0 -> 0x$REG1)"
    else
        echo "  FAIL: descriptor moved by $d, expected +/- 0x4000 (0x$REG0 -> 0x$REG1)"; fail=1
    fi
else
    echo "  WARN: could not read the descriptor (ml-regdump missing?); flip unverified"
fi
# 4. short feed was rejected and left the page as the synthetic (unchanged)
if cmp -s "$OUT/after.bin" "$OUT/after-short.bin"; then
    echo "  PASS: short feed rejected, page unchanged"
    [ -s "$OUT/short-warn.txt" ] && echo "       (driver logged: $(tail -1 "$OUT/short-warn.txt"))"
else
    echo "  FAIL: short feed changed the page (the commit-on-close guard did not fire)"; fail=1
fi

echo
echo "captures in $OUT"
exit $fail
