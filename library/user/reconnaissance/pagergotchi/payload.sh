#!/bin/bash
# Title: PagerGotchi
# Description: Pwnagotchi for WiFi Pineapple Pager - Automated WiFi handshake capture with personality
# Author: brAinphreAk
# Version: 2.0
# Category: Reconnaissance
# Library: libpagerctl.so (pagerctl)

# Payload directory (standard Pager installation path)
PAYLOAD_DIR="/root/payloads/user/reconnaissance/pagergotchi"
DATA_DIR="$PAYLOAD_DIR/data"

cd "$PAYLOAD_DIR" || {
    LOG "red" "ERROR: $PAYLOAD_DIR not found"
    exit 1
}

#
# Find and setup pagerctl dependencies (libpagerctl.so + pagerctl.py)
# Check bundled lib/ first, then PAGERCTL utilities dir
#
PAGERCTL_FOUND=false
PAGERCTL_SEARCH_PATHS=(
    "$PAYLOAD_DIR/lib"
    "/mmc/root/payloads/user/utilities/PAGERCTL"
)

for dir in "${PAGERCTL_SEARCH_PATHS[@]}"; do
    if [ -f "$dir/libpagerctl.so" ] && [ -f "$dir/pagerctl.py" ]; then
        PAGERCTL_DIR="$dir"
        PAGERCTL_FOUND=true
        break
    fi
done

if [ "$PAGERCTL_FOUND" = false ]; then
    LOG ""
    LOG "red" "=== MISSING DEPENDENCY ==="
    LOG ""
    LOG "red" "libpagerctl.so and pagerctl.py not found!"
    LOG ""
    LOG "Searched:"
    for dir in "${PAGERCTL_SEARCH_PATHS[@]}"; do
        LOG "  $dir"
    done
    LOG ""
    LOG "Install PAGERCTL payload or copy files to:"
    LOG "  $PAYLOAD_DIR/lib/"
    LOG ""
    LOG "Press any button to exit..."
    WAIT_FOR_INPUT >/dev/null 2>&1
    exit 1
fi

# If pagerctl files aren't in our lib dir, copy them there
if [ "$PAGERCTL_DIR" != "$PAYLOAD_DIR/lib" ]; then
    mkdir -p "$PAYLOAD_DIR/lib" 2>/dev/null
    cp "$PAGERCTL_DIR/libpagerctl.so" "$PAYLOAD_DIR/lib/" 2>/dev/null
    cp "$PAGERCTL_DIR/pagerctl.py" "$PAYLOAD_DIR/lib/" 2>/dev/null
    LOG "green" "Copied pagerctl from $PAGERCTL_DIR"
fi

#
# Setup local paths for bundled binaries and libraries
# Uses libpagerctl.so for display/input handling
# MMC paths needed when python3 installed with opkg -d mmc
#
export PATH="/mmc/usr/bin:$PAYLOAD_DIR/bin:$PATH"
export PYTHONPATH="$PAYLOAD_DIR/lib:$PAYLOAD_DIR:$PYTHONPATH"
export LD_LIBRARY_PATH="/mmc/usr/lib:$PAYLOAD_DIR/lib:$LD_LIBRARY_PATH"

#
# Check for Python3 and python3-ctypes - required system dependencies
#
NEED_PYTHON=false
NEED_CTYPES=false

if ! command -v python3 >/dev/null 2>&1; then
    NEED_PYTHON=true
    NEED_CTYPES=true
elif ! python3 -c "import ctypes" 2>/dev/null; then
    NEED_CTYPES=true
fi

