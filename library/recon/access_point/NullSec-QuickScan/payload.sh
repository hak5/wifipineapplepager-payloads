#!/bin/sh
# Title: NullSec QuickScan
# Author: bad-antics
# Description: Fast 30-second WiFi environment scan with detailed security analysis
# Category: Recon
# Version: 1.0
# GitHub: https://github.com/bad-antics/nullsec-pineapple-suite

PROMPT "NULLSEC QUICKSCAN

Fast 30-second scan of
all nearby WiFi networks.

Shows:
- Network names (SSID)
- Security types
- Signal strength
- Client count

Press OK to start scan."

[ ! -d "/sys/class/net/wlan0" ] && { ERROR_DIALOG "wlan0 not found!"; exit 1; }

SPINNER_START "Scanning 30 seconds..."

airmon-ng start wlan0 >/dev/null 2>&1
MON_IF=$(iw dev | grep -oE "wlan[0-9]mon" | head -1)
[ -z "$MON_IF" ] && MON_IF="wlan0"

timeout 30 airodump-ng "$MON_IF" --write-interval 5 -w /tmp/quickscan --output-format csv 2>/dev/null

SPINNER_STOP

CSV_FILE=$(ls /tmp/quickscan*.csv 2>/dev/null | head -1)
if [ -f "$CSV_FILE" ]; then
    AP_COUNT=$(grep -cE "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}," "$CSV_FILE" 2>/dev/null | head -1 || echo 0)
    WPA3=$(grep -c "WPA3" "$CSV_FILE" 2>/dev/null || echo 0)
    WPA2=$(grep -c "WPA2" "$CSV_FILE" 2>/dev/null || echo 0)
    WEP=$(grep -c " WEP" "$CSV_FILE" 2>/dev/null || echo 0)
    OPEN=$(grep -c " OPN" "$CSV_FILE" 2>/dev/null || echo 0)
else
    AP_COUNT=0; WPA3=0; WPA2=0; WEP=0; OPEN=0
fi

PROMPT "SCAN COMPLETE

Networks Found: $AP_COUNT

Security Breakdown:
WPA3: $WPA3
WPA2: $WPA2
WEP: $WEP
Open: $OPEN

Press OK to exit."

airmon-ng stop "$MON_IF" >/dev/null 2>&1
rm -f /tmp/quickscan* 2>/dev/null

exit 0
