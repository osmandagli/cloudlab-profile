#!/bin/bash

set -euo pipefail
mkdir -p /local/logs
cd /local/repository
exec > /local/logs/setup.log 2>&1

echo "Setup started $(date)"

ROLE=${1:-relay}
RELAY_CPU=2
NIC_IFACES=("eno12409np1" "enp23s0f0np0")
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
    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\"/GRUB_CMDLINE_LINUX_DEFAULT=\"quiet nosmt isolcpus=$RELAY_CPU nohz_full=$RELAY_CPU rcu_nocbs=$RELAY_CPU iommu=pt\"/" $GRUB_CFG
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

# Download perf
KERNEL_VERSION=$(uname -r)
sudo apt install -y linux-tools-$KERNEL_VERSION linux-cloud-tools-$KERNEL_VERSION \
    clang llvm libelf-dev libpcap-dev build-essential libc6-dev-i386 m4 \
    linux-tools-common linux-tools-generic \
    tcpdump

[ -d xdp-tutorial ] || git clone https://github.com/xdp-project/xdp-tutorial
cd xdp-tutorial
./configure
make
cd ..

# Give permissions to the perf
echo 'kernel.perf_event_paranoid=-1' | sudo tee /etc/sysctl.d/99-perf.conf
echo 'kernel.kptr_restrict=0' | sudo tee -a /etc/sysctl.d/99-perf.conf
sudo sysctl -p /etc/sysctl.d/99-perf.conf

fi # Relay role

# Clone the repo
[ -d moxygen ] || git clone https://github.com/facebookexperimental/moxygen.git
cd moxygen

apt install -y \
  g++ \
  python3-dev \
  python3-pip \
  libdouble-conversion-dev \
  python3-pex

if [[ "$ROLE" == "publisher" || "$ROLE" == "subscriber" ]]; then
    apt install -y ffmpeg
fi

# Download dependent packages
PIP_BREAK_SYSTEM_PACKAGES=1 ./build/fbcode_builder/getdeps.py install-system-deps --recursive moxygen

# Set env variables for building
eval $(./build/fbcode_builder/getdeps.py env --src-dir moxygen:. moxygen)

mkdir -p /local/moxygen_build

# Change the ftpmirro to original ftp server
# Sometimes ftpmirror doesn't work
grep -rl 'ftpmirror.gnu.org' . | xargs sed -i 's|ftpmirror\.gnu\.org|ftp.gnu.org|g'

# Build moxygen
./build/fbcode_builder/getdeps.py build moxygen \
    --allow-system-packages \
    --scratch-path /local/moxygen_build \
    --build-dir /local/moxygen_build/build \
    --install-dir /local/moxygen_build

# export the LD_LIBRARY_PATH
echo "export LD_LIBRARY_PATH=$(find /local/moxygen_build/installed/ -name lib -type d |tr '\n' ':' | sed 's/:$//')" >> ~/.bashrc

if [[ "$ROLE" == "relay" ]]; then
    cd /local/repository/moxygen/scripts
    bash create-server-certs.sh

    # Apply patches
    cd /local/moxygen_build/repos/github.com-facebook-proxygen.git
    git am /local/repository/patches/proxygen/*.patch
    cd /local/moxygen_build/build/proxygen
    ninja install

    cd /local/moxygen_build/repos/github.com-facebookexperimental-moxygen.git
    git am /local/repository/patches/moxygen/*.patch
    cd /local/moxygen_build/build
    cp /local/repository/patches/cmake/* /local/moxygen_build/repos/github.com-facebookexperimental-moxygen.git/cmake/
    cmake -S /local/moxygen_build/repos/github.com-facebookexperimental-moxygen.git \
        -B /local/moxygen_build/build \
        -DLIBBPF_LIBRARIES=/local/repository/xdp-tutorial/lib/install/lib/libbpf.a \
        -DLIBBPF_INCLUDE_DIR=/local/repository/xdp-tutorial/lib/install/include \
        -DLIBXDP_LIBRARIES=/local/repository/xdp-tutorial/lib/install/lib/libxdp.a \
        -DLIBXDP_INCLUDE_DIR=/local/repository/xdp-tutorial/lib/install/include
    ninja install
    cd /local/moxygen_build/repos/github.com-facebookexperimental-moxygen.git/moxygen/xdp
    clang -O2 -g -Wall -target bpf \
    -I/local/repository/xdp-tutorial/lib/install/include \
    -c XdpKernel.bpf.c \
    -o XdpKernel.bpf.o
fi


tee /etc/sysctl.d/99-udp-buffers.conf <<'EOF'
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
EOF

sudo sysctl --system

sysctl net.core.rmem_max net.core.wmem_max

# change ownership of moxygen
chown odagli: -R /local

echo "Setup completed: $(date)."
