#!/bin/bash
# Title: Pull Ringtone PR
# Author: Austin (git@austin.dev)
# Description: Downloads and overwrites ringtones from a specific GitHub Pull Request
# Version: 1.1

GH_ORG="hak5"
GH_REPO="wifipineapplepager-ringtones"
TARGET_DIR="/mmc/root/ringtones"
TEMP_DIR="/tmp/pager_pr_update"

PR_NUMBER=""
PR_TITLE=""
PR_AUTHOR=""
CHANGED_FILES="/tmp/pr_changed_files_$$.txt"
COUNT_NEW=0
COUNT_UPDATED=0
LOG_BUFFER=""
SKIP_REVIEW=false

cleanup() {
    rm -rf "$TEMP_DIR"
    rm -f "$CHANGED_FILES"
}

# Returns 0 on confirm, 1 on reject/cancel/error
confirm_dialog() {
    local msg="$1"
    local resp
    resp=$(CONFIRMATION_DIALOG "$msg")
    local status=$?
    
    case $status in
        $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
            return 1
            ;;
        $DUCKYSCRIPT_ERROR)
            LED FAIL
            ERROR_DIALOG "An error occurred"
            return 1
            ;;
    esac
    
    [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]
}

check_and_install_packages() {
    LED SETUP
    LOG "Checking required packages..."
    
    local packages=""
    
    ! which curl > /dev/null && ! which wget > /dev/null && packages="curl"
    ! which unzip > /dev/null && packages="$packages unzip"
    
    [ -z "$packages" ] && return 0
    
    opkg update
    for pkg in $packages; do
        LOG "Installing $pkg..."
        if ! opkg install "$pkg"; then
            LED FAIL
            ERROR_DIALOG "Failed to install $pkg"
            return 1
        fi
    done
    return 0
}

get_ringtone_title() {
    # ringtone name/title is text before the first colon in the ringtone file
    local ringtone_file="$1"
    IFS=':' read -r ringtone_name _ < "$ringtone_file"
    echo "$ringtone_name"
}

fetch_url() {
    local url="$1" out="$2"
    
    if which curl > /dev/null; then
        curl -sL --max-time 30 "$url" -o "$out"
    elif which wget > /dev/null; then
        wget -q --no-check-certificate --timeout=30 "$url" -O "$out"
    else
        return 1
    fi
}

