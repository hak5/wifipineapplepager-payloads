#!/bin/bash
# ============================================================================
# Title: Quick Clone Pro
# Description: Clone AP with SSID + MAC, persistent Open AP configuration
# Author: Aitema-GmbH
# Version: 2.0
# Category: recon/access_point
# Target: WiFi Pineapple Pager
# ============================================================================
#
# Features:
#   - Clone SSID from selected AP in Recon
#   - Clone MAC address (BSSID) for full impersonation
#   - Persistent configuration via UCI (survives reboot)
#   - Configure Open AP directly (not just SSID Pool)
#   - Option to also add to SSID Pool
#
# This is the "proper" way - changes are written to the Pineapple's config
# and appear in the Open AP menu after the payload exits.
#
# ============================================================================

shopt -s nullglob

# =========================
# ENVIRONMENT VARIABLES
# =========================
TARGET_SSID="$_RECON_SELECTED_AP_SSID"
TARGET_BSSID="$_RECON_SELECTED_AP_BSSID"
TARGET_CHANNEL="$_RECON_SELECTED_AP_CHANNEL"

# Open AP Interface
OPEN_AP_IFACE="wlan0open"

# =========================
# CLEANUP
# =========================
cleanup() {
    LED SETUP
}
trap cleanup EXIT INT TERM

# =========================
# FUNCTIONS
# =========================

get_current_config() {
    CURRENT_SSID=$(uci get wireless.wlan0open.ssid 2>/dev/null)
    CURRENT_MAC=$(uci get wireless.wlan0open.macaddr 2>/dev/null)
    CURRENT_STATE=$(uci get wireless.wlan0open.disabled 2>/dev/null)
}

set_open_ap() {
    local ssid="$1"
    local mac="$2"

    # Set SSID
    uci set wireless.wlan0open.ssid="$ssid"

    # Set MAC if provided
    if [ -n "$mac" ]; then
        uci set wireless.wlan0open.macaddr="$mac"
    fi

    # Enable Open AP
    uci set wireless.wlan0open.disabled='0'

    # Commit to flash
    uci commit wireless

    # Apply changes
    wifi reload
}

restore_original() {
    if [ -f "/tmp/quickclone_backup_ssid" ]; then
        local orig_ssid=$(cat /tmp/quickclone_backup_ssid)
        local orig_mac=$(cat /tmp/quickclone_backup_mac 2>/dev/null)

        uci set wireless.wlan0open.ssid="$orig_ssid"
        [ -n "$orig_mac" ] && uci set wireless.wlan0open.macaddr="$orig_mac"
        uci commit wireless
        wifi reload

        rm -f /tmp/quickclone_backup_*
        LOG green "Original config restored"
    fi
}

# =========================
# VALIDATION
# =========================
if [ -z "$TARGET_SSID" ] || [ -z "$TARGET_BSSID" ]; then
    LED FAIL
    ERROR_DIALOG "No AP Selected!\n\nGo to Recon, select an\nAccess Point, then run\nthis payload."
    exit 1
fi

# =========================
# MAIN
# =========================

LED SETUP

# Get current config
get_current_config

LOG cyan "=========================================="
LOG cyan "  QUICK CLONE PRO"
LOG cyan "=========================================="
LOG ""
LOG "Target Network:"
LOG "  SSID: $TARGET_SSID"
LOG "  MAC:  $TARGET_BSSID"
LOG "  CH:   $TARGET_CHANNEL"
LOG ""
LOG "Current Open AP:"
LOG "  SSID: $CURRENT_SSID"
LOG "  MAC:  $CURRENT_MAC"
LOG ""

# Step 1: Confirm clone
RESP=$(CONFIRMATION_DIALOG "Clone this network?\n\nSSID: $TARGET_SSID\nMAC: $TARGET_BSSID\n\nWill configure Open AP")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
        LOG yellow "Cancelled"
        exit 0
        ;;
    $DUCKYSCRIPT_ERROR)
        LED FAIL
        ERROR_DIALOG "Dialog error"
        exit 1
        ;;
