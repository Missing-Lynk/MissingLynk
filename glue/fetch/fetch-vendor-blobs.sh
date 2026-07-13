#!/usr/bin/env bash
# fetch-vendor-blobs.sh - pull every vendor blob the open slot-B stack needs off a LIVE,
# booted stock slot A, into one host-side directory (mirroring the device paths):
#
#   RF baseband     /usr/usrdata/ar813x/bb_demo_gnd_d.img (+ non-debug bb_demo_gnd.img)
#   RF configs      bb_config_gnd.json, bb_config_gnd_5m.json, usr_cfg.json,
#                   ar8030_pwr.json, chan_valid_bmp.json, chan_fast_valid_bmp.json
#   RF merged cfg   bb_config_gnd.json.usr_cfg.json - the file kernel/modules/load.sh
#                   actually passes to artosyn_sdio. GENERATED at boot by the vendor's
#                   auto_merge (base + power cal + channel bitmap + bound-peer usr_cfg),
#                   so it does NOT exist in a static rootfs/partition dump - it can only
#                   be fetched from a running slot A. That file is this script's reason
#                   to exist; without it the AR8030 comes up with placeholder MACs and
#                   no bound peer (see docs/reference/datasheets/ar8030-rf-link.md).
#   RF ref client   cmd_dbg + daemon (bb-socket client + bridge for Path A), plus the
#                   glibc runtime they need to run on the open musl Alpine slot B
#                   (loader + libc/libstdc++/libm/libgcc_s/libpthread, ldd-resolved)
#   Codec firmware  /usr/bin/chagall{,_lowmem}.bin.gz (Wave521C VCPU ucode; NOT RF -
#                   see re/open-mpp/07-codec-ip-chipsmedia-wave5.md). Decompressed after
#                   fetch, and the full chagall.bin is also staged at
#                   lib/firmware/cnm/wave521c_k3_codec_fw.bin - the exact path/name the
#                   open wave5 V4L2 driver requests, ready to drop into the B rootfs.
#   Vendor MPI libs /usr/lib/libmpi_{sys,venc,vdec,vb,scaler}.so + libmpp_service.so -
#                   what userspace/libre/tools/ml-codec-probe links (point AR_LIBDIR at
#                   <dest>/usr/lib as an alternative to a full out/P1_GND extraction).
#
# NOT fetched here: ar_lowdelay + the RTSP RE libraries - that set already has a tool
# (`missinglynk dump-firmware [--all]` -> firmware/bin/, see firmware/bin/README.md).
#
# Everything lands under <dest> (default firmware/bin/slot-a/, git-ignored like the rest
# of firmware/bin - these are proprietary vendor binaries, never commit them). Each file
# is streamed over a plain ssh channel (the vendor Dropbear has no scp/sftp) and verified
# by md5 against the device's copy. Read-only on the device; safe to run any time slot A
# is up. Missing optional files warn; missing required ones fail the run at the end.
#
# Usage:   glue/fetch/fetch-vendor-blobs.sh [dest-dir]
# Env:     DEVICE_IP (default 192.168.3.100)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DEST="${1:-$REPO/firmware/bin/slot-a}"
DEVICE_IP="${DEVICE_IP:-192.168.3.100}"

command -v sshpass >/dev/null || { echo "sshpass not installed" >&2; exit 1; }

# Legacy-crypto Dropbear on the vendor (slot A) system - see docs/guides/serial-and-debug-access.md.
. "$(dirname "$0")/../lib/ssh-opts.sh"
SSHOPTS=("${SSH_OPTS_LEGACY[@]}")
sshv() { sshpass -p artosyn ssh "${SSHOPTS[@]}" root@"$DEVICE_IP" "$@"; }

echo "[*] checking $DEVICE_IP is booted on slot A (stock vendor)..."
if ! sshv true 2>/dev/null; then
    if sshpass -p libre ssh -o ConnectTimeout=6 "${SSH_OPTS_LIBRE[@]}" root@"$DEVICE_IP" true 2>/dev/null; then
        echo "refusing: $DEVICE_IP is on slot B (open Alpine), not slot A." >&2
        echo "  These blobs (esp. the auto_merge'd RF config) only exist on a running stock A." >&2
        echo "  Run: glue/boot/flip-slot.sh a   (then re-run this script once it's back up)" >&2
        exit 1
    fi

    echo "cannot SSH to $DEVICE_IP as root/artosyn - is it booted and on slot A?" >&2
    exit 1
fi
echo "[+] confirmed: slot A (root/artosyn)"

MISSING_REQ=()
MISSING_OPT=()

# fetch <required|optional> <remote-path>  -> $DEST/<remote-path minus leading />
fetch() {
    local req="$1" rpath="$2"
    local lpath="$DEST/${rpath#/}"
    if ! sshv "test -f '$rpath'" 2>/dev/null; then
        if [ "$req" = required ]; then
            echo "[!] MISSING (required): $rpath" >&2; MISSING_REQ+=("$rpath")
        else
            echo "[-] missing (optional): $rpath" >&2; MISSING_OPT+=("$rpath")
        fi

        return 0
    fi

    mkdir -p "$(dirname "$lpath")"
    sshv "cat '$rpath'" > "$lpath"
    local rsum lsum
    rsum="$(sshv "md5sum '$rpath'" | cut -d' ' -f1)"
    lsum="$(md5sum "$lpath" | cut -d' ' -f1)"
    if [ -z "$rsum" ] || [ "$rsum" != "$lsum" ]; then
        echo "[!] md5 mismatch for $rpath (remote=$rsum local=$lsum)" >&2
        exit 1
    fi
    echo "[+] $rpath  ($(stat -c%s "$lpath") B, md5 ok)"
}

