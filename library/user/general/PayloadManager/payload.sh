#!/bin/bash
# Title: Payload Manager
# Description: Browse, install, update, enable/disable payloads. Compare installed vs GitHub repo.
# Author: BillyJBryant <github.com/BillyJBryant>
# Version: 1.0

# === CONFIGURATION ===
CONFIG_NAME="PayloadManager"

# Default values (can be overridden by user settings)
GH_ORG="hak5"
GH_REPO="wifipineapplepager-payloads"
GH_BRANCH="master"

# Settings (loaded from persistent config)
SETTING_DEFAULT_MODE="ask"      # ask, interactive, batch
SETTING_CUSTOM_REPO=""          # user/repo format, empty = use default
SETTING_CUSTOM_BRANCH=""        # branch name, empty = use default
SETTING_SHOW_LOCAL="true"       # show [LOC] payloads in browse

# === SETTINGS FUNCTIONS ===

load_settings() {
    # Load each setting, using default if not set
    local val=""

    val=$(PAYLOAD_GET_CONFIG "$CONFIG_NAME" default_mode 2>/dev/null) && [ -n "$val" ] && SETTING_DEFAULT_MODE="$val"
    val=$(PAYLOAD_GET_CONFIG "$CONFIG_NAME" custom_repo 2>/dev/null) && [ -n "$val" ] && SETTING_CUSTOM_REPO="$val"
    val=$(PAYLOAD_GET_CONFIG "$CONFIG_NAME" custom_branch 2>/dev/null) && [ -n "$val" ] && SETTING_CUSTOM_BRANCH="$val"
    val=$(PAYLOAD_GET_CONFIG "$CONFIG_NAME" show_local 2>/dev/null) && [ -n "$val" ] && SETTING_SHOW_LOCAL="$val"

    # Apply custom repo/branch if set
    if [ -n "$SETTING_CUSTOM_REPO" ]; then
        GH_ORG=$(echo "$SETTING_CUSTOM_REPO" | cut -d'/' -f1)
        GH_REPO=$(echo "$SETTING_CUSTOM_REPO" | cut -d'/' -f2)
    fi
    if [ -n "$SETTING_CUSTOM_BRANCH" ]; then
        GH_BRANCH="$SETTING_CUSTOM_BRANCH"
    fi
}

save_setting() {
    local key="$1"
    local value="$2"
    PAYLOAD_SET_CONFIG "$CONFIG_NAME" "$key" "$value"
}

is_first_run() {
    # Check if we've ever saved settings
    local val=$(PAYLOAD_GET_CONFIG "$CONFIG_NAME" first_run_done 2>/dev/null)
    [ "$val" != "true" ]
}

mark_first_run_done() {
    save_setting "first_run_done" "true"
}

# Build ZIP URL (called after settings are loaded)
build_zip_url() {
    ZIP_URL="https://github.com/$GH_ORG/$GH_REPO/archive/refs/heads/$GH_BRANCH.zip"
}

# === FIRST RUN SETUP ===

first_run_setup() {
    LOG ""
    LOG "=== WELCOME TO PAYLOAD MANAGER ==="
    LOG ""
    LOG "Let's configure your preferences."
    LOG ""
    LOG green "Press GREEN to continue"
    WAIT_FOR_BUTTON_PRESS A

    # Default update mode
    LOG ""
    LOG "=== UPDATE MODE ==="
    LOG "When updates are available:"
    LOG "1) Ask each time (recommended)"
    LOG "2) Always review individually"
    LOG "3) Always update all automatically"
    LOG ""
    LOG green "Press GREEN when ready"
    WAIT_FOR_BUTTON_PRESS A

    local mode_choice=$(NUMBER_PICKER "Select mode" 1)
    case "$mode_choice" in
        1) SETTING_DEFAULT_MODE="ask" ;;
        2) SETTING_DEFAULT_MODE="interactive" ;;
        3) SETTING_DEFAULT_MODE="batch" ;;
        *) SETTING_DEFAULT_MODE="ask" ;;
    esac
    save_setting "default_mode" "$SETTING_DEFAULT_MODE"

    # Custom repository
    LOG ""
    LOG "=== REPOSITORY ==="
    local repo_resp=$(CONFIRMATION_DIALOG "Use official Hak5 repository?")
    if [ "$repo_resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        LOG ""
        LOG "Enter custom repo (user/repo format):"
        LOG green "Press GREEN when ready"
        WAIT_FOR_BUTTON_PRESS A
        local custom_repo=$(TEXT_PICKER "Repository" "")
        if [ -n "$custom_repo" ]; then
            SETTING_CUSTOM_REPO="$custom_repo"
            save_setting "custom_repo" "$SETTING_CUSTOM_REPO"
            GH_ORG=$(echo "$custom_repo" | cut -d'/' -f1)
            GH_REPO=$(echo "$custom_repo" | cut -d'/' -f2)
        fi

        LOG ""
        LOG "Enter branch name (or leave empty for master):"
        LOG green "Press GREEN when ready"
        WAIT_FOR_BUTTON_PRESS A
        local custom_branch=$(TEXT_PICKER "Branch" "master")
        if [ -n "$custom_branch" ] && [ "$custom_branch" != "master" ]; then
            SETTING_CUSTOM_BRANCH="$custom_branch"
            save_setting "custom_branch" "$SETTING_CUSTOM_BRANCH"
            GH_BRANCH="$custom_branch"
        fi
    fi

    # Show local-only payloads
    LOG ""
    local local_resp=$(CONFIRMATION_DIALOG "Show local-only payloads in browse?")
    if [ "$local_resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        SETTING_SHOW_LOCAL="true"
    else
        SETTING_SHOW_LOCAL="false"
    fi
    save_setting "show_local" "$SETTING_SHOW_LOCAL"

    # Mark setup complete
    mark_first_run_done
    build_zip_url

    LOG ""
    LOG "Setup complete!"
    LOG ""
    LOG "Repository: $GH_ORG/$GH_REPO"
    LOG "Branch: $GH_BRANCH"
    LOG "Update mode: $SETTING_DEFAULT_MODE"
    LOG ""
    LOG green "Press GREEN to continue"
    WAIT_FOR_BUTTON_PRESS A
}

# === SETTINGS MENU ===

show_settings_menu() {
    while true; do
        LOG ""
        LOG "=== SETTINGS ==="
        LOG "1) Update mode: $SETTING_DEFAULT_MODE"
        LOG "2) Repository: ${SETTING_CUSTOM_REPO:-hak5/wifipineapplepager-payloads}"
        LOG "3) Branch: ${SETTING_CUSTOM_BRANCH:-master}"
        LOG "4) Show local payloads: $SETTING_SHOW_LOCAL"
        LOG "5) Reset to defaults"
        LOG "6) Back"
        LOG ""
        LOG green "Press GREEN when ready"
        WAIT_FOR_BUTTON_PRESS A

        local choice=$(NUMBER_PICKER "Select option" 1)

        case "$choice" in
            1) settings_update_mode ;;
            2) settings_repository ;;
            3) settings_branch ;;
            4) settings_show_local ;;
            5) settings_reset ;;
            6) return ;;
        esac
    done
}

