#!/bin/bash

# payload.sh - Setup script for SmartRogue-AI

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

echo "[+] Root privileges confirmed."

# 2. Dependency Check
DEPENDENCIES=("airmon-ng" "dnsmasq" "python3")
for dep in "${DEPENDENCIES[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
        echo "[-] Error: $dep is not installed. Please install it to proceed."
        exit 1
    fi
done
echo "[+] All dependencies are installed."

# 3. airmon-ng check kill
echo "[+] Killing interfering processes..."
airmon-ng check kill

# 4. airmon-ng start wlan0
echo "[+] Enabling monitor mode on wlan0..."
airmon-ng start wlan0
if [ $? -ne 0 ]; then
    echo "[-] Failed to start monitor mode on wlan0."
    exit 1
fi

# 5. dnsmasq setup
# Assuming a basic setup for a rogue AP scenario
# We use wlan0mon as it is the default interface name after airmon-ng start
INTERFACE="wlan0mon"
IP_ADDR="192.168.1.1"
NETMASK="255.255.255.0"

echo "[+] Configuring network interface $INTERFACE..."
ifconfig $INTERFACE $IP_ADDR netmask $NETMASK up

echo "[+] Starting dnsmasq..."
# Start dnsmasq to provide DHCP and DNS services
dnsmasq --interface=$INTERFACE --dhcp-range=$IP_ADDR,192.168.1.10,192.168.1.50,12h --dnsmasq.conf /dev/null &
DNSMASQ_PID=$!

# 6. Launch core/engine.py
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
trap "kill $DNSMASQ_PID; airmon-ng stop $INTERFACE" EXIT
