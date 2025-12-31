#!/bin/bash
# Title: Tailscale Status
# Description: Show Tailscale connection status
# Author: JAKONL
# Version: 1.0
# Category: Remote-Access

LOG "=== Tailscale Status ==="

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

LOG "Checking Tailscale status..."

# Get status
status_output=$("$TAILSCALE" status 2>&1)
status_code=$?

if [ $status_code -ne 0 ]; then
    ERROR_DIALOG "Failed to get status"
    LOG red "ERROR: Could not get Tailscale status"
    LOG "$status_output"
    exit 1
fi

# Get IP address
ip_output=$("$TAILSCALE" ip -4 2>&1)
tailscale_ip=$(echo "$ip_output" | head -n 1)

# Check if connected
if echo "$status_output" | grep -q "stopped"; then
    ALERT "Tailscale: Stopped"
    LOG yellow "Status: Stopped"
    LOG "Tailscale is not running"
elif echo "$status_output" | grep -q "NeedsLogin"; then
    ALERT "Tailscale: Needs Login"
    LOG yellow "Status: Needs Authentication"
    LOG "Run Tailscale Installer to authenticate"
else
    ALERT "Connected: $tailscale_ip"
    LOG green "Status: Connected"
    LOG "Tailscale IP: $tailscale_ip"
fi

# Log full status
LOG "--- Full Status ---"
echo "$status_output" | while IFS= read -r line; do
    LOG "$line"
done

# Show network info
LOG "--- Network Info ---"
netmap=$("$TAILSCALE" netmap 2>&1)
if [ $? -eq 0 ]; then
    echo "$netmap" | head -n 10 | while IFS= read -r line; do
        LOG "$line"
    done
else
    LOG "Network map not available"
fi

LOG "=== Status Check Complete ==="

