    #!/bin/bash
    # Title: Update AIO
    # Description: Unified updater for Payloads, Themes, and Ringtones.
    # Author: Z3r0L1nk (based on cococode's work)
    # Version: 1.0.0

    # === CONFIGURATION ===
    CACHE_ROOT="/mmc/root/pager_update_cache"

    # Define resources: Name|Repo|Branch|CacheDirName|TargetDir|Type
    # Type: PAYLOAD_DIRS, THEME_DIRS, FLAT_FILES
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
                # Ringtones are usually flat in a folder or root. 
                # Adjust based on known repo structure: wifipineapplepager-ringtones has ringtones/ dir?
                # Based on previous analysis: yes, inside zip it was 'ringtones' folder.
                # Let's check cache dir content dynamically or assume 'ringtones' subdir if exists, else root.
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

            # Logic: New vs Update
            if [ ! -e "$target_path" ]; then
                # SPECIAL CASE: New Payload in alerts/ dir -> disable by default?
                if [ "$type" == "PAYLOAD_DIRS" ] && [[ "$item_rel_path" =~ ^alerts/ ]]; then
                    target_path="$(dirname "$target_path")/DISABLED.$(basename "$target_path")"
                fi

                mkdir -p "$(dirname "$target_path")"
                cp -rf "$src_item" "$target_path"
                LOG_BUFFER+="[ NEW ] $name: $item_title\n"
                COUNT_NEW=$((COUNT_NEW + 1))
            else
                # Diff Check
                if diff -r -q "$src_item" "$target_path" > /dev/null; then
                    continue # No changes
                fi
                
                # Conflict
                handle_conflict "$src_item" "$target_path" "$name: $item_title"
            fi

        done < "$file_list"
        rm -f "$file_list"
    }

    handle_conflict() {
        local src="$1"
        local dst="$2"
        local label="$3"
        local do_overwrite=false

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

    start_ui() {
        local selected_indices=()
        
        LED SETUP
        if [ "$(CONFIRMATION_DIALOG "Update EVERYTHING (Payloads, Themes, Ringtones)?")" == "1" ]; then
            selected_indices=(0 1 2)
        else
            # Ask individually
            for i in "${!RESOURCES[@]}"; do
                IFS='|' read -r r_name _ _ _ _ _ <<< "${RESOURCES[$i]}"
                if [ "$(CONFIRMATION_DIALOG "Update $r_name?")" == "1" ]; then
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
                process_resource "$r_name" "$full_cache" "$r_target" "$r_type"
            fi
        done

        LOG "\n$LOG_BUFFER"
        LOG "Done: $COUNT_NEW New, $COUNT_UPDATED Updated, $COUNT_SKIPPED Skipped"
    }

    # === RUN ===
    start_ui
