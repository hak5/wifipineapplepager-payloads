#!/bin/bash
# Name: Interface Manager
# Description: Displays interface status and manages interface activation
# Author: PentestPlaybook
# Version: 1.4
# Category: Evil Portal

bring_up_interface() {
    IFACE=$1
    IFACE_NAME=$2

    # Save any pending SSID/key changes before committing
    PENDING_SSID_WPA=$(uci changes wireless | grep "^wireless\.wlan0wpa\.ssid=" | cut -d= -f2- | tr -d "'" | tail -1)
    PENDING_KEY_WPA=$(uci changes wireless | grep "^wireless\.wlan0wpa\.key=" | cut -d= -f2- | tr -d "'" | tail -1)
    PENDING_SSID_OPEN=$(uci changes wireless | grep "^wireless\.wlan0open\.ssid=" | cut -d= -f2- | tr -d "'" | tail -1)
    PENDING_KEY_OPEN=$(uci changes wireless | grep "^wireless\.wlan0open\.key=" | cut -d= -f2- | tr -d "'" | tail -1)
    PENDING_SSID_MGMT=$(uci changes wireless | grep "^wireless\.wlan0mgmt\.ssid=" | cut -d= -f2- | tr -d "'" | tail -1)
    PENDING_KEY_MGMT=$(uci changes wireless | grep "^wireless\.wlan0mgmt\.key=" | cut -d= -f2- | tr -d "'" | tail -1)

    # Revert all pending SSID/key changes from the buffer
    [ -n "$PENDING_SSID_WPA" ] && uci revert wireless.wlan0wpa.ssid
    [ -n "$PENDING_KEY_WPA" ] && uci revert wireless.wlan0wpa.key
    [ -n "$PENDING_SSID_OPEN" ] && uci revert wireless.wlan0open.ssid
    [ -n "$PENDING_KEY_OPEN" ] && uci revert wireless.wlan0open.key
    [ -n "$PENDING_SSID_MGMT" ] && uci revert wireless.wlan0mgmt.ssid
    [ -n "$PENDING_KEY_MGMT" ] && uci revert wireless.wlan0mgmt.key

    LOG "Bringing up ${IFACE_NAME}..."
    uci set wireless.${IFACE}.disabled='0'
    uci commit wireless

    # Re-stage all pending SSID/key changes without committing
    [ -n "$PENDING_SSID_WPA" ] && uci set wireless.wlan0wpa.ssid="$PENDING_SSID_WPA"
    [ -n "$PENDING_KEY_WPA" ] && uci set wireless.wlan0wpa.key="$PENDING_KEY_WPA"
    [ -n "$PENDING_SSID_OPEN" ] && uci set wireless.wlan0open.ssid="$PENDING_SSID_OPEN"
    [ -n "$PENDING_KEY_OPEN" ] && uci set wireless.wlan0open.key="$PENDING_KEY_OPEN"
    [ -n "$PENDING_SSID_MGMT" ] && uci set wireless.wlan0mgmt.ssid="$PENDING_SSID_MGMT"
    [ -n "$PENDING_KEY_MGMT" ] && uci set wireless.wlan0mgmt.key="$PENDING_KEY_MGMT"

    wifi reload
    sleep 35

    # Reload wifi if any values were restaged so interfaces reflect pending changes
    if [ -n "$PENDING_SSID_WPA" ] || [ -n "$PENDING_KEY_WPA" ] || \
       [ -n "$PENDING_SSID_OPEN" ] || [ -n "$PENDING_KEY_OPEN" ] || \
       [ -n "$PENDING_SSID_MGMT" ] || [ -n "$PENDING_KEY_MGMT" ]; then
        wifi reload
    fi

    LOG "${IFACE_NAME} is back up"
    LOG ""
}

