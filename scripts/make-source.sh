#!/usr/bin/env bash
# Pre-encode the load-generator source ONCE.
#
# run-publishers.sh used to run a live x264 1080p encode per stream (~1.2 cores
# each), so past ~45 streams the publisher box saturated and ffmpeg silently
# fell behind real-time -- the relay then saw a fraction of the intended load,
# varying run to run. Encoding once and replaying with -c copy makes the offered
# load exactly N x VB, deterministically.
#
#   ./make-source.sh                       # 1920x1080 @ 8Mbps, 600s
#   RES=1280x720 VB=4000k ./make-source.sh
#
# DUR defaults to 600s so a normal profiling run never has to loop the file.

set -euo pipefail

SRC=${SRC:-$HOME/Movies/asian-commercial.flv}
RES=${RES:-1920x1080}
VB=${VB:-8000k}
AB=${AB:-96k}
DUR=${DUR:-600}
PRE=${PRE:-$HOME/Movies/preenc-${RES}-${VB}.flv}

[ -r "$SRC" ] || { echo "FATAL: source not readable: $SRC" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "FATAL: ffmpeg not in PATH" >&2; exit 1; }

W=${RES%x*}; H=${RES#*x}

if [ -s "$PRE" ]; then
  echo "==> Already exists, nothing to do: $PRE"
  exit 0
fi

echo "==> Encoding ${DUR}s of ${RES} @ ${VB} -> $PRE"
echo "==> (one-time, uses all cores, takes a few minutes)"

# No -re here: encode as fast as the box allows.
# -stream_loop -1 + -t DUR repeats the short clip up to the target duration.
ffmpeg -nostdin -y -hide_banner -stats -loglevel warning \
  -stream_loop -1 -i "$SRC" -t "$DUR" \
  -vf "scale=$W:$H" \
  -c:v libx264 -b:v "$VB" -g 60 -keyint_min 60 \
  -profile:v baseline -preset veryfast \
  -c:a aac -b:a "$AB" \
  -f flv "$PRE"

echo
echo "==> Done: $(du -h "$PRE" | cut -f1)  $PRE"
echo "==> run-publishers.sh will pick this up automatically."
