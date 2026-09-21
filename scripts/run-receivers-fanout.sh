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
RELAY_URL=${RELAY_URL:-https://10.10.1.1:4433/moq}
RECEIVER=${RECEIVER:-/local/moxygen_build/bin/moqflvreceiverclient}
LOG_DIR=${LOG_DIR:-/tmp/moq-load/sub}
NS_PREFIX=${NS_PREFIX:-flvstreamer}
RAMP=${RAMP:-0.3}        # delay between receiver launches (avoid a thundering herd)
SETTLE=${SETTLE:-10}     # seconds to wait after launch before the liveness check
WATCH=${WATCH:-10}       # re-check liveness every WATCH seconds (0 = off)

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
ramp_secs=$(awk -v t="$total" -v r="$RAMP" 'BEGIN{printf "%d", t*r}')
echo "==> $N namespaces x $FANOUT subscribers = $total receivers -> $RELAY_URL"
echo "==> ratio 1:$FANOUT  (subscribing to ${NS_PREFIX}1 .. ${NS_PREFIX}${N})"
echo "==> ramp ${ramp_secs}s at ${RAMP}s/receiver -- do NOT start profiling before it finishes"
echo

# Count receivers still alive. Sessions dying mid-run is the failure mode that
# silently deflates relay CPU: the relay forwards to fewer subscribers than you
# think it has, so the run looks "fine" but measures the wrong load.
alive_count() {
  local n=0 p
  for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && n=$(( n + 1 )); done
  echo "$n"
}

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
echo "==> All $total launched. Settling ${SETTLE}s before liveness check..."
sleep "$SETTLE"

live=$(alive_count)
failed=$(grep -ilE 'error|fail' "$LOG_DIR"/*.log 2>/dev/null | wc -l)

echo
echo "  receivers alive : $live / $total"
echo "  logs with errors: $failed / $total"

if [ "$live" -lt "$total" ] || [ "$failed" -gt 0 ]; then
  echo
  echo "  !! NOT all subscribers are healthy. The relay is fanning out to $live"
  echo "     sessions, not $total -- relay CPU will read low and will NOT be"
  echo "     reproducible between runs. Do not trust profiling from this run."
  echo
  echo "     Most likely the WebTransport early-stream race: FANOUT subscribers"
  echo "     hit the same namespace at once. Confirm the relay binary is patched:"
  echo "       grep -r drainPendingWtStreams /local/repository/moxygen/   # must hit"
  echo "       grep patchfile /local/repository/moxygen/build/fbcode_builder/manifests/proxygen"
  echo "     Both patches are commented out in setup.sh:148-155 by default."
  echo
  echo "     Sample failures:"
  grep -ilE 'error|fail' "$LOG_DIR"/*.log 2>/dev/null | head -3 \
    | xargs -r -I{} sh -c 'echo "       --- {}"; grep -iE "error|fail" {} | head -2 | sed "s/^/       /"'
else
  echo
  echo "  OK: all $total subscriber sessions healthy."
fi

echo
echo "==> Confirm the fan-out on the relay: egress should be ~${FANOUT}x ingress,"
echo "    and it should hold $total subscriber sessions, not $N."
echo "    Publisher side: N=$N ./verify-load.sh"
echo
echo "==> Ctrl-C to stop."

# Keep reporting: a session that dies at minute 3 invalidates the run just as
# thoroughly as one that never started, and nothing else would surface it.
if [ "$WATCH" -gt 0 ]; then
  while sleep "$WATCH"; do
    now=$(alive_count)
    [ "$now" -ne "$live" ] && {
      echo "  [$(date +%T)] receivers alive: $now / $total  (was $live)"
      live=$now
    }
    [ "$now" -eq 0 ] && { echo "  [$(date +%T)] all receivers gone."; break; }
  done
fi

wait
