#!/bin/bash
# Title:                DNS Lookup (nslookup)
# Description:          Performs DNS lookups using nslookup and logs the results
# Author:               tototo31
# Version:              1.0

# Options
LOOTDIR=/root/loot/nslookup
DEFAULT_RECORD_TYPE="AAAA"

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

# Prompt user for target domain or hostname
LOG "Launching DNS lookup..."
target=$(TEXT_PICKER "Enter domain or hostname" "google.com")
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

# Prompt user for DNS record type (optional)
record_type=$(TEXT_PICKER "Enter DNS record type" "$DEFAULT_RECORD_TYPE")
case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG "User cancelled"
        exit 1
        ;;
    $DUCKYSCRIPT_REJECTED)
        LOG "Using default record type: $DEFAULT_RECORD_TYPE"
        record_type=$DEFAULT_RECORD_TYPE
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG "An error occurred, using default record type: $DEFAULT_RECORD_TYPE"
        record_type=$DEFAULT_RECORD_TYPE
        ;;
esac

# Get DNS server from DHCP if available
dhcp_dns=""
if [ -f /etc/resolv.conf ]; then
    dhcp_dns=$(grep -E "^nameserver" /etc/resolv.conf | head -n 1 | awk '{print $2}' | tr -d '\n')
fi

# Prompt user for DNS server (optional)
dns_server=$(TEXT_PICKER "Enter DNS server" "$dhcp_dns")
case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG "User cancelled"
        exit 1
        ;;
    $DUCKYSCRIPT_REJECTED)
        LOG "Using system default DNS server"
        dns_server=""
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG "An error occurred, using system default DNS server"
        dns_server=""
        ;;
esac

# Create loot destination if needed
mkdir -p $LOOTDIR
# Sanitize target for filename (replace invalid chars with underscores)
safe_target=$(echo "$target" | tr '/: ' '_')
safe_record_type=$(echo "$record_type" | tr '[:lower:]' '[:upper:]')
if [ -n "$dns_server" ]; then
    safe_dns_server=$(echo "$dns_server" | tr '/: ' '_')
    lootfile=$LOOTDIR/$(date -Is)_${safe_target}_${safe_record_type}_${safe_dns_server}
else
    lootfile=$LOOTDIR/$(date -Is)_${safe_target}_${safe_record_type}
fi

LOG "Performing DNS lookup for $target (type: $safe_record_type)..."
if [ -n "$dns_server" ]; then
    LOG "Using DNS server: $dns_server"
fi
LOG "Results will be saved to: $lootfile\n"

# Run nslookup and save to file, also log each line
# nslookup syntax: nslookup -type=<type> <domain> [dns_server]
if [ -n "$dns_server" ]; then
    nslookup -type=$safe_record_type $target $dns_server 2>&1 | tee $lootfile | tr '\n' '\0' | xargs -0 -n 1 LOG
else
    nslookup -type=$safe_record_type $target 2>&1 | tee $lootfile | tr '\n' '\0' | xargs -0 -n 1 LOG
fi

LOG "\nDNS lookup complete!"