fetch_pr_info() {
    local temp_json="/tmp/pr_info_$$.json"
    
    if ! fetch_url "https://api.github.com/repos/$GH_ORG/$GH_REPO/pulls/$1" "$temp_json"; then
        rm -f "$temp_json"
        return 1
    fi
    
    PR_TITLE=$(sed -n 's/.*"title"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$temp_json" | head -n 1)
    PR_AUTHOR=$(sed -n '/"user"/,/}/p' "$temp_json" | sed -n 's/.*"login"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    rm -f "$temp_json"
    
    [ -z "$PR_TITLE" ] || [ -z "$PR_AUTHOR" ] && return 1
    [ ${#PR_TITLE} -gt 50 ] && PR_TITLE="${PR_TITLE:0:47}..."
    return 0
}

fetch_pr_files() {
    local temp_json="/tmp/pr_files_$$.json"
    
    if ! fetch_url "https://api.github.com/repos/$GH_ORG/$GH_REPO/pulls/$1/files" "$temp_json"; then
        rm -f "$temp_json"
        return 1
    fi
    
    grep -o '"filename"[[:space:]]*:[[:space:]]*"[^"]*"' "$temp_json" | \
        sed 's/"filename"[[:space:]]*:[[:space:]]*"\(.*\)"/\1/' > "$CHANGED_FILES"
    rm -f "$temp_json"
    
    [ -s "$CHANGED_FILES" ] || return 1
    return 0
}

setup() {
    LED SETUP
    check_and_install_packages || return 1
    
    PR_NUMBER=$(NUMBER_PICKER "Enter Pull Request #" 1)
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            return 1
            ;;
    esac
    
    if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" -le 0 ]; then
        LED FAIL
        ERROR_DIALOG "Invalid PR number"
        return 1
    fi
    
    LED SETUP
    if ! fetch_pr_info "$PR_NUMBER"; then
        LED FAIL
        ERROR_DIALOG "Failed to fetch PR info. PR may not exist."
        return 1
    fi
    
    local confirm_msg="PR #$PR_NUMBER by $PR_AUTHOR: $PR_TITLE - Pull?"
    [ ${#confirm_msg} -gt 50 ] && confirm_msg="PR #$PR_NUMBER by $PR_AUTHOR: ${PR_TITLE:0:30}... - Pull?"
    confirm_dialog "$confirm_msg" || return 1
    
    LED SETUP
    if ! fetch_pr_files "$PR_NUMBER"; then
        LED FAIL
        ERROR_DIALOG "Failed to fetch PR file list"
        return 1
    fi
    
    local file_count
    file_count=$(grep -c "^ringtones/" "$CHANGED_FILES" 2>/dev/null || echo "0")
    if [ "$file_count" -eq 0 ]; then
        LED FAIL
        ERROR_DIALOG "No ringtone files changed in PR"
        cleanup
        return 1
    fi
    
    # Ask about reviewing each file
    if ! confirm_dialog "Review each file changed? ($file_count files)"; then
        if confirm_dialog "Overwrite all $file_count touched files with PR contents?"; then
            SKIP_REVIEW=true
        else
            return 1
        fi
    fi
    return 0
}

download_pr() {
    LED ATTACK
    LOG "Downloading PR #$PR_NUMBER from $GH_ORG/$GH_REPO..."
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    
    local zip_file="$TEMP_DIR/pr_$PR_NUMBER.zip"
    if ! fetch_url "https://github.com/$GH_ORG/$GH_REPO/archive/refs/pull/$PR_NUMBER/head.zip" "$zip_file"; then
        LED FAIL
        ERROR_DIALOG "Failed to download PR #$PR_NUMBER"
        cleanup
        return 1
    fi
    
    if ! unzip -q "$zip_file" -d "$TEMP_DIR"; then
        LED FAIL
        ERROR_DIALOG "Failed to extract PR archive"
        cleanup
        return 1
    fi
    return 0
}

log_file_action() {
    local is_new="$1" label="$2"
    if [ "$is_new" = true ]; then
        LOG_BUFFER+="[ NEW ] $label\n"
        COUNT_NEW=$((COUNT_NEW + 1))
    else
        LOG_BUFFER+="[ UPDATED ] $label\n"
        COUNT_UPDATED=$((COUNT_UPDATED + 1))
    fi
}

process_ringtones() {
    LED SPECIAL
    
    # Find extracted directory
    local extracted_dir
    extracted_dir=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "${GH_REPO}-*" | head -n 1)
    [ -z "$extracted_dir" ] && extracted_dir=$(find "$TEMP_DIR" -maxdepth 1 -type d ! -path "$TEMP_DIR" | head -n 1)
    
    if [ -z "$extracted_dir" ] || [ ! -d "$extracted_dir/ringtones" ]; then
        LED FAIL
        ERROR_DIALOG "Invalid PR archive structure"
        cleanup
        return 1
    fi
    
    local file_count=0
    
    while read -r changed_file; do
        [[ "$changed_file" != ringtones/* ]] && continue
        
        local src_file="$extracted_dir/$changed_file"
        [ ! -e "$src_file" ] && continue
        
        # Only process .rtttl files
        [[ "$src_file" != *.rtttl ]] && continue
        
        local rel_path="${changed_file#ringtones/}"
        local target_file="$TARGET_DIR/$rel_path"
        local target_dir=$(dirname "$target_file")
        
        # Prompt for each file unless skipping review
        if [ "$SKIP_REVIEW" = false ]; then
            local title=$(get_ringtone_title "$src_file" 2>/dev/null || echo "")
            local prompt="$rel_path"
            [ -n "$title" ] && prompt="$rel_path ($title)"
            confirm_dialog "Update: $prompt?" || continue
        fi
        
        file_count=$((file_count + 1))
        mkdir -p "$target_dir"
        
        local is_new=false
        [ ! -e "$target_file" ] && is_new=true
        
        # Check for changes
        if [ "$is_new" = false ] && diff -q "$src_file" "$target_file" > /dev/null 2>&1; then
            continue
        fi
        
        cp "$src_file" "$target_file"
        local title=$(get_ringtone_title "$src_file" 2>/dev/null || echo "$rel_path")
        log_file_action "$is_new" "$title"
    done < "$CHANGED_FILES"
    
    if [ "$file_count" -eq 0 ]; then
        LED FAIL
        ERROR_DIALOG "No files processed"
        cleanup
        return 1
    fi
    return 0
}

finish() {
    cleanup
    
    LOG "\n$LOG_BUFFER"
    LOG "Done: $COUNT_NEW New, $COUNT_UPDATED Updated from PR #$PR_NUMBER"
    LED FINISH
}

while true; do
    setup && download_pr && process_ringtones && { finish; break; }
done
