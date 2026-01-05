#!/bin/bash
# Title: Update Themes
# Description: Downloads and syncs all themes from github.
# Author: cococode
# Version: 2.0

# === CONFIGURATION ===
GH_ORG="hak5"
GH_REPO="wifipineapplepager-themes"
GH_BRANCH="master"

GIT_URL="https://github.com/$GH_ORG/$GH_REPO.git"
TARGET_DIR="/mmc/root/themes"
CACHE_DIR="/mmc/root/pager_update_cache/UpdateThemes" # where the repo will be cloned/updated

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
    # just use theme directory name as the theme title
    local dir="$1"
    echo "$(basename $dir)"
}

setup() {
    LED SETUP
    if [ "$(opkg status git-http)" == "" ]; then
        LOG "One-time setup: installing dependencies (git, git-http)...this will take several minutes!"
        opkg update
        opkg install git git-http
    fi
}

download_themes() {
    LED ATTACK

    # check local cache if it exists - does it match this config?
    if [ -d "$CACHE_DIR" ]; then
        cd "$CACHE_DIR"
        local current_remote=$(git remote get-url origin)
        if [ "$current_remote" == "$GIT_URL" ]; then
            # remote config (upstream repo url) hasn't changed, no need to clone
            # make sure repo is clean (users should NOT be putting things here)
            LOG "Checking for changes (pulling latest)...\n$GH_ORG/$GH_REPO/$GH_BRANCH"
            git reset --hard HEAD
            git clean -df
            git checkout $GH_BRANCH
            if ! git pull; then
                LOG "Could not pull. Make sure your pager is connected to the internet and try again."
                exit 1
            fi
            return
        fi
    fi

    # local cache doesn't exist or config has changed for which remote url to use
    rm -rf "$CACHE_DIR"
    LOG "One-time setup: cloning repo. This will take a few more minutes...\n$GH_ORG/$GH_REPO/$GH_BRANCH"
    if ! git clone -b "$GH_BRANCH" "$GIT_URL" --depth 1 "$CACHE_DIR"; then
        LED FAIL
        LOG "Could not clone. Make sure your pager is connected to the internet and try again."
        exit 1
    fi
}

process_themes() {
    LED SPECIAL
    local src_lib="$CACHE_DIR/themes"

    if [ ! -d "$src_lib" ]; then
        LED FAIL
        LOG "Something is wrong with the repo structure."
        exit 1
    fi

    # FIND STRATEGY:
    # Instead of assuming flat structure, find every 'theme.json'
    # and treat its directory as a theme unit.
    find "$src_lib" -name "theme.json" > /tmp/pager_theme_list.txt

    while read -r pfile; do
        # src_path is the directory containing theme.json
        local src_path=$(dirname "$pfile")

        # Calculate relative path from library root to preserve structure
        local rel_path="${src_path#$src_lib/}"
        local target_path="$TARGET_DIR/$rel_path"
        local dir_name=$(basename "$src_path")

        # 1. NEW THEME
        if [ ! -d "$target_path" ]; then
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

    done < /tmp/pager_theme_list.txt

    rm -f /tmp/pager_theme_list.txt
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
        if [ "$(CONFIRMATION_DIALOG "Updates found! Review each updated theme?")" == "0" ]; then
             if [ "$(CONFIRMATION_DIALOG "Overwrite ALL themes with updated versions?")" == "1" ]; then
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
    rm -rf "$dst"
    cp -rf "$src" "$dst"
}

finish() {
    LOG "\n$LOG_BUFFER"
    LOG "Done: $COUNT_NEW New, $COUNT_UPDATED Updated, $COUNT_SKIPPED Skipped"
}

# === MAIN ===
setup
download_themes
process_themes
finish