esac

case "$RESP" in
    "$DUCKYSCRIPT_USER_DENIED")
        LOG yellow "User declined"
        exit 0
        ;;
esac

# Step 2: Ask about MAC cloning
RESP=$(CONFIRMATION_DIALOG "Also clone MAC address?\n\n[Yes] = Full clone (SSID+MAC)\n[No] = SSID only")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
        LOG yellow "Cancelled"
        exit 0
        ;;
esac

CLONE_MAC=0
case "$RESP" in
    "$DUCKYSCRIPT_USER_CONFIRMED")
        CLONE_MAC=1
        LOG "MAC cloning: YES"
        ;;
    *)
        LOG "MAC cloning: NO"
        ;;
esac

# Step 3: Ask about SSID Pool
RESP=$(CONFIRMATION_DIALOG "Also add to SSID Pool?\n\n[Yes] = Adds for future use\n[No] = Open AP only")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
        LOG yellow "Cancelled"
        exit 0
        ;;
esac

ADD_TO_POOL=0
case "$RESP" in
    "$DUCKYSCRIPT_USER_CONFIRMED")
        ADD_TO_POOL=1
        LOG "Add to pool: YES"
        ;;
    *)
        LOG "Add to pool: NO"
        ;;
esac

LOG ""

# Backup current config
echo "$CURRENT_SSID" > /tmp/quickclone_backup_ssid
echo "$CURRENT_MAC" > /tmp/quickclone_backup_mac

LED ATTACK
LOG yellow "Applying configuration..."
LOG ""

# Apply Open AP config
if [ "$CLONE_MAC" -eq 1 ]; then
    LOG "Setting SSID: $TARGET_SSID"
    LOG "Setting MAC:  $TARGET_BSSID"
    set_open_ap "$TARGET_SSID" "$TARGET_BSSID"
else
    LOG "Setting SSID: $TARGET_SSID"
    set_open_ap "$TARGET_SSID" ""
fi

sleep 2

# Add to SSID Pool if requested
if [ "$ADD_TO_POOL" -eq 1 ]; then
    LOG "Adding to SSID Pool..."
    PINEAPPLE_SSID_POOL_ADD "$TARGET_SSID"
    sleep 1
fi

LED FINISH
VIBRATE

LOG ""
LOG green "=========================================="
LOG green "  CLONE COMPLETE"
LOG green "=========================================="
LOG ""
LOG "Open AP now configured as:"
LOG "  SSID: $TARGET_SSID"
[ "$CLONE_MAC" -eq 1 ] && LOG "  MAC:  $TARGET_BSSID"
LOG ""
LOG cyan "Configuration is PERSISTENT!"
LOG cyan "Check: Settings > Open AP"
LOG ""

# Show result
if [ "$CLONE_MAC" -eq 1 ]; then
    ALERT "Clone Complete!\n\nOpen AP configured:\nSSID: $TARGET_SSID\nMAC: $TARGET_BSSID\n\nPersistent - check Open AP menu"
else
    ALERT "Clone Complete!\n\nOpen AP configured:\nSSID: $TARGET_SSID\n\nPersistent - check Open AP menu"
fi

# Ask if user wants to restore later
RESP=$(CONFIRMATION_DIALOG "Restore original config\nwhen done testing?\n\n[Yes] = Restore now\n[No] = Keep new config")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
        exit 0
        ;;
esac

case "$RESP" in
    "$DUCKYSCRIPT_USER_CONFIRMED")
        LED ATTACK
        LOG "Restoring original config..."
        restore_original
        LED FINISH
        ALERT "Original config restored!\n\nSSID: $CURRENT_SSID"
        ;;
    *)
        LOG "Keeping new configuration"
        rm -f /tmp/quickclone_backup_*
        ;;
esac

exit 0
