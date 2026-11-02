#!/bin/bash
#
# Title: SmartRogue-AI
# Author: turkkat284-ui (email: turkkat284@gmail.com)
# Description: SmartRogue-AI is not just another Rogue AP. It is an intelligent ecosystem designed for the WiFi Pineapple Pager that eliminates the "one-size-fits-all" approach to captive portals.
# Target: Windows / Linux / apple / android
# Category: Rogue-AP / evil portal
#

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

echo "[+] Root privileges confirmed."

# 2. Dependency Check (Adapted for OpenWrt/embedded environment)
DEPENDENCIES=("iw" "dnsmasq" "python3")
for dep in "${DEPENDENCIES[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
        echo "[-] Error: $dep is not installed. Please install it to proceed."
        exit 1
    fi
done
echo "[+] All dependencies are installed."

# 3. Interface Setup (Using OpenWrt compatible ip command instead of airmon-ng)
INTERFACE="wlan0"
IP_ADDR="192.168.1.1"

echo "[+] Configuring network interface $INTERFACE..."
ip link set dev $INTERFACE down
ip addr flush dev $INTERFACE
ip addr add $IP_ADDR/24 dev $INTERFACE
ip link set dev $INTERFACE up
if [ $? -ne 0 ]; then
    echo "[-] Failed to configure interface $INTERFACE."
    exit 1
fi

# 4. dnsmasq setup (Fixed flag error from --dnsmasq.conf to --conf-file)
echo "[+] Starting dnsmasq..."
dnsmasq --interface=$INTERFACE --dhcp-range=192.168.1.10,192.168.1.50,12h --conf-file=/dev/null --bind-interfaces
DNSMASQ_PID=$!

# 5. Launch core/engine.py
echo "[+] Launching core engine..."
if [ -f "core/engine.py" ]; then
    python3 core/engine.py
else
    echo "[-] Error: core/engine.py not found!"
    # Clean up dnsmasq if engine fails to start
    kill $DNSMASQ_PID
    exit 1
fi

# Cleanup on exit
trap "kill $DNSMASQ_PID; ip link set dev $INTERFACE down" EXIT
