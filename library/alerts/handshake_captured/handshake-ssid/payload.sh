#!/bin/bash
# Title: SSID Handshake Capture Alert
# Description: Alert human readable summary plus SSID
# Author: RootJunky
# Version: 1.0

PCAP="$_ALERT_HANDSHAKE_PCAP_PATH"

# Extract SSID from beacon frames
SSID=$(tcpdump -r "$PCAP" -e -I -s 256 \
  | sed -n 's/.*Beacon (\([^)]*\)).*/\1/p' \
  | head -n 1)

# Fallback if SSID not found
[ -n "$SSID" ] || SSID="UNKNOWN_SSID"

# Build enhanced alert message
ALERT "SSID: $SSID | $_ALERT_HANDSHAKE_SUMMARY"

# ALERT "$_ALERT_HANDSHAKE_SUMMARY"

# Additional variables include:
# $_ALERT_HANDSHAKE_SUMMARY             human-readable handshake summary "handshake AP ... CLIENT ... packets..."
# $_ALERT_HANDSHAKE_AP_MAC_ADDRESS      ap/bssid mac of handshake
# $_ALERT_HANDSHAKE_CLIENT_MAC_ADDRESS  client mac address
# $_ALERT_HANDSHAKE_TYPE                eapol | pmkid
# $_ALERT_HANDSHAKE_COMPLETE            (eapol only) complete 4-way handshake + beacon captured
# $_ALERT_HANDSHAKE_CRACKABLE           (eapol only) handshake is potentially crackable
# $_ALERT_HANDSHAKE_PCAP_PATH           path to pcap file
# $_ALERT_HANDSHAKE_HASHCAT_PATH        path to hashcat-converted file
