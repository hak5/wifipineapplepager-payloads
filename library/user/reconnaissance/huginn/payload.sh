#!/bin/bash
# Title: HUGINN - WiFi/BLE Identity Correlator
# Description: Correlates WiFi probe requests with BLE advertisements to identify devices
# Author: HaleHound
# Version: 2.0.7
# Category: reconnaissance/correlation
#
# Named after Odin's raven of "thought" - sees all, correlates identities
#
# LED States:
#   Blue Solid    - Scanning in progress
#   Orange Solid  - Correlating data
#   Green Solid   - Complete
#   Red Flash     - Error
#
# What this actually does:
#   1. Captures WiFi probe requests (MAC, SSID, vendor, timestamp, RSSI)
#   2. Captures BLE advertisements (MAC, name, vendor, timestamp, RSSI)
#   3. Correlates them using temporal proximity + vendor matching
#   4. Outputs confidence-scored identity matches

# ============================================================================
# CONFIGURATION
# ============================================================================
WIFI_INTERFACE="wlan0mon"
BLE_ADAPTER="hci0"
LOOT_DIR="/root/loot/huginn"
OUI_FILE="/lib/hak5/oui.txt"

# Temp files (in RAM)
WIFI_RAW="/tmp/huginn_wifi_raw.txt"
BLE_RAW="/tmp/huginn_ble_raw.txt"
WIFI_PARSED="/tmp/huginn_wifi.txt"
BLE_PARSED="/tmp/huginn_ble.txt"
CORRELATION_RESULTS="/tmp/huginn_correlations.txt"

# Correlation parameters
TIME_WINDOW=15         # Seconds - tighter temporal correlation for higher quality matches
VENDOR_WEIGHT=40       # Points for matching vendor
TIME_WEIGHT=35         # Points for temporal proximity (scaled by closeness)
RSSI_WEIGHT=0          # DISABLED - BLE RSSI is fake (hcitool doesn't give RSSI)
APPEARANCE_WEIGHT=10   # Points for similar MAC types (both randomized or both permanent)
MIN_CONFIDENCE=35      # Require temporal + appearance (filters weak single-criterion matches)

# Defaults
DEFAULT_SCAN_TIME=60

# ============================================================================
# CLEANUP
# ============================================================================
cleanup() {
    # Kill channel hopper
    if [ -f /tmp/huginn_hopper.pid ]; then
        kill $(cat /tmp/huginn_hopper.pid) 2>/dev/null
        rm -f /tmp/huginn_hopper.pid
    fi

    # Kill any lingering capture processes
    pkill -f "tcpdump.*huginn" 2>/dev/null
    pkill -f "hcitool.*lescan" 2>/dev/null
    pkill -f "hcidump.*huginn" 2>/dev/null

    # Reset BLE adapter
    hciconfig "$BLE_ADAPTER" down 2>/dev/null
    hciconfig "$BLE_ADAPTER" up 2>/dev/null

    # Clean temp files
    rm -f "$WIFI_RAW" "$BLE_RAW" /tmp/huginn_*.pid 2>/dev/null

    LED OFF 2>/dev/null
}
trap cleanup EXIT INT TERM

# ============================================================================
# LED PATTERNS
# ============================================================================
led_scanning() { LED R 0 G 0 B 255; }
led_correlating() { LED R 255 G 165 B 0; }
led_done() { LED R 0 G 255 B 0; }
led_error() { LED R 255 G 0 B 0; sleep 0.2; LED OFF; sleep 0.2; LED R 255 G 0 B 0; }

# ============================================================================
# VENDOR LOOKUP
# ============================================================================
get_vendor() {
    local mac="$1"

    # Fallback OUI location
    [ ! -f "$OUI_FILE" ] && [ -f "/rom/lib/hak5/oui.txt" ] && OUI_FILE="/rom/lib/hak5/oui.txt"

    if [ -f "$OUI_FILE" ]; then
        # OUI file format: "B8:13:32\tVendor Name" (with colons, tab-separated)
        local oui
        oui=$(echo "$mac" | cut -c1-8 | tr 'a-f' 'A-F')
        grep -i "^$oui" "$OUI_FILE" 2>/dev/null | cut -f2 | head -1
    else
        echo "Unknown"
    fi
}

