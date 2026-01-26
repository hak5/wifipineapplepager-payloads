#!/bin/bash
# Title: VERDANDI - Probe Fingerprint Engine
# Description: Defeats MAC randomization by fingerprinting probe request IEs
# Author: HaleHound
# Version: 2.0.1
# Category: reconnaissance/fingerprinting
#
# Named after Verdandi - the Norn who sees the present, the TRUE identity
#
# LED States:
#   Cyan Solid    - Capturing probes
#   Amber Solid   - Processing/fingerprinting
#   Green Solid   - Complete
#   Red Flash     - Error
#
# How this defeats MAC randomization:
#   Modern devices randomize their WiFi MAC addresses for privacy.
#   But they CANNOT randomize their radio capabilities:
#     - HT Capabilities (802.11n) - Tag 45
#     - VHT Capabilities (802.11ac) - Tag 191
#     - HE Capabilities (802.11ax/WiFi 6) - Tag 255 Extension 35
#     - Extended Capabilities - Tag 127
#     - Supported Rates - Tag 1
#     - Vendor Specific IEs - Tag 221
#     - IE Tag ORDER - different drivers send in different sequences
#
#   These create a FINGERPRINT that persists even when MAC changes.
#   Combined with RSSI, we can distinguish same-model devices.
#
# Changelog:
#   2.0.1 - Fixed RSSI extraction for BusyBox tr compatibility
#   2.0.0 - Major overhaul:
#           - Added RSSI tracking (distinguish same-model devices by distance)
#           - Added IE tag ORDER fingerprinting
#           - Added Extended Capabilities (Tag 127)
#           - Added Vendor Specific (Tag 221) extraction
#           - Added HE Capabilities (Tag 255/Ext 35) for WiFi 6
#           - Improved fingerprint uniqueness
#   1.1.0 - Added SSID extraction
#   1.0.0 - Initial release

# ============================================================================
# CONFIGURATION
# ============================================================================
WIFI_INTERFACE="wlan1mon"
LOOT_DIR="/root/loot/verdandi"
OUI_FILE="/lib/hak5/oui.txt"

# Temp files (in RAM)
CAPTURE_RAW="/tmp/verdandi_capture.txt"
FINGERPRINT_DB="/tmp/verdandi_fingerprints.txt"
MAC_TO_FP="/tmp/verdandi_mac_fp.txt"
FP_TO_SSID="/tmp/verdandi_fp_ssids.txt"
FP_TO_RSSI="/tmp/verdandi_fp_rssi.txt"
RESULTS_FILE="/tmp/verdandi_results.txt"

# Defaults
DEFAULT_SCAN_TIME=120

# ============================================================================
# CLEANUP
# ============================================================================
cleanup() {
    if [ -f /tmp/verdandi_hopper.pid ]; then
        kill $(cat /tmp/verdandi_hopper.pid) 2>/dev/null
        rm -f /tmp/verdandi_hopper.pid
    fi
    pkill -f "tcpdump.*verdandi" 2>/dev/null
    rm -f /tmp/verdandi_*.pid 2>/dev/null
    LED OFF 2>/dev/null
}
trap cleanup EXIT INT TERM

# ============================================================================
# LED PATTERNS
# ============================================================================
led_capturing() { LED R 0 G 255 B 255; }
led_processing() { LED R 255 G 165 B 0; }
led_done() { LED R 0 G 255 B 0; }
led_error() { LED R 255 G 0 B 0; sleep 0.2; LED OFF; sleep 0.2; LED R 255 G 0 B 0; }

# ============================================================================
# VENDOR LOOKUP
# ============================================================================
get_vendor() {
    local mac="$1"
    [ ! -f "$OUI_FILE" ] && [ -f "/rom/lib/hak5/oui.txt" ] && OUI_FILE="/rom/lib/hak5/oui.txt"
    if [ -f "$OUI_FILE" ]; then
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
    local second_char
    second_char=$(echo "$1" | cut -c2 | tr 'A-F' 'a-f')
    case "$second_char" in
        2|6|a|e) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================================
