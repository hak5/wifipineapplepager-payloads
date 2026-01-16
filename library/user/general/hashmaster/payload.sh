#!/bin/bash
# Title: HashMaster22000
# Description: Analyze current collection and detect new/improved captures from any source
# Author:  spencershepard
# Version:  5.1
# Category: general

ANALYSIS_PAYLOAD_VERSION="5.1"

# Configuration
DB_FILE="/root/hashmaster.db"
HANDSHAKE_DIR="${1:-/root/loot/handshakes}"

# Source shared database initialization script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HSMANAGER="${SCRIPT_DIR}/hashmaster.sh"
if [[ -f "$HSMANAGER" ]]; then
    source "$HSMANAGER"
else
    LOG red "ERROR: Cannot find hashmaster.sh at $HSMANAGER" >&2
    exit 1
fi

debug_log "========================================"
debug_log "HashMaster Analysis Payload v${ANALYSIS_PAYLOAD_VERSION}"
debug_log "HashMaster Library v${HASHMASTER_LIB_VERSION}"
debug_log "Scanning directory: $HANDSHAKE_DIR"

if [[ ! -d "$HANDSHAKE_DIR" ]]; then
    LOG red "Directory not found: $HANDSHAKE_DIR"
    exit 1
fi

# Install alert payload if not present (optional)
if install_alert_payload; then
    LOG green "Alert payload is installed (alerts will be enabled)"
else
    LOG yellow "Alert payload not installed (alerts will not be enabled)"
fi

LOG "Scanning $HANDSHAKE_DIR"

# Temporary files
TEMP_DATA=$(mktemp)
TEMP_QUALITY=$(mktemp)
TEMP_HIGH_VALUE=$(mktemp)
trap "rm -f $TEMP_DATA $TEMP_QUALITY $TEMP_HIGH_VALUE" EXIT

# Parse . 22000 files
parse_handshakes() {
    local line_count=0
    local found_any=false
    local file_count=0

    # Count .22000 files
    file_count=$(find "$HANDSHAKE_DIR" -name "*.22000" -type f 2>/dev/null | wc -l)
    if [[ $file_count -eq 0 ]]; then
        LOG yellow "WARNING: No .22000 files found in $HANDSHAKE_DIR"
        return 1
    fi

    
    LOG "Extracting hash lines from $file_count .22000 files..."
    
    # Use grep -H to include filenames (fast batch processing)
    while IFS= read -r file_and_line; do
        found_any=true
        ((line_count++))
        
        # Progress every 100 hashes
        if (( line_count % 100 == 0 )); then
            LOG "Processed $line_count handshakes..."
        fi
        
        # Split filename from hash line (grep -H output: "filename:line")
        local hashcat_file="${file_and_line%%:*}"
        local line="${file_and_line#*:}"
        local pcap_file="${hashcat_file%.22000}.pcap"
        
        IFS='*' read -ra fields <<< "$line"
        
        local type="${fields[1]}"
        local ap_mac="${fields[3]}"
        local client_mac="${fields[4]}"
        local ssid_hex="${fields[5]}"
        
        # Normalize MAC addresses to uppercase with colons for consistency
        ap_mac=$(echo "$ap_mac" | sed 's/../&:/g;s/:$//' | tr 'a-z' 'A-Z')
        client_mac=$(echo "$client_mac" | sed 's/../&:/g;s/:$//' | tr 'a-z' 'A-Z')
        
        # Convert SSID (fast pure bash, no external process)
        local ssid=$(hex_to_ascii "$ssid_hex" 2>/dev/null)
        # Check if conversion failed or contains non-printable chars
        if [[ -z "$ssid" ]] || [[ "$ssid" =~ [^[:print:]] ]]; then
            ssid="UNKNOWN_SSID"
        fi
        
        # Determine type
        local type_name="UNKNOWN"
        [[ "$type" == "01" ]] && type_name="PMKID"
        [[ "$type" == "02" ]] && type_name="EAPOL"
        
        # Validate crackability
        local quality_status
        quality_status=$(validate_crackable "$line")
        
        local quality="${quality_status%%:*}"
        local detail="${quality_status##*:}"
        detail="${detail# }"  # Strip leading space
        
        # Store data with file paths (include client_mac in TEMP_QUALITY for reliable extraction)
        echo "$ssid|$ap_mac|$client_mac|$type_name" >> "$TEMP_DATA"
        echo "$ssid|$ap_mac|$client_mac|$quality|$detail|$type_name|$pcap_file|$hashcat_file" >> "$TEMP_QUALITY"
        
    done < <(find "$HANDSHAKE_DIR" -name "*.22000" -type f -exec grep -H "^WPA" {} + 2>/dev/null)
    
    if ! $found_any; then
        return 1
    fi
    
    LOG "Parsed $line_count handshakes total"
    
    return 0
}

