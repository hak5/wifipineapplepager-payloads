#!/bin/bash
# Title: MAC Spoofer
# Author: Brandon Starkweather
# Description: MAC Spoofer for blending with specific environments.

# --- 1. WORKFLOW BRIEFING ---
PROMPT "MAC SPOOFER

This payload changes your
digital identity to match
specific environments.

Steps:
1. Select Interface
2. Select Environment
3. Select Profile
4. Apply & Verify

Press OK to Begin."

# --- 2. SMART INTERFACE SELECTION ---
ALL_IFS=$(ls /sys/class/net | grep -v lo)
SORTED_LIST=""

# Priority Check
for iface in wlan0cli wlan0 wlan1mon wlan1 eth0; do
    if echo "$ALL_IFS" | grep -q "$iface"; then
        SORTED_LIST="$SORTED_LIST $iface"
    fi
done

# Add remaining interfaces
for iface in $ALL_IFS; do
    if ! echo "$SORTED_LIST" | grep -q "$iface"; then
        SORTED_LIST="$SORTED_LIST $iface"
    fi
done

IFACE_ARRAY=($SORTED_LIST)

INTERFACE=$(LIST_PICKER "Select Interface" "${IFACE_ARRAY[@]}" "${IFACE_ARRAY[0]}")
if [ -z "$INTERFACE" ]; then exit 0; fi

# --- 3. TRUE HARDWARE BACKUP ---
BACKUP_MAC="/tmp/original_mac_${INTERFACE}"
BACKUP_HOST="/tmp/original_host"

# Function to get the REAL hardware address
get_factory_mac() {
    local iface=$1
    local perm_mac=""

    # Method 1: ethtool (Best for physical hardware)
    if command -v ethtool &>/dev/null; then
        perm_mac=$(ethtool -P "$iface" 2>/dev/null | awk '/Permanent address/ {print $3}')
    fi

    # Method 2: iw phy (Best for wireless)
    if [[ -z "$perm_mac" || "$perm_mac" == "00:00:00:00:00:00" ]] && command -v iw &>/dev/null; then
        local phy=$(iw dev "$iface" info 2>/dev/null | grep wiphy | awk '{print $2}')
        if [ -n "$phy" ]; then
            perm_mac=$(iw phy "phy$phy" info 2>/dev/null | grep "Perm addr" | awk '{print $3}')
        fi
    fi

    # Method 3: Fallback to current address
    if [[ -z "$perm_mac" || "$perm_mac" == "00:00:00:00:00:00" ]]; then
        perm_mac=$(cat /sys/class/net/$iface/address)
    fi

    echo "$perm_mac"
}

if [ ! -f "$BACKUP_MAC" ]; then
    REAL_MAC=$(get_factory_mac "$INTERFACE")
    echo "$REAL_MAC" > "$BACKUP_MAC"
    CURRENT_HOST=$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname)
    echo "$CURRENT_HOST" > "$BACKUP_HOST"
fi

ORIG_MAC=$(cat "$BACKUP_MAC")
ORIG_HOST=$(cat "$BACKUP_HOST")

gen_suffix() {
    awk 'BEGIN{srand(); for(i=0;i<3;i++) printf ":%02X", int(rand()*256)}'
}

# --- 4. CATEGORY SELECTION ---
CAT_NAME=$(LIST_PICKER "Select Env ($INTERFACE)" \
    "Restore Original" \
    "Home (Wireless)" \
    "Corporate (Wireless)" \
    "Commercial (Wireless)" \
    "Industrial (Wireless)" \
    "Ethernet (Wired)" \
    "Home (Wireless)")
if [ -z "$CAT_NAME" ]; then exit 0; fi

# --- 5. PROFILE SELECTION ---
NEW_OUI=""

