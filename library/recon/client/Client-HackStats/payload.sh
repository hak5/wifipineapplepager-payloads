#!/bin/bash
# Title: Client HackStats
# Author: Unit981
# Description: Get handshake and pcap stats for selected client
# Version: 1.1

#Setting directory
HANDSHAKE_DIR="/root/loot/handshakes/"

#Making sure MAC is searchable
mac_clean=$(echo "$_RECON_SELECTED_CLIENT_MAC_ADDRESS" | tr -d ' :')
mac_upper=${mac_clean^^}

LOG "$_RECON_SELECTED_CLIENT_MAC_ADDRESS"
LOG "$mac_upper"

#Count files containing MAC anywhere in filename
handshake_count=$(find "$HANDSHAKE_DIR" -type f -name "*${mac_upper}*.22000" 2>/dev/null | wc -l)
pcap_count=$(find "$HANDSHAKE_DIR" -type f -name "*${mac_upper}*.pcap" 2>/dev/null | wc -l)

#Final output
ALERT "#@ HACK THE PLANET @# \n\n Client MAC: $_RECON_SELECTED_CLIENT_MAC_ADDRESS \n Handshake Count: $handshake_count \n PCAP Count: $pcap_count"
