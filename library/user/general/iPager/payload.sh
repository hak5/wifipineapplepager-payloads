#!/bin/bash
# Title: iPager
# Description: Two Way Pager/Apple iMessage <-> Hak5 WiFi Pineapple Pager Relay
# Author: $p!ll_bl00d
# Version: 1.0
# Category: General/Notifications
#
# REQUIREMENTS: Mac running iPager.py on macOS on same network, SSH key auth configured
#
# DESCRIPTION:
#   Receives iMessage notifications relayed from a macOS host via SSH and
#   shows sender + content on the Pager screen.
#   Double-tap UP at any time to pick a sender (or manually enter a phone
#   number/email) and type a reply on the onboard keyboard; it's handed back
#   to the Mac via /tmp/pager_outbox for delivery over iMessage.
#   Loops continuously until manually stopped.
#
# SETUP:
#   1. Install payload.sh to Pager
#   2. Configure SSH key auth from Mac (see README)
#   3. Run iPager.py on macOS server (Mac mini/MacBook) on same network
#   4. Launch this payload from Pager dashboard
#
# NOTES:
#   - Compose trigger is UP (double-tap). The Pager's own stop-confirmation 
#     dialog is a Cancel/Yes toggle
#   - Every payload start force-kills any previous instance of itself
#   - Future Versions: Build LED State & Vibration Alerts for Specific Messages

MSG_FILE="/tmp/pager_msg"
FLAG_FILE="/tmp/msg_new"
OUTBOX_FILE="/tmp/pager_outbox"
OUTBOX_FLAG="/tmp/outbox_new"
CONTACTS_FILE="/tmp/pager_contacts"
CONTACTS_LOCK="/tmp/pager_contacts.lock"
BUSY_FLAG="/tmp/pager_busy"
PID_FILE="/tmp/pager_payload.pid"
WATCHER_PID_FILE="/tmp/pager_watcher.pid"
REPLY_BUTTON="UP"
MANUAL_OPTION="+ New recipient"

LAST_MSG=""
LAST_CONTACT_IDX=""

for pidfile in "$PID_FILE" "$WATCHER_PID_FILE"; do
    if [ -f "$pidfile" ]; then
        old_pid=$(cat "$pidfile" 2>/dev/null)
        [ -n "$old_pid" ] && kill -9 "$old_pid" 2>/dev/null
    fi
done
echo $$ > "$PID_FILE"

# Fresh contact list every time the payload starts, so restarting never
# leaves old entries around to (re)combine with newly arriving ones.
rm -f "$CONTACTS_FILE" "$FLAG_FILE" "$BUSY_FLAG"
rmdir "$CONTACTS_LOCK" 2>/dev/null

# ── Contact list (built locally as messages arrive) ─────────────────────────────

acquire_contacts_lock() {
    local tries=0
    while ! mkdir "$CONTACTS_LOCK" 2>/dev/null; do
        sleep 0.05
        tries=$((tries + 1))
        [ "$tries" -gt 40 ] && break  # ~2s safety timeout, don't hang forever
    done
}

release_contacts_lock() {
    rmdir "$CONTACTS_LOCK" 2>/dev/null
}

upsert_contact() {
    local idx="$1" name="$2"
    acquire_contacts_lock
    touch "$CONTACTS_FILE"
    grep -v "^${idx}|" "$CONTACTS_FILE" > "${CONTACTS_FILE}.tmp" 2>/dev/null
    echo "${idx}|${name}" >> "${CONTACTS_FILE}.tmp"
    mv "${CONTACTS_FILE}.tmp" "$CONTACTS_FILE"
    release_contacts_lock
}

# ── Idle / message screen ──────────────────────────────────────────────────────

redraw_idle() {
    CLEAR
    if [ -n "$LAST_MSG" ]; then
        SHOW "[ iMSG ]"
        SHOW "─────────────────"
        SHOW "$LAST_MSG"
        SHOW "─────────────────"
        SHOW "(Up x2) Send"
    else
        SHOW "┌─────────────────┐"
        SHOW "│     iPager      │"
        SHOW "└─────────────────┘"
        SHOW ""
        SHOW "Waiting for relay..."
    fi
}

