#!/bin/bash
# Title: Handshake Sanitiser
# Author: PanicAcid
# Description: Advanced loot management with Full vs Partial quality control.
# Version: 1.0

HANDSHAKE_DIR="/root/loot/handshakes"

# 1. Directory Validation
if [ ! -d "$HANDSHAKE_DIR" ]; then
    LOG "[!] Error: Handshake directory not found."
    exit 1
fi

# 2. User Interaction Sequence
DO_DEDUPE=$(CONFIRMATION_DIALOG "Deduplicate captures? (Keeps newest of each type)")
DO_PURGE_PARTIAL=$(CONFIRMATION_DIALOG "Purge Partials if a Full exists for that target?")
DO_RENAME=$(CONFIRMATION_DIALOG "Rename for Windows? (Replaces : with -)")

if [ "$DO_DEDUPE" == "0" ] && [ "$DO_PURGE_PARTIAL" == "0" ] && [ "$DO_RENAME" == "0" ]; then
    LOG "No actions selected. Exiting."
    exit 0
fi

cd "$HANDSHAKE_DIR" || exit 1

# 3. Execution: Deduplication (Standard newest-of-each-type logic)
if [ "$DO_DEDUPE" == "1" ]; then
    LOG "Deduplicating handshakes..."
    unique_events=$(ls | sed 's/^[0-9]*_//' | cut -d'.' -f1 | sort -u)
    d_count=0
    for event in $unique_events; do
        timestamps=$(ls | grep -F "_${event}." | cut -d'_' -f1 | sort -rn -u)
        latest_ts=$(echo "$timestamps" | head -n 1)
        old_timestamps=$(echo "$timestamps" | tail -n +2)
        for old_ts in $old_timestamps; do
            rm -f ${old_ts}_${event}.* && ((d_count++))
        done
    done
    LOG "[*] Deduplication complete. $d_count files removed."
fi

# 4. Execution: Quality Purge (Nuke Partials if Full exists)
if [ "$DO_PURGE_PARTIAL" == "1" ]; then
    LOG "Cleaning up redundant partials..."
    p_count=0
    # Find all unique BSSID_Client pairings (ignoring the suffix)
    pairings=$(ls | cut -d'_' -f2-3 | sort -u)
    
    for pair in $pairings; do
        # Check if we have at least one FULL handshake for this pair
        if ls *_${pair}_handshake.pcap >/dev/null 2>&1; then
            # If yes, delete any PARTIAL handshakes for this pair
            if ls *_${pair}_handshake_partial.* >/dev/null 2>&1; then
                rm -f *_${pair}_handshake_partial.*
                ((p_count++))
            fi
        fi
    done
    LOG "[*] Quality Purge complete. $p_count redundant partials removed."
fi

# 5. Execution: Windows Normalisation
if [ "$DO_RENAME" == "1" ]; then
    LOG "Applying Windows naming standards..."
    r_count=0
    for file in *:* ; do
        [ -e "$file" ] || continue
        new_name=$(echo "$file" | tr ':' '-')
        mv "$file" "$new_name"
        ((r_count++))
    done
    LOG "[*] Normalisation complete. $r_count files updated."
fi

LOG "[*] Sanitiser finished. Loot is high-quality and clean."