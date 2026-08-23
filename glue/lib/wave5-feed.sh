#!/usr/bin/env bash
# wave5-feed.sh - bring up the goggle's synthetic downlink so video really is flowing.
#
# Source it after ssh-opts.sh (it uses sshg):
#   . "$(dirname "${BASH_SOURCE[0]}")/../lib/wave5-feed.sh"
#
# A wedge experiment on the goggle only means something if the decode path is live when it runs,
# and a goggle with no air unit decodes nothing. ml-fake-air answers the control plane and
# ml-rf-replay pushes a recorded downlink at it, which drives the real decode, compose and flip
# chain from a host with no radio in the room.
#
# lo must be UP and carrying the air unit's link address after every reboot: ml-linkd addresses the
# air unit at 10.0.0.100 and the fake air answers there.

# wave5_feed_up <stage-dir> <dump-name> [air-ip] - start the fake air unit and the replay.
# Prints one line of state: lo=<n> air=<up|dead> replay=<up|dead>.
wave5_feed_up() {
    local stage="$1"
    local dump="$2"
    local air_ip="${3:-10.0.0.100}"

    sshg "ip link set lo up 2>/dev/null
          ip addr add $air_ip/32 dev lo 2>/dev/null
          rc-service ml-watchdog status >/dev/null 2>&1 || rc-service ml-watchdog start >/dev/null 2>&1
          pgrep ml-pipeline >/dev/null || { rc-service ml-video zap; rc-service ml-video start; sleep 6; }
          pkill ml-rf-replay 2>/dev/null; pkill ml-fake-air 2>/dev/null; sleep 1
          setsid '$stage/ml-fake-air' > /var/log/ml-fake-air.log 2>&1 </dev/null &
          sleep 2
          setsid '$stage/ml-rf-replay' '$stage/$dump' --loop > /var/log/ml-soak-replay.log 2>&1 </dev/null &
          sleep 3
          echo lo=\$(ip -4 addr show lo | grep -c inet) air=\$(pgrep ml-fake-air >/dev/null && echo up || echo dead) replay=\$(pgrep ml-rf-replay >/dev/null && echo up || echo dead)" </dev/null
}

# wave5_flips - cumulative video flip count. The 1 Hz "lat n=" summary is the reliable signal;
# per-flip latraw logging is not always enabled. ml-logd truncates /var/log mid-run to reclaim
# space, so a caller must read a DECREASE as a truncation and re-baseline, never as a stall.
# Bounded, because this runs once per cycle in a loop that must notice a device going away. An
# unbounded ssh here hangs the whole harness on a unit that has stopped answering, which reads as
# "the soak is still running" for as long as anyone leaves it.
wave5_flips() {
    device_ssh_timeout 20 'grep -c "lat n=" /var/log/ml-pipeline.log 2>/dev/null || echo 0'         </dev/null 2>/dev/null
}
