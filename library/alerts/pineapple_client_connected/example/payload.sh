#!/bin/bash
# Title: Example Client Connected Alert
# Description: Alert human readable summary
# Author: Hak5Darren
# Version: 1.0

ALERT "$_ALERT_CLIENT_CONNECTED_SUMMARY"

# Additional variables include:
# $_ALERT                                     "pineapple_client_connected"
# $_ALERT_CLIENT_CONNECTED_SUMMARY            human-readable summary of connection
# $_ALERT_CLIENT_CONNECTED_AP_MAC_ADDRESS     ap/bssid
# $_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS client mac
# $_ALERT_CLIENT_CONNECTED_SSID               utf-8 sanitized ssid
# $_ALERT_CLIENT_CONNECTED_SSID_LENGTH        length of original ssid
