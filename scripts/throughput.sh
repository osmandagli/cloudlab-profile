#!/usr/bin/env bash
# Relay throughput + loss, sampled in sub-windows. Run on the relay WHILE the load runs.
#   ./throughput.sh [iface]
#   env: N, W, WARM, HDR, FANOUT, ARM
#
# Counters: ethtool -S VSI stats. Verified empirically to be re-read from HW on
# every call (no ~1s service-task quantization): at a steady 200 pps, 250 ms
# samples returned 50-51 packets each. They also include AF_XDP zero-copy TX,
# which the per-queue tx_queue_* counters do not.
set -uo pipefail
export LC_ALL=C

IF=${1:-${IFACE:-eno12409np1}}
N=${N:-11}             # sub-windows (odd -> exact median)
W=${W:-3}              # seconds per sub-window
WARM=${WARM:-8}        # seconds discarded before sampling
HDR=${HDR:-42}         # eth(14)+IPv4(20)+UDP(8); wire adds preamble/SFD/FCS/IFG = 24
FANOUT=${FANOUT:-1}    # expected tx_pkts/rx_pkts; 0 disables the check
ARM=${ARM:-vanilla}    # label only: "vanilla" or "xdp"

[ -d "/sys/class/net/$IF" ] || { echo "no such interface: $IF" >&2; exit 1; }
case "$N$W" in *[!0-9]*) echo "N and W must be integers" >&2; exit 1;; esac
[ "$N" -ge 1 ] && [ "$W" -ge 1 ] || { echo "N and W must be >= 1" >&2; exit 1; }

# Fail loudly at startup if the driver does not expose a counter we rely on,
# rather than silently reporting it as zero for the whole run.
STATS=$(ethtool -S "$IF") || { echo "ethtool -S $IF failed" >&2; exit 1; }
for c in rx_bytes tx_bytes rx_unicast tx_unicast rx_dropped tx_errors \
         rx_dropped.nic tx_dropped_link_down.nic; do
  grep -qE "^ +${c//./\\.}:" <<<"$STATS" || { echo "missing counter: $c" >&2; exit 1; }
done

snap() {
  ethtool -S "$IF" | awk '
    /^ +rx_bytes:/                  {rb=$2}
    /^ +tx_bytes:/                  {tb=$2}
    /^ +rx_unicast:/                {rp=$2}
    /^ +tx_unicast:/                {tp=$2}
    /^ +rx_dropped:/                {rd=$2}
    /^ +tx_errors:/                 {te=$2}
    /^ +rx_dropped\.nic:/           {rdn=$2}
    /^ +tx_dropped_link_down\.nic:/ {tdl=$2}
    END {print rb, tb, rp, tp, rd, te, rdn, tdl}'
}
# -s so we do not clobber any other nstat baseline on the box.
udp_errs() { nstat -asz 2>/dev/null | awk '/UdpRcvbufErrors/ {print $2}'; }

TMP=$(mktemp) || exit 1
trap 'rm -f "$TMP"' EXIT

echo "iface=$IF  arm=$ARM  warmup=${WARM}s  ${N}x${W}s sub-windows  hdr=${HDR}B"
sleep "$WARM"

read -r pb ptb ppr ppt RD0 TE0 RDN0 TDL0 <<<"$(snap)"; pt=${EPOCHREALTIME/,/.}
U0=$(udp_errs)

# Chained snapshots: N+1 reads, no unmeasured gap between sub-windows.
for _ in $(seq "$N"); do
  sleep "$W"
  read -r cb ctb cpr cpt RD1 TE1 RDN1 TDL1 <<<"$(snap)"; ct=${EPOCHREALTIME/,/.}
  awk -v rdb=$((cb-pb))   -v rdp=$((cpr-ppr)) \
      -v tdb=$((ctb-ptb)) -v tdp=$((cpt-ppt)) \
      -v a="$pt" -v b="$ct" -v h="$HDR" 'BEGIN{
        el=b-a; if (el<=0) exit;
        printf "%.2f %.2f %.0f %.2f %.2f %.0f\n",
          (rdb+24*rdp)*8/el/1e6, (rdb-h*rdp)*8/el/1e6, rdp/el,
          (tdb+24*tdp)*8/el/1e6, (tdb-h*tdp)*8/el/1e6, tdp/el }' >>"$TMP"
  pb=$cb; ptb=$ctb; ppr=$cpr; ppt=$cpt; pt=$ct
done
U1=$(udp_errs)

# A short sample set means ethtool or awk failed mid-run; do not report a
# partial run as if it were a clean one.
got=$(grep -c . "$TMP")
[ "$got" -eq "$N" ] || { echo "only $got/$N samples collected" >&2; exit 1; }

col() { cut -d' ' -f"$1" "$TMP" | sort -n; }
median_col() {
  col "$1" | awk '{v[NR]=$1}
    END{print (NR%2) ? v[(NR+1)/2] : (v[NR/2]+v[NR/2+1])/2}'
}
stat_col() { # $1=column $2=printf format -> "median [min .. max] +-spread%"
  col "$1" | awk -v f="${2:-%.2f}" '{v[NR]=$1}
    END{ m = (NR%2) ? v[(NR+1)/2] : (v[NR/2]+v[NR/2+1])/2;
         s = (m>0) ? 100*(v[NR]-v[1])/m : 0;
         printf f"  ["f" .. "f"]  +-%.1f%%", m, v[1], v[NR], s }'
}

# Guard against reporting an idle link as a measurement.
if awk -v v="$(median_col 1)" 'BEGIN{exit !(v+0 < 1)}'; then
  echo "no traffic on $IF during the window -- was the load running?" >&2
  exit 1
fi

echo "  rx wire:        $(stat_col 1) Mbit/s"
echo "  rx udp payload: $(stat_col 2) Mbit/s   (QUIC packets: still includes QUIC header + AEAD tag)"
echo "  rx pps:         $(stat_col 3 %.0f)"
echo "  tx wire:        $(stat_col 4) Mbit/s"
echo "  tx udp payload: $(stat_col 5) Mbit/s"
echo "  tx pps:         $(stat_col 6 %.0f)"
echo "  loss over run:  rx_dropped=$((RD1-RD0))  rx_dropped.nic=$((RDN1-RDN0))" \
     "tx_errors=$((TE1-TE0))  tx_dropped_link_down.nic=$((TDL1-TDL0))   (all must be 0)"

if [ "$ARM" = xdp ]; then
  echo "  UdpRcvbufErrors: n/a (xdp bypasses the UDP socket; a 0 here proves nothing)"
else
  echo "  UdpRcvbufErrors over run: $((U1-U0))   (must be 0)"
fi

if [ "$FANOUT" != 0 ]; then
  awk -v tx="$(median_col 6)" -v rx="$(median_col 3)" -v f="$FANOUT" 'BEGIN{
    ratio = (rx>0) ? tx/rx : 0;
    printf "  tx/rx packet ratio: %.2f (expected ~%s)%s\n", ratio, f,
           (ratio < f*0.8 || ratio > f*1.25) ? "   <-- TOPOLOGY MISMATCH" : "" }'
fi

echo
echo "  Comparing arms: treat a difference as real only if the [min .. max]"
echo "  ranges do not overlap. If they do, raise N (more samples), not W."