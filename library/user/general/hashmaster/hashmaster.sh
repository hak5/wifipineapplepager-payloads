#!/bin/bash
# These functions are shared between user and alert metapayloads for Handshake Manager

HASHMASTER_LIB_VERSION="1.2.2"

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

# Escape single quotes and strip newlines for safe SQL literals
# Usage: sql_escape "value"
sql_escape() {
    local s="$1"
    # Replace newlines/carriage returns with spaces to keep SQL tidy
    s="${s//$'\n'/ }"
    s="${s//$'\r'/ }"
    # Escape single quotes by doubling
    s="${s//\'/\'\'}"
    echo -n "$s"
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
    # Quiet PRAGMA outputs to avoid noise on stdout in headless runs
    sqlite3 "$db_file" "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;" >/dev/null 2>&1
    
    # Create tables if they don't exist
    sqlite3 "$db_file" "CREATE TABLE IF NOT EXISTS handshakes (
        ssid_hex TEXT NOT NULL,
        bssid TEXT NOT NULL,
        ssid_printable TEXT,
        best_quality TEXT,
        first_seen INTEGER,
        last_seen INTEGER,
        total_captures INTEGER DEFAULT 1,
        crackable INTEGER DEFAULT 0,
        best_pcap_path TEXT,
        best_hashcat_path TEXT,
        PRIMARY KEY (ssid_hex, bssid)
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
    sqlite3 "$db_file" "ALTER TABLE handshakes ADD COLUMN ssid_hex TEXT;" 2>/dev/null || true
    sqlite3 "$db_file" "ALTER TABLE handshakes ADD COLUMN ssid_printable TEXT;" 2>/dev/null || true
    sqlite3 "$db_file" "ALTER TABLE handshakes ADD COLUMN best_pcap_path TEXT;" 2>/dev/null || true
    sqlite3 "$db_file" "ALTER TABLE handshakes ADD COLUMN best_hashcat_path TEXT;" 2>/dev/null || true
    sqlite3 "$db_file" "ALTER TABLE clients ADD COLUMN best_quality TEXT;" 2>/dev/null || true
    sqlite3 "$db_file" "ALTER TABLE clients ADD COLUMN crackable INTEGER DEFAULT 0;" 2>/dev/null || true
    sqlite3 "$db_file" "ALTER TABLE clients ADD COLUMN best_pcap_path TEXT;" 2>/dev/null || true
    sqlite3 "$db_file" "ALTER TABLE clients ADD COLUMN best_hashcat_path TEXT;" 2>/dev/null || true

    # Helpful indexes for common lookups
    sqlite3 "$db_file" "CREATE INDEX IF NOT EXISTS idx_handshakes_bssid ON handshakes(bssid);" >/dev/null 2>&1
    sqlite3 "$db_file" "CREATE INDEX IF NOT EXISTS idx_handshakes_ssid_hex ON handshakes(ssid_hex);" >/dev/null 2>&1
    
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

# Extract hex SSID from .22000 line
# Usage: get_hex_ssid <hashline>
get_hex_ssid() {
    local hash_line="$1"
    IFS='*' read -ra fields <<< "$hash_line"
    local ssid_hex="${fields[5]}"
    echo "$ssid_hex"
}
# Get SSID hex by matching BSSID within a .22000 file
# Usage: get_ssid_hex <bssid_with_colons> <hashcat_path>
get_ssid_hex() {
    local bssid="$1"
    local hashcat_path="$2"
    local ssid_hex=""

    # Validate inputs
    if [[ -z "$bssid" ]] || [[ ! -f "$hashcat_path" ]]; then
        debug_log "get_ssid_hex: invalid inputs (bssid='$bssid', hashcat_path='$hashcat_path')"
        echo "$ssid_hex"
        return 0
    fi

    # Normalize BSSID to hashcat field format (12 hex, uppercase, no colons)
    local bssid_hex
    bssid_hex=$(echo "$bssid" | tr -d ':' | tr 'a-z' 'A-Z')
    if [[ ! "$bssid_hex" =~ ^[0-9A-F]{12}$ ]]; then
        debug_log "get_ssid_hex: bssid normalization failed for '$bssid' -> '$bssid_hex'"
        echo ""
        return 0
    fi

    # Scan WPA lines and pick the first matching BSSID
    local line
    local match_count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Trim Windows CR and any leading BOM
        line="${line%$'\r'}"
        [[ -z "$line" ]] && continue
        # Only process lines that start with WPA*
        local prefix="${line%%\**}"
        local prefix_uc
        prefix_uc=$(echo "$prefix" | tr 'a-z' 'A-Z')
        [[ "$prefix_uc" != "WPA" ]] && continue

        IFS='*' read -ra fields <<< "$line"

        local ap_hex="${fields[3]}"
        local ap_hex_uc
        ap_hex_uc=$(echo "$ap_hex" | tr 'a-f' 'A-F')
        if [[ "$ap_hex_uc" == "$bssid_hex" ]]; then
            ((match_count++))
            local candidate_hex="${fields[5]}"
            # Validate hex
            if [[ -n "$candidate_hex" ]] && [[ "$candidate_hex" =~ ^[0-9A-Fa-f]+$ ]] && (( ${#candidate_hex} % 2 == 0 )); then
                ssid_hex=$(echo "$candidate_hex" | tr 'a-f' 'A-F')
                debug_log "get_ssid_hex: match ${match_count} for $bssid_hex, ssid_hex='$ssid_hex' (len=${#ssid_hex})"
            fi
            if [[ -z "$ssid_hex" ]]; then
                debug_log "get_ssid_hex: match ${match_count} for $bssid_hex but ESSID hex invalid or empty (candidate='${fields[5]}')"
            fi
            break
        fi
    done < "$hashcat_path"

    if [[ $match_count -eq 0 ]]; then
        debug_log "get_ssid_hex: no WPA lines found for BSSID '$bssid_hex' in '$hashcat_path'"
    fi

    echo "$ssid_hex"
}

# Convert hex SSID to alphanumeric ASCII (path-safe) with validation
# Usage: hex_to_printable_ssid <hex_ssid>
hex_to_printable_ssid() {
    local ssid_hex="$1"

    # Validate hex: non-empty, even length, only hex digits
    if [[ -z "$ssid_hex" ]] || [[ ! "$ssid_hex" =~ ^[0-9A-Fa-f]+$ ]] || (( ${#ssid_hex} % 2 != 0 )); then
        echo "UNKNOWN_SSID"
        return 0
    fi

    # Portable hex → ASCII using awk without strtonum (BusyBox-compatible)
    # Converts two hex chars to a byte via manual mapping
    local ssid
    ssid=$(echo "$ssid_hex" | awk 'BEGIN{ORS=""; map="0123456789ABCDEF"} {
        s=toupper($0);
        for(i=1;i<=length(s);i+=2){
            c1=index(map, substr(s,i,1))-1;
            c2=index(map, substr(s,i+1,1))-1;
            if (c1<0 || c2<0) continue;
            val=c1*16 + c2;
            printf "%c", val;
        }
    }' 2>/dev/null)

    # Fallback if decoding failed
    if [[ -z "$ssid" ]]; then
        echo "UNKNOWN_SSID"
        return 0
    fi

    # Keep allowed ASCII: letters/digits + space + underscore + dash + dot
    # Avoid POSIX character classes due to BusyBox tr limitations
    ssid=$(printf "%s" "$ssid" | sed 's/[^A-Za-z0-9 _.-]//g')

    # Final fallback if sanitization empties the value
    [[ -z "$ssid" ]] && ssid="UNKNOWN_SSID"

    echo "$ssid"
}

# Get SSID by matching BSSID within a .22000 file (no DB fallback)
# Usage: get_ssid <bssid_with_colons> <hashcat_path>
get_ssid() {
    local bssid="$1"
    local hashcat_path="$2"
    local ssid="UNKNOWN_SSID"

    # Validate inputs
    if [[ -z "$bssid" ]] || [[ ! -f "$hashcat_path" ]]; then
        echo "$ssid"
        return 0
    fi

    # Normalize BSSID to hashcat field format (12 hex, uppercase, no colons)
    local bssid_hex
    bssid_hex=$(echo "$bssid" | tr -d ':' | tr 'a-z' 'A-Z')
    if [[ ! "$bssid_hex" =~ ^[0-9A-F]{12}$ ]]; then
        echo "$ssid"
        return 0
    fi

    # Scan WPA lines and pick the first matching BSSID
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='*' read -ra fields <<< "$line"

        # fields[3] = AP MAC (12 hex, uppercase, no colons)
        local ap_hex="${fields[3]}"
        if [[ "$ap_hex" == "$bssid_hex" ]]; then
            # fields[5] = SSID hex; validate and sanitize
            local ssid_hex="${fields[5]}"
            if [[ -n "$ssid_hex" ]] && [[ "$ssid_hex" =~ ^[0-9A-Fa-f]+$ ]] && (( ${#ssid_hex} % 2 == 0 )); then
                ssid=$(hex_to_printable_ssid "$ssid_hex")
                [[ -z "$ssid" ]] && ssid="UNKNOWN_SSID"
            else
                ssid="UNKNOWN_SSID"
            fi
            break
        fi
    done < <(grep -E '^WPA' "$hashcat_path" 2>/dev/null)

    echo "$ssid"
}

# Determine best quality level from a .22000 file by scanning all lines
# Usage: determine_file_quality <hashcat_path>
determine_file_quality() {
    local hashcat_path="$1"
    local best_quality="UNKNOWN"
    local best_rank=0

    # Validate input
    if [[ -z "$hashcat_path" || ! -f "$hashcat_path" ]]; then
        echo "$best_quality"
        return 0
    fi

    # Iterate over all WPA lines and choose the highest-ranked crackable entry
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local status
        status=$(validate_crackable "$line")

        # status format: CRACKABLE:<DETAIL> or INVALID:<REASON>
        local verdict="${status%%:*}"
        local detail="${status##*:}"
        detail="${detail# }"

        if [[ "$verdict" == "CRACKABLE" ]]; then
            # Map detail to a quality label used by quality_rank
            local qlabel="$detail"
            # Treat unknown msgpair as legacy for ranking purposes
            [[ "$qlabel" == "EAPOL_UNKNOWN_MSGPAIR" ]] && qlabel="EAPOL_LEGACY"

            local rank
            rank=$(quality_rank "$qlabel")
            if [[ "$rank" -gt "$best_rank" ]]; then
                best_rank="$rank"
                best_quality="$qlabel"
                # Early exit if we reached the highest possible rank
                if [[ "$best_rank" -ge 5 ]]; then
                    break
                fi
            fi
        fi
    done < <(grep -E '^WPA' "$hashcat_path" 2>/dev/null)

    echo "$best_quality"
}

# Parse .22000 hashcat files and derive per-handshake metadata
# Usage: parse_handshake_files <handshake_dir> <out_data_file> <out_quality_file>
# - Writes lines to out_data:    SSID|BSSID|CLIENT_MAC|TYPE_NAME
# - Writes lines to out_quality: SSID|BSSID|CLIENT_MAC|QUALITY|DETAIL|TYPE_NAME|PCAP_PATH|HASHCAT_PATH
parse_handshake_files() {
    local input_path="$1"
    local out_data="$2"
    local out_quality="$3"

    if [[ -z "$input_path" || -z "$out_data" || -z "$out_quality" ]]; then
        echo "ERROR: Missing args to parse_handshake_files" >&2
        return 1
    fi

    local line_count=0
    local found_any=false

    # Build list of .22000 files to process (supports single file or directory)
    local files=()
    local file_count=0

    if [[ -f "$input_path" ]]; then
        # Single file
        if [[ "$input_path" == *.22000 ]]; then
            files+=("$input_path")
        else
            debug_log "Input file is not a .22000: $input_path"
            return 1
        fi
    elif [[ -d "$input_path" ]]; then
        # Directory of files
        while IFS= read -r f; do
            files+=("$f")
        done < <(find "$input_path" -name "*.22000" -type f 2>/dev/null)
    else
        debug_log "Input path not found: $input_path"
        return 1
    fi

    file_count=${#files[@]}
    if [[ $file_count -eq 0 ]]; then
        debug_log "No .22000 files found in $input_path"
        return 1
    fi

    debug_log "Extracting WPA lines from $file_count .22000 file(s) (shared parser)"

    # Use grep -H to include filenames for each WPA line over the file set
    while IFS= read -r file_and_line; do
        found_any=true
        ((line_count++))

        # Split filename from hash line (grep -H output: "filename:line")
        local hashcat_file="${file_and_line%%:*}"
        local line="${file_and_line#*:}"
        local pcap_file="${hashcat_file%.22000}.pcap"

        IFS='*' read -ra fields <<< "$line"

        local type="${fields[1]}"
        local ap_mac="${fields[3]}"
        local client_mac="${fields[4]}"
        local ssid_hex="${fields[5]}"

        # Normalize MAC addresses to uppercase with colons
        ap_mac=$(echo "$ap_mac" | sed 's/../&:/g;s/:$//' | tr 'a-z' 'A-Z')
        client_mac=$(echo "$client_mac" | sed 's/../&:/g;s/:$//' | tr 'a-z' 'A-Z')

        # Convert SSID from hex using shared helper
        local ssid
        ssid=$(hex_to_ascii "$ssid_hex" 2>/dev/null)
        if [[ -z "$ssid" ]] || [[ "$ssid" =~ [^[:print:]] ]]; then
            ssid="UNKNOWN_SSID"
        fi

        # Determine type name
        local type_name="UNKNOWN"
        [[ "$type" == "01" ]] && type_name="PMKID"
        [[ "$type" == "02" ]] && type_name="EAPOL"

        # Validate crackability and extract detail
        local quality_status
        quality_status=$(validate_crackable "$line")
        local quality="${quality_status%%:*}"
        local detail="${quality_status##*:}"
        detail="${detail# }"  # Strip leading space

        # Emit records
        echo "$ssid|$ap_mac|$client_mac|$type_name" >> "$out_data"
        echo "$ssid|$ap_mac|$client_mac|$quality|$detail|$type_name|$pcap_file|$hashcat_file" >> "$out_quality"

    done < <(grep -H "^WPA" "${files[@]}" 2>/dev/null)

    if ! $found_any; then
        debug_log "Shared parser found no WPA lines in .22000 file(s)"
        return 1
    fi

    debug_log "Shared parser wrote $line_count handshake records"
    return 0
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

