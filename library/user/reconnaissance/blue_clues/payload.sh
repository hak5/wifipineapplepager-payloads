#!/bin/bash
# Title: Blue Clues
# Author: Brandon Starkweather


# --- 1. SETUP ---
LOOT_DIR="/root/loot/blue_clues"

# Hardware Control Functions
set_global_color() {
    # $1=R, $2=G, $3=B
    for dir in up down left right; do
        if [ -f "/sys/class/leds/${dir}-led-red/brightness" ]; then
            echo "$1" > "/sys/class/leds/${dir}-led-red/brightness"
            echo "$2" > "/sys/class/leds/${dir}-led-green/brightness"
            echo "$3" > "/sys/class/leds/${dir}-led-blue/brightness"
        fi
    done
}

set_led() {
    STATE="$1"
    if [ "$STATE" -eq 1 ]; then
        if [ "$FB_MODE" -eq 2 ] || [ "$FB_MODE" -eq 4 ]; then
            set_global_color 255 0 0 # Red
        fi
    elif [ "$STATE" -eq 2 ]; then
        set_global_color 0 255 0 # Green
    else
        set_global_color 0 0 0 # Off
    fi
}

do_vibe() {
    if [ "$FB_MODE" -eq 3 ] || [ "$FB_MODE" -eq 4 ]; then
        if [ -f "/sys/class/gpio/vibrator/value" ]; then
            echo "1" > /sys/class/gpio/vibrator/value
            sleep 0.2
            echo "0" > /sys/class/gpio/vibrator/value
        fi
    fi
}

cleanup() {
    set_global_color 0 0 0
    rm /tmp/bt_scan.txt 2>/dev/null
    exit 0
}
trap cleanup EXIT INT TERM

# --- 2. CONFIGURATION PROMPTS ---
PROMPT "BLUE CLUES

This tool scans for visible Bluetooth devices.

Press OK to Configure."

# Select Feedback Mode
PROMPT "FEEDBACK OPTIONS

1. Silent (Log Only)
2. LED (Red Flash)
3. Vibe (Short Buzz)
4. Both (Flash + Buzz)

Press OK."
FB_MODE=$(NUMBER_PICKER "Select Feedback Mode" 1)
if [ -z "$FB_MODE" ]; then exit 0; fi

# Select Duration
PROMPT "SCAN DURATION

Enter minutes to scan.

Press OK."
MINS=$(NUMBER_PICKER "Enter Minutes" 1)
if [ -z "$MINS" ]; then exit 0; fi

# --- 3. CREATE DIRECTORY & FILE (Like Nmap Example) ---
mkdir -p "$LOOT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOOT_DIR}/blueclues_${TIMESTAMP}.txt"

# Confirm Start
PROMPT "STARTING SCAN...

Saving to:
$LOG_FILE

Duration: ${MINS}m
Press OK to Begin."

# --- 4. MAIN SCAN LOOP ---
START_TIME=$(date +%s)
DURATION_SEC=$((MINS * 60))
END_TIME=$((START_TIME + DURATION_SEC))

set_global_color 0 0 0

while [ $(date +%s) -lt $END_TIME ]; do
    
    # Run Scan
    hcitool scan > /tmp/bt_scan.txt
    
    # Process Data (Skip header line)
    RAW_DATA=$(tail -n +2 /tmp/bt_scan.txt)
    
    if [ -n "$RAW_DATA" ]; then
        # Check for valid MAC address format
        if echo "$RAW_DATA" | grep -q ":"; then
            CURRENT_TIME=$(date '+%H:%M:%S')
            # Append to Log File
            echo "$RAW_DATA" | sed "s/^/$CURRENT_TIME\t/" >> "$LOG_FILE"
            
            # Feedback Trigger
            set_led 1 # Red
            do_vibe
            sleep 1
            set_global_color 0 0 0
        fi
    fi
    
    sleep 1
done

# --- 5. FINISH ---
# Summary logic
UNIQUE_COUNT=$(awk '{print $2}' "$LOG_FILE" 2>/dev/null | sort -u | grep -c ":" || echo 0)

PROMPT "SCAN COMPLETE

Found: $UNIQUE_COUNT Devices
Log Saved.

Press OK to Exit."

exit 0
