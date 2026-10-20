#!/bin/bash
# Title: PullPR_Manager
# Author: Austin (git@austin.dev), Combined by z3r0l1nk
# Description: Downloads and overwrites Payloads, Themes, or Ringtones from a specific GitHub Pull Request
# Version: 1.1

# Type configuration - set by user selection
PR_TYPE=""
GH_ORG="hak5"
GH_REPO=""
TARGET_DIR=""
FILE_PREFIX=""

TEMP_DIR="/tmp/pager_pr_update"
PR_NUMBER=""
PR_TITLE=""
PR_AUTHOR=""
CHANGED_FILES="/tmp/pr_changed_files_$$.txt"
COUNT_NEW=0
COUNT_UPDATED=0
COUNT_SKIPPED=0
LOG_BUFFER=""
PENDING_UPDATE_PATH=""
BATCH_MODE=""
FIRST_CONFLICT=true

cleanup() {
    rm -rf "$TEMP_DIR"
    rm -f "$CHANGED_FILES"
}

setup_packages() {
    LED SETUP
    if [ "$(opkg status unzip)" == "" ] || [ "$(opkg status curl)" == "" ]; then
        LOG "One-time setup: installing dependencies..."
        opkg update
        opkg install curl unzip
    fi
}

get_payload_title() {
    local pfile="$1/payload.sh"
    [ -f "$pfile" ] && grep -m 1 "^# *Title:" "$pfile" | cut -d: -f2- | sed 's/^[ \t]*//'
}

get_theme_title() {
    local dir="$1"
    echo "$(basename $dir)"
}

