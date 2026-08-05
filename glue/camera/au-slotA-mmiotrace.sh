#!/usr/bin/env bash
# Slot-A (vendor) MMIO write-tracer runner.
#
# Captures every VIF/CSI/ISP/CGU register write the vendor camera stack makes on
# a real capture-start, in program order, including transient set-then-clear
# pulses and the exact DMA target address - the things no register dump shows.
# It LD_PRELOADs native/build/mmiotrace.so into the vendor's register-writing
# process, which write-protects its /dev/mem (and /dev/ar_sys) mappings and logs
# every store.
#
# REQUIRES: air unit booted to STOCK slot A (root@192.168.3.100 / artosyn) with
# the GOGGLE ON so the vendor actually streams the camera. This does NOT touch
# slot B and writes nothing to flash.
#
# Usage (run the phases in order):
#   au-slotA-mmiotrace.sh push          # stage mmiotrace.so + ml-regdump on the unit
#   au-slotA-mmiotrace.sh discover      # find the process that maps MMIO + how it launches
#   au-slotA-mmiotrace.sh trace <PID>   # kill that PID and relaunch it under the tracer
#   au-slotA-mmiotrace.sh pull          # fetch /tmp/mmio.log and pre-summarise it
#
# The discover step prints the candidate process, its full argv, cwd, parent, and
# the init script that starts it. Read that before trace: if a supervisor respawns
# the process, stop the SERVICE (rc-service / the init script) rather than trace,
# or use the boot-preload alternative printed by discover.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/au-camera.sh"

# Reads the vendor stack: slot A only. AU_PORT reaches a unit behind a relay.
au_stock_slot_a

OUT="$REPO/out/au-mmiotrace"
# Physical logging + TRAP window. Narrowed to just VIF (0x8870000) + CSI (0x8880000):
# a wider window traps the ENCODER (wave5/JPU ~0x8830000) too, and our store emulation
# corrupts its VB_SetConf/VENC_LoadDefault so the video pipeline aborts BEFORE it ever
# programs the VIF (0 VIF writes, no video, goggle shows "not associated"). Trapping only
# VIF+CSI leaves venc untouched so video starts and the arm sequence actually runs.
# (Excludes CGU 0x0a104000 - that path is /dev/ar_clk ioctl + our prologue already; and
# ISP 0x8c00000 - bypassed on our view path. Override with MMIO_LO/HI for a wider sweep.)
LO="${MMIO_LO:-0x08860000}"
HI="${MMIO_HI:-0x0888ffff}"
# MMIO_READS=1 also traps loads, so the vendor's polls and waits appear in the log.
# Off by default: it faults on every register READ as well, which is far more
# interruption than the store-only trap the realtime daemon is known to survive.
# Narrow the window (MMIO_LO/HI) when using it. MMIO_TIME=1 adds ns timestamps.
READS="${MMIO_READS:-0}"
TIME="${MMIO_TIME:-0}"
# MMIO_NOMEM=1 disables /dev/mem store trapping entirely and captures ONLY the /dev/ar_sys
# register-write ioctl. That is the safe way to use a full-address-space window: with trapping
# on, a wide window mprotects the whole 256 MiB mapping and faults on codec and display stores
# too, which corrupts venc and stops video before the camera is ever programmed.
NOMEM="${MMIO_NOMEM:-0}"
# MMIO_SKIP_LO/HI leave one span untrapped inside a wide window. The vendor maps all 256 MiB of
# register space in a single /dev/mem call, so a whole-space window is the only way to find
# writes outside the blocks already traced; but trapping the encoder (wave5/JPU around
# 0x08830000) corrupts its setup and the video pipeline dies before the camera is programmed.
# MMIO_IOCTL_CENSUS=1 additionally logs any unrecognised ar_sys ioctl request number.
SKIP_LO="${MMIO_SKIP_LO:-1}"
SKIP_HI="${MMIO_SKIP_HI:-0}"
CENSUS="${MMIO_IOCTL_CENSUS:-0}"