# ============================================================================
# MAC RANDOMIZATION DETECTION
# ============================================================================
is_randomized_mac() {
    # Locally administered MACs have second hex char as 2, 6, A, or E
    local second_char
    second_char=$(echo "$1" | cut -c2 | tr 'A-F' 'a-f')
    case "$second_char" in
        2|6|a|e) return 0 ;;  # Is randomized
        *) return 1 ;;         # Not randomized
    esac
}

# ============================================================================
# CHANNEL HOPPING
# ============================================================================
# 2.4GHz: 1, 6, 11 (non-overlapping)
# 5GHz: 36, 40, 44, 48, 149, 153, 157, 161
CHANNELS_24="1 6 11"
CHANNELS_5="36 40 44 48 149 153 157 161"

start_channel_hopper() {
    local interface=$1
    local duration=$2

    (
        end_time=$(($(date +%s) + duration))
        while [ $(date +%s) -lt $end_time ]; do
            # Hop through 2.4GHz channels
            for ch in $CHANNELS_24; do
                iw dev "$interface" set channel "$ch" 2>/dev/null
                sleep 0.3
            done
            # Hop through 5GHz channels
            for ch in $CHANNELS_5; do
                iw dev "$interface" set channel "$ch" 2>/dev/null
                sleep 0.3
            done
        done
    ) &
    echo $! > /tmp/huginn_hopper.pid
}

stop_channel_hopper() {
    if [ -f /tmp/huginn_hopper.pid ]; then
        kill $(cat /tmp/huginn_hopper.pid) 2>/dev/null
        rm -f /tmp/huginn_hopper.pid
    fi
}

# ============================================================================
# WIFI PROBE CAPTURE
# ============================================================================
start_wifi_capture() {
    local duration=$1
    LOG "Starting WiFi probe capture on $WIFI_INTERFACE..."

    # Start channel hopping in background
    LOG "Starting channel hopper (2.4GHz + 5GHz)..."
    start_channel_hopper "$WIFI_INTERFACE" "$duration"

    # Capture probe requests with tcpdump
    # Add timestamps DURING capture (not at parse time)
    # Format: unixtime|tcpdump_line
    (
        timeout "$duration" tcpdump -i "$WIFI_INTERFACE" -e -l -s 256 \
            type mgt subtype probe-req 2>/dev/null | \
        while IFS= read -r line; do
            echo "$(date +%s)|$line"
        done > "$WIFI_RAW"
    ) &

    echo $! > /tmp/huginn_wifi.pid
}

parse_wifi_probes() {
    LOG "Parsing WiFi probes..."

    # Clear previous
    > "$WIFI_PARSED"

    # Parse tcpdump output
    # Format: unixtime|tcpdump_line
    while IFS= read -r line; do
        # Extract timestamp from first field (captured during scan)
        local ts
        ts=$(echo "$line" | cut -d'|' -f1)
        [ -z "$ts" ] && ts=$(date +%s)

        # Get the rest of the line (tcpdump output)
        local tcpdump_line
        tcpdump_line=$(echo "$line" | cut -d'|' -f2-)

        # Extract source MAC (SA:xx:xx:xx:xx:xx:xx)
        local mac
        mac=$(echo "$tcpdump_line" | grep -oE 'SA:[0-9a-fA-F:]+' | cut -d: -f2- | head -1)
        [ -z "$mac" ] && continue

        # Extract SSID from Probe Request (SSID)
        local ssid
        ssid=$(echo "$tcpdump_line" | grep -oE 'Probe Request \([^)]*\)' | sed 's/Probe Request (\(.*\))/\1/')
        [ -z "$ssid" ] && ssid="[Broadcast]"

        # Extract signal strength
        local rssi
        rssi=$(echo "$tcpdump_line" | grep -oE '[-][0-9]+dBm' | tr -d 'dBm' | head -1)
        [ -z "$rssi" ] && rssi="-99"

        # Get vendor
        local vendor
        vendor=$(get_vendor "$mac")
        [ -z "$vendor" ] && vendor="Unknown"

        # Check if randomized
        local randomized="N"
        is_randomized_mac "$mac" && randomized="Y"

        # Output: timestamp|mac|ssid|rssi|vendor|randomized
        echo "${ts}|${mac}|${ssid}|${rssi}|${vendor}|${randomized}" >> "$WIFI_PARSED"

    done < "$WIFI_RAW"

    # Deduplicate by MAC (keep first occurrence with all SSIDs)
    sort -t'|' -k2,2 -u "$WIFI_PARSED" > "${WIFI_PARSED}.tmp"
    mv "${WIFI_PARSED}.tmp" "$WIFI_PARSED"
}

