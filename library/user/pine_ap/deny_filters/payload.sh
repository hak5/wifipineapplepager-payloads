#!/bin/bash
# Name: Deny Filters
# Description: Sets PineAP SSID and Client filters to deny mode
# Author: PentestPlaybook
# Version: 1.1
# Category: PineAP

LOG "Configuring PineAP Filters..."

# Set SSID/Network filter to deny mode
LOG "Setting SSID filter to DENY mode..."
uci set pineapd.@ssid_filter[0].mode='deny'

# Set MAC/Client filter to deny mode
LOG "Setting Client filter to DENY mode..."
uci set pineapd.@mac_filter[0].mode='deny'

# Commit changes for persistence
LOG "Committing changes..."
uci commit pineapd

# Restart pineapd to apply changes
LOG "Restarting PineAP daemon..."
/etc/init.d/pineapd restart

# Wait for pineapd to restart (up to 15 seconds)
LOG "Waiting for pineapd to restart..."
for i in {1..15}; do
    if pgrep -x "pineapd" > /dev/null; then
        LOG "SUCCESS: PineAP daemon restarted (took ${i} seconds)"
        LOG "SSID Filter: DENY mode"
        LOG "Client Filter: DENY mode"
        exit 0
    fi
    sleep 1
done

LOG "WARNING: pineapd not detected after 15 seconds. Check daemon status."
