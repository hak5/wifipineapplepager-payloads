#!/bin/bash
# Title: HashMaster Alert
# Description: Handshake smart alerts for new networks, quality improvements, and status changes
# Author:  spencershepard
# Version:  1.2.1

# Alert options are set via hashmaster.sh, not here

ALERT_PAYLOAD_VERSION="1.2.1"

DB_FILE="/root/hashmaster.db"

# Source shared functions and variables
HSMANAGER="/root/payloads/user/general/hashmaster/hashmaster.sh"
if [[ -f "$HSMANAGER" ]]; then
    source "$HSMANAGER"
else
    ALERT "ERROR: Cannot find hashmaster.sh at $HSMANAGER" >&2
    exit 1
fi


# ===================================

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

# Debounce: prevent processing same BSSID+CLIENT pair within 5 seconds
# Use both MACs to handle deauth attacks capturing multiple clients simultaneously
DEBOUNCE_KEY="${AP_MAC//:/}_${CLIENT_MAC//:/}"
DEBOUNCE_FILE="/tmp/hashmaster_debounce_${DEBOUNCE_KEY}"
if [[ -f "$DEBOUNCE_FILE" ]]; then
    last_time=$(cat "$DEBOUNCE_FILE" 2>/dev/null || echo 0)
    current_time=$(date +%s)
    time_diff=$((current_time - last_time))
    if [[ $time_diff -lt 5 ]]; then
        debug_log "Debounced: BSSID $AP_MAC + Client $CLIENT_MAC processed ${time_diff}s ago (< 5s threshold)"
        exit 0
    fi
fi
echo $(date +%s) > "$DEBOUNCE_FILE"

# Global lock to prevent concurrent alert processing (eliminates database contention)
# Multiple alerts can fire simultaneously, but only one should process at a time
LOCK_FILE="/tmp/hashmaster_alert.lock"
LOCK_FD=200

