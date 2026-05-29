#!/bin/bash

set -euo pipefail
mkdir -p /local
exec > /local/setup.log 2>&1

echo "Setup started $(date)"

RELAY_CPU=2
GRUB_CFG=/etc/default/grub
HT_DISABLED_MARKER=/local/.ht_disabled

write_startup_script() {
	cat > /etc/rc.local << 'EOF'
#!/bin/bash
bash /local/repository/setup.sh
exit 0
EOF

chmod +x /etc/rc.local
}

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

echo "Setup completed: $(date)"
