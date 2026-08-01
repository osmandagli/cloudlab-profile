#!/usr/bin/env bash
# MoQ relay load generator -- RECEIVER side.
# Runs N moqflvreceiverclient instances, one per publisher namespace.
#
# Start this AFTER run-publishers.sh: the relay looks up the namespace with
# createMissingNodes=false (MoQRelay.cpp:1382), so subscribe-before-announce
# fails rather than waiting.
#
#   ./run-receivers.sh
#   N=5 ./run-receivers.sh
#
# No --flv_outpath is passed, so nothing is written to disk -- we want the
# relay's egress cost measured, not this box's I/O.

set -uo pipefail

N=${N:-10}
RELAY_URL=${RELAY_URL:-https://10.10.2.2:4433/moq}
RECEIVER=${RECEIVER:-/local/moxygen_build/bin/moqflvreceiverclient}
LOG_DIR=${LOG_DIR:-/tmp/moq-load/sub}
NS_PREFIX=${NS_PREFIX:-flvstreamer}

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

echo "==> $N receivers -> $RELAY_URL"
echo "==> subscribing to: ${NS_PREFIX}1 .. ${NS_PREFIX}${N}"
echo

for i in $(seq 1 "$N"); do
  "$RECEIVER" \
    --insecure \
    --connect_url "$RELAY_URL" \
    --track_namespace "${NS_PREFIX}${i}" \
    --logging INFO \
    > "$LOG_DIR/receiver$i.log" 2>&1 &
  pids+=($!)
  printf "  [%2d/%d] %s%d\n" "$i" "$N" "$NS_PREFIX" "$i"
  sleep 0.3
done

echo
echo "==> All $N receivers launched. Sanity-check for subscribe failures:"
echo "      grep -il 'error\\|fail' $LOG_DIR/*.log"
echo
echo "==> Ctrl-C to stop."
wait
