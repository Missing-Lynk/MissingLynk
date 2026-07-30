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
. "$HERE/../lib/ssh-opts.sh"

AU_IP="${AU_IP:-192.168.3.100}"		# STOCK slot A
AU_PORT="${AU_PORT:-22}"
AU_PASS="${AU_PASS:-artosyn}"		# vendor password
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
mkdir -p "$OUT"

au() {
    sshpass -p "$AU_PASS" ssh "${SSH_OPTS_LEGACY[@]}" -p "$AU_PORT" "root@$AU_IP" "$@"
}
push_file() {
    sshpass -p "$AU_PASS" ssh "${SSH_OPTS_LEGACY[@]}" -p "$AU_PORT" "root@$AU_IP" "cat > $2" < "$1" \
        && echo "pushed $2"
}

cmd="${1:-discover}"

case "$cmd" in
push)
    push_file "$REPO/native/build/mmiotrace.so" /tmp/mmiotrace.so
    push_file "$REPO/native/build/ml-regdump" /tmp/ml-regdump
    au 'chmod +x /tmp/ml-regdump; ls -la /tmp/mmiotrace.so /tmp/ml-regdump'
    ;;

discover)
    echo "=== processes that map MMIO (/dev/mem or /dev/ar_sys) = the register writers ==="
    # shellcheck disable=SC2016  # remote command string: the loop expands on the device, not here.
    au '
    for m in /proc/[0-9]*/maps; do
      pid=${m%/maps}; pid=${pid##*/}
      if grep -qE "/dev/mem|/dev/ar_sys" "$m" 2>/dev/null; then
        comm=$(cat /proc/$pid/comm 2>/dev/null)
        cl=$(tr "\0" " " < /proc/$pid/cmdline 2>/dev/null)
        ppid=$(awk "/^PPid:/{print \$2}" /proc/$pid/status 2>/dev/null)
        pcomm=$(cat /proc/$ppid/comm 2>/dev/null)
        echo "PID=$pid comm=$comm PPid=$ppid($pcomm)"
        echo "   cmd: $cl"
        echo "   exe: $(readlink /proc/$pid/exe 2>/dev/null)  cwd: $(readlink /proc/$pid/cwd 2>/dev/null)"
        echo "   maps: $(grep -oE "/dev/(mem|ar_sys)" "$m" | sort -u | tr "\n" " ")"
      fi
    done
    echo "=== how the camera daemon is started (init) ==="
    grep -rniE "camera|ldrt|arlink|vin|mpp|server|vi_" /etc/init.d/ /etc/inittab /etc/rc* 2>/dev/null | head -20
    echo "=== running procs (camera-ish) ==="
    ps -w 2>/dev/null | grep -iE "camera|ldrt|arlink|vin|mpp|server|cam" | grep -v grep'
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
    au "
    exe=\$(readlink /proc/$pid/exe)
    cwd=\$(readlink /proc/$pid/cwd)
    echo \"exe=\$exe cwd=\$cwd\"
    tr '\0' '\n' < /proc/$pid/cmdline > /tmp/argv.txt
    echo '--- argv ---'; cat -n /tmp/argv.txt
    echo '=== stopping the current instance ==='
    kill $pid 2>/dev/null; sleep 1
    kill -9 $pid 2>/dev/null; sleep 1
    # kill -0 succeeds on a ZOMBIE, so it reports a process we just killed as alive
    # and sends you looking for a supervisor that is not there. Read the state field
    # instead: Z means dead-and-unreaped, which is gone for our purposes.
    st=\$(awk '{print \$3}' /proc/$pid/stat 2>/dev/null)
    case \"\$st\" in
      '') echo 'still alive: no (reaped)' ;;
      Z)  echo 'still alive: no (zombie, killed and unreaped)' ;;
      *)  echo \"still alive: YES-supervisor-respawn (state \$st)\" ;;
    esac
    echo '=== relaunching under the tracer (log /tmp/mmio.log) ==='
    : > /tmp/mmio.log
    cd \"\$cwd\" 2>/dev/null || cd /
    LD_PRELOAD=/tmp/mmiotrace.so MMIOTRACE_OUT=/tmp/mmio.log \
      MMIOTRACE_LO=$LO MMIOTRACE_HI=$HI \
      MMIOTRACE_READS=$READS MMIOTRACE_TIME=$TIME MMIOTRACE_NOMEM=$NOMEM \
      MMIOTRACE_SKIP_LO=$SKIP_LO MMIOTRACE_SKIP_HI=$SKIP_HI MMIOTRACE_IOCTL_CENSUS=$CENSUS \
      setsid \$(cat /tmp/argv.txt | tr '\n' ' ') > /tmp/cam.out 2>&1 &
    sleep 8
    echo '--- mmio.log size ---'; wc -l /tmp/mmio.log 2>/dev/null
    echo '--- first lines ---'; head -20 /tmp/mmio.log 2>/dev/null
    echo '--- cam.out tail ---'; tail -5 /tmp/cam.out 2>/dev/null"
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
    push_file "$REPO/native/build/mmiotrace.so" /usrdata/mmiotrace.so
    push_file "$TEMPLATE" /usrdata/run_dbg.sh.tmpl
    # shellcheck disable=SC2016  # remote command string: every expansion below runs on the device.
    au '
    set -e
    # 1. buildtime byte-exact FIRST, then verify - guards the rm -rf /usrdata/* wipe path.
    cp /usr/usrdata/buildtime /usrdata/buildtime
    o=$(md5sum /usr/usrdata/buildtime | cut -d" " -f1)
    n=$(md5sum /usrdata/buildtime   | cut -d" " -f1)
    if [ "$o" != "$n" ]; then echo "ABORT: buildtime mismatch ($o != $n) - NOT writing run_dbg.sh"; rm -f /usrdata/run_dbg.sh /usrdata/run_dbg.sh.tmpl; exit 1; fi
    echo "buildtime match: $n"
    # 2. resolve the REAL ar_lowdelay absolute path - abort if not found (a broken
    #    shim with an empty target would recurse). Then substitute placeholders.
    REAL=$(command -v ar_lowdelay 2>/dev/null || true)
    if [ -z "$REAL" ]; then for d in /usr/bin /bin /usr/sbin /sbin /usr/usrdata; do [ -x "$d/ar_lowdelay" ] && REAL="$d/ar_lowdelay" && break; done; fi
    if [ -z "$REAL" ] || [ ! -x "$REAL" ]; then echo "ABORT: cannot locate real ar_lowdelay"; rm -f /usrdata/run_dbg.sh.tmpl; exit 1; fi
    echo "real ar_lowdelay: $REAL"
    sed -e "s#__REAL__#$REAL#g" -e "s#__LO__#'"$LO"'#g" -e "s#__HI__#'"$HI"'#g" \
      -e "s#__READS__#'"$READS"'#g" -e "s#__TIME__#'"$TIME"'#g" \
      -e "s#__NOMEM__#'"$NOMEM"'#g" \
      -e "s#__SKIP_LO__#'"$SKIP_LO"'#g" -e "s#__SKIP_HI__#'"$SKIP_HI"'#g" \
      -e "s#__CENSUS__#'"$CENSUS"'#g" \
      /usrdata/run_dbg.sh.tmpl > /usrdata/run_dbg.sh
    rm -f /usrdata/run_dbg.sh.tmpl
    chmod +x /usrdata/run_dbg.sh
    # 3. sanity: no placeholders left, the shim env line is present, real path is executable.
    if grep -q "__REAL__\|__LO__\|__HI__\|__READS__\|__TIME__\|__NOMEM__\|__SKIP_LO__\|__SKIP_HI__\|__CENSUS__" /usrdata/run_dbg.sh; then echo "ABORT: unsubstituted placeholder in run_dbg.sh"; rm -f /usrdata/run_dbg.sh; exit 1; fi
    echo "--- shim LD_PRELOAD line (want mmiotrace.so + real path + window) ---"
    grep -n "LD_PRELOAD=/usrdata/mmiotrace.so" /usrdata/run_dbg.sh
    echo "--- self-remove + verbatim run.sh source present? (want both) ---"
    grep -nE "rm -f /usrdata/run_dbg.sh|\. /usr/usrdata/run.sh" /usrdata/run_dbg.sh
    # 4. FLUSH to flash before the operator can power-cut. /usrdata is ubifs;
    #    without this the write cache can lose buildtime while run_dbg.sh persists,
    #    which trips run.sh mismatch guard (rm -rf /usrdata/*; reboot) and scrubs the
    #    hook. Sync, then re-verify the on-flash buildtime still matches by dropping
    #    caches is not available, so cmp the two files after sync as the persistence
    #    check the boot gate itself will do.
    sync; sync
    if ! cmp -s /usr/usrdata/buildtime /usrdata/buildtime; then
      echo "ABORT: buildtime mismatch AFTER sync - the gate would wipe the hook; not leaving it armed"
      rm -f /usrdata/run_dbg.sh; sync; exit 1
    fi
    echo "synced; buildtime persisted and still matches"
    echo "--- staged ---"; ls -la /usrdata/run_dbg.sh /usrdata/buildtime /usrdata/mmiotrace.so'
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
    au 'cat /usrdata/hook.log 2>/dev/null || echo "(no hook.log - hook did not run, or already cleaned)"'
    echo "=== usb0 gadget state (want: usb0 present, UDC attached) ==="
    au 'ip -o link show usb0 2>/dev/null || echo "usb0 ABSENT"; echo "udc:"; cat /sys/class/udc/*/state 2>/dev/null || echo "(no udc)"'
    echo "=== ar_lowdelay running + hooked? ==="
    # shellcheck disable=SC2016  # remote command string: $(pidof ...) and $p must expand on the device.
    au 'p=$(pidof ar_lowdelay 2>/dev/null); echo "pid=$p"; [ -n "$p" ] && grep -o "mmiotrace.so" /proc/$p/maps 2>/dev/null | head -1'
    echo "=== mmio.log lines so far ==="
    au 'wc -l /tmp/mmio.log 2>/dev/null || echo "(no mmio.log yet)"'
    ;;

remove-preload)
    echo "=== removing the debug hook (restores normal boot) ==="
    au '
    rm -rf /usrdata/run_dbg.sh /usrdata/run_dbg.sh.tmpl /usrdata/buildtime /usrdata/mmiotrace.so /usrdata/bin /usrdata/hook.log
    echo "run_dbg.sh present? (want: no such file)"; ls -la /usrdata/run_dbg.sh 2>&1 || true'
    ;;

pull)
    sshpass -p "$AU_PASS" ssh "${SSH_OPTS_LEGACY[@]}" -p "$AU_PORT" "root@$AU_IP" \
        'cat /tmp/mmio.log' > "$OUT/mmio.log" 2>/dev/null
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