settings_update_mode() {
    LOG ""
    LOG "=== UPDATE MODE ==="
    LOG "1) Ask each time"
    LOG "2) Always interactive"
    LOG "3) Always batch"
    LOG ""
    LOG green "Press GREEN when ready"
    WAIT_FOR_BUTTON_PRESS A

    local choice=$(NUMBER_PICKER "Select mode" 1)
    case "$choice" in
        1) SETTING_DEFAULT_MODE="ask" ;;
        2) SETTING_DEFAULT_MODE="interactive" ;;
        3) SETTING_DEFAULT_MODE="batch" ;;
        *) return ;;
    esac
    save_setting "default_mode" "$SETTING_DEFAULT_MODE"
    LOG "Saved: $SETTING_DEFAULT_MODE"
}

settings_repository() {
    LOG ""
    local use_default=$(CONFIRMATION_DIALOG "Use official Hak5 repository?")
    if [ "$use_default" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        SETTING_CUSTOM_REPO=""
        save_setting "custom_repo" ""
        GH_ORG="hak5"
        GH_REPO="wifipineapplepager-payloads"
        build_zip_url
        LOG "Reset to official repository"
    else
        LOG ""
        LOG "Enter repo (user/repo format):"
        LOG green "Press GREEN when ready"
        WAIT_FOR_BUTTON_PRESS A
        local custom_repo=$(TEXT_PICKER "Repository" "$SETTING_CUSTOM_REPO")
        if [ -n "$custom_repo" ]; then
            SETTING_CUSTOM_REPO="$custom_repo"
            save_setting "custom_repo" "$SETTING_CUSTOM_REPO"
            GH_ORG=$(echo "$custom_repo" | cut -d'/' -f1)
            GH_REPO=$(echo "$custom_repo" | cut -d'/' -f2)
            build_zip_url
            LOG "Saved: $custom_repo"
        fi
    fi
    # Clear cached download since repo changed
    GITHUB_DOWNLOADED=false
}

settings_branch() {
    LOG ""
    LOG "Enter branch name:"
    LOG green "Press GREEN when ready"
    WAIT_FOR_BUTTON_PRESS A
    local branch=$(TEXT_PICKER "Branch" "${SETTING_CUSTOM_BRANCH:-master}")
    if [ -n "$branch" ]; then
        if [ "$branch" = "master" ]; then
            SETTING_CUSTOM_BRANCH=""
            save_setting "custom_branch" ""
        else
            SETTING_CUSTOM_BRANCH="$branch"
            save_setting "custom_branch" "$branch"
        fi
        GH_BRANCH="$branch"
        build_zip_url
        LOG "Saved: $branch"
    fi
    # Clear cached download since branch changed
    GITHUB_DOWNLOADED=false
}

settings_show_local() {
    if [ "$SETTING_SHOW_LOCAL" = "true" ]; then
        SETTING_SHOW_LOCAL="false"
    else
        SETTING_SHOW_LOCAL="true"
    fi
    save_setting "show_local" "$SETTING_SHOW_LOCAL"
    LOG "Show local payloads: $SETTING_SHOW_LOCAL"
}

settings_reset() {
    local resp=$(CONFIRMATION_DIALOG "Reset all settings to defaults?")
    if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        PAYLOAD_DEL_CONFIG "$CONFIG_NAME" default_mode
        PAYLOAD_DEL_CONFIG "$CONFIG_NAME" custom_repo
        PAYLOAD_DEL_CONFIG "$CONFIG_NAME" custom_branch
        PAYLOAD_DEL_CONFIG "$CONFIG_NAME" show_local
        PAYLOAD_DEL_CONFIG "$CONFIG_NAME" first_run_done

        # Reset runtime values
        SETTING_DEFAULT_MODE="ask"
        SETTING_CUSTOM_REPO=""
        SETTING_CUSTOM_BRANCH=""
        SETTING_SHOW_LOCAL="true"
        GH_ORG="hak5"
        GH_REPO="wifipineapplepager-payloads"
        GH_BRANCH="master"
        build_zip_url
        GITHUB_DOWNLOADED=false

        LOG "Settings reset to defaults"
    fi
}

# Detect target directory
if [ -d "/mmc/root/payloads" ]; then
    TARGET_DIR="/mmc/root/payloads"
elif [ -d "/root/payloads" ]; then
    TARGET_DIR="/root/payloads"
else
    TARGET_DIR="/mmc/root/payloads"
fi

TEMP_DIR="/tmp/payload_manager"
GITHUB_CACHE="/tmp/pm_github.txt"
LOCAL_CACHE="/tmp/pm_local.txt"
DIFF_CACHE="/tmp/pm_diff.txt"

# Status constants
STATUS_NEW="NEW"
STATUS_OK="OK"
STATUS_OUTDATED="UPD"
STATUS_DISABLED="DIS"
STATUS_LOCAL="LOC"

# State
PENDING_UPDATE_PATH=""
GITHUB_DOWNLOADED=false

# === UTILITY FUNCTIONS ===

# Extract metadata from a payload file
# Returns: title|description|author|version
get_payload_meta() {
    local pfile="$1"
    local title="" desc="" author="" version=""

    if [ -f "$pfile" ]; then
        title=$(grep -m 1 -i "^# *Title:" "$pfile" 2>/dev/null | cut -d: -f2- | sed 's/^[ \t]*//;s/[ \t]*$//')
        desc=$(grep -m 1 -i "^# *Description:" "$pfile" 2>/dev/null | cut -d: -f2- | sed 's/^[ \t]*//;s/[ \t]*$//')
        author=$(grep -m 1 -i "^# *Author:" "$pfile" 2>/dev/null | cut -d: -f2- | sed 's/^[ \t]*//;s/[ \t]*$//')
        version=$(grep -m 1 -i "^# *Version:" "$pfile" 2>/dev/null | cut -d: -f2- | sed 's/^[ \t]*//;s/[ \t]*$//')
    fi

    echo "$title|$desc|$author|$version"
}

# Compare versions - returns 0 if v1 > v2
version_newer() {
    local v1="$1"
    local v2="$2"

    [ -z "$v1" ] && return 1
    [ -z "$v2" ] && return 0
    [ "$v1" = "$v2" ] && return 1

    # Use sort -V for version comparison
    local highest=$(printf '%s\n' "$v1" "$v2" | sort -V 2>/dev/null | tail -n1)
    [ "$highest" = "$v1" ]
}

# === DEPENDENCY CHECK ===

check_dependencies() {
    LED SETUP
    local need_install=""

    if ! which wget > /dev/null 2>&1; then
        need_install="wget"
    fi

    if ! which unzip > /dev/null 2>&1; then
        need_install="$need_install unzip"
    fi

    if [ -n "$need_install" ]; then
        LOG "Installing: $need_install"
        opkg update > /dev/null 2>&1
        for pkg in $need_install; do
            if ! opkg install "$pkg" > /dev/null 2>&1; then
                LED FAIL
                ERROR_DIALOG "Failed to install $pkg"
                exit 1
            fi
        done
    fi
}

# === LOCAL PAYLOAD SCANNING ===

# Scan local payloads and write to cache
# Format: rel_path|name|version|disabled
scan_local_payloads() {
    > "$LOCAL_CACHE"

    # Find enabled payloads (payload.sh)
    find "$TARGET_DIR" -name "payload.sh" -type f 2>/dev/null | while read -r pfile; do
        local dir=$(dirname "$pfile")
        local rel_path="${dir#$TARGET_DIR/}"
        local name=$(basename "$dir")
        local meta=$(get_payload_meta "$pfile")
        local version=$(echo "$meta" | cut -d'|' -f4)

        echo "$rel_path|$name|$version|false" >> "$LOCAL_CACHE"
    done

    # Find disabled payloads (payload.sh.disabled)
    find "$TARGET_DIR" -name "payload.sh.disabled" -type f 2>/dev/null | while read -r pfile; do
        local dir=$(dirname "$pfile")
        local rel_path="${dir#$TARGET_DIR/}"
        local name=$(basename "$dir")
        local meta=$(get_payload_meta "$pfile")
        local version=$(echo "$meta" | cut -d'|' -f4)

        echo "$rel_path|$name|$version|true" >> "$LOCAL_CACHE"
    done
}

# === GITHUB DOWNLOAD AND SCANNING ===

download_github_repo() {
    if [ "$GITHUB_DOWNLOADED" = true ] && [ -d "$TEMP_DIR/$GH_REPO-$GH_BRANCH/library" ]; then
        return 0
    fi

    LED ATTACK
    LOG "Downloading payload repository..."

    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"

    if ! wget -q --no-check-certificate "$ZIP_URL" -O "$TEMP_DIR/$GH_BRANCH.zip" 2>/dev/null; then
        LED FAIL
        ERROR_DIALOG "Download failed. Check network."
        return 1
    fi

    if ! unzip -q "$TEMP_DIR/$GH_BRANCH.zip" -d "$TEMP_DIR" 2>/dev/null; then
        LED FAIL
        ERROR_DIALOG "Failed to extract archive"
        return 1
    fi

    GITHUB_DOWNLOADED=true
    return 0
}

# Scan GitHub payloads and write to cache
# Format: rel_path|name|version
scan_github_payloads() {
    local src_lib="$TEMP_DIR/$GH_REPO-$GH_BRANCH/library"
    > "$GITHUB_CACHE"

    if [ ! -d "$src_lib" ]; then
        return 1
    fi

    find "$src_lib" -name "payload.sh" -type f 2>/dev/null | while read -r pfile; do
        local dir=$(dirname "$pfile")
        local rel_path="${dir#$src_lib/}"
        local name=$(basename "$dir")
        local meta=$(get_payload_meta "$pfile")
        local version=$(echo "$meta" | cut -d'|' -f4)

        echo "$rel_path|$name|$version" >> "$GITHUB_CACHE"
    done
}

# === DIFF/COMPARISON LOGIC ===

# Build comprehensive diff between local and GitHub
# Format: rel_path|name|github_ver|local_ver|status|disabled
build_payload_diff() {
    LOG "Scanning local payloads..."
    scan_local_payloads

    if ! download_github_repo; then
        return 1
    fi

    LOG "Scanning GitHub payloads..."
    scan_github_payloads

    LED SPECIAL
    LOG "Comparing..."

    > "$DIFF_CACHE"

    # Process GitHub payloads
    while IFS='|' read -r gh_rel_path gh_name gh_version; do
        [ -z "$gh_name" ] && continue

        local found=false
        local local_version=""
        local is_disabled=false

        # Search in local cache
        while IFS='|' read -r loc_rel_path loc_name loc_version loc_disabled; do
            if [ "$loc_name" = "$gh_name" ]; then
                found=true
                local_version="$loc_version"
                [ "$loc_disabled" = "true" ] && is_disabled=true
                break
            fi
        done < "$LOCAL_CACHE"

        if [ "$found" = false ]; then
            echo "$gh_rel_path|$gh_name|$gh_version||$STATUS_NEW|false" >> "$DIFF_CACHE"
        elif version_newer "$gh_version" "$local_version"; then
            echo "$gh_rel_path|$gh_name|$gh_version|$local_version|$STATUS_OUTDATED|$is_disabled" >> "$DIFF_CACHE"
        else
            echo "$gh_rel_path|$gh_name|$gh_version|$local_version|$STATUS_OK|$is_disabled" >> "$DIFF_CACHE"
        fi
    done < "$GITHUB_CACHE"

    # Find local-only payloads (if show_local is enabled)
    if [ "$SETTING_SHOW_LOCAL" = "true" ]; then
        while IFS='|' read -r loc_rel_path loc_name loc_version loc_disabled; do
            [ -z "$loc_name" ] && continue

            local in_github=false
            while IFS='|' read -r gh_rel_path gh_name gh_version; do
                if [ "$gh_name" = "$loc_name" ]; then
                    in_github=true
                    break
                fi
            done < "$GITHUB_CACHE"

            if [ "$in_github" = false ]; then
                echo "$loc_rel_path|$loc_name||$loc_version|$STATUS_LOCAL|$loc_disabled" >> "$DIFF_CACHE"
            fi
        done < "$LOCAL_CACHE"
    fi

    LED FINISH
    return 0
}

# === CORE ACTIONS ===

install_payload() {
    local rel_path="$1"
    local name="$2"
    local src_lib="$TEMP_DIR/$GH_REPO-$GH_BRANCH/library"
    local src_path="$src_lib/$rel_path"
    local target_path="$TARGET_DIR/$rel_path"

    if [ ! -d "$src_path" ]; then
        ERROR_DIALOG "Source not found in repo"
        return 1
    fi

    LED ATTACK
    LOG "Installing $name..."

    mkdir -p "$(dirname "$target_path")"

    if cp -rf "$src_path" "$target_path" 2>/dev/null; then
        LED FINISH
        LOG "Installed: $name"
        return 0
    else
        LED FAIL
        ERROR_DIALOG "Failed to install $name"
        return 1
    fi
}

uninstall_payload() {
    local rel_path="$1"
    local name="$2"
    local target_path="$TARGET_DIR/$rel_path"

    if [ ! -d "$target_path" ]; then
        ERROR_DIALOG "Payload not found"
        return 1
    fi

    # Self-protection
    if [ -f "$target_path/payload.sh" ] && [ "$target_path/payload.sh" -ef "$0" ]; then
        ERROR_DIALOG "Cannot uninstall self"
        return 1
    fi

    local resp=$(CONFIRMATION_DIALOG "Uninstall $name?")
    if [ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        return 1
    fi

    LED ATTACK
    LOG "Uninstalling $name..."

    if rm -rf "$target_path" 2>/dev/null; then
        LED FINISH
        LOG "Uninstalled: $name"
        return 0
    else
        LED FAIL
        ERROR_DIALOG "Failed to uninstall"
        return 1
    fi
}

disable_payload() {
    local rel_path="$1"
    local name="$2"
    local target_path="$TARGET_DIR/$rel_path"
    local pfile="$target_path/payload.sh"
    local disabled_file="$target_path/payload.sh.disabled"

    if [ ! -f "$pfile" ]; then
        ERROR_DIALOG "Payload not found or already disabled"
        return 1
    fi

    # Self-protection
    if [ "$pfile" -ef "$0" ]; then
        ERROR_DIALOG "Cannot disable self"
        return 1
    fi

    LED ATTACK
    LOG "Disabling $name..."

    if mv "$pfile" "$disabled_file" 2>/dev/null; then
        LED FINISH
        LOG "Disabled: $name"
        return 0
    else
        LED FAIL
        ERROR_DIALOG "Failed to disable"
        return 1
    fi
}

enable_payload() {
    local rel_path="$1"
    local name="$2"
    local target_path="$TARGET_DIR/$rel_path"
    local pfile="$target_path/payload.sh"
    local disabled_file="$target_path/payload.sh.disabled"

    if [ ! -f "$disabled_file" ]; then
        ERROR_DIALOG "Disabled payload not found"
        return 1
    fi

    LED ATTACK
    LOG "Enabling $name..."

    if mv "$disabled_file" "$pfile" 2>/dev/null; then
        LED FINISH
        LOG "Enabled: $name"
        return 0
    else
        LED FAIL
        ERROR_DIALOG "Failed to enable"
        return 1
    fi
}

update_payload() {
    local rel_path="$1"
    local name="$2"
    local src_lib="$TEMP_DIR/$GH_REPO-$GH_BRANCH/library"
    local src_path="$src_lib/$rel_path"
    local target_path="$TARGET_DIR/$rel_path"
    local was_disabled=false

    # Preserve disabled state across update
    if [ -f "$target_path/payload.sh.disabled" ]; then
        was_disabled=true
    fi

    # Self-update protection
    if [ -f "$target_path/payload.sh" ] && [ "$target_path/payload.sh" -ef "$0" ]; then
        LOG "Queuing self-update..."
        cp "$src_path/payload.sh" "/tmp/pending_pm_update.sh"
        PENDING_UPDATE_PATH="/tmp/pending_pm_update.sh"
        # Copy other files immediately
        find "$src_path" -type f ! -name "payload.sh" | while read -r sfile; do
            local rel_name="${sfile#$src_path/}"
            local dfile="$target_path/$rel_name"
            mkdir -p "$(dirname "$dfile")"
            cp "$sfile" "$dfile"
        done
        LOG "Update queued (applies on exit)"
        return 0
    fi

    LED ATTACK
    LOG "Updating $name..."

    rm -rf "$target_path"

    if cp -rf "$src_path" "$target_path" 2>/dev/null; then
        if [ "$was_disabled" = true ] && [ -f "$target_path/payload.sh" ]; then
            mv "$target_path/payload.sh" "$target_path/payload.sh.disabled" 2>/dev/null
        fi
        LED FINISH
        LOG "Updated: $name"
        return 0
    else
        LED FAIL
        ERROR_DIALOG "Failed to update"
        return 1
    fi
}

# === MENU SYSTEM ===

show_main_menu() {
    while true; do
        LOG ""
        LOG "=== PAYLOAD MANAGER ==="
        LOG "1) Browse & Compare"
        LOG "2) Check for Updates"
        LOG "3) Manage Installed"
        LOG "4) Manage Disabled"
        LOG "5) Settings"
        LOG "6) Exit"
        LOG ""
        LOG green "Press GREEN when ready"
        WAIT_FOR_BUTTON_PRESS A

        local choice=$(NUMBER_PICKER "Select option" 1)

        case "$choice" in
            1) browse_payloads ;;
            2) check_updates ;;
            3) manage_installed ;;
            4) manage_disabled ;;
            5) show_settings_menu ;;
            6) cleanup_and_exit ;;
            *) ;;
        esac
    done
}

