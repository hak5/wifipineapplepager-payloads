#!/bin/bash
# Title: Tailscale Connect
# Description: Connect to Tailscale network
# Author: JAKONL
# Version: 1.0

LOG "=== Tailscale Connect ==="

# ============================================
# CONFIGURATION
# ============================================

INSTALL_DIR="/usr/sbin"
TAILSCALE="$INSTALL_DIR/tailscale"
TAILSCALED="$INSTALL_DIR/tailscaled"
INIT_SCRIPT="/etc/init.d/tailscaled"

# ============================================
# MAIN
# ============================================

if [ ! -f "$TAILSCALE" ]; then
    ERROR_DIALOG "Tailscale not installed"
    LOG red "ERROR: Tailscale is not installed"
    exit 1
fi

LOG "Starting Tailscale connection..."

# Start tailscaled if not running
if ! pgrep tailscaled > /dev/null; then
    LOG "Starting tailscaled daemon..."
    if [ -f "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" start
    else
        "$TAILSCALED" --state=/root/.tailscale/tailscaled.state --statedir=/root/.tailscale/ --socket=/var/run/tailscale/tailscaled.sock &
    fi
    sleep 3
fi

LOG "Connecting to Tailscale network..."

# Connect using tailscale up
spinner_id=$(START_SPINNER "Connecting")
output=$("$TAILSCALE" up 2>&1)
result=$?

# Extract auth URL if present
auth_url=$(echo "$output" | grep -o 'https://login.tailscale.com/a/[a-zA-Z0-9]*')

if [ -n "$auth_url" ]; then
    STOP_SPINNER $spinner_id
    LOG "Authentication required"
    LOG "Auth URL: $auth_url"

    # Show shortened URL
    url_code=$(echo "$auth_url" | sed 's|https://login.tailscale.com/a/||')
    ALERT "Auth needed - check logs"
    PROMPT "Code: $url_code - Press button"

    # Wait for auth
    spinner_id=$(START_SPINNER "Waiting for auth")
    sleep 30
fi

STOP_SPINNER $spinner_id

# Check result
if [ $result -eq 0 ] || echo "$output" | grep -q "Success"; then
    # Get IP
    ip=$("$TAILSCALE" ip -4 2>&1 | head -n 1)
    ALERT "Connected: $ip"
    LOG green "Successfully connected to Tailscale"
    LOG "Tailscale IP: $ip"
else
    ERROR_DIALOG "Connection failed"
    LOG red "ERROR: Failed to connect"
    LOG "$output"
    exit 1
fi

LOG "=== Connection Complete ==="