acquire_lock() {
    exec 200>"$LOCK_FILE"
    local timeout=15  # Maximum 15s wait for lock
    local elapsed=0
    
    while ! flock -n 200; do
        if [[ $elapsed -ge $timeout ]]; then
            debug_log "Failed to acquire lock after ${timeout}s - another alert still processing"
            exit 0  # Exit gracefully, will process on next alert
        fi
        sleep 1
        ((elapsed++))
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
    local title="$1"
    local ssid="$2"
    local bssid="$3"
    local details="$4"
    
    debug_log "Alert: title='$title', ssid='$ssid', bssid='$bssid'"
    
    local msg="$title\n"
    msg+="━━━━━━━━━━━━━━━━━━━━\n"
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

# Initialize database if needed
if ! init_handshake_database "$DB_FILE"; then
    ERROR_DIALOG "Failed to initialize handshake tracking database at $DB_FILE"
    exit 1
fi

# Force WAL checkpoint to clear any stale locks before we start
sqlite3 "$DB_FILE" "PRAGMA wal_checkpoint(RESTART);" 2>/dev/null

# Get SSID
SSID=$(get_ssid "$DB_FILE" "$AP_MAC" "$HASHCAT_PATH")
debug_log "SSID determined: $SSID"

# Validate crackability - compare our logic vs Pager assessment
VALIDATED_CRACKABLE=0

# Handle both old (with colons) and new (without colons) filename formats
actual_hashcat_path="$HASHCAT_PATH"
if [[ ! -f "$actual_hashcat_path" ]]; then
    # Try removing colons from MAC addresses in filename
    filename=$(basename "$actual_hashcat_path")
    dirname=$(dirname "$actual_hashcat_path")
    no_colon_filename="${filename//:/}"
    actual_hashcat_path="$dirname/$no_colon_filename"
    debug_log "Original path not found, trying without colons: $actual_hashcat_path"
fi

if [[ -f "$actual_hashcat_path" ]]; then
    # Wait for file to be written and contain WPA hash (up to 5s total)
    # hcxpcapngtool needs time to process pcap and write the .22000 file
    hash_line=""
    file_size=0
    for attempt in 1 2 3 4 5; do
        file_size=$(stat -c%s "$actual_hashcat_path" 2>/dev/null || echo 0)
        if [[ $file_size -gt 100 ]]; then 
            hash_line=$(grep "^WPA" "$actual_hashcat_path" 2>/dev/null | head -1)
            if [[ -n "$hash_line" ]]; then
                debug_log "Hash file ready: $actual_hashcat_path (size: $file_size bytes, attempt $attempt)"
                break
            fi
        fi
        if [[ $attempt -lt 5 ]]; then
            debug_log "Hash file not ready (size: $file_size, attempt $attempt), waiting 2s..."
            sleep 2
        fi
    done
    
    if [[ -n "$hash_line" ]]; then
        validation_result=$(validate_crackable "$hash_line" 2>&1)
        validation_status="${validation_result%%:*}"
        if [[ "$validation_status" == "CRACKABLE" ]]; then
            VALIDATED_CRACKABLE=1
        fi
        debug_log "Our validation: '$validation_result' -> crackable=$VALIDATED_CRACKABLE"
    else
        debug_log "Hash file not ready for validation - hcxpcapngtool still processing (trusting Pager assessment)"
    fi
else
    debug_log "Hash file not found: $HASHCAT_PATH (also tried without colons)"
fi

# Use Pager's assessment (proven accurate), but log comparison
ACTUAL_CRACKABLE=0
[[ "${CRACKABLE,,}" == "true" ]] && ACTUAL_CRACKABLE=1
debug_log "Pager says: crackable=$CRACKABLE ($ACTUAL_CRACKABLE)"
debug_log "Comparison: Pager=$ACTUAL_CRACKABLE, Our validation=$VALIDATED_CRACKABLE $([ $ACTUAL_CRACKABLE -ne $VALIDATED_CRACKABLE ] && echo '*** MISMATCH ***' || echo 'Match')"

# Determine current quality
CURRENT_QUALITY=$(determine_quality "$TYPE" "$COMPLETE" "$HASHCAT_PATH")
CURRENT_RANK=$(quality_rank "$CURRENT_QUALITY")
debug_log "Quality: $CURRENT_QUALITY (rank $CURRENT_RANK), Min threshold: $MIN_QUALITY_RANK, Crackable: $ACTUAL_CRACKABLE"

# Exit if not crackable and we only care about crackable
if [[ $ACTUAL_CRACKABLE -eq 0 ]] && [[ $ALERT_NON_CRACKABLE -eq 0 ]]; then
    debug_log "Exiting: not crackable and ALERT_NON_CRACKABLE=0"
    exit 0
fi

# Check minimum quality threshold
if [[ $CURRENT_RANK -lt $MIN_QUALITY_RANK ]]; then
    debug_log "Exiting: quality rank $CURRENT_RANK below threshold $MIN_QUALITY_RANK"
    exit 0
fi

# Check if best quality only filter is enabled
if [[ $ALERT_BEST_QUALITY_ONLY -eq 1 ]] && [[ "$CURRENT_QUALITY" != "EAPOL_M2M3_BEST" ]]; then
    debug_log "Exiting: ALERT_BEST_QUALITY_ONLY enabled but quality is $CURRENT_QUALITY"
    exit 0
fi

# Query database for this network
DB_ENTRY=$(sqlite3 "$DB_FILE" "SELECT best_quality, crackable FROM handshakes WHERE ssid='$SSID' AND bssid='$AP_MAC';" 2>/dev/null)
debug_log "DB query result: '$DB_ENTRY' (length: ${#DB_ENTRY})"
debug_log "About to check if DB_ENTRY is empty..."

if [[ -z "$DB_ENTRY" ]]; then
    # NEW NETWORK
    debug_log "==> NEW NETWORK PATH: Empty DB_ENTRY"
    debug_log "New network detected. ALERT_NEW_NETWORK=$ALERT_NEW_NETWORK"
    if [[ $ALERT_NEW_NETWORK -eq 1 ]]; then
        debug_log "Sending NEW NETWORK alert"
        alert_title="NEW NETWORK"
        [[ $ACTUAL_CRACKABLE -eq 1 ]] && alert_title="NEW CRACKABLE NETWORK"
        alert_message "$alert_title" "$SSID" "$AP_MAC" "Quality: $CURRENT_QUALITY\nType: $TYPE\nCrackable: $([ $ACTUAL_CRACKABLE -eq 1 ] && echo 'Yes' || echo 'No')"
    fi
    
    # Add to database using UPSERT to prevent duplicate alerts and race conditions
    timestamp=$(date +%s)
    crackable_int=$ACTUAL_CRACKABLE
    
    db_exec "INSERT INTO handshakes (ssid, bssid, best_quality, first_seen, last_seen, total_captures, crackable, best_pcap_path, best_hashcat_path) VALUES ('${SSID//\'/\'\''}', '${AP_MAC//\'/\'\''}', '$CURRENT_QUALITY', $timestamp, $timestamp, 1, $crackable_int, '${PCAP_PATH//\'/\'\''}', '${HASHCAT_PATH//\'/\'\''}') ON CONFLICT(ssid, bssid) DO UPDATE SET last_seen=$timestamp, total_captures=total_captures+1;" "$DB_FILE"
    
    if [[ $? -ne 0 ]]; then
        debug_log "Failed to insert network - database busy, will retry on next handshake"
        exit 0
    fi
    
    debug_log "Inserted new network into database"
    
    # Track client if present and client tracking enabled
    if [[ $TRACK_CLIENTS -eq 1 && -n "$CLIENT_MAC" ]]; then
        # Skip client tracking for randomized MACs to prevent database bloat
        # But we still track the network handshake above - it's valuable for cracking
        if [[ $FILTER_RANDOMIZED_MACS -eq 1 ]] && is_randomized_mac "$CLIENT_MAC"; then
            debug_log "Client MAC $CLIENT_MAC is randomized - network tracked but client skipped"
        else
            db_exec "INSERT INTO clients (bssid, client_mac, first_seen, last_seen, capture_count, best_quality, crackable, best_pcap_path, best_hashcat_path) VALUES ('${AP_MAC//\'/\'\''}', '${CLIENT_MAC//\'/\'\''}', $timestamp, $timestamp, 1, '$CURRENT_QUALITY', $crackable_int, '${PCAP_PATH//\'/\'\''}', '${HASHCAT_PATH//\'/\'\''}') ON CONFLICT(bssid, client_mac) DO UPDATE SET last_seen=$timestamp, capture_count=capture_count+1;"
            debug_log "Inserted new client $CLIENT_MAC for network $AP_MAC with quality $CURRENT_QUALITY"
        fi
    fi
else
    # EXISTING NETWORK - check for improvements
    debug_log "==> EXISTING NETWORK PATH"
    IFS='|' read -r db_quality db_crackable <<< "$DB_ENTRY"
    
    # Set defaults for any empty values
    [[ -z "$db_quality" ]] && db_quality="$CURRENT_QUALITY"
    [[ -z "$db_crackable" ]] && db_crackable=0
    
    DB_RANK=$(quality_rank "$db_quality")
    debug_log "DB: quality=$db_quality (rank $DB_RANK), crackable=$db_crackable | Current: quality=$CURRENT_QUALITY (rank $CURRENT_RANK), crackable=$ACTUAL_CRACKABLE"
    
    # Prepare SQL parameters with validation
    timestamp=$(date +%s)
    crackable_int=${ACTUAL_CRACKABLE:-0}
    update_quality="$db_quality"
    
    # Validate critical parameters before SQL construction
    if ! validate_sql_params \
        "timestamp" "$timestamp" \
        "crackable_int" "$crackable_int" \
        "update_quality" "$update_quality" \
        "SSID" "$SSID" \
        "AP_MAC" "$AP_MAC"; then
        debug_log "FATAL: Cannot update database - invalid parameters"
        exit 1
    fi
    
    if [[ $CURRENT_RANK -gt $DB_RANK ]]; then
        # Quality improved - update with new file paths
        update_quality="$CURRENT_QUALITY"
        
        # Validate file paths
        if ! validate_sql_params \
            "PCAP_PATH" "$PCAP_PATH" \
            "HASHCAT_PATH" "$HASHCAT_PATH"; then
            debug_log "FATAL: Cannot update with file paths - invalid parameters"
            exit 1
        fi
        
        sql=$(build_update_sql "handshakes" "ssid='${SSID//\'/\'\'}' AND bssid='${AP_MAC//\'/\'\'}'" \
            "best_quality" "$update_quality" \
            "last_seen" "$timestamp" \
            "total_captures" "total_captures+1" \
            "crackable" "$crackable_int" \
            "best_pcap_path" "${PCAP_PATH}" \
            "best_hashcat_path" "${HASHCAT_PATH}")
        
        db_exec "$sql"
    else
        # No quality improvement - just update metadata
        sql=$(build_update_sql "handshakes" "ssid='${SSID//\'/\'\'}' AND bssid='${AP_MAC//\'/\'\'}'" \
            "best_quality" "$update_quality" \
            "last_seen" "$timestamp" \
            "total_captures" "total_captures+1" \
            "crackable" "$crackable_int")
        
        db_exec "$sql"
    fi
    debug_log "Updated existing network in database"
    
    # Check for new client (if client tracking enabled)
    if [[ $TRACK_CLIENTS -eq 1 && -n "$CLIENT_MAC" ]]; then
        # Skip client tracking for randomized MACs to prevent database bloat
        if [[ $FILTER_RANDOMIZED_MACS -eq 1 ]] && is_randomized_mac "$CLIENT_MAC"; then
            debug_log "Client MAC $CLIENT_MAC is randomized - network tracked but client skipped"
        else
            client_entry=$(sqlite3 "$DB_FILE" "SELECT best_quality, crackable FROM clients WHERE bssid='${AP_MAC//\'/\'\''}' AND client_mac='${CLIENT_MAC//\'/\'\''}' LIMIT 1;" 2>/dev/null)
        
        if [[ -z "$client_entry" ]]; then
            # NEW CLIENT for this network
            db_exec "INSERT INTO clients (bssid, client_mac, first_seen, last_seen, capture_count, best_quality, crackable, best_pcap_path, best_hashcat_path) VALUES ('${AP_MAC//\'/\'\''}', '${CLIENT_MAC//\'/\'\''}', $timestamp, $timestamp, 1, '$CURRENT_QUALITY', $crackable_int, '${PCAP_PATH//\'/\'\''}', '${HASHCAT_PATH//\'/\'\''}') ON CONFLICT(bssid, client_mac) DO UPDATE SET last_seen=$timestamp, capture_count=capture_count+1;"
            debug_log "New client detected: $CLIENT_MAC for $SSID ($AP_MAC) with quality $CURRENT_QUALITY"
            
            # Only alert if not randomized MAC
            if [[ $ALERT_NEW_CLIENT -eq 1 && $is_randomized -eq 0 ]]; then
                alert_message "NEW CLIENT DETECTED" "$SSID" "$AP_MAC" "Client: $CLIENT_MAC\nQuality: $CURRENT_QUALITY"
            fi
        else
            # Existing client - check for quality improvement
            IFS='|' read -r client_quality client_crackable <<< "$client_entry"
            client_rank=$(quality_rank "$client_quality")
            debug_log "Existing client $CLIENT_MAC - DB quality: $client_quality (rank $client_rank), Current: $CURRENT_QUALITY (rank $CURRENT_RANK)"
            
            if [[ $CURRENT_RANK -gt $client_rank ]]; then
                # Quality improved for this specific client-AP pair - update with new file paths
                db_exec "UPDATE clients SET last_seen=$timestamp, capture_count=capture_count+1, best_quality='$CURRENT_QUALITY', crackable=$crackable_int, best_pcap_path='${PCAP_PATH//\'/\'\'}', best_hashcat_path='${HASHCAT_PATH//\'/\'\'}'  WHERE bssid='${AP_MAC//\'/\'\'}'  AND client_mac='${CLIENT_MAC//\'/\'\'}';"
                debug_log "Client quality improved from $client_quality to $CURRENT_QUALITY"
                
                # Only alert if not randomized MAC
                if [[ $ALERT_QUALITY_IMPROVED -eq 1 && $is_randomized -eq 0 ]]; then
                    alert_message "CLIENT QUALITY IMPROVED" "$SSID" "$AP_MAC" "Client: $CLIENT_MAC\nPrevious: $client_quality\nNew: $CURRENT_QUALITY"
                fi
            else
                # No quality improvement - just update metadata
                db_exec "UPDATE clients SET last_seen=$timestamp, capture_count=capture_count+1, crackable=$crackable_int WHERE bssid='${AP_MAC//\'/\'\'}'  AND client_mac='${CLIENT_MAC//\'/\'\'}';"
                debug_log "Updated existing client $CLIENT_MAC (no quality change)"
            fi
        fi        
    fi
    
    # Check if quality improved
    if [[ $CURRENT_RANK -gt $DB_RANK ]]; then
        debug_log "Quality improved. ALERT_QUALITY_IMPROVED=$ALERT_QUALITY_IMPROVED"
        if [[ $ALERT_QUALITY_IMPROVED -eq 1 ]]; then
            debug_log "Sending QUALITY IMPROVED alert"
            alert_message "QUALITY IMPROVED" "$SSID" "$AP_MAC" "Previous: $db_quality\nNew: $CURRENT_QUALITY"
        fi
    elif [[ "$db_crackable" != "1" ]] && [[ $ACTUAL_CRACKABLE -eq 1 ]]; then
        # Network was not crackable before, now it is
        debug_log "Sending NOW CRACKABLE alert"
        alert_message "NOW CRACKABLE" "$SSID" "$AP_MAC" "Quality: $CURRENT_QUALITY"
    else
        debug_log "No alert condition met: rank not improved and already crackable"
    fi
fi

debug_log "Exiting normally"
exit 0
