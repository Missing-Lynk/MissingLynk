#!/usr/bin/env bash
# wave5-stage0.sh - the read-only capture the wave5 wedge plan calls Stage 0.
#
# Source it after ssh-opts.sh (it uses device_ssh_timeout):
#   . "$(dirname "${BASH_SOURCE[0]}")/../lib/wave5-stage0.sh"
#
# A wedge is recovered by a cold power cycle, which destroys the state that says what happened, so
# the capture runs BEFORE anything else touches the device. Everything here reads: no module is
# loaded, no service restarted, no register written.
#
# What decides the case is the D-state section. A task in D with v4l2_m2m_cancel_job in its stack
# confirms the pinned-job mechanism in plans/wave5-vpu-wedge-recovery.md; its absence means the
# symptom came from somewhere else and the plan needs rethinking.
#
# The process list is unfiltered. A filtered one reads as a complete list and is not: a capture
# whose ps matched only ml-* names was read as proof that the watchdog daemon was absent, when it
# could not have shown it under any circumstances - the init script runs busybox /sbin/watchdog,
# whose process carries that name and not ml-watchdog. The watchdog section states the same fact
# directly, because whether the timer was armed decides how to read a board that never came back:
# an armed timer that did not reset is a failure below the watchdog, an unarmed one says nothing.
#
# That section reads the holder from `fuser /dev/watchdog` and treats the pidfile as advisory.
# The pidfile goes stale across a crash or a restart and then names a dead or reused PID, and
# CONFIG_WATCHDOG_SYSFS is off on this kernel, so /sys/class/watchdog/watchdog0 carries only dev
# and uevent - there is no state, timeout or bootstatus to read. The open fd is the only evidence
# the timer is armed.
#
# The register reads cover 0x0a080000 (the VPU host interface) except 0x20/0x24. FIO_CTRL_ADDR and
# FIO_DATA are a stateful handshake rather than registers, and reading them moves the block.

# wave5_capture_stage0 <outfile> [regdump-path] - write the capture to a host file.
wave5_capture_stage0() {
    local outfile="$1"
    local regdump="${2:-/tmp/ml-regdump}"

    device_ssh_timeout 90 "
        R=$regdump
        echo '=== uptime'; cut -d. -f1 /proc/uptime
        echo '=== D-state tasks'
        for p in /proc/[0-9]*; do
            s=\$(awk '/^State:/{print \$2}' \$p/status 2>/dev/null)
            [ \"\$s\" = D ] || continue
            echo \"--- pid \$(basename \$p) \$(tr '\\0' ' ' < \$p/cmdline 2>/dev/null)\"
            cat \$p/stack 2>/dev/null
        done
        echo '=== video nodes'; ls -la /dev/video* 2>&1
        echo '=== processes'; ps w
        echo '=== watchdog'
        ls -la /dev/watchdog 2>&1
        H=\$(fuser /dev/watchdog 2>/dev/null | tr -d ' ')
        echo \"holder=\${H:-NONE}\"
        [ -n \"\$H\" ] && tr '\\0' ' ' < /proc/\$H/cmdline 2>/dev/null
        echo
        echo \"pidfile=\$(cat /run/ml-watchdog.pid 2>/dev/null || echo none)\"
        echo '=== wave5 refcount'; lsmod | grep -i wave5
        echo '=== PC sample 1'; \$R 0x0a080004 1
        echo '=== PC sample 2'; \$R 0x0a080004 1
        echo '=== PC sample 3'; \$R 0x0a080004 1
        echo '=== 0x38..0x4c HOST_INT_REQ/INT_STS/VINT_REASON'; \$R 0x0a080038 6
        echo '=== 0x70..0x7c BUSY/HALT/VCPU status'; \$R 0x0a080070 4
        echo '=== 0x98 RET_VPU_CONFIG0'; \$R 0x0a080098 1
        echo '=== 0x100..0x110 COMMAND/RET_SUCCESS/FAIL_REASON/INSTANCE'; \$R 0x0a080100 5
        echo '=== 0x1e0..0x1fc queue + stage instance info'; \$R 0x0a0801e0 8
        echo '=== dmesg tail'; dmesg 2>/dev/null | tail -160
        echo '=== wedge signatures'
        dmesg 2>/dev/null | grep -icE 'blocked for more than|result not ready|timed out|VPU reload failed|did not stop'
        dmesg 2>/dev/null | grep -iE 'blocked for more than|result not ready|timed out|VPU reload|VPU recovered|abandoning the drain|wave5' | tail -20
    " </dev/null > "$outfile" 2>&1
}
