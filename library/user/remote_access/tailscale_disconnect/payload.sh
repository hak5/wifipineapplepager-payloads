#!/bin/bash
# Title: Tailscale Disconnect
# Description: Disconnect from Tailscale network
# Author: JAKONL
# Version: 1.0

LOG "=== Tailscale Disconnect ==="

# ============================================
# CONFIGURATION
# ============================================

INSTALL_DIR="/usr/sbin"
TAILSCALE="$INSTALL_DIR/tailscale"

# ============================================
# MAIN
# ============================================

if [ ! -f "$TAILSCALE" ]; then
    ERROR_DIALOG "Tailscale not installed"
    LOG red "ERROR: Tailscale is not installed"
    exit 1
fi

# Confirm disconnection
resp=$(CONFIRMATION_DIALOG "Disconnect from Tailscale?")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG "Disconnect cancelled"
        exit 0
        ;;
esac

case "$resp" in
    $DUCKYSCRIPT_USER_CONFIRMED)
        LOG "Disconnecting from Tailscale network..."
        
        spinner_id=$(START_SPINNER "Disconnecting")
        
        # Disconnect
        output=$("$TAILSCALE" down 2>&1)
        result=$?
        
        STOP_SPINNER $spinner_id
        
        if [ $result -eq 0 ]; then
            ALERT "Disconnected"
            LOG green "Successfully disconnected from Tailscale"
        else
            ERROR_DIALOG "Disconnect failed"
            LOG red "ERROR: Failed to disconnect"
            LOG "$output"
            exit 1
        fi
        ;;
    $DUCKYSCRIPT_USER_DENIED)
        LOG "User cancelled disconnect"
        ALERT "Disconnect cancelled"
        exit 0
        ;;
    *)
        LOG "ERROR: Unknown response: $resp"
        ERROR_DIALOG "Unknown response"
        exit 1
        ;;
esac

LOG "=== Disconnect Complete ==="

