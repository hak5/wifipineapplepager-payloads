#!/bin/bash
# Title: HandyShake - Enhanced Handshake Capture Alert
# Author: curtthecoder - github.com/curthayman
# Description: Comprehensive handshake alert with visual/tactile feedback, vendor lookup, and detailed logging
# Version: 1.1
# Based on: handshake-ssid by RootJunky

# ============================================================================
# CONFIGURATION
# ============================================================================

PCAP="$_ALERT_HANDSHAKE_PCAP_PATH"
LOG "HANDYSHAKE: triggered - AP=$_ALERT_HANDSHAKE_AP_MAC_ADDRESS PCAP=$PCAP"
LOG_FILE="/root/loot/handshakes/handshake_log.txt"
CAPTURE_HISTORY="/root/loot/handshakes/capture_history.txt"
ENABLE_VENDOR_LOOKUP=true
ENABLE_GPS_LOGGING=true
ENABLE_AUTO_RENAME=true
RESTORE_LED="R SOLID"       # LED color/mode to restore after alert (e.g. "R SOLID", "G SLOW"). Leave empty to keep alert color.

# ============================================================================
# EXTRACT SSID FROM PCAP
# ============================================================================

# Try summary variable first (works for partial handshakes with no Beacon frames)
SSID=$(echo "$_ALERT_HANDSHAKE_SUMMARY" | sed -n 's/.*SSID[: ]*"\([^"]*\)".*/\1/p' | head -1)

# Fallback: parse Beacon frames from PCAP (works for complete handshakes)
if [ -z "$SSID" ] && [ -f "$PCAP" ]; then
    SSID=$(tcpdump -r "$PCAP" -e -I -s 256 2>/dev/null \
      | sed -n 's/.*Beacon (\([^)]*\)).*/\1/p' \
      | head -n 1)
fi

[ -n "$SSID" ] || SSID="UNKNOWN_SSID_IHAVENOCLUE"

# ============================================================================
# DUPLICATE DETECTION
# ============================================================================

DUPLICATE=false
CAPTURE_KEY="${_ALERT_HANDSHAKE_AP_MAC_ADDRESS}|${_ALERT_HANDSHAKE_CLIENT_MAC_ADDRESS}"

mkdir -p "$(dirname "$CAPTURE_HISTORY")"
touch "$CAPTURE_HISTORY"

if grep -qF "$CAPTURE_KEY" "$CAPTURE_HISTORY" 2>/dev/null; then
    DUPLICATE=true
    LOG "DUPLICATE: $SSID ($CAPTURE_KEY) already captured - logging only"
fi

echo "${CAPTURE_KEY}|${SSID}|$(date '+%Y-%m-%d %H:%M:%S')" >> "$CAPTURE_HISTORY"

# ============================================================================
# SIGNAL STRENGTH AND CHANNEL
# ============================================================================

RSSI=""
CHANNEL=""

RSSI=$(tcpdump -r "$PCAP" -e -I -s 256 2>/dev/null \
  | sed -n 's/.*[^0-9]\(-[0-9][0-9]*\)dBm signal.*/\1/p' \
  | head -n 1)
[ -n "$RSSI" ] && RSSI="${RSSI}dBm" || RSSI="N/A"

CHANNEL=$(tcpdump -r "$PCAP" -e -I -s 256 2>/dev/null \
  | sed -n 's/.*[^0-9]\([0-9][0-9]*\) MHz.*/\1/p' \
  | head -n 1)
