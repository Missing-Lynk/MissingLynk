#!/usr/bin/env bash
# Cross-build uMTP-Responder (umtprd) for the open slot-B Alpine rootfs (aarch64).
#
# umtprd is the userspace MTP responder that drives the FunctionFS (f_fs) gadget
# function - the goggle side of the MTP-over-USB feature (ml-kernel issue #5). It
# is NOT in the Alpine repos, so we build it from a pinned upstream tag here, the
# same way native/build.sh builds the other on-device tools.
#
# Built STATIC inside an arm64 Alpine (musl) container so the result is
# libc-agnostic and drops straight into the rootfs (like the static ml-pipeline /
# mtdtool). Needs docker with arm64 emulation (binfmt).
#
# Output: native/umtprd/build/umtprd  (staged to /usr/local/bin/umtprd by
# rootfs/build.sh when present). Not part of `make native`/`all`: it clones from
# the network, so it is its own `make umtprd` target and must not break the
# offline-cacheable common build.
set -euo pipefail
cd "$(dirname "$0")"

# Pinned upstream. Bump deliberately; umtprd is small and stable.
UMTPRD_REPO="https://github.com/viveris/uMTP-Responder.git"
UMTPRD_TAG="umtprd-1.8.1"

OUT="$PWD/build"
mkdir -p "$OUT"

docker run --rm --platform=linux/arm64 -v "$OUT":/out alpine:3.20 sh -euc "
    apk add --no-cache build-base git linux-headers >/dev/null
    git clone --depth 1 --branch '$UMTPRD_TAG' '$UMTPRD_REPO' /src
    cd /src
    # Do NOT override CFLAGS: the Makefile appends -I./inc (for buildconf.h) + -O3 there,
    # and a command-line CFLAGS= would clobber it. Only set LDFLAGS, replicating the libs the
    # Makefile links (-lpthread -lrt -s) plus -static, since a command-line LDFLAGS= is final
    # (the makefile's += cannot append to it). Static musl link -> libc-agnostic binary.
    make CC=gcc LDFLAGS='-static -lpthread -lrt -s'
    cp umtprd /out/umtprd
    strip /out/umtprd
"

file "$OUT/umtprd"
echo "umtprd -> $OUT/umtprd"
