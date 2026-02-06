#!/bin/bash
#
# Title: Skimmer Scanner
# Description: Detects potential credit card skimmers by identifying suspicious Bluetooth devices
# Device: WiFi Pineapple Pager
# Author: Adam Glenn
# Version: 1.0
#

# --- 1. SETUP ---
WORK_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOG_FILE="$WORK_DIR/skimmer_detections.log"
BT_CACHE="$WORK_DIR/bt_scan.tmp"
SIGNATURES_FILE="$WORK_DIR/skimmer_signatures.txt"

# OUI Library for vendor lookup
OUI_FILE="/lib/hak5/oui.txt"
if [ ! -f "$OUI_FILE" ]; then OUI_FILE="/rom/lib/hak5/oui.txt"; fi

# --- 2. CLEANUP FUNCTION ---
cleanup() {
    killall hcitool 2>/dev/null
    killall bluetoothctl 2>/dev/null
    sleep 0.5

    if [ -f "$BT_CACHE" ]; then
        rm -f "$BT_CACHE"
    fi

    LED OFF
    exit
}

trap cleanup EXIT SIGINT SIGTERM

# --- 3. HELPER FUNCTIONS ---

# Vendor Lookup
get_vendor() {
    local mac=$1
    if [ ! -f "$OUI_FILE" ]; then echo "Unknown"; return; fi
    local mac_clean=$(echo "$mac" | tr -d ':' | head -c 6 | tr '[:lower:]' '[:upper:]')
    local vendor=$(grep -i "$mac_clean" "$OUI_FILE" 2>/dev/null | cut -f 3 | head -n 1)

    if [ -z "$vendor" ]; then echo "Unknown"; else echo "$vendor"; fi
}

# Get device name via Bluetooth inquiry
get_device_name() {
    local mac=$1
    local name=""

    # Try BLE first (faster)
    name=$(timeout 3 bluetoothctl info "$mac" 2>/dev/null | grep "Name:" | cut -d':' -f2- | xargs)

    # Fallback to classic BT
    if [ -z "$name" ]; then
        name=$(timeout 3 hcitool name "$mac" 2>/dev/null)
    fi

    if [ -z "$name" ]; then echo "<No Name>"; else echo "$name"; fi
}

