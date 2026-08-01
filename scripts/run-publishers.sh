#!/usr/bin/env bash
# MoQ relay load generator -- PUBLISHER side.
# Runs N independent streams: ffmpeg -> fifo -> moqflvstreamerclient -> relay.
#
#   ./run-publishers.sh              # 10 streams, 1080p @ 8Mbps
#   N=5 VB=4000k RES=1280x720 ./run-publishers.sh
#
# Ctrl-C tears everything down.

set -uo pipefail

N=${N:-40}
RELAY_URL=${RELAY_URL:-https://10.10.1.2:4433/moq}
SRC=${SRC:-$HOME/Movies/asian-commercial.flv}
RES=${RES:-1920x1080}
VB=${VB:-8000k}
AB=${AB:-96k}
FIFO_DIR=${FIFO_DIR:-$HOME/Movies}
LOG_DIR=${LOG_DIR:-/tmp/moq-load/pub}
STREAMER=${STREAMER:-/local/moxygen_build/bin/moqflvstreamerclient}
NS_PREFIX=${NS_PREFIX:-flvstreamer}

pids=()

cleanup() {
  echo
  echo "==> Stopping ${#pids[@]} processes..."
  if [ ${#pids[@]} -gt 0 ]; then
    kill "${pids[@]}" 2>/dev/null
    sleep 1
    kill -9 "${pids[@]}" 2>/dev/null
  fi
  for i in $(seq 1 "$N"); do rm -f "$FIFO_DIR/fifo$i.flv"; done
  echo "==> Done. Logs kept in $LOG_DIR"
}
trap cleanup EXIT INT TERM

[ -r "$SRC" ]      || { echo "FATAL: source not readable: $SRC" >&2; exit 1; }
[ -x "$STREAMER" ] || { echo "FATAL: streamer not found: $STREAMER" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "FATAL: ffmpeg not in PATH" >&2; exit 1; }

mkdir -p "$LOG_DIR" "$FIFO_DIR"
W=${RES%x*}; H=${RES#*x}

echo "==> $N streams -> $RELAY_URL"
echo "==> ${RES} @ ${VB} video + ${AB} audio, looping $(basename "$SRC")"
echo "==> namespaces: ${NS_PREFIX}1 .. ${NS_PREFIX}${N}"
echo

for i in $(seq 1 "$N"); do
  fifo="$FIFO_DIR/fifo$i.flv"
  rm -f "$fifo"
  mkfifo "$fifo"

  # Streamer first -- it opens the fifo for reading. ffmpeg's open() for write
  # blocks until a reader attaches, so this order is load-bearing.
  "$STREAMER" \
    --insecure \
    --connect_url "$RELAY_URL" \
    --input_flv_file "$fifo" \
    --track_namespace "${NS_PREFIX}${i}" \
    --logging INFO \
    > "$LOG_DIR/streamer$i.log" 2>&1 &
  pids+=($!)

  # -stream_loop -1 is required: the clip is only 28s and a profiling run is 60s.
  ffmpeg -nostdin -y -hide_banner -loglevel warning \
    -stream_loop -1 -re -i "$SRC" \
    -vf "scale=$W:$H" \
    -c:v libx264 -b:v "$VB" -g 60 -keyint_min 60 \
    -profile:v baseline -preset veryfast \
    -c:a aac -b:a "$AB" \
    -f flv "$fifo" \
    > "$LOG_DIR/ffmpeg$i.log" 2>&1 &
  pids+=($!)

  printf "  [%2d/%d] %s%d\n" "$i" "$N" "$NS_PREFIX" "$i"
  sleep 0.5
done

echo
echo "==> All $N streams launched. Verify on the relay:"
echo "      mpstat -P 2 1          # expect ~1% per stream"
echo "      grep 'already published' <relay log>   # non-empty = namespace collision"
echo
echo "==> Now start the receivers, then record. Ctrl-C here to stop."
wait
