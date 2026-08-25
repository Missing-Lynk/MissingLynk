#!/usr/bin/env bash
# rf-net-bench.sh - benchmark IP latency and UDP throughput over the goggle<->air RF link.
#
# This is a network-only benchmark. It does not change RF channels, MCS, bitrate, boot slots,
# flash state, or services. It records ping RTT/loss and, when iperf3 is installed on both
# endpoints, UDP loss/jitter/throughput.
#
# PREREQ:
#   - goggle reachable at DEVICE_IP as root/ROOT_PASS
#   - air powered and associated at AIR_RF_IP
#   - optional throughput: iperf3 installed on the goggle and air
#   - optional relay control: air SSH reachable through ml-tcprelay
#
# Usage:
#   AIR_CTRL_IP=192.168.3.102 glue/capture/rf-net-bench.sh
#   AIR_CTRL_IP=192.168.3.102 LENS="8192 11000 16000" RATES="12M 16M 20M" glue/capture/rf-net-bench.sh
#   DIRECTIONS=both AIR_CTRL_IP=192.168.3.102 glue/capture/rf-net-bench.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

AIR_RF_IP="${AIR_RF_IP:-10.0.0.100}"
GOGGLE_RF_IP="${GOGGLE_RF_IP:-10.0.0.1}"
AIR_CTRL_IP="${AIR_CTRL_IP:-}"
AIR_PASS="${AIR_PASS:-}"
AIR_RELAY_PORT="${AIR_RELAY_PORT:-8822}"
SLOT="${SLOT:-unknown}"
PING_N="${PING_N:-10}"
PING_INTERVAL="${PING_INTERVAL:-0.3}"
IPERF_SECS="${IPERF_SECS:-8}"
IPERF_LEN="${IPERF_LEN:-}"
LENS="${LENS:-${IPERF_LEN:-1024 2048 3584 4096 8192 11000 16000 19000}}"
RATES="${RATES:-16M 20M 24M}"
DIRECTIONS="${DIRECTIONS:-downlink}"  # both, uplink, downlink
OUT_BASE="${OUT_BASE:-$REPO/out/rf-net-bench}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT:-$OUT_BASE/$STAMP}"
MLTCPRELAY="$REPO/archive/libre/tools/ml-tcprelay/ml-tcprelay"
IPERF_JSON_SUMMARY="$HERE/iperf-json-summary.py"

# shellcheck source=../lib/ssh-opts.sh
. "$HERE/../lib/ssh-opts.sh"

AIR_PASS="${AIR_PASS:-$PASS}"

mkdir -p "$OUT"/{raw,summary}

log()
{
    printf '%s\n' "$*"
}

run_goggle()
{
    local name="$1"
    shift

    log "== $name =="
    sshg "$@" 2>&1 | tee "$OUT/raw/$name.txt"
}

air_ssh()
{
    local port="$AIR_RELAY_PORT" ip="$DEVICE_IP"

    if [ -n "$AIR_CTRL_IP" ]; then
        port="${AIR_CTRL_PORT:-22}"
        ip="$AIR_CTRL_IP"
    fi

    sshpass -p "$AIR_PASS" ssh \
        -p "$port" \
        -o ConnectTimeout=10 \
        "${SSH_OPTS_LEGACY[@]}" \
        root@"$ip" "$@"
}

start_air_relay()
{
    if [ -n "$AIR_CTRL_IP" ]; then
        air_ssh true >/dev/null 2>&1
        return
    fi

    if [ ! -x "$MLTCPRELAY" ]; then
        log "air relay unavailable: $MLTCPRELAY is missing"
        return 1
    fi

    if ! sshg "test -x /tmp/ml-tcprelay" >/dev/null 2>&1; then
        device_push_as "$MLTCPRELAY" /tmp/ml-tcprelay >/dev/null 2>&1 || return 1
    fi

    sshg "kill \$(pidof ml-tcprelay) 2>/dev/null; setsid /tmp/ml-tcprelay '$AIR_RELAY_PORT' '$AIR_RF_IP' 22 >/tmp/rf-net-bench-relay.log 2>&1 </dev/null &" \
        >/dev/null 2>&1 || return 1
    sleep 1
    air_ssh true >/dev/null 2>&1
}

