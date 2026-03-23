#!/bin/bash
# Title: TRIG_MAC|WIRELESS TRIPWIRE
# Version: 2.0
# Author: THENRGLABS

# --- 1. THE TRANSPARENT STARTUP ---
nuke_everything() {
    rm -f /tmp/tm_running
    LOG red "CLEANING PROCESSES..."
    # Kill and log
    pkill -9 -f "tcpdump" && LOG gray "TCPDUMP STOPPED"
    pkill -9 -f "hcitool" && LOG gray "BT SCAN STOPPED"
    pkill -9 -f "scan_cycle" 2>/dev/null
    pgrep -f "trig_mac.sh" | grep -v $$ | xargs kill -9 2>/dev/null
    rm -f /tmp/tm_alock /tmp/w /tmp/b
}

nuke_everything
sleep 0.5
RINGTONE getmachine

# --- 2. GPS & ENVIRONMENT ---
BAUD=9600 
DEV="/dev/ttyUSB0"

if [ -e "$DEV" ]; then
    LOG cyan "SYNCING GPSD..."
    killall gpsd 2>/dev/null
    stty -F "$DEV" "$BAUD"
    gpsd "$DEV" -F /var/run/gpsd.sock
    sleep 2
fi

LOOT_DIR="/root/loot/TRIG_MAC"
mkdir -p "$LOOT_DIR"
BT="$LOOT_DIR/ble_targets.t"; SS="$LOOT_DIR/ssid_targets.t"
WF="$LOOT_DIR/wifi_targets.t"; LOGFILE="$LOOT_DIR/hits_$(date +%Y-%m-%d).csv"
touch "$BT" "$SS" "$WF" "$LOGFILE"

# --- 3. INTELLIGENCE HELPERS ---
get_gps_split() {
    local RAW=$(gpspipe -w -n 10 | grep -m 1 "TPV" | sed -n 's/.*"lat":\([-0-9.]*\).*"lon":\([-0-9.]*\).*/\1 \2/p')
    [ -z "$RAW" ] && echo "0.000 0.000" || echo "$RAW"
}

write_log() {
    [ ! -s "$LOGFILE" ] && echo "Timestamp,Type,TargetID,MAC,Latitude,Longitude" > "$LOGFILE"
    local COORDS=$(get_gps_split)
    local LAT=$(echo $COORDS | awk '{print $1}')
    local LON=$(echo $COORDS | awk '{print $2}')
    echo "$(date '+%Y-%m-%d %H:%M:%S'),$1,\"$2\",${3:-N/A},$LAT,$LON" >> "$LOGFILE"
    sync
}

notify() {
    local type=$1 id=$2 bg=$3 mac_info=$4
    NOW=$(date +%s)
    local COORDS=$(get_gps_split)
    local LAT=$(echo $COORDS | awk '{print $1}')
    local LON=$(echo $COORDS | awk '{print $2}')
    
    write_log "$type" "$id" "$mac_info"
    
    SHOULD_RING=true
    if [ -f "/tmp/tm_alock" ]; then
        LAST_HIT=$(cat /tmp/tm_alock)
        [ $((NOW - LAST_HIT)) -lt 120 ] && SHOULD_RING=false
    fi

    if [ "$SHOULD_RING" = "true" ]; then
        echo "$NOW" > "/tmp/tm_alock"; sync
        LED R 255; RINGTONE warning
        ALERT "TRIPWIRE: $id\nLAT: $LAT\nLON: $LON"
        sleep 1.2; LED OFF
        [ "$bg" != "true" ] && LOG red "HIT: $type" && LOG white "$id"
    else
        # THE SILENT HIT FEEDBACK
        [ "$bg" != "true" ] && LOG yellow "SILENT HIT: $type" && LOG gray "$id"
    fi
    
    [ "$bg" != "true" ] && LOG cyan "LOC: $LAT,$LON"
}

# --- 4. SCAN ENGINE ---
scan_cycle() {
    [ ! -f /tmp/tm_running ] && exit 0
    if [ -s "$SS" ] || [ -s "$WF" ]; then
        timeout 12 tcpdump -l -i wlan0mon -n -e 'type mgt' 2>/dev/null > /tmp/w
        [ -s "$SS" ] && while read -r s; do
            H=$(grep -i "$s" /tmp/w | head -n 1)
            if [ -n "$H" ]; then
                M=$(echo "$H" | grep -oE "SA:[0-9a-fA-F:]{17}" | cut -d':' -f2-7)
                notify "SSID" "$s" "$1" "$M"
            fi
        done < "$SS"
        [ -s "$WF" ] && while read -r w; do
            grep -iq "$w" /tmp/w && notify "MAC" "$w" "$1"
        done < "$WF"
    fi
    if [ -s "$BT" ]; then
        timeout 7 hcitool lescan --duplicates 2>/dev/null | grep -v "Scanning" > /tmp/b
        while read -r t; do grep -iq "$t" /tmp/b && notify "BLE" "$t" "$1"; done < "$BT"
    fi
}

# --- 5. INTERFACE ---
LOG cyan "WIRELESS TRIPWIRE v2.2"
while true; do
    sed -i '/^[[:space:]]*$/d' "$SS" "$BT" "$WF" 2>/dev/null
    T=$(cat "$SS" "$BT" "$WF" 2>/dev/null | grep -v '^$' | wc -l)
    LOG white "Targets: $T"
    LOG "UP:SSID DN:MAC LF:WiFi B:PURGE A:ARM"
    
    R=$(WAIT_FOR_INPUT)
    if [ "$R" = "UP" ]; then I=$(TEXT_PICKER "SSID" ""); [ -n "$I" ] && echo "$I" >> "$SS" && RINGTONE getmachine
    elif [ "$R" = "DOWN" ]; then I=$(MAC_PICKER "BLE" ""); [ -n "$I" ] && echo "$I" >> "$BT" && RINGTONE getmachine
    elif [ "$R" = "LEFT" ]; then I=$(MAC_PICKER "WiFi" ""); [ -n "$I" ] && echo "$I" >> "$WF" && RINGTONE getmachine
    elif [ "$R" = "B" ]; then 
        LOG red "PURGE TARGETS?"
        LOG "UP: YES | DOWN: CANCEL"
        if [ "$(WAIT_FOR_INPUT)" = "UP" ]; then
            > "$BT"; > "$SS"; > "$WF"
            RINGTONE getmachine; LOG green "LIST WIPED"
        fi
        LOG yellow "EXIT SCRIPT?"
        LOG "UP: NO | DOWN: YES"
        if [ "$(WAIT_FOR_INPUT)" = "DOWN" ]; then
            nuke_everything
            LOG white "EXITTING..."
            exit 0
        fi
    elif [ "$R" = "A" ]; then break; fi
done

# --- 6. DEPLOYMENT ---
LOG yellow "CHOOSE MODE:"
LOG "UP: LIVE | DOWN: BACKGROUND"
SEL=$(WAIT_FOR_INPUT)

LOG green "PREPARING RADIOS..."
ifconfig wlan0mon up 2>/dev/null; hciconfig hci0 up 2>/dev/null
sleep 2

touch /tmp/tm_running
RINGTONE success; LED G 255; sleep 1

if [ "$SEL" = "UP" ]; then
    LOG cyan "TRIPWIRE: LIVE"
    while [ -f /tmp/tm_running ]; do scan_cycle "false"; done
else
    LOG green "ARMED IN BACKGROUND"
    ( while [ -f /tmp/tm_running ]; do scan_cycle "true"; done ) &
    RINGTONE alert; sleep 1.5; exit 0
fi
