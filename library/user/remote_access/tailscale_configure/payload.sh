#!/bin/bash
# Title: Tailscale Configuration
# Description: Configure Tailscale after installation
# Author: JAKONL
# Version: 1.0

LOG "=== Tailscale Configuration ==="

# ============================================
# CONFIGURATION
# ============================================

INSTALL_DIR="/usr/sbin"
INIT_SCRIPT="/etc/init.d/tailscaled"
CONFIG_DIR="/etc/tailscale"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_DIR="/root/.tailscale"

# ============================================
# HELPER FUNCTIONS
# ============================================

save_config() {
    local auto_start="$1"

    cat > "$CONFIG_FILE" << EOF
# Tailscale Configuration
AUTO_START=$auto_start
CONFIGURED_DATE=$(date)
EOF

    LOG "Configuration saved"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

start_tailscaled() {
    LOG "Starting tailscaled daemon..."
    
    # Create socket directory
    mkdir -p /var/run/tailscale
    
    # Start the daemon
    if ! "$INIT_SCRIPT" start; then
        ERROR_DIALOG "Failed to start tailscaled"
        LOG "ERROR: Could not start tailscaled service"
        return 1
    fi
    
    # Wait for daemon to be ready
    sleep 3
    
    LOG "Tailscaled started successfully"
    return 0
}

authenticate_interactive() {
    LOG "Starting interactive authentication..."

    # Create a temporary file for output
    local tmp_output="/tmp/tailscale_auth_output.txt"

    # Run tailscale login in background and capture output
    LOG "Running: tailscale login"
    "$INSTALL_DIR/tailscale" login > "$tmp_output" 2>&1 &
    local tailscale_pid=$!

    LOG "Waiting for authentication URL..."

    # Wait for the auth URL to appear in output (no spinner - quick operation)
    local auth_url=""
    local max_wait=30
    local waited=0

    while [ $waited -lt $max_wait ]; do
        if [ -f "$tmp_output" ]; then
            # Check if already authenticated
            if grep -q "Success" "$tmp_output" 2>/dev/null; then
                LOG "Device is already authenticated"
                rm -f "$tmp_output"
                return 0
            fi

            # Look for auth URL
            auth_url=$(grep -o 'https://login.tailscale.com/a/[a-zA-Z0-9]*' "$tmp_output" 2>/dev/null | head -n 1)

            if [ -n "$auth_url" ]; then
                break
            fi
        fi

        sleep 1
        waited=$((waited + 1))
    done

    if [ -z "$auth_url" ]; then
        # Check if process failed
        if ! kill -0 $tailscale_pid 2>/dev/null; then
            ERROR_DIALOG "Authentication failed"
            LOG "ERROR: tailscale login process exited unexpectedly"
            if [ -f "$tmp_output" ]; then
                LOG "Output:"
                cat "$tmp_output" 2>&1 | while read line; do LOG "$line"; done
                rm -f "$tmp_output"
            fi
            return 1
        fi

        ERROR_DIALOG "Could not get auth URL"
        LOG "ERROR: No authentication URL found after ${max_wait}s"
        if [ -f "$tmp_output" ]; then
            LOG "Output:"
            cat "$tmp_output" 2>&1 | while read line; do LOG "$line"; done
        fi
        kill $tailscale_pid 2>/dev/null
        rm -f "$tmp_output"
        return 1
    fi

    # Display the authentication URL clearly
    LOG ""
    LOG "=========================================="
    LOG "AUTHENTICATION REQUIRED"
    LOG "=========================================="
    LOG ""
    LOG "Visit this URL on another device:"
    LOG ""
    LOG "  $auth_url"
    LOG ""
    LOG "=========================================="
    LOG ""
    LOG "Waiting for you to complete authentication..."
    LOG "Do NOT press any buttons - authentication will complete automatically"
    LOG ""

    max_wait=300  # 5 minutes - give user plenty of time
    waited=0
    local auth_success=false

    while [ $waited -lt $max_wait ]; do
        # Check if tailscale login process completed
        if ! kill -0 $tailscale_pid 2>/dev/null; then
            # Process finished, check if successful
            if "$INSTALL_DIR/tailscale" status >/dev/null 2>&1; then
                auth_success=true
                break
            else
                # Process ended but not authenticated - error
                ERROR_DIALOG "Authentication failed"
                LOG "ERROR: tailscale login completed but device not authenticated"
                if [ -f "$tmp_output" ]; then
                    LOG "Output:"
                    cat "$tmp_output" 2>&1 | while read line; do LOG "$line"; done
                fi
                rm -f "$tmp_output"
                return 1
            fi
        fi

        sleep 5
        waited=$((waited + 5))
    done

    if [ "$auth_success" = true ]; then
        LOG "Authentication completed successfully"
        rm -f "$tmp_output"

        # Now bring up the Tailscale connection
        LOG "Starting Tailscale connection..."
        if ! "$INSTALL_DIR/tailscale" up 2>&1 | while read line; do LOG "$line"; done; then
            ERROR_DIALOG "Failed to start Tailscale"
            LOG red "ERROR: tailscale up failed after authentication"
            return 1
        fi

        LOG green "Tailscale connection established"
        return 0
    else
        ERROR_DIALOG "Authentication timeout (5 min)"
        LOG "ERROR: Authentication timed out after ${max_wait}s"
        LOG "Please complete authentication at: $auth_url"

        # Kill the background process
        kill $tailscale_pid 2>/dev/null
        rm -f "$tmp_output"
        return 1
    fi
}



show_status() {
    LOG "Getting Tailscale status..."

    local status=$("$INSTALL_DIR/tailscale" status 2>&1)
    local ip=$("$INSTALL_DIR/tailscale" ip -4 2>/dev/null | head -n 1)

    if [ -n "$ip" ]; then
        LOG ""
        LOG "=========================================="
        LOG "✓ AUTHENTICATION SUCCESSFUL!"
        LOG "=========================================="
        LOG ""
        LOG "Your Tailscale IP Address: $ip"
        LOG ""
        LOG "Full status:"
        LOG "$status"
        LOG ""

        # Show IP once in PROMPT only - user must acknowledge to exit
        PROMPT "Tailscale IP: $ip - Press OK to exit"
    else
        LOG "Status: $status"
        PROMPT "Tailscale connected - Press OK to exit"
    fi
}

# ============================================
# MAIN CONFIGURATION
# ============================================

main_configure() {
    LOG "=== Tailscale Configuration Started ==="

    # Check if already configured
    if load_config; then
        LOG "Tailscale is already configured"

        # Try to get current IP address
        local current_ip=$("$INSTALL_DIR/tailscale" ip -4 2>/dev/null | head -n 1)

        if [ -n "$current_ip" ]; then
            LOG "Current Tailscale IP: $current_ip"
            LOG ""

            # Show current IP and ask if they want to reconfigure
            resp=$(CONFIRMATION_DIALOG "Current IP: $current_ip - Reconfigure?")
        else
            LOG "Tailscale configured but no IP found (may not be connected)"
            LOG ""

            # No IP available, just ask about reconfiguration
            resp=$(CONFIRMATION_DIALOG "Reconfigure Tailscale?")
        fi

        case $? in
            $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                LOG "Configuration cancelled"
                exit 0
                ;;
        esac

        case "$resp" in
            $DUCKYSCRIPT_USER_DENIED)
                LOG "User chose not to reconfigure"

                # If we have an IP, show it before exiting
                if [ -n "$current_ip" ]; then
                    PROMPT "Current IP: $current_ip - Press OK to exit"
                fi

                exit 0
                ;;
        esac

        LOG "User chose to reconfigure Tailscale"
    fi
    
    # Ask about auto-start
    resp=$(CONFIRMATION_DIALOG "Enable auto-start at boot?")
    local auto_start="no"
    case "$resp" in
        $DUCKYSCRIPT_USER_CONFIRMED)
            auto_start="yes"
            "$INIT_SCRIPT" enable
            LOG "Auto-start enabled"
            ;;
        *)
            "$INIT_SCRIPT" disable
            LOG "Auto-start disabled"
            ;;
    esac
    
    # Start the daemon
    if ! start_tailscaled; then
        exit 1
    fi

    # Perform interactive authentication
    LOG ""
    LOG green "Starting authentication..."
    LOG ""

    if ! authenticate_interactive; then
        exit 1
    fi

    # Save configuration
    save_config "$auto_start"

    # Show status (includes user prompt to exit)
    show_status

    LOG "=== Configuration Complete ==="
}

# Execute configuration
main_configure

