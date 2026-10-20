#!/bin/sh
# Title:       Looking Glass
# Description:  Detects nearby smart glasses via BLE advertising
#               frames using Bluetooth SIG company IDs.
# Version:      1.0
# Category:     reconnaissance

SCAN_TIME=120

BLE_RAW="/tmp/glasses_btmon.txt"
BLE_NAMES="/tmp/glasses_lescan.txt"
SEEN_FILE="/tmp/glasses_seen.txt"

> "${BLE_RAW}"
> "${BLE_NAMES}"
> "${SEEN_FILE}"

PID_MON=""
PID_SCAN=""

cleanup() {
    [ -n "${PID_MON}" ]  && kill "${PID_MON}" 2>/dev/null
    [ -n "${PID_SCAN}" ] && kill "${PID_SCAN}" 2>/dev/null
    killall -q hcitool btmon hcidump 2>/dev/null
    rm -f "${BLE_RAW}" "${BLE_NAMES}" "${SEEN_FILE}" 2>/dev/null
    DPADLED off 2>/dev/null
}
trap cleanup EXIT

LOG cyan "Looking_Glass v1.0"
LOG ""

# --- Install bluez-utils if needed ---
if ! command -v hcitool > /dev/null 2>&1 || ! command -v hciconfig > /dev/null 2>&1; then
    LOG yellow "Installing bluez-utils..."
    __sid=$(START_SPINNER "Installing...")
    opkg update > /dev/null 2>&1
    opkg install bluez-utils > /dev/null 2>&1
    command -v hcitool > /dev/null 2>&1 || opkg install bluez-utils-extra > /dev/null 2>&1
    command -v hcitool > /dev/null 2>&1 || opkg install kmod-bluetooth bluez-libs bluez-utils > /dev/null 2>&1
    STOP_SPINNER "${__sid}"
    if ! command -v hcitool > /dev/null 2>&1; then
        ERROR_DIALOG "bluez-utils install failed. Need internet."
        exit 1
    fi
    LOG green "Installed."
else
    LOG green "bluez-utils OK."
fi

# --- Bring up BT adapter ---
command -v rfkill > /dev/null 2>&1 && rfkill unblock bluetooth > /dev/null 2>&1

BT=""
for I in hci0 hci1 hci2; do
    hciconfig "${I}" > /dev/null 2>&1 && BT="${I}" && break
done
[ -z "${BT}" ] && [ -d /sys/class/bluetooth ] && BT=$(ls /sys/class/bluetooth/ 2>/dev/null | head -1)
if [ -z "${BT}" ]; then
    modprobe bluetooth hci_uart btusb > /dev/null 2>&1; sleep 2
    for I in hci0 hci1; do
        hciconfig "${I}" > /dev/null 2>&1 && BT="${I}" && break
    done
fi
[ -z "${BT}" ] && { ERROR_DIALOG "No Bluetooth adapter."; exit 1; }

LOG "Adapter: ${BT}"
hciconfig "${BT}" down > /dev/null 2>&1; sleep 1
hciconfig "${BT}" reset > /dev/null 2>&1; sleep 1
hciconfig "${BT}" up > /dev/null 2>&1; sleep 2

UP=0
hciconfig "${BT}" 2>/dev/null | grep -qi "UP RUNNING" && UP=1
if [ "${UP}" -eq 0 ]; then
    hciconfig "${BT}" reset > /dev/null 2>&1; sleep 2
    hciconfig "${BT}" up > /dev/null 2>&1; sleep 2
    hciconfig "${BT}" 2>/dev/null | grep -qi "UP\|RUNNING" && UP=1
fi
[ "${UP}" -eq 0 ] && { ERROR_DIALOG "BT adapter won't start. Reboot Pager."; exit 1; }
LOG green "${BT} is UP."

# --- Detection patterns ---

BTMON_PATTERN="Meta Platforms|Luxottica|Snap Inc|Snapchat|Bose Corp|Google|Vuzix|XREAL|Nreal"
HEXDUMP_PATTERN="ff ab 01|ff 8e 05|ff 53 0d|ff c2 03|ff 9e 00|ff e0 00|ff 22 08|ff 87 09"
NAME_PATTERN="Ray-Ban|RayBan|Meta|Spectacles|Bose Frame|Google Glass|Vuzix|XREAL|Nreal|Oakley"

# --- Brand identification ---