browse_payloads() {
    if ! build_payload_diff; then
        return
    fi

    while true; do
        # Get unique top-level categories
        local categories=$(cut -d'/' -f1 "$DIFF_CACHE" 2>/dev/null | sort -u)

        if [ -z "$categories" ]; then
            ALERT "No payloads found"
            return
        fi

        LOG ""
        LOG "=== CATEGORIES ==="

        local idx=1
        local cat_array=()

        while read -r cat; do
            [ -z "$cat" ] && continue
            local count=$(grep "^$cat/" "$DIFF_CACHE" 2>/dev/null | wc -l)
            LOG "$idx) $cat ($count)"
            cat_array+=("$cat")
            idx=$((idx + 1))
        done <<< "$categories"

        LOG "$idx) Back"
        LOG ""
        LOG green "Press GREEN when ready"
        WAIT_FOR_BUTTON_PRESS A

        local choice=$(NUMBER_PICKER "Select category" 1)

        if [ "$choice" -ge "$idx" ] || [ "$choice" -lt 1 ]; then
            return
        fi

        local selected_cat="${cat_array[$((choice-1))]}"
        browse_subcategory "$selected_cat"
    done
}

browse_subcategory() {
    local category="$1"

    while true; do
        # Get subcategories
        local subcats=$(grep "^$category/" "$DIFF_CACHE" 2>/dev/null | cut -d'/' -f2 | sort -u)

        LOG ""
        LOG "=== $category ==="

        local idx=1
        local subcat_array=()

        while read -r subcat; do
            [ -z "$subcat" ] && continue
            local count=$(grep "^$category/$subcat/" "$DIFF_CACHE" 2>/dev/null | wc -l)
            LOG "$idx) $subcat ($count)"
            subcat_array+=("$subcat")
            idx=$((idx + 1))
        done <<< "$subcats"

        LOG "$idx) Back"
        LOG ""
        LOG green "Press GREEN when ready"
        WAIT_FOR_BUTTON_PRESS A

        local choice=$(NUMBER_PICKER "Select" 1)

        if [ "$choice" -ge "$idx" ] || [ "$choice" -lt 1 ]; then
            return
        fi

        local selected_subcat="${subcat_array[$((choice-1))]}"
        browse_payloads_list "$category/$selected_subcat"
    done
}

