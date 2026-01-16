#!/bin/bash
# These functions are shared between user and alert metapayloads for Handshake Manager
# Version: 1.2

HASHMASTER_LIB_VERSION="1.2.1"

# Debug logging (1=enabled, 0=disabled)
DEBUG=1                          # Enable verbose debug logging to /root/hashmaster_debug.log

# Enable/disable specific alert types (1=enabled, 0=disabled) (affects alert payload behavior only)
ALERT_NEW_NETWORK=1              # Alert when a completely new network is captured (unique SSID/BSSID combo)
ALERT_QUALITY_IMPROVED=1         # Alert when capture quality improves (e.g., M1M2 -> M2M3)
ALERT_NEW_CLIENT=1               # Alert when a new client connects to a known network
ALERT_BEST_QUALITY_ONLY=0        # Only alert for EAPOL_M2M3_BEST quality captures
ALERT_NON_CRACKABLE=1            # Alert even if handshake is not crackable

# Client tracking settings
TRACK_CLIENTS=1                  # Enable tracking of clients in database (0=disable all client tracking)
FILTER_RANDOMIZED_MACS=1         # Filter out randomized MAC addresses (prevents spam from iOS/Android devices)

# Quality threshold (minimum quality rank to trigger alerts)
# 0=all, 2=PMKID+, 3=M3M4+, 4=M1M2+, 5=M2M3 only
MIN_QUALITY_RANK=2               # Only alert for PMKID quality or better


# You probably don't want to change anything below here
ALERT_PAYLOAD_SRC="/root/payloads/user/general/hashmaster/alert_payload.sh"
ALERT_PAYLOAD_DEST="/root/payloads/alerts/handshake_captured/hashmaster/payload.sh"
ALERT_PAYLOAD_DISABLED="/root/payloads/alerts/handshake_captured/DISABLED.hashmaster/payload.sh"

# Debug logging function - returns early if DEBUG not enabled
debug_log() {
    [[ $DEBUG -eq 1 ]] || return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> /tmp/hashmaster_debug.log
}