have_goggle_cmd()
{
    sshg "command -v '$1' >/dev/null 2>&1" >/dev/null 2>&1
}

have_air_cmd()
{
    air_ssh "command -v '$1' >/dev/null 2>&1" >/dev/null 2>&1
}

ping_summary()
{
    awk -v label="$1" '
        /transmitted/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /transmitted/) {
                    for (j = i - 1; j >= 1; j--) {
                        if ($j ~ /^[0-9]+$/) {
                            tx = $j
                            break
                        }
                    }
                }
                if ($i ~ /received/) {
                    for (j = i - 1; j >= 1; j--) {
                        if ($j ~ /^[0-9]+$/) {
                            rx = $j
                            break
                        }
                    }
                }
                if ($i ~ /^[0-9.]+%$/) {
                    loss = $i
                }
            }
        }
        /round-trip|rtt/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9.]+\/[0-9.]+\/[0-9.]+/) {
                    split($i, a, "/")
                    min = a[1]
                    avg = a[2]
                    max = a[3]
                    mdev = a[4]
                    break
                }
            }
        }
        END {
            if (tx == "") {
                printf "%-12s no summary\n", label
            } else if (avg == "") {
                printf "%-12s tx=%s rx=%s loss=%s no-rtt\n", label, tx, rx, loss
            } else {
                printf "%-12s tx=%s rx=%s loss=%s min=%sms avg=%sms max=%sms mdev=%sms\n",
                    label, tx, rx, loss, min, avg, max, mdev
            }
        }'
}

extract_iperf_json_field()
{
    "$IPERF_JSON_SUMMARY" "$1"
}

sample_sdio()
{
    local secs="$1"
    local label="$2"

    # shellcheck disable=SC2016  # remote script: rx*/tx*/$S expand on the goggle.
    sshg 'S='"$secs"'
read rx0 tx0 < <(awk "/sdio0:/{print \$2, \$10}" /proc/net/dev)
sleep "$S"
read rx1 tx1 < <(awk "/sdio0:/{print \$2, \$10}" /proc/net/dev)
echo "'"$label"' rx_bytes=$((rx1-rx0)) tx_bytes=$((tx1-tx0)) secs=$S"' \
        > "$OUT/raw/sdio-$label.txt" 2>&1 || true
}

