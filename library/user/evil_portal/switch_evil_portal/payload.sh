#!/bin/bash
# Name: Switch Evil Portal
# Description: Switches the active Evil Portal
# Author: 0x4B / PentestPlaybook
# Version: 1.2
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

    CURRENT_PORTAL=$(basename "$(readlink "$PORTAL_DIR/current" 2>/dev/null)" 2>/dev/null)
    DEFAULT_PORTAL="${CURRENT_PORTAL:-${PORTALS[0]}}"

    SELECTED_PORTAL=$(LIST_PICKER "Select Portal" "${PORTALS[@]}" "$DEFAULT_PORTAL")
    if [ $? -ne 0 ]; then
        PROMPT "Selection cancelled"
        exit 0
    fi
fi

# Validate and fix permissions before switching
# Check for anything not set to exactly 755
LOG "Checking permissions on portal: $SELECTED_PORTAL"
BAD_PERMS=$(find "$PORTAL_DIR/$SELECTED_PORTAL/" ! -perm 755 | wc -l)
if [ "$BAD_PERMS" -gt 0 ]; then
    LOG "Bad permissions detected on $BAD_PERMS item(s). Fixing..."
    chmod -R 755 "$PORTAL_DIR/$SELECTED_PORTAL/"
    LOG "Permissions corrected."
else
    LOG "Permissions OK."
fi

# Switch portal via init script
LOG "Switching Evil Portal to: $SELECTED_PORTAL"
/etc/init.d/evilportal switch "$SELECTED_PORTAL"
ALERT "Evil Portal switched to:\n$SELECTED_PORTAL. Refresh browser if necessary."