# ── Background message watcher ───────────────────────────────────────────────

message_watcher() {
    while true; do
        if [ -f "$FLAG_FILE" ]; then
            rm -f "$FLAG_FILE"

            if [ -f "$MSG_FILE" ]; then
                MSG=$(cat "$MSG_FILE")

                if [ "$MSG" != "$LAST_MSG" ]; then
                    LAST_MSG="$MSG"

                    if [[ "$MSG" =~ ^\[([0-9]+)\]\ ([^:]+): ]]; then
                        LAST_CONTACT_IDX="${BASH_REMATCH[1]}"
                        upsert_contact "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
                    fi

                    LOG "$MSG"

                    if [ ! -f "$BUSY_FLAG" ]; then
                        redraw_idle
                        VIBRATE 200
                        WAIT 120
                        VIBRATE 200
                    fi
                fi
            fi
        fi
        WAIT 1000
    done
}

message_watcher &
WATCHER_PID=$!
echo "$WATCHER_PID" > "$WATCHER_PID_FILE"
trap "kill $WATCHER_PID 2>/dev/null; rm -f $BUSY_FLAG $PID_FILE $WATCHER_PID_FILE" EXIT INT TERM

# ── Reply flow ────────────────────────────────────────────────────────────────

do_reply_flow() {
    touch "$BUSY_FLAG"

    local options=()
    local default_opt=""
    if [ -s "$CONTACTS_FILE" ]; then
        while IFS='|' read -r idx name; do
            [ -z "$idx" ] && continue
            opt="${idx} ${name}"
            options+=("$opt")
            if [ "$idx" == "$LAST_CONTACT_IDX" ]; then
                default_opt="$opt"
            fi
        done < "$CONTACTS_FILE"
    fi
    options+=("$MANUAL_OPTION")
    [ -z "$default_opt" ] && default_opt="${options[0]}"

    __choice=$(LIST_PICKER "Send to:" "${options[@]}" "$default_opt") || { rm -f "$BUSY_FLAG"; redraw_idle; return; }

    if [ "$__choice" == "$MANUAL_OPTION" ]; then
        __target=$(TEXT_PICKER "Phone or email" "") || { rm -f "$BUSY_FLAG"; redraw_idle; return; }
        __msg=$(TEXT_PICKER "Message" "") || { rm -f "$BUSY_FLAG"; redraw_idle; return; }

        if [ -n "$__target" ] && [ -n "$__msg" ]; then
            printf 'NEW:%s|%s' "$__target" "$__msg" > "$OUTBOX_FILE"
            touch "$OUTBOX_FLAG"
            LOG "Reply queued for new recipient $__target: $__msg"
            PROMPT "Sent to $__target"
        fi

        rm -f "$BUSY_FLAG"
        redraw_idle
        return
    fi

    __idx="${__choice%% *}"
    __msg=$(TEXT_PICKER "Message" "") || { rm -f "$BUSY_FLAG"; redraw_idle; return; }

    if [ -n "$__idx" ] && [ -n "$__msg" ]; then
        printf '%s|%s' "$__idx" "$__msg" > "$OUTBOX_FILE"
        touch "$OUTBOX_FLAG"
        LOG "Reply queued for #$__idx: $__msg"
        PROMPT "Sent to #$__idx"
    fi

    rm -f "$BUSY_FLAG"
    redraw_idle
}

# ── Initial display ──────────────────────────────────────────────────────────────

redraw_idle
LOG "iMessage relay payload started"

# ── Main loop (foreground - owns the buttons, no forking/killing) ──────────────
# Requires REPLY_BUTTON twice in a row to open compose

while true; do
    WAIT_FOR_BUTTON_PRESS "$REPLY_BUTTON"
    WAIT_FOR_BUTTON_PRESS "$REPLY_BUTTON"
    do_reply_flow
done
