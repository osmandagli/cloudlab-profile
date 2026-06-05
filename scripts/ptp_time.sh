#!/bin/bash

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <master|slave> <iface1> [iface2]"
    echo "  master: requires two interfaces (e.g. eno12409 enp23s0f0)"
    echo "  slave:  requires one interface"
    exit 1
fi

MODE="$1"
IFACE1="$2"
NODE_NAME="${3:-node}"  # used for log naming in slave mode

exec > /local/log/ptp_${MODE}_${IFACE1}.log 2>&1

sudo apt install -y linuxptp

if [[ "$MODE" == "master" ]]; then
    IFACE2="${3:?master mode requires a second interface as \$3}"
    echo "Starting ptp4l in master mode on $IFACE1 and $IFACE2..."
    sudo ptp4l -i "$IFACE1" -m --tx_timestamp_timeout 100 > ptp_master_${IFACE1}.log 2>&1 &
    sudo ptp4l -i "$IFACE2" -m --tx_timestamp_timeout 100 > ptp_master_${IFACE2}.log 2>&1 &
    sudo phc2sys -s "$IFACE1" -w -m > phc_master.log 2>&1 &
    echo "Logs: ptp_master_${IFACE1}.log, ptp_master_${IFACE2}.log, phc_master.log"

elif [[ "$MODE" == "slave" ]]; then
    echo "Starting ptp4l in slave mode on $IFACE1..."
    sudo ptp4l -i "$IFACE1" -m -s --tx_timestamp_timeout 100 > ptp_slave_${IFACE1}.log 2>&1 &
    sudo phc2sys -s "$IFACE1" -w -m > phc_slave_${IFACE1}.log 2>&1 &
    echo "Logs: ptp_slave_${IFACE1}.log, phc_slave_${IFACE1}.log"

else
    echo "Unknown mode: $MODE. Use 'master' or 'slave'."
    exit 1
fi

echo "Done. Check logs with: tail -f ptp_*.log"