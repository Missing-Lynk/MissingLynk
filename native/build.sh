#!/usr/bin/env bash
# Build fbtext for the goggle (aarch64) inside an arm64 gcc:7 container
# (Debian stretch = glibc 2.24, <= the goggle's 2.25, so the binary runs there).
# Needs docker with arm64 emulation (binfmt). Output: native/fbtext
set -euo pipefail
cd "$(dirname "$0")"

# mtdtool is built static (standalone, runs in any device state).
docker run --rm --platform=linux/arm64 -v "$PWD":/work -w /work gcc:7 sh -c '
    gcc -O2 fbtext.c -o fbtext -lm &&
    gcc -O2 -Wall minidhcpd.c -o minidhcpd &&
    gcc -O2 -Wall -static mtdtool.c -o mtdtool &&
    gcc -O2 -I. mlmenu/draw.c mlmenu/config.c mlmenu/menu.c -o mlmenu/mlmenu -lm'
file fbtext minidhcpd mtdtool mlmenu/mlmenu
