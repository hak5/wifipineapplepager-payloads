#!/bin/bash
# Title:                ARP Table
# Description:          Lists the ARP table and logs the results
# Author:               tototo31
# Version:              1.0

# Options
LOOTDIR=/root/loot/arp

# Check if device has a valid IP address (not loopback, not 172.16.52.0/24)
is_valid_ip() {
    local ip=$1
    if [ -z "$ip" ] || [ "$ip" = "127.0.0.1" ]; then
        return 1
    fi
    # Exclude 172.16.52.0/24 subnet (Pineapple management network)
    if echo "$ip" | grep -qE '^172\.16\.52\.'; then
        return 1
    fi
    return 0
}

has_ip=false
if command -v hostname >/dev/null 2>&1; then
    ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
    if is_valid_ip "$ip_addr"; then
        has_ip=true
    fi
fi

if [ "$has_ip" = false ]; then
    # Try alternative method using ip command
    if command -v ip >/dev/null 2>&1; then
        for ip_addr in $(ip -4 addr show | grep -E 'inet [0-9]' | awk '{print $2}' | cut -d'/' -f1); do
            if is_valid_ip "$ip_addr"; then
                has_ip=true
                break
            fi
        done
    fi
fi

if [ "$has_ip" = false ]; then
    LOG "ERROR: No valid IP address detected"
    ERROR_DIALOG "No valid IP address detected. This utility requires a valid IP address. Please ensure the device is in client mode and connected to a network."
    LOG "Exiting - device must be in client mode with a valid network connection"
    exit 1
fi

# Create loot destination if needed
mkdir -p $LOOTDIR
lootfile=$LOOTDIR/$(date -Is)_arp_table

LOG "Listing ARP table..."
LOG "Results will be saved to: $lootfile\n"

# Try to use 'ip neigh show' first (more modern), fall back to 'arp -a'
if command -v ip >/dev/null 2>&1; then
    LOG "Using 'ip neigh show' command..."
    ip neigh show | tee $lootfile | sed G | tr '\n' '\0' | xargs -0 -n 1 LOG
elif command -v arp >/dev/null 2>&1; then
    LOG "Using 'arp -a' command..."
    arp -a | tee $lootfile | sed G | tr '\n' '\0' | xargs -0 -n 1 LOG
else
    LOG "ERROR: Neither 'ip' nor 'arp' command found"
    ERROR_DIALOG "Neither 'ip' nor 'arp' command found. Cannot list ARP table."
    exit 1
fi

LOG "\nARP table listing complete!"

