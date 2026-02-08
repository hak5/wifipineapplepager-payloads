#!/bin/bash
# Title: HashMaster Alert
# Description: Handshake smart alerts for new networks, quality improvements, and status changes
# Author:  spencershepard
# Version:  1.3.1
ALERT_PAYLOAD_VERSION="1.3.1"

# Alert options are set via hashmaster.sh, not here


DB_FILE="/root/hashmaster.db"

# Source shared functions and variables
HSMANAGER="/root/payloads/user/general/hashmaster/hashmaster.sh"
if [ -f "$HSMANAGER" ]; then
    . "$HSMANAGER"
else
    ALERT "ERROR: Cannot find hashmaster.sh at $HSMANAGER" >&2
    exit 1
fi

# Fallbacks when running headless (ensure alerts/errors emit something)
# Use portable checks to support ash/sh
if ! command -v ALERT >/dev/null 2>&1; then
    ALERT() { echo "[ALERT] $*"; }
fi
if ! command -v ERROR_DIALOG >/dev/null 2>&1; then
    ERROR_DIALOG() { echo "[ERROR] $*" >&2; }
fi


# ===================================

# $_ALERT_HANDSHAKE_SUMMARY             human-readable handshake summary "handshake AP ... CLIENT ... packets..."
# $_ALERT_HANDSHAKE_AP_MAC_ADDRESS      ap/bssid mac of handshake
# $_ALERT_HANDSHAKE_CLIENT_MAC_ADDRESS  client mac address
# $_ALERT_HANDSHAKE_TYPE                eapol | pmkid
# $_ALERT_HANDSHAKE_COMPLETE            (eapol only) complete 4-way handshake + beacon captured
# $_ALERT_HANDSHAKE_CRACKABLE           (eapol only) handshake is potentially crackable
# $_ALERT_HANDSHAKE_PCAP_PATH           path to pcap file
# $_ALERT_HANDSHAKE_HASHCAT_PATH        path to hashcat-converted file


# Get variables from alert event
AP_MAC="$_ALERT_HANDSHAKE_AP_MAC_ADDRESS"
CLIENT_MAC="$_ALERT_HANDSHAKE_CLIENT_MAC_ADDRESS"
TYPE="$_ALERT_HANDSHAKE_TYPE"
CRACKABLE="$_ALERT_HANDSHAKE_CRACKABLE"
COMPLETE="$_ALERT_HANDSHAKE_COMPLETE"
PCAP_PATH="$_ALERT_HANDSHAKE_PCAP_PATH"
HASHCAT_PATH="$_ALERT_HANDSHAKE_HASHCAT_PATH"

# Normalize MAC addresses to uppercase with colons for consistency
AP_MAC=$(echo "$AP_MAC" | tr 'a-z' 'A-Z')
CLIENT_MAC=$(echo "$CLIENT_MAC" | tr 'a-z' 'A-Z')

# The lock file mechanism probably isn't necessary? Not sure if multiple alerts can run simultaneously
LOCK_FILE="/tmp/hashmaster_alert.lock"
LOCK_FD=200

acquire_lock() {
    exec 200>"$LOCK_FILE"
    local timeout=15  # Maximum 15s wait for lock
    local elapsed=0
    
    while ! flock -n 200; do
        if [ "$elapsed" -ge "$timeout" ]; then
            debug_log "Failed to acquire lock after ${timeout}s - another alert still processing"
            exit 0  # Exit gracefully, will process on next alert
        fi
        sleep 1
        elapsed=$((elapsed+1))
    done
    debug_log "Lock acquired (waited ${elapsed}s)"
}

release_lock() {
    flock -u 200 2>/dev/null
    debug_log "Lock released"
}

# Acquire global lock - ensures only one alert processes at a time
acquire_lock

# Ensure lock is released on exit
trap release_lock EXIT

alert_message() {
    title="$1"
    ssid="$2"
    bssid="$3"
    details="$4"
    
    debug_log "Alert: title='$title', ssid='$ssid', bssid='$bssid'"
    
    local msg="$title\n"
    msg+="=======================\n"
    [[ -n "$ssid" ]] && msg+="Network: $ssid\n"
    [[ -n "$bssid" ]] && msg+="BSSID: $bssid\n"
    [[ -n "$details" ]] && msg+="$details\n"
    
    debug_log "Alert message being sent: $msg"
    ALERT "$msg"
}

debug_log "========================================"
debug_log "HashMaster Alert Payload v${ALERT_PAYLOAD_VERSION}"
debug_log "Processing handshake alert for BSSID: $AP_MAC, Type: $TYPE, Crackable: $CRACKABLE"
debug_log "$(env)"
debug_log "Interpreter check: BASH_VERSION='${BASH_VERSION:-none}', SHELL='$SHELL'"