# The device halves are files of their own. Their knobs go over as environment rather than
# being interpolated into the script text, so they stay real files that shellcheck can read.
MMIO_ENV="LO=$LO HI=$HI READS=$READS TIME=$TIME NOMEM=$NOMEM"
MMIO_ENV="$MMIO_ENV SKIP_LO=$SKIP_LO SKIP_HI=$SKIP_HI CENSUS=$CENSUS"
mkdir -p "$OUT"

cmd="${1:-discover}"

case "$cmd" in
push)
    device_push_as "$REPO/native/build/mmiotrace.so" /tmp/mmiotrace.so
    device_push_as "$REPO/native/build/ml-regdump" /tmp/ml-regdump
    sshg 'chmod +x /tmp/ml-regdump; ls -la /tmp/mmiotrace.so /tmp/ml-regdump'
    ;;

discover)
    echo "=== processes that map MMIO (/dev/mem or /dev/ar_sys) = the register writers ==="
    device_push_as "$HERE/mmio-discover-remote.sh" /tmp/mmio-discover.sh || exit 1
    sshg '/tmp/mmio-discover.sh'
    echo
    echo ">>> Pick the PID whose maps include /dev/mem (the VIF register writer)."
    echo ">>> Then: $0 trace <PID>"
    echo ">>> If PPid is a supervisor that respawns it, stop the SERVICE first, or edit"
    echo "    its init script to prepend:  LD_PRELOAD=/tmp/mmiotrace.so"
    echo "    MMIOTRACE_OUT=/tmp/mmio.log MMIOTRACE_LO=$LO MMIOTRACE_HI=$HI   and reboot A."
    echo ">>> Read tracing (polls and waits, not just values): prefix MMIO_READS=1 MMIO_TIME=1"
    ;;

trace)
    pid="${2:?usage: $0 trace <PID>}"
    echo "=== capturing argv/cwd of PID $pid ==="
    device_push_as "$HERE/mmio-trace-remote.sh" /tmp/mmio-trace.sh || exit 1
    sshg "$MMIO_ENV /tmp/mmio-trace.sh $pid"
    echo
    echo ">>> If mmio.log is empty: the writer is a different PID, or it maps a device"
    echo "    other than /dev/mem|/dev/ar_sys, or a supervisor respawned the unhooked"
    echo "    original. Re-run discover, or use the init-script boot-preload path."
    echo ">>> Let it stream a few seconds, then: $0 pull"
    ;;

install-preload)
    # The rootfs is a READ-ONLY squashfs, so /usr/usrdata/run.sh cannot be edited.
    # Instead use the vendor's own debug hook: run.sh checks for /usrdata/run_dbg.sh
    # (on the WRITABLE ubifs /usrdata) and, if /usrdata/buildtime matches
    # /usr/usrdata/buildtime, runs it (as a child process) INSTEAD of the normal path.
    #
    # We do NOT regenerate the boot script (the old approach did, via awk/sed surgery
    # on run.sh - fragile: any live-vs-captured difference or a mis-stripped `fi`
    # produced a script that died before usb_gadget_configfs.sh, killing usb0/SSH).
    # Instead run_dbg.sh (au-run-dbg.template.sh) is a THIN, self-removing wrapper: it
    # PATH-shims only ar_lowdelay to run under LD_PRELOAD, then sources the LIVE,
    # verbatim run.sh normal path. USB/RF/video come up exactly as stock because it is
    # stock. The vendor's own /usr/usrdata/run_dbg.sh runs through the same
    # exec-a-child boundary and brings USB up, so this boundary is proven safe.
    #
    # SAFETY: if run_dbg.sh exists but buildtime MISMATCHES, run.sh does
    # `rm -rf /usrdata/*` and reboots. So buildtime is copied byte-exact and VERIFIED
    # before run_dbg.sh is written; abort loudly on any mismatch.
    TEMPLATE="$HERE/au-run-dbg.template.sh"
    [ -f "$TEMPLATE" ] || { echo "ABORT: missing $TEMPLATE"; exit 1; }
    echo "=== installing thin debug hook /usrdata/run_dbg.sh (writable ubifs) ==="
    device_push_as "$REPO/native/build/mmiotrace.so" /usrdata/mmiotrace.so || exit 1
    device_push_as "$TEMPLATE" /usrdata/run_dbg.sh.tmpl || exit 1
    device_push_as "$HERE/mmio-preload-remote.sh" /tmp/mmio-preload.sh || exit 1
    sshg "$MMIO_ENV /tmp/mmio-preload.sh"
    echo
    echo ">>> Now: cold power cycle A with the GOGGLE OFF. On boot, run.sh runs our"
    echo "    self-removing /usrdata/run_dbg.sh: it shims ar_lowdelay under the tracer"
    echo "    and sources the real run.sh (usb0/SSH/RF up as stock). Then turn the"
    echo "    goggle ON to trigger the stream. Then: $0 pull"
    echo ">>> To confirm the boot path took the hook (even over UART): $0 verify"
    echo ">>> When done: $0 remove-preload"
    ;;

