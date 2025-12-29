#!/bin/bash
# Title: Full Bluetooth Scan
# Author: Hackazillarex , Log Viewer scripted by Brandon Starkweather
# Description: One-shot full scan of Classic and BLE devices on Pineapple Pager
# Version: 1.3

# === CONFIG ===
LOOT_DIR="/root/loot/bluetooth"
SCAN_DURATION=90       # 1.5 minutes
DATE_FMT="+%Y-%m-%d_%H-%M-%S"
HOSTNAME="$(hostname)"
LOG_VIEWER="/root/payloads/user/general/log_viewer/payload.sh"

mkdir -p "$LOOT_DIR"

# --- Sanity checks ---
for cmd in hciconfig hcitool bluetoothctl; do
    command -v "$cmd" >/dev/null 2>&1 || { LOG red "Missing $cmd"; exit 1; }
done
hciconfig | grep -q hci0 || { LOG red "No hci0 device found"; exit 1; }

LOG blue "Bluetooth Scan starting on $HOSTNAME"

TS="$(date "$DATE_FMT")"
OUT="$LOOT_DIR/bt_scan_$TS.txt"

{
    echo "=== Bluetooth Pager Full Scan ==="
    echo "Host: $HOSTNAME"
    echo "Date: $(date)"
    echo

    # --- Classic Bluetooth ---
    echo "--- Classic Bluetooth Devices ---"
    CLASSIC=$(hcitool scan 2>/dev/null | tail -n +2)
    if [ -z "$CLASSIC" ]; then
        echo "No Classic Bluetooth devices found."
    else
        echo "$CLASSIC"
    fi

    echo
    # --- BLE Devices ---
    echo "--- BLE Devices ---"
    echo "Scanning for $SCAN_DURATION seconds..."

    TMP_BLE="/tmp/bt_ble_scan.log"
    >"$TMP_BLE"

    bluetoothctl scan on >/dev/null 2>&1 &
    SCAN_PID=$!

    START=$(date +%s)
    while [ $(( $(date +%s) - START )) -lt "$SCAN_DURATION" ]; do
        bluetoothctl devices 2>/dev/null >> "$TMP_BLE"
        sleep 5
    done

    bluetoothctl scan off >/dev/null 2>&1
    kill "$SCAN_PID" >/dev/null 2>&1

    if [ -s "$TMP_BLE" ]; then
        awk '!seen[$0]++' "$TMP_BLE"
    else
        echo "No BLE devices found."
    fi

    rm -f "$TMP_BLE"

} > "$OUT"

# --- Cleanup empty logs ---
if ! grep -q "Device" "$OUT"; then
    rm -f "$OUT"
    LOG yellow "No Bluetooth devices found"
else
    LOG green "Scan complete — results saved"
fi

# --- Launch Log Viewer (Pager UI safe) ---
if [ -f "$LOG_VIEWER" ]; then
    LOG blue "Opening Log Viewer..."
    source "$LOG_VIEWER"
else
    LOG red "Log Viewer not found at $LOG_VIEWER"
fi

exit 0