case "$CAT_NAME" in
    "Restore Original")
        NEW_MAC="$ORIG_MAC"
        NEW_NAME="$ORIG_HOST"
        CAT_NAME="Factory"
        ;;

    "Home (Wireless)")
        PROF=$(LIST_PICKER "Home Profiles" \
            "Apple iPhone 15" \
            "Samsung Smart TV" \
            "Amazon Echo Dot" \
            "Sony PlayStation 5" \
            "Apple iPhone 15")
        case "$PROF" in
            "Apple iPhone 15")    NEW_OUI="F0:99:B6"; NEW_NAME="iPhone-15"; TYPE="Mobile" ;;
            "Samsung Smart TV")   NEW_OUI="84:C0:EF"; NEW_NAME="Samsung-TV-QLED"; TYPE="SmartTV" ;;
            "Amazon Echo Dot")    NEW_OUI="FC:D7:49"; NEW_NAME="Echo-Dot-LivingRoom"; TYPE="IoT" ;;
            "Sony PlayStation 5") NEW_OUI="00:D9:D1"; NEW_NAME="PS5-Console"; TYPE="Console" ;;
            *) exit 0 ;;
        esac
        ;;

    "Corporate (Wireless)")
        PROF=$(LIST_PICKER "Corporate Profiles" \
            "HP LaserJet Pro" \
            "Cisco IP Phone" \
            "Polycom Conf Phone" \
            "Dell Latitude Laptop" \
            "HP LaserJet Pro")
        case "$PROF" in
            "HP LaserJet Pro")      NEW_OUI="00:21:5A"; NEW_NAME="HP-LaserJet-M404"; TYPE="Printer" ;;
            "Cisco IP Phone")       NEW_OUI="00:08:2F"; NEW_NAME="SEP-Cisco-8845"; TYPE="VoIP" ;;
            "Polycom Conf Phone")   NEW_OUI="00:04:F2"; NEW_NAME="Polycom-Trio-8800"; TYPE="VoIP" ;;
            "Dell Latitude Laptop") NEW_OUI="F8:BC:12"; NEW_NAME="DESKTOP-DELL-5420"; TYPE="Laptop" ;;
            *) exit 0 ;;
        esac
        ;;

    "Commercial (Wireless)")
        PROF=$(LIST_PICKER "Commercial Profiles" \
            "Zebra Barcode Scanner" \
            "Verifone POS Terminal" \
            "Ingenico Card Reader" \
            "Axis Security Camera" \
            "Zebra Barcode Scanner")
        case "$PROF" in
            "Zebra Barcode Scanner") NEW_OUI="00:A0:F8"; NEW_NAME="Zebra-TC52-Scanner"; TYPE="Scanner" ;;
            "Verifone POS Terminal") NEW_OUI="00:0B:4F"; NEW_NAME="Verifone-VX520"; TYPE="POS" ;;
            "Ingenico Card Reader")  NEW_OUI="00:03:81"; NEW_NAME="Ingenico-iSC250"; TYPE="POS" ;;
            "Axis Security Camera")  NEW_OUI="AC:CC:8E"; NEW_NAME="Axis-M30-Cam"; TYPE="Camera" ;;
            *) exit 0 ;;
        esac
        ;;

    "Industrial (Wireless)")
        PROF=$(LIST_PICKER "Industrial Profiles" \
            "Siemens Simatic PLC" \
            "Rockwell Automation" \
            "Honeywell Controller" \
            "Schneider Electric" \
            "Siemens Simatic PLC")
        case "$PROF" in
            "Siemens Simatic PLC")  NEW_OUI="00:1C:06"; NEW_NAME="Siemens-S7-1200"; TYPE="PLC" ;;
            "Rockwell Automation")  NEW_OUI="00:00:BC"; NEW_NAME="Allen-Bradley-PLC"; TYPE="PLC" ;;
            "Honeywell Controller") NEW_OUI="00:30:AF"; NEW_NAME="Honeywell-HVAC-Ctl"; TYPE="HVAC" ;;
            "Schneider Electric")   NEW_OUI="00:00:54"; NEW_NAME="Schneider-Modicon"; TYPE="PLC" ;;
            *) exit 0 ;;
        esac
        ;;

    "Ethernet (Wired)")
        PROF=$(LIST_PICKER "Wired Profiles" \
            "MSI Gaming Desktop" \
            "Cisco Desk Phone" \
            "Verifone POS" \
            "Moxa NPort Gateway" \
            "MSI Gaming Desktop")
        case "$PROF" in
            "MSI Gaming Desktop") NEW_OUI="D8:CB:8A"; NEW_NAME="MSI-Gaming-Desktop"; TYPE="PC" ;;
            "Cisco Desk Phone")   NEW_OUI="00:08:2F"; NEW_NAME="Cisco-IP-Phone"; TYPE="VoIP" ;;
            "Verifone POS")       NEW_OUI="00:0B:4F"; NEW_NAME="Verifone-VX520-Eth"; TYPE="POS" ;;
            "Moxa NPort Gateway") NEW_OUI="00:90:E8"; NEW_NAME="Moxa-NPort-5110"; TYPE="Gateway" ;;
            *) exit 0 ;;
        esac
        ;;

    *)
        exit 0
        ;;
esac

if [ -n "$NEW_OUI" ]; then
    SUFFIX=$(gen_suffix)
    NEW_MAC="${NEW_OUI}${SUFFIX}"
fi

# --- 6. CONFIRMATION ---
PROMPT "CONFIRM SPOOF

Iface: $INTERFACE
Target: $NEW_NAME
MAC: $NEW_MAC

Press OK to Apply."

# --- 7. EXECUTION ---
LOG blue "=== APPLYING IDENTITY ==="

ifconfig "$INTERFACE" down
if [ $? -ne 0 ]; then
    LOG red "FAIL: Interface busy"
    exit 1
fi
LOG yellow "Interface DOWN"

ifconfig "$INTERFACE" hw ether "$NEW_MAC"
if [ $? -eq 0 ]; then
    LOG green "MAC Set: $NEW_MAC"
else
    LOG red "FAIL: MAC Change Error"
    ifconfig "$INTERFACE" up
    exit 1
fi

hostname "$NEW_NAME" 2>/dev/null
echo "$NEW_NAME" > /proc/sys/kernel/hostname 2>/dev/null
LOG green "Host Set: $NEW_NAME"

ifconfig "$INTERFACE" up
LOG yellow "Interface UP"

sleep 2

# --- 8. VERIFICATION ---
FINAL_MAC=$(cat /sys/class/net/$INTERFACE/address)
FINAL_HOST=$(cat /proc/sys/kernel/hostname 2>/dev/null)
if [ -z "$FINAL_HOST" ]; then FINAL_HOST=$(hostname); fi

LOG blue "=== IDENTITY VERIFIED ==="
LOG "MAC: $FINAL_MAC"
LOG "Host: $FINAL_HOST"
LOG "---"
LOG green "SUCCESS"

sleep 5
exit 0
