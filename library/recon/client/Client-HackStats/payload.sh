#!/bin/bash
# Title: Targeted Client HackStats
# Author: Unit981
# Description: Get handshake and pcap stats for selected client
# Version: 1.0

/usr/bin/LOG "Dumping Selected Client information"
LOG "Client OUI: $_RECON_SELECTED_CLIENT_OUI"
LOG "Client MAC: $_RECON_SELECTED_CLIENT_MAC_ADDRESS"
LOG "Client SSID: $_RECON_SELECTED_CLIENT_SSID"
LOG "Client AP BSSID: $_RECON_SELECTED_CLIENT_BSSID"
LOG "Client Packets: $_RECON_SELECTED_CLIENT_PACKETS"
LOG "Client Channel: $_RECON_SELECTED_CLIENT_CHANNEL"
LOG "Client Encryption Type: $_RECON_SELECTED_CLIENT_ENCRYPTION_TYPE"
LOG "Client RSSI: $_RECON_SELECTED_CLIENT_RSSI"
LOG "Client Timestamp: $_RECON_SELECTED_CLIENT_TIMESTAMP"
LOG "Client Frequency: $_RECON_SELECTED_CLIENT_FREQ"

#Base directory
HANDSHAKE_DIR="/root/loot/handshakes/"
bssid_clean=$(printf "%s" "$_RECON_SELECTED_CLIENT_MAC_ADDRESS" | sed 's/[[:space:]]//g')
bssid_upper=${bssid_clean^^}

#Count files containing MAC anywhere in filename
handshake_count=$(find "$HANDSHAKE_DIR" -type f -name "*${bssid_upper}*.22000" 2>/dev/null | wc -l)
pcap_count=$(find "$HANDSHAKE_DIR" -type f -name "*${bssid_upper}*.pcap" 2>/dev/null | wc -l)


#Final output
LOG "Handshake Count: $handshake_count"
LOG "PCAP Count: $pcap_count"
