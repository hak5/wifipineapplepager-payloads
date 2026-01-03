#!/bin/bash
#
# Title: BT Pager Warden
# Description: Detects specific BT devices and alerts via Screen & LED. Giving you a fair warning so you can steer clear of a person if you want.
# Device: WiFi Pineapple Pager
# Author: oMen
#

# --- 1. SETUP ---
# Automatically find the script directory
WORK_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOG_FILE="$WORK_DIR/bt_warden.log"
BT_CACHE="$WORK_DIR/bt_scan.tmp"

# TARGETS (Use uppercase for MAC addresses)
# Put your ex-girlfriends, that one awkward colleague, or the pizza delivery guy you owe money, BD_ADDR here. Watch, Headset, Airpods etc..
TARGET_BT=("E4:65:B8:CE:18:9E" "49:EB:0C:C3:16:18" "80:7A:BF:11:DD:C2" "11:75:58:8E:E9:16")

# --- 2. CLEANUP FUNCTION ---
# This runs automatically when the script is stopped or killed.
cleanup() {
    # 1. Kill the scanning process immediately
    killall hcitool 2>/dev/null
    
    # 2. Wait a split second to release file locks
    sleep 0.5
    
    # 3. Delete the cache file AND the log file (Session only)
    if [ -f "$BT_CACHE" ]; then
        rm -f "$BT_CACHE"
    fi
    
    if [ -f "$LOG_FILE" ]; then
        rm -f "$LOG_FILE"
    fi
    
    # 4. Turn off LED and exit
    LED OFF
    exit
}

# Trap signals: Ensures cleanup runs on Exit, Ctrl+C (SIGINT) or Kill (SIGTERM)
trap cleanup EXIT SIGINT SIGTERM

# --- 3. INITIALIZATION ---
# Clean up any rogue processes from previous runs
killall hcitool 2>/dev/null
rm -f "$BT_CACHE"
rm -f "$LOG_FILE"

# Create a fresh log file for this session
touch "$LOG_FILE"
echo "--- BT Warden Started [$(date '+%H:%M:%S')] ---" >> "$LOG_FILE"

# --- 4. HELPER: NOTIFICATION ---
notify_hit() {
    local addr=$1
    
    # Anti-spam: Check the last 5 lines of the log
    if tail -n 5 "$LOG_FILE" | grep -q "$addr"; then
        return
    fi

    # Log the hit
    echo "[$(date '+%H:%M:%S')] ALERT: Target Found -> $addr" >> "$LOG_FILE"
    
    # Visual Alert (Blue LED)
    LED R 0 G 0 B 255
    
    # Screen Alert (Blocking)
    ALERT "TARGET DETECTED" "MAC: $addr\nDevice is nearby!"
    
    # Turn off LED after a short delay
    sleep 2
    LED OFF
}

# --- 5. MAIN LOOP ---
echo "Starting monitoring loop..."

while true; do
    
    # Reset Bluetooth adapter to prevent errors/hanging
    hciconfig hci0 down
    hciconfig hci0 up
    
    # Start scan in background to maintain PID control
    # overwriting the file (>) to keep it fresh
    hcitool lescan --duplicates 2>/dev/null > "$BT_CACHE" &
    SCAN_PID=$!
    
    # Scan duration
    sleep 5
    
    # Kill the specific scan process
    kill $SCAN_PID 2>/dev/null
    wait $SCAN_PID 2>/dev/null
    
    # Check results
    if [ -s "$BT_CACHE" ]; then
        for bt_target in "${TARGET_BT[@]}"; do
            # Case-insensitive search
            if grep -iq "$bt_target" "$BT_CACHE"; then
                notify_hit "$bt_target"
            fi
        done
    fi

    # Empty the cache file ensuring it's ready for the next loop
    : > "$BT_CACHE"

    # Pause between scans
    sleep 5
done