# Validate required SQL parameters - exits script if any are invalid
# Usage: validate_sql_params "param1_name" "$param1_value" "param2_name" "$param2_value" ...
validate_sql_params() {
    local all_valid=true
    while [[ $# -gt 0 ]]; do
        local param_name="$1"
        local param_value="$2"
        shift 2
        
        if [[ -z "$param_value" ]]; then
            debug_log "ERROR: SQL parameter '$param_name' is empty or unset"
            all_valid=false
        else
            debug_log "SQL param OK: $param_name='$param_value'"
        fi
    done
    
    if [[ "$all_valid" == false ]]; then
        debug_log "FATAL: SQL validation failed - cannot construct safe query"
        return 1
    fi
    return 0
}

# Safe SQL UPDATE builder - validates all params before constructing query
# Usage: build_update_sql <table> <where_clause> "col1" "val1" "col2" "val2" ...
build_update_sql() {
    local table="$1"
    local where_clause="$2"
    shift 2
    
    local set_clause=""
    local separator=""
    
    while [[ $# -gt 0 ]]; do
        local col="$1"
        local val="$2"
        shift 2
        
        # For numeric values (no quotes), check if it's a number
        if [[ "$val" =~ ^[0-9]+$ ]]; then
            set_clause+="${separator}${col}=${val}"
        else
            # Escape single quotes for SQL string literals
            local escaped_val="${val//\'/\'\'}"
            set_clause+="${separator}${col}='${escaped_val}'"
        fi
        separator=", "
    done
    
    echo "UPDATE ${table} SET ${set_clause} WHERE ${where_clause};"
}

# Database locking wrapper for single SQL statement (prevents concurrent access)
# Usage: db_exec "<sql_statement>"
db_exec() {
    local db_file="${2:-$DB_FILE}"
    local sql="$1"
    local max_retries=10
    local retry_delay=1
    local attempt=1
    
    # Log the full SQL for debugging
    debug_log "Executing SQL: $sql"
    
    while [[ $attempt -le $max_retries ]]; do
        local error_output
        # Set busy_timeout on each connection (each sqlite3 invocation is a new connection)
        # 5s timeout is sufficient with flock serialization - fail fast if issues occur
        error_output=$(sqlite3 "$db_file" "PRAGMA busy_timeout=5000; BEGIN IMMEDIATE TRANSACTION; $sql; COMMIT;" 2>&1)
        if [[ $? -eq 0 ]]; then
            return 0
        fi
        
        # Distinguish between lock and other errors
        if [[ "$error_output" == *"locked"* ]]; then
            debug_log "Database locked on attempt $attempt/$max_retries, retrying in ${retry_delay}s"
        else
            debug_log "SQL error on attempt $attempt: $error_output"
        fi
        sleep "$retry_delay"
        ((attempt++))
    done
    
    echo "ERROR: Database operation failed after $max_retries retries" >&2
    return 1
}

# Database locking wrapper for batch SQL statements (prevents concurrent access)
# Usage: db_exec_batch "<sql_statements>"
db_exec_batch() {
    local db_file="${2:-$DB_FILE}"
    local sql="$1"
    local max_retries=10
    local retry_delay=1
    local attempt=1
    
    # Count statements for progress logging
    local stmt_count=$(echo -e "$sql" | grep -c ';')
    debug_log "Executing batch with $stmt_count statements"
    
    while [[ $attempt -le $max_retries ]]; do
        local error_output
        # Set busy_timeout on each connection (each sqlite3 invocation is a new connection)
        # 5s timeout is sufficient with flock serialization - fail fast if issues occur
        error_output=$(echo -e "PRAGMA busy_timeout=5000;\nBEGIN IMMEDIATE TRANSACTION;\n$sql\nCOMMIT;" | sqlite3 "$db_file" 2>&1)
        if [[ $? -eq 0 ]]; then
            debug_log "Batch completed successfully on attempt $attempt"
            return 0
        fi
        
        # Database is locked or error occurred
        if [[ "$error_output" == *"locked"* ]]; then
            debug_log "Database locked on batch attempt $attempt/$max_retries, retrying in ${retry_delay}s"
        else
            debug_log "Batch SQL error on attempt $attempt: $error_output"
        fi
        sleep "$retry_delay"
        ((attempt++))
    done
    
    echo "ERROR: Database batch locked after $max_retries retries ($stmt_count statements)" >&2
    return 1
}

# Initialize handshake tracking database with tables and migrations
init_handshake_database() {
    local db_file="${1:-$DB_FILE}"
    
    if [[ -z "$db_file" ]]; then
        echo "ERROR: Database file path not provided to init_handshake_database" >&2
        return 1
    fi
    
    # Enable WAL mode for better concurrent write performance
    # 5s timeout is sufficient with flock serialization
    sqlite3 "$db_file" "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;" 2>/dev/null
    
    # Create tables if they don't exist
    sqlite3 "$db_file" "CREATE TABLE IF NOT EXISTS handshakes (
        ssid TEXT NOT NULL,
        bssid TEXT NOT NULL,
        best_quality TEXT,
        first_seen INTEGER,
        last_seen INTEGER,
        total_captures INTEGER DEFAULT 1,
        crackable INTEGER DEFAULT 0,
        best_pcap_path TEXT,
        best_hashcat_path TEXT,
        PRIMARY KEY (ssid, bssid)
    );
    CREATE TABLE IF NOT EXISTS clients (
        bssid TEXT NOT NULL,
        client_mac TEXT NOT NULL,
        first_seen INTEGER,
        last_seen INTEGER,
        capture_count INTEGER DEFAULT 1,
        best_quality TEXT,
        crackable INTEGER DEFAULT 0,
        best_pcap_path TEXT,
        best_hashcat_path TEXT,
        PRIMARY KEY (bssid, client_mac)
    );" 2>/dev/null
    
    # Migrate existing databases - add new columns if they don't exist
    sqlite3 "$db_file" "ALTER TABLE handshakes ADD COLUMN best_pcap_path TEXT;" 2>/dev/null || true
    sqlite3 "$db_file" "ALTER TABLE handshakes ADD COLUMN best_hashcat_path TEXT;" 2>/dev/null || true
    sqlite3 "$db_file" "ALTER TABLE clients ADD COLUMN best_quality TEXT;" 2>/dev/null || true
    sqlite3 "$db_file" "ALTER TABLE clients ADD COLUMN crackable INTEGER DEFAULT 0;" 2>/dev/null || true
    sqlite3 "$db_file" "ALTER TABLE clients ADD COLUMN best_pcap_path TEXT;" 2>/dev/null || true
    sqlite3 "$db_file" "ALTER TABLE clients ADD COLUMN best_hashcat_path TEXT;" 2>/dev/null || true
    
    return 0
}

# Quality ranking (higher = better)
# Ranks cracking success rate for already-captured handshakes (assuming PSK is in wordlist)
quality_rank() {
    case "$1" in
        # Rank 5: BEST - Message 2 + Message 3 (Complete 4-way handshake)
        # Contains both client and AP nonces with full EAPOL frames and verified MIC
        # HIGHEST cracking success rate - most complete data, best hashcat compatibility
        # If PSK is in wordlist, this will crack it
        EAPOL_M2M3_BEST) echo 5 ;;
        
        # Rank 4: GOOD - Message 1 + Message 2 (Partial handshake)
        # Contains ANonce (AP) and SNonce (client) with MIC verification
        # HIGH cracking success rate - universally compatible, works on all WPA/WPA2
        # Slight edge over PMKID for reliability across all router implementations
        EAPOL_M1M2) echo 4 ;;
        
        # Rank 3: ACCEPTABLE - Message 3 + Message 4 OR Legacy EAPOL
        # M3+M4: Has nonces and MIC but may have hashcat compatibility edge cases
        # Legacy: Older format without MSGPAIR - still crackable but less reliable
        # MODERATE success rate - may encounter issues with some captures
        EAPOL_M3M4) echo 3 ;;
        EAPOL_LEGACY) echo 3 ;;
        
        # Rank 2: BASELINE - PMKID only (No full handshake)
        # Faster to crack (simpler computation) but LOWER success rate
        # Some router implementations have PMKID quirks that prevent cracking
        # Even with correct PSK in wordlist, may fail on certain captures
        # Only use if no EAPOL handshake available
        PMKID) echo 2 ;;
        
        # Rank 0: UNKNOWN/INVALID
        *) echo 0 ;;
    esac
}

