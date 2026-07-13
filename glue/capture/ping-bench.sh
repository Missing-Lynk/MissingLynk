#!/usr/bin/env bash
# ping-bench.sh - fast authoritative goggle->air link benchmark (~80s total).
# Runs small (56B) and large (1400B) pings CONCURRENTLY so both sample the SAME
# time window (removes the sequential temporal confound) and the whole test fits
# a short air-battery window. 1s spacing on both slots (busybox A has no -i), so
# slot A (vendor, busybox) and slot B (open, iputils) are directly comparable.
# Full stats per size: loss%, mean, stddev, min/p50/p90/p99/max.
#
# NOTE: do NOT run ml-rf-video during this (it wedges the air). Slot A streams
# video while measured (its normal state) - note it when comparing.
#
# Usage: DEVICE_IP=192.168.3.100 ROOT_PASS=libre SLOT=B N=75 glue/capture/ping-bench.sh
set -uo pipefail
SLOT="${SLOT:-?}"; N="${N:-75}"
. "$(dirname "$0")/../lib/ssh-opts.sh"   # provides device_ssh_timeout + DEVICE_IP/PASS defaults
sshb(){ device_ssh_timeout $((N+70)) "$@"; }

stats(){ # parse a ping log on stdin, label $1
  awk -v label="$1" '
    /transmitted/{ for(i=1;i<=NF;i++){
        if($i ~ /transmitted/){ for(j=i;j>=1;j--) if($j ~ /^[0-9]+$/){sent=$j;break} }
        if($i ~ /received/)   { for(j=i;j>=1;j--) if($j ~ /^[0-9]+$/){recv=$j;break} } } }
    /time=/{ for(i=1;i<=NF;i++) if($i~/^time=/){ split($i,a,"="); v[n++]=a[2]; s+=a[2] } }
    END{
      if(sent=="")sent="'$N'"
      if(n==0){
        printf "  %-7s sent=%s recv=%s  NO REPLIES\n", label, sent, recv+0
      } else {
        mean=s/n; for(i=0;i<n;i++){d=v[i]-mean;ss+=d*d} sd=sqrt(ss/n)
        for(i=0;i<n;i++)for(j=i+1;j<n;j++)if(v[j]<v[i]){t=v[i];v[i]=v[j];v[j]=t}
        loss=(sent-recv)/sent*100
        printf "  %-7s LOSS=%.1f%% (sent=%d recv=%d)  mean=%.0f sd=%.0f min=%.0f p50=%.0f p90=%.0f p99=%.0f max=%.0f\n",
               label, loss, sent, recv, mean, sd, v[0], v[int(0.50*(n-1))], v[int(0.90*(n-1))], v[int(0.99*(n-1))], v[n-1]
      }
    }'
}

echo "============ PING BENCH (slot $SLOT, N=$N/size, concurrent, 1s spacing, ~$((N+5))s) ============"
out="$(sshb "
  ping -c $N -s 56   10.0.0.100 >/tmp/pb_small.log 2>&1 &
  ping -c $N -s 1400 10.0.0.100 >/tmp/pb_large.log 2>&1 &
  wait
  echo '=====SMALL====='; cat /tmp/pb_small.log
  echo '=====LARGE====='; cat /tmp/pb_large.log
")"
printf '%s\n' "$out" | awk '/=====SMALL=====/{f=1;next}/=====LARGE=====/{f=0}f' | stats "small"
printf '%s\n' "$out" | awk '/=====LARGE=====/{f=1;next}f' | stats "large"
echo "================================================================================"