write_metadata()
{
    {
        echo "recorded: $STAMP"
        echo "slot: $SLOT"
        echo "goggle_ip: $DEVICE_IP"
        echo "goggle_rf_ip: $GOGGLE_RF_IP"
        echo "air_rf_ip: $AIR_RF_IP"
        echo "air_ctrl_ip: ${AIR_CTRL_IP:-relay-via-goggle:$AIR_RELAY_PORT}"
        echo "ping_n: $PING_N"
        echo "ping_interval: $PING_INTERVAL"
        echo "iperf_secs: $IPERF_SECS"
        echo "iperf_lens: $LENS"
        echo "rates: $RATES"
        echo "directions: $DIRECTIONS"
        echo
        echo "--- goggle identity ---"
        sshg 'uname -a; ip -br addr show sdio0 2>/dev/null; dmesg | grep -m1 -o "bb_[a-z_0-9]*\.img" || true' 2>&1 || true
        echo
        echo "--- goggle baseband firmware/config identity ---"
        # shellcheck disable=SC2016  # remote script: $f expands on the goggle.
        sshg 'for f in /lib/firmware/bb_demo*_d.img /lib/firmware/bb_config*.json* /usrdata/missinglynk/bb_config*.json*; do
                  [ -e "$f" ] || continue
                  ls -l "$f"
                  sha256sum "$f" 2>/dev/null || md5sum "$f" 2>/dev/null || true
              done' 2>&1 || true
        echo
        echo "--- goggle rf tail ---"
        sshg 'tail -40 /var/log/ml-linkd.log 2>/dev/null | grep -E "1v1info|snr|thr|mcs|rate|rx=" || true' 2>&1 || true
        echo
        echo "--- air identity ---"
        if [ "${AIR_SSH_OK:-0}" -eq 1 ]; then
            air_ssh 'uname -a; ip -br addr show sdio0 2>/dev/null; dmesg | grep -m1 -o "bb_[a-z_0-9]*\.img" || true' 2>&1 || true
            echo
            echo "--- air baseband firmware/config identity ---"
            # shellcheck disable=SC2016  # remote script: $f expands on the air unit.
            air_ssh 'for f in /lib/firmware/bb_demo*_d.img /lib/firmware/bb_config*.json* /usrdata/missinglynk/bb_config*.json*; do
                         [ -e "$f" ] || continue
                         ls -l "$f"
                         sha256sum "$f" 2>/dev/null || md5sum "$f" 2>/dev/null || true
                     done' 2>&1 || true
        else
            echo "air ssh unavailable"
        fi
    } > "$OUT/metadata.txt"
}

run_ping_suite()
{
    run_goggle "ping-small" "ping -c '$PING_N' -i '$PING_INTERVAL' -W 2 '$AIR_RF_IP'"
    run_goggle "ping-large" "ping -c '$PING_N' -i '$PING_INTERVAL' -s 1400 -W 2 '$AIR_RF_IP'"

    {
        ping_summary small < "$OUT/raw/ping-small.txt"
        ping_summary large < "$OUT/raw/ping-large.txt"
    } | tee "$OUT/summary/ping.txt"
}

start_iperf_server_on_air()
{
    air_ssh "kill \$(pidof iperf3) 2>/dev/null; iperf3 -s -1 >/tmp/rf-net-bench-iperf3-server.log 2>&1 &" \
        >/dev/null 2>&1
    sleep 1
}

start_iperf_server_on_goggle()
{
    sshg "kill \$(pidof iperf3) 2>/dev/null; iperf3 -s -1 >/tmp/rf-net-bench-iperf3-server.log 2>&1 &" \
        >/dev/null 2>&1
    sleep 1
}

run_iperf_goggle_to_air()
{
    local rate="$1"
    local len="$2"
    local safe_rate="${rate//[^A-Za-z0-9_.-]/_}"
    local safe_len="${len//[^A-Za-z0-9_.-]/_}"
    local raw="$OUT/raw/iperf-goggle-to-air-len${safe_len}-$safe_rate.json"
    local ping="$OUT/raw/ping-during-goggle-to-air-len${safe_len}-$safe_rate.txt"

    start_iperf_server_on_air || return 1
    sshg "ping -c '$IPERF_SECS' -i 1 -W 2 '$AIR_RF_IP' > /tmp/rf-net-bench-ping-load.log 2>&1 & \
          iperf3 -u -c '$AIR_RF_IP' -b '$rate' -t '$IPERF_SECS' -l '$len' --json; \
          cat /tmp/rf-net-bench-ping-load.log >&2" > "$raw" 2> "$ping"
    printf 'goggle->air len=%-6s rate=%-8s %s | ' "$len" "$rate" "$(extract_iperf_json_field "$raw")"
    ping_summary "ping-load" < "$ping"
}

