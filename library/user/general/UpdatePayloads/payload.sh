#!/bin/bash
# Title: Update Payloads
# Description: Downloads and syncs all payloads from github.
# Author: cococode
# Version: 1.4.1

# === CONFIGURATION ===
GH_ORG="hak5"
GH_REPO="wifipineapplepager-payloads"
GH_BRANCH="master"

ZIP_URL="https://github.com/$GH_ORG/$GH_REPO/archive/refs/heads/$GH_BRANCH.zip"
TARGET_DIR="/mmc/root/payloads"
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

get_dir_title() {
    local dir="$1"
    local pfile="$dir/payload.sh"
    if [ -f "$pfile" ]; then
        grep -m 1 "^# *Title:" "$pfile" | cut -d: -f2- | sed 's/^[ \t]*//;s/[ \t]*$//'
    fi
}

setup() {
    LED SETUP
    if ! which unzip > /dev/null; then
        LOG "Installing unzip..."
        opkg update
        opkg install unzip diffutils
    fi
}

download_payloads() {
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

process_payloads() {
    LED SPECIAL
    local src_lib="$TEMP_DIR/$GH_REPO-$GH_BRANCH/library"

    if [ ! -d "$src_lib" ]; then
        LED FAIL
        LOG "Invalid Zip Structure"
        exit 1
    fi

    # FIND STRATEGY:
    # Instead of assuming flat structure, find every 'payload.sh'
    # and treat its directory as a payload unit.
    find "$src_lib" -name "payload.sh" > /tmp/pager_payload_list.txt

    while read -r pfile; do
        # src_path is the directory containing payload.sh
        local src_path=$(dirname "$pfile")

        # Calculate relative path from library root to preserve structure
        local rel_path="${src_path#$src_lib/}"
        local target_path="$TARGET_DIR/$rel_path"
        local dir_name=$(basename "$src_path")
        local disabled_path=$(dirname "$target_path")/DISABLED.$dir_name

        # 0. DISABLED PAYLOAD - update the target to the disabled version
        if [ -d "$disabled_path" ]; then
            target_path=$disabled_path
        fi

        # 1. NEW PAYLOAD
        if [ ! -d "$target_path" ]; then
            # 1a. NEW ALERT - disable by default
            in_alerts_dir=^alerts/
            if [[ "$rel_path" =~ $in_alerts_dir ]]; then
                target_path=$disabled_path
            fi
            mkdir -p "$(dirname "$target_path")"
            cp -rf "$src_path" "$target_path"
            LOG_BUFFER+="[ NEW ] $(get_dir_title $src_path)\n"
            COUNT_NEW=$((COUNT_NEW + 1))
            continue
        fi

        # 2. CHECK FOR CHANGES
        if diff -r -q "$src_path" "$target_path" > /dev/null; then
            continue
        fi

        # 3. CONFLICT DETECTED
        handle_conflict "$dir_name" "$src_path" "$target_path"

    done < /tmp/pager_payload_list.txt

    rm -f /tmp/pager_payload_list.txt
}

handle_conflict() {
    local name="$1"
    local src="$2"
    local dst="$3"
    local title=$(get_dir_title "$src")
    local do_overwrite=false

    # === BATCH SELECTION (First Conflict Only) ===
    if [ "$FIRST_CONFLICT" = true ]; then
        LED SETUP
        if [ "$(CONFIRMATION_DIALOG "Updates found! Review each updated payload?")" == "0" ]; then
             if [ "$(CONFIRMATION_DIALOG "Overwrite ALL payloads with updated versions?")" == "1" ]; then
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

    # Self-Update Protection
    if [ "$dst/payload.sh" -ef "$0" ]; then
        # If updating THIS payload, copy everything except payload.sh
        # and queue payload.sh for the end
        find "$src" -type f | while read -r sfile; do
            local rel_name="${sfile#$src/}"
            local dfile="$dst/$rel_name"

            if [ "$(basename "$sfile")" == "payload.sh" ]; then
                cp "$sfile" "/tmp/pending_updater_update.sh"
                PENDING_UPDATE_PATH="/tmp/pending_updater_update.sh"
            else
                mkdir -p "$(dirname "$dfile")"
                cp "$sfile" "$dfile"
            fi
        done
    else
        # Standard fast copy
        rm -rf "$dst"
        cp -rf "$src" "$dst"
    fi
}

finish() {
    if [ -f "$PENDING_UPDATE_PATH" ]; then
        cat "$PENDING_UPDATE_PATH" > "$0"
    fi

    rm -rf "$TEMP_DIR"

    LOG "\n$LOG_BUFFER"
    LOG "Done: $COUNT_NEW New, $COUNT_UPDATED Updated, $COUNT_SKIPPED Skipped"
}

# === MAIN ===
setup
download_payloads
process_payloads
finish
