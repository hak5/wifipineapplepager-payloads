#!/bin/bash
# Title: HUGINN - Identity Correlator
# Description: WiFi + BLE fusion for tracking devices through MAC randomization
# Author: HaleHound
# Version: 1.0.1
# Category: reconnaissance/correlation
# Named after Odin's raven - "thought" - sees all, correlates identities

# === CONFIGURATION ===
WIFI_INTERFACE="wlan1mon"
BLE_ADAPTER="hci0"
LOOTDIR="/root/loot/huginn"
WIFI_PROBES="/tmp/huginn_wifi.txt"
BLE_DEVICES="/tmp/huginn_ble.txt"
CORRELATION_DB="/tmp/huginn_correlations.txt"
OUI_FILE="/lib/hak5/oui.txt"

# Scan parameters
DEFAULT_SCAN_TIME=60
CHANNEL_HOP_DELAY=0.3

# === CLEANUP ===
cleanup() {
    # Kill capture processes using saved PIDs (not pkill -f huginn which kills this script!)
    if [ -f /tmp/huginn_wifi.pid ]; then
        kill -9 $(cat /tmp/huginn_wifi.pid) 2>/dev/null
        rm -f /tmp/huginn_wifi.pid
    fi
    if [ -f /tmp/huginn_ble.pid ]; then
        kill -9 $(cat /tmp/huginn_ble.pid) 2>/dev/null
        rm -f /tmp/huginn_ble.pid
    fi
    # Kill any orphaned tcpdump/hcitool processes
    pkill -9 -f "tcpdump.*$WIFI_INTERFACE" 2>/dev/null
    pkill -9 -f "hcitool.*lescan" 2>/dev/null
    # Reset BLE adapter
    hciconfig $BLE_ADAPTER down 2>/dev/null
    hciconfig $BLE_ADAPTER up 2>/dev/null
    LED OFF 2>/dev/null
}

trap cleanup EXIT INT TERM

# === LED PATTERNS ===
led_scanning() {
    LED R 0 G 0 B 255
}

led_correlation() {
    LED R 255 G 165 B 0
}

led_done() {
    LED R 0 G 255 B 0
}

# === HELPER FUNCTIONS ===

get_vendor() {
    local mac="$1"
    [ ! -f "$OUI_FILE" ] && [ -f "/rom/lib/hak5/oui.txt" ] && OUI_FILE="/rom/lib/hak5/oui.txt"

    if [ -f "$OUI_FILE" ]; then
        local oui=$(echo "$mac" | tr -d ':' | cut -c1-6 | tr 'a-f' 'A-F')
        grep -i "^$oui" "$OUI_FILE" 2>/dev/null | cut -f 3 | head -1
    fi
}

is_randomized_mac() {
    local second_char=$(echo "$1" | cut -c2)
    case "$second_char" in
        2|6|a|e|A|E) return 0 ;;
        *) return 1 ;;
    esac
}

# === WIFI CAPTURE (SIMPLIFIED) ===
start_wifi_capture() {
    local duration=$1
    LOG "Starting WiFi probe capture..."

    # Simple tcpdump capture - just get MACs and SSIDs
    timeout $duration tcpdump -i $WIFI_INTERFACE -e -l 2>/dev/null | \
    grep -i "probe request" | \
    while read line; do
        local ts=$(date +%s)
        local mac=$(echo "$line" | grep -oE 'SA:[0-9a-fA-F:]+' | cut -d: -f2- | head -1)
        local ssid=$(echo "$line" | grep -oE 'Probe Request \([^)]*\)' | sed 's/Probe Request (\(.*\))/\1/')

        if [ -n "$mac" ]; then
            [ -z "$ssid" ] && ssid="[Broadcast]"
            local vendor=$(get_vendor "$mac")
            [ -z "$vendor" ] && vendor="Unknown"
            echo "$ts|$mac|$ssid|$vendor" >> "$WIFI_PROBES"
        fi
    done &

    echo $! > /tmp/huginn_wifi.pid
}

# === BLE CAPTURE (SIMPLIFIED) ===
start_ble_capture() {
    local duration=$1
    LOG "Starting BLE scan..."

    hciconfig $BLE_ADAPTER down 2>/dev/null
    hciconfig $BLE_ADAPTER up 2>/dev/null
    sleep 0.5

    timeout $duration hcitool -i $BLE_ADAPTER lescan 2>/dev/null | \
    while read line; do
        local ts=$(date +%s)
        local mac=$(echo "$line" | grep -oE '[0-9A-Fa-f:]{17}' | head -1)
        local name=$(echo "$line" | sed "s/$mac//" | sed 's/^[[:space:]]*//')

        if [ -n "$mac" ] && [ "$mac" != "LE" ]; then
            [ -z "$name" ] && name="[Unknown]"
            local vendor=$(get_vendor "$mac")
            [ -z "$vendor" ] && vendor="Unknown"
            echo "$ts|$mac|$name|$vendor" >> "$BLE_DEVICES"
        fi
    done &

    echo $! > /tmp/huginn_ble.pid
}

