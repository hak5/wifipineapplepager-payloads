#!/bin/bash
# Title: Example Handshake Capture Alert
# Description: Alert human readable summary
# Author: Hak5Darren
# Version: 1.0

ALERT "$_ALERT_HANDSHAKE_SUMMARY"

# Additional variables include:
# $_ALERT_HANDSHAKE_SUMMARY             human-readable handshake summary "handshake AP ... CLIENT ... packets..."
# $_ALERT_HANDSHAKE_AP_MAC_ADDRESS      ap/bssid mac of handshake
# $_ALERT_HANDSHAKE_CLIENT_MAC_ADDRESS  client mac address
# $_ALERT_HANDSHAKE_TYPE                eapol | pmkid
# $_ALERT_HANDSHAKE_COMPLETE            (eapol only) complete 4-way handshake + beacon captured
# $_ALERT_HANDSHAKE_CRACKABLE           (eapol only) handshake is potentially crackable
# $_ALERT_HANDSHAKE_PCAP_PATH           path to pcap file
# $_ALERT_HANDSHAKE_HASHCAT_PATH        path to hashcat-converted file
