#!/bin/bash
IF=$1 ROLE=$2 OPT= R=-rr
pkill -x ptp4l; pkill -x phc2sys; sleep 1
[ "$ROLE" = master ] || { OPT=-s R=-r; systemctl disable --now chrony systemd-timesyncd 2>/dev/null; }
trap 'kill 0' EXIT
if ethtool -T "$IF" | grep -q hardware-receive; then
  ptp4l -i "$IF" $OPT -m &
  sleep 5
  phc2sys -a $R -m
else
  ptp4l -i "$IF" $OPT -S -m
fi