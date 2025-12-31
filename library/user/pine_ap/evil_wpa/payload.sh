#!/bin/bash
# Name: Evil WPA
# Description: Sets up and enables the Evil WPA portal interface (wlan0wpa)
# Author: PentestPlaybook
# Version: 1.2
# Category: Wireless

LOG "Configuring Evil WPA Interface..."

# Prompt for SSID
SSID=$(TEXT_PICKER "SSID" "") || exit 0
if [[ -z "$SSID" ]]; then
    LOG "ERROR: SSID cannot be empty."
    exit 1
fi

# Set custom SSID using heredoc to preserve special characters
IFS= read -r -d '' SSID_VALUE <<EOF
$SSID
EOF
uci set wireless.wlan0wpa.ssid="$SSID_VALUE"

# Prompt for Evil WPA passphrase
PSK=$(TEXT_PICKER "Passphrase" "") || exit 0
if [[ -z "$PSK" ]]; then
    LOG "ERROR: Passphrase cannot be empty."
    exit 1
fi

if [[ ${#PSK} -lt 8 ]]; then
    LOG "ERROR: Passphrase must be at least 8 characters."
    exit 1
fi

# Set Evil WPA passphrase using heredoc to preserve special characters
IFS= read -r -d '' PSK_VALUE <<EOF
$PSK
EOF
uci set wireless.wlan0wpa.key="$PSK_VALUE"

# Set encryption type to WPA2
uci set wireless.wlan0wpa.encryption='psk2'

# Enable the interface
uci set wireless.wlan0wpa.disabled=0

# Commit wireless changes for persistence
uci commit wireless

LOG "Restarting WPA daemon and WiFi..."

# Restart wpad and wifi
/etc/init.d/wpad restart
sleep 2
wifi

# Wait for interface to become available (up to 15 seconds)
LOG "Waiting for wlan0wpa interface..."
for i in {1..15}; do
    if iw dev | grep -q "wlan0wpa"; then
        LOG "SUCCESS: wlan0wpa interface is active (took ${i} seconds)"
        iw dev wlan0wpa info > /tmp/wpa_status.txt 2>&1
        exit 0
    fi
    sleep 1
done

LOG "WARNING: wlan0wpa not detected after 15 seconds. Check wireless config / radio state."
