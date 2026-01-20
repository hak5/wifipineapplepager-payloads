#!/bin/bash
# Name: Switch Evil Portal
# Description: Switches the active Evil Portal
# Author: 0x4B
# Version: 1.0
# Category: Wireless

PORTAL_DIR="/root/portals"
SELECTED_PORTAL=""

# Non-interactive option 
if [ -n "$1" ]; then
    SELECTED_PORTAL="$1"
    LOG "Requested portal: $SELECTED_PORTAL"

else

    PORTALS=()

    # Build portal list (exclude 'current')
    for d in "$PORTAL_DIR"/*/; do
        name="$(basename "$d")"
        [ "$name" = "current" ] && continue
        PORTALS+=("$name")
    done

    if [ "${#PORTALS[@]}" -eq 0 ]; then
        ERROR_DIALOG "No portals found"
        exit 1
    fi

    # Build menu text
    MENU="Select a portal:\n\n"
    i=1
    for p in "${PORTALS[@]}"; do
        MENU="$MENU$i) $p\n"
        i=$((i+1))
    done

    LOG "$MENU"
    LOG "Press 'A' button to select portal."
    WAIT_FOR_BUTTON_PRESS A

    # Prompt for number
    CHOICE=$(NUMBER_PICKER "Enter portal number" "1")
    if [ $? -ne 0 ]; then
        PROMPT "Selection cancelled"
        exit 0
    fi

    INDEX=$((CHOICE -1))

    if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#PORTALS[@]}" ]; then
        ERROR_DIALOG "Invalid selection"
        exit 1
    fi

    SELECTED_PORTAL="${PORTALS[$INDEX]}"
fi

# Switch portal via init script
LOG "Switching Evil Portal to: $SELECTED_PORTAL"
/etc/init.d/evilportal switch "$SELECTED_PORTAL"

PROMPT "Evil Portal switched to:\n$SELECTED_PORTAL"
