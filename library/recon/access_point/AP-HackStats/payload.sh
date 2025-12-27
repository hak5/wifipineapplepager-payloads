#!/bin/bash
# Title: Targeted AP HackStats
# Author: Unit981
# Description: Get handshake and pcap stats for selected AP
# Version: 1.0

/usr/bin/LOG "Dumping Selected AP information"
LOG "AP OUI: $_RECON_SELECTED_AP_OUI"
LOG "AP BSSID: $_RECON_SELECTED_AP_BSSID"
LOG "AP SSID: $_RECON_SELECTED_AP_SSID"
LOG "AP Hidden: $_RECON_SELECTED_AP_HIDDEN"
LOG "AP Channel: $_RECON_SELECTED_AP_CHANNEL"
LOG "AP Encryption Type: $_RECON_SELECTED_AP_ENCRYPTION_TYPE"
LOG "AP Client Count: $_RECON_SELECTED_AP_CLIENT_COUNT"
LOG "AP RSSI: $_RECON_SELECTED_AP_RSSI"
LOG "AP Timestamp: $_RECON_SELECTED_AP_TIMESTAMP"
LOG "AP Frequency: $_RECON_SELECTED_AP_FREQ"
LOG "AP Packets: $_RECON_SELECTED_AP_PACKETS"


#Base directory
HANDSHAKE_DIR="/root/loot/handshakes/"
bssid_clean=$(printf "%s" "$_RECON_SELECTED_AP_BSSID" | sed 's/[[:space:]]//g')
bssid_upper=${bssid_clean^^}

#Count files containing MAC anywhere in filename
handshake_count=$(find "$HANDSHAKE_DIR" -type f -name "*${bssid_upper}*.22000" 2>/dev/null | wc -l)
pcap_count=$(find "$HANDSHAKE_DIR" -type f -name "*${bssid_upper}*.pcap" 2>/dev/null | wc -l)


#Final output
LOG "Handshake Count: $handshake_count"
LOG "PCAP Count: $pcap_count"
