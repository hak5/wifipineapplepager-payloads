#!/bin/bash
# Title: MAC Spoofer
# Author: Brandon Starkweather
# Description: MAC Spoofer for blending with specific environments.
# Version: 1.0

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

LIST_STR=""
count=1
for i in "${IFACE_ARRAY[@]}"; do
    LIST_STR="${LIST_STR}${count}: ${i}
"
    count=$((count + 1))
done

PROMPT "SELECT INTERFACE
(Sorted by Utility)

$LIST_STR

Press OK."

IF_ID=$(NUMBER_PICKER "Enter Interface ID:" 1)
if [ -z "$IF_ID" ]; then exit 0; fi

IDX=$((IF_ID - 1))
INTERFACE="${IFACE_ARRAY[$IDX]}"

if [ -z "$INTERFACE" ]; then
    PROMPT "Invalid Selection."
    exit 1
fi

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
PROMPT "SELECT ENV ($INTERFACE)

0. Restore Original
1. Home (Wireless)
2. Corporate (Wireless)
3. Commercial (Wireless)
4. Industrial (Wireless)
5. Ethernet (Wired Mix)

Press OK."

CAT_ID=$(NUMBER_PICKER "Select Category" 1)
if [ -z "$CAT_ID" ]; then exit 0; fi

# --- 5. PROFILE SELECTION ---

if [ "$CAT_ID" -eq 0 ]; then
    NEW_MAC="$ORIG_MAC"
    NEW_NAME="$ORIG_HOST"
    CAT_NAME="Factory"
    NEW_OUI="" 
    
else
    case "$CAT_ID" in
        1) CAT_NAME="Home" ;;
        2) CAT_NAME="Corporate" ;;
        3) CAT_NAME="Commercial" ;;
        4) CAT_NAME="Industrial" ;;
        5) CAT_NAME="Ethernet" ;;
    esac

    case "$CAT_ID" in
        1)
            # === HOME ===
            PROMPT "HOME PROFILES
            
1. Apple iPhone 15
2. Samsung Smart TV
3. Amazon Echo Dot
4. Sony PlayStation 5

Press OK."
            PROF_ID=$(NUMBER_PICKER "Select Device" 1)
            
            if [ "$PROF_ID" -eq 1 ]; then
                NEW_OUI="F0:99:B6"; NEW_NAME="iPhone-15"; TYPE="Mobile"
            elif [ "$PROF_ID" -eq 2 ]; then
                NEW_OUI="84:C0:EF"; NEW_NAME="Samsung-TV-QLED"; TYPE="SmartTV"
            elif [ "$PROF_ID" -eq 3 ]; then
                # UPDATED: Amazon Technologies Inc.
                NEW_OUI="FC:D7:49"; NEW_NAME="Echo-Dot-LivingRoom"; TYPE="IoT"
            elif [ "$PROF_ID" -eq 4 ]; then
                NEW_OUI="00:D9:D1"; NEW_NAME="PS5-Console"; TYPE="Console"
            else exit 0; fi
            ;;

        2)
            # === CORPORATE ===
            PROMPT "CORPORATE PROFILES
            
1. HP LaserJet Pro
2. Cisco IP Phone
3. Polycom Conf Phone
4. Dell Latitude Laptop

Press OK."
            PROF_ID=$(NUMBER_PICKER "Select Device" 1)
            
            if [ "$PROF_ID" -eq 1 ]; then
                NEW_OUI="00:21:5A"; NEW_NAME="HP-LaserJet-M404"; TYPE="Printer"
            elif [ "$PROF_ID" -eq 2 ]; then
                NEW_OUI="00:08:2F"; NEW_NAME="SEP-Cisco-8845"; TYPE="VoIP"
            elif [ "$PROF_ID" -eq 3 ]; then
                NEW_OUI="00:04:F2"; NEW_NAME="Polycom-Trio-8800"; TYPE="VoIP"
            elif [ "$PROF_ID" -eq 4 ]; then
                NEW_OUI="F8:BC:12"; NEW_NAME="DESKTOP-DELL-5420"; TYPE="Laptop"
            else exit 0; fi
            ;;

        3)
            # === COMMERCIAL ===
            PROMPT "COMMERCIAL PROFILES
            