get_brand() {
    local line
    line=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    echo "${line}" | grep -qi "luxottica\|0x0d53\|53 0d" && { echo "Meta Ray-Ban (Luxottica)"; return; }
    echo "${line}" | grep -qi "meta platforms\|0x01ab\|0x058e\|ab 01\|8e 05" && { echo "Meta Ray-Ban"; return; }
    echo "${line}" | grep -qi "snap\|0x03c2\|c2 03\|spectacles" && { echo "Snap Spectacles"; return; }
    echo "${line}" | grep -qi "bose\|0x009e\|9e 00" && { echo "Bose Frames"; return; }
    echo "${line}" | grep -qi "vuzix\|0x0822\|22 08" && { echo "Vuzix Glasses"; return; }
    echo "${line}" | grep -qi "xreal\|nreal\|0x0987\|87 09" && { echo "XREAL Glasses"; return; }
    echo "${line}" | grep -qi "google\|0x00e0\|e0 00" && { echo "Meta Ray-Ban"; return; }
    echo "${line}" | grep -qi "ray-ban\|rayban" && { echo "Meta Ray-Ban"; return; }
    echo "${line}" | grep -qi "oakley" && { echo "Oakley Meta"; return; }

    echo "Smart Glasses"
}

get_key() {
    local line
    line=$(echo "$1" | tr '[:upper:]' '[:lower:]')

    echo "${line}" | grep -qi "luxottica\|0x0d53\|53 0d" && { echo "luxottica"; return; }
    echo "${line}" | grep -qi "meta platforms\|0x01ab\|0x058e\|ab 01\|8e 05" && { echo "meta"; return; }
    echo "${line}" | grep -qi "snap\|0x03c2\|c2 03\|spectacles" && { echo "snap"; return; }
    echo "${line}" | grep -qi "bose\|0x009e\|9e 00" && { echo "bose"; return; }
    echo "${line}" | grep -qi "vuzix\|0x0822\|22 08" && { echo "vuzix"; return; }
    echo "${line}" | grep -qi "xreal\|nreal\|0x0987\|87 09" && { echo "xreal"; return; }
    echo "${line}" | grep -qi "google\|0x00e0\|e0 00" && { echo "google"; return; }
    echo "${line}" | grep -qi "ray-ban\|rayban" && { echo "rayban"; return; }
    echo "${line}" | grep -qi "oakley" && { echo "oakley"; return; }

    echo "unk"
}

# --- RSSI estimation ---

estimate_distance() {
    local r="$1"
    if [ "${r}" -gt -40 ] 2>/dev/null; then
        echo "<1m"
    elif [ "${r}" -gt -55 ] 2>/dev/null; then
        echo "1-3m"
    elif [ "${r}" -gt -70 ] 2>/dev/null; then
        echo "3-8m"
    elif [ "${r}" -gt -85 ] 2>/dev/null; then
        echo "8-15m"
    else
        echo ">15m"
    fi
}

# --- Start BLE capture ---

LOG ""
LOG "Scanning ${SCAN_TIME}s..."
LOG ""

USE_MON=0
USE_HEX=0

if command -v btmon > /dev/null 2>&1; then
    btmon > "${BLE_RAW}" 2>&1 &
    PID_MON=$!
    USE_MON=1
    sleep 1
elif command -v hcidump > /dev/null 2>&1; then
    hcidump -i "${BT}" --raw > "${BLE_RAW}" 2>&1 &
    PID_MON=$!
    USE_HEX=1
    sleep 1
else
    PID_MON=""
fi

hcitool -i "${BT}" lescan --duplicates > "${BLE_NAMES}" 2>&1 &
PID_SCAN=$!
sleep 2

if ! kill -0 "${PID_SCAN}" 2>/dev/null; then
    hcitool -i "${BT}" lescan > "${BLE_NAMES}" 2>&1 &
    PID_SCAN=$!; sleep 2
fi
if ! kill -0 "${PID_SCAN}" 2>/dev/null; then
    hcitool lescan > "${BLE_NAMES}" 2>&1 &
    PID_SCAN=$!; sleep 2
fi
if ! kill -0 "${PID_SCAN}" 2>/dev/null; then
    [ -n "${PID_MON}" ] && kill "${PID_MON}" 2>/dev/null
    ERROR_DIALOG "BLE scan failed. Reboot Pager."
    exit 1
fi

LOG green "Scan active."

# --- Main scan loop ---