# Initialize database if needed
if ! init_handshake_database "$DB_FILE"; then
    ERROR_DIALOG "Failed to initialize handshake tracking database at $DB_FILE"
    exit 1
fi

# Force WAL checkpoint to clear any stale locks before we start
sqlite3 "$DB_FILE" "PRAGMA wal_checkpoint(RESTART);" 2>/dev/null

# Wait up to 20s (every 3s) for the hashcat file to be available
MAX_WAIT=20
WAIT_INTERVAL=3
elapsed=0
if [ ! -f "$HASHCAT_PATH" ]; then
    debug_log "Hashcat file not found yet: $HASHCAT_PATH"
fi
while [ ! -f "$HASHCAT_PATH" ] && [ "$elapsed" -lt "$MAX_WAIT" ]; do
    sleep "$WAIT_INTERVAL"
    elapsed=$((elapsed+WAIT_INTERVAL))
    debug_log "Waiting for hashcat file (${elapsed}/${MAX_WAIT}s): $HASHCAT_PATH"
done
if [ ! -f "$HASHCAT_PATH" ]; then
    ALERT "[ERROR] HashMaster waited ${MAX_WAIT}s after handshake capture, but hashcat file is still missing: $HASHCAT_PATH"
    debug_log "Exiting: hashcat file missing after wait"
    exit 1
fi

# Get SSID hex and printable
SSID_HEX=$(get_ssid_hex "$AP_MAC" "$HASHCAT_PATH")
SSID_PRINTABLE=$(hex_to_printable_ssid "$SSID_HEX")
debug_log "SSID determined: hex=$SSID_HEX printable=$SSID_PRINTABLE"

# If we previously stored an unknown SSID for this BSSID, and now we know the SSID hex,
# promote the row by updating ssid_hex + ssid_printable for that BSSID.
SSID_PROMOTED=0
if [ -n "$SSID_HEX" ]; then
    BSSID_ESC_PROMO=$(sql_escape "$AP_MAC")
    SSID_HEX_ESC_PROMO=$(sql_escape "$SSID_HEX")
    SSID_PRINTABLE_ESC_PROMO=$(sql_escape "$SSID_PRINTABLE")
    # Check if there is an unknown-SSID row for this BSSID
    unknown_row=$(sqlite3 "$DB_FILE" "SELECT 1 FROM handshakes WHERE bssid='$BSSID_ESC_PROMO' AND (ssid_hex IS NULL OR ssid_hex='') LIMIT 1;" 2>/dev/null)
    if [ "$unknown_row" = "1" ]; then
        db_exec "UPDATE handshakes SET ssid_hex='$SSID_HEX_ESC_PROMO', ssid_printable='$SSID_PRINTABLE_ESC_PROMO' WHERE bssid='$BSSID_ESC_PROMO' AND (ssid_hex IS NULL OR ssid_hex='');" "$DB_FILE"
        SSID_PROMOTED=1
        debug_log "SSID promotion: BSSID $AP_MAC upgraded to hex=$SSID_HEX printable=$SSID_PRINTABLE"
        # Send immediate alert about SSID discovery
        alert_message "SSID DISCOVERED" "$SSID_PRINTABLE" "$AP_MAC" "SSID discovered for previously unknown network"
    fi
fi

# Trust the Pager's crackability assessment - it has already validated the handshake
ACTUAL_CRACKABLE=0
CRACKABLE_LC=$(echo "$CRACKABLE" | tr 'A-Z' 'a-z')
if [ "$CRACKABLE_LC" = "true" ]; then ACTUAL_CRACKABLE=1; fi
debug_log "Pager assessment: crackable=$CRACKABLE ($ACTUAL_CRACKABLE)"
debug_log "Hash file path: $HASHCAT_PATH"

# Determine current quality from the hash file
CURRENT_QUALITY=$(determine_file_quality "$HASHCAT_PATH")
CURRENT_RANK=$(quality_rank "$CURRENT_QUALITY")
debug_log "Quality: $CURRENT_QUALITY (rank $CURRENT_RANK), Min threshold: $MIN_QUALITY_RANK, Crackable: $ACTUAL_CRACKABLE"


# Check minimum quality threshold
if [ "$CURRENT_RANK" -lt "$MIN_QUALITY_RANK" ]; then
    debug_log "Exiting: quality rank $CURRENT_RANK below threshold $MIN_QUALITY_RANK"
    exit 0
fi

