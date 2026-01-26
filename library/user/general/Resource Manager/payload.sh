    #!/bin/bash
    # Title:  Resource_Manager
    # Description: Unified payload with two modes: Download All or Update Installed Only
    # Author: Z3r0L1nk (based on cococode's work)
    # Version: 2.1.1

    # === CONFIGURATION ===
    CACHE_ROOT="/mmc/root/pager_update_cache"
    RESOURCES=(
        "Payloads|wifipineapplepager-payloads|master|Update_Payloads|/mmc/root/payloads|PAYLOAD_DIRS"
        "Themes|wifipineapplepager-themes|master|Update_Themes|/mmc/root/themes|THEME_DIRS"
        "Ringtones|wifipineapplepager-ringtones|master|Update_Ringtones|/mmc/root/ringtones|FLAT_FILES"
    )

    GH_ORG="hak5"

    # === STATE ===
    BATCH_MODE=""           # "" (Interactive), "OVERWRITE", "SKIP"
    FIRST_CONFLICT=true
    COUNT_NEW=0
    COUNT_UPDATED=0
    COUNT_SKIPPED=0
    LOG_BUFFER=""
    UPDATE_MODE=""          # "DOWNLOAD_ALL" or "UPDATE_INSTALLED"
    SELF_UPDATE_SRC=""
    SELF_UPDATE_DST=""
    SELF_UPDATE_LABEL=""
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # === UTILITIES ===

    setup() {
        LED SETUP
        if [ "$(opkg status git-http)" == "" ]; then
            LOG "One-time setup: installing dependencies (git, git-http, diffutils)..."
            opkg update
            opkg install git git-http diffutils
        fi
    }

    get_payload_title() {
        local pfile="$1/payload.sh"
        if [ -f "$pfile" ]; then
            grep -m 1 "^# *Title:" "$pfile" | cut -d: -f2- | sed 's/^[ \t]*//;s/[ \t]*$//'
        else
            basename "$1"
        fi
    }

    get_theme_title() {
        basename "$1"
    }

    get_ringtone_title() {
        local rfile="$1"
        IFS=':' read -r rname _ < "$rfile"
        echo "$rname"
    }

    # === CORE LOGIC ===

    update_repo() {
        local repo="$1"
        local branch="$2"
        local cache_dir="$3"
        local git_url="https://github.com/$GH_ORG/$repo.git"

        LED ATTACK
        
        if [ -d "$cache_dir" ]; then
            cd "$cache_dir" || return 1
            local current_remote=$(git remote get-url origin 2>/dev/null)
            if [ "$current_remote" == "$git_url" ]; then
                LOG "Checking for updates: $repo..."
                git reset --hard HEAD > /dev/null
                git clean -df > /dev/null
                git checkout "$branch" > /dev/null 2>&1
                if ! git pull -q; then
                    LOG "Pull failed for $repo. Check internet."
                    return 1
                fi
                return 0
            fi
        fi

        # Clone if cache missing or invalid
        rm -rf "$cache_dir"
        mkdir -p "$(dirname "$cache_dir")"
        LOG "Cloning $repo..."
        if ! git clone -b "$branch" "$git_url" --depth 1 "$cache_dir" -q; then
            LOG "Clone failed for $repo. Check internet."
            return 1
        fi
    }

    process_resource() {
        local name="$1"
        local cache_dir="$2"
        local target_root="$3"
        local type="$4"

        LED SPECIAL
        local file_list="/tmp/pager_update_list.txt"
        
        # 1. Identify Items based on Type
        case "$type" in
            "PAYLOAD_DIRS")
                if [ ! -d "$cache_dir/library" ]; then LOG "Invalid payload repo structure"; return; fi
                # Find payload.sh, treat parent dir as unit
                find "$cache_dir/library" -name "payload.sh" > "$file_list"
                root_prefix="$cache_dir/library/"
                ;;
            "THEME_DIRS")
                if [ ! -d "$cache_dir/themes" ]; then LOG "Invalid theme repo structure"; return; fi
                # Find theme.json, treat parent dir as unit
                find "$cache_dir/themes" -name "theme.json" > "$file_list"
                root_prefix="$cache_dir/themes/"
                ;;
            "FLAT_FILES")
                local search_root="$cache_dir"
                [ -d "$cache_dir/ringtones" ] && search_root="$cache_dir/ringtones"
                
                find "$search_root" -name "*.rtttl" > "$file_list"
                root_prefix="$search_root/"
                ;;
        esac

        # 2. Process Items
        while read -r found_file; do
            local src_item=""
            local item_rel_path=""
            local item_title=""
            local target_path=""

            if [ "$type" == "FLAT_FILES" ]; then
                src_item="$found_file"
                item_rel_path="${src_item#$root_prefix}"
                target_path="$target_root/$item_rel_path"
                item_title=$(get_ringtone_title "$src_item")
            else
                # Directory based
                src_item=$(dirname "$found_file")
                item_rel_path="${src_item#$root_prefix}"
                target_path="$target_root/$item_rel_path"
                if [ "$type" == "PAYLOAD_DIRS" ]; then
                    item_title=$(get_payload_title "$src_item")
                    # Handle DISABLED logic for payloads
                    local dir_name=$(basename "$src_item")
                    local disabled_path="$(dirname "$target_path")/DISABLED.$dir_name"
                    if [ -d "$disabled_path" ]; then target_path="$disabled_path"; fi
                elif [ "$type" == "THEME_DIRS" ]; then
                    item_title=$(get_theme_title "$src_item")
                fi
            fi

            # Download mode: Only download items NOT already present
            if [ -e "$target_path" ]; then
                COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
                continue # Already exists, skip
            fi

            # New item - download it
            if [ "$type" == "PAYLOAD_DIRS" ] && [[ "$item_rel_path" =~ ^alerts/ ]]; then
                target_path="$(dirname "$target_path")/DISABLED.$(basename "$target_path")"
            fi

            mkdir -p "$(dirname "$target_path")"
            cp -rf "$src_item" "$target_path"
            LOG_BUFFER+="[ NEW ] $name: $item_title\n"
            COUNT_NEW=$((COUNT_NEW + 1))

        done < "$file_list"
        rm -f "$file_list"
    }

    handle_conflict() {
        local src="$1"
        local dst="$2"
        local label="$3"
        local do_overwrite=false

        # Detect self-update and defer it
        if [[ "$dst" == "$SCRIPT_DIR"* ]] || [[ "$dst" == "$SCRIPT_DIR" ]]; then
            SELF_UPDATE_SRC="$src"
            SELF_UPDATE_DST="$dst"
            SELF_UPDATE_LABEL="$label"
            LOG_BUFFER+="[ DEFERRED ] $label (self-update queued for end)\n"
            return
        fi

        # Bulk Choice
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

    process_installed_only() {
        local name="$1"
        local cache_dir="$2"
        local target_root="$3"
        local type="$4"

        LED SPECIAL
        
        case "$type" in
            "PAYLOAD_DIRS")
                if [ ! -d "$cache_dir/library" ]; then LOG "Invalid payload repo structure"; return; fi
                cache_prefix="$cache_dir/library/"
                ;;
            "THEME_DIRS")
                if [ ! -d "$cache_dir/themes" ]; then LOG "Invalid theme repo structure"; return; fi
                cache_prefix="$cache_dir/themes/"
                ;;
            "FLAT_FILES")
                cache_prefix="$cache_dir/"
                [ -d "$cache_dir/ringtones" ] && cache_prefix="$cache_dir/ringtones/"
                ;;
        esac

        # Scan LOCAL installed items and check for updates in cache
        if [ "$type" == "FLAT_FILES" ]; then
            # Ringtones: scan local .rtttl files
            find "$target_root" -name "*.rtttl" 2>/dev/null | while read -r local_file; do
                local rel_path="${local_file#$target_root/}"
                local cache_file="$cache_prefix$rel_path"
                
                if [ -f "$cache_file" ]; then
                    if ! diff -q "$cache_file" "$local_file" > /dev/null 2>&1; then
                        local item_title=$(get_ringtone_title "$local_file")
                        handle_conflict "$cache_file" "$local_file" "$name: $item_title"
                    fi
                fi
            done
        else
            # Payloads/Themes: scan local directories
            local marker_file="payload.sh"
            [ "$type" == "THEME_DIRS" ] && marker_file="theme.json"
            
            find "$target_root" -name "$marker_file" 2>/dev/null | while read -r local_marker; do
                local local_dir=$(dirname "$local_marker")
                local dir_name=$(basename "$local_dir")
                
                # Handle DISABLED. prefix
                local clean_name="${dir_name#DISABLED.}"
                local rel_path="${local_dir#$target_root/}"
                local clean_rel_path="${rel_path/DISABLED./}"
                
                local cache_item="$cache_prefix$clean_rel_path"
                
                if [ -d "$cache_item" ]; then
                    if ! diff -r -q "$cache_item" "$local_dir" > /dev/null 2>&1; then
                        local item_title=""
                        if [ "$type" == "PAYLOAD_DIRS" ]; then
                            item_title=$(get_payload_title "$local_dir")
                        else
                            item_title=$(get_theme_title "$local_dir")
                        fi
                        handle_conflict "$cache_item" "$local_dir" "$name: $item_title"
                    fi
                fi
            done
        fi
    }

    start_ui() {
        local selected_indices=()
        
        LED SETUP
        # Main Menu: Download All vs Update Installed
        if [ "$(CONFIRMATION_DIALOG "No=Update installed only - YES=Download ALL")" == "1" ]; then

            UPDATE_MODE="DOWNLOAD_ALL"
        else
            UPDATE_MODE="UPDATE_INSTALLED"
        fi

        # Resource selection (mode-aware prompts)
        local action_word="Update"
        [ "$UPDATE_MODE" == "DOWNLOAD_ALL" ] && action_word="Download"
        
        if [ "$(CONFIRMATION_DIALOG "$action_word ALL (Payloads, Themes, Ringtones)?")" == "1" ]; then
            selected_indices=(0 1 2)
        else
            for i in "${!RESOURCES[@]}"; do
                IFS='|' read -r r_name _ _ _ _ _ <<< "${RESOURCES[$i]}"
                if [ "$(CONFIRMATION_DIALOG "$action_word $r_name?")" == "1" ]; then
                    selected_indices+=("$i")
                fi
            done
        fi

        if [ ${#selected_indices[@]} -eq 0 ]; then
            LOG "Nothing selected."
            exit 0
        fi

        setup

        for i in "${selected_indices[@]}"; do
            IFS='|' read -r r_name r_repo r_branch r_cache r_target r_type <<< "${RESOURCES[$i]}"
            local full_cache="$CACHE_ROOT/$r_cache"
            
            if update_repo "$r_repo" "$r_branch" "$full_cache"; then
                if [ "$UPDATE_MODE" == "DOWNLOAD_ALL" ]; then
                    process_resource "$r_name" "$full_cache" "$r_target" "$r_type"
                else
                    process_installed_only "$r_name" "$full_cache" "$r_target" "$r_type"
                fi
            fi
        done

        if [ "$UPDATE_MODE" == "UPDATE_INSTALLED" ]; then
            LOG "\n$LOG_BUFFER"
            LOG "Done (Installed Only): $COUNT_UPDATED Updated, $COUNT_SKIPPED Skipped"
        else
            LOG "\n$LOG_BUFFER"
            LOG "Done (Download All): $COUNT_NEW Downloaded, $COUNT_UPDATED Updated, $COUNT_SKIPPED Skipped"
        fi

        # Apply deferred self-update if queued
        if [ -n "$SELF_UPDATE_SRC" ]; then
            LED SETUP
            if [ "$(CONFIRMATION_DIALOG "Apply self-update: $SELF_UPDATE_LABEL?")" == "1" ]; then
                LOG "Applying self-update..."
                rm -rf "$SELF_UPDATE_DST"
                cp -rf "$SELF_UPDATE_SRC" "$SELF_UPDATE_DST"
                LOG "Self-update complete. Restart payload to use new version."
            else
                LOG "Self-update skipped."
            fi
        fi
    }

    # === RUN ===
    start_ui
