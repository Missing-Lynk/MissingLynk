#!/bin/sh
# mmio-discover-remote.sh - the device half of au-slotA-mmiotrace.sh discover, staged to
# /tmp/mmio-discover.sh and run there.
#
# Names the process that writes camera registers, so the caller knows which PID to relaunch
# under the tracer. A process qualifies by having /dev/mem or /dev/ar_sys in its maps: those
# are the only two ways to reach the register space from userspace on this firmware.
#
# Read-only. Takes no arguments and no environment.
for m in /proc/[0-9]*/maps; do
	pid=${m%/maps}; pid=${pid##*/}
	if grep -qE "/dev/mem|/dev/ar_sys" "$m" 2>/dev/null; then
		comm=$(cat /proc/"$pid"/comm 2>/dev/null)
		cl=$(tr "\0" " " < /proc/"$pid"/cmdline 2>/dev/null)
		ppid=$(awk "/^PPid:/{print \$2}" /proc/"$pid"/status 2>/dev/null)
		pcomm=$(cat /proc/"$ppid"/comm 2>/dev/null)
		echo "PID=$pid comm=$comm PPid=$ppid($pcomm)"
		echo "   cmd: $cl"
		echo "   exe: $(readlink /proc/"$pid"/exe 2>/dev/null)  cwd: $(readlink /proc/"$pid"/cwd 2>/dev/null)"
		echo "   maps: $(grep -oE "/dev/(mem|ar_sys)" "$m" | sort -u | tr "\n" " ")"
	fi
done
echo "=== how the camera daemon is started (init) ==="
grep -rniE "camera|ldrt|arlink|vin|mpp|server|vi_" /etc/init.d/ /etc/inittab /etc/rc* 2>/dev/null | head -20
echo "=== running procs (camera-ish) ==="
# shellcheck disable=SC2009  # busybox has no pgrep, and the full argv is the point here
ps -w 2>/dev/null | grep -iE "camera|ldrt|arlink|vin|mpp|server|cam" | grep -v grep
