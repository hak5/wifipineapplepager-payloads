#!/bin/bash
# Title: Flock You - Color Key Refresh v9.15
# Description: Continuous BLE scanner for Flock Safety surveillance devices.
#              Detects FS Ext Battery, Penguin, Pigvision, and other Flock BLE.
# Author: colonelpanichacks
# Contributors: Claude (Anthropic), Grok (xAI), Brandon Starkweather
# Data Sources: colonelpanichacks/flock-you, deflock.me, GainSec,
#               Ryan O'Horo (FCC research), Will Greenberg (BLE research)
# Version: 9.15
# Category: Reconnaissance
LOOT_DIR="/root/loot/flock_you"
mkdir -p "$LOOT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOOT_DIR}/flock_hcitool_${TIMESTAMP}.txt"
LOG yellow "Flock-You v9.15 started at $(date)"
LOG "Scanning continuously..."
LOG "Color key:"
LOG yellow   "  FS Ext Battery"
LOG green    "  Penguin"
LOG magenta  "  Pigvision"
LOG cyan     "  Other Flock"
LOG "----------------------------------"
echo "v9.15 started at $(date)" > "$LOG_FILE"
DETECTIONS=0
SEEN_STRONG=""
COUNTER=0  # For legend refresh
while true; do
    hciconfig hci0 down 2>>"$LOG_FILE"
    hciconfig hci0 reset 2>>"$LOG_FILE"
    hciconfig hci0 up 2>>"$LOG_FILE"
    timeout 18 hcitool lescan --duplicates > /tmp/hci_scan.txt 2>>"$LOG_FILE" &
    PID=$!
    sleep 12
    kill $PID 2>/dev/null
    wait $PID 2>/dev/null
    if [ -s /tmp/hci_scan.txt ]; then
        grep -i "fs ext battery\|penguin\|flock\|pigvision" /tmp/hci_scan.txt | sort -u | while read -r full_line; do
            MAC=$(echo "$full_line" | awk '{print $1}')
            NAME=$(echo "$full_line" | cut -d' ' -f2-)
            if echo "$SEEN_STRONG" | grep -q "$MAC $NAME"; then continue; fi
            CURRENT_TIME=$(date '+%H:%M:%S')
            ENTRY="DECT: $CURRENT_TIME | $MAC | $NAME"
            # Color by type
            if echo "$NAME" | grep -qi "fs ext battery"; then
                LOG yellow "$ENTRY"
            elif echo "$NAME" | grep -qi "penguin"; then
                LOG green "$ENTRY"
            elif echo "$NAME" | grep -qi "pigvision"; then
                LOG magenta "$ENTRY"
            elif echo "$NAME" | grep -qi "flock"; then
                LOG cyan "$ENTRY"
            else
                LOG "$ENTRY"
            fi
            echo "$ENTRY" >> "$LOG_FILE"
            DETECTIONS=$((DETECTIONS + 1))
            COUNTER=$((COUNTER + 1))
            # Refresh short legend every 10 detections
            if [ $((COUNTER % 10)) -eq 0 ]; then
                LOG " "
                LOG yellow   "FS Ext Battery"
                LOG green    "Penguin"
                LOG magenta  "Pigvision"
                LOG cyan     "Other Flock"
                LOG " "
            fi
            # Tone + LED
            if [ -f /sys/class/gpio/vibrator/value ]; then
                echo 1 > /sys/class/gpio/vibrator/value 2>/dev/null
                sleep 0.15
                echo 0 > /sys/class/gpio/vibrator/value 2>/dev/null
            fi
            if ls /sys/class/leds/* >/dev/null 2>&1; then
                LED=$(ls /sys/class/leds/* | head -1)
                echo 1 > "${LED}/brightness" 2>/dev/null
                sleep 0.3
                echo 0 > "${LED}/brightness" 2>/dev/null
            fi
            SEEN_STRONG="$SEEN_STRONG $MAC $NAME"
        done
    fi
    sleep 3
done
exit 0