# CHANNEL HOPPING
# ============================================================================
CHANNELS_24="1 6 11"
CHANNELS_5="36 40 44 48 149 153 157 161"

start_channel_hopper() {
    local interface=$1
    local duration=$2
    (
        end_time=$(($(date +%s) + duration))
        while [ $(date +%s) -lt $end_time ]; do
            for ch in $CHANNELS_24; do
                iw dev "$interface" set channel "$ch" 2>/dev/null
                sleep 0.3
            done
            for ch in $CHANNELS_5; do
                iw dev "$interface" set channel "$ch" 2>/dev/null
                sleep 0.3
            done
        done
    ) &
    echo $! > /tmp/verdandi_hopper.pid
}

stop_channel_hopper() {
    if [ -f /tmp/verdandi_hopper.pid ]; then
        kill $(cat /tmp/verdandi_hopper.pid) 2>/dev/null
        rm -f /tmp/verdandi_hopper.pid
    fi
}

# ============================================================================
# PROBE CAPTURE
# ============================================================================
start_probe_capture() {
    local duration=$1
    LOG "Capturing probes with full IE extraction..."
    start_channel_hopper "$WIFI_INTERFACE" "$duration"

    # -e: Link-level header (MAC, RSSI)
    # -xx: Full hex dump for IE parsing
    # -s 1024: Capture enough for all IEs including vendor specific
    # -l: Line buffered
    timeout "$duration" tcpdump -i "$WIFI_INTERFACE" -e -xx -s 1024 -l \
        'type mgt subtype probe-req' 2>/dev/null > "$CAPTURE_RAW" &
    echo $! > /tmp/verdandi_capture.pid
}

# ============================================================================
# ENHANCED FINGERPRINT EXTRACTION ENGINE
# ============================================================================
# Extracts multiple IE types and their ORDER to create unique fingerprint
#
# Tags we extract:
#   Tag 1:   Supported Rates
#   Tag 45:  HT Capabilities (802.11n)
#   Tag 50:  Extended Supported Rates
#   Tag 127: Extended Capabilities (varies by OS)
#   Tag 191: VHT Capabilities (802.11ac)
#   Tag 221: Vendor Specific (OUI + data)
#   Tag 255: Extension Element (includes HE Caps for WiFi 6)

