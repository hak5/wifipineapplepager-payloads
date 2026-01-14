#!/bin/bash
# Title: HashMaster Alert
# Description: Handshake smart alerts for new networks, quality improvements, and status changes
# Author:  spencershepard
# Version:  1.0

# Alert options are set via hashmaster.sh, not here

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

debug_log "Processing handshake alert for BSSID: $AP_MAC, Type: $TYPE, Crackable: $CRACKABLE"
debug_log "$(env)"

# Initialize database if needed
if ! init_handshake_database "$DB_FILE"; then
    ERROR_DIALOG "Failed to initialize handshake tracking database at $DB_FILE"
    exit 1
fi

# Get SSID
SSID=$(get_ssid "$DB_FILE" "$AP_MAC" "$HASHCAT_PATH")
debug_log "SSID determined: $SSID"

# Validate crackability - compare our logic vs Pager assessment
local VALIDATED_CRACKABLE=0
if [[ -f "$HASHCAT_PATH" ]]; then
    local hash_line=$(grep "^WPA" "$HASHCAT_PATH" | head -1)
    if [[ -n "$hash_line" ]]; then
        local validation_result=$(validate_crackable "$hash_line" 2>&1)
        local validation_status="${validation_result%%:*}"
        if [[ "$validation_status" == "CRACKABLE" ]]; then
            VALIDATED_CRACKABLE=1
        fi
        debug_log "Our validation: '$validation_result' -> crackable=$VALIDATED_CRACKABLE"
    else
        debug_log "No WPA hash line found in $HASHCAT_PATH"
    fi
else
    debug_log "Hash file not found: $HASHCAT_PATH"
fi

# Use Pager's assessment (proven accurate), but log comparison
local ACTUAL_CRACKABLE=0
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
debug_log "DB query result: '$DB_ENTRY'"

if [[ -z "$DB_ENTRY" ]]; then
    # NEW NETWORK
    debug_log "New network detected. ALERT_NEW_NETWORK=$ALERT_NEW_NETWORK"
    if [[ $ALERT_NEW_NETWORK -eq 1 ]]; then
        debug_log "Sending NEW NETWORK alert"
        local alert_title="NEW NETWORK"
        [[ $ACTUAL_CRACKABLE -eq 1 ]] && alert_title="NEW CRACKABLE NETWORK"
        alert_message "$alert_title" "$SSID" "$AP_MAC" "Quality: $CURRENT_QUALITY\nType: $TYPE\nCrackable: $([ $ACTUAL_CRACKABLE -eq 1 ] && echo 'Yes' || echo 'No')"
    fi
    
    # Add to database to prevent duplicate alerts
    local timestamp=$(date +%s)
    local crackable_int=$ACTUAL_CRACKABLE
    
    db_exec "INSERT OR IGNORE INTO handshakes (ssid, bssid, best_quality, first_seen, last_seen, total_captures, crackable, best_pcap_path, best_hashcat_path) VALUES ('${SSID//\'/\'\'}', '${AP_MAC//\'/\'\'}', '$CURRENT_QUALITY', $timestamp, $timestamp, 1, $crackable_int, '${PCAP_PATH//\'/\'\'}', '${HASHCAT_PATH//\'/\'\'}');"
    debug_log "Inserted new network into database"
    
    # Track client if present and client tracking enabled
    if [[ $TRACK_CLIENTS -eq 1 && -n "$CLIENT_MAC" ]]; then
        local is_randomized=0
        if [[ $FILTER_RANDOMIZED_MACS -eq 1 ]] && is_randomized_mac "$CLIENT_MAC"; then
            is_randomized=1
            debug_log "Client MAC $CLIENT_MAC is randomized (will track but not alert)"
        fi
        
        db_exec "INSERT OR IGNORE INTO clients (bssid, client_mac, first_seen, last_seen, capture_count, best_quality, crackable, best_pcap_path, best_hashcat_path) VALUES ('${AP_MAC//\'/\'\'}', '${CLIENT_MAC//\'/\'\'}', $timestamp, $timestamp, 1, '$CURRENT_QUALITY', $crackable_int, '${PCAP_PATH//\'/\'\'}', '${HASHCAT_PATH//\'/\'\'}');"
        debug_log "Inserted new client $CLIENT_MAC for network $AP_MAC with quality $CURRENT_QUALITY"
    fi