browse_payloads_list() {
    local path_prefix="$1"

    while true; do
        LOG ""
        LOG "=== $path_prefix ==="

        local idx=1
        local payload_lines=()

        while IFS='|' read -r rel_path name gh_ver loc_ver status disabled; do
            if [[ "$rel_path" == $path_prefix/* ]]; then
                local status_icon=""

                if [ "$disabled" = "true" ]; then
                    if [ "$status" = "$STATUS_OUTDATED" ]; then
                        status_icon="[DIS][UPD]"
                    elif [ "$status" = "$STATUS_LOCAL" ]; then
                        status_icon="[DIS][LOC]"
                    else
                        status_icon="[DIS]"
                    fi
                else
                    case "$status" in
                        "$STATUS_NEW") status_icon="[NEW]" ;;
                        "$STATUS_OK") status_icon="[OK]" ;;
                        "$STATUS_OUTDATED") status_icon="[UPD]" ;;
                        "$STATUS_LOCAL") status_icon="[LOC]" ;;
                    esac
                fi

                LOG "$idx) $status_icon $name"
                payload_lines+=("$rel_path|$name|$gh_ver|$loc_ver|$status|$disabled")
                idx=$((idx + 1))
            fi
        done < "$DIFF_CACHE"

        if [ ${#payload_lines[@]} -eq 0 ]; then
            ALERT "No payloads in this category"
            return
        fi

        LOG "$idx) Back"
        LOG ""
        LOG green "Press GREEN when ready"
        WAIT_FOR_BUTTON_PRESS A

        local choice=$(NUMBER_PICKER "Select payload" 1)

        if [ "$choice" -ge "$idx" ] || [ "$choice" -lt 1 ]; then
            return
        fi

        local selected="${payload_lines[$((choice-1))]}"
        show_payload_detail "$selected"

        # Refresh diff after action
        build_payload_diff > /dev/null 2>&1
    done
}

show_payload_detail() {
    local payload_info="$1"
    IFS='|' read -r rel_path name gh_ver loc_ver status disabled <<< "$payload_info"

    # Get metadata from appropriate source
    local pfile=""
    if [ "$status" = "$STATUS_NEW" ]; then
        pfile="$TEMP_DIR/$GH_REPO-$GH_BRANCH/library/$rel_path/payload.sh"
    else
        local target="$TARGET_DIR/$rel_path"
        [ -f "$target/payload.sh" ] && pfile="$target/payload.sh"
        [ -f "$target/payload.sh.disabled" ] && pfile="$target/payload.sh.disabled"
    fi

    local meta=$(get_payload_meta "$pfile")
    IFS='|' read -r title desc author version <<< "$meta"

    LOG ""
    LOG "=== $name ==="
    [ -n "$title" ] && LOG "Title: $title"
    [ -n "$desc" ] && LOG "Desc: $desc"
    [ -n "$author" ] && LOG "Author: $author"
    LOG "GitHub: ${gh_ver:-N/A}"
    LOG "Local: ${loc_ver:-Not installed}"
    if [ "$disabled" = "true" ]; then
        LOG "Status: $status (disabled)"
    else
        LOG "Status: $status"
    fi
    LOG ""

    # Build action menu based on status
    local actions=()
    local action_idx=1

    case "$status" in
        "$STATUS_NEW")
            LOG "$action_idx) Install"
            actions+=("install")
            action_idx=$((action_idx + 1))
            ;;
        "$STATUS_OK")
            if [ "$disabled" = "true" ]; then
                LOG "$action_idx) Enable"
                actions+=("enable")
                action_idx=$((action_idx + 1))
            else
                LOG "$action_idx) Disable"
                actions+=("disable")
                action_idx=$((action_idx + 1))
            fi
            LOG "$action_idx) Uninstall"
            actions+=("uninstall")
            action_idx=$((action_idx + 1))
            ;;
        "$STATUS_OUTDATED")
            LOG "$action_idx) Update"
            actions+=("update")
            action_idx=$((action_idx + 1))
            if [ "$disabled" = "true" ]; then
                LOG "$action_idx) Enable"
                actions+=("enable")
                action_idx=$((action_idx + 1))
            else
                LOG "$action_idx) Disable"
                actions+=("disable")
                action_idx=$((action_idx + 1))
            fi
            LOG "$action_idx) Uninstall"
            actions+=("uninstall")
            action_idx=$((action_idx + 1))
            ;;
        "$STATUS_LOCAL")
            if [ "$disabled" = "true" ]; then
                LOG "$action_idx) Enable"
                actions+=("enable")
                action_idx=$((action_idx + 1))
            else
                LOG "$action_idx) Disable"
                actions+=("disable")
                action_idx=$((action_idx + 1))
            fi
            LOG "$action_idx) Uninstall"
            actions+=("uninstall")
            action_idx=$((action_idx + 1))
            ;;
    esac

    LOG "$action_idx) Back"
    LOG ""
    LOG green "Press GREEN when ready"
    WAIT_FOR_BUTTON_PRESS A

    local choice=$(NUMBER_PICKER "Select action" 1)

    if [ "$choice" -ge "$action_idx" ] || [ "$choice" -lt 1 ]; then
        return
    fi

    local action="${actions[$((choice-1))]}"

    case "$action" in
        "install") install_payload "$rel_path" "$name" ;;
        "uninstall") uninstall_payload "$rel_path" "$name" ;;
        "disable") disable_payload "$rel_path" "$name" ;;
        "enable") enable_payload "$rel_path" "$name" ;;
        "update") update_payload "$rel_path" "$name" ;;
    esac
}

check_updates() {
    if ! build_payload_diff; then
        return
    fi

    local new_count=$(grep "|$STATUS_NEW|" "$DIFF_CACHE" 2>/dev/null | wc -l)
    local upd_count=$(grep "|$STATUS_OUTDATED|" "$DIFF_CACHE" 2>/dev/null | wc -l)
    local dis_count=$(grep "|true$" "$DIFF_CACHE" 2>/dev/null | wc -l)
    local ok_count=$(grep "|$STATUS_OK|" "$DIFF_CACHE" 2>/dev/null | wc -l)
    local total=$((new_count + upd_count))

    LOG ""
    LOG "=== UPDATE SUMMARY ==="
    LOG "Up to date: $ok_count"
    LOG "New available: $new_count"
    LOG "Updates available: $upd_count"
    LOG "Disabled: $dis_count"
    LOG ""

    if [ "$total" -eq 0 ]; then
        ALERT "All payloads up to date!"
        return
    fi

    # Determine update mode based on settings
    local batch_mode=""

    if [ "$SETTING_DEFAULT_MODE" = "interactive" ]; then
        batch_mode="INTERACTIVE"
    elif [ "$SETTING_DEFAULT_MODE" = "batch" ]; then
        batch_mode="UPDATE_ALL"
    else
        # "ask" mode - prompt user
        local resp=$(CONFIRMATION_DIALOG "Review each payload individually?")
        if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
            batch_mode="INTERACTIVE"
        else
            local batch_resp=$(CONFIRMATION_DIALOG "Install/Update ALL $total payloads?")
            if [ "$batch_resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                batch_mode="UPDATE_ALL"
            else
                batch_mode="SKIP_ALL"
            fi
        fi
    fi

    if [ "$batch_mode" = "SKIP_ALL" ]; then
        LOG "Update cancelled"
        return
    fi

    LED SPECIAL
    local count_new=0
    local count_updated=0
    local count_skipped=0
    local log_buffer=""

    # Process NEW payloads
    while IFS='|' read -r rel_path name gh_ver loc_ver status disabled; do
        [ "$status" != "$STATUS_NEW" ] && continue

        local do_install=false
        local meta=$(get_payload_meta "$TEMP_DIR/$GH_REPO-$GH_BRANCH/library/$rel_path/payload.sh")
        local title=$(echo "$meta" | cut -d'|' -f1)
        local display_name="$name"
        [ -n "$title" ] && display_name="$name ($title)"

        if [ "$batch_mode" = "UPDATE_ALL" ]; then
            do_install=true
        else
            # Interactive mode
            LED SPECIAL
            local iresp=$(CONFIRMATION_DIALOG "Install NEW: $display_name?")
            if [ "$iresp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                do_install=true
            fi
        fi

        if [ "$do_install" = true ]; then
            install_payload "$rel_path" "$name" > /dev/null 2>&1
            log_buffer+="[NEW] $title\n"
            count_new=$((count_new + 1))
        else
            log_buffer+="[SKIP] $title\n"
            count_skipped=$((count_skipped + 1))
        fi
    done < "$DIFF_CACHE"

    # Process OUTDATED payloads
    while IFS='|' read -r rel_path name gh_ver loc_ver status disabled; do
        [ "$status" != "$STATUS_OUTDATED" ] && continue

        local do_update=false
        local meta=$(get_payload_meta "$TEMP_DIR/$GH_REPO-$GH_BRANCH/library/$rel_path/payload.sh")
        local title=$(echo "$meta" | cut -d'|' -f1)
        local display_name="$name"
        [ -n "$title" ] && display_name="$name ($title)"

        if [ "$batch_mode" = "UPDATE_ALL" ]; then
            do_update=true
        else
            # Interactive mode
            LED SPECIAL
            local iresp=$(CONFIRMATION_DIALOG "Update: $display_name ($loc_ver -> $gh_ver)?")
            if [ "$iresp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
                do_update=true
            fi
        fi

        if [ "$do_update" = true ]; then
            update_payload "$rel_path" "$name" > /dev/null 2>&1
            log_buffer+="[UPD] $title\n"
            count_updated=$((count_updated + 1))
        else
            log_buffer+="[SKIP] $title\n"
            count_skipped=$((count_skipped + 1))
        fi
    done < "$DIFF_CACHE"

    LED FINISH
    LOG ""
    LOG "=== UPDATE COMPLETE ==="
    printf "$log_buffer"
    LOG ""
    LOG "New: $count_new, Updated: $count_updated, Skipped: $count_skipped"
}

manage_installed() {
    scan_local_payloads

    while true; do
        LOG ""
        LOG "=== INSTALLED PAYLOADS ==="

        local idx=1
        local payload_lines=()

        while IFS='|' read -r rel_path name version disabled; do
            [ -z "$name" ] && continue
            [ "$disabled" = "true" ] && continue

            LOG "$idx) $name (v$version)"
            payload_lines+=("$rel_path|$name|$version")
            idx=$((idx + 1))
        done < "$LOCAL_CACHE"

        if [ ${#payload_lines[@]} -eq 0 ]; then
            ALERT "No installed payloads found"
            return
        fi

        LOG "$idx) Back"
        LOG ""
        LOG green "Press GREEN when ready"
        WAIT_FOR_BUTTON_PRESS A

        local choice=$(NUMBER_PICKER "Select payload" 1)

        if [ "$choice" -ge "$idx" ] || [ "$choice" -lt 1 ]; then
            return
        fi

        local selected="${payload_lines[$((choice-1))]}"
        IFS='|' read -r rel_path name version <<< "$selected"

        LOG ""
        LOG "=== $name ==="
        LOG "Version: $version"
        LOG ""
        LOG "1) Disable"
        LOG "2) Uninstall"
        LOG "3) Back"
        LOG ""
        LOG green "Press GREEN when ready"
        WAIT_FOR_BUTTON_PRESS A

        local action=$(NUMBER_PICKER "Select action" 1)

        case "$action" in
            1) disable_payload "$rel_path" "$name" ;;
            2) uninstall_payload "$rel_path" "$name" ;;
        esac

        scan_local_payloads
    done
}

manage_disabled() {
    scan_local_payloads

    while true; do
        LOG ""
        LOG "=== DISABLED PAYLOADS ==="

        local idx=1
        local payload_lines=()

        while IFS='|' read -r rel_path name version disabled; do
            [ -z "$name" ] && continue
            [ "$disabled" != "true" ] && continue

            LOG "$idx) $name"
            payload_lines+=("$rel_path|$name|$version")
            idx=$((idx + 1))
        done < "$LOCAL_CACHE"

        if [ ${#payload_lines[@]} -eq 0 ]; then
            ALERT "No disabled payloads"
            return
        fi

        LOG "$idx) Back"
        LOG ""
        LOG green "Press GREEN when ready"
        WAIT_FOR_BUTTON_PRESS A

        local choice=$(NUMBER_PICKER "Select payload" 1)

        if [ "$choice" -ge "$idx" ] || [ "$choice" -lt 1 ]; then
            return
        fi

        local selected="${payload_lines[$((choice-1))]}"
        IFS='|' read -r rel_path name version <<< "$selected"

        LOG ""
        LOG "=== $name ==="
        LOG "1) Enable"
        LOG "2) Uninstall"
        LOG "3) Back"
        LOG ""
        LOG green "Press GREEN when ready"
        WAIT_FOR_BUTTON_PRESS A

        local action=$(NUMBER_PICKER "Select action" 1)

        case "$action" in
            1) enable_payload "$rel_path" "$name" ;;
            2) uninstall_payload "$rel_path" "$name" ;;
        esac

        scan_local_payloads
    done
}

# === CLEANUP ===

cleanup() {
    rm -rf "$TEMP_DIR"
    rm -f "$GITHUB_CACHE" "$LOCAL_CACHE" "$DIFF_CACHE"
}

cleanup_and_exit() {
    # Apply pending self-update
    if [ -f "$PENDING_UPDATE_PATH" ]; then
        cat "$PENDING_UPDATE_PATH" > "$0"
        rm -f "$PENDING_UPDATE_PATH"
    fi

    cleanup
    LED FINISH
    LOG "Goodbye!"
    exit 0
}

# === MAIN ===
trap cleanup EXIT

check_dependencies
load_settings
build_zip_url

# First run setup
if is_first_run; then
    first_run_setup
fi

show_main_menu
