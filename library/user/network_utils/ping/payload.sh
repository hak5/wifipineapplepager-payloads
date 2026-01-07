#!/bin/bash
# Title:                Ping
# Description:          Pings a target IP address or hostname and logs the results
# Author:               tototo31
# Version:              1.0

# Options
LOOTDIR=/root/loot/ping
PING_COUNT=4

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

# Prompt user for target IP address or hostname
LOG "Launching ping..."
target=$(TEXT_PICKER "Enter target host" "8.8.8.8")
case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG "User cancelled"
        exit 1
        ;;
    $DUCKYSCRIPT_REJECTED)
        LOG "Dialog rejected"
        exit 1
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG "An error occurred"
        exit 1
        ;;
esac

# Prompt user for number of pings (optional)
ping_count=$(NUMBER_PICKER "Number of pings" $PING_COUNT)
case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG "User cancelled"
        exit 1
        ;;
    $DUCKYSCRIPT_REJECTED)
        LOG "Using default ping count: $PING_COUNT"
        ping_count=$PING_COUNT
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG "An error occurred, using default ping count: $PING_COUNT"
        ping_count=$PING_COUNT
        ;;
esac

# Create loot destination if needed
mkdir -p $LOOTDIR
# Sanitize target for filename (replace invalid chars with underscores)
safe_target=$(echo "$target" | tr '/: ' '_')
lootfile=$LOOTDIR/$(date -Is)_$safe_target

LOG "Pinging $target ($ping_count times)..."
LOG "Results will be saved to: $lootfile\n"

# Run ping and save to file, also log each line
ping -c $ping_count $target | tee $lootfile | tr '\n' '\0' | xargs -0 -n 1 LOG

LOG "\nPing complete!"

