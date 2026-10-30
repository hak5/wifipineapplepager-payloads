#!/bin/bash
# Title: Starchorus deauth/disassoc alert
# Description: Writes one line per firmware alert to the Starchorus alerts.log, in a directory of its own (time and addresses only). Sends nothing.
# Author: Starchorus
# Version: 0.2.6.2
# Contract: 3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The companion of Starchorus for the firmware's alert deauth_flood_detected. The firmware runs this file once for each such event and hands it the
# event in environment variables and in no other way: no channel, no signal strength, no frame count and no time. The file appends one line to alerts.log
# in a directory of its own (/root/loot/starchorus-alerts, outside the directory the page server may serve whole), EPOCH, deauth, AP, SOURCE, DESTINATION and CLIENT separated by tabs, the four addresses in lower case, or "-" where the
# firmware gave none or something that is not an address; the Starchorus collector reads that log, and the page words it as 'many deauth/disassoc frames
# heard for this AP'. What it is not: a detector (the firmware decides what counts as many, nothing here listens to a frame), anything that transmits, or
# anything that signals the user (no display, sound, LED or vibration command: the firmware's own alert already shows the event, and whether this file
# should add a signal is the owner's choice and has not been made). The Contract line is the interface number the Starchorus scripts share (see payload.sh): this file
# fixes the line format of alerts.log that the collector parses, so a change to that format moves the number in both. The alert name and the message text are not written: the text is free text from the
# firmware, and the log holds times and addresses only. SOURCE is the address the frames claim, which in a flood is usually not the sender's, so it is kept as
# received and is no lead to anyone. The log is kept to its last 2,000 lines, so that a flood of events cannot fill the flash. Install: copy this file to
# /root/payloads/alerts/deauth_flood_detected/starchorus/payload.sh and make it executable (the README of the payload says how). Exit status: 0, always.

# A directory of its own, not STARCHORUS_DIR: uhttpd or python3 serve that directory whole where the Pager has one, and this log holds other people's addresses.
# The firmware runs this file without the payload's environment, so the place is fixed; STARCHORUS_ALERT_DIR is an override for tests.
DIR=${STARCHORUS_ALERT_DIR:-/root/loot/starchorus-alerts}
LOG=$DIR/alerts.log

# $1 -> MAC: the text if it is an address (six pairs of hex digits), else "-". Case is settled once, on the whole line, below.
mac() {
    case $1 in
        [[:xdigit:]][[:xdigit:]]:[[:xdigit:]][[:xdigit:]]:[[:xdigit:]][[:xdigit:]]:[[:xdigit:]][[:xdigit:]]:[[:xdigit:]][[:xdigit:]]:[[:xdigit:]][[:xdigit:]]) MAC=$1 ;;
        *) MAC=- ;;
    esac
}

# The time comes from the clock here, not from the firmware; a clock that gives no number writes nothing.
now=$(date +%s 2>/dev/null)
case $now in ''|*[!0-9]*) exit 0 ;; esac

mac "${_ALERT_DENIAL_AP_MAC_ADDRESS:-}"; ap=$MAC
mac "${_ALERT_DENIAL_SOURCE_MAC_ADDRESS:-}"; src=$MAC
mac "${_ALERT_DENIAL_DESTINATION_MAC_ADDRESS:-}"; dst=$MAC
mac "${_ALERT_DENIAL_CLIENT_MAC_ADDRESS:-}"; cl=$MAC
# The line is all digits, "deauth", "-", tabs and addresses, so one tr over it lower-cases the addresses and nothing else.
line=$(printf '%s\tdeauth\t%s\t%s\t%s\t%s' "$now" "$ap" "$src" "$dst" "$cl" | tr 'A-F' 'a-f')

# One append, then the cap: the last 2,000 lines, through a file of the same directory (a rename, so the collector never reads half a file). Always returns 0.
record() {
    printf '%s\n' "$line" >> "$LOG" || return 0
    n=$(wc -l < "$LOG"); n=${n##* }
    if [ "${n:-0}" -gt 2000 ]; then
        if ! { tail -n 2000 "$LOG" > "$LOG.$$" && mv "$LOG.$$" "$LOG"; }; then rm -f "$LOG.$$"; fi
    fi
    return 0
}

# Alerts may overlap (the firmware says nothing about it), so the append and the cap run under one lock on a file of their own (the log itself is replaced by the
# rename, and a lock on the old file would not hold the next writer). Where flock is missing, or its lock file cannot be opened, the write goes ahead without the lock.
# The log is private to the owner: it holds the addresses of other people's equipment, and it lives outside the directory the page server serves.
umask 077
mkdir -p "$DIR" 2>/dev/null || exit 0
if command -v flock >/dev/null 2>&1; then
    ( flock -x 9; record ) 2>/dev/null 9> "$DIR/alerts.lock" || record
else
    record
fi
exit 0
