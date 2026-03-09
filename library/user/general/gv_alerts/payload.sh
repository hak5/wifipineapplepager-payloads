#!/bin/bash
# Title: Google Voice Alerts
# Author: brAinphreAk
# Description: Receive Google Voice calls/texts/voicemails as alerts
# Version: 2.1
# Category: Notifications

# =============================================================================
# CONFIGURATION - EDIT THESE BEFORE INSTALLING ON PAGER
# =============================================================================

WEBHOOK_URL="https://script.google.com/macros/s/YOUR_SCRIPT_ID_HERE/exec"
CHECK_INTERVAL=2  # Minutes between checks

# =============================================================================
# INTERNAL CONFIGURATION (don't edit)
# =============================================================================

INSTALL_DIR="/root/payloads/user/general/gv_alerts"
LAST_HASH_FILE="$INSTALL_DIR/.last_hash"
CRON_ENTRY="*/$CHECK_INTERVAL * * * * $INSTALL_DIR/payload.sh --check"

# =============================================================================
# CHECK FUNCTION (called by cron with --check argument)
# =============================================================================

do_check() {
    # Exit if no webhook configured
    [ -z "$WEBHOOK_URL" ] || echo "$WEBHOOK_URL" | grep -q 'YOUR_SCRIPT_ID_HERE' && return 0

    # Read last hash for bandwidth optimization
    last_hash=""
    [ -f "$LAST_HASH_FILE" ] && last_hash=$(cat "$LAST_HASH_FILE" 2>/dev/null)

    # URL-encode the hash (contains + and / which break URL params)
    encoded_hash=$(printf '%s' "$last_hash" | sed 's/+/%2B/g; s/\//%2F/g')

    # Check messages (pass lastHash to reduce bandwidth when unchanged)
    response=$(curl -sL -m 15 "$WEBHOOK_URL?lastHash=$encoded_hash" 2>/dev/null)
    [ $? -ne 0 ] || [ -z "$response" ] && return 1

    # Check if unchanged (minimal response = no new messages)
    unchanged=$(echo "$response" | grep -o '"unchanged":true')
    [ -n "$unchanged" ] && return 0

    # Parse full response
    has_messages=$(echo "$response" | grep -o '"hasMessages":true')
    msg_hash=$(echo "$response" | grep -o '"msgHash":"[^"]*"' | sed 's/"msgHash":"//;s/"$//')
    alert_text=$(echo "$response" | grep -o '"alertText":"[^"]*"' | sed 's/"alertText":"//;s/"$//')
    alert_text=$(printf '%b' "$alert_text")

    [ -z "$msg_hash" ] && msg_hash="empty"

    # Alert on new messages
    if [ -n "$has_messages" ]; then
        ALERT "$alert_text"
        RINGTONE hak5_the_planet
        echo "$msg_hash" > "$LAST_HASH_FILE"
    else
        echo "" > "$LAST_HASH_FILE"
    fi
}

# If called with --check, run check and exit
if [ "$1" = "--check" ]; then
    do_check
    exit 0
fi

# =============================================================================
# PAYLOAD FUNCTIONS
# =============================================================================

install_payload() {
    LOG blue "Installing GV Alerts..."

    # Check if webhook URL is configured
    if [ -z "$WEBHOOK_URL" ] || echo "$WEBHOOK_URL" | grep -q 'YOUR_SCRIPT_ID_HERE'; then
        ALERT "Webhook not configured!\n\nSet WEBHOOK_URL in\npayload.sh and re-upload."
        exit 1
    fi

    # Add cron job
    (crontab -l 2>/dev/null | grep -v "gv_alerts" | grep -v "payload.sh.*check"; echo "$CRON_ENTRY") | crontab -

    # Enable cron service if not running
    if ! /etc/init.d/cron status >/dev/null 2>&1; then
        /etc/init.d/cron start
        /etc/init.d/cron enable
    fi

    # Clear hash
    rm -f "$LAST_HASH_FILE"

    LOG green "Installation complete!"
    ALERT "GV Alerts installed! Checking every $CHECK_INTERVAL min. Edit payload.sh to change."
}

