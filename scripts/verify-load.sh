#!/usr/bin/env bash
# Prove the offered load is what you think it is.
#
# Measures actual bytes on the wire and compares against N x VB. Run this on the
# publisher (egress to relay) or the subscriber (ingress from relay) AFTER the
# load is up and has settled for ~10s.
#
#   ./verify-load.sh                          # publisher, N=40
#   N=100 ./verify-load.sh
#   N=10 FANOUT=5 IFACE=enp23s0f0np0 DIR=rx ./verify-load.sh    # subscriber side
#
# Exits non-zero if delivered bitrate is under TOL of target -- so you find out
# the run is invalid before you spend an hour profiling it.

set -uo pipefail

N=${N:-40}
FANOUT=${FANOUT:-1}
VB=${VB:-8000k}
AB=${AB:-96k}
IFACE=${IFACE:-enp23s0f0np0}
DIR=${DIR:-tx}                 # tx on publisher, rx on subscriber
SECS=${SECS:-10}
TOL=${TOL:-0.90}               # fail below 90% of target

[ -d "/sys/class/net/$IFACE" ] || { echo "FATAL: no such interface: $IFACE" >&2; exit 1; }

tokbps() {  # "8000k" | "96k" | "8000000" -> kbps
  local v=$1
  case "$v" in
    *k|*K) echo "${v%[kK]}" ;;
    *m|*M) echo $(( ${v%[mM]} * 1000 )) ;;
    *)     echo $(( v / 1000 )) ;;
  esac
}

vk=$(tokbps "$VB"); ak=$(tokbps "$AB")
streams=$(( N * FANOUT ))
target_mbps=$(( streams * (vk + ak) / 1000 ))

stat=/sys/class/net/$IFACE/statistics/${DIR}_bytes
b1=$(cat "$stat"); sleep "$SECS"; b2=$(cat "$stat")
actual_mbps=$(( (b2 - b1) * 8 / SECS / 1000000 ))

pct=0
[ "$target_mbps" -gt 0 ] && pct=$(( actual_mbps * 100 / target_mbps ))

echo "iface        : $IFACE ($DIR, ${SECS}s)"
echo "streams      : $N x $FANOUT = $streams"
echo "target       : ${target_mbps} Mbps  (${vk}+${ak} kbps each)"
echo "actual       : ${actual_mbps} Mbps"
echo "delivered    : ${pct}%"

# Publisher-side encode saturation is the usual cause of a shortfall.
if [ "$DIR" = tx ] && command -v ffmpeg >/dev/null; then
  fcpu=$(ps -eo pcpu,comm | awk '/ffmpeg/{s+=$1} END{printf "%.0f", s}')
  cap=$(( $(nproc) * 100 ))
  echo "ffmpeg cpu   : ${fcpu}% of ${cap}% available"
  if [ "${fcpu:-0}" -gt "$(( cap * 90 / 100 ))" ]; then
    echo
    echo "  !! ffmpeg is CPU-saturated -- encodes are falling behind real-time."
    echo "     Run ./make-source.sh so publishers replay with -c copy instead."
  fi
fi

floor=$(awk -v t="$target_mbps" -v f="$TOL" 'BEGIN{printf "%d", t*f}')
if [ "$actual_mbps" -lt "$floor" ]; then
  echo
  echo "FAIL: under ${floor} Mbps floor. The relay is NOT seeing $streams streams'"
  echo "      worth of traffic -- do not trust profiling numbers from this run."
  exit 1
fi

echo
echo "OK: offered load is within tolerance."