# ============================================================================
# BLE CAPTURE
# ============================================================================
start_ble_capture() {
    local duration=$1
    LOG "Starting BLE scan on $BLE_ADAPTER..."

    # Reset adapter
    hciconfig "$BLE_ADAPTER" down 2>/dev/null
    hciconfig "$BLE_ADAPTER" up 2>/dev/null
    sleep 0.5

    # Start lescan (outputs MAC + name)
    # Add timestamps DURING capture (not at parse time)
    # Format: unixtime|hcitool_line
    (
        timeout "$duration" hcitool -i "$BLE_ADAPTER" lescan 2>/dev/null | \
        while IFS= read -r line; do
            echo "$(date +%s)|$line"
        done > "$BLE_RAW"
    ) &
    echo $! > /tmp/huginn_ble.pid
}

parse_ble_advertisements() {
    LOG "Parsing BLE advertisements..."

    # Clear previous
    > "$BLE_PARSED"

    # Parse hcitool lescan output
    # Format: unixtime|MAC_ADDRESS DeviceName
    while IFS= read -r line; do
        # Extract timestamp from first field (captured during scan)
        local ts
        ts=$(echo "$line" | cut -d'|' -f1)
        [ -z "$ts" ] && ts=$(date +%s)

        # Get the rest of the line (hcitool output)
        local hci_line
        hci_line=$(echo "$line" | cut -d'|' -f2-)

        # Skip header
        echo "$hci_line" | grep -q "LE Scan" && continue

        # Extract MAC
        local mac
        mac=$(echo "$hci_line" | grep -oE '[0-9A-Fa-f:]{17}' | head -1)
        [ -z "$mac" ] && continue
        [ "$mac" = "00:00:00:00:00:00" ] && continue

        # Extract name (everything after MAC)
        local name
        name=$(echo "$hci_line" | sed "s/$mac//" | sed 's/^[[:space:]]*//' | tr -d '\n')
        [ -z "$name" ] && name="(unknown)"

        # Get vendor
        local vendor
        vendor=$(get_vendor "$mac")
        [ -z "$vendor" ] && vendor="Unknown"

        # Check if randomized
        local randomized="N"
        is_randomized_mac "$mac" && randomized="Y"

        # BLE doesn't give RSSI easily from hcitool, use placeholder
        local rssi="-70"

        # Output: timestamp|mac|name|rssi|vendor|randomized
        echo "${ts}|${mac}|${name}|${rssi}|${vendor}|${randomized}" >> "$BLE_PARSED"

    done < "$BLE_RAW"

    # Deduplicate by MAC
    sort -t'|' -k2,2 -u "$BLE_PARSED" > "${BLE_PARSED}.tmp"
    mv "${BLE_PARSED}.tmp" "$BLE_PARSED"
}