extract_fingerprint() {
    local hex_data="$1"

    # Convert to continuous lowercase hex string
    local hex_clean
    hex_clean=$(echo "$hex_data" | tr -d ' \n\t' | tr 'A-F' 'a-f')

    local ht_caps=""
    local vht_caps=""
    local he_caps=""
    local ext_caps=""
    local supported_rates=""
    local vendor_ouis=""
    local tag_order=""
    local frame_len=${#hex_clean}

    # Skip radiotap header (variable length) and 802.11 header
    # Radiotap length is at bytes 2-3 (little endian)
    # For simplicity, we search for known tag patterns in the entire frame

    # === TAG ORDER TRACKING ===
    # Find position of each tag type and sort to get order
    local tag_positions=""

    # HT Capabilities: Tag 45 (0x2d), usually length 26 (0x1a)
    if echo "$hex_clean" | grep -q "2d1a"; then
        ht_caps=$(echo "$hex_clean" | sed -n 's/.*2d1a\([0-9a-f]\{52\}\).*/\1/p' | head -1)
        local pos=$(echo "$hex_clean" | grep -bo "2d1a" | head -1 | cut -d: -f1)
        [ -n "$pos" ] && tag_positions="${tag_positions}${pos}:2d "
    fi

    # VHT Capabilities: Tag 191 (0xbf), length 12 (0x0c)
    if echo "$hex_clean" | grep -q "bf0c"; then
        vht_caps=$(echo "$hex_clean" | sed -n 's/.*bf0c\([0-9a-f]\{24\}\).*/\1/p' | head -1)
        local pos=$(echo "$hex_clean" | grep -bo "bf0c" | head -1 | cut -d: -f1)
        [ -n "$pos" ] && tag_positions="${tag_positions}${pos}:bf "
    fi

    # Extended Capabilities: Tag 127 (0x7f), variable length
    # Common lengths: 8, 10, 11 bytes
    if echo "$hex_clean" | grep -qE "7f0[89ab]"; then
        # Extract up to 22 hex chars (11 bytes) of ext caps
        ext_caps=$(echo "$hex_clean" | sed -n 's/.*7f\(0[89ab]\)\([0-9a-f]*\).*/\2/p' | cut -c1-22 | head -1)
        local pos=$(echo "$hex_clean" | grep -boE "7f0[89ab]" | head -1 | cut -d: -f1)
        [ -n "$pos" ] && tag_positions="${tag_positions}${pos}:7f "
    fi

    # Supported Rates: Tag 1 (0x01), length 4-8
    if echo "$hex_clean" | grep -qE "010[4-8]"; then
        supported_rates=$(echo "$hex_clean" | sed -n 's/.*01\(0[4-8]\)\([0-9a-f]*\).*/\2/p' | cut -c1-16 | head -1)
        local pos=$(echo "$hex_clean" | grep -boE "010[4-8]" | head -1 | cut -d: -f1)
        [ -n "$pos" ] && tag_positions="${tag_positions}${pos}:01 "
    fi

    # Extended Supported Rates: Tag 50 (0x32)
    if echo "$hex_clean" | grep -qE "320[1-8]"; then
        local pos=$(echo "$hex_clean" | grep -boE "320[1-8]" | head -1 | cut -d: -f1)
        [ -n "$pos" ] && tag_positions="${tag_positions}${pos}:32 "
    fi

    # HE Capabilities: Tag 255 (0xff) with Extension ID 35 (0x23)
    # Format: ff [length] 23 [HE caps data]
    if echo "$hex_clean" | grep -q "ff..23"; then
        he_caps=$(echo "$hex_clean" | sed -n 's/.*ff\(..\)23\([0-9a-f]*\).*/\2/p' | cut -c1-32 | head -1)
        local pos=$(echo "$hex_clean" | grep -bo "ff..23" | head -1 | cut -d: -f1)
        [ -n "$pos" ] && tag_positions="${tag_positions}${pos}:ff "
    fi

    # Vendor Specific: Tag 221 (0xdd)
    # Extract OUIs (3 bytes after length) - multiple may exist
    # Common OUIs: 00:17:f2 (Apple), 00:50:f2 (Microsoft WPS), 00:10:18 (Broadcom)
    local vendor_matches
    vendor_matches=$(echo "$hex_clean" | grep -oE "dd[0-9a-f]{2}[0-9a-f]{6}" | head -5)
    if [ -n "$vendor_matches" ]; then
        vendor_ouis=$(echo "$vendor_matches" | while read -r v; do
            echo "$v" | cut -c5-10
        done | sort -u | tr '\n' ',' | sed 's/,$//')
        local pos=$(echo "$hex_clean" | grep -bo "dd" | head -1 | cut -d: -f1)
        [ -n "$pos" ] && tag_positions="${tag_positions}${pos}:dd "
    fi

    # Sort tag positions to get tag ORDER
    tag_order=$(echo "$tag_positions" | tr ' ' '\n' | sort -t: -k1 -n | cut -d: -f2 | tr '\n' '-' | sed 's/-$//')

    # === BUILD FINGERPRINT STRING ===
    local fp_string=""

    # Tag order is high-entropy - drivers differ in IE sequence
    [ -n "$tag_order" ] && fp_string="${fp_string}ORD:${tag_order}|"

    # HT Caps - 802.11n radio features
    [ -n "$ht_caps" ] && fp_string="${fp_string}HT:${ht_caps}|"

    # VHT Caps - 802.11ac features
    [ -n "$vht_caps" ] && fp_string="${fp_string}VHT:${vht_caps}|"

    # HE Caps - WiFi 6 features
    [ -n "$he_caps" ] && fp_string="${fp_string}HE:${he_caps}|"

    # Extended Caps - varies by OS version
    [ -n "$ext_caps" ] && fp_string="${fp_string}EXT:${ext_caps}|"

    # Supported Rates
    [ -n "$supported_rates" ] && fp_string="${fp_string}SR:${supported_rates}|"

    # Vendor OUIs present
    [ -n "$vendor_ouis" ] && fp_string="${fp_string}VEN:${vendor_ouis}|"

    # Frame length bucket (rounded to 50 bytes)
    local frame_bucket=$((frame_len / 100 * 100))
    fp_string="${fp_string}LEN:${frame_bucket}"

    # Generate hash
    if [ -n "$fp_string" ]; then
        echo "$fp_string" | md5sum | cut -c1-16
    else
        echo ""
    fi
}

# ============================================================================
# PROCESS CAPTURED DATA
# ============================================================================
process_captures() {
    LOG "Processing probes with enhanced fingerprinting..."
    led_processing

    > "$FINGERPRINT_DB"
    > "$MAC_TO_FP"
    > "$FP_TO_SSID"
    > "$FP_TO_RSSI"

    local current_mac=""
    local current_ssid=""
    local current_rssi=""
    local current_hex=""
    local probe_count=0

    while IFS= read -r line; do
        # New packet header: timestamp, contains SA: and dBm
        if echo "$line" | grep -qE '^[0-9]{2}:[0-9]{2}:[0-9]{2}\.' && echo "$line" | grep -q 'SA:'; then
            # Process previous packet
            if [ -n "$current_mac" ] && [ -n "$current_hex" ]; then
                process_single_probe "$current_mac" "$current_hex" "$current_ssid" "$current_rssi"
                probe_count=$((probe_count + 1))
            fi

            current_hex=""

            # Extract MAC
            current_mac=$(echo "$line" | grep -oE 'SA:[0-9a-fA-F:]+' | head -1 | cut -d: -f2-)

            # Extract SSID from Probe Request (SSID_NAME)
            current_ssid=$(echo "$line" | sed -n 's/.*Probe Request (\([^)]*\)).*/\1/p')

            # Extract RSSI (e.g., "-51dBm signal") - use sed for BusyBox compatibility
            current_rssi=$(echo "$line" | grep -oE '[-][0-9]+dBm' | head -1 | sed 's/-//;s/dBm//')

        elif echo "$line" | grep -qE '^[[:space:]]+0x[0-9a-f]+:'; then
            # Hex data line
            local hex_part
            hex_part=$(echo "$line" | sed 's/.*0x[0-9a-f]*:[[:space:]]*//' | tr -d ' \t')
            current_hex="${current_hex}${hex_part}"
        fi

    done < "$CAPTURE_RAW"

    # Process last packet
    if [ -n "$current_mac" ] && [ -n "$current_hex" ]; then
        process_single_probe "$current_mac" "$current_hex" "$current_ssid" "$current_rssi"
        probe_count=$((probe_count + 1))
    fi

    LOG "Processed $probe_count probes"
}

process_single_probe() {
    local mac="$1"
    local hex_data="$2"
    local ssid="$3"
    local rssi="$4"

    [ -z "$mac" ] && return
    [ -z "$hex_data" ] && return

    local fingerprint
    fingerprint=$(extract_fingerprint "$hex_data")
    [ -z "$fingerprint" ] && return

    # Record MAC -> Fingerprint
    echo "${mac}|${fingerprint}|${rssi}" >> "$MAC_TO_FP"

    # Record SSID for fingerprint
    if [ -n "$ssid" ]; then
        if ! grep -q "^${fingerprint}|.*${ssid}" "$FP_TO_SSID" 2>/dev/null; then
            if grep -q "^${fingerprint}|" "$FP_TO_SSID" 2>/dev/null; then
                local old_line
                old_line=$(grep "^${fingerprint}|" "$FP_TO_SSID")
                local new_line="${old_line},${ssid}"
                grep -v "^${fingerprint}|" "$FP_TO_SSID" > "${FP_TO_SSID}.tmp" 2>/dev/null
                echo "$new_line" >> "${FP_TO_SSID}.tmp"
                mv "${FP_TO_SSID}.tmp" "$FP_TO_SSID"
            else
                echo "${fingerprint}|${ssid}" >> "$FP_TO_SSID"
            fi
        fi
    fi

    # Track RSSI range for fingerprint (helps distinguish same-model devices)
    if [ -n "$rssi" ]; then
        if grep -q "^${fingerprint}|" "$FP_TO_RSSI" 2>/dev/null; then
            local existing
            existing=$(grep "^${fingerprint}|" "$FP_TO_RSSI" | cut -d'|' -f2-)
            local min_rssi max_rssi
            min_rssi=$(echo "$existing" | cut -d',' -f1)
            max_rssi=$(echo "$existing" | cut -d',' -f2)
            [ "$rssi" -lt "$min_rssi" ] 2>/dev/null && min_rssi=$rssi
            [ "$rssi" -gt "$max_rssi" ] 2>/dev/null && max_rssi=$rssi
            grep -v "^${fingerprint}|" "$FP_TO_RSSI" > "${FP_TO_RSSI}.tmp" 2>/dev/null
            echo "${fingerprint}|${min_rssi},${max_rssi}" >> "${FP_TO_RSSI}.tmp"
            mv "${FP_TO_RSSI}.tmp" "$FP_TO_RSSI"
        else
            echo "${fingerprint}|${rssi},${rssi}" >> "$FP_TO_RSSI"
        fi
    fi

    # Update fingerprint DB with MAC
    if grep -q "^${fingerprint}|" "$FINGERPRINT_DB" 2>/dev/null; then
        local existing_entry
        existing_entry=$(grep "^${fingerprint}|" "$FINGERPRINT_DB")
        if ! echo "$existing_entry" | grep -q "$mac"; then
            local old_line
            old_line=$(grep "^${fingerprint}|" "$FINGERPRINT_DB")
            local new_line="${old_line},${mac}"
            grep -v "^${fingerprint}|" "$FINGERPRINT_DB" > "${FINGERPRINT_DB}.tmp" 2>/dev/null
            echo "$new_line" >> "${FINGERPRINT_DB}.tmp"
            mv "${FINGERPRINT_DB}.tmp" "$FINGERPRINT_DB"
        fi
    else
        echo "${fingerprint}|${mac}" >> "$FINGERPRINT_DB"
    fi
}

# ============================================================================
# ANALYZE RESULTS
# ============================================================================
analyze_fingerprints() {
    LOG "Analyzing fingerprints..."

    local total_macs=0
    local unique_fingerprints=0
    local randomization_detected=0

    total_macs=$(cut -d'|' -f1 "$MAC_TO_FP" 2>/dev/null | sort -u | wc -l | tr -d ' ')
    unique_fingerprints=$(cut -d'|' -f1 "$FINGERPRINT_DB" 2>/dev/null | sort -u | wc -l | tr -d ' ')

    {
        echo "=============================================="
        echo "  VERDANDI v2.0 - PROBE FINGERPRINT REPORT"
        echo "  Generated: $(date)"
        echo "=============================================="
        echo ""
        echo "SUMMARY"
        echo "======="
        echo "Total MAC Addresses Observed: $total_macs"
        echo "Unique Device Fingerprints:   $unique_fingerprints"
        echo ""

        if [ "$unique_fingerprints" -lt "$total_macs" ] && [ "$unique_fingerprints" -gt 0 ]; then
            echo "*** RANDOMIZATION DETECTED ***"
            echo "Multiple MACs mapping to same fingerprint = same device"
            echo ""
        fi

        echo "=============================================="
        echo "  DEVICE FINGERPRINTS"
        echo "=============================================="
        echo ""

        while IFS='|' read -r fingerprint macs_list; do
            [ -z "$fingerprint" ] && continue

            local mac_count
            mac_count=$(echo "$macs_list" | tr ',' '\n' | grep -c .)

            echo "=== Fingerprint: $fingerprint ==="

            if [ "$mac_count" -gt 1 ]; then
                echo ">>> SAME DEVICE - $mac_count MACs DETECTED <<<"
                randomization_detected=$((randomization_detected + 1))
            fi

            # Show SSIDs
            local ssids_line
            ssids_line=$(grep "^${fingerprint}|" "$FP_TO_SSID" 2>/dev/null | cut -d'|' -f2-)
            if [ -n "$ssids_line" ]; then
                echo "Networks Probed: $ssids_line"
            else
                echo "Networks Probed: (broadcast only - privacy mode)"
            fi

            # Show RSSI range
            local rssi_line
            rssi_line=$(grep "^${fingerprint}|" "$FP_TO_RSSI" 2>/dev/null | cut -d'|' -f2-)
            if [ -n "$rssi_line" ]; then
                local min_r max_r
                min_r=$(echo "$rssi_line" | cut -d',' -f1)
                max_r=$(echo "$rssi_line" | cut -d',' -f2)
                if [ "$min_r" = "$max_r" ]; then
                    echo "Signal Strength: -${min_r}dBm"
                else
                    echo "Signal Range: -${max_r}dBm to -${min_r}dBm"
                fi
            fi

            echo "MAC Addresses ($mac_count):"
            echo "$macs_list" | tr ',' '\n' | while read -r mac; do
                [ -z "$mac" ] && continue
                local vendor
                vendor=$(get_vendor "$mac")
                local rand_flag=""
                is_randomized_mac "$mac" && rand_flag=" [RAND]"
                echo "  $mac$rand_flag"
            done
            echo ""

        done < "$FINGERPRINT_DB"

        echo "=============================================="
        echo "  INTELLIGENCE SUMMARY"
        echo "=============================================="
        echo ""
        echo "Devices actively randomizing: $randomization_detected"
        echo ""

        if [ "$randomization_detected" -gt 0 ]; then
            echo "VERDANDI tracked these devices across MAC changes using:"
            echo "  - IE Tag Order (driver signature)"
            echo "  - HT/VHT/HE Capabilities (radio features)"
            echo "  - Extended Capabilities (OS fingerprint)"
            echo "  - Vendor OUIs (manufacturer hints)"
            echo "  - RSSI (distance differentiation)"
            echo ""
        fi

        # Show any fingerprints with significantly different RSSI
        echo "=============================================="
        echo "  COHORT ANALYSIS"
        echo "=============================================="
        echo ""
        echo "Same fingerprint + different RSSI = different people, same phone model"
        echo ""

        while IFS='|' read -r fp rssi_range; do
            [ -z "$fp" ] && continue
            local min_r max_r diff
            min_r=$(echo "$rssi_range" | cut -d',' -f1)
            max_r=$(echo "$rssi_range" | cut -d',' -f2)
            diff=$((max_r - min_r))
            # If RSSI varies by more than 20dB, likely different physical locations/people
            if [ "$diff" -gt 20 ] 2>/dev/null; then
                echo "Fingerprint $fp: RSSI spread ${diff}dB"
                echo "  Possible multiple people with same device model"
                echo ""
            fi
        done < "$FP_TO_RSSI"

        echo "=============================================="
        echo "  RAW DATA"
        echo "=============================================="
        echo ""
        echo "Fingerprint DB:"
        cat "$FINGERPRINT_DB" 2>/dev/null
        echo ""
        echo "SSID Mappings:"
        cat "$FP_TO_SSID" 2>/dev/null
        echo ""
        echo "RSSI Ranges:"
        cat "$FP_TO_RSSI" 2>/dev/null

    } > "$RESULTS_FILE"

    echo "$randomization_detected"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

LOG ""
LOG "__   _____ ___ ___   _   _  _ ___ ___ "
LOG "\\ \\ / / __| _ \\   \\ /_\\ | \\| |   \\_ _|"
LOG " \\ V /| _||   / |) / _ \\| .\` | |) | | "
LOG "  \\_/ |___|_|_\\___/_/ \\_\\_|\\_|___/___|"
LOG ""
LOG "    Probe Fingerprint Engine"
LOG "           v2.0.0"
LOG ""

PROMPT "VERDANDI defeats MAC randomization by fingerprinting:

- Radio capabilities (HT/VHT/HE)
- Extended capabilities (OS signature)
- IE tag ordering (driver signature)
- RSSI tracking (distance/location)

Press OK to configure."

scan_time=$(NUMBER_PICKER "Scan Duration (seconds)" "$DEFAULT_SCAN_TIME")
case $? in
    "$DUCKYSCRIPT_CANCELLED"|"$DUCKYSCRIPT_REJECTED"|"$DUCKYSCRIPT_ERROR")
        LOG "Cancelled"
        exit 0
        ;;
esac
[ -z "$scan_time" ] && scan_time=$DEFAULT_SCAN_TIME
[ "$scan_time" -lt 30 ] 2>/dev/null && scan_time=30
[ "$scan_time" -gt 600 ] 2>/dev/null && scan_time=600

DIALOG_RESULT=$(CONFIRMATION_DIALOG "Start ${scan_time}s scan?

Enhanced fingerprinting enabled.")

if [ "$DIALOG_RESULT" != "1" ]; then
    LOG "Cancelled"
    exit 0
fi

mkdir -p "$LOOT_DIR"
rm -f "$CAPTURE_RAW" "$FINGERPRINT_DB" "$MAC_TO_FP" "$FP_TO_SSID" "$FP_TO_RSSI" "$RESULTS_FILE"
touch "$CAPTURE_RAW" "$FINGERPRINT_DB" "$MAC_TO_FP" "$FP_TO_SSID" "$FP_TO_RSSI"

if ! iw dev "$WIFI_INTERFACE" info >/dev/null 2>&1; then
    if iw dev "wlan0mon" info >/dev/null 2>&1; then
        WIFI_INTERFACE="wlan0mon"
    else
        ERROR_DIALOG "Monitor interface not found!"
        exit 1
    fi
fi

LOG ""
LOG "=========================================="
LOG "  CAPTURING FOR ${scan_time}s"
LOG "  Enhanced fingerprinting active"
LOG "=========================================="
LOG ""

led_capturing
VIBRATE 100

start_probe_capture "$scan_time"

elapsed=0
while [ "$elapsed" -lt "$scan_time" ]; do
    local_lines=$(wc -l < "$CAPTURE_RAW" 2>/dev/null | tr -d ' ')
    LOG "[${elapsed}/${scan_time}s] Lines: $local_lines"
    sleep 5
    elapsed=$((elapsed + 5))
done

LOG ""
LOG "Processing..."

sleep 2
stop_channel_hopper
pkill -f "tcpdump.*$WIFI_INTERFACE" 2>/dev/null

process_captures
randomization_count=$(analyze_fingerprints)

timestamp=$(date +%Y%m%d_%H%M%S)
final_report="$LOOT_DIR/verdandi_report_${timestamp}.txt"
cp "$RESULTS_FILE" "$final_report"
cp "$FINGERPRINT_DB" "$LOOT_DIR/fingerprints_${timestamp}.txt" 2>/dev/null
cp "$MAC_TO_FP" "$LOOT_DIR/mac_to_fp_${timestamp}.txt" 2>/dev/null
cp "$FP_TO_SSID" "$LOOT_DIR/fp_ssids_${timestamp}.txt" 2>/dev/null
cp "$FP_TO_RSSI" "$LOOT_DIR/fp_rssi_${timestamp}.txt" 2>/dev/null

rm -f "$CAPTURE_RAW" "$FINGERPRINT_DB" "$MAC_TO_FP" "$FP_TO_SSID" "$FP_TO_RSSI" "$RESULTS_FILE"

led_done
VIBRATE 300

total_macs=$(grep -c . "$LOOT_DIR/mac_to_fp_${timestamp}.txt" 2>/dev/null || echo "0")
unique_fps=$(cut -d'|' -f1 "$LOOT_DIR/fingerprints_${timestamp}.txt" 2>/dev/null | sort -u | wc -l | tr -d ' ')

ALERT "VERDANDI v2.0 Complete!

MACs: $total_macs
Fingerprints: $unique_fps
Randomizing: $randomization_count

Enhanced tracking with:
- IE Tag Order
- Extended Caps
- RSSI Analysis

Report: $final_report"

DIALOG_RESULT=$(CONFIRMATION_DIALOG "View report?")
if [ "$DIALOG_RESULT" = "1" ]; then
    while IFS= read -r line; do
        LOG "$line"
    done < "$final_report"
    PROMPT "End of report."
fi

LOG ""
LOG "VERDANDI v2.0 complete"
exit 0