# Check if device matches skimmer signatures
check_skimmer_signatures() {
    local mac=$1
    local name=$2
    local vendor=$3
    local risk_level=0
    local reasons=""

    # Load signature patterns if file exists
    if [ -f "$SIGNATURES_FILE" ]; then
        while IFS= read -r pattern; do
            # Skip empty lines and comments
            [[ -z "$pattern" || "$pattern" =~ ^# ]] && continue

            # Check if pattern matches MAC, name, or vendor (case insensitive)
            if echo "$mac" | grep -iq "$pattern" || \
               echo "$name" | grep -iq "$pattern" || \
               echo "$vendor" | grep -iq "$pattern"; then
                risk_level=$((risk_level + 2))
                reasons="${reasons}Signature match: $pattern; "
            fi
        done < "$SIGNATURES_FILE"
    fi

    # Common skimmer device name patterns
    if echo "$name" | grep -iE "HC-0[56]|BT0[0-9]|JDY-|MLT-BT|CSR|SPP-|RNBT|linvor" > /dev/null; then
        risk_level=$((risk_level + 3))
        reasons="${reasons}Known skimmer module name; "
    fi

    # Suspicious vendor OUIs (common cheap BT modules)
    # NOTE: Removed "Unknown" - random MACs legitimately won't have OUI entries
    if echo "$vendor" | grep -iE "Shenzhen|Guangdong|Generic|Bluegiga|Laird|Cypress|Silicon Labs" > /dev/null; then
        risk_level=$((risk_level + 2))
        reasons="${reasons}Suspicious vendor (common in DIY modules); "
    fi

    # Check for randomized MAC addresses (private BLE addresses)
    local is_random_mac=false
    if [[ "$mac" =~ ^[0-9A-F][2367ABEF]: ]]; then
        is_random_mac=true
        # Random MACs are NORMAL for modern BLE privacy - don't add points by themselves
    fi

    # Generic/No name - only flag if NOT a random MAC (random MACs don't broadcast names)
    if [[ "$name" == "<No Name>" || "$name" =~ ^[0-9A-F:-]+$ ]]; then
        if [ "$is_random_mac" = false ]; then
            # Non-random MAC with no name is more suspicious
            risk_level=$((risk_level + 2))
            reasons="${reasons}No device name on non-private device; "
        fi
    fi

    # Output results
    echo "${risk_level}|${reasons}"
}

# Notification function
notify_skimmer() {
    local mac=$1
    local name=$2
    local vendor=$3
    local risk=$4
    local reasons=$5

    # Determine severity
    local severity="UNKNOWN"
    local color_r=255
    local color_g=255
    local color_b=0

    if [ "$risk" -ge 5 ]; then
        severity="HIGH RISK"
        color_r=255
        color_g=0
        color_b=0
    elif [ "$risk" -ge 3 ]; then
        severity="MEDIUM RISK"
        color_r=255
        color_g=165
        color_b=0
    else
        severity="LOW RISK"
        color_r=255
        color_g=255
        color_b=0
    fi

    # Log the detection
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $severity - MAC: $mac | Name: $name | Vendor: $vendor" >> "$LOG_FILE"
    echo "  Reasons: $reasons" >> "$LOG_FILE"

    # Visual Alert (LED)
    LED R "$color_r" G "$color_g" B "$color_b"

    # Screen Alert
    ALERT "⚠ SKIMMER DETECTED" "Risk: $severity\n\nMAC: $mac\nName: $name\nVendor: $vendor\n\nCheck area for skimmers!"

    # Brief vibration pattern based on risk
    if [ "$risk" -ge 5 ]; then
        # High risk: 3 short buzzes
        for i in 1 2 3; do
            echo "1" > /sys/class/gpio/vibrator/value 2>/dev/null
            sleep 0.2
            echo "0" > /sys/class/gpio/vibrator/value 2>/dev/null
            sleep 0.2
        done
    else
        # Medium/Low risk: 1 buzz
        echo "1" > /sys/class/gpio/vibrator/value 2>/dev/null
        sleep 0.3
        echo "0" > /sys/class/gpio/vibrator/value 2>/dev/null
    fi

    sleep 2
    LED OFF
}

# --- 4. INITIALIZATION ---
killall hcitool 2>/dev/null
killall bluetoothctl 2>/dev/null
rm -f "$BT_CACHE"

# Create log file
touch "$LOG_FILE"
echo "=== Skimmer Scanner Started [$(date '+%Y-%m-%d %H:%M:%S')] ===" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Check for signature file
if [ ! -f "$SIGNATURES_FILE" ]; then
    LOG yellow "No signature file found, using built-in patterns only"
else
    LOG green "Loaded signature database"
fi

# Configuration prompt
PROMPT "SKIMMER SCANNER

Continuously monitors for suspicious Bluetooth devices that may be credit card skimmers.

Detects:
- Known skimmer modules (HC-05, BT04, etc.)
- Suspicious vendors
- Unnamed devices
- Random MAC addresses

Press OK to start."

# --- 5. MAIN SCANNING LOOP ---
LOG blue "Starting skimmer detection..."

# Track seen devices to prevent spam
declare -A SEEN_DEVICES

while true; do
    # Reset Bluetooth adapter
    hciconfig hci0 down 2>/dev/null
    sleep 0.5
    hciconfig hci0 up 2>/dev/null
    sleep 0.5

    # Perform BLE scan (most skimmers use BLE)
    : > "$BT_CACHE"
    timeout 8 hcitool lescan --duplicates 2>/dev/null | grep -E "([0-9A-F]{2}:){5}[0-9A-F]{2}" > "$BT_CACHE" &
    SCAN_PID=$!

    # Also try Classic Bluetooth in parallel
    timeout 5 hcitool scan 2>/dev/null | grep -E "([0-9A-F]{2}:){5}[0-9A-F]{2}" >> "$BT_CACHE" &
    SCAN_PID2=$!

    wait $SCAN_PID 2>/dev/null
    wait $SCAN_PID2 2>/dev/null

    # Process discovered devices
    if [ -s "$BT_CACHE" ]; then
        # Read MACs into array first to avoid subshell issue with pipes
        mapfile -t mac_array < <(grep -oE "([0-9A-F]{2}:){5}[0-9A-F]{2}" "$BT_CACHE" | sort -u)

        for bt_mac in "${mac_array[@]}"; do
            # Convert to uppercase for consistency
            bt_mac=$(echo "$bt_mac" | tr '[:lower:]' '[:upper:]')

            # Skip if we've already alerted on this device recently
            current_time=$(date +%s)
            if [ -n "${SEEN_DEVICES[$bt_mac]}" ]; then
                last_seen=${SEEN_DEVICES[$bt_mac]}
                # Re-check device every 5 minutes
                if [ $((current_time - last_seen)) -lt 300 ]; then
                    continue
                fi
            fi

            # Gather device information
            vendor=$(get_vendor "$bt_mac")
            name=$(get_device_name "$bt_mac")

            # Check against skimmer signatures
            result=$(check_skimmer_signatures "$bt_mac" "$name" "$vendor")
            risk_level=$(echo "$result" | cut -d'|' -f1)
            reasons=$(echo "$result" | cut -d'|' -f2)

            # Alert if risk level is significant (3 or higher - reduced false positives)
            if [ "$risk_level" -ge 3 ]; then
                notify_skimmer "$bt_mac" "$name" "$vendor" "$risk_level" "$reasons"
                SEEN_DEVICES[$bt_mac]=$current_time
            fi
        done
    fi

    # Clear cache
    : > "$BT_CACHE"

    # Pause between scans
    sleep 3
done
