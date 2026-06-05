#!/bin/bash

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <perf.data file> [output_name]"
    exit 1
fi

PERF_FILE="$1"
OUTPUT_NAME="${2:-flamegraph}"  # default name if not provided

exec > /local/log/flame_graph_${OUTPUT_NAME}.log 2>&1

# clone only if not already present
if [ ! -d "FlameGraph" ]; then
    git clone https://github.com/brendangregg/FlameGraph.git
fi
cd FlameGraph

perf script -i "$PERF_FILE" | ./stackcollapse-perf.pl > "${OUTPUT_NAME}.folded"
./flamegraph.pl "${OUTPUT_NAME}.folded" > "${OUTPUT_NAME}.svg"

echo "Done: ${OUTPUT_NAME}.svg"