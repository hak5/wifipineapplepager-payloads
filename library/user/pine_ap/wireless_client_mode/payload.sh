#!/bin/bash
# Name: Wireless Client Mode
# Description: Connect wlan0cli to an existing WiFi network
# Author: PentestPlaybook
# Version: 1.1
# Category: Wireless

LOG "Configuring Wireless Client Mode..."

# Prompt for Target SSID
TARGET_SSID=$(TEXT_PICKER "Target SSID" "") || exit 0
if [[ -z "$TARGET_SSID" ]]; then
    LOG "ERROR: SSID cannot be empty."
    exit 1
fi

# Set SSID using heredoc to preserve special characters
IFS= read -r -d '' SSID_VALUE <<EOF
$TARGET_SSID
EOF
SSID_VALUE="${SSID_VALUE%$'\n'}"

# Prompt for Target PSK
TARGET_PSK=$(TEXT_PICKER "WPA Passphrase" "") || exit 0
if [[ -z "$TARGET_PSK" ]]; then
    LOG "ERROR: Passphrase cannot be empty."
    exit 1
fi
if [[ ${#TARGET_PSK} -lt 8 ]]; then
    LOG "ERROR: Passphrase must be at least 8 characters."
    exit 1
fi

# Set PSK using heredoc to preserve special characters
IFS= read -r -d '' PSK_VALUE <<EOF
$TARGET_PSK
EOF
PSK_VALUE="${PSK_VALUE%$'\n'}"

# Prompt for Encryption Type
ENCRYPTION_TYPE=$(TEXT_PICKER "Encryption" "sae-mixed") || exit 0
if [[ -z "$ENCRYPTION_TYPE" ]]; then
    LOG "ERROR: Encryption type cannot be empty."
    exit 1
fi

# Set encryption using heredoc to preserve special characters
IFS= read -r -d '' ENCRYPTION_VALUE <<EOF
$ENCRYPTION_TYPE
EOF
ENCRYPTION_VALUE="${ENCRYPTION_VALUE%$'\n'}"

# Configure wireless interface
uci set wireless.wlan0cli.ssid="$SSID_VALUE"
uci set wireless.wlan0cli.key="$PSK_VALUE"
uci set wireless.wlan0cli.encryption="$ENCRYPTION_VALUE"
uci set wireless.wlan0cli.network='cli'
uci set wireless.wlan0cli.disabled=0

# Create the 'cli' network interface with DHCP
uci set network.cli=interface
uci set network.cli.proto='dhcp'
uci set network.cli.device='wlan0cli'

# Commit all changes
uci commit wireless
uci commit network
LOG "Reloading network configuration..."
/etc/init.d/network reload
sleep 5
LOG "Waiting for WiFi connection..."
wifi reload
sleep 10

# Check connection
if iw dev wlan0cli link 2>/dev/null | grep -q "Connected"; then
    CONNECTED_SSID=$(iw dev wlan0cli link | grep "SSID" | awk '{print $2}')
    LOG "✓ Connected to: $CONNECTED_SSID"
    
    # Wait for DHCP
    sleep 5
    if ifconfig wlan0cli | grep -q "inet addr"; then
        IP=$(ifconfig wlan0cli | grep "inet addr" | awk '{print $2}' | cut -d: -f2)
        LOG "✓ IP Address: $IP"
        
        # Test connectivity
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            LOG "✓ Internet is working!"
        else
            LOG "⚠ Connected but can't reach internet"
        fi
    else
        LOG "⚠ Connected but waiting for IP..."
        LOG "If this persists, run: /etc/init.d/network restart"
    fi
else
    LOG "✗ Not connected to WiFi"
fi
