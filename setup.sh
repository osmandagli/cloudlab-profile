#!/bin/bash

set -euo pipefail
mkdir -p /local/logs
exec > /local/logs/setup.log 2>&1

echo "Setup started $(date)"

ROLE=${1:-relay}
RELAY_CPU=2
NIC_IFACES=("eno12409" "enp23s0f0")
RELAY_PORT=4433
GRUB_CFG=/etc/default/grub
HT_DISABLED_MARKER=/local/.ht_disabled
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"

apt update

write_startup_script() {
	cat > /etc/rc.local << EOF
#!/bin/bash
bash $SCRIPT_PATH
exit 0
EOF

chmod +x /etc/rc.local
}
if [[ "$ROLE" == "relay" ]]; then 
# Disable Hyperthreading
if [[ ! -f "$HT_DISABLED_MARKER" ]]; then
	echo "Disabling HT via GRUB..."
	sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\"/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet nosmt isolcpus=$RELAY_CPU nohz_full=$RELAY_CPU rcu_nocbs=$RELAY_CPU\"/" $GRUB_CFG
	update-grub
	touch "$HT_DISABLED_MARKER"
	write_startup_script
	reboot
	exit 0
fi

echo "Post reboot setup: $(date)"

HT_STATUS=$(cat /sys/devices/system/cpu/smt/active 2>/dev/null || echo "unknown")
echo "SMT/HT status: $HT_STATUS" # 0:off 1:on

#apt-get install -y linux-tools-common linux-tools-$(uname -r) cpufrequtils

echo "Setting performance governor on all cores..."
for cpu in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
    echo "performance" > "$cpu"
done

for cpu in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
       echo "$(basename $(dirname $cpu)): $(cat $cpu)" | sed "s/policy/cpu /g"
done

echo "Disabling deep C-states on all cores..."
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    for state in "$cpu"/cpuidle/state[2-9]; do
        # state0 = C0 (active), state1 = C1 (halt)
        # state2+ = C2, C6, C7 etc — disable
        if [[ -f "$state/disable" ]]; then
            echo 1 > "$state/disable"
        fi
    done
done

echo "C-state status for cpu0:"
for state in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
    name=$(cat "$state/name")
    disabled=$(cat "$state/disable")
    echo "  $name: disabled=$disabled"
done

echo "Setting flow director"

# Disable irbalance service 
systemctl stop irqbalance
systemctl disable irqbalance

for NIC_IFACE in "${NIC_IFACES[@]}"; do

    # Add the rule to the interface
    ethtool -U $NIC_IFACE \
            flow-type udp4 \
            dst-port $RELAY_PORT \
            action $RELAY_CPU

    # Check the rule
    ethtool -u $NIC_IFACE

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

# Download perf
KERNEL_VERSION=$(uname -r)
sudo apt install linux-tools-$KERNEL_VERSION linux-cloud-tools-$KERNEL_VERSION -y

# Give permissions to the perf
echo 'kernel.perf_event_paranoid=-1' | sudo tee /etc/sysctl.d/99-perf.conf
echo 'kernel.kptr_restrict=0' | sudo tee -a /etc/sysctl.d/99-perf.conf
sudo sysctl -p /etc/sysctl.d/99-perf.conf

fi # Relay role

# Clone the repo
[ -d moxygen ] || git clone https://github.com/facebookexperimental/moxygen.git
cd moxygen

apt install g++ python3-dev python3-pip -y

# Download dependent packages" 
./build/fbcode_builder/getdeps.py install-system-deps --recursive moxygen

# Set env variables for building
eval $(./build/fbcode_builder/getdeps.py env --src-dir moxygen:. moxygen)

# Build the moxygen
./build/fbcode_builder/getdeps.py build moxygen --clean --scratch-path ~/moxygen_build --build-dir ~/moxygen_build/build --install-dir ~/moxygen_build

# export the LD_LIBRARY_PATH 
echo "export LD_LIBRARY_PATH=$(find ~/moxygen_build/installed/ -name lib -type d |tr '\n' ':' | sed 's/:$//')" >> ~/.bashrc

echo "Setup completed: $(date)"