if [ -n "$CHANNEL" ]; then
    case "$CHANNEL" in
        2412) CHANNEL="1" ;; 2417) CHANNEL="2" ;; 2422) CHANNEL="3" ;;
        2427) CHANNEL="4" ;; 2432) CHANNEL="5" ;; 2437) CHANNEL="6" ;;
        2442) CHANNEL="7" ;; 2447) CHANNEL="8" ;; 2452) CHANNEL="9" ;;
        2457) CHANNEL="10" ;; 2462) CHANNEL="11" ;; 2467) CHANNEL="12" ;;
        2472) CHANNEL="13" ;; 2484) CHANNEL="14" ;;
        5180) CHANNEL="36" ;; 5200) CHANNEL="40" ;; 5220) CHANNEL="44" ;;
        5240) CHANNEL="48" ;; 5260) CHANNEL="52" ;; 5280) CHANNEL="56" ;;
        5300) CHANNEL="60" ;; 5320) CHANNEL="64" ;; 5500) CHANNEL="100" ;;
        5520) CHANNEL="104" ;; 5540) CHANNEL="108" ;; 5560) CHANNEL="112" ;;
        5580) CHANNEL="116" ;; 5600) CHANNEL="120" ;; 5620) CHANNEL="124" ;;
        5640) CHANNEL="128" ;; 5660) CHANNEL="132" ;; 5680) CHANNEL="136" ;;
        5700) CHANNEL="140" ;; 5720) CHANNEL="144" ;; 5745) CHANNEL="149" ;;
        5765) CHANNEL="153" ;; 5785) CHANNEL="157" ;; 5805) CHANNEL="161" ;;
        5825) CHANNEL="165" ;;
        *) CHANNEL="${CHANNEL}MHz" ;;
    esac
else
    CHANNEL="N/A"
fi

# ============================================================================
# CAPTURE COUNTER
# ============================================================================

CAPTURE_COUNT=$(wc -l < "$CAPTURE_HISTORY" 2>/dev/null | tr -d ' ')
[ -n "$CAPTURE_COUNT" ] || CAPTURE_COUNT="1"

# ============================================================================
# HASH FILE VERIFICATION
# ============================================================================

HASH_FILE="$_ALERT_HANDSHAKE_HASHCAT_PATH"
HASH_STATUS="OK"

if [ -z "$HASH_FILE" ] || [ ! -f "$HASH_FILE" ]; then
    HASH_STATUS="MISSING"
elif [ ! -s "$HASH_FILE" ]; then
    HASH_STATUS="EMPTY"
fi

if [ "$HASH_STATUS" = "MISSING" ] && [ -f "$PCAP" ] && command -v hcxpcapngtool >/dev/null 2>&1; then
    RECOVERED_HASH="${PCAP%.pcap}.22000"
    timeout 10 hcxpcapngtool -o "$RECOVERED_HASH" "$PCAP" 2>/dev/null
    if [ -s "$RECOVERED_HASH" ]; then
        HASH_FILE="$RECOVERED_HASH"
        HASH_STATUS="RECOVERED"
        LOG "HASH RECOVERY: Generated $RECOVERED_HASH from PCAP"
    fi
fi

# ============================================================================
# VENDOR LOOKUP
# ============================================================================

AP_VENDOR="Unknown Vendor"
CLIENT_VENDOR="Unknown Vendor"

if [ "$ENABLE_VENDOR_LOOKUP" = true ]; then
    HAK5_OUI="/root/.hcxtools/oui.txt"

    _oui_file_lookup() {
        local mac="$1"
        [ -f "$HAK5_OUI" ] || return 1
        local oui
        oui=$(echo "$mac" | tr ':' '-' | cut -c1-8 | tr '[:lower:]' '[:upper:]')
        grep -i "^${oui}[[:space:]]*(hex)" "$HAK5_OUI" \
            | sed 's/^[^)]*)[[:space:]]*//' \
            | head -1 | tr -d '\r\n'
    }

    _lookup_vendor() {
        local mac="$1"
        local v=""

        if command -v whoismac >/dev/null 2>&1; then
            v=$(timeout 5 whoismac -m "$mac" 2>/dev/null \
                | grep -i "^VENDOR:" | head -1 \
                | sed 's/^VENDOR: *//;s/ *(UAA[^)]*) *,.*//;s/ *(LAA[^)]*) *,.*//;s/ *([Uu]nicast.*//' \
                | tr -d '\r\n')
        fi

        # Fallback to OUI file if whoismac unavailable or returned nothing
        if [ -z "$v" ] || [ "$v" = "Unknown Vendor" ]; then
            v=$(_oui_file_lookup "$mac")
        fi

        echo "${v:-Unknown Vendor}"
    }

    AP_VENDOR=$(_lookup_vendor "$_ALERT_HANDSHAKE_AP_MAC_ADDRESS")
    CLIENT_VENDOR=$(_lookup_vendor "$_ALERT_HANDSHAKE_CLIENT_MAC_ADDRESS")

    if [ "$AP_VENDOR" = "Unknown Vendor" ] || [ "$CLIENT_VENDOR" = "Unknown Vendor" ]; then
        LOG "VENDOR LOOKUP: One or more vendors unknown - OUI database may be outdated. Update: cd ~/.hcxtools && rm oui.txt && wget https://standards-oui.ieee.org/oui/oui.txt"
    fi