if [ "$NEED_PYTHON" = true ] || [ "$NEED_CTYPES" = true ]; then
    LOG ""
    LOG "red" "=== MISSING REQUIREMENT ==="
    LOG ""
    if [ "$NEED_PYTHON" = true ]; then
        LOG "Python3 is required to run PagerGotchi."
    else
        LOG "Python3-ctypes is required to run PagerGotchi."
    fi
    LOG "All other dependencies are bundled."
    LOG ""
    LOG "green" "GREEN = Install dependencies (requires internet)"
    LOG "red" "RED   = Exit"
    LOG ""

    while true; do
        BUTTON=$(WAIT_FOR_INPUT 2>/dev/null)
        case "$BUTTON" in
            "GREEN"|"A")
                LOG ""
                LOG "Updating package lists..."
                opkg update 2>&1 | while IFS= read -r line; do LOG "  $line"; done
                LOG ""
                LOG "Installing Python3 + ctypes to MMC..."
                opkg -d mmc install python3 python3-ctypes 2>&1 | while IFS= read -r line; do LOG "  $line"; done
                LOG ""
                # Verify installation succeeded
                if command -v python3 >/dev/null 2>&1 && python3 -c "import ctypes" 2>/dev/null; then
                    LOG "green" "Python3 installed successfully!"
                    sleep 1
                else
                    LOG "red" "Failed to install Python3"
                    LOG "red" "Check internet connection and try again."
                    LOG ""
                    LOG "Press any button to exit..."
                    WAIT_FOR_INPUT >/dev/null 2>&1
                    exit 1
                fi
                break
                ;;
            "RED"|"B")
                LOG "Exiting."
                exit 0
                ;;
        esac
    done
fi

# Verify pwnagotchi_port Python module exists
[ ! -d "$PAYLOAD_DIR/pwnagotchi_port" ] && {
    LOG "red" "ERROR: pwnagotchi_port module not found"
    exit 1
}

#
# Setup
#

# Create data directory
mkdir -p "$DATA_DIR" 2>/dev/null

# Setup monitor mode interface
setup_monitor_mode() {
    local INTERFACE="wlan0mon"

    if ! iw dev 2>/dev/null | grep -q "$INTERFACE"; then
        LOG "Setting up monitor mode..."

        ifconfig wlan0 down 2>/dev/null
        iw dev wlan0 set type monitor 2>/dev/null
        ifconfig wlan0 up 2>/dev/null
        ip link set wlan0 name "$INTERFACE" 2>/dev/null

        if ! iw dev 2>/dev/null | grep -q "$INTERFACE"; then
            if command -v airmon-ng >/dev/null 2>&1; then
                airmon-ng start wlan0 2>/dev/null
            fi
        fi

        if iw dev 2>/dev/null | grep -q "$INTERFACE"; then
            LOG "green" "Monitor mode enabled: $INTERFACE"
            return 0
        else
            if iw dev wlan0 info 2>/dev/null | grep -q "type monitor"; then
                LOG "green" "wlan0 already in monitor mode"
                return 0
            fi
            LOG "red" "Failed to enable monitor mode"
            return 1
        fi
    else
        LOG "green" "Monitor mode already active: $INTERFACE"
    fi
    return 0
}

#
# Main
#

# Show info/splash screen first
LOG ""
LOG "green" "Pwnagotchi for WiFi Pineapple Pager"
LOG "cyan" "ported by *brAinphreAk* (www.brAinphreAk.net)"
LOG ""
LOG "yellow" "Features:"
LOG "cyan" "  - Automated WiFi handshake capture"
LOG "cyan" "  - PMKID and 4-way handshake attacks"
LOG "cyan" "  - Deauth Scope: Whitelist/Blacklist"
LOG "cyan" "  - Privacy Mode: Obfuscate display"
LOG "cyan" "  - Optional GPS & WiGLE logging"
LOG ""
LOG "green" "GREEN = Start"
LOG "red" "RED = Exit"
LOG ""

while true; do
    BUTTON=$(WAIT_FOR_INPUT 2>/dev/null)
    case "$BUTTON" in
        "GREEN"|"A")
            break
            ;;
        "RED"|"B")
            LOG "Exiting."
            exit 0
            ;;
    esac
done

