#!/bin/bash
# Title: Device Profiler
# Description: Profile connected devices via OUI lookup, detect randomized MACs, track unique clients with CSV/JSON logging
# Author: z3r0l1nk
# Version: 2.1

# Configuration
DATA_DIR="/root/loot/device_profiler"
OUI_DB="/tmp/oui_cache.txt"
DEVICE_LOG="$DATA_DIR/connections.csv"
DEVICE_JSON="$DATA_DIR/connections.json"
SEEN_DB="$DATA_DIR/seen_clients.txt"
QUIET_MODE=false  # Set to true to only alert on new clients

# Initialize data directory and files
mkdir -p "$DATA_DIR"
if [ ! -f "$DEVICE_LOG" ]; then
    echo "timestamp,client_mac,client_vendor,ap_mac,ap_vendor,ssid,is_new" > "$DEVICE_LOG"
fi
if [ ! -f "$DEVICE_JSON" ]; then
    echo '[]' > "$DEVICE_JSON"
fi
if [ ! -f "$SEEN_DB" ]; then
    touch "$SEEN_DB"
fi

# Detect Locally Administered Address (LAA) - randomized MACs
# Bit 1 of first octet set = locally administered (randomized)
is_random_mac() {
    local mac=$(echo "$1" | tr '[:lower:]' '[:upper:]' | sed 's/[:-]//g')
    local first_octet=$((16#${mac:0:2}))
    (( first_octet & 2 ))
}

# Function to extract OUI from MAC address
get_oui() {
    echo "$1" | tr '[:lower:]' '[:upper:]' | sed 's/[:-]//g' | cut -c1-6
}

# Function to lookup vendor
lookup_vendor() {
    local oui=$(get_oui "$1")
    if [ -f "$OUI_DB" ] && grep -q "^$oui" "$OUI_DB" 2>/dev/null; then
        grep "^$oui" "$OUI_DB" | cut -d'|' -f2 | head -1
    else
        case "$oui" in
            # ---- Virtualization ----
            "000C29"|"005056"|"000569") echo "VMware" ;;
            "001C42"|"000D93") echo "Parallels" ;;
            "080027") echo "VirtualBox" ;;
            "525400") echo "QEMU / KVM" ;;
            "00163E") echo "Xen" ;;
            "00155D") echo "Microsoft Hyper-V" ;;
            "001C14") echo "Microsoft" ;;

            # ---- Apple ----
            "3C22FB"|"A45E60"|"DC2B2A"|"F4F5D8"|"BC926B") echo "Apple" ;;

            # ---- Samsung ----
            "F8E079"|"ACDE48"|"A4C639"|"002454") echo "Samsung" ;;

            # ---- Google ----
            "B4E62D"|"94E979"|"40F520"|"F4F5A5") echo "Google" ;;

            # ---- Intel ----
            "2C6E85"|"F0D5BF"|"3C6A9D"|"1C697A") echo "Intel" ;;

            # ---- Broadcom ----
            "001018"|"18C04D"|"B827EB") echo "Broadcom" ;;

            # ---- Qualcomm ----
            "001374"|"F4F5E8") echo "Qualcomm" ;;

            # ---- Huawei ----
            "FC4463"|"981DFA"|"00259E") echo "Huawei" ;;

            # ---- TP-Link ----
            "EC086B"|"B0487A"|"C4E984") echo "TP-Link" ;;

            # ---- Ubiquiti ----
            "68D79A"|"24A43C"|"80A2A4") echo "Ubiquiti" ;;

            # ---- MikroTik ----
            "4C5E0C"|"64D1A3") echo "MikroTik" ;;

            # ---- Cisco ----
            "001B54"|"0023EB"|"5475D0") echo "Cisco" ;;

            # ---- Dell ----
            "F8BC12"|"D4AE52"|"B83FD2") echo "Dell" ;;

            # ---- HP ----
            "3C52A1"|"B4B686"|"F4CE46") echo "HP" ;;

            # ---- Lenovo ----
            "9C2A70"|"00259E"|"F81EDF") echo "Lenovo" ;;

            # ---- Sony ----
            "A8E539"|"0016FE") echo "Sony" ;;

            # ---- Amazon / Echo / Ring ----
            "44D9E7"|"50F5DA"|"747548") echo "Amazon" ;;

            # ---- Raspberry Pi ----
            "B827EB"|"DC:A6:32") echo "Raspberry Pi" ;;

            # ---- Espressif (ESP32 / ESP8266) ----
            "24DC4F"|"7C9EBD"|"84F3EB") echo "Espressif" ;;

            # ---- Realtek ----
            "001E10"|"5254AB"|"E04F43") echo "Realtek" ;;

            *) echo "Unknown" ;;
        esac
    fi
}

