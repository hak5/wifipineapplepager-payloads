#!/bin/bash
# Title: 1988
# Description: persistent background listener that will trigger an easter egg link, lights, and sound when the OG code is entered
# Author: m0usem0use
# Version: 1
# Device: WiFi Pineapple Pager

# --- Robust Path Finding ---
# 1. Try relative path (standard)
SOURCE_DIR=$(cd "$(dirname "$0")" && pwd)
LISTENER_SOURCE="$SOURCE_DIR/listener.sh"

# 2. Fallback: If not found, check the standard user payload path
if [ ! -f "$LISTENER_SOURCE" ]; then
    # Common location for user games
    FALLBACK_PATH="/root/payloads/user/games/1988/listener.sh"
    if [ -f "$FALLBACK_PATH" ]; then
        LISTENER_SOURCE="$FALLBACK_PATH"
        SOURCE_DIR="/root/payloads/user/games/1988"
    else
        # 3. Fallback: Check if we are running FROM the mmc (manual install case)
        FALLBACK_MMC="/mmc/root/1988/listener.sh"
        if [ -f "$FALLBACK_MMC" ]; then
            LISTENER_SOURCE="$FALLBACK_MMC"
            SOURCE_DIR="/mmc/root/1988"
        fi
    fi
fi

# --- Config ---
INSTALL_DIR="/mmc/root/1988"
LISTENER_DEST="$INSTALL_DIR/listener.sh"
RC_LOCAL="/etc/rc.local"

# --- Helper Functions ---

is_installed() {
    if grep -q "$LISTENER_DEST" "$RC_LOCAL"; then
        return 0
    else
        return 1
    fi
}

start_listener() {
    $LISTENER_DEST > /dev/null 2>&1 &
}

stop_listener() {
    killall listener.sh > /dev/null 2>&1
    pkill -f "$LISTENER_DEST" > /dev/null 2>&1
}

# --- Main Logic ---

LED SETUP

if is_installed; then
    # === UNINSTALL ===
    if [ "$(CONFIRMATION_DIALOG "1988 Active. Uninstall?")" == "1" ]; then
        LED FAIL
        stop_listener
        sed -i "\|$LISTENER_DEST|d" "$RC_LOCAL"
        rm -rf "$INSTALL_DIR"
        ALERT "1988 Uninstalled."
        exit 0
    fi
else
    # === INSTALL ===
    if [ "$(CONFIRMATION_DIALOG "Install Listener?")" == "1" ]; then
        LED SPECIAL
        
        # Verify source exists
        if [ ! -f "$LISTENER_SOURCE" ]; then
            ERROR_DIALOG "Err: listener.sh not found!"
            LOG "looked in: $SOURCE_DIR"
            exit 1
        fi
        
        mkdir -p "$INSTALL_DIR"
        cp "$LISTENER_SOURCE" "$LISTENER_DEST"
        chmod +x "$LISTENER_DEST"
        
        if ! grep -q "$LISTENER_DEST" "$RC_LOCAL"; then
            sed -i "/exit 0/i $LISTENER_DEST &" "$RC_LOCAL"
        fi
        
        start_listener
        LOG "********************************"
        LOG "UP UP DOWN DOWN"
        LOG "LEFT RIGHT LEFT RIGHT"
        LOG "B A START!"
        LOG "********************************"
        ALERT "Installed!"
        exit 0
    fi
fi

LED OFF
exit 0