# Now do setup after GREEN button pressed
LOG ""
SPINNER_ID=$(START_SPINNER "Setting up PagerGotchi...")

if ! setup_monitor_mode; then
    STOP_SPINNER "$SPINNER_ID" 2>/dev/null
    LOG ""
    LOG "red" "Monitor mode setup failed!"
    LOG "Press any button to try anyway..."
    WAIT_FOR_INPUT >/dev/null 2>&1
    SPINNER_ID=$(START_SPINNER "Starting anyway...")
fi

# Stop services to free framebuffer (but keep pineapd running)
/etc/init.d/php8-fpm stop 2>/dev/null
/etc/init.d/nginx stop 2>/dev/null
/etc/init.d/bluetoothd stop 2>/dev/null
/etc/init.d/pineapplepager stop 2>/dev/null

# Stop pineapd service and start our own with handshakes enabled
STOP_SPINNER "$SPINNER_ID" 2>/dev/null
LOG "Starting pineapd with handshake capture..."
/etc/init.d/pineapd stop 2>/dev/null
killall pineapd 2>/dev/null
sleep 1

# Start our pineapd with handshakes enabled
/usr/sbin/pineapd \
    --recon=true \
    --reconpath /root/recon/ \
    --reconname pager \
    --handshakepath /root/loot/handshakes/ \
    --handshakes=true \
    --partialhandshakes=true \
    --interface wlan1mon \
    --band wlan1mon:2,5 \
    --type wlan1mon:max \
    --hop wlan1mon:fast \
    --primary wlan1mon \
    --inject wlan1mon &
PINEAPD_PID=$!
sleep 2

# Verify pineapd started
if kill -0 $PINEAPD_PID 2>/dev/null; then
    LOG "green" "pineapd started with handshake capture (PID: $PINEAPD_PID)"
else
    LOG "red" "Warning: pineapd may not have started correctly"
fi

# Detect and setup GPS if available
LOG "Detecting GPS device..."
GPS_DEVICE=$(uci -q get gpsd.core.device 2>/dev/null)
if [ -n "$GPS_DEVICE" ] && [ -e "$GPS_DEVICE" ]; then
    LOG "green" "GPS detected: $GPS_DEVICE"
    LOG "Restarting gpsd..."
    /etc/init.d/gpsd restart 2>/dev/null
    sleep 2
else
    LOG "No GPS device detected (optional)"
fi

sleep 0.5

# Payload loop — PagerGotchi can hand off to other apps via exit code 42
# Python writes the target launch script path to data/.next_payload
# No pineapplepager restart needed between switches
NEXT_PAYLOAD_FILE="$DATA_DIR/.next_payload"

while true; do
    cd "$PAYLOAD_DIR"
    python3 run_pagergotchi.py
    EXIT_CODE=$?

    # Cleanup pagergotchi processes
    killall hcxdumptool 2>/dev/null
    if [ -n "$PINEAPD_PID" ]; then
        kill $PINEAPD_PID 2>/dev/null
        PINEAPD_PID=""
    fi
    killall pineapd 2>/dev/null

    # Exit code 42 = hand off to another payload
    if [ "$EXIT_CODE" -eq 42 ] && [ -f "$NEXT_PAYLOAD_FILE" ]; then
        NEXT_SCRIPT=$(cat "$NEXT_PAYLOAD_FILE")
        rm -f "$NEXT_PAYLOAD_FILE"

        if [ -f "$NEXT_SCRIPT" ]; then
            bash "$NEXT_SCRIPT"
            # Only loop back to pagergotchi if launched app exits 42
            [ $? -eq 42 ] && continue
        fi
    fi

    break
done

sleep 1

# Restore services on final exit
/etc/init.d/pineapd start 2>/dev/null &
/etc/init.d/php8-fpm start 2>/dev/null &
/etc/init.d/nginx start 2>/dev/null &
/etc/init.d/bluetoothd start 2>/dev/null &
/etc/init.d/pineapplepager start 2>/dev/null &