uninstall_payload() {
    LOG blue "Uninstalling GV Alerts..."

    # Remove cron job
    crontab -l 2>/dev/null | grep -v "payload.sh.*check" | crontab -

    # Disable cron service if no other cron jobs remain
    remaining_jobs=$(crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" | wc -l)
    if [ "$remaining_jobs" -eq 0 ]; then
        /etc/init.d/cron stop
        /etc/init.d/cron disable
    fi

    # Remove state files
    rm -f "$LAST_HASH_FILE"

    LOG green "Uninstalled!"
    ALERT "GV Alerts uninstalled"
}

toggle_alerts() {
    if is_installed; then
        # Disable - remove cron job
        crontab -l 2>/dev/null | grep -v "payload.sh.*check" | crontab -

        # Stop cron if no other jobs
        remaining_jobs=$(crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" | wc -l)
        if [ "$remaining_jobs" -eq 0 ]; then
            /etc/init.d/cron stop
            /etc/init.d/cron disable
        fi

        ALERT "GV Alerts: OFF"
        LOG green "GV Alerts disabled"
    else
        # Enable - add cron job
        rm -f "$LAST_HASH_FILE"
        (crontab -l 2>/dev/null | grep -v "payload.sh.*check"; echo "$CRON_ENTRY") | crontab -

        # Start cron if not running
        if ! /etc/init.d/cron status >/dev/null 2>&1; then
            /etc/init.d/cron start
            /etc/init.d/cron enable
        fi

        ALERT "GV Alerts: ON"
        LOG green "GV Alerts enabled"
    fi
}

clear_history() {
    rm -f "$LAST_HASH_FILE"
    ALERT "History cleared!\n\nNext check will show\nall unread messages."
    LOG green "Message history cleared"
}

check_now() {
    rm -f "$LAST_HASH_FILE"
    LOG blue "Checking for messages..."
    id=$(START_SPINNER "Checking...")
    do_check
    STOP_SPINNER $id
    LOG green "Check complete"
}

test_alerts() {
    # Check if webhook URL is configured
    if [ -z "$WEBHOOK_URL" ] || echo "$WEBHOOK_URL" | grep -q 'YOUR_SCRIPT_ID_HERE'; then
        LOG red "Webhook URL not configured"
        ALERT "Webhook not configured!\n\nSet WEBHOOK_URL in\npayload.sh and re-upload."
        return
    fi

    LOG blue "Webhook URL configured"
    id=$(START_SPINNER "Testing...")
    response=$(curl -sL -m 15 "$WEBHOOK_URL" 2>/dev/null)
    STOP_SPINNER $id

    if [ $? -ne 0 ] || [ -z "$response" ]; then
        LOG red "Webhook connection failed"
        ALERT "Connection failed!\n\nCheck internet."
        return
    fi

    # Check for valid response
    has_messages=$(echo "$response" | grep -o '"hasMessages":true')
    if [ -z "$has_messages" ]; then
        LOG green "Webhook OK - No messages"
        ALERT "No unread messages."
        return
    fi

    # Show the actual alert
    LOG green "Webhook OK - Messages found"
    alert_text=$(echo "$response" | grep -o '"alertText":"[^"]*"' | sed 's/"alertText":"//;s/"$//')
    alert_text=$(printf '%b' "$alert_text")
    ALERT "$alert_text"
    RINGTONE hak5_the_planet
}

is_installed() {
    crontab -l 2>/dev/null | grep -q "payload.sh.*check"
}

# =============================================================================
# MAIN MENU
# =============================================================================

LOG "GV Alerts"

if is_installed; then
    # Installed = cron job exists = ON
    resp=$(CONFIRMATION_DIALOG $'GV Alerts is ON\n\nTurn OFF?')

    case "$resp" in
        $DUCKYSCRIPT_USER_CONFIRMED)
            toggle_alerts
            ;;
        $DUCKYSCRIPT_USER_DENIED)
            resp=$(CONFIRMATION_DIALOG "Check for messages now?")
            if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                check_now
            else
                resp=$(CONFIRMATION_DIALOG "Clear message history?")
                if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                    clear_history
                else
                    resp=$(CONFIRMATION_DIALOG "Uninstall GV Alerts?")
                    [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ] && uninstall_payload
                fi
            fi
            ;;
    esac
else
    # First run - install
    resp=$(CONFIRMATION_DIALOG "Install GV Alerts?")
    if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        install_payload
    else
        resp=$(CONFIRMATION_DIALOG "Test GV Alerts?")
        if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
            test_alerts
            # Wait for user to dismiss alert
            sleep 3
            # Offer to install after successful test
            resp=$(CONFIRMATION_DIALOG "Install GV Alerts?")
            [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ] && install_payload
        fi
    fi
fi

exit 0
