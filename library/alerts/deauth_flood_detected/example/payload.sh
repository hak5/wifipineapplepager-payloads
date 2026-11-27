#!/bin/bash
# Title: Example Deauth Flood Alert
# Description: Alert human readable summary
# Author: Hak5Darren
# Version: 1.0

ALERT "$_ALERT_DENIAL_MESSAGE"

# Additional variables include:
# $_ALERT                                 "deauth_flood_detected"
# $_ALERT_DENIAL_MESSAGE                  human readable alert content "deauth/disassoc flood from ..."
# $_ALERT_DENIAL_SOURCE_MAC_ADDRESS       source mac
# $_ALERT_DENIAL_DESTINATION_MAC_ADDRESS  destination mac
# $_ALERT_DENIAL_AP_MAC_ADDRESS           ap/bssid mac address regardless of direction
# $_ALERT_DENIAL_CLIENT_MAC_ADDRESS       client mac address regardless of direction