1. Zebra Barcode Scanner
2. Verifone POS Terminal
3. Ingenico Card Reader
4. Axis Security Camera

Press OK."
            PROF_ID=$(NUMBER_PICKER "Select Device" 1)
            
            if [ "$PROF_ID" -eq 1 ]; then
                NEW_OUI="00:A0:F8"; NEW_NAME="Zebra-TC52-Scanner"; TYPE="Scanner"
            elif [ "$PROF_ID" -eq 2 ]; then
                # UPDATED: Verifone, Inc.
                NEW_OUI="00:0B:4F"; NEW_NAME="Verifone-VX520"; TYPE="POS"
            elif [ "$PROF_ID" -eq 3 ]; then
                # UPDATED: Ingenico International
                NEW_OUI="00:03:81"; NEW_NAME="Ingenico-iSC250"; TYPE="POS"
            elif [ "$PROF_ID" -eq 4 ]; then
                NEW_OUI="AC:CC:8E"; NEW_NAME="Axis-M30-Cam"; TYPE="Camera"
            else exit 0; fi
            ;;

        4)
            # === INDUSTRIAL ===
            PROMPT "INDUSTRIAL PROFILES
            
1. Siemens Simatic PLC
2. Rockwell Automation
3. Honeywell Controller
4. Schneider Electric

Press OK."
            PROF_ID=$(NUMBER_PICKER "Select Device" 1)
            
            if [ "$PROF_ID" -eq 1 ]; then
                NEW_OUI="00:1C:06"; NEW_NAME="Siemens-S7-1200"; TYPE="PLC"
            elif [ "$PROF_ID" -eq 2 ]; then
                NEW_OUI="00:00:BC"; NEW_NAME="Allen-Bradley-PLC"; TYPE="PLC"
            elif [ "$PROF_ID" -eq 3 ]; then
                # UPDATED: Honeywell GmbH
                NEW_OUI="00:30:AF"; NEW_NAME="Honeywell-HVAC-Ctl"; TYPE="HVAC"
            elif [ "$PROF_ID" -eq 4 ]; then
                NEW_OUI="00:00:54"; NEW_NAME="Schneider-Modicon"; TYPE="PLC"
            else exit 0; fi
            ;;

        5)
            # === ETHERNET (NEW) ===
            PROMPT "WIRED PROFILES
            
1. MSI Gaming Desktop (Home)
2. Cisco Desk Phone (Corp)
3. Verifone POS (Retail)
4. Moxa NPort Gateway (Ind)

Press OK."
            PROF_ID=$(NUMBER_PICKER "Select Device" 1)
            
            if [ "$PROF_ID" -eq 1 ]; then
                NEW_OUI="D8:CB:8A"; NEW_NAME="MSI-Gaming-Desktop"; TYPE="PC"
            elif [ "$PROF_ID" -eq 2 ]; then
                NEW_OUI="00:08:2F"; NEW_NAME="Cisco-IP-Phone"; TYPE="VoIP"
            elif [ "$PROF_ID" -eq 3 ]; then
                # UPDATED: Verifone, Inc.
                NEW_OUI="00:0B:4F"; NEW_NAME="Verifone-VX520-Eth"; TYPE="POS"
            elif [ "$PROF_ID" -eq 4 ]; then
                NEW_OUI="00:90:E8"; NEW_NAME="Moxa-NPort-5110"; TYPE="Gateway"
            else exit 0; fi
            ;;
            
        *)
            exit 0
            ;;
    esac

    if [ -n "$NEW_OUI" ]; then
        SUFFIX=$(gen_suffix)
        NEW_MAC="${NEW_OUI}${SUFFIX}"
    fi
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