# ============================================================================
# CORRELATION ENGINE - THE REAL DEAL
# ============================================================================
correlate_signals() {
    LOG "Running correlation engine..."
    led_correlating

    local wifi_count ble_count
    wifi_count=$(wc -l < "$WIFI_PARSED" 2>/dev/null | tr -d ' ')
    ble_count=$(wc -l < "$BLE_PARSED" 2>/dev/null | tr -d ' ')

    [ "$wifi_count" -eq 0 ] && { LOG "No WiFi devices captured"; return 1; }
    [ "$ble_count" -eq 0 ] && { LOG "No BLE devices captured"; return 1; }

    LOG "Correlating $wifi_count WiFi devices with $ble_count BLE devices..."

    # Create results file
    {
        echo "=============================================="
        echo "  HUGINN IDENTITY CORRELATION REPORT"
        echo "  Generated: $(date)"
        echo "=============================================="
        echo ""
        echo "WiFi Devices: $wifi_count"
        echo "BLE Devices:  $ble_count"
        echo ""
        echo "Correlation Parameters:"
        echo "  Time Window:    ${TIME_WINDOW}s"
        echo "  Min Confidence: ${MIN_CONFIDENCE}%"
        echo ""
        echo "=============================================="
        echo "  CORRELATED IDENTITIES"
        echo "=============================================="
        echo ""
    } > "$CORRELATION_RESULTS"

    local matches=0
    local seen_pairs="/tmp/huginn_seen_pairs.txt"
    rm -f "$seen_pairs"
    touch "$seen_pairs"

    # For each WiFi device, check against all BLE devices
    while IFS='|' read -r w_ts w_mac w_ssid w_rssi w_vendor w_rand; do
        [ -z "$w_mac" ] && continue

        while IFS='|' read -r b_ts b_mac b_name b_rssi b_vendor b_rand; do
            [ -z "$b_mac" ] && continue

            # Skip if same MAC (shouldn't happen but check)
            [ "$w_mac" = "$b_mac" ] && continue

            # Skip if we've already seen this WiFi+BLE pair (deduplication)
            local pair_key="${w_mac}:${b_mac}"
            if grep -q "^${pair_key}$" "$seen_pairs" 2>/dev/null; then
                continue
            fi

            # Calculate confidence score
            local score=0
            local reasons=""

            # 1. VENDOR MATCH (most important)
            if [ "$w_vendor" != "Unknown" ] && [ "$b_vendor" != "Unknown" ]; then
                if [ "$w_vendor" = "$b_vendor" ]; then
                    score=$((score + VENDOR_WEIGHT))
                    reasons="${reasons}Vendor match ($w_vendor); "
                fi
            fi

            # 2. TEMPORAL PROXIMITY
            local time_diff
            time_diff=$((w_ts - b_ts))
            [ $time_diff -lt 0 ] && time_diff=$((time_diff * -1))

            if [ "$time_diff" -le "$TIME_WINDOW" ]; then
                # Scale points by how close in time
                local time_score
                time_score=$((TIME_WEIGHT * (TIME_WINDOW - time_diff) / TIME_WINDOW))
                score=$((score + time_score))
                reasons="${reasons}Time proximity (${time_diff}s); "
            fi

            # 3. RSSI SIMILARITY (within 15 dBm)
            local rssi_diff
            rssi_diff=$((w_rssi - b_rssi))
            [ $rssi_diff -lt 0 ] && rssi_diff=$((rssi_diff * -1))

            if [ "$rssi_diff" -le 15 ]; then
                local rssi_score
                rssi_score=$((RSSI_WEIGHT * (15 - rssi_diff) / 15))
                score=$((score + rssi_score))
                reasons="${reasons}RSSI similar (${rssi_diff}dB diff); "
            fi

            # 4. BOTH RANDOMIZED OR BOTH NOT
            if [ "$w_rand" = "$b_rand" ]; then
                score=$((score + APPEARANCE_WEIGHT))
                if [ "$w_rand" = "Y" ]; then
                    reasons="${reasons}Both randomized MACs; "
                else
                    reasons="${reasons}Both permanent MACs; "
                fi
            fi

            # Report if above threshold
            if [ "$score" -ge "$MIN_CONFIDENCE" ]; then
                # Mark this pair as seen (deduplication)
                echo "$pair_key" >> "$seen_pairs"
                matches=$((matches + 1))
                {
                    echo "--- Match #${matches} (Confidence: ${score}%) ---"
                    echo "WiFi Device:"
                    echo "  MAC:    $w_mac $([ "$w_rand" = "Y" ] && echo "[RANDOMIZED]")"
                    echo "  Vendor: $w_vendor"
                    echo "  SSID:   $w_ssid"
                    echo "  RSSI:   ${w_rssi}dBm"
                    echo ""
                    echo "BLE Device:"
                    echo "  MAC:    $b_mac $([ "$b_rand" = "Y" ] && echo "[RANDOMIZED]")"
                    echo "  Vendor: $b_vendor"
                    echo "  Name:   $b_name"
                    echo "  RSSI:   ${b_rssi}dBm"
                    echo ""
                    echo "Correlation Reasons:"
                    echo "  $reasons"
                    echo ""
                } >> "$CORRELATION_RESULTS"
            fi

        done < "$BLE_PARSED"
    done < "$WIFI_PARSED"

    # Summary
    {
        echo "=============================================="
        echo "  SUMMARY"
        echo "=============================================="
        echo ""
        echo "Total Correlations Found: $matches"
        echo ""
        if [ "$matches" -eq 0 ]; then
            echo "No high-confidence matches found."
            echo "This could mean:"
            echo "  - Devices are using different vendors for WiFi/BLE"
            echo "  - Signals were not captured in same time window"
            echo "  - MAC randomization is hiding identities"
        fi
        echo ""
        echo "=============================================="
        echo "  RAW DEVICE LISTS"
        echo "=============================================="
        echo ""
        echo "--- WiFi Devices ---"
        while IFS='|' read -r ts mac ssid rssi vendor rand; do
            echo "  $mac | $vendor | $ssid | ${rssi}dBm $([ "$rand" = "Y" ] && echo "[RAND]")"
        done < "$WIFI_PARSED"
        echo ""
        echo "--- BLE Devices ---"
        while IFS='|' read -r ts mac name rssi vendor rand; do
            echo "  $mac | $vendor | $name $([ "$rand" = "Y" ] && echo "[RAND]")"
        done < "$BLE_PARSED"
    } >> "$CORRELATION_RESULTS"

    LOG "Correlation complete: $matches matches found"
    return 0
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Banner
LOG ""
LOG " _  _ _   _  ___ ___ _  _ _  _ "
LOG "| || | | | |/ __|_ _| \\| | \\| |"
LOG "| __ | |_| | (_ || || .\` | .\` |"
LOG "|_||_|\\___/ \\___|___|_|\\_|_|\\_|"
LOG ""
LOG "  WiFi/BLE Identity Correlator"
LOG "          v2.0.7"
LOG ""

# Introduction
PROMPT "HUGINN correlates WiFi and Bluetooth signals to identify devices that appear on both bands.

This helps track devices even when they use MAC randomization.

Press OK to configure."

# Get scan duration
scan_time=$(NUMBER_PICKER "Scan Duration (seconds)" "$DEFAULT_SCAN_TIME")
case $? in
    "$DUCKYSCRIPT_CANCELLED"|"$DUCKYSCRIPT_REJECTED"|"$DUCKYSCRIPT_ERROR")
        LOG "Cancelled by user"
        exit 0
        ;;
