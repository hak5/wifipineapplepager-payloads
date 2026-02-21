#!/bin/bash
#
# Mad Possum Rogue Auth Watch
# Wi-Fi Pineapple Pager Payload
# Defensive monitoring + alerting
#

LOG_DIR="/sd/logs/madpossum_rogue_auth_watch"
ALERT_LOG="$LOG_DIR/alerts.log"
FIRST_RUN_FLAG="$LOG_DIR/.initialized"
RINGTONE="/usr/share/sounds/pager/Digimon.rtttl"

mkdir -p "$LOG_DIR"

#####################################
# First-run dependency verification #
#####################################
if [ ! -f "$FIRST_RUN_FLAG" ]; then
    echo "[*] First run detected — verifying dependencies" >> "$ALERT_LOG"

    for BIN in grep awk logger; do
        if ! command -v "$BIN" >/dev/null 2>&1; then
            echo "[!] Missing dependency: $BIN" >> "$ALERT_LOG"
        fi
    done

    touch "$FIRST_RUN_FLAG"
fi

echo "[*] Mad Possum Rogue Auth Watch started at $(date)" >> "$ALERT_LOG"

#####################################
# PineAP event monitoring            #
#####################################
logread -f | while read -r LINE; do

    echo "$LINE" | grep -Ei "pineap|association|auth|karma|probe" >/dev/null
    if [ $? -eq 0 ]; then

        TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

        BSSID=$(echo "$LINE" | grep -Eo "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}" | head -n1)
        CHANNEL=$(echo "$LINE" | grep -Eo "channel [0-9]+" | awk '{print $2}')
        RSSI=$(echo "$LINE" | grep -Eo "RSSI [-]?[0-9]+" | awk '{print $2}')

        {
            echo "[$TIMESTAMP] Rogue / Evil AP behavior detected"
            echo "BSSID: ${BSSID:-Unknown}"
            echo "Channel: ${CHANNEL:-Unknown}"
            echo "RSSI: ${RSSI:-Unknown}"
            echo "Raw Event: $LINE"
            echo "----------------------------------------"
        } >> "$ALERT_LOG"

        #####################################
        # Pager alert (with Digimon ringtone) #
        #####################################
        if command -v aplay >/dev/null 2>&1; then
            aplay "$RINGTONE" 2>/dev/null &
        fi

        # Pager notification
        logger "Rogue Auth Watch: Evil AP authentication detected"

    fi
done