fi

# ============================================================================
# GPS COORDINATES (if available)
# ============================================================================

GPS_DATA=""
if [ "$ENABLE_GPS_LOGGING" = true ]; then
    GPS_INFO=$(timeout 5 GPS_GET 2>/dev/null)
    if [ -n "$GPS_INFO" ] && ! echo "$GPS_INFO" | grep -qE '^[0., ]+$'; then
        GPS_DATA=" | GPS: $GPS_INFO"
    else
        GPS_INFO=""
        GPS_DATA=" | GPS: No GPS"
    fi
fi

# ============================================================================
# DEVICE AND NETWORK INTELLIGENCE
# ============================================================================

_classify_device() {
    local vendor="$1"
    if echo "$vendor" | grep -qi "amazon"; then
        echo "Amazon device (Echo/Fire TV/Kindle/Ring)"
    elif echo "$vendor" | grep -qi "apple"; then
        echo "Apple device (iPhone/iPad/MacBook/AirPods)"
    elif echo "$vendor" | grep -qi "samsung"; then
        echo "Samsung device (Galaxy phone/Smart TV/tablet)"
    elif echo "$vendor" | grep -qi "google"; then
        echo "Google device (Pixel/Chromecast/Nest)"
    elif echo "$vendor" | grep -qi "roku"; then
        echo "Roku streaming device"
    elif echo "$vendor" | grep -qi "sonos"; then
        echo "Sonos speaker"
    elif echo "$vendor" | grep -qi "ring"; then
        echo "Ring security device (doorbell/camera)"
    elif echo "$vendor" | grep -qi "nest"; then
        echo "Google Nest device (thermostat/camera/Hub)"
    elif echo "$vendor" | grep -qi "ecobee"; then
        echo "Ecobee smart thermostat"
    elif echo "$vendor" | grep -qi "philips\|signify"; then
        echo "Philips Hue smart lighting"
    elif echo "$vendor" | grep -qi "tp-link\|tplink"; then
        echo "TP-Link device (router/smart home)"
    elif echo "$vendor" | grep -qi "belkin"; then
        echo "Belkin device (router/WeMo smart home)"
    elif echo "$vendor" | grep -qi "wyze"; then
        echo "Wyze smart home device (camera/bulb/plug)"
    elif echo "$vendor" | grep -qi "eufy"; then
        echo "Eufy security device (camera/doorbell)"
    elif echo "$vendor" | grep -qi "arlo"; then
        echo "Arlo security camera"
    elif echo "$vendor" | grep -qi "bose"; then
        echo "Bose audio device"
    elif echo "$vendor" | grep -qi "sony"; then
        echo "Sony device (TV/PlayStation/headphones)"
    elif echo "$vendor" | grep -qi "microsoft"; then
        echo "Microsoft device (Surface/Xbox/laptop)"
    elif echo "$vendor" | grep -qi "nintendo"; then
        echo "Nintendo device (Switch/gaming)"
    elif echo "$vendor" | grep -qi "xiaomi"; then
        echo "Xiaomi device (phone/smart home)"
    elif echo "$vendor" | grep -qi "huawei"; then
        echo "Huawei device (phone/router)"
    elif echo "$vendor" | grep -qi "texas"; then
        echo "IoT/Smart Home device (Texas Instruments chip)"
    elif echo "$vendor" | grep -qi "motorola"; then
        echo "Motorola device (phone)"
    elif echo "$vendor" | grep -qi "lenovo"; then
        echo "Lenovo device (laptop/tablet/phone)"
    elif echo "$vendor" | grep -qi "dell"; then
        echo "Dell device (laptop/desktop)"
    elif echo "$vendor" | grep -qi "hewlett\|hp inc"; then
        echo "HP device (laptop/printer)"
    elif echo "$vendor" | grep -qi "cisco"; then
        echo "Cisco device (enterprise networking)"
    elif echo "$vendor" | grep -qi "aruba"; then
        echo "Aruba device (enterprise networking)"
    elif echo "$vendor" | grep -qi "ubiquiti"; then
        echo "Ubiquiti device (networking)"
    elif echo "$vendor" | grep -qi "espressif"; then
        echo "ESP32/ESP8266 IoT device (DIY/smart home)"
    elif echo "$vendor" | grep -qi "raspberry"; then
        echo "Raspberry Pi device"
    elif echo "$vendor" | grep -qi "hon hai\|foxconn"; then
        echo "Foxconn-built device (Amazon Echo/Fire TV, Nintendo Switch, Sony PlayStation, Vizio TV)"
    elif echo "$vendor" | grep -qi "tonly"; then
        echo "Tonly Technology device (Bluetooth speaker, soundbar, or TCL audio product)"
    elif echo "$vendor" | grep -qi "altobeam"; then
        echo "AltoBeam device (Smart TV, streaming box, or Android TV device)"
    fi
}