HITS=0
PULSE=1
DEADLINE=$(( $(date +%s) + SCAN_TIME ))

DPADLED cyan

while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
    sleep 3

    if [ "${PULSE}" -eq 1 ]; then
        DPADLED off; PULSE=0
    else
        DPADLED cyan; PULSE=1
    fi

    # Check btmon / hcidump for company ID matches
    MATCHES=""
    if [ "${USE_MON}" -eq 1 ]; then
        MATCHES=$(grep -iE "${BTMON_PATTERN}" "${BLE_RAW}" 2>/dev/null | sort -u | head -30)
    elif [ "${USE_HEX}" -eq 1 ]; then
        MATCHES=$(grep -iE "${HEXDUMP_PATTERN}" "${BLE_RAW}" 2>/dev/null | sort -u | head -30)
    fi

    if [ -n "${MATCHES}" ]; then
        while IFS= read -r LINE; do
            [ -z "${LINE}" ] && continue
            KEY=$(get_key "${LINE}")
            [ -z "${KEY}" ] || [ "${KEY}" = "unk" ] && continue
            grep -qF "${KEY}" "${SEEN_FILE}" 2>/dev/null && continue

            BRAND=$(get_brand "${LINE}")
            echo "${KEY}" >> "${SEEN_FILE}"
            HITS=$((HITS + 1))

            RSSI=$(grep -oE 'RSSI: -?[0-9]+' "${BLE_RAW}" 2>/dev/null | tail -1 | grep -oE '\-?[0-9]+')

            if [ -n "${RSSI}" ]; then
                DIST=$(estimate_distance "${RSSI}")
                LOG red "DETECTED: ${BRAND}"
                LOG red "  Signal: ${RSSI} dBm (~${DIST})"
            else
                LOG red "DETECTED: ${BRAND}"
            fi
            VIBRATE "alert"

            DPADLED red;  sleep 0.3
            DPADLED off;  sleep 0.3
            DPADLED red;  sleep 0.3
            DPADLED off;  sleep 0.3
            DPADLED red;  sleep 0.3
            DPADLED off;  sleep 0.3
            DPADLED cyan
            PULSE=1
        done <<ENDCHECK1
${MATCHES}
ENDCHECK1
    fi

    # Check lescan for device name matches
    NAMEHITS=$(grep -iE "${NAME_PATTERN}" "${BLE_NAMES}" 2>/dev/null | sort -u | head -30)

    if [ -n "${NAMEHITS}" ]; then
        while IFS= read -r LINE; do
            [ -z "${LINE}" ] && continue
            DNAME=$(echo "${LINE}" | sed 's/^[0-9A-Fa-f:]\{17\}[[:space:]]*//')
            [ -z "${DNAME}" ] && continue

            KEY="n_$(get_key "${DNAME}")"
            grep -qF "${KEY}" "${SEEN_FILE}" 2>/dev/null && continue

            BRAND=$(get_brand "${DNAME}")
            [ "${BRAND}" = "Smart Glasses" ] && continue
            echo "${KEY}" >> "${SEEN_FILE}"
            HITS=$((HITS + 1))

            LOG red "DETECTED: ${BRAND} (${DNAME})"
            VIBRATE "alert"

            DPADLED red;  sleep 0.3
            DPADLED off;  sleep 0.3
            DPADLED red;  sleep 0.3
            DPADLED off;  sleep 0.3
            DPADLED red;  sleep 0.3
            DPADLED off;  sleep 0.3
            DPADLED cyan
            PULSE=1
        done <<ENDCHECK2
${NAMEHITS}
ENDCHECK2
    fi
done

# --- Stop capture ---

[ -n "${PID_SCAN}" ] && kill "${PID_SCAN}" 2>/dev/null
[ -n "${PID_MON}" ]  && kill "${PID_MON}" 2>/dev/null
killall -q hcitool btmon hcidump 2>/dev/null

# --- Summary ---

DPADLED off
LOG ""

if [ "${HITS}" -gt 0 ]; then
    LOG red "Done: ${HITS} smart glasses detected!"
    VIBRATE "alert"
    ALERT "${HITS} smart glasses detected nearby!"
    DPADLED red; sleep 1
    DPADLED off; sleep 0.5
    DPADLED red; sleep 1
    DPADLED off
else
    LOG green "Done. No smart glasses detected."
fi

DPADLED off
exit 0
