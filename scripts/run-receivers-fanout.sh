#!/usr/bin/env bash
# MoQ relay load generator -- RECEIVER side, WITH FAN-OUT.
# Runs FANOUT receivers per publisher namespace, i.e. the relay must forward
# each ingress track to FANOUT independent subscriber sessions.
#
# This is the sibling of run-receivers.sh (which is 1:1). Use it to isolate the
# per-subscriber fan-out cost: hold ingress constant (same N publishers) and
# raise FANOUT, so only the egress path (per-subscriber re-encrypt / IOBuf
# clone / buffering in MoQForwarder) scales.
#
#   N=1  FANOUT=5  ./run-receivers-fanout.sh     # a single 1:5 test
#   N=10 FANOUT=5  ./run-receivers-fanout.sh     # 10 publishers x 5 = 50 subs
#   N=40 FANOUT=1  ./run-receivers-fanout.sh     # == the old 1:1 baseline
#
# Start this AFTER run-publishers.sh: the relay looks up the namespace with
# createMissingNodes=false (MoQRelay.cpp:1382), so subscribe-before-announce
# fails rather than waiting.
#
# NOTE: FANOUT subscribers connect to the SAME namespace at nearly the same
# time. That is exactly the early-stream race your WebTransport patch fixes --
# it fires far more often here than at 1:1, so confirm the patched relay binary
# is the one running (grep the relay log for dropped/segfaulted sessions).
#
# No --flv_outpath is passed, so nothing is written to disk -- we want the
# relay's egress cost measured, not this box's I/O.

set -uo pipefail

N=${N:-10}               # number of publisher namespaces (ingress streams)
FANOUT=${FANOUT:-5}      # subscribers per namespace (the 1:FANOUT ratio)
RELAY_URL=${RELAY_URL:-https://10.10.2.2:4433/moq}
RECEIVER=${RECEIVER:-/local/moxygen_build/bin/moqflvreceiverclient}
LOG_DIR=${LOG_DIR:-/tmp/moq-load/sub}
NS_PREFIX=${NS_PREFIX:-flvstreamer}
RAMP=${RAMP:-0.3}        # delay between receiver launches (avoid a thundering herd)

pids=()

cleanup() {
  echo
  echo "==> Stopping ${#pids[@]} receivers..."
  if [ ${#pids[@]} -gt 0 ]; then
    kill "${pids[@]}" 2>/dev/null
    sleep 1
    kill -9 "${pids[@]}" 2>/dev/null
  fi
  echo "==> Done. Logs kept in $LOG_DIR"
}
trap cleanup EXIT INT TERM

[ -x "$RECEIVER" ] || { echo "FATAL: receiver not found: $RECEIVER" >&2; exit 1; }
mkdir -p "$LOG_DIR"

total=$(( N * FANOUT ))
echo "==> $N namespaces x $FANOUT subscribers = $total receivers -> $RELAY_URL"
echo "==> ratio 1:$FANOUT  (subscribing to ${NS_PREFIX}1 .. ${NS_PREFIX}${N})"
echo

k=0
for i in $(seq 1 "$N"); do
  for j in $(seq 1 "$FANOUT"); do
    k=$(( k + 1 ))
    "$RECEIVER" \
      --insecure \
      --connect_url "$RELAY_URL" \
      --track_namespace "${NS_PREFIX}${i}" \
      --logging INFO \
      > "$LOG_DIR/receiver_ns${i}_c${j}.log" 2>&1 &
    pids+=($!)
    printf "  [%3d/%d] %s%d  (copy %d/%d)\n" "$k" "$total" "$NS_PREFIX" "$i" "$j" "$FANOUT"
    sleep "$RAMP"
  done
done

echo
echo "==> All $total receivers launched. Sanity checks:"
echo "      grep -il 'error\\|fail' $LOG_DIR/*.log     # subscribe failures"
echo "    On the relay, confirm the fan-out actually happened:"
echo "      egress bitrate should be ~${FANOUT}x ingress (ss -i / ifstat on the sub NIC)"
echo "      relay should hold $total subscriber sessions, not $N"
echo
echo "==> Ctrl-C to stop."
wait
