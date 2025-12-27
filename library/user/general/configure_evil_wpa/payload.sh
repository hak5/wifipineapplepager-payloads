#!/bin/bash
# Name: Configure Evil WPA
# Description: Sets up and enables the WPA evil portal interface (wlan0wpa)
# Author: PentestPlaybook
# Version: 1.0
# Category: Wireless

ALERT "Configuring Evil WPA Interface..."

# Set custom SSID
IFS= read -r -d '' SSID <<'EOF'
[Insert an SSID for your WPA2 Network]
EOF

uci set wireless.wlan0wpa.ssid="$SSID"

# Set WPA passphrase
IFS= read -r -d '' PSK <<'EOF'
[Insert a Strong Passphrase for your WPA2 Network]
EOF

uci set wireless.wlan0wpa.key="$PSK"

# Set encryption type to WPA2
uci set wireless.wlan0wpa.encryption='psk2'

# Enable the interface
uci set wireless.wlan0wpa.disabled=0

# Commit wireless changes for persistence
uci commit wireless

ALERT "Reloading WiFi configuration..."

# Reload WiFi
wifi reload

# Wait for interface to become available (up to 15 seconds)
ALERT "Waiting for wlan0wpa interface..."
for i in {1..15}; do
    if iw dev | grep -q "wlan0wpa"; then
        ALERT "SUCCESS: wlan0wpa interface is active (took ${i} seconds)"
        iw dev wlan0wpa info > /tmp/wpa_status.txt 2>&1
        exit 0
    fi
    sleep 1
done

ALERT "WARNING: wlan0wpa not detected after 15 seconds. Check wireless config / radio state."
