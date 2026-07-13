#!/usr/bin/env bash
# kdev.sh - kernel dev driver: build and/or RAM-boot the open kernel. Composable flags:
#   --build        full clean reproducible build (kernel Image + dtb, then the modules)
#   --build-fast   incremental build (reuse the tree; fast dev loop; NOT bit-reproducible)
#   --ramboot      RAM-boot whatever is CURRENTLY built (Image + dtb); does NOT rebuild
#   --initramfs[=P]  with --ramboot: boot an initramfs instead of the flashed rootfs
#                  (default P: kernel/initramfs/build/initramfs.cpio.gz -> the bare-kernel
#                  busybox shell; build it first with kernel/initramfs/build.sh)
#   -v|--verbose   stream full make/docker/serial output (default: quiet, tail-on-failure)
#   -h | --help    show this header
#
# Flags compose, in build-then-boot order:
#   kdev.sh --build               # full build only
#   kdev.sh --build-fast          # fast build only
#   kdev.sh --build-fast --ramboot  # fast build, then boot it
#   kdev.sh --ramboot             # boot the current artifacts, no rebuild
#   kdev.sh --ramboot --initramfs   # boot the current kernel into the busybox shell
#
# RAM-boot preconditions (see glue/boot/ram-boot.sh): the device is on the open slot-B Alpine
# and reachable, and the Pico UART bridge is connected. Modules are built but NOT loaded here
# (loading is a separate on-device step; the build prints where the staged .ko are).
#
# Env passthrough: BUILD_DIR JOBS NOTRIM MINIMAL DEBUGSDIO VERBOSE (build); DEVICE_IP ROOT_PASS (ramboot).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
KERNEL_DIR="$REPO/kernel"

DO_BUILD=0
FAST_BUILD=0
DO_RAMBOOT=0
DO_INITRAMFS=0
INITRAMFS_PATH=""
VERBOSE="${VERBOSE:-0}"
for a in "$@"; do
  case "$a" in
    --build)
      DO_BUILD=1
      ;;
    --build-fast)
      DO_BUILD=1
      FAST_BUILD=1
      ;;
    --ramboot)
      DO_RAMBOOT=1
      ;;
    --initramfs)
      DO_INITRAMFS=1
      ;;
    --initramfs=*)
      DO_INITRAMFS=1
      INITRAMFS_PATH="${a#*=}"
      ;;
    -v|--verbose)
      VERBOSE=1
      ;;
    -h|--help)
      sed -n '2,/^set -/p' "$0" | sed 's/^# \?//; s/^set -.*//'
      exit 0
      ;;
    *)
      echo "unknown option: $a (try --help)" >&2
      exit 2
      ;;
  esac
done
export VERBOSE
export ML_VERBOSE="$VERBOSE"

if [ "$DO_BUILD" = 0 ] && [ "$DO_RAMBOOT" = 0 ]; then
  echo "nothing to do; pass --build, --build-fast, and/or --ramboot (see --help)" >&2
  exit 2
fi

if [ "$DO_INITRAMFS" = 1 ] && [ "$DO_RAMBOOT" = 0 ]; then
  echo "--initramfs only applies with --ramboot" >&2
  exit 2
fi

# Sourced only after flag parsing so --help/usage work without the kernel tree checked
# out beside glue (matters once glue is its own repo).
# shellcheck disable=SC1091
source "$REPO/kernel/scripts/pin.env"
BUILD_DIR="${BUILD_DIR:-$KERNEL_BUILD_DEFAULT}"
IMG="$BUILD_DIR/linux/arch/arm64/boot/Image"
DTB="$BUILD_DIR/linux/arch/arm64/boot/proxima-9311.dtb"
MODS="$BUILD_DIR/ml-modules"

step() { printf '\n========== %s ==========\n' "$1" >&2; }

if [ "$DO_BUILD" = 1 ]; then
  if [ "$FAST_BUILD" = 1 ]; then
    step "build (FAST/incremental): kernel Image + dtb"
    export FAST=1
  else
    step "build (clean/reproducible): kernel Image + dtb"
  fi

  marker="$(mktemp)"
  "$REPO/kernel/scripts/build.sh" build

  # Guard against a silently-failed build: the Image must exist and be newer than the marker.
  if ! { [ -f "$IMG" ] && [ "$IMG" -nt "$marker" ]; }; then
    echo "[!] build produced no fresh Image at $IMG" >&2
    rm -f "$marker"
    exit 1
  fi
  rm -f "$marker"

  # Report how the LZ4-packed Image compares to the 6 MiB kernel slot. `|| true` so an
  # over-slot build (e.g. a debug/RAM-boot-only kernel) still prints the margin without
  # aborting; mkkernel.py's own NOTE flags the overflow.
  step "slot fit: packed Image vs the 6 MiB kernel slot"
  python3 "$REPO/glue/flash/mkkernel.py" size "$IMG" || true

  step "build: modules (ABI-matched to the Image above)"
  "$KERNEL_DIR/modules/build.sh"
  if ! ls "$MODS"/*.ko >/dev/null 2>&1; then
    echo "[!] no .ko in $MODS after the module build" >&2
    exit 1
  fi
fi

if [ "$DO_RAMBOOT" = 1 ]; then
  step "RAM-boot: current Image + dtb (nothing flashed; slot unchanged)"
  if ! { [ -f "$IMG" ] && [ -f "$DTB" ]; }; then
    echo "[!] missing $IMG or $DTB (build first with --build or --build-fast)" >&2
    exit 1
  fi

  INITRAMFS=""
  if [ "$DO_INITRAMFS" = 1 ]; then
    INITRAMFS="${INITRAMFS_PATH:-$KERNEL_DIR/initramfs/build/initramfs.cpio.gz}"
    if [ ! -f "$INITRAMFS" ]; then
      echo "[!] no initramfs at $INITRAMFS (build it: $KERNEL_DIR/initramfs/build.sh)" >&2
      exit 1
    fi
    echo "RAM-booting the initramfs ($INITRAMFS) -> busybox shell, NOT the flashed rootfs" >&2
  fi

  INITRAMFS="$INITRAMFS" DEVICE_IP="${DEVICE_IP:-192.168.3.100}" \
    "$REPO/glue/boot/ram-boot.sh" "$IMG" "$DTB"
fi

step "done"
echo "Image:   $IMG" >&2
if [ "$DO_BUILD" = 1 ]; then
  echo "Modules: $MODS  (staged in $MODS/rootfs/lib/modules/; deploy + load on-device)" >&2
fi
