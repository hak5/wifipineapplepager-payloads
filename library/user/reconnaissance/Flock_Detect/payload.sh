#!/bin/bash
# Title: Flock You - GPS Tagging v9.16
# Description: Continuous BLE scanner for Flock Safety surveillance devices.
#              Detects FS Ext Battery, Penguin, Pigvision, and other Flock BLE.
#              v9.16 tags each detection with a GPS fix from gpsd (falls back
#              to NO_GPS when no fix is available) and writes a companion CSV.
# Author: colonelpanichacks
# Contributors: Claude (Anthropic), Grok (xAI), Brandon Starkweather
# Data Sources: colonelpanichacks/flock-you, deflock.me, GainSec,
#               Ryan O'Horo (FCC research), Will Greenberg (BLE research)
# Version: 9.16
# Category: Reconnaissance
LOOT_DIR="/root/loot/flock_you"
mkdir -p "$LOOT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOOT_DIR}/flock_hcitool_${TIMESTAMP}.txt"
CSV_FILE="${LOOT_DIR}/flock_gps_${TIMESTAMP}.csv"

# --- GPS fix reader ------------------------------------------------------
# Pulls one TPV (Time-Position-Velocity) report from gpsd via gpspipe -w
# (JSON/WATCH mode) and echoes "lat,lon" when a usable 2D/3D fix exists.
# Echoes nothing on no fix / no receiver. Uses the same gpspipe+jq pattern
# proven in gps-checker. Kept short (timeout 3) so a detection cycle never
# stalls waiting on GPS. mode: 0/1 = no fix, 2 = 2D, 3 = 3D.
get_gps_fix() {
    local json mode lat lon
    json="$(timeout 3 gpspipe -w -n 30 2>/dev/null | grep '"class":"TPV"' | grep '"lat":' | tail -n 1)"
    [ -z "$json" ] && return 1
    mode="$(echo "$json" | jq -r '.mode // 0' 2>/dev/null)"
    case "$mode" in 2|3) ;; *) return 1 ;; esac
    lat="$(echo "$json" | jq -r '.lat // empty' 2>/dev/null)"
    lon="$(echo "$json" | jq -r '.lon // empty' 2>/dev/null)"
    [ -n "$lat" ] && [ -n "$lon" ] || return 1
    echo "${lat},${lon}"
}

LOG yellow "Flock-You v9.16 started at $(date)"
LOG "Scanning continuously (GPS-tagged)..."
LOG "Color key:"
LOG yellow   "  FS Ext Battery"
LOG green    "  Penguin"
LOG magenta  "  Pigvision"
LOG cyan     "  Other Flock"
LOG "----------------------------------"
echo "v9.16 started at $(date)" > "$LOG_FILE"
echo "time,mac,name,lat,lon" > "$CSV_FILE"
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
        # One fix per cycle: position won't change meaningfully within a
        # ~12s scan window, and this avoids multiplying the GPS delay across
        # multiple detections in the same batch. Empty => NO_GPS this cycle.
        CYCLE_GPS="$(get_gps_fix)"
        grep -i "fs ext battery\|penguin\|flock\|pigvision" /tmp/hci_scan.txt | sort -u | while read -r full_line; do
            MAC=$(echo "$full_line" | awk '{print $1}')
            NAME=$(echo "$full_line" | cut -d' ' -f2-)
            if echo "$SEEN_STRONG" | grep -q "$MAC $NAME"; then continue; fi
            CURRENT_TIME=$(date '+%H:%M:%S')
            if [ -n "$CYCLE_GPS" ]; then
                GPS_TAG="$CYCLE_GPS"
                CSV_LAT="${CYCLE_GPS%,*}"
                CSV_LON="${CYCLE_GPS#*,}"
            else
                GPS_TAG="NO_GPS"
                CSV_LAT=""
                CSV_LON=""
            fi
            ENTRY="DECT: $CURRENT_TIME | $MAC | $NAME | $GPS_TAG"
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
            echo "${CURRENT_TIME},${MAC},\"${NAME}\",${CSV_LAT},${CSV_LON}" >> "$CSV_FILE"
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
