#!/bin/bash
# Title: Tailscale Uninstaller
# Description: Remove Tailscale from device
# Author: JAKONL
# Version: 1.0
# Category: Remote-Access

LOG "=== Tailscale Uninstaller ==="
LOG "Preparing to uninstall Tailscale..."

# ============================================
# CONFIGURATION
# ============================================

INSTALL_DIR="/usr/sbin"
INIT_SCRIPT="/etc/init.d/tailscaled"
CONFIG_DIR="/etc/tailscale"
STATE_DIR="/root/.tailscale"
RUN_DIR="/var/run/tailscale"

# ============================================
# FUNCTIONS
# ============================================

check_installed() {
    if [ ! -f "$INSTALL_DIR/tailscale" ] && [ ! -f "$INSTALL_DIR/tailscaled" ]; then
        return 1
    fi
    return 0
}

uninstall_tailscale() {
    LOG "Stopping Tailscale service..."
    
    # Stop and disable service if it exists
    if [ -f "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" stop 2>/dev/null
        "$INIT_SCRIPT" disable 2>/dev/null
        LOG "Service stopped and disabled"
    fi
    
    # Disconnect from network
    if [ -f "$INSTALL_DIR/tailscale" ]; then
        LOG "Disconnecting from Tailscale network..."
        "$INSTALL_DIR/tailscale" down 2>/dev/null
    fi
    
    LOG "Removing Tailscale files..."
    
    # Remove binaries
    rm -f "$INSTALL_DIR/tailscale"
    rm -f "$INSTALL_DIR/tailscaled"
    LOG "Binaries removed"
    
    # Remove init script
    rm -f "$INIT_SCRIPT"
    LOG "Init script removed"
    
    # Remove configuration and state
    rm -rf "$CONFIG_DIR"
    rm -rf "$STATE_DIR"
    rm -rf "$RUN_DIR"
    LOG "Configuration and state removed"
    
    return 0
}

# ============================================
# MAIN
# ============================================

main_uninstall() {
    LOG "=== Tailscale Uninstallation Started ==="
    
    # Check if Tailscale is installed
    if ! check_installed; then
        ALERT "Tailscale not installed"
        LOG "Tailscale is not installed on this device"
        exit 0
    fi
    
    # Confirm uninstallation
    resp=$(CONFIRMATION_DIALOG "Uninstall Tailscale?")
    case $? in
        $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            LOG "Uninstall cancelled"
            ALERT "Uninstall cancelled"
            exit 0
            ;;
    esac
    
    case "$resp" in
        $DUCKYSCRIPT_USER_CONFIRMED)
            LOG "User confirmed uninstallation"
            
            # Show warning about data loss
            resp2=$(CONFIRMATION_DIALOG "This will remove all Tailscale data. Continue?")
            case $? in
                $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                    LOG "Uninstall cancelled at warning"
                    ALERT "Uninstall cancelled"
                    exit 0
                    ;;
            esac
            
            case "$resp2" in
                $DUCKYSCRIPT_USER_CONFIRMED)
                    LOG "Proceeding with uninstallation..."
                    
                    # Perform uninstallation
                    spinner_id=$(START_SPINNER "Uninstalling")
                    
                    if uninstall_tailscale; then
                        STOP_SPINNER $spinner_id
                        ALERT "Tailscale uninstalled!"
                        LOG "=== Uninstallation Complete ==="
                        LOG green "Tailscale has been completely removed"
                    else
                        STOP_SPINNER $spinner_id
                        ERROR_DIALOG "Uninstall failed"
                        LOG red "ERROR: Uninstallation failed"
                        exit 1
                    fi
                    ;;
                $DUCKYSCRIPT_USER_DENIED)
                    LOG "User cancelled at final confirmation"
                    ALERT "Uninstall cancelled"
                    exit 0
                    ;;
                *)
                    LOG "ERROR: Unknown response: $resp2"
                    ERROR_DIALOG "Unknown response"
                    exit 1
                    ;;
            esac
            ;;
        $DUCKYSCRIPT_USER_DENIED)
            LOG "User declined uninstallation"
            ALERT "Uninstall cancelled"
            exit 0
            ;;
        *)
            LOG "ERROR: Unknown response: $resp"
            ERROR_DIALOG "Unknown response"
            exit 1
            ;;
    esac
}

# Execute uninstallation
main_uninstall

