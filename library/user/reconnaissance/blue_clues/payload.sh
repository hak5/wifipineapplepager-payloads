#!/bin/bash
# Title: Blue Clues
# Author: Brandon Starkweather
# Description: Active Audit Tool
# Version: 1.0

# --- 1. SETUP ---
SCRIPT_DIR=$(dirname "$0")
LOOT_DIR="/root/loot/blue_clues"
VIEWER_SCRIPT="/root/payloads/user/general/log_viewer/payload.sh"

# --- CONFIG FILES ---
# Ignore List: Located in the same directory as this script
IGNORE_FILE="${SCRIPT_DIR}/ignore_list.txt"
if [ ! -f "$IGNORE_FILE" ]; then touch "$IGNORE_FILE"; fi

# --- OUI LIBRARY ---
OUI_FILE="/lib/hak5/oui.txt"
if [ ! -f "$OUI_FILE" ]; then OUI_FILE="/rom/lib/hak5/oui.txt"; fi

# Helper: Vendor Lookup
get_vendor() {
    local mac=$1
    if [[ "$mac" == *"00:00:06"* ]]; then echo "Xerox (Generic)"; return; fi
    
    if [ ! -f "$OUI_FILE" ]; then echo "Unknown"; return; fi
    local mac_clean=$(echo "$mac" | tr -d ':' | head -c 6 | tr '[:lower:]' '[:upper:]')
    local vendor=$(grep -i "$mac_clean" "$OUI_FILE" 2>/dev/null | cut -f 3)
    
    if [ -z "$vendor" ]; then echo "Unknown"; else echo "$vendor"; fi
}

# Helper: Class Translator
get_device_type() {
    local hex=$1
    case "$hex" in
        *"240404"*) echo "[Headset]" ;;
        *"240418"*) echo "[Headphones]" ;;
        *"240408"*) echo "[Handsfree]" ;;
        *"200404"*) echo "[Audio/Video]" ;;
        *"5a020c"*) echo "[Phone: Smart]" ;;
        *"7a020c"*) echo "[Phone: iPhone]" ;;
        *"100"*)    echo "[Computer]" ;;
        *"500"*)    echo "[LAN/Access]" ;;
        *)          echo "[$hex]" ;;
    esac
}

# Helper: Name Request
get_real_name() {
    local target_mac=$1
    local forced_name=$(hcitool name "$target_mac")
    if [ -n "$forced_name" ]; then echo "$forced_name"; else echo "<Unknown>"; fi
}

# Helper: Services (Deep Scan)
get_services() {
    local target_mac=$1
    local raw_sdp=$(timeout 5 sdptool browse "$target_mac" 2>/dev/null)
    local services=$(echo "$raw_sdp" | grep "Service Name:" | cut -d':' -f2 | sed 's/^ //' | tr '\n' ',' | sed 's/,$//')
    if [ -z "$services" ]; then echo "{No Services}"; else echo "{$services}"; fi
}

# --- HARDWARE CONTROL ---
set_global_color() {
    for dir in up down left right; do
        if [ -f "/sys/class/leds/${dir}-led-red/brightness" ]; then
            echo "$1" > "/sys/class/leds/${dir}-led-red/brightness"
            echo "$2" > "/sys/class/leds/${dir}-led-green/brightness"
            echo "$3" > "/sys/class/leds/${dir}-led-blue/brightness"
        fi
    done
}
set_led() {
    if [ "$1" -eq 1 ] && { [ "$FB_MODE" -eq 2 ] || [ "$FB_MODE" -eq 4 ]; }; then set_global_color 255 0 0; fi
}
do_vibe() {
    if [ "$FB_MODE" -eq 3 ] || [ "$FB_MODE" -eq 4 ]; then
        if [ -f "/sys/class/gpio/vibrator/value" ]; then
            echo "1" > /sys/class/gpio/vibrator/value; sleep 0.2; echo "0" > /sys/class/gpio/vibrator/value
        fi
    fi
}
cleanup() { set_global_color 0 0 0; rm /tmp/bt_scan.txt /tmp/bt_inq.txt 2>/dev/null; }
trap cleanup INT TERM

# --- 2. CONFIGURATION ---
PROMPT "BLUE CLUES

Tool for auditing Bluetooth devices by attempting to connect to them.

Press OK."

PROMPT "FEEDBACK OPTIONS

1. Silent (Log Only)
2. LED (Red Flash)
3. Vibe (Short Buzz)
4. Both (Flash + Buzz)

Press OK."
FB_MODE=$(NUMBER_PICKER "Select Feedback Mode" 1)
if [ -z "$FB_MODE" ]; then exit 0; fi

PROMPT "DEEP SCAN?

Attempt connection for available services.

1. Yes (Slower)
2. No"
DEEP_CHOICE=$(NUMBER_PICKER "Select Option" 1)
DEEP_SCAN=false
if [ "$DEEP_CHOICE" -eq 1 ]; then DEEP_SCAN=true; fi

PROMPT "Set Duration of Scan 
in Minutes"
MINS=$(NUMBER_PICKER "Enter Minutes" 1)
if [ -z "$MINS" ]; then exit 0; fi

# --- 3. EXECUTION ---
mkdir -p "$LOOT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOOT_DIR}/blueclues_${TIMESTAMP}.txt"

PROMPT "STARTING...

Saving to:
$LOG_FILE

Press Enter to Continue."

START_TIME=$(date +%s)
END_TIME=$((START_TIME + (MINS * 60)))
set_global_color 0 0 0

# IN-MEMORY LIST FOR DEDUPLICATION
SEEN_MACS=""

while [ $(date +%s) -lt $END_TIME ]; do
    
    # 1. INQUIRY
    hcitool inq --flush > /tmp/bt_inq.txt
    
    # 2. Parse Loop
    grep -E "([0-9A-F]{2}:){5}[0-9A-F]{2}" /tmp/bt_inq.txt | while read -r line; do
        
        BT_MAC=$(echo "$line" | awk '{print $1}')
        RAW_CLASS=$(echo "$line" | grep -o "class: 0x[0-9a-fA-F]*" | cut -d' ' -f2)
        
        # --- IGNORE LIST CHECK ---
        if grep -Fq "$BT_MAC" "$IGNORE_FILE"; then
            continue
        fi

        # --- MEMORY DEDUPLICATION ---
        if [[ "$SEEN_MACS" == *"$BT_MAC"* ]]; then
            continue
        fi

        if [ -n "$BT_MAC" ]; then
            # New Valid Device
            SEEN_MACS="${SEEN_MACS} ${BT_MAC}"
            
            # Gather Intelligence
            VENDOR=$(get_vendor "$BT_MAC")
            TYPE_NAME=$(get_device_type "$RAW_CLASS")
            BT_NAME=$(get_real_name "$BT_MAC")
            
            # --- DEEP SCAN LOGIC ---
            SERVICES="{Skipped}"
            if [ "$DEEP_SCAN" = true ] || [ "$BT_NAME" == "<Unknown>" ]; then
                SERVICES=$(get_services "$BT_MAC")
            fi
            
            CURRENT_TIME=$(date '+%H:%M:%S')
            
            LOG_ENTRY="$CURRENT_TIME  $BT_MAC  $TYPE_NAME  [$VENDOR]  $BT_NAME  $SERVICES"
            echo "$LOG_ENTRY" >> "$LOG_FILE"
            
            set_led 1
            do_vibe
        fi
    done
    
    set_global_color 0 0 0
    sleep 1
done

cleanup
if [ -f "$VIEWER_SCRIPT" ]; then /bin/bash "$VIEWER_SCRIPT" "$LOG_FILE" 1; fi
exit 0