#!/bin/sh
# mmio-trace-remote.sh - the device half of au-slotA-mmiotrace.sh trace, staged to
# /tmp/mmio-trace.sh and run there.
#
# Kills the register-writing process and relaunches its exact argv under the tracer, so the
# capture-start it performs next is logged in program order.
#
#   mmio-trace.sh <PID>
#
# The tracer window arrives as an environment variable set by the host at invocation:
#   LO HI                the physical span to trap
#   READS TIME           also trap loads; add ns timestamps
#   NOMEM                skip /dev/mem trapping, capture only the ar_sys write ioctl
#   SKIP_LO SKIP_HI      leave one span untrapped inside a wide window
#   CENSUS               log unrecognised ar_sys ioctl request numbers
pid="$1"

exe=$(readlink /proc/"$pid"/exe)
cwd=$(readlink /proc/"$pid"/cwd)
echo "exe=$exe cwd=$cwd"
tr '\0' '\n' < /proc/"$pid"/cmdline > /tmp/argv.txt
echo '--- argv ---'; cat -n /tmp/argv.txt
echo '=== stopping the current instance ==='
kill "$pid" 2>/dev/null; sleep 1
kill -9 "$pid" 2>/dev/null; sleep 1
# kill -0 succeeds on a ZOMBIE, so it reports a process we just killed as alive
# and sends you looking for a supervisor that is not there. Read the state field
# instead: Z means dead-and-unreaped, which is gone for our purposes.
st=$(awk '{print $3}' /proc/"$pid"/stat 2>/dev/null)
case "$st" in
'') echo 'still alive: no (reaped)' ;;
Z)  echo 'still alive: no (zombie, killed and unreaped)' ;;
*)  echo "still alive: YES-supervisor-respawn (state $st)" ;;
esac
echo '=== relaunching under the tracer (log /tmp/mmio.log) ==='
: > /tmp/mmio.log
cd "$cwd" 2>/dev/null || cd /
# The argv split is deliberate: each word of the captured cmdline must reach setsid as
# its own argument, so this is the one expansion that must stay unquoted.
# shellcheck disable=SC2046
LD_PRELOAD=/tmp/mmiotrace.so MMIOTRACE_OUT=/tmp/mmio.log \
	MMIOTRACE_LO=$LO MMIOTRACE_HI=$HI \
	MMIOTRACE_READS=$READS MMIOTRACE_TIME=$TIME MMIOTRACE_NOMEM=$NOMEM \
	MMIOTRACE_SKIP_LO=$SKIP_LO MMIOTRACE_SKIP_HI=$SKIP_HI MMIOTRACE_IOCTL_CENSUS=$CENSUS \
	setsid $(cat /tmp/argv.txt | tr '\n' ' ') > /tmp/cam.out 2>&1 &
sleep 8
echo '--- mmio.log size ---'; wc -l /tmp/mmio.log 2>/dev/null
echo '--- first lines ---'; head -20 /tmp/mmio.log 2>/dev/null
echo '--- cam.out tail ---'; tail -5 /tmp/cam.out 2>/dev/null
