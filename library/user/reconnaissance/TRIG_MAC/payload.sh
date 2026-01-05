#!/bin/bash
# Title: TRIG_MAC v11.9
# Device: WiFi Pineapple Pager
# Fix: RINGTONE alert used, removed all VIBRATE commands

# --- 1. CONFIG ---
DB_BT="trig_mac_bt"; DB_WF="trig_mac_wf"; DB_SSID="trig_mac_ssid"
WORK_DIR="/tmp/trig_mac"; LOG_HIT="/tmp/trig_hits"
mkdir -p "$WORK_DIR" "$LOG_HIT" "/root/loot/TRIG_MAC"
BT_TARGETS="$WORK_DIR/bt.txt"; WF_TARGETS="$WORK_DIR/wf.txt"; SSID_TARGETS="$WORK_DIR/ss.txt"

# --- 2. VERBOSE RESTORE ---
OLD_BT=$(PAYLOAD_GET_CONFIG "TRIG_MAC" "$DB_BT"); OLD_WF=$(PAYLOAD_GET_CONFIG "TRIG_MAC" "$DB_WF"); OLD_SSID=$(PAYLOAD_GET_CONFIG "TRIG_MAC" "$DB_SSID")
if [ -n "$OLD_BT" ] || [ -n "$OLD_WF" ] || [ -n "$OLD_SSID" ]; then
    if [ "$(CONFIRMATION_DIALOG "Load previous targets?")" = "1" ]; then
        echo "$OLD_BT" | tr ',' '\n' | grep -v '^$' > "$BT_TARGETS"
        echo "$OLD_WF" | tr ',' '\n' | grep -v '^$' > "$WF_TARGETS"
        echo "$OLD_SSID" | tr ',' '\n' | grep -v '^$' > "$SSID_TARGETS"
        TITLE "RESTORING..."
        [ -s "$BT_TARGETS" ] && while read -r line; do LOG "LOAD BLE: $line"; done < "$BT_TARGETS"
        [ -s "$WF_TARGETS" ] && while read -r line; do LOG "LOAD WF: $line"; done < "$WF_TARGETS"
        [ -s "$SSID_TARGETS" ] && while read -r line; do LOG "LOAD SSID: $line"; done < "$SSID_TARGETS"
        sleep 1
    fi
fi

# --- 3. MENU LOOP ---
while true; do
    cS=$(grep -c . "$SSID_TARGETS" 2>/dev/null || echo 0); cB=$(grep -c . "$BT_TARGETS" 2>/dev/null || echo 0); cW=$(grep -c . "$WF_TARGETS" 2>/dev/null || echo 0)
    TITLE "TRIG_MAC [S:$cS B:$cB W:$cW]"; LOG "UP:SSID DN:BLE LF:WiFi A:GO B:CLR"
    resp=$(WAIT_FOR_INPUT)
    case $resp in
        UP)   IN=$(TEXT_PICKER "Target SSID" ""); [ -n "$IN" ] && { echo "$IN" >> "$SSID_TARGETS"; LOG "ADD SSID: $IN"; } ;;
        DOWN) IN=$(MAC_PICKER "Add BLE MAC" ""); [ -n "$IN" ] && { echo "$IN" >> "$BT_TARGETS"; LOG "ADD BLE: $IN"; } ;;
        LEFT) IN=$(MAC_PICKER "Add WiFi MAC" ""); [ -n "$IN" ] && { echo "$IN" >> "$WF_TARGETS"; LOG "ADD WF: $IN"; } ;;
        A)    break ;; 
        B)    if [ "$(CONFIRMATION_DIALOG "WIPE?")" = "1" ]; then rm -f "$BT_TARGETS" "$WF_TARGETS" "$SSID_TARGETS"; PAYLOAD_SET_CONFIG "TRIG_MAC" "$DB_BT" ""; PAYLOAD_SET_CONFIG "TRIG_MAC" "$DB_WF" ""; PAYLOAD_SET_CONFIG "TRIG_MAC" "$DB_SSID" ""; LOG "CLEARED"; fi ;;
    esac
    PAYLOAD_SET_CONFIG "TRIG_MAC" "$DB_BT" "$(tr '\n' ',' < "$BT_TARGETS" 2>/dev/null | sed 's/,$//')"
    PAYLOAD_SET_CONFIG "TRIG_MAC" "$DB_WF" "$(tr '\n' ',' < "$WF_TARGETS" 2>/dev/null | sed 's/,$//')"
    PAYLOAD_SET_CONFIG "TRIG_MAC" "$DB_SSID" "$(tr '\n' ',' < "$SSID_TARGETS" 2>/dev/null | sed 's/,$//')"
done

# --- 4. STARTUP NOTIFICATION ---
TITLE "INIT RADIOS..."
hciconfig hci0 up 2>/dev/null
[ ! -d /sys/class/net/wlan0mon ] && { iw dev wlan0 interface add wlan0mon type monitor; ifconfig wlan0mon up; }

LED G 255
RINGTONE alert
TITLE "SCAN STARTED!"
LOG "Warden Active..."
sleep 3
LED OFF

# --- 5. NOTIFY ENGINE ---
notify() {
    local type=$1 id=$2 info=$3
    [ -f "$LOG_HIT/$id" ] && return
    touch "$LOG_HIT/$id"
    RINGTONE warning; LED R 255 B 0 G 0
    LOG "HIT! $type: $id"
    LOG "$info"
    ALERT_RINGTONE true "$type DETECTED\nID: $id\n$info"
    echo "[$(date '+%T')] $type | $id | $info" >> "/root/loot/TRIG_MAC/hits.log"
    LED OFF
}

# --- 6. STABLE SCAN LOOP ---
while true; do
    # 6.1 BLE Phase
    if [ -s "$BT_TARGETS" ]; then
        TITLE "BLE SCANNING..."; timeout -s SIGINT 5 hcitool lescan --duplicates 2>/dev/null > /tmp/ble.tmp &
        BLE_PID=$! ; sleep 5 ; kill -2 $BLE_PID 2>/dev/null
        while read -r target; do grep -iq "$target" /tmp/ble.tmp && notify "BT" "$target" "Device Detected"; done < "$BT_TARGETS"
    fi

    # 6.2 WiFi Phase
    TITLE "WIFI SNIFFING..."
    timeout 10 tcpdump -i wlan0mon -n -e -s 256 -A 'type mgt subtype probe-req' 2>/dev/null > /tmp/wifi.tmp
    
    while read -r ts; do
        if grep -iq "$ts" /tmp/wifi.tmp; then
            sm=$(grep -iB 5 "$ts" /tmp/wifi.tmp | grep -oE '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}' | tail -1)
            notify "SSID" "$sm" "Target: $ts"
        fi
    done < "$SSID_TARGETS"

    while read -r tw; do
        if grep -iq "$tw" /tmp/wifi.tmp; then
            fs=$(grep -iA 10 "$tw" /tmp/wifi.tmp | grep -oE 'Probe Request \([^)]*\)' | head -1 | sed 's/Probe Request (\(.*\))/\1/')
            notify "WIFI" "$tw" "Probing: ${fs:-Broadcast}"
        fi
    done < "$WF_TARGETS"

    [ $(($(date +%s) % 300)) -lt 15 ] && rm -f "$LOG_HIT"/* 2>/dev/null
    TITLE "WARDEN ACTIVE"; LED B 20; sleep 1; LED OFF
done