_classify_network() {
    local ssid_lower ap_lower
    ssid_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    ap_lower=$(echo "$2" | tr '[:upper:]' '[:lower:]')

    if echo "$ap_lower" | grep -qi "cisco\|aruba\|meraki\|ruckus\|aerohive\|fortinet\|juniper"; then
        echo "Business/Enterprise (enterprise-grade access point)"
    elif echo "$ssid_lower" | grep -qi "corp\|office\|guest\|employee\|staff\|hotel\|cafe\|shop\|store\|restaurant\|bar\|inc\|llc\|ltd"; then
        echo "Likely Business/Public network"
    elif echo "$ssid_lower" | grep -qi "verizon_\|xfinity\|spectrum\|att\|optimum\|cox\|myspectrumwifi\|myfiosgateway"; then
        echo "Home/Personal network (ISP-issued gateway)"
    elif echo "$ap_lower" | grep -qi "netgear\|linksys\|tp-link\|asus\|belkin\|d-link\|xfinity\|spectrum\|att\|verizon\|comcast\|cox\|google\|eero\|orbi\|synology\|ubiquiti\|unifi\|askey\|sagemcom\|arris\|technicolor\|sercomm"; then
        echo "Home/Personal network (consumer router)"
    else
        echo "Unknown network type"
    fi
}

CLIENT_DEVICE_HINT=$(_classify_device "$CLIENT_VENDOR")
echo "DEBUG: CLIENT_VENDOR='$CLIENT_VENDOR' HINT='$CLIENT_DEVICE_HINT'" >> /root/loot/handshakes/debug.txt
NETWORK_TYPE=$(_classify_network "$SSID" "$AP_VENDOR")

# ============================================================================
# DETERMINE HANDSHAKE TYPE AND QUALITY
# ============================================================================

HANDSHAKE_TYPE="$_ALERT_HANDSHAKE_TYPE"
SUMMARY="$_ALERT_HANDSHAKE_SUMMARY"
TYPE_LABEL=""
QUALITY_LABEL=""
CRACK_STATUS=""

if [ "$HANDSHAKE_TYPE" = "eapol" ]; then
    TYPE_LABEL="EAPOL"

    if [ "$_ALERT_HANDSHAKE_COMPLETE" = "true" ]; then
        QUALITY_LABEL="COMPLETE"
    else
        QUALITY_LABEL="PARTIAL"
    fi

    if [ "$_ALERT_HANDSHAKE_CRACKABLE" = "true" ]; then
        CRACK_STATUS="CRACKABLE"
    else
        CRACK_STATUS="NOT CRACKABLE"
    fi

elif [ "$HANDSHAKE_TYPE" = "pmkid" ]; then
    TYPE_LABEL="PMKID"
    QUALITY_LABEL="SINGLE PACKET"
    CRACK_STATUS="CRACKABLE"