run_iperf_air_to_goggle()
{
    local rate="$1"
    local len="$2"
    local safe_rate="${rate//[^A-Za-z0-9_.-]/_}"
    local safe_len="${len//[^A-Za-z0-9_.-]/_}"
    local raw="$OUT/raw/iperf-air-to-goggle-len${safe_len}-$safe_rate.json"
    local ping="$OUT/raw/ping-during-air-to-goggle-len${safe_len}-$safe_rate.txt"

    start_iperf_server_on_goggle || return 1
    sshg "ping -c '$IPERF_SECS' -i 1 -W 2 '$AIR_RF_IP' > /tmp/rf-net-bench-ping-load.log 2>&1 &" \
        >/dev/null 2>&1 || true
    air_ssh "iperf3 -u -c '$GOGGLE_RF_IP' -b '$rate' -t '$IPERF_SECS' -l '$len' --json" > "$raw" 2>&1
    sshg "cat /tmp/rf-net-bench-ping-load.log 2>/dev/null" > "$ping" 2>&1 || true
    printf 'air->goggle len=%-6s rate=%-8s %s | ' "$len" "$rate" "$(extract_iperf_json_field "$raw")"
    ping_summary "ping-load" < "$ping"
}

run_iperf_suite()
{
    if ! have_goggle_cmd iperf3; then
        log "skipping iperf3: iperf3 is not installed on the goggle"
        return 0
    fi

    if [ "${AIR_SSH_OK:-0}" -ne 1 ]; then
        log "skipping iperf3: air SSH is unavailable, cannot start air-side server/client"
        return 0
    fi

    if ! have_air_cmd iperf3; then
        log "skipping iperf3: iperf3 is not installed on the air"
        return 0
    fi

    log "== iperf3 UDP sweep =="
    {
        if [ "$DIRECTIONS" = "both" ] || [ "$DIRECTIONS" = "uplink" ]; then
            for len in $LENS; do
                for rate in $RATES; do
                    run_iperf_goggle_to_air "$rate" "$len" \
                        || printf 'goggle->air len=%-6s rate=%-8s failed\n' "$len" "$rate"
                done
            done
        fi
        if [ "$DIRECTIONS" = "both" ] || [ "$DIRECTIONS" = "downlink" ]; then
            for len in $LENS; do
                for rate in $RATES; do
                    run_iperf_air_to_goggle "$rate" "$len" \
                        || printf 'air->goggle len=%-6s rate=%-8s failed\n' "$len" "$rate"
                done
            done
        fi
    } | tee "$OUT/summary/iperf3.txt"
}

log "===================== RF NET BENCH ($STAMP, slot $SLOT) ====================="
log "output: $OUT"
log "goggle: $DEVICE_IP  air: $AIR_RF_IP"

if ! sshg true >/dev/null 2>&1; then
    log "cannot reach root@$DEVICE_IP as root/$PASS"
    exit 1
fi

# shellcheck disable=SC2016  # remote script: r1/r2 arithmetic runs on the goggle.
run_goggle "association" 'r1=$(awk "/sdio0:/{print \$2}" /proc/net/dev); sleep 3; r2=$(awk "/sdio0:/{print \$2}" /proc/net/dev); echo "telemetry_rx_pkts_3s=$((r2-r1))"'

AIR_SSH_OK=0
if start_air_relay; then
    AIR_SSH_OK=1
    if [ -n "$AIR_CTRL_IP" ]; then
        log "air ssh: ok direct at $AIR_CTRL_IP:${AIR_CTRL_PORT:-22}"
    else
        log "air ssh: ok via relay port $AIR_RELAY_PORT"
    fi
else
    log "air ssh: unavailable (${AIR_CTRL_IP:-relay port $AIR_RELAY_PORT})"
fi

write_metadata
sample_sdio 3 idle
run_ping_suite
run_iperf_suite

log "summary:"
sed 's/^/  /' "$OUT/summary/ping.txt"
if [ -f "$OUT/summary/iperf3.txt" ]; then
    sed 's/^/  /' "$OUT/summary/iperf3.txt"
fi
log "raw logs: $OUT/raw"
log "metadata: $OUT/metadata.txt"
log "======================================================================"