# Query database for this network
debug_log "Executing query: SELECT best_quality, crackable FROM handshakes WHERE ssid_hex='$SSID_HEX' AND bssid='$AP_MAC';"
DB_ENTRY=$(sqlite3 "$DB_FILE" "SELECT best_quality, crackable FROM handshakes WHERE ssid_hex='$SSID_HEX' AND bssid='$AP_MAC';" 2>&1)
DB_QUERY_EXIT=$?
debug_log "Query exit code: $DB_QUERY_EXIT"
debug_log "Query result: '$DB_ENTRY' (length: ${#DB_ENTRY})"

if [ "$DB_QUERY_EXIT" -ne 0 ]; then
    debug_log "ERROR: Database query failed with exit code $DB_QUERY_EXIT"
    debug_log "Error output: $DB_ENTRY"
    exit 1
fi

debug_log "About to evaluate if DB_ENTRY is empty..."
DB_EMPTY="YES"; [ -n "$DB_ENTRY" ] && DB_EMPTY="NO"
debug_log "DB_ENTRY value check: empty=$DB_EMPTY"

if [ -z "$DB_ENTRY" ]; then
    # NEW NETWORK
    debug_log "==> NEW NETWORK PATH: Empty DB_ENTRY"
    debug_log "New network detected. ALERT_NEW_NETWORK=$ALERT_NEW_NETWORK"
    debug_log "Preparing DB insert/update for SSID='$SSID_PRINTABLE' BSSID='$AP_MAC' quality='$CURRENT_QUALITY' crackable='$ACTUAL_CRACKABLE'"
    
    # Add to database using portable pattern (INSERT OR IGNORE + UPDATE)
    timestamp=$(date +%s)
    crackable_int=$ACTUAL_CRACKABLE
    # Pre-escape single quotes for SQL safety via shared helper
    SSID_HEX_ESC=$(sql_escape "$SSID_HEX")
    SSID_PRINTABLE_ESC=$(sql_escape "$SSID_PRINTABLE")
    BSSID_ESC=$(sql_escape "$AP_MAC")
    PCAP_ESC=$(sql_escape "$PCAP_PATH")
    HASHCAT_ESC=$(sql_escape "$HASHCAT_PATH")
    
    debug_log "DB: executing INSERT then UPDATE for new network"
    sql_insert="INSERT OR IGNORE INTO handshakes (ssid_hex, bssid, ssid_printable, best_quality, first_seen, last_seen, total_captures, crackable, best_pcap_path, best_hashcat_path) VALUES ('$SSID_HEX_ESC', '$BSSID_ESC', '$SSID_PRINTABLE_ESC', '$CURRENT_QUALITY', $timestamp, $timestamp, 1, $crackable_int, '$PCAP_ESC', '$HASHCAT_ESC');"
    sql_update="UPDATE handshakes SET last_seen=$timestamp, total_captures=COALESCE(total_captures,0)+1, ssid_printable='$SSID_PRINTABLE_ESC', best_quality='$CURRENT_QUALITY', crackable=$crackable_int, best_pcap_path='$PCAP_ESC', best_hashcat_path='$HASHCAT_ESC' WHERE ssid_hex='$SSID_HEX_ESC' AND bssid='$BSSID_ESC';"
    if ! db_exec "$sql_insert" "$DB_FILE"; then
        debug_log "FATAL: INSERT failed for new network"
        exit 0
    fi
    if ! db_exec "$sql_update" "$DB_FILE"; then
        debug_log "FATAL: UPDATE failed for new network"
        exit 0
    fi
    debug_log "DB: new network persisted (insert and update complete)"

    # Send alert after DB persistence to avoid blocking before writes
    if [ "$ALERT_NEW_NETWORK" -eq 1 ]; then
        debug_log "Sending NEW NETWORK alert"
        alert_title="NEW NETWORK"
        if [ "$ACTUAL_CRACKABLE" -eq 1 ]; then alert_title="NEW CRACKABLE NETWORK"; fi
        alert_message "$alert_title" "$SSID_PRINTABLE" "$AP_MAC" "Quality: $CURRENT_QUALITY\nType: $TYPE\nCrackable: $([ $ACTUAL_CRACKABLE -eq 1 ] && echo 'Yes' || echo 'No')"
    fi
    
    # Track client if present and client tracking enabled
    if [ "$TRACK_CLIENTS" -eq 1 ] && [ -n "$CLIENT_MAC" ]; then
        is_randomized=0
        if [ "$FILTER_RANDOMIZED_MACS" -eq 1 ] && is_randomized_mac "$CLIENT_MAC"; then
            is_randomized=1
        fi
        if [ "$is_randomized" -eq 1 ]; then
            debug_log "Client MAC $CLIENT_MAC is randomized - network tracked but client skipped"
        else
            debug_log "DB: INSERT OR IGNORE client row"
            CLIENT_ESC=$(sql_escape "$CLIENT_MAC")
            db_exec "INSERT OR IGNORE INTO clients (bssid, client_mac, first_seen, last_seen, capture_count, best_quality, crackable, best_pcap_path, best_hashcat_path) VALUES ('$BSSID_ESC', '$CLIENT_ESC', $timestamp, $timestamp, 1, '$CURRENT_QUALITY', $crackable_int, '$PCAP_ESC', '$HASHCAT_ESC');" "$DB_FILE"
            debug_log "DB: UPDATE client metadata/counts"
            db_exec "UPDATE clients SET last_seen=$timestamp, capture_count=COALESCE(capture_count,0)+1 WHERE bssid='$BSSID_ESC' AND client_mac='$CLIENT_ESC';" "$DB_FILE"
            debug_log "Inserted/Updated new client $CLIENT_MAC for network $AP_MAC with quality $CURRENT_QUALITY"
        fi
    fi