else
    if echo "$SUMMARY" | grep -qi "pmkid"; then
        HANDSHAKE_TYPE="pmkid"
        TYPE_LABEL="PMKID"
        QUALITY_LABEL="SINGLE PACKET"
    elif echo "$SUMMARY" | grep -q '\[.*[1-4]'; then
        HANDSHAKE_TYPE="eapol"
        TYPE_LABEL="EAPOL"
        if echo "$SUMMARY" | grep -q '\[.*1.*2.*3.*4'; then
            QUALITY_LABEL="COMPLETE"
        else
            QUALITY_LABEL="PARTIAL"
        fi
    else
        TYPE_LABEL="UNKNOWN"
        QUALITY_LABEL="UNKNOWN"
    fi

    if echo "$SUMMARY" | grep -qi "crackable"; then
        CRACK_STATUS="CRACKABLE"
    elif echo "$SUMMARY" | grep -qi "not crackable\|uncrackable"; then
        CRACK_STATUS="NOT CRACKABLE"
    else
        CRACK_STATUS="UNKNOWN"
    fi
fi

# ============================================================================
# AUTO-RENAME PCAP
# ============================================================================

RENAMED_PCAP=""
if [ "$ENABLE_AUTO_RENAME" = true ] && [ -f "$PCAP" ]; then
    SAFE_SSID=$(echo "$SSID" | sed 's/[^a-zA-Z0-9_-]/_/g' | tr -s '_')
    SAFE_MAC=$(echo "$_ALERT_HANDSHAKE_AP_MAC_ADDRESS" | tr ':' '-')
    FILE_TS=$(date '+%Y%m%d_%H%M%S')
    NEW_NAME="${SAFE_SSID}_${SAFE_MAC}_${FILE_TS}.pcap"
    PCAP_DIR=$(dirname "$PCAP")
    NEW_PATH="${PCAP_DIR}/${NEW_NAME}"

    if cp "$PCAP" "$NEW_PATH" 2>/dev/null; then
        RENAMED_PCAP="$NEW_PATH"
        LOG "AUTO-RENAME: Copied to $NEW_NAME"
    fi
fi

# ============================================================================
# VISUAL AND TACTILE FEEDBACK
# ============================================================================

LED_ARGS=""
if [ "$DUPLICATE" = true ]; then
    VIBRATE 50
    LED W SOLID
    LED_ARGS="W SOLID"
else
    if [ "$HANDSHAKE_TYPE" = "eapol" ]; then
        if [ "$_ALERT_HANDSHAKE_COMPLETE" = "true" ] && [ "$_ALERT_HANDSHAKE_CRACKABLE" = "true" ]; then
            VIBRATE 200 100 200 100 200
            LED G SUCCESS
            LED_ARGS="G SUCCESS"
        elif [ "$_ALERT_HANDSHAKE_COMPLETE" = "true" ]; then
            VIBRATE 200 100 200
            LED C SOLID
            LED_ARGS="C SOLID"
        else
            VIBRATE 150 100 150
            LED Y SLOW
            LED_ARGS="Y SLOW"
        fi
    elif [ "$HANDSHAKE_TYPE" = "pmkid" ]; then
        VIBRATE 300
        LED M SOLID
        LED_ARGS="M SOLID"
    else
        VIBRATE 100
        LED Y FAST
        LED_ARGS="Y FAST"
    fi
fi

# ============================================================================
# ALERT
# ============================================================================

DUP_TAG=""
[ "$DUPLICATE" = true ] && DUP_TAG=" [DUP]"

ALERT_MSG="Capture #${CAPTURE_COUNT}${DUP_TAG}: $SSID
$TYPE_LABEL ($QUALITY_LABEL) - $CRACK_STATUS
Signal: $RSSI
AP: $_ALERT_HANDSHAKE_AP_MAC_ADDRESS ($AP_VENDOR)
Client: $_ALERT_HANDSHAKE_CLIENT_MAC_ADDRESS ($CLIENT_VENDOR)${CLIENT_DEVICE_HINT:+
Hint: $CLIENT_DEVICE_HINT}"

ALERT "$ALERT_MSG"
[ -n "$LED_ARGS" ] && LED $LED_ARGS

# ============================================================================
# LOGGING
# ============================================================================

TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

mkdir -p "$(dirname "$LOG_FILE")"

cat >> "$LOG_FILE" << EOF
================================================================================
CAPTURE #${CAPTURE_COUNT}: $TIMESTAMP$([ "$DUPLICATE" = true ] && echo " [DUPLICATE]")
================================================================================
SSID:           $SSID
Type:           $HANDSHAKE_TYPE ($TYPE_LABEL)
Quality:        $QUALITY_LABEL
Crackable:      $CRACK_STATUS
Signal:         $RSSI
Channel:        $CHANNEL

AP MAC:         $_ALERT_HANDSHAKE_AP_MAC_ADDRESS
AP Vendor:      $AP_VENDOR

Client MAC:     $_ALERT_HANDSHAKE_CLIENT_MAC_ADDRESS
Client Vendor:  $CLIENT_VENDOR

PCAP File:      ${RENAMED_PCAP:-$_ALERT_HANDSHAKE_PCAP_PATH}
Hashcat File:   $_ALERT_HANDSHAKE_HASHCAT_PATH (${HASH_STATUS})
${GPS_DATA:+GPS Location:   ${GPS_INFO:-No GPS}}

Network Type:   $NETWORK_TYPE
${CLIENT_DEVICE_HINT:+Device Hint:    $CLIENT_DEVICE_HINT}

Summary:        $_ALERT_HANDSHAKE_SUMMARY

Latest Handshake: "$SSID" ($TYPE_LABEL - $CRACK_STATUS) from $_ALERT_HANDSHAKE_AP_MAC_ADDRESS captured on $TIMESTAMP
================================================================================

EOF

LOG "HANDSHAKE #${CAPTURE_COUNT}: $SSID ($_ALERT_HANDSHAKE_AP_MAC_ADDRESS) - $TYPE_LABEL - $CRACK_STATUS - Ch:$CHANNEL $RSSI$([ "$DUPLICATE" = true ] && echo ' [DUP]')"

# ============================================================================
# STATISTICS
# ============================================================================

STATS_FILE="/root/loot/handshakes/statistics.txt"

TOTAL_HANDSHAKES=$(find /root/loot/handshakes -type f -name "*.22000" 2>/dev/null | wc -l)
TOTAL_PCAPS=$(find /root/loot/handshakes -type f -name "*.pcap" 2>/dev/null | wc -l)

EAPOL_COUNT=$(grep -c "Type:.*eapol" "$LOG_FILE" 2>/dev/null); EAPOL_COUNT=${EAPOL_COUNT:-0}
PMKID_COUNT=$(grep -c "Type:.*pmkid" "$LOG_FILE" 2>/dev/null); PMKID_COUNT=${PMKID_COUNT:-0}
CRACKABLE_COUNT=$(grep -c "Crackable:.*CRACKABLE" "$LOG_FILE" 2>/dev/null); CRACKABLE_COUNT=${CRACKABLE_COUNT:-0}

cat > "$STATS_FILE" << EOF
WiFi Pineapple Pager - Handshake Capture Statistics
Last Updated: $TIMESTAMP
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Total Captures:      $TOTAL_HANDSHAKES
Total PCAPs:         $TOTAL_PCAPS

Capture Types:
  - EAPOL:           $EAPOL_COUNT
  - PMKID:           $PMKID_COUNT

Crackable:           $CRACKABLE_COUNT

Unique AP+Client Pairs: $(cut -d'|' -f1,2 "$CAPTURE_HISTORY" 2>/dev/null | sort -u | wc -l | tr -d ' ')
Duplicates:          $(grep -c "\[DUPLICATE\]" "$LOG_FILE" 2>/dev/null || echo 0)

Most Recent:
  SSID:              $SSID
  AP MAC:            $_ALERT_HANDSHAKE_AP_MAC_ADDRESS
  Type:              $TYPE_LABEL
  Signal:            $RSSI
  Channel:           $CHANNEL
  Status:            $CRACK_STATUS
  Hash File:         $HASH_STATUS
EOF

# ============================================================================
# COMPLETION
# ============================================================================

[ -n "$RESTORE_LED" ] && LED $RESTORE_LED

exit 0
