#!/bin/bash
# Name: Configure PineAP Filters
# Description: Sets PineAP SSID and Client filters to deny mode
# Author: PentestPlaybook
# Version: 1.0
# Category: PineAP

ALERT "Configuring PineAP Filters..."

# Set SSID/Network filter to deny mode
ALERT "Setting SSID filter to DENY mode..."
uci set pineapd.@ssid_filter[0].mode='deny'

# Set MAC/Client filter to deny mode
ALERT "Setting Client filter to DENY mode..."
uci set pineapd.@mac_filter[0].mode='deny'

# Commit changes for persistence
ALERT "Committing changes..."
uci commit pineapd

# Restart pineapd to apply changes
ALERT "Restarting PineAP daemon..."
/etc/init.d/pineapd restart

# Wait for pineapd to restart (up to 15 seconds)
ALERT "Waiting for pineapd to restart..."
for i in {1..15}; do
    if pgrep -x "pineapd" > /dev/null; then
        ALERT "SUCCESS: PineAP daemon restarted (took ${i} seconds)"
        ALERT "SSID Filter: DENY mode"
        ALERT "Client Filter: DENY mode"
        exit 0
    fi
    sleep 1
done

ALERT "WARNING: pineapd not detected after 15 seconds. Check daemon status."