# Detect new and improved captures by comparing filesystem to DB
detect_high_value() {
    LOG "Analyzing quality and detecting high value captures..."
    
    local new_count=0
    local improvement_count=0
    
    # Build associative arrays for fast lookups (eliminates nested grep loops)
    declare -A pair_counts pair_best_quality pair_best_rank pair_crackable pair_best_pcap pair_best_hashcat
    declare -A client_best_quality client_best_rank client_crackable client_best_pcap client_best_hashcat
    
    LOG "Building quality index..."
    
    # First pass: count occurrences
    while IFS='|' read -r ssid bssid client _; do
        local key="$ssid|$bssid"
        ((pair_counts[$key]++))
    done < "$TEMP_DATA"
    
    # Second pass: determine best quality with file paths
    while IFS='|' read -r ssid bssid client_mac quality detail _ pcap_path hashcat_path; do
        local key="$ssid|$bssid"
        
        if [[ "$quality" == "CRACKABLE" ]]; then
            pair_crackable[$key]=1
            local rank=$(quality_rank "$detail")
            
            # Track best for network (SSID|BSSID)
            if [[ -z "${pair_best_rank[$key]}" ]] || [[ $rank -gt ${pair_best_rank[$key]} ]]; then
                pair_best_rank[$key]=$rank
                pair_best_quality[$key]="$detail"
                pair_best_pcap[$key]="$pcap_path"
                pair_best_hashcat[$key]="$hashcat_path"
            fi
            
            # Track best for client using hash line data (reliable)
            # Validate MAC format: should have colons and uppercase (already normalized)
            # Skip randomized MACs if filtering enabled
            if [[ $TRACK_CLIENTS -eq 1 && -n "$client_mac" ]] && [[ "$client_mac" =~ ^[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}$ ]]; then
                # Check if MAC is randomized
                local skip_client=0
                if [[ $FILTER_RANDOMIZED_MACS -eq 1 ]] && is_randomized_mac "$client_mac"; then
                    debug_log "Skipping randomized MAC: $client_mac"
                    skip_client=1
                fi
                
                if [[ $skip_client -eq 0 ]]; then
                    local client_key="$bssid|$client_mac"
                    
                    if [[ -z "${client_best_rank[$client_key]}" ]] || [[ $rank -gt ${client_best_rank[$client_key]} ]]; then
                        client_best_rank[$client_key]=$rank
                        client_best_quality[$client_key]="$detail"
                        client_crackable[$client_key]=1
                        client_best_pcap[$client_key]="$pcap_path"
                        client_best_hashcat[$client_key]="$hashcat_path"
                    fi
                fi
            fi
        fi
    done < "$TEMP_QUALITY"
    
    LOG "Comparing with database (${#pair_counts[@]} unique networks)..."
    
    # Get all DB entries in one query
    local db_data=$(sqlite3 "$DB_FILE" "SELECT ssid, bssid, best_quality, total_captures, first_seen FROM handshakes;" 2>/dev/null)
    
    # Build DB lookup
    declare -A db_quality db_total db_first_seen
    while IFS='|' read -r ssid bssid quality total first_seen; do
        local key="$ssid|$bssid"
        db_quality[$key]="$quality"
        db_total[$key]="$total"
        db_first_seen[$key]="$first_seen"
    done <<< "$db_data"
    
    # Prepare batch SQL operations
    local timestamp=$(date +%s)
    local sql_inserts=""
    local sql_updates=""
    local processed=0
    local total_pairs=${#pair_counts[@]}
    
    # Process each unique SSID/BSSID pair
    for key in "${!pair_counts[@]}"; do
        ((processed++))
        
        # Progress every 100 networks
        if (( processed % 100 == 0 )); then
            LOG "Processed $processed/$total_pairs networks..."
        fi
        
        IFS='|' read -r ssid bssid <<< "$key"
        
        local file_count=${pair_counts[$key]}
        local best_quality=${pair_best_quality[$key]:-NONE}
        local best_rank=${pair_best_rank[$key]:-0}
        local is_crackable=${pair_crackable[$key]:-0}
        local best_pcap=${pair_best_pcap[$key]:-}
        local best_hashcat=${pair_best_hashcat[$key]:-}
        
        # Escape single quotes for SQL
        local ssid_sql="${ssid//\'/\'\'}"
        local bssid_sql="${bssid//\'/\'\'}"
        local quality_sql="${best_quality//\'/\'\'}"
        local pcap_sql="${best_pcap//\'/\'\'}"
        local hashcat_sql="${best_hashcat//\'/\'\'}"
        
        if [[ -z "${db_quality[$key]}" ]]; then
            # NEW NETWORK
            if [[ $is_crackable -eq 1 ]]; then
                echo "NEW|$ssid|$bssid|$best_quality" >> "$TEMP_HIGH_VALUE"
                ((new_count++))
            fi
            
            sql_inserts+="INSERT INTO handshakes (ssid, bssid, best_quality, first_seen, last_seen, total_captures, crackable, best_pcap_path, best_hashcat_path) VALUES ('$ssid_sql', '$bssid_sql', '$quality_sql', $timestamp, $timestamp, $file_count, $is_crackable, '$pcap_sql', '$hashcat_sql');\n"
        else
            # EXISTING NETWORK
            local db_qual="${db_quality[$key]}"
            local existing_rank=$(quality_rank "$db_qual")
            
            if [[ $best_rank -gt $existing_rank ]] && [[ $is_crackable -eq 1 ]]; then
                echo "IMPROVED|$ssid|$bssid|$db_qual|$best_quality" >> "$TEMP_HIGH_VALUE"
                ((improvement_count++))
            fi
            
            local update_quality="$db_qual"
            local update_pcap="$pcap_sql"
            local update_hashcat="$hashcat_sql"
            if [[ $best_rank -gt $existing_rank ]]; then
                update_quality="$best_quality"
                # Quality improved - update file paths too
                sql_updates+="UPDATE handshakes SET best_quality='${update_quality//\'/\'\'}', last_seen=$timestamp, total_captures=$file_count, crackable=$is_crackable, best_pcap_path='$pcap_sql', best_hashcat_path='$hashcat_sql' WHERE ssid='$ssid_sql' AND bssid='$bssid_sql';\n"
            else
                # No improvement - don't update file paths
                sql_updates+="UPDATE handshakes SET best_quality='${update_quality//\'/\'\'}', last_seen=$timestamp, total_captures=$file_count, crackable=$is_crackable WHERE ssid='$ssid_sql' AND bssid='$bssid_sql';\n"
            fi
        fi
    done
    
    # Process clients table
    LOG "Processing client captures..."
    local client_inserts=""
    local client_updates=""
    
    # Get existing client data
    local client_db_data=$(sqlite3 "$DB_FILE" "SELECT bssid, client_mac, best_quality FROM clients;" 2>/dev/null)
    declare -A client_db_quality
    while IFS='|' read -r bssid client quality; do
        local ckey="$bssid|$client"
        client_db_quality[$ckey]="$quality"
    done <<< "$client_db_data"
    
    # Insert/update clients
    for client_key in "${!client_best_quality[@]}"; do
        IFS='|' read -r bssid client <<< "$client_key"
        
        local c_quality=${client_best_quality[$client_key]}
        local c_rank=${client_best_rank[$client_key]}
        local c_crackable=${client_crackable[$client_key]:-0}
        local c_pcap=${client_best_pcap[$client_key]:-}
        local c_hashcat=${client_best_hashcat[$client_key]:-}
        
        # Escape for SQL
        local c_bssid_sql="${bssid//\'/\'\'}"
        local c_client_sql="${client//\'/\'\'}"
        local c_quality_sql="${c_quality//\'/\'\'}"
        local c_pcap_sql="${c_pcap//\'/\'\'}"
        local c_hashcat_sql="${c_hashcat//\'/\'\'}"
        
        if [[ -z "${client_db_quality[$client_key]}" ]]; then
            # New client
            client_inserts+="INSERT INTO clients (bssid, client_mac, first_seen, last_seen, capture_count, best_quality, crackable, best_pcap_path, best_hashcat_path) VALUES ('$c_bssid_sql', '$c_client_sql', $timestamp, $timestamp, 1, '$c_quality_sql', $c_crackable, '$c_pcap_sql', '$c_hashcat_sql');\n"
        else
            # Existing client - check for improvement
            local db_c_rank=$(quality_rank "${client_db_quality[$client_key]}")
            if [[ $c_rank -gt $db_c_rank ]]; then
                # Quality improved - update with new paths
                client_updates+="UPDATE clients SET last_seen=$timestamp, capture_count=capture_count+1, best_quality='$c_quality_sql', crackable=$c_crackable, best_pcap_path='$c_pcap_sql', best_hashcat_path='$c_hashcat_sql' WHERE bssid='$c_bssid_sql' AND client_mac='$c_client_sql';\n"
            else
                # No improvement
                client_updates+="UPDATE clients SET last_seen=$timestamp, capture_count=capture_count+1, crackable=$c_crackable WHERE bssid='$c_bssid_sql' AND client_mac='$c_client_sql';\n"
            fi
        fi
    done
    
    # Execute batch SQL operations with database locking
    LOG "Updating database..."
    
    if [[ -n "$sql_inserts" ]]; then
        LOG "Processing network inserts..."
        db_exec_batch "$sql_inserts"
    fi
    
    if [[ -n "$sql_updates" ]]; then
        LOG "Processing network updates..."
        db_exec_batch "$sql_updates"
    fi
    
    if [[ -n "$client_inserts" ]]; then
        LOG "Processing client inserts..."
        db_exec_batch "$client_inserts"
    fi
    
    if [[ -n "$client_updates" ]]; then
        LOG "Processing client updates..."
        db_exec_batch "$client_updates"
    fi
    
    # Clear file paths for networks where the stored files no longer exist on disk
    LOG "Cleaning up database - verifying stored file paths..."
    local cleared_count=0
    local cleanup_sql=""
    
    # Get all networks with stored file paths
    while IFS='|' read -r ssid bssid pcap_path hashcat_path; do
        local needs_cleanup=0
        
        # Check if stored pcap file no longer exists
        if [[ -n "$pcap_path" ]] && [[ ! -f "$pcap_path" ]]; then
            needs_cleanup=1
            debug_log "PCAP file missing: $pcap_path"
        fi
        
        # Check if stored hashcat file no longer exists
        if [[ -n "$hashcat_path" ]] && [[ ! -f "$hashcat_path" ]]; then
            needs_cleanup=1
            debug_log "Hashcat file missing: $hashcat_path"
        fi
        
        # Clear paths if files are missing
        if [[ $needs_cleanup -eq 1 ]]; then
            local ssid_sql="${ssid//\'/\'\'}" 
            local bssid_sql="${bssid//\'/\'\'}" 
            cleanup_sql+="UPDATE handshakes SET best_pcap_path='', best_hashcat_path='' WHERE ssid='$ssid_sql' AND bssid='$bssid_sql';\n"
            cleanup_sql+="UPDATE clients SET best_pcap_path='', best_hashcat_path='' WHERE bssid='$bssid_sql';\n"
            ((cleared_count++))
        fi
    done <<< "$(db_exec "SELECT ssid, bssid, best_pcap_path, best_hashcat_path FROM handshakes WHERE best_pcap_path != '' OR best_hashcat_path != '';")"
    
    # Execute cleanup in a single transaction
    if [[ -n "$cleanup_sql" ]]; then
        db_exec_batch "$cleanup_sql"
    fi
    
    if [[ $cleared_count -gt 0 ]]; then
        LOG "Cleared file paths for $cleared_count networks (files deleted from disk)"
    fi
    
    LOG "Found $new_count new networks, $improvement_count improvements"
}

# Initialize database
if ! init_handshake_database "$DB_FILE"; then
    ERROR_DIALOG "Failed to initialize handshake tracking database at $DB_FILE"
    exit 1
fi

# Acquire global lock to prevent conflicts with alert payloads
# Uses same lock file as alert_payload.sh for mutual exclusion
LOCK_FILE="/tmp/hashmaster_alert.lock"
LOCK_FD=200

acquire_lock() {
    exec 200>"$LOCK_FILE"
    local timeout=30  # Maximum 30s wait (user payload can wait longer than alerts)
    local elapsed=0
    
    while ! flock -n 200; do
        if [[ $elapsed -ge $timeout ]]; then
            ERROR_DIALOG "Failed to acquire lock after ${timeout}s - alert payloads still processing"
            exit 1
        fi
        sleep 1
        ((elapsed++))
    done
    [[ $elapsed -gt 0 ]] && LOG "Waited ${elapsed}s for alert processing to complete"
}

release_lock() {
    flock -u 200 2>/dev/null
}

# Acquire lock before any database operations
acquire_lock

# Ensure lock is released on exit
trap release_lock EXIT

# Parse files and detect high value captures
if parse_handshakes; then
    detect_high_value
    LOG "Filesystem scan complete"
else
    LOG "No .22000 files found in $HANDSHAKE_DIR - showing database-only statistics"
    # Create empty temp files so statistics generation doesn't fail
    > "$TEMP_DATA"
    > "$TEMP_QUALITY"
fi

# Generate statistics
LOG "Generating statistics..."

total_handshakes=$(wc -l < "$TEMP_DATA" | tr -d ' ')
unique_ssids=$(cut -d'|' -f1 "$TEMP_DATA" 2>/dev/null | sort -u | wc -l | tr -d ' ')
unique_bssids=$(cut -d'|' -f2 "$TEMP_DATA" 2>/dev/null | sort -u | wc -l | tr -d ' ')
unique_clients=$(cut -d'|' -f3 "$TEMP_DATA" 2>/dev/null | sort -u | wc -l | tr -d ' ')
pmkid_count=$(grep -c "|PMKID$" "$TEMP_DATA" 2>/dev/null | tr -d ' ' || echo 0)
eapol_count=$(grep -c "|EAPOL$" "$TEMP_DATA" 2>/dev/null | tr -d ' ' || echo 0)

crackable_count=$(grep -c "^[^|]*|[^|]*|[^|]*|CRACKABLE|" "$TEMP_QUALITY" 2>/dev/null | tr -d ' ' || echo 0)
invalid_count=$(grep -c "^[^|]*|[^|]*|[^|]*|INVALID|" "$TEMP_QUALITY" 2>/dev/null | tr -d ' ' || echo 0)
questionable_count=$(grep -c "^[^|]*|[^|]*|[^|]*|QUESTIONABLE|" "$TEMP_QUALITY" 2>/dev/null | tr -d ' ' || echo 0)
best_quality_count=$(grep -c "|EAPOL_M2M3_BEST|" "$TEMP_QUALITY" 2>/dev/null | tr -d ' ' || echo 0)

crackable_pct=0
[[ $total_handshakes -gt 0 ]] && crackable_pct=$((crackable_count * 100 / total_handshakes))

# DB statistics
db_total_networks=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM handshakes;" 2>/dev/null || echo 0)
db_crackable_networks=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM handshakes WHERE crackable=1;" 2>/dev/null || echo 0)
db_total_captures=$(sqlite3 "$DB_FILE" "SELECT SUM(total_captures) FROM handshakes;" 2>/dev/null || echo 0)

# Display overview
LOG "======================================"
LOG cyan "[HANDSHAKE COLLECTION ANALYSIS]"
LOG "======================================"
LOG ""
LOG blue "[CURRENT COLLECTION - Filesystem]"
LOG "   Handshakes on Disk: $total_handshakes"
LOG "   Unique SSIDs: $unique_ssids"
LOG "   Unique Access Points: $unique_bssids"
LOG "   Unique Clients: $unique_clients"
LOG ""
LOG blue "[CAPTURE TYPES]"
LOG "   PMKID: $pmkid_count"
LOG "   EAPOL: $eapol_count"
LOG ""
LOG blue "[QUALITY ASSESSMENT]"
if [[ $crackable_count -gt 0 ]]; then
    LOG green "   Crackable: $crackable_count ($crackable_pct%)"
else
    LOG red "   Crackable: $crackable_count ($crackable_pct%)"
fi
LOG yellow "   Best Quality (M2+M3): $best_quality_count"
LOG "   Invalid/Incomplete: $invalid_count"
LOG "   Questionable: $questionable_count"
LOG ""
LOG blue "[HISTORICAL TRACKING - All Time]"
LOG "   Networks Ever Seen: $db_total_networks"
LOG "   Crackable Networks: $db_crackable_networks"
LOG "   Total Captures (lifetime): $db_total_captures"
LOG ""

# Show high value discoveries
if [[ -f "$TEMP_HIGH_VALUE" ]] && [[ -s "$TEMP_HIGH_VALUE" ]]; then
    LOG "======================================"
    LOG green "[*** HIGH VALUE DISCOVERIES ***]"
    LOG ""
    
    # Show new networks
    grep "^NEW|" "$TEMP_HIGH_VALUE" | while IFS='|' read -r type ssid bssid quality; do
        LOG green "[NEW] $ssid ($bssid)"
        LOG "      Quality: $quality"
        LOG yellow "      This is the FIRST capture of this network!"
        LOG ""
    done
    
    # Show improvements
    grep "^IMPROVED|" "$TEMP_HIGH_VALUE" | while IFS='|' read -r type ssid bssid old_quality new_quality; do
        LOG cyan "[IMPROVED] $ssid ($bssid)"
        LOG "      Previous:  $old_quality"
        LOG "      New: $new_quality"
        LOG yellow "      Quality has improved!"
        LOG ""
    done
    
    LOG "======================================"
fi

LOG cyan "[DETAILED SSID BREAKDOWN]"
LOG ""

# Pre-compute ALL stats into associative arrays
declare -A ssid_total ssid_pmkid ssid_eapol ssid_crackable ssid_best ssid_invalid ssid_questionable
declare -A ssid_bssids ssid_clients
declare -A bssid_total bssid_crackable bssid_best bssid_pmkid bssid_eapol bssid_invalid

# Build stats from TEMP_DATA
while IFS='|' read -r ssid bssid client type_name; do
    skey="$ssid"
    bkey="$ssid|$bssid"
    
    ((ssid_total[$skey]++))
    [[ "$type_name" == "PMKID" ]] && ((ssid_pmkid[$skey]++))
    [[ "$type_name" == "EAPOL" ]] && ((ssid_eapol[$skey]++))
    
    ((bssid_total[$bkey]++))
    [[ "$type_name" == "PMKID" ]] && ((bssid_pmkid[$bkey]++))
    [[ "$type_name" == "EAPOL" ]] && ((bssid_eapol[$bkey]++))
    
    # Track unique BSSIDs and clients per SSID
    if [[ -z "${ssid_bssids[$skey]}" ]]; then
        ssid_bssids[$skey]="$bssid"
    elif [[ ! "${ssid_bssids[$skey]}" =~ (^|,)"$bssid"(,|$) ]]; then
        ssid_bssids[$skey]="${ssid_bssids[$skey]},$bssid"
    fi
    
    if [[ -z "${ssid_clients[$skey]}" ]]; then
        ssid_clients[$skey]="$client"
    elif [[ ! "${ssid_clients[$skey]}" =~ (^|,)"$client"(,|$) ]]; then
        ssid_clients[$skey]="${ssid_clients[$skey]},$client"
    fi
done < <(cat "$TEMP_DATA")

# Build quality stats from TEMP_QUALITY
while IFS='|' read -r ssid bssid client_mac quality detail type_name pcap_path hashcat_path; do
    skey="$ssid"
    bkey="$ssid|$bssid"
    
    [[ "$quality" == "CRACKABLE" ]] && ((ssid_crackable[$skey]++))
    [[ "$detail" == "EAPOL_M2M3_BEST" ]] && ((ssid_best[$skey]++))
    [[ "$quality" == "INVALID" ]] && ((ssid_invalid[$skey]++))
    [[ "$quality" == "QUESTIONABLE" ]] && ((ssid_questionable[$skey]++))
    
    [[ "$quality" == "CRACKABLE" ]] && ((bssid_crackable[$bkey]++))
    [[ "$detail" == "EAPOL_M2M3_BEST" ]] && ((bssid_best[$bkey]++))
    [[ "$quality" == "INVALID" ]] && ((bssid_invalid[$bkey]++))
done < <(cat "$TEMP_QUALITY")

LOG "Generating detailed per-SSID breakdown..."
LOG ""

# Now report using only lookups (no grep!)
for ssid in "${!ssid_total[@]}"; do
    total=${ssid_total[$ssid]}
    pmkid=${ssid_pmkid[$ssid]:-0}
    eapol=${ssid_eapol[$ssid]:-0}
    crackable=${ssid_crackable[$ssid]:-0}
    best=${ssid_best[$ssid]:-0}
    invalid=${ssid_invalid[$ssid]:-0}
    questionable=${ssid_questionable[$ssid]:-0}
    
    # Count unique BSSIDs and clients
    bssid_count=$(echo "${ssid_bssids[$ssid]}" | tr ',' '\n' | wc -l)
    client_count=$(echo "${ssid_clients[$ssid]}" | tr ',' '\n' | wc -l)
    
    # Determine status
    status_icon="[? ]"
    status_text="UNKNOWN"
    status_color=""
    
    if [[ $invalid -eq $total ]]; then
        status_icon="[X]"
        status_text="ALL INVALID"
        status_color="red"
    elif [[ $best -gt 0 ]]; then
        status_icon="[***]"
        status_text="EXCELLENT"
        status_color="green"
    elif [[ $crackable -gt 0 ]]; then
        status_icon="[OK]"
        status_text="READY"
        status_color="yellow"
    elif [[ $questionable -gt 0 ]]; then
        status_icon="[! ]"
        status_text="QUESTIONABLE"
        status_color="orange"
    else
        status_icon="[X]"
        status_text="NOT CRACKABLE"
        status_color="red"
    fi
    
    LOG "$status_color" "$status_icon $ssid [$status_text]"
    LOG "   |-- Handshakes on Disk: $total"
    LOG "   |-- Crackable: $crackable"
    
    if [[ $pmkid -gt 0 ]] && [[ $eapol -gt 0 ]]; then
        LOG "   |-- Types: PMKID ($pmkid), EAPOL ($eapol)"
    elif [[ $pmkid -gt 0 ]]; then
        LOG "   |-- Type: PMKID ($pmkid)"
    elif [[ $eapol -gt 0 ]]; then
        LOG "   |-- Type:  EAPOL ($eapol)"
    fi
    
    [[ $best -gt 0 ]] && LOG "   |-- Quality: $best BEST (M2+M3)"
    [[ $invalid -gt 0 ]] && LOG "   |-- Invalid/Incomplete: $invalid"
    [[ $questionable -gt 0 ]] && LOG "   |-- Questionable: $questionable"
    
    LOG "   |-- Unique Clients: $client_count"
    LOG "   +-- Access Point(s) [$bssid_count]:"
    
    # Split BSSIDs and iterate
    IFS=',' read -ra bssid_array <<< "${ssid_bssids[$ssid]}"
    for bssid in "${bssid_array[@]}"; do
        bkey="$ssid|$bssid"
        
        # All stats are pre-computed - just lookup!
        bssid_tot=${bssid_total[$bkey]:-0}
        bssid_crack=${bssid_crackable[$bkey]:-0}
        bssid_bst=${bssid_best[$bkey]:-0}
        bssid_pmk=${bssid_pmkid[$bkey]:-0}
        bssid_eap=${bssid_eapol[$bkey]:-0}
        bssid_inv=${bssid_invalid[$bkey]:-0}
        
        # Get DB info
        db_info=$(sqlite3 "$DB_FILE" "SELECT first_seen, total_captures FROM handshakes WHERE ssid='$ssid' AND bssid='$bssid';" 2>/dev/null)
        db_suffix=""
        if [[ -n "$db_info" ]]; then
            IFS='|' read -r db_first db_total <<< "$db_info"
            db_date=$(date -d "@$db_first" "+%Y-%m-%d" 2>/dev/null || date -r "$db_first" "+%Y-%m-%d" 2>/dev/null || echo "unknown")
            db_suffix=" [DB: $db_total lifetime, first: $db_date]"
        fi
        
        # Check if this is a high value discovery
        hv_marker=""
        if grep -q "^NEW|$ssid|$bssid|" "$TEMP_HIGH_VALUE" 2>/dev/null; then
            hv_marker=" <<< NEW NETWORK"
        elif grep -q "^IMPROVED|$ssid|$bssid|" "$TEMP_HIGH_VALUE" 2>/dev/null; then
            hv_marker=" <<< QUALITY IMPROVED"
        fi
        
        type_str=""
        [[ $bssid_pmk -gt 0 ]] && type_str="${type_str}PMKID: $bssid_pmk "
        [[ $bssid_eap -gt 0 ]] && type_str="${type_str}EAPOL:$bssid_eap "
        
        if [[ $bssid_inv -eq $bssid_tot ]]; then
            LOG "       |-- [X] $bssid:  $bssid_tot on disk, ALL INVALID ($type_str)$db_suffix$hv_marker"
        elif [[ $bssid_bst -gt 0 ]]; then
            LOG "       |-- [***] $bssid: $bssid_tot on disk, $bssid_crack crackable, $bssid_bst BEST ($type_str)$db_suffix$hv_marker"
        elif [[ $bssid_crack -gt 0 ]]; then
            LOG "       |-- [OK] $bssid: $bssid_tot on disk, $bssid_crack crackable ($type_str)$db_suffix$hv_marker"
        else
            LOG "       |-- [X] $bssid: $bssid_tot on disk, 0 crackable ($type_str)$db_suffix$hv_marker"
        fi
    done
    
    LOG ""
done

LOG "======================================"

if [[ $crackable_count -eq 0 ]]; then
    LOG "[WARNING] No crackable handshakes found!"
elif [[ $crackable_pct -lt 50 ]]; then
    LOG "[WARNING] Low quality:  Only $crackable_pct% crackable."
else
    LOG "[OK] Analysis complete! $crackable_count/$total_handshakes crackable ($crackable_pct%)"
fi

LOG "Database updated:  $db_total_networks networks tracked, $db_total_captures lifetime captures"

exit 0