verify)
    # Forensic check after a hooked boot: /usrdata/hook.log records each stage the
    # wrapper reached (shim install, ar_lowdelay hooked, run.sh sourced), and usb0
    # state confirms the gadget bound. Works over UART if USB is down.
    echo "=== boot-hook markers (/usrdata/hook.log) ==="
    sshg 'cat /usrdata/hook.log 2>/dev/null || echo "(no hook.log - hook did not run, or already cleaned)"'
    echo "=== usb0 gadget state (want: usb0 present, UDC attached) ==="
    sshg 'ip -o link show usb0 2>/dev/null || echo "usb0 ABSENT"; echo "udc:"; cat /sys/class/udc/*/state 2>/dev/null || echo "(no udc)"'
    echo "=== ar_lowdelay running + hooked? ==="
    # shellcheck disable=SC2016  # remote command string: $(pidof ...) and $p must expand on the device.
    sshg 'p=$(pidof ar_lowdelay 2>/dev/null); echo "pid=$p"; [ -n "$p" ] && grep -o "mmiotrace.so" /proc/$p/maps 2>/dev/null | head -1'
    echo "=== mmio.log lines so far ==="
    sshg 'wc -l /tmp/mmio.log 2>/dev/null || echo "(no mmio.log yet)"'
    ;;

remove-preload)
    echo "=== removing the debug hook (restores normal boot) ==="
    sshg '
    rm -rf /usrdata/run_dbg.sh /usrdata/run_dbg.sh.tmpl /usrdata/buildtime /usrdata/mmiotrace.so /usrdata/bin /usrdata/hook.log
    echo "run_dbg.sh present? (want: no such file)"; ls -la /usrdata/run_dbg.sh 2>&1 || true'
    ;;

pull)
    device_pull /tmp/mmio.log "$OUT/mmio.log" || exit 1
    echo "saved $OUT/mmio.log ($(wc -l < "$OUT/mmio.log") lines)"
    echo "=== VIF (0x8870xxx) writes, in order ==="
    grep -iE 'pa=0x08870' "$OUT/mmio.log" | head -80
    echo "=== the view-0 address write (reg 0x20) - reveals the DMA target + any offset ==="
    grep -iE 'pa=0x08870020' "$OUT/mmio.log"
    echo "=== CGU (0x0a104xxx) writes - the clock setup ==="
    grep -iE 'pa=0x0a104' "$OUT/mmio.log"
    echo "=== full log: $OUT/mmio.log ==="
    ;;

*)
    echo "usage: $0 {push|discover|trace <PID>|install-preload|verify|remove-preload|pull}"; exit 1 ;;
esac
