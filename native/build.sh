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

docker run --rm --platform=linux/arm64 -v "$PWD":/work -w /work gcc:7 sh -c '
    gcc -O2 fbtext.c -o build/fbtext -lm &&
    gcc -O2 -Wall minidhcpd.c -o build/minidhcpd &&
    gcc -O2 -Wall -static mtdtool.c -o build/mtdtool &&
    gcc -O2 -Wall -static -Ivendor mlflash/src/mlflash.c mlflash/src/util.c mlflash/src/mlimg.c mlflash/src/slot.c vendor/cJSON.c -o build/mlflash -lcrypto &&
    gcc -O2 -Wall -static air-qpower.c -o build/air-qpower &&
    gcc -O2 -Wall -static ml-rfcmd.c -o build/ml-rfcmd &&
    gcc -O2 -Wall -static enc-import-test.c -o build/enc-import-test &&
    gcc -O2 -I. mlmenu/draw.c mlmenu/config.c mlmenu/menu.c -o build/mlmenu -lm'
file build/fbtext build/minidhcpd build/mtdtool build/mlflash build/air-qpower build/ml-rfcmd build/mlmenu