# === SIMPLE CORRELATION ===
correlate_identities() {
    LOG "Running correlation..."

    {
        echo "=== HUGINN IDENTITY CORRELATIONS ==="
        echo "Generated: $(date)"
        echo ""

        # Count devices
        local wifi_count=$(cut -d'|' -f2 "$WIFI_PROBES" 2>/dev/null | sort -u | wc -l)
        local ble_count=$(cut -d'|' -f2 "$BLE_DEVICES" 2>/dev/null | sort -u | wc -l)

        echo "WiFi devices: $wifi_count"
        echo "BLE devices: $ble_count"
        echo ""

        # Simple vendor correlation
        echo "--- VENDOR MATCHES ---"

        # Get unique WiFi vendors
        cut -d'|' -f4 "$WIFI_PROBES" 2>/dev/null | sort -u | grep -v "Unknown" > /tmp/wifi_vendors.txt

        # Check each vendor in BLE data
        while read vendor; do
            if grep -q "|$vendor" "$BLE_DEVICES" 2>/dev/null; then
                echo "Vendor: $vendor"
                echo "  WiFi: $(grep "|$vendor" "$WIFI_PROBES" | cut -d'|' -f2 | head -1)"
                echo "  BLE:  $(grep "|$vendor" "$BLE_DEVICES" | cut -d'|' -f2 | head -1)"
                echo ""
            fi
        done < /tmp/wifi_vendors.txt

        rm -f /tmp/wifi_vendors.txt

        echo "--- WIFI DEVICES ---"
        cut -d'|' -f2,3,4 "$WIFI_PROBES" 2>/dev/null | sort -u | head -20

        echo ""
        echo "--- BLE DEVICES ---"
        cut -d'|' -f2,3,4 "$BLE_DEVICES" 2>/dev/null | sort -u | head -20

    } > "$CORRELATION_DB"

    LOG "Correlation complete"
}

# === MAIN ===

LOG ""
LOG " _  _ _  _  ___ ___ _  _ _  _ "
LOG "| || | || |/ __|_ _| \\| | \\| |"
LOG "| __ | || | (_ || || .\` | .\` |"
LOG "|_||_|\\__/ \\___|___|_|\\_|_|\\_|"
LOG ""
LOG " WiFi+BLE Correlator v1.0.1"
LOG " Odin's Raven of Thought"
LOG ""

PROMPT "HUGINN correlates WiFi and Bluetooth signals to track devices.

Press OK to configure."

# Get scan duration
scan_time=$(NUMBER_PICKER "Scan Duration (seconds)" 60)
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG "Cancelled"
        exit 1
        ;;
esac
[ -z "$scan_time" ] && scan_time=$DEFAULT_SCAN_TIME

DIALOG_RESULT=$(CONFIRMATION_DIALOG "Start $scan_time second scan?")
if [ "$DIALOG_RESULT" != "1" ]; then
    LOG "Cancelled"
    exit 0
fi

# Setup
mkdir -p "$LOOTDIR"
rm -f "$WIFI_PROBES" "$BLE_DEVICES" "$CORRELATION_DB"
touch "$WIFI_PROBES" "$BLE_DEVICES"

LOG "Scanning for $scan_time seconds..."
led_scanning

# Verify interfaces
if ! iw dev $WIFI_INTERFACE info >/dev/null 2>&1; then
    ERROR_DIALOG "WiFi interface $WIFI_INTERFACE not found!"
    exit 1
fi

if ! hciconfig $BLE_ADAPTER >/dev/null 2>&1; then
    ERROR_DIALOG "BLE adapter not found!"
    exit 1
fi

# Start captures
start_wifi_capture $scan_time
start_ble_capture $scan_time

# Wait with progress
elapsed=0
while [ $elapsed -lt $scan_time ]; do
    wifi_c=$(wc -l < "$WIFI_PROBES" 2>/dev/null || echo 0)
    ble_c=$(wc -l < "$BLE_DEVICES" 2>/dev/null || echo 0)
    LOG "[$elapsed/${scan_time}s] WiFi: $wifi_c | BLE: $ble_c"
    sleep 5
    elapsed=$((elapsed + 5))
done

LOG "Finalizing..."
sleep 2

# Kill captures
pkill -f "tcpdump.*$WIFI_INTERFACE" 2>/dev/null
pkill -f "hcitool.*lescan" 2>/dev/null

# Results
wifi_total=$(cut -d'|' -f2 "$WIFI_PROBES" 2>/dev/null | sort -u | wc -l)
ble_total=$(cut -d'|' -f2 "$BLE_DEVICES" 2>/dev/null | sort -u | wc -l)

LOG ""
LOG "=== SCAN COMPLETE ==="
LOG "WiFi devices: $wifi_total"
LOG "BLE devices: $ble_total"

led_correlation
VIBRATE 100

# Run correlation
correlate_identities

# Save results
timestamp=$(date +%Y%m%d_%H%M%S)
final_report="$LOOTDIR/huginn_report_$timestamp.txt"
cp "$CORRELATION_DB" "$final_report"
cp "$WIFI_PROBES" "$LOOTDIR/wifi_probes_$timestamp.txt" 2>/dev/null
cp "$BLE_DEVICES" "$LOOTDIR/ble_devices_$timestamp.txt" 2>/dev/null

rm -f "$WIFI_PROBES" "$BLE_DEVICES" "$CORRELATION_DB"

led_done
VIBRATE 200

LOG "Report: $final_report"

ALERT "HUGINN Complete!

WiFi: $wifi_total devices
BLE: $ble_total devices

Saved to: $LOOTDIR"

# View results?
DIALOG_RESULT=$(CONFIRMATION_DIALOG "View report?")
if [ "$DIALOG_RESULT" = "1" ]; then
    if [ -f "/root/payloads/user/general/log_viewer/payload.sh" ]; then
        source "/root/payloads/user/general/log_viewer/payload.sh" "$final_report"
    else
        cat "$final_report" | while read line; do LOG "$line"; done
    fi
fi

exit 0
