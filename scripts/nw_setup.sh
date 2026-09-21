#!/user/bin/env bash

RELAY_CPU=2
NIC_IFACES=("eno12409np1" "enp23s0f0np0")
RELAY_PORT=4433

echo "Setting flow director"

for NIC_IFACE in "${NIC_IFACES[@]}"; do

    # Add the rule to the interface
    ethtool -U $NIC_IFACE \
            flow-type udp4 \
            dst-port $RELAY_PORT \
            action $RELAY_CPU

    # Check the rule
    ethtool -u $NIC_IFACE

    set ip link set dev $NIC_IFACE mtu 1500

    # Get all the possible NIC IRQs
    NIC_IRQ=$(grep ${NIC_IFACE}-TxRx-${RELAY_CPU}$ /proc/interrupts | awk '{print $1}' | tr -d ':')

    if [[ -n "$NIC_IRQ" ]]; then
            CPU_MASK=$(printf "%x" $((1 << RELAY_CPU)))
            echo "$CPU_MASK" > /proc/irq/$NIC_IRQ/smp_affinity
            echo "Pinned IRQ $NIC_IRQ to CPU $RELAY_CPU (mask 0x$CPU_MASK)"
    else
            echo "WARNING: Could not find IRQ for ${NIC_IFACE}-TxRx-${RELAY_CPU}"
            echo "Available IRQs:"
            grep "$NIC_IFACE" /proc/interrupts
    fi
done