# Identify device type based on vendor
get_device_type() {
    local vendor=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    case "$vendor" in
        # ---- Virtualization / Emulation ----
        *vmware*|*virtualbox*|*parallels*|*qemu*|*kvm*|*xen*|*hyper-v*|*microsoft*)
            echo "🖥️ Virtual Machine"
            ;;

        # ---- Phones / Tablets ----
        *apple*)
            echo "📱 Apple iPhone / Mac / iPad"
            ;;
        *samsung*)
            echo "📱 Samsung Device"
            ;;
        *google*)
            echo "📱 Google Pixel / Android"
            ;;
        *huawei*)
            echo "📱 Huawei Device"
            ;;
        *sony*)
            echo "📱 Sony Mobile"
            ;;

        # ---- PCs / Laptops ----
        *intel*|*dell*|*hp*|*lenovo*)
            echo "💻 PC / Laptop"
            ;;

        # ---- Networking Gear ----
        *cisco*|*ubiquiti*|*mikrotik*|*tp-link*)
            echo "🌐 Network Equipment"
            ;;

        # ---- SBC / Makers ----
        *raspberry*)
            echo "🥧 Raspberry Pi"
            ;;
        *espressif*)
            echo "🔌 IoT / ESP Device"
            ;;

        # ---- Chipset Vendors (Wi-Fi / Ethernet) ----
        *broadcom*|*realtek*|*qualcomm*)
            echo "📡 Network Adapter"
            ;;

        # ---- Smart Home / Consumer IoT ----
        *amazon*)
            echo "🏠 Smart Home / Amazon Device"
            ;;

        *)  echo "❓ Unknown Device" ;;
    esac
}


# Check for randomized MAC first, then fall back to OUI lookup
if is_random_mac "$_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS"; then
    CLIENT_VENDOR="Randomized MAC"
    DEVICE_TYPE="📱 Mobile Device (Randomized MAC)"
else
    CLIENT_VENDOR=$(lookup_vendor "$_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS")
    DEVICE_TYPE=$(get_device_type "$CLIENT_VENDOR")
fi

AP_VENDOR=$(lookup_vendor "$_ALERT_CLIENT_CONNECTED_AP_MAC_ADDRESS")
TIMESTAMP=$(date -Iseconds)

# Normalize MAC for deduplication
normalize_mac() {
    echo "$1" | tr '[:lower:]' '[:upper:]' | sed 's/[:-]//g'
}

CLIENT_MAC_NORM=$(normalize_mac "$_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS")

# Check if this is a new or returning client
if grep -q "^$CLIENT_MAC_NORM$" "$SEEN_DB" 2>/dev/null; then
    IS_NEW=false
    IS_NEW_LABEL="returning"
else
    IS_NEW=true
    IS_NEW_LABEL="new"
    echo "$CLIENT_MAC_NORM" >> "$SEEN_DB"
fi

# Count unique clients
UNIQUE_CLIENTS=$(wc -l < "$SEEN_DB" | tr -d ' ')

# Log the connection (CSV)
echo "$TIMESTAMP,$_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS,$CLIENT_VENDOR,$_ALERT_CLIENT_CONNECTED_AP_MAC_ADDRESS,$AP_VENDOR,$_ALERT_CLIENT_CONNECTED_SSID,$IS_NEW_LABEL" >> "$DEVICE_LOG"

# Log the connection (JSON)
json_escape() {
    echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

JSON_ENTRY=$(cat <<EOF
{
  "timestamp": "$TIMESTAMP",
  "client_mac": "$(json_escape "$_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS")",
  "client_vendor": "$(json_escape "$CLIENT_VENDOR")",
  "device_type": "$(json_escape "$DEVICE_TYPE")",
  "ap_mac": "$(json_escape "$_ALERT_CLIENT_CONNECTED_AP_MAC_ADDRESS")",
  "ap_vendor": "$(json_escape "$AP_VENDOR")",
  "ssid": "$(json_escape "$_ALERT_CLIENT_CONNECTED_SSID")",
  "is_new": $IS_NEW,
  "unique_clients": $UNIQUE_CLIENTS
}
EOF
)

# Append to JSON array
if [ "$(cat "$DEVICE_JSON")" = "[]" ]; then
    echo "[$JSON_ENTRY]" > "$DEVICE_JSON"
else
    sed -i 's/]$/,/' "$DEVICE_JSON"
    echo "$JSON_ENTRY]" >> "$DEVICE_JSON"
fi

# Build alert based on new/returning status
if [ "$IS_NEW" = true ]; then
    ALERT_MSG="🆕 $DEVICE_TYPE CONNECTED
Client: $_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS
Vendor: $CLIENT_VENDOR
SSID: $_ALERT_CLIENT_CONNECTED_SSID
AP Vendor: $AP_VENDOR
Status: NEW CLIENT
Unique clients: $UNIQUE_CLIENTS"
    ALERT "$ALERT_MSG"
elif [ "$QUIET_MODE" = false ]; then
    ALERT_MSG="$DEVICE_TYPE CONNECTED
Client: $_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS
Vendor: $CLIENT_VENDOR
SSID: $_ALERT_CLIENT_CONNECTED_SSID
Status: Returning client
Unique clients: $UNIQUE_CLIENTS"
    ALERT "$ALERT_MSG"
fi