esac
[ -z "$scan_time" ] && scan_time=$DEFAULT_SCAN_TIME

# Confirm
DIALOG_RESULT=$(CONFIRMATION_DIALOG "Start ${scan_time}s scan?

WiFi: $WIFI_INTERFACE
BLE:  $BLE_ADAPTER")

if [ "$DIALOG_RESULT" != "1" ]; then
    LOG "Cancelled by user"
    exit 0
fi

# Setup
mkdir -p "$LOOT_DIR"
rm -f "$WIFI_RAW" "$BLE_RAW" "$WIFI_PARSED" "$BLE_PARSED" "$CORRELATION_RESULTS"
touch "$WIFI_RAW" "$BLE_RAW" "$WIFI_PARSED" "$BLE_PARSED"

# Verify interfaces
if ! iw dev "$WIFI_INTERFACE" info >/dev/null 2>&1; then
    ERROR_DIALOG "WiFi interface $WIFI_INTERFACE not found!

Make sure monitor mode is enabled."
    exit 1
fi

if ! hciconfig "$BLE_ADAPTER" >/dev/null 2>&1; then
    ERROR_DIALOG "BLE adapter $BLE_ADAPTER not found!"
    exit 1
fi

# Start scanning
LOG ""
LOG "=========================================="
LOG "  SCANNING FOR ${scan_time} SECONDS"
LOG "=========================================="
LOG ""

led_scanning
VIBRATE 100

# Start both captures simultaneously
start_wifi_capture "$scan_time"
start_ble_capture "$scan_time"

# Progress display
elapsed=0
while [ "$elapsed" -lt "$scan_time" ]; do
    wifi_lines=$(wc -l < "$WIFI_RAW" 2>/dev/null | tr -d ' ')
    ble_lines=$(wc -l < "$BLE_RAW" 2>/dev/null | tr -d ' ')
    LOG "[${elapsed}/${scan_time}s] WiFi: $wifi_lines packets | BLE: $ble_lines lines"
    sleep 5
    elapsed=$((elapsed + 5))
done

LOG ""
LOG "Scan complete. Processing..."

# Wait for captures to finish
sleep 2

# Kill any remaining capture processes
pkill -f "tcpdump.*$WIFI_INTERFACE" 2>/dev/null
pkill -f "hcitool.*lescan" 2>/dev/null

# Parse the raw captures
parse_wifi_probes
parse_ble_advertisements

# Count unique devices
wifi_devices=$(wc -l < "$WIFI_PARSED" 2>/dev/null | tr -d ' ')
ble_devices=$(wc -l < "$BLE_PARSED" 2>/dev/null | tr -d ' ')

LOG ""
LOG "=========================================="
LOG "  CAPTURE COMPLETE"
LOG "=========================================="
LOG "WiFi Devices: $wifi_devices"
LOG "BLE Devices:  $ble_devices"
LOG ""

VIBRATE 200

# Run correlation
if ! correlate_signals; then
    led_error
    ERROR_DIALOG "Correlation failed - not enough data captured."
    exit 1
fi

# Save results
timestamp=$(date +%Y%m%d_%H%M%S)
final_report="$LOOT_DIR/huginn_report_${timestamp}.txt"
cp "$CORRELATION_RESULTS" "$final_report"

# Also save raw data for analysis
cp "$WIFI_PARSED" "$LOOT_DIR/wifi_devices_${timestamp}.txt" 2>/dev/null
cp "$BLE_PARSED" "$LOOT_DIR/ble_devices_${timestamp}.txt" 2>/dev/null

# Cleanup temp files
rm -f "$WIFI_RAW" "$BLE_RAW" "$WIFI_PARSED" "$BLE_PARSED" "$CORRELATION_RESULTS"

led_done
VIBRATE 300

# Get match count from report
match_count=$(grep -c "^--- Match #" "$final_report" 2>/dev/null || echo "0")

# Alert
ALERT "HUGINN Complete!

WiFi Devices: $wifi_devices
BLE Devices:  $ble_devices
Correlations: $match_count

Report saved to:
$final_report"

# Offer to view results
DIALOG_RESULT=$(CONFIRMATION_DIALOG "View correlation report?")
if [ "$DIALOG_RESULT" = "1" ]; then
    if [ -f "/root/payloads/user/general/log_viewer/payload.sh" ]; then
        /root/payloads/user/general/log_viewer/payload.sh "$final_report"
    else
        # Fallback: display in LOG
        while IFS= read -r line; do
            LOG "$line"
        done < "$final_report"
        PROMPT "End of report. Press OK."
    fi
fi

LOG ""
LOG "HUGINN complete. Results in $LOOT_DIR"

exit 0
