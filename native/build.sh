#!/usr/bin/env bash
# Build fbtext for the goggle (aarch64) inside an arm64 gcc:7 container
# (Debian stretch = glibc 2.24, <= the goggle's 2.25, so the binary runs there).
# Needs docker with arm64 emulation (binfmt). Output: native/fbtext
set -euo pipefail
cd "$(dirname "$0")"

# Outputs land in native/build/ (gitignored). mtdtool + air-qpower are static (standalone, run in any
# device state / on the air unit).
mkdir -p build

# Shared third-party deps are fetched here into native/vendor/ (gitignored), pinned +
# sha256-verified - never committed into the tree (same approach as kernel/scripts/pin.env).
# Any native tool can compile/link them (-Ivendor). OpenSSL libcrypto is linked from the
# container, not fetched. cJSON: mlflash's manifest.json parser.
CJSON_VERSION=v1.7.18
CJSON_BASEURL="https://raw.githubusercontent.com/DaveGamble/cJSON/${CJSON_VERSION}"
CJSON_C_SHA256=75c51de8fa40ac9d7a99319c6330719bd692eb81c0a869265f3d4c682533f9b9
CJSON_H_SHA256=0578cc29132912edbc88f83207a8fc76e5db3db0605497e909a9384ef3cc474b

fetch_pinned() {   # url dest sha256; cached, re-fetched only if missing or hash-mismatched
    local url="$1" dest="$2" want="$3"
    if [ -f "$dest" ] && printf '%s  %s\n' "$want" "$dest" | sha256sum -c - >/dev/null 2>&1; then
        return
    fi
    echo "[deps] fetch $(basename "$dest") (cJSON ${CJSON_VERSION})"
    curl -fsSL "$url" -o "$dest"
    printf '%s  %s\n' "$want" "$dest" | sha256sum -c - >/dev/null \
        || { echo "sha256 mismatch: $dest" >&2; rm -f "$dest"; exit 1; }
}

mkdir -p vendor
fetch_pinned "$CJSON_BASEURL/cJSON.c" vendor/cJSON.c "$CJSON_C_SHA256"
fetch_pinned "$CJSON_BASEURL/cJSON.h" vendor/cJSON.h "$CJSON_H_SHA256"

# mtd-utils supplies ubiformat + libmtd/libubi/libubigen/libscan for mlflash's userapp UBI write
# (brick-capable NAND logic; vendored upstream, never reimplemented). Fetched as the pinned +
# sha256-verified release tarball, extracted into vendor/mtd-utils/ (gitignored, cached).
MTDUTILS_VERSION=v2.3.1
MTDUTILS_TARBALL_SHA256=f53cde04802439fa6ac2ffbd80955f2b790262c02bd6fa2f7783a19fdc33716d

if [ ! -f vendor/mtd-utils/ubi-utils/ubiformat.c ]; then
    fetch_pinned "https://github.com/sigma-star/mtd-utils/archive/refs/tags/${MTDUTILS_VERSION}.tar.gz" \
        vendor/mtd-utils.tar.gz "$MTDUTILS_TARBALL_SHA256"
    rm -rf vendor/mtd-utils
    mkdir -p vendor/mtd-utils
    tar xzf vendor/mtd-utils.tar.gz -C vendor/mtd-utils --strip-components=1
fi

MTDUTILS_INC="-I vendor/mtd-utils/include -I vendor/mtd-utils/include/mtd"
MTDUTILS_LIB="vendor/mtd-utils/lib/libmtd.c vendor/mtd-utils/lib/libmtd_legacy.c \
vendor/mtd-utils/lib/libubi.c vendor/mtd-utils/lib/libubigen.c vendor/mtd-utils/lib/libscan.c \
vendor/mtd-utils/lib/libcrc32.c vendor/mtd-utils/lib/common.c vendor/mtd-utils/lib/execinfo.c"

# mlflash links vendored mtd-utils. Compile the upstream units with -w (their warnings are not
# ours to fix) and -Dmain=ubiformat_main so ubiformat's main() links in as a callable function.
docker run --rm --platform=linux/arm64 -v "$PWD":/work -w /work \
    -e MTDUTILS_VERSION="$MTDUTILS_VERSION" -e MTDUTILS_INC="$MTDUTILS_INC" \
    -e MTDUTILS_LIB="$MTDUTILS_LIB" gcc:7 sh -c '
    gcc -O2 fbtext.c -o build/fbtext -lm &&
    gcc -O2 -Wall minidhcpd.c -o build/minidhcpd &&
    gcc -O2 -Wall -static mtdtool.c -o build/mtdtool &&
    for f in $MTDUTILS_LIB vendor/mtd-utils/ubi-utils/ubiformat.c; do
        gcc -O2 -w -static -DVERSION=\"mtd-utils-$MTDUTILS_VERSION\" -Dmain=ubiformat_main \
            $MTDUTILS_INC -c "$f" -o "build/mtdu-$(basename "$f" .c).o" || exit 1
    done &&
    gcc -O2 -Wall -static -Ivendor $MTDUTILS_INC \
        mlflash/src/mlflash.c mlflash/src/util.c mlflash/src/mlimg.c mlflash/src/slot.c \
        mlflash/src/probe.c mlflash/src/mtd.c mlflash/src/ubi.c mlflash/src/board.c \
        vendor/cJSON.c build/mtdu-*.o -o build/mlflash -lcrypto &&
    gcc -O2 -Wall -static air-qpower.c -o build/air-qpower &&
    gcc -O2 -Wall -static ml-rfcmd.c -o build/ml-rfcmd &&
    gcc -O2 -Wall -static -Ivendor ml-rf-persist.c vendor/cJSON.c -o build/ml-rf-persist &&
    gcc -O2 -Wall -static enc-import-test.c -o build/enc-import-test &&
    gcc -O2 -I. mlmenu/draw.c mlmenu/config.c mlmenu/menu.c -o build/mlmenu -lm'

# minidhcpd-musl: static musl build for the open slot-B rootfs (staged by rootfs/build.sh into
# /usr/local/bin/minidhcpd, started by the usb-gadget service). The glibc build above stays the
# stock-firmware component's binary (missinglynk install). Same Alpine pin as the rootfs.
docker run --rm --platform=linux/arm64 -v "$PWD":/work -w /work alpine:3.24 sh -c '
    apk add -q build-base &&
    gcc -O2 -Wall -static minidhcpd.c -o build/minidhcpd-musl &&
    strip build/minidhcpd-musl'
file build/fbtext build/minidhcpd build/minidhcpd-musl build/mtdtool build/mlflash build/air-qpower build/ml-rfcmd build/ml-rf-persist build/mlmenu
