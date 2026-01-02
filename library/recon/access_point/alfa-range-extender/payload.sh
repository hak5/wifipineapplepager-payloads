#!/bin/bash
# ============================================================================
# Title: ALFA Range Extender Recon
# Description: Extended WiFi scanning with ALFA AWUS036ACH in monitor mode
# Author: Aitema-GmbH
# Version: 2.0
# Category: recon/access_point
# Target: WiFi Pineapple Pager
# Hardware: ALFA AWUS036ACH (RTL8812AU)
# ============================================================================
#
# This payload enables an external ALFA AWUS036ACH adapter for extended
# range WiFi reconnaissance. The adapter's high-gain antenna provides
# significantly better range than the built-in radio.
#
# Requirements:
#   - ALFA AWUS036ACH connected via USB-A adapter
#   - RTL8812AU driver installed (kmod-rtl8812au-ct or similar)
#
# ============================================================================

shopt -s nullglob

# =========================
# CONFIGURATION
# =========================
ADAPTER_INTERFACE="wlan2"
LOOT_DIR="/root/loot/alfa-recon"
LOG_FILE="/tmp/alfa-range-extender.log"
SCAN_PID=""

# =========================
# CLEANUP
# =========================
cleanup() {
    # Kill any running scan
    if [ -n "$SCAN_PID" ]; then
        kill "$SCAN_PID" 2>/dev/null
    fi
    LED SETUP
}
trap cleanup EXIT INT TERM

# =========================
# FUNCTIONS
# =========================

check_adapter() {
    if ip link show "$ADAPTER_INTERFACE" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

load_driver() {
    # Try to load RTL8812AU driver
    if ! lsmod | grep -q "8812au\|88XXau"; then
        modprobe 8812au 2>/dev/null || modprobe 88XXau 2>/dev/null
        sleep 2
    fi
}

setup_monitor_mode() {
    local iface="$1"

    ip link set "$iface" down 2>/dev/null
    iw dev "$iface" set type monitor 2>/dev/null
    ip link set "$iface" up 2>/dev/null

    # Verify
    if iw dev "$iface" info 2>/dev/null | grep -q "type monitor"; then
        return 0
    else
        return 1
    fi
}

get_adapter_info() {
    local iface="$1"
    local mac=$(cat /sys/class/net/"$iface"/address 2>/dev/null)
    local driver=$(readlink /sys/class/net/"$iface"/device/driver 2>/dev/null | xargs basename 2>/dev/null)
    echo "MAC: $mac | Driver: $driver"
}

# =========================
# MAIN
# =========================

# Create loot directory
mkdir -p "$LOOT_DIR"

# Start logging
echo "=== ALFA Range Extender started: $(date) ===" >> "$LOG_FILE"

LED SETUP
LOG cyan "=========================================="
LOG cyan "  ALFA RANGE EXTENDER"
LOG cyan "=========================================="
LOG ""
LOG "Initializing ALFA AWUS036ACH..."
LOG ""

# Step 1: Load driver
LED ATTACK
LOG "Loading RTL8812AU driver..."
load_driver
sleep 1

# Step 2: Check adapter
if ! check_adapter; then
    LED FAIL
    ERROR_DIALOG "ALFA Adapter not found!\n\nPlease check:\n- USB-A adapter connected?\n- ALFA AWUS036ACH plugged in?\n- RTL8812AU driver installed?"
    echo "ERROR: Adapter not found" >> "$LOG_FILE"
    exit 1
fi

# Show adapter info
ADAPTER_INFO=$(get_adapter_info "$ADAPTER_INTERFACE")
LOG green "Adapter detected!"
LOG "$ADAPTER_INFO"
LOG ""

# Step 3: Confirm monitor mode activation
RESP=$(CONFIRMATION_DIALOG "Enable Monitor Mode\nfor extended recon?")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
        LOG yellow "Cancelled by user"
        exit 0
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG red "Dialog error"
        exit 1
        ;;
esac

case "$RESP" in
    "$DUCKYSCRIPT_USER_DENIED")
        LOG yellow "User declined"
        ALERT "Setup cancelled"
        exit 0
        ;;
esac

# Step 4: Enable monitor mode
LED ATTACK
LOG "Enabling Monitor Mode..."

if ! setup_monitor_mode "$ADAPTER_INTERFACE"; then
    LED FAIL
    ERROR_DIALOG "Monitor Mode failed!\n\nPossible causes:\n- Driver issue\n- Interface busy"
    exit 1
fi

LOG green "Monitor Mode active on $ADAPTER_INTERFACE"
LOG ""

# Step 5: Select band
RESP=$(CONFIRMATION_DIALOG "Select band:\n\n[Yes] = 5 GHz (faster)\n[No] = 2.4 GHz (range)")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
        LOG yellow "Cancelled"
        exit 0
        ;;
esac

case "$RESP" in
    "$DUCKYSCRIPT_USER_CONFIRMED")
        BAND="5GHz"
        CHANNELS="36,40,44,48,52,56,60,64,100,104,108,112,116,120,124,128,132,136,140,149,153,157,161,165"
        iw dev "$ADAPTER_INTERFACE" set freq 5180 2>/dev/null  # Channel 36
        ;;
    *)
        BAND="2.4GHz"
        CHANNELS="1,2,3,4,5,6,7,8,9,10,11,12,13"
        iw dev "$ADAPTER_INTERFACE" set freq 2437 2>/dev/null  # Channel 6
        ;;
esac

LOG "Band: $BAND selected"
LOG ""

# Step 6: Select scan mode
RESP=$(CONFIRMATION_DIALOG "Start auto-scan?\n\n[Yes] = airodump-ng auto\n[No] = Manual setup only")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
        LOG yellow "Cancelled"
        exit 0
        ;;
esac

case "$RESP" in
    "$DUCKYSCRIPT_USER_CONFIRMED")
        # Auto-scan mode
        SCAN_FILE="$LOOT_DIR/scan_$(date +%Y%m%d_%H%M%S)"
        LOG cyan "Starting scan..."
        LOG "Output: $SCAN_FILE"
        LOG ""
        LOG yellow "Press B button to stop"

        # Check if airodump-ng is available
        if ! command -v airodump-ng > /dev/null 2>&1; then
            LED FAIL
            ERROR_DIALOG "airodump-ng not found!\n\nInstall with:\nopkg install aircrack-ng"
            exit 1
        fi

        LED ATTACK

        # Start airodump-ng in background
        airodump-ng "$ADAPTER_INTERFACE" --band abg -w "$SCAN_FILE" --output-format csv,kismet,pcap &
        SCAN_PID=$!

        # Wait for button press
        WAIT_FOR_BUTTON_PRESS B

        # Stop scan
        kill "$SCAN_PID" 2>/dev/null
        SCAN_PID=""

        LOG green "Scan stopped"
        LOG ""
        LOG "Results saved to:"
        LOG "$SCAN_FILE.*"

        LED FINISH
        VIBRATE

        ALERT "Scan Complete!\n\nResults saved:\n$SCAN_FILE.*\n\nFiles:\n- .csv (networks)\n- .kismet (XML)\n- .pcap (packets)"
        ;;
    *)
        # Manual mode
        LED FINISH

        ALERT "ALFA Ready!\n\nInterface: $ADAPTER_INTERFACE\nMode: Monitor\nBand: $BAND\n\nManual scan:\nairodump-ng $ADAPTER_INTERFACE"
        ;;
esac

# Log completion
echo "=== Session ended: $(date) ===" >> "$LOG_FILE"
LOG green "ALFA Range Extender session complete"

exit 0