else
    # EXISTING NETWORK - check for improvements
    debug_log "==> EXISTING NETWORK PATH"
    IFS='|' read -r db_quality db_crackable <<< "$DB_ENTRY"
    
    # Set defaults for any empty values
    [ -z "$db_quality" ] && db_quality="$CURRENT_QUALITY"
    [ -z "$db_crackable" ] && db_crackable=0
    
    DB_RANK=$(quality_rank "$db_quality")
    debug_log "DB: quality=$db_quality (rank $DB_RANK), crackable=$db_crackable | Current: quality=$CURRENT_QUALITY (rank $CURRENT_RANK), crackable=$ACTUAL_CRACKABLE"
    
    # Prepare SQL parameters with validation
    timestamp=$(date +%s)
    crackable_int=${ACTUAL_CRACKABLE:-0}
    update_quality="$db_quality"
    # Pre-escape single quotes for SQL safety (existing-network path)
    SSID_HEX_ESC=$(sql_escape "$SSID_HEX")
    BSSID_ESC=$(sql_escape "$AP_MAC")
    CLIENT_ESC=$(sql_escape "$CLIENT_MAC")
    PCAP_ESC=$(sql_escape "$PCAP_PATH")
    HASHCAT_ESC=$(sql_escape "$HASHCAT_PATH")
    SSID_PRINTABLE_ESC=$(sql_escape "$SSID_PRINTABLE")
    
    # Validate critical parameters before SQL construction
    if ! validate_sql_params \
        "timestamp" "$timestamp" \
        "crackable_int" "$crackable_int" \
        "update_quality" "$update_quality" \
        "AP_MAC" "$AP_MAC"; then
        debug_log "FATAL: Cannot update database - invalid parameters"
        exit 1
    fi
    
    if [ "$CURRENT_RANK" -gt "$DB_RANK" ]; then
        # Quality improved - update with new file paths (use explicit SQL to increment numeric column)
        update_quality="$CURRENT_QUALITY"

        # Validate file paths
        if ! validate_sql_params \
            "PCAP_PATH" "$PCAP_PATH" \
            "HASHCAT_PATH" "$HASHCAT_PATH"; then
            debug_log "FATAL: Cannot update with file paths - invalid parameters"
            exit 1
        fi

        sql_update="UPDATE handshakes SET \
            last_seen=$timestamp, \
            total_captures=COALESCE(total_captures,0)+1, \
            ssid_printable='$SSID_PRINTABLE_ESC', \
            best_quality='$update_quality', \
            crackable=$crackable_int, \
            best_pcap_path='$PCAP_ESC', \
            best_hashcat_path='$HASHCAT_ESC' \
            WHERE ssid_hex='$SSID_HEX_ESC' AND bssid='$BSSID_ESC';"
        db_exec "$sql_update"
    else
        # No quality improvement - just update metadata
        sql_update="UPDATE handshakes SET \
            last_seen=$timestamp, \
            total_captures=COALESCE(total_captures,0)+1, \
            ssid_printable='$SSID_PRINTABLE_ESC', \
            crackable=$crackable_int \
            WHERE ssid_hex='$SSID_HEX_ESC' AND bssid='$BSSID_ESC';"
        db_exec "$sql_update"
    fi
    debug_log "Updated existing network in database"
    
    # Check for new client (if client tracking enabled)
    if [ "$TRACK_CLIENTS" -eq 1 ] && [ -n "$CLIENT_MAC" ]; then
        is_randomized=0
        if [ "$FILTER_RANDOMIZED_MACS" -eq 1 ] && is_randomized_mac "$CLIENT_MAC"; then
            is_randomized=1
        fi
        if [ "$is_randomized" -eq 1 ]; then
            debug_log "Client MAC $CLIENT_MAC is randomized - network tracked but client skipped"
        else
            client_entry=$(sqlite3 "$DB_FILE" "SELECT best_quality, crackable FROM clients WHERE bssid='$BSSID_ESC' AND client_mac='$CLIENT_ESC' LIMIT 1;" 2>/dev/null)
            if [ -z "$client_entry" ]; then
                # NEW CLIENT for this network
                db_exec "INSERT OR IGNORE INTO clients (bssid, client_mac, first_seen, last_seen, capture_count, best_quality, crackable, best_pcap_path, best_hashcat_path) VALUES ('$BSSID_ESC', '$CLIENT_ESC', $timestamp, $timestamp, 1, '$CURRENT_QUALITY', $crackable_int, '$PCAP_ESC', '$HASHCAT_ESC');" "$DB_FILE"
                db_exec "UPDATE clients SET last_seen=$timestamp, capture_count=COALESCE(capture_count,0)+1 WHERE bssid='$BSSID_ESC' AND client_mac='$CLIENT_ESC';" "$DB_FILE"
                debug_log "New client detected: $CLIENT_MAC for $SSID_PRINTABLE ($AP_MAC) with quality $CURRENT_QUALITY"
                # Only alert if enabled and not randomized MAC
                if [ "$ALERT_NEW_CLIENT" -eq 1 ] && [ "$is_randomized" -eq 0 ]; then
                    alert_message "NEW CLIENT DETECTED" "$SSID_PRINTABLE" "$AP_MAC" "Client: $CLIENT_MAC\nQuality: $CURRENT_QUALITY"
                fi
            else
                # Existing client - check for quality improvement
                IFS='|' read -r client_quality client_crackable <<< "$client_entry"
                client_rank=$(quality_rank "$client_quality")
                debug_log "Existing client $CLIENT_MAC - DB quality: $client_quality (rank $client_rank), Current: $CURRENT_QUALITY (rank $CURRENT_RANK)"
                if [ "$CURRENT_RANK" -gt "$client_rank" ]; then
                    # Quality improved for this specific client-AP pair - update with new file paths
                    db_exec "UPDATE clients SET last_seen=$timestamp, capture_count=capture_count+1, best_quality='$CURRENT_QUALITY', crackable=$crackable_int, best_pcap_path='$PCAP_ESC', best_hashcat_path='$HASHCAT_ESC' WHERE bssid='$BSSID_ESC' AND client_mac='$CLIENT_ESC';" 
                    debug_log "Client quality improved from $client_quality to $CURRENT_QUALITY"
                    # Only alert if enabled and not randomized MAC
                    if [ "$ALERT_QUALITY_IMPROVED" -eq 1 ] && [ "$is_randomized" -eq 0 ]; then
                        alert_message "CLIENT QUALITY IMPROVED" "$SSID_PRINTABLE" "$AP_MAC" "Client: $CLIENT_MAC\nPrevious: $client_quality\nNew: $CURRENT_QUALITY"
                    fi
                else
                    # No quality improvement - just update metadata
                    db_exec "UPDATE clients SET last_seen=$timestamp, capture_count=capture_count+1, crackable=$crackable_int WHERE bssid='$BSSID_ESC' AND client_mac='$CLIENT_ESC';" 
                    debug_log "Updated existing client $CLIENT_MAC (no quality change)"
                fi
            fi
        fi
    fi
    
    # Check if quality improved
    if [ "$CURRENT_RANK" -gt "$DB_RANK" ]; then
        debug_log "Quality improved. ALERT_QUALITY_IMPROVED=$ALERT_QUALITY_IMPROVED"
        if [ "$ALERT_QUALITY_IMPROVED" -eq 1 ]; then
            debug_log "Sending QUALITY IMPROVED alert"
            alert_message "QUALITY IMPROVED" "$SSID_PRINTABLE" "$AP_MAC" "Previous: $db_quality\nNew: $CURRENT_QUALITY"
        fi
    elif [ "$db_crackable" != "1" ] && [ "$ACTUAL_CRACKABLE" -eq 1 ]; then
        # Network was not crackable before, now it is
        debug_log "Sending NOW CRACKABLE alert"
        alert_message "NOW CRACKABLE" "$SSID_PRINTABLE" "$AP_MAC" "Quality: $CURRENT_QUALITY"
    else
        debug_log "No alert condition met: rank not improved and already crackable"
    fi
fi

debug_log "Exiting normally"
exit 0