AR813X=/usr/usrdata/ar813x

echo "[*] RF baseband firmware + configs ($AR813X)..."
fetch required "$AR813X/bb_demo_gnd_d.img"
fetch optional "$AR813X/bb_demo_gnd.img"
fetch required "$AR813X/bb_config_gnd.json"
fetch optional "$AR813X/bb_config_gnd_5m.json"
fetch required "$AR813X/usr_cfg.json"
fetch optional "$AR813X/ar8030_pwr.json"
fetch optional "$AR813X/chan_valid_bmp.json"
fetch optional "$AR813X/chan_fast_valid_bmp.json"
fetch optional "$AR813X/cmd_dbg"
fetch optional "$AR813X/daemon"

# Running the vendor daemon + cmd_dbg on the open Alpine slot B needs the glibc runtime.
# Those are glibc binaries (interp /lib/ld-linux-aarch64.so.1, GLIBC_2.17); Alpine is musl and
# has NO glibc/loader at all, so LD_LIBRARY_PATH cannot help - the whole vendor glibc set
# (loader + libc/libstdc++/libm/libgcc_s/libpthread) must be staged and the binaries invoked
# via the explicit loader. Resolve the exact device paths with ldd on-device and stream each so
# they land under $DEST at their real device paths (ready for a matching --library-path).
# Optional: only needed to run the vendor binaries, not for an own client.
echo "[*] vendor glibc runtime for daemon/cmd_dbg (on musl Alpine)..."
RT_LIBS="$(sshv "for b in $AR813X/daemon $AR813X/cmd_dbg; do [ -f \"\$b\" ] && ldd \"\$b\" 2>/dev/null; done \
    | awk '{ for(i=1;i<=NF;i++) if(\$i ~ /^\\//) print \$i }' | sort -u" 2>/dev/null || true)"
if [ -n "$RT_LIBS" ]; then
    while IFS= read -r lib; do
        [ -n "$lib" ] && fetch optional "$lib"
    done <<< "$RT_LIBS"
else
    echo "[-] could not resolve runtime libs via on-device ldd (busybox may lack it);" >&2
    echo "    falling back to a candidate glibc set under /lib and /usr/lib." >&2
    for cand in /lib/ld-linux-aarch64.so.1 /lib/libc.so.6 /lib/libm.so.6 /lib/libpthread.so.0 \
                /lib/libgcc_s.so.1 /usr/lib/libstdc++.so.6 \
                /usr/lib/libc.so.6 /usr/lib/libm.so.6 /usr/lib/libgcc_s.so.1; do
        sshv "test -f '$cand'" 2>/dev/null && fetch optional "$cand"
    done
fi

echo "[*] merged RF config (generated at boot by auto_merge; searching for it)..."
MERGED="$(sshv "find $AR813X /usr/usrdata/product/ar813x /tmp /usrdata \
    -maxdepth 3 -name 'bb_config_gnd.json.usr_cfg.json' 2>/dev/null | head -1" || true)"
if [ -n "$MERGED" ]; then
    fetch required "$MERGED"
else
    echo "[!] MISSING (required): bb_config_gnd.json.usr_cfg.json - auto_merge output not found." >&2
    echo "    Has the RF stack started on this boot? (it is created by start_ar813x.sh)" >&2
    MISSING_REQ+=("bb_config_gnd.json.usr_cfg.json")
fi

echo "[*] Wave521C codec firmware (/usr/bin)..."
fetch required /usr/bin/chagall.bin.gz
fetch optional /usr/bin/chagall_lowmem.bin.gz
fetch optional /usr/bin/chagall.bin
fetch optional /usr/bin/chagall_lowmem.bin

echo "[*] vendor MPI libraries (/usr/lib, for ml-codec-probe)..."
for lib in libmpi_sys.so libmpi_venc.so libmpi_vdec.so libmpi_vb.so libmpi_scaler.so libmpp_service.so; do
    fetch required "/usr/lib/$lib"
done

# Decompress the codec firmware (keep the .gz too) and stage the wave5-driver copy.
for gz in "$DEST"/usr/bin/chagall*.bin.gz; do
    [ -f "$gz" ] || continue
    gunzip -kf "$gz"
    echo "[+] decompressed ${gz##*/} -> $(basename "${gz%.gz}") ($(stat -c%s "${gz%.gz}") B)"
done

if [ -f "$DEST/usr/bin/chagall.bin" ]; then
    mkdir -p "$DEST/lib/firmware/cnm"
    cp "$DEST/usr/bin/chagall.bin" "$DEST/lib/firmware/cnm/wave521c_k3_codec_fw.bin"
    echo "[+] staged lib/firmware/cnm/wave521c_k3_codec_fw.bin (what the open wave5 driver requests)"
fi

echo
echo "[+] done -> $DEST"
[ ${#MISSING_OPT[@]} -eq 0 ] || echo "[-] optional files not found: ${MISSING_OPT[*]}" >&2
if [ ${#MISSING_REQ[@]} -gt 0 ]; then
    echo "[!] REQUIRED files not found: ${MISSING_REQ[*]}" >&2
    exit 1
fi