get_ringtone_title() {
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

# Fetch PR files with pagination support
fetch_pr_files() {
    local page=1
    local temp_json="/tmp/pr_files_$$.json"

    : > "$CHANGED_FILES"

    while true; do
        if ! fetch_url \
            "https://api.github.com/repos/$GH_ORG/$GH_REPO/pulls/$1/files?per_page=100&page=$page" \
            "$temp_json"; then
            rm -f "$temp_json"
            return 1
        fi

        grep -o '"filename"[[:space:]]*:[[:space:]]*"[^"]*"' "$temp_json" | \
            sed 's/"filename"[[:space:]]*:[[:space:]]*"\(.*\)"/\1/' >> "$CHANGED_FILES"

        if ! grep -q '"filename"' "$temp_json"; then
            break
        fi

        page=$((page + 1))
    done

    rm -f "$temp_json"

    [ -s "$CHANGED_FILES" ] || return 1
    return 0
}

select_type() {
    LED SETUP
    
    # Ask user to select type using sequential confirmations
    if [ "$(CONFIRMATION_DIALOG "Pull Payload PR?")" == "1" ]; then
        PR_TYPE="payload"
        GH_REPO="wifipineapplepager-payloads"
        TARGET_DIR="/mmc/root/payloads"
        FILE_PREFIX="library/"
        return 0
    fi
    
    if [ "$(CONFIRMATION_DIALOG "Pull Theme PR?")" == "1" ]; then
        PR_TYPE="theme"
        GH_REPO="wifipineapplepager-themes"
        TARGET_DIR="/mmc/root/themes"
        FILE_PREFIX="themes/"
        return 0
    fi
    
    if [ "$(CONFIRMATION_DIALOG "Pull Ringtone PR?")" == "1" ]; then
        PR_TYPE="ringtone"
        GH_REPO="wifipineapplepager-ringtones"
        TARGET_DIR="/mmc/root/ringtones"
        FILE_PREFIX="ringtones/"
        return 0
    fi
    
    LOG "No type selected."
    return 1
}

setup() {
    select_type || return 1
    
    setup_packages
    
    LED SETUP
    PR_NUMBER=$(NUMBER_PICKER "Enter PR #" 1)
    
    if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" -le 0 ]; then
        LOG "Invalid PR number"
        return 1
    fi
    
    LED SETUP
    if ! fetch_pr_info "$PR_NUMBER"; then
        LOG "Failed to fetch PR info. PR may not exist."
        return 1
    fi
    
    local confirm_msg="PR #$PR_NUMBER by $PR_AUTHOR: $PR_TITLE"
    [ ${#confirm_msg} -gt 45 ] && confirm_msg="PR #$PR_NUMBER by $PR_AUTHOR"
    
    if [ "$(CONFIRMATION_DIALOG "$confirm_msg - Pull?")" != "1" ]; then
        return 1
    fi
    
    LED SETUP
    if ! fetch_pr_files "$PR_NUMBER"; then
        LOG "Failed to fetch PR file list"
        return 1
    fi
    
    local file_count
    file_count=$(grep -c "^${FILE_PREFIX}" "$CHANGED_FILES" 2>/dev/null || echo "0")
    if [ "$file_count" -eq 0 ]; then
        LOG "No ${PR_TYPE} files changed in PR"
        cleanup
        return 1
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
        LOG "Failed to download PR #$PR_NUMBER"
        cleanup
        return 1
    fi
    
    if ! unzip -q "$zip_file" -d "$TEMP_DIR"; then
        LOG "Failed to extract PR archive"
        cleanup
        return 1
    fi
    return 0
}

handle_conflict() {
    local src="$1"
    local dst="$2"
    local label="$3"
    local do_overwrite=false

    # Bulk Choice on first conflict
    if [ "$FIRST_CONFLICT" = true ]; then
        LED SETUP
        if [ "$(CONFIRMATION_DIALOG "Updates found! Review each one?")" == "0" ]; then
            if [ "$(CONFIRMATION_DIALOG "Overwrite ALL with updates?")" == "1" ]; then
                BATCH_MODE="OVERWRITE"
            else
                BATCH_MODE="SKIP"
            fi
        fi
        FIRST_CONFLICT=false
    fi

    if [ "$BATCH_MODE" == "OVERWRITE" ]; then
        do_overwrite=true
    elif [ "$BATCH_MODE" == "SKIP" ]; then
        do_overwrite=false
    else
        LED SPECIAL
        if [ "$(CONFIRMATION_DIALOG "Update $label?")" == "1" ]; then
            do_overwrite=true
        else
            do_overwrite=false
        fi
    fi

    if [ "$do_overwrite" = true ]; then
        rm -rf "$dst"
        cp -rf "$src" "$dst"
        LOG_BUFFER+="[ UPDATED ] $label\n"
        COUNT_UPDATED=$((COUNT_UPDATED + 1))
    else
        LOG_BUFFER+="[ SKIPPED ] $label\n"
        COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
    fi
}

process_payloads() {
    LED SPECIAL
    
    local extracted_dir
    extracted_dir=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "${GH_REPO}-*" | head -n 1)
    [ -z "$extracted_dir" ] && extracted_dir=$(find "$TEMP_DIR" -maxdepth 1 -type d ! -path "$TEMP_DIR" | head -n 1)
    
    if [ -z "$extracted_dir" ] || [ ! -d "$extracted_dir/library" ]; then
        LOG "Invalid PR archive structure"
        cleanup
        return 1
    fi
    
    local file_list="/tmp/pr_payload_list.txt"
    find "$extracted_dir/library" -name "payload.sh" > "$file_list"
    
    while read -r found_file; do
        local src_item=$(dirname "$found_file")
        local item_rel_path="${src_item#$extracted_dir/library/}"
        local target_path="$TARGET_DIR/$item_rel_path"
        local item_title=$(get_payload_title "$src_item")
        [ -z "$item_title" ] && item_title=$(basename "$src_item")
        
        # Check if in changed files
        if ! grep -q "^library/$item_rel_path" "$CHANGED_FILES"; then
            continue
        fi
        
        # Handle DISABLED logic
        local dir_name=$(basename "$src_item")
        local disabled_path="$(dirname "$target_path")/DISABLED.$dir_name"
        if [ -d "$disabled_path" ]; then
            target_path="$disabled_path"
        fi
        
        if [ ! -e "$target_path" ]; then
            # New item - disable alerts by default
            if [[ "$item_rel_path" =~ ^alerts/ ]]; then
                target_path="$(dirname "$target_path")/DISABLED.$(basename "$target_path")"
            fi
            mkdir -p "$(dirname "$target_path")"
            cp -rf "$src_item" "$target_path"
            LOG_BUFFER+="[ NEW ] $item_title\n"
            COUNT_NEW=$((COUNT_NEW + 1))
        else
            # Existing - check for changes
            if diff -r -q "$src_item" "$target_path" > /dev/null 2>&1; then
                continue
            fi
            handle_conflict "$src_item" "$target_path" "$item_title"
        fi
    done < "$file_list"
    
    rm -f "$file_list"
    return 0
}

process_themes() {
    LED SPECIAL
    
    local extracted_dir
    extracted_dir=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "${GH_REPO}-*" | head -n 1)
    [ -z "$extracted_dir" ] && extracted_dir=$(find "$TEMP_DIR" -maxdepth 1 -type d ! -path "$TEMP_DIR" | head -n 1)
    
    if [ -z "$extracted_dir" ] || [ ! -d "$extracted_dir/themes" ]; then
        LOG "Invalid PR archive structure"
        cleanup
        return 1
    fi
    
    local file_list="/tmp/pr_theme_list.txt"
    find "$extracted_dir/themes" -name "theme.json" > "$file_list"
    
    while read -r found_file; do
        local src_item=$(dirname "$found_file")
        local item_rel_path="${src_item#$extracted_dir/themes/}"
        local target_path="$TARGET_DIR/$item_rel_path"
        local item_title=$(get_theme_title "$src_item")
        
        # Check if in changed files
        if ! grep -q "^themes/$item_rel_path" "$CHANGED_FILES"; then
            continue
        fi
        
        if [ ! -e "$target_path" ]; then
            mkdir -p "$(dirname "$target_path")"
            cp -rf "$src_item" "$target_path"
            LOG_BUFFER+="[ NEW ] $item_title\n"
            COUNT_NEW=$((COUNT_NEW + 1))
        else
            if diff -r -q "$src_item" "$target_path" > /dev/null 2>&1; then
                continue
            fi
            handle_conflict "$src_item" "$target_path" "$item_title"
        fi
    done < "$file_list"
    
    rm -f "$file_list"
    return 0
}

process_ringtones() {
    LED SPECIAL
    
    local extracted_dir
    extracted_dir=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "${GH_REPO}-*" | head -n 1)
    [ -z "$extracted_dir" ] && extracted_dir=$(find "$TEMP_DIR" -maxdepth 1 -type d ! -path "$TEMP_DIR" | head -n 1)
    
    local search_root="$extracted_dir"
    [ -d "$extracted_dir/ringtones" ] && search_root="$extracted_dir/ringtones"
    
    local file_list="/tmp/pr_ringtone_list.txt"
    find "$search_root" -name "*.rtttl" > "$file_list"
    
    while read -r src_item; do
        local item_rel_path="${src_item#$search_root/}"
        local target_path="$TARGET_DIR/$item_rel_path"
        local item_title=$(get_ringtone_title "$src_item" 2>/dev/null)
        [ -z "$item_title" ] && item_title=$(basename "$src_item")
        
        # Check if in changed files
        if ! grep -q "ringtones/$item_rel_path" "$CHANGED_FILES"; then
            continue
        fi
        
        if [ ! -e "$target_path" ]; then
            mkdir -p "$(dirname "$target_path")"
            cp "$src_item" "$target_path"
            LOG_BUFFER+="[ NEW ] $item_title\n"
            COUNT_NEW=$((COUNT_NEW + 1))
        else
            if diff -q "$src_item" "$target_path" > /dev/null 2>&1; then
                continue
            fi
            handle_conflict "$src_item" "$target_path" "$item_title"
        fi
    done < "$file_list"
    
    rm -f "$file_list"
    return 0
}

process_files() {
    case "$PR_TYPE" in
        "payload")
            process_payloads
            ;;
        "theme")
            process_themes
            ;;
        "ringtone")
            process_ringtones
            ;;
    esac
}

finish() {
    cleanup
    
    LOG "\n$LOG_BUFFER"
    LOG "Done: $COUNT_NEW New, $COUNT_UPDATED Updated, $COUNT_SKIPPED Skipped from PR #$PR_NUMBER"
    LED FINISH
}

# === RUN ===
if setup; then
    if download_pr; then
        process_files
        finish
    fi
fi