disable_interface() {
    LOG "Info: Networking will be restarted."

    # Build menu with Evil Portal indicator
    WPA_EP=""
    OPEN_EP=""

    uci show wireless.wlan0wpa.network 2>/dev/null | grep -q "evil" && WPA_EP=" (Evil Portal)"
    uci show wireless.wlan0open.network 2>/dev/null | grep -q "evil" && OPEN_EP=" (Evil Portal)"

    MENU="Select interface to disable:\n\n"
    MENU="${MENU}1) Evil WPA${WPA_EP}\n"
    MENU="${MENU}2) Open AP${OPEN_EP}\n"
    MENU="${MENU}3) Management"

    LOG "$MENU"
    LOG "Press 'A' button to select."
    WAIT_FOR_BUTTON_PRESS A

    CHOICE=$(NUMBER_PICKER "Enter interface number" "")
    if [ $? -ne 0 ]; then
        exit 0
    fi

    case "$CHOICE" in
        1)
            SELECTED_IFACE="wlan0wpa"
            SELECTED_NAME="Evil WPA"
            ;;
        2)
            SELECTED_IFACE="wlan0open"
            SELECTED_NAME="Open AP"
            ;;
        3)
            SELECTED_IFACE="wlan0mgmt"
            SELECTED_NAME="Management"
            ;;
        *)
            ERROR_DIALOG "Invalid selection"
            exit 1
            ;;
    esac

    # Save any pending SSID/key changes before committing
    PENDING_SSID_WPA=$(uci changes wireless | grep "^wireless\.wlan0wpa\.ssid=" | cut -d= -f2- | tr -d "'" | tail -1)
    PENDING_KEY_WPA=$(uci changes wireless | grep "^wireless\.wlan0wpa\.key=" | cut -d= -f2- | tr -d "'" | tail -1)
    PENDING_SSID_OPEN=$(uci changes wireless | grep "^wireless\.wlan0open\.ssid=" | cut -d= -f2- | tr -d "'" | tail -1)
    PENDING_KEY_OPEN=$(uci changes wireless | grep "^wireless\.wlan0open\.key=" | cut -d= -f2- | tr -d "'" | tail -1)
    PENDING_SSID_MGMT=$(uci changes wireless | grep "^wireless\.wlan0mgmt\.ssid=" | cut -d= -f2- | tr -d "'" | tail -1)
    PENDING_KEY_MGMT=$(uci changes wireless | grep "^wireless\.wlan0mgmt\.key=" | cut -d= -f2- | tr -d "'" | tail -1)

    # Revert all pending SSID/key changes from the buffer
    [ -n "$PENDING_SSID_WPA" ] && uci revert wireless.wlan0wpa.ssid
    [ -n "$PENDING_KEY_WPA" ] && uci revert wireless.wlan0wpa.key
    [ -n "$PENDING_SSID_OPEN" ] && uci revert wireless.wlan0open.ssid
    [ -n "$PENDING_KEY_OPEN" ] && uci revert wireless.wlan0open.key
    [ -n "$PENDING_SSID_MGMT" ] && uci revert wireless.wlan0mgmt.ssid
    [ -n "$PENDING_KEY_MGMT" ] && uci revert wireless.wlan0mgmt.key

    LOG "Disabling ${SELECTED_NAME}..."
    uci set wireless.${SELECTED_IFACE}.disabled='1'
    uci commit wireless

    # Re-stage all pending SSID/key changes without committing
    [ -n "$PENDING_SSID_WPA" ] && uci set wireless.wlan0wpa.ssid="$PENDING_SSID_WPA"
    [ -n "$PENDING_KEY_WPA" ] && uci set wireless.wlan0wpa.key="$PENDING_KEY_WPA"
    [ -n "$PENDING_SSID_OPEN" ] && uci set wireless.wlan0open.ssid="$PENDING_SSID_OPEN"
    [ -n "$PENDING_KEY_OPEN" ] && uci set wireless.wlan0open.key="$PENDING_KEY_OPEN"
    [ -n "$PENDING_SSID_MGMT" ] && uci set wireless.wlan0mgmt.ssid="$PENDING_SSID_MGMT"
    [ -n "$PENDING_KEY_MGMT" ] && uci set wireless.wlan0mgmt.key="$PENDING_KEY_MGMT"

    LOG "Restarting Networking..."
    /etc/init.d/network restart
    sleep 10
    wifi
    sleep 35

    # Reload wifi if any values were restaged so interfaces reflect pending changes
    if [ -n "$PENDING_SSID_WPA" ] || [ -n "$PENDING_KEY_WPA" ] || \
       [ -n "$PENDING_SSID_OPEN" ] || [ -n "$PENDING_KEY_OPEN" ] || \
       [ -n "$PENDING_SSID_MGMT" ] || [ -n "$PENDING_KEY_MGMT" ]; then
        wifi reload
    fi

    LOG "Connectivity Restored"
    LOG ""
}

