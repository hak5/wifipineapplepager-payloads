#!/bin/bash
# Title: Update Ringtones
# Description: Downloads and syncs all ringtones from github.
# Author: cococode
# Version: 1.4.1

# === CONFIGURATION ===
GH_ORG="hak5"
GH_REPO="wifipineapplepager-ringtones"
GH_BRANCH="master"

ZIP_URL="https://github.com/$GH_ORG/$GH_REPO/archive/refs/heads/$GH_BRANCH.zip"
TARGET_DIR="/mmc/root/ringtones"
TEMP_DIR="/tmp/pager_update"

# === STATE ===
BATCH_MODE=""           # "" (Interactive), "OVERWRITE", "SKIP"
FIRST_CONFLICT=true
PENDING_UPDATE_PATH=""
COUNT_NEW=0
COUNT_UPDATED=0
COUNT_SKIPPED=0
LOG_BUFFER=""

# === UTILITIES ===

get_ringtone_title() {
    # ringtone name/title is text before the first colon in the ringtone file
    local ringtone_file="$1"
    IFS=':' read -r ringtone_name _ < "$ringtone_file"
    echo "$ringtone_name"
}

setup() {
    LED SETUP
    if ! which unzip > /dev/null; then
        LOG "Installing unzip..."
        opkg update
        opkg install unzip diffutils
    fi
}

download_ringtones() {
    LED ATTACK
    LOG "Downloading from github... $GH_ORG/$GH_REPO/$GH_BRANCH"
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"

    if ! wget -q --no-check-certificate "$ZIP_URL" -O "$TEMP_DIR/$GH_BRANCH.zip"; then
        LED FAIL
        LOG "Download Failed"
        exit 1
    fi

    unzip -q "$TEMP_DIR/$GH_BRANCH.zip" -d "$TEMP_DIR"
}

process_ringtones() {
    LED SPECIAL
    local src_lib="$TEMP_DIR/$GH_REPO-$GH_BRANCH/ringtones"

    if [ ! -d "$src_lib" ]; then
        LED FAIL
        LOG "Invalid Zip Structure"
        exit 1
    fi

    # FIND STRATEGY:
    # Easiest repo to handle...flat list of rtttl files, no dependencies!
    find "$src_lib" -name "*.rtttl" > /tmp/pager_ringtone_list.txt

    while read -r pfile; do
        # src_path is the individual ringtone file (instead of directory)
        local src_path=$pfile

        # Calculate relative path from library root to preserve structure
        local rel_path="${src_path#$src_lib/}"
        local target_path="$TARGET_DIR/$rel_path"

        # 1. NEW RINGTONE
        if [ ! -e "$target_path" ]; then
            mkdir -p "$(dirname "$target_path")"
            cp "$src_path" "$target_path"
            LOG_BUFFER+="[ NEW ] $(get_ringtone_title $src_path)\n"
            COUNT_NEW=$((COUNT_NEW + 1))
            continue
        fi

        # 2. CHECK FOR CHANGES
        if diff -q "$src_path" "$target_path" > /dev/null; then
            continue
        fi

        # 3. CONFLICT DETECTED
        handle_conflict "$src_path" "$target_path"

    done < /tmp/pager_ringtone_list.txt

    rm -f /tmp/pager_ringtone_list.txt
}

handle_conflict() {
    local src="$1"
    local dst="$2"
    local name="$(basename $src)"
    local title=$(get_ringtone_title "$src")
    local do_overwrite=false

    # === BATCH SELECTION (First Conflict Only) ===
    if [ "$FIRST_CONFLICT" = true ]; then
        LED SETUP
        if [ "$(CONFIRMATION_DIALOG "Updates found! Review each updated ringtone?")" == "0" ]; then
             if [ "$(CONFIRMATION_DIALOG "Overwrite ALL ringtones with updated versions?")" == "1" ]; then
                BATCH_MODE="OVERWRITE"
             else
                BATCH_MODE="SKIP"
             fi
        fi
        FIRST_CONFLICT=false
    fi

    # === DECISION LOGIC ===
    if [ "$BATCH_MODE" == "OVERWRITE" ]; then
        do_overwrite=true
    elif [ "$BATCH_MODE" == "SKIP" ]; then
        do_overwrite=false
    else
        # Interactive Prompt
        LED SPECIAL

        local prompt="$name"
        [ -n "$title" ] && prompt="$name ($title)"

        if [ "$(CONFIRMATION_DIALOG "Update $prompt?")" == "1" ]; then
            do_overwrite=true
        else
            do_overwrite=false
        fi
    fi

    # === EXECUTION ===
    if [ "$do_overwrite" = true ]; then
        perform_safe_copy "$src" "$dst"
        LOG_BUFFER+="[ UPDATED ] $title\n"
        COUNT_UPDATED=$((COUNT_UPDATED + 1))
    else
        LOG_BUFFER+="[ SKIPPED ] $title\n"
        COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
    fi
}

perform_safe_copy() {
    local src="$1"
    local dst="$2"

    # Standard fast copy
    cp "$src" "$dst"
}

finish() {
    rm -rf "$TEMP_DIR"

    LOG "\n$LOG_BUFFER"
    LOG "Done: $COUNT_NEW New, $COUNT_UPDATED Updated, $COUNT_SKIPPED Skipped"
}

# === MAIN ===
setup
download_ringtones
process_ringtones
finish