else
    # EXISTING NETWORK - check for improvements
    IFS='|' read -r db_quality db_crackable <<< "$DB_ENTRY"
    debug_log "Existing network - DB quality: $db_quality, DB crackable: $db_crackable"
    
    DB_RANK=$(quality_rank "$db_quality")
    debug_log "Current rank: $CURRENT_RANK, DB rank: $DB_RANK"
    
    # Update database with latest timestamp and increment capture count
    local timestamp=$(date +%s)
    local crackable_int=$ACTUAL_CRACKABLE
    
    # Determine if quality should be updated (and file paths)
    local update_quality="$db_quality"
    if [[ $CURRENT_RANK -gt $DB_RANK ]]; then
        update_quality="$CURRENT_QUALITY"
        # Quality improved - update file paths to point to better capture
        db_exec "UPDATE handshakes SET best_quality='$update_quality', last_seen=$timestamp, total_captures=total_captures+1, crackable=$crackable_int, best_pcap_path='${PCAP_PATH//\'/\'\'}', best_hashcat_path='${HASHCAT_PATH//\'/\'\'}'  WHERE ssid='${SSID//\'/\'\'}' AND bssid='${AP_MAC//\'/\'\'}';"
    else
        # No quality improvement - just update metadata
        db_exec "UPDATE handshakes SET best_quality='$update_quality', last_seen=$timestamp, total_captures=total_captures+1, crackable=$crackable_int WHERE ssid='${SSID//\'/\'\'}' AND bssid='${AP_MAC//\'/\'\'}';"
    fi
    debug_log "Updated existing network in database"
    
    # Check for new client (if client tracking enabled)
    if [[ $TRACK_CLIENTS -eq 1 && -n "$CLIENT_MAC" ]]; then
        local is_randomized=0
        if [[ $FILTER_RANDOMIZED_MACS -eq 1 ]] && is_randomized_mac "$CLIENT_MAC"; then
            is_randomized=1
            debug_log "Client MAC $CLIENT_MAC is randomized (will track but not alert)"
        fi
        
        local client_entry=$(sqlite3 "$DB_FILE" "SELECT best_quality, crackable FROM clients WHERE bssid='${AP_MAC//\'/\'\'}'  AND client_mac='${CLIENT_MAC//\'/\'\'}' LIMIT 1;" 2>/dev/null)
        
        if [[ -z "$client_entry" ]]; then
            # NEW CLIENT for this network
            db_exec "INSERT INTO clients (bssid, client_mac, first_seen, last_seen, capture_count, best_quality, crackable, best_pcap_path, best_hashcat_path) VALUES ('${AP_MAC//\'/\'\'}', '${CLIENT_MAC//\'/\'\'}', $timestamp, $timestamp, 1, '$CURRENT_QUALITY', $crackable_int, '${PCAP_PATH//\'/\'\'}', '${HASHCAT_PATH//\'/\'\'}');"
            debug_log "New client detected: $CLIENT_MAC for $SSID ($AP_MAC) with quality $CURRENT_QUALITY"
            
            # Only alert if not randomized MAC
            if [[ $ALERT_NEW_CLIENT -eq 1 && $is_randomized -eq 0 ]]; then
                alert_message "NEW CLIENT DETECTED" "$SSID" "$AP_MAC" "Client: $CLIENT_MAC\nQuality: $CURRENT_QUALITY"
            fi
        else
            # Existing client - check for quality improvement
            IFS='|' read -r client_quality client_crackable <<< "$client_entry"
            local client_rank=$(quality_rank "$client_quality")
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

exit 0
