#!/bin/bash
# Title:                Whois
# Description:          Queries whois information for a domain name or IP address and logs the results
# Author:               tototo31
# Version:              1.0

# Options
LOOTDIR=/root/loot/whois

# === UTILITIES ===

setup() {
    LED SETUP
    if ! command -v whois >/dev/null 2>&1; then
        LOG "Installing whois..."
        opkg update
        opkg install whois
        if ! command -v whois >/dev/null 2>&1; then
            LED FAIL
            LOG "ERROR: Failed to install whois"
            ERROR_DIALOG "whois installation failed. Cannot query domain information."
            LOG "Exiting - whois is required but could not be installed"
            exit 1
        fi
    fi
}

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

check_network() {
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
}

filter_whois_output() {
    # Filter out verbose/boilerplate sections to make output more readable on small screens
    # Reads from stdin and filters out unwanted lines
    grep -v -i -E \
        -e '^$' \
        -e '^--+$' \
        -e '^==+$' \
        -e '^#.*' \
        -e 'terms? and conditions?' \
        -e 'terms? of service' \
        -e 'icann' \
        -e 'contact icann' \
        -e 'for more information.*icann' \
        -e 'please note.*icann' \
        -e 'copyright' \
        -e 'legal disclaimer' \
        -e 'disclaimer' \
        -e 'access to.*whois' \
        -e 'whois data.*terms' \
        -e 'data protection' \
        -e 'privacy policy' \
        -e 'redacted for privacy' \
        -e '^notice:' \
        -e '^warning:' \
        -e '^important:' \
        -e '^please note:' \
        -e '^note:' \
        -e '^the data.*is provided' \
        -e '^this information.*provided' \
        -e '^you may not' \
        -e '^unauthorized use' \
        -e '^by querying' \
        -e '^querying.*whois' \
        -e '^.*whois.*terms' \
        -e '^.*registrar.*terms' \
        -e '^.*registry.*terms' \
        -e '^.*domain.*terms' \
        -e '^.*see.*for.*information' \
        -e '^.*refer.*to.*' \
        -e '^.*more.*information.*available' \
        -e '^.*additional.*information' \
        -e '^.*for.*details' \
        -e '^.*please.*refer' \
        -e '^.*see.*http' \
        -e '^.*visit.*http' \
        -e '^.*http.*terms' \
        -e '^.*http.*policy' \
        -e '^.*http.*disclaimer' \
        -e '^.*http.*icann'
}

# === MAIN ===

# Setup and check dependencies
setup
check_network

# Prompt user for target domain or IP address
LOG "Launching whois..."
target=$(TEXT_PICKER "Enter domain or IP" "example.com")
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

# Create loot destination if needed
mkdir -p $LOOTDIR
# Sanitize target for filename (replace invalid chars with underscores)
safe_target=$(echo "$target" | tr '/: ' '_')
lootfile=$LOOTDIR/$(date -Is)_$safe_target

LOG "Querying whois for $target..."
LOG "Results will be saved to: $lootfile\n"

# Run whois, save full output to file, and display filtered output
LED ATTACK
# Save full unfiltered output to file and filter for display
whois $target 2>&1 | tee $lootfile | filter_whois_output | tr '\n' '\0' | xargs -0 -n 1 LOG

LOG "\nWhois query complete!"

