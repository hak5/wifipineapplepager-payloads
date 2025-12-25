#!/bin/bash
# Name: Configure Wireless Client Mode
# Description: Connect wlan0cli to an existing WiFi network
# Author: alobe
# Version: 1.0
# Category: Wireless

ALERT "Configuring Wireless Client Mode..."

TARGET_SSID="[Insert Your Modem's SSID]"
TARGET_PSK="[Insert Your Modem's WPA2 Passphrase]"

# Configure wireless interface
uci set wireless.wlan0cli.ssid="$TARGET_SSID"
uci set wireless.wlan0cli.key="$TARGET_PSK"
uci set wireless.wlan0cli.encryption='[Insert Your Modem's WPA2 Encryption Type (ex: "sae-mixed")]'
uci set wireless.wlan0cli.network='cli'
uci set wireless.wlan0cli.disabled=0

# Create the 'cli' network interface with DHCP
uci set network.cli=interface
uci set network.cli.proto='dhcp'
uci set network.cli.device='wlan0cli'

# Commit all changes
uci commit wireless
uci commit network

ALERT "Reloading network configuration..."
/etc/init.d/network reload
sleep 5

ALERT "Waiting for WiFi connection..."
wifi reload
sleep 10

# Check connection
if iw dev wlan0cli link 2>/dev/null | grep -q "Connected"; then
    CONNECTED_SSID=$(iw dev wlan0cli link | grep "SSID" | awk '{print $2}')
    ALERT "✓ Connected to: $CONNECTED_SSID"
    
    # Wait for DHCP
    sleep 5
    
    if ifconfig wlan0cli | grep -q "inet addr"; then
        IP=$(ifconfig wlan0cli | grep "inet addr" | awk '{print $2}' | cut -d: -f2)
        ALERT "✓ IP Address: $IP"
        
        # Test connectivity
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            ALERT "✓ Internet is working!"
        else
            ALERT "⚠ Connected but can't reach internet"
        fi
    else
        ALERT "⚠ Connected but waiting for IP..."
        ALERT "If this persists, run: /etc/init.d/network restart"
    fi
else
    ALERT "✗ Not connected to WiFi"
fi