# Check if a MAC address is randomized (locally administered)
# Returns 0 if randomized, 1 if not randomized
# Randomized MACs have the "locally administered" bit set (bit 1 of first octet)
# This means the second hex digit will be one of: 2, 3, 6, 7, A, B, E, F
is_randomized_mac() {
    local mac="$1"
    # Extract second hex digit (first octet's lower nibble)
    local second_digit="${mac:1:1}"
    
    # Check if it matches the locally administered pattern
    if [[ "$second_digit" =~ [2367AaBbEeFf] ]]; then
        return 0  # MAC is randomized
    else
        return 1  # MAC is not randomized
    fi
}

# Fast hex to ASCII conversion (avoids spawning xxd for every line)
hex_to_ascii() {
    local hex="$1"
    local result=""
    local i
    
    # Process two chars at a time
    for (( i=0; i<${#hex}; i+=2 )); do
        local byte="${hex:$i:2}"
        # Convert hex to decimal, then to ASCII char
        printf -v char "\\x$byte"
        result+="$char"
    done
    
    echo -n "$result"
}

# Crackability validator
validate_crackable() {
    local line="$1"
    IFS='*' read -ra fields <<< "$line"
    
    local type="${fields[1]}"
    local hash_or_pmkid="${fields[2]}"
    local nonce_ap="${fields[6]}"
    local eapol="${fields[7]}"
    local msgpair="${fields[8]}"
    
    # PMKID validation
    if [[ "$type" == "01" ]]; then
        if [[ ${#hash_or_pmkid} -eq 32 ]]; then
            echo "CRACKABLE: PMKID"
            return 0
        else
            echo "INVALID:PMKID_MALFORMED"
            return 1
        fi
    fi
    
    # EAPOL validation
    if [[ "$type" == "02" ]]; then
        # Check required fields
        if [[ -z "$hash_or_pmkid" ]] || [[ -z "$nonce_ap" ]] || [[ -z "$eapol" ]]; then
            echo "INVALID:MISSING_FIELDS"
            return 1
        fi
        
        # Check MIC length
        if [[ ${#hash_or_pmkid} -ne 32 ]]; then
            echo "INVALID:MIC_MALFORMED"
            return 1
        fi
        
        # Validate MSGPAIR
        if [[ -n "$msgpair" ]]; then
            # Convert hex msgpair to decimal safely
            local msgpair_dec
            if [[ "$msgpair" =~ ^[0-9A-Fa-f]+$ ]]; then
                msgpair_dec=$((16#$msgpair))
            else
                echo "INVALID:MSGPAIR_MALFORMED"
                return 1
            fi
            
            case "$msgpair_dec" in
                0|2|128|130)
                    echo "CRACKABLE:EAPOL_M1M2"
                    return 0
                    ;;
                1|3|129|131)
                    echo "CRACKABLE:EAPOL_M2M3_BEST"
                    return 0
                    ;;
                4|5|132|133)
                    echo "CRACKABLE:EAPOL_M3M4"
                    return 0
                    ;;
                *)
                    # Unknown MSGPAIR but has valid MIC and required fields - still crackable
                    echo "CRACKABLE:EAPOL_UNKNOWN_MSGPAIR"
                    return 0
                    ;;
            esac
        else
            echo "CRACKABLE:EAPOL_LEGACY"
            return 0
        fi
    fi
    
    echo "UNKNOWN:TYPE_$type"
    return 1
}

# Get SSID from database if it exists, otherwise from hashcat file
# Usage: get_ssid <db_file> <bssid> <hashcat_path>
get_ssid() {
    local db_file="$1"
    local bssid="$2"
    local hashcat_path="$3"
    
    local ssid=$(sqlite3 "$db_file" "SELECT ssid FROM handshakes WHERE bssid='$bssid' LIMIT 1;" 2>/dev/null)
    
    if [[ -z "$ssid" ]] && [[ -f "$hashcat_path" ]]; then
        # Extract SSID from hashcat 22000 format
        local hash_line=$(grep "^WPA" "$hashcat_path" | head -1)
        IFS='*' read -ra fields <<< "$hash_line"
        local ssid_hex="${fields[5]}"
        if [[ -n "$ssid_hex" ]]; then
            # Convert hex to ASCII
            ssid=$(hex_to_ascii "$ssid_hex" 2>/dev/null)
            # Check for non-printable chars
            if [[ "$ssid" =~ [^[:print:]] ]]; then
                ssid="UNKNOWN_SSID"
            fi
        else
            ssid="UNKNOWN_SSID"
        fi
    fi
    
    [[ -z "$ssid" ]] && ssid="UNKNOWN_SSID"
    echo "$ssid"
}

# Determine quality level from the capture
# Usage: determine_quality <type> <complete> <hashcat_path>
determine_quality() {
    local type="$1"
    local complete="$2"
    local hashcat_path="$3"
    local quality="UNKNOWN"
    local type_lower="${type,,}"
    
    if [[ "$type_lower" == "pmkid" ]]; then
        quality="PMKID"
    elif [[ "$type_lower" == "eapol" ]]; then
        if [[ "${complete,,}" == "true" ]]; then
            # Try to determine EAPOL quality from hashcat file if it exists
            if [[ -f "$hashcat_path" ]]; then
                # Parse msgpair from hashcat 22000 format
                local hash_line=$(grep "^WPA" "$hashcat_path" | head -1)
                IFS='*' read -ra fields <<< "$hash_line"
                local msgpair="${fields[8]}"
                if [[ -n "$msgpair" ]]; then
                    local msgpair_dec=$((16#$msgpair))
                    case "$msgpair_dec" in
                        1|3|129|131) quality="EAPOL_M2M3_BEST" ;;
                        0|2|128|130) quality="EAPOL_M1M2" ;;
                        4|5|132|133) quality="EAPOL_M3M4" ;;
                        *) quality="EAPOL_LEGACY" ;;
                    esac
                else
                    quality="EAPOL_LEGACY"
                fi
            else
                quality="EAPOL_LEGACY"
            fi
        else
            quality="EAPOL_M1M2"  # Incomplete, assume M1M2
        fi
    fi
    
    echo "$quality"
}


# Called from user payload to install alert payload
# UI methods are safe
install_alert_payload() {

    # Check if source file exists
    if [[ ! -f "$ALERT_PAYLOAD_SRC" ]]; then
        LOG red "ERROR: Source alert payload not found at $ALERT_PAYLOAD_SRC"
        return 1
    fi
    
    # Determine if this is an update/reinstall or new installation
    local is_update=false
    local disabled_dir=$(dirname "$ALERT_PAYLOAD_DISABLED")
    
    if [[ -f "$ALERT_PAYLOAD_DEST" ]]; then
        LOG "Alert payload already installed. Updating..."
        is_update=true
    elif [[ -d "$disabled_dir" ]] || [[ -f "$ALERT_PAYLOAD_DISABLED" ]]; then
        LOG yellow "Alert payload is disabled. Re-enabling and updating..."
        is_update=true
    fi
    
    # Only ask for confirmation on new installation
    if [[ "$is_update" == false ]]; then
        resp=$(CONFIRMATION_DIALOG "Install alert payload for automatic handshake notifications? Highly recommended.")
        case $? in
            $DUCKYSCRIPT_REJECTED)
                LOG "Alert payload installation rejected. Not installing."
                return 1
                ;;
            $DUCKYSCRIPT_ERROR)
                LOG red "An error occurred during confirmation dialog"
                return 1
                ;;
        esac

        case "$resp" in
            $DUCKYSCRIPT_USER_CONFIRMED)
                # Continue to installation
                ;;
            $DUCKYSCRIPT_USER_DENIED)
                LOG "Alert payload installation denied by user. Not installing."
                return 1
                ;;
            *)
                LOG red "Unknown response: $resp"
                return 1
                ;;
        esac
    fi
    
    # Install/update the payload
    LOG "Installing alert payload..."
    # Create destination directory if needed
    local dest_dir=$(dirname "$ALERT_PAYLOAD_DEST")
    if [[ ! -d "$dest_dir" ]]; then
        mkdir -p "$dest_dir" || {
            LOG red "ERROR: Failed to create directory: $dest_dir"
            return 1
        }
        LOG green "Created directory: $dest_dir"
    fi
    
    # Copy the payload
    cp "$ALERT_PAYLOAD_SRC" "$ALERT_PAYLOAD_DEST" || {
        LOG red "ERROR: Failed to copy alert payload"
        return 1
    }
    
    if [[ "$is_update" == true ]]; then
        LOG green "Successfully updated alert payload at: $ALERT_PAYLOAD_DEST"
    else
        LOG green "Successfully installed alert payload to: $ALERT_PAYLOAD_DEST"
    fi
    return 0
}

