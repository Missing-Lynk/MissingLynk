#!/usr/bin/env bash
# capture-identity.sh - record what a measurement was taken against.
#
# Two latency captures are comparable only when both name the build they ran on and the runtime
# knobs that were armed. The knobs matter as much as the build: a capture taken with the forced
# vblank-phase injector armed reads ~2 s of rx2flip and a fraction of the frame rate, and nothing
# in the numbers themselves says why. The same applies to the pacing servo, which steers the pixel
# clock out from under a run, and to the pixel clock itself, which is a settable leaf.
#
# The witness for the flags is the running process's own environment, not the flag directory:
# ml-video-up reads /usrdata/missinglynk at ml-video start and exports ML_* from it, so a flag
# added or removed since that start is visible in the directory but has no effect on the process
# being measured. /proc/<pid>/environ is what the measurement actually ran under.
#
# Source after ssh-opts.sh; capture_identity <repo-root> writes a report to stdout.

# capture_identity <repo-root>
capture_identity() {
    local repo="$1" sub

    echo "--- host tree ---"
    printf 'superproject %s\n' "$(git -C "$repo" describe --always --dirty 2>/dev/null)"
    printf '             %s\n' "$(git -C "$repo" log -1 --format='%H %ci' 2>/dev/null)"
    printf '             %s\n' "$(git -C "$repo" log -1 --format='%s' 2>/dev/null)"
    for sub in kernel userspace rootfs android native flasher; do
        [ -e "$repo/$sub/.git" ] || continue
        printf '%-12s %-24s %s\n' "$sub" \
            "$(git -C "$repo/$sub" describe --always --dirty 2>/dev/null)" \
            "$(git -C "$repo/$sub" log -1 --format='%s' 2>/dev/null)"
    done

    echo
    echo "--- host tree, uncommitted files ---"
    git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null || true
    for sub in kernel userspace rootfs; do
        [ -e "$repo/$sub/.git" ] || continue
        git -C "$repo/$sub" status --porcelain --untracked-files=no 2>/dev/null |
            sed "s|^\(...\)|\1$sub/|" || true
    done

    echo
    echo "--- device build ---"
    # shellcheck disable=SC2016  # uname, the module path and the uptime read expand on the device
    sshg '
        cat /etc/ml-release 2>/dev/null
        echo "kernel        $(uname -r)"
        ko=$(find /lib/modules -name ml_dmablit.ko 2>/dev/null | head -1)
        [ -n "$ko" ] && echo "ml_dmablit.ko $(sha256sum "$ko" | cut -c1-16)"
        echo "uptime_s      $(cut -d. -f1 /proc/uptime)"
    ' </dev/null 2>&1 || true

    echo
    echo "--- runtime knobs ---"
    # shellcheck disable=SC2016  # the pid lookup and /proc read expand on the device
    sshg '
        echo "pixclk_hz     $(cat /sys/kernel/debug/ar9311_pixclk_rate 2>/dev/null)"
        p=$(pgrep ml-pipeline | tail -1)
        if [ -n "$p" ]; then
            echo "ml-pipeline   pid $p"
            echo "ML_* environment the running pipeline was started with:"
            tr "\0" "\n" < "/proc/$p/environ" | grep "^ML_" | sort | sed "s/^/  /"
        else
            echo "ml-pipeline   not running"
        fi
        echo "flag files now present in /usrdata/missinglynk:"
        ls -1 /usrdata/missinglynk 2>/dev/null | sed "s/^/  /"
    ' </dev/null 2>&1 || true
}