while true; do

    LOG "=================================================="
    LOG ""

    print_interface_status() {
        IFACE=$1

        # Get SSID
        SSID=$(uci get wireless.${IFACE}.ssid 2>/dev/null || echo "N/A")

        # Get encryption
        ENCRYPTION=$(uci get wireless.${IFACE}.encryption 2>/dev/null || echo "none")
        if echo "$ENCRYPTION" | grep -q "psk2"; then
            ENC_TYPE="WPA2"
        elif echo "$ENCRYPTION" | grep -q "psk"; then
            ENC_TYPE="WPA"
        else
            ENC_TYPE="Open"
        fi

        # Get passphrase
        if [ "$ENC_TYPE" = "Open" ]; then
            PASSPHRASE="N/A"
        else
            PASSPHRASE=$(uci get wireless.${IFACE}.key 2>/dev/null || echo "N/A")
        fi

        # Get enabled state from config
        DISABLED=$(uci get wireless.${IFACE}.disabled 2>/dev/null || echo "0")
        if [ "$DISABLED" = "1" ]; then
            ENABLED="No"
        else
            ENABLED="Yes"
        fi

        # Get status
        if iwinfo ${IFACE} info &>/dev/null; then
            STATUS="UP"
        else
            STATUS="DOWN"
        fi

        # Get Evil Portal status
        EP_BRIDGE=$(grep -o 'iifname "[^"]*"' /etc/init.d/evilportal 2>/dev/null | head -1 | grep -o '"[^"]*"' | tr -d '"')
        EP_RUNNING=0
        pgrep nginx > /dev/null && EP_RUNNING=1

        if [ "$EP_RUNNING" -eq 1 ]; then
            if [ "$EP_BRIDGE" = "br-lan" ]; then
                EVIL_PORTAL="Yes (All Interfaces)"
            elif [ "$EP_BRIDGE" = "br-evil" ]; then
                if uci show wireless.${IFACE}.network 2>/dev/null | grep -q "evil"; then
                    EVIL_PORTAL="Yes (Isolated)"
                else
                    EVIL_PORTAL="No"
                fi
            else
                EVIL_PORTAL="Not Installed"
            fi
        else
            EVIL_PORTAL="Not Installed"
        fi

        LOG "Interface: ${IFACE}"
        LOG "Encryption Type: ${ENC_TYPE}"
        LOG "SSID: ${SSID}"
        LOG "Passphrase: ${PASSPHRASE}"
        LOG "Enabled: ${ENABLED}"
        LOG "Status: ${STATUS}"
        LOG "Evil Portal: ${EVIL_PORTAL}"
        LOG ""
    }

    print_interface_status wlan0wpa
    print_interface_status wlan0open
    print_interface_status wlan0mgmt

    # Check enabled state from config
    WPA_ENABLED=0
    OPEN_ENABLED=0
    MGMT_ENABLED=0

    [ "$(uci get wireless.wlan0wpa.disabled 2>/dev/null)" != "1" ] && WPA_ENABLED=1
    [ "$(uci get wireless.wlan0open.disabled 2>/dev/null)" != "1" ] && OPEN_ENABLED=1
    [ "$(uci get wireless.wlan0mgmt.disabled 2>/dev/null)" != "1" ] && MGMT_ENABLED=1

    ENABLED_COUNT=$((WPA_ENABLED + OPEN_ENABLED + MGMT_ENABLED))

    # Check actual UP state
    WPA_UP=0
    OPEN_UP=0
    MGMT_UP=0

    iwinfo wlan0wpa info &>/dev/null && WPA_UP=1
    iwinfo wlan0open info &>/dev/null && OPEN_UP=1
    iwinfo wlan0mgmt info &>/dev/null && MGMT_UP=1

    UP_COUNT=$((WPA_UP + OPEN_UP + MGMT_UP))

    # Check if all three interfaces are enabled - fix this first as it causes connectivity loss
    if [ "$ENABLED_COUNT" -eq 3 ]; then
        DIALOG_RESULT=$(CONFIRMATION_DIALOG "WARNING! All 3 interfaces are enabled. Disable an interface to restore connectivity?")
        if [ "$DIALOG_RESULT" != "1" ]; then
            exit 0
        fi

        disable_interface
        continue
    fi

    # Check internet connectivity
    if ! ping -c1 8.8.8.8 &>/dev/null; then
        LOG "ERROR: No internet connectivity detected"
        LOG "Interfaces may be UP but not broadcasting"
        LOG "Verify WiFi Client Mode is enabled and configured correctly"
        exit 1
    fi

    # Check for any interface that is enabled in config but DOWN
    for IFACE_CHECK in wlan0wpa wlan0open wlan0mgmt; do
        case "$IFACE_CHECK" in
            wlan0wpa) IFACE_ENABLED=$WPA_ENABLED; IFACE_UP=$WPA_UP; IFACE_NAME="Evil WPA" ;;
            wlan0open) IFACE_ENABLED=$OPEN_ENABLED; IFACE_UP=$OPEN_UP; IFACE_NAME="Open AP" ;;
            wlan0mgmt) IFACE_ENABLED=$MGMT_ENABLED; IFACE_UP=$MGMT_UP; IFACE_NAME="Management" ;;
        esac

        if [ "$IFACE_ENABLED" -eq 1 ] && [ "$IFACE_UP" -eq 0 ]; then
            DIALOG_RESULT=$(CONFIRMATION_DIALOG "${IFACE_NAME} is enabled but DOWN. Bring it up?")
            if [ "$DIALOG_RESULT" = "1" ]; then

                # Check if bringing it up would cause 3 interfaces to be UP simultaneously
                if [ "$UP_COUNT" -ge 2 ]; then
                    DIALOG_RESULT=$(CONFIRMATION_DIALOG "WARNING: Bringing up ${IFACE_NAME} would bring all 3 interfaces UP. Disable an interface first?")
                    if [ "$DIALOG_RESULT" != "1" ]; then
                        exit 0
                    fi
                    disable_interface
                fi

                bring_up_interface "$IFACE_CHECK" "$IFACE_NAME"
                continue 2
            fi
        fi
    done

    # Check if Evil Portal interface is disabled
    EVIL_IFACE=""
    EVIL_IFACE_NAME=""

    if uci show wireless.wlan0wpa.network 2>/dev/null | grep -q "evil"; then
        EVIL_IFACE="wlan0wpa"
        EVIL_IFACE_NAME="Evil WPA"
    elif uci show wireless.wlan0open.network 2>/dev/null | grep -q "evil"; then
        EVIL_IFACE="wlan0open"
        EVIL_IFACE_NAME="Open AP"
    fi

    if [ -n "$EVIL_IFACE" ]; then
        EVIL_ENABLED=0
        [ "$(uci get wireless.${EVIL_IFACE}.disabled 2>/dev/null)" != "1" ] && EVIL_ENABLED=1

        if [ "$EVIL_ENABLED" -eq 0 ]; then
            DIALOG_RESULT=$(CONFIRMATION_DIALOG "Evil Portal interface (${EVIL_IFACE_NAME}) is disabled. Enable it?")
            if [ "$DIALOG_RESULT" = "1" ]; then

                # Check if enabling and bringing up would cause 3 interfaces to be UP simultaneously
                if [ "$UP_COUNT" -ge 2 ]; then
                    DIALOG_RESULT=$(CONFIRMATION_DIALOG "WARNING: Enabling ${EVIL_IFACE_NAME} would bring all 3 interfaces UP. Disable an interface first?")
                    if [ "$DIALOG_RESULT" != "1" ]; then
                        exit 0
                    fi
                    disable_interface
                fi

                bring_up_interface "$EVIL_IFACE" "$EVIL_IFACE_NAME"
                continue
            fi
        fi
    fi

    break

done
