#!/bin/bash
# Title: ThemeNab Theme Sideloader
# Author: Hak5Darren
# Description: Side-load Pager themes from pending pull requests or ZIP URLs
# Version: 1.0

REPO="hak5/wifipineapplepager-themes"
API_ROOT="${THEMENAB_API_ROOT:-https://api.github.com/repos/${REPO}}"
DEST_ROOT="${THEMENAB_DEST_ROOT:-/root/themes}"
TEMP_BASE="${THEMENAB_TEMP_BASE:-/mmc}"
payload_home="${_PAYLOAD_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}"
payload_home="${payload_home%/}"
LOG_FILE="${THEMENAB_LOG_FILE:-${payload_home}/themenab.log}"

TEMP_ROOT=""
STAGE=""
LOG_READY=0
JSON_BACKEND=""

write_log() {
    local level="$1"
    shift

    [ "$LOG_READY" -eq 1 ] || return 0
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$level" "$*" >> "$LOG_FILE" 2>/dev/null
}

log_info() {
    write_log INFO "$*"
    LOG "$*"
}

log_success() {
    write_log SUCCESS "$*"
    LOG green "$*"
}

log_error() {
    write_log ERROR "$*"
    LOG red "$*"
}

debug_log() {
    write_log DEBUG "$*"
}

prompt_error() {
    log_error "$*"
    PROMPT "$*"
}

init_logging() {
    local log_directory

    log_directory=$(dirname "$LOG_FILE")
    if mkdir -p "$log_directory" 2>/dev/null && touch "$LOG_FILE" 2>/dev/null; then
        LOG_READY=1
        printf '\n============================================================\n' >> "$LOG_FILE"
        write_log INFO "ThemeNab v1.0 started; pid=$$"
        write_log DEBUG "Repository=${REPO}"
        write_log DEBUG "API root=${API_ROOT}"
        write_log DEBUG "Destination root=${DEST_ROOT}"
        write_log DEBUG "Temporary base=${TEMP_BASE}"
        write_log DEBUG "Payload home=${payload_home}"
        write_log DEBUG "Shell=${BASH_VERSION:-unknown}"
    else
        LOG red "ThemeNab could not open ${LOG_FILE}"
        PROMPT "ERROR: ThemeNab could not open its diagnostic log"
        return 1
    fi
}

log_system_state() {
    [ "$LOG_READY" -eq 1 ] || return 0

    write_log DEBUG "System state snapshot follows"
    {
        printf '%s\n' "--- uptime ---"
        uptime 2>&1 || true
        printf '%s\n' "--- memory ---"
        free 2>&1 || true
        printf '%s\n' "--- storage ---"
        df -h "$TEMP_BASE" "$DEST_ROOT" 2>&1 || true
        printf '%s\n' "--- processes ---"
        ps 2>&1 || true
    } >> "$LOG_FILE" 2>&1
}

cleanup() {
    local exit_status="$1"

    debug_log "Cleanup started; exit_status=${exit_status}"

    if [ -n "$STAGE" ]; then
        debug_log "Removing staging directory ${STAGE}"
        rm -rf "$STAGE" >> "$LOG_FILE" 2>&1
    fi
    if [ -n "$TEMP_ROOT" ]; then
        debug_log "Removing temporary root ${TEMP_ROOT}"
        rm -rf "$TEMP_ROOT" >> "$LOG_FILE" 2>&1
    fi

    write_log INFO "ThemeNab finished; exit_status=${exit_status}"
}

handle_signal() {
    local signal_name="$1"

    log_error "Received ${signal_name}; stopping ThemeNab"
    log_system_state
    exit 1
}

reset_temp_root() {
    if [ -n "$TEMP_ROOT" ]; then
        debug_log "Resetting temporary root ${TEMP_ROOT}"
        rm -rf "$TEMP_ROOT" >> "$LOG_FILE" 2>&1
    fi

    if [ ! -d "$TEMP_BASE" ] || [ ! -w "$TEMP_BASE" ]; then
        prompt_error "ERROR: ${TEMP_BASE} is not available for temporary storage"
        return 1
    fi

    TEMP_ROOT=$(mktemp -d "${TEMP_BASE}/themenab.XXXXXX" 2>> "$LOG_FILE") || {
        prompt_error "ERROR: Unable to create a temporary directory"
        return 1
    }

    debug_log "Temporary root created: ${TEMP_ROOT}"
}

verify_connection() {
    local ping_status

    log_info "Verifying Internet connection"

    if ! command -v ping >/dev/null 2>&1; then
        prompt_error "Internet access unavailable. Check the connection and try again"
        exit 1
    fi

    ping -c 1 example.com >> "$LOG_FILE" 2>&1
    ping_status=$?
    debug_log "Connection test exit status=${ping_status}"

    if [ "$ping_status" -ne 0 ]; then
        prompt_error "Internet access unavailable. Check the connection and try again"
        exit 1
    fi

    log_success "Internet connection verified"
}

download_to() {
    local url="$1"
    local output="$2"
    local download_status=1
    local safe_url="${url%%\?*}"

    log_info "Downloading theme ZIP"
    debug_log "Download URL (query omitted)=${safe_url}"
    debug_log "Download destination=${output}"

    if command -v curl >/dev/null 2>&1; then
        debug_log "Downloader=curl"
        curl -fsSL --connect-timeout 15 --max-time 300 -o "$output" "$url" 2>> "$LOG_FILE"
        download_status=$?
    elif command -v wget >/dev/null 2>&1; then
        debug_log "Downloader=wget"
        wget -q -O "$output" "$url" 2>> "$LOG_FILE"
        download_status=$?
    else
        prompt_error "ERROR: curl or wget is required"
        return 1
    fi

    debug_log "Download exit status=${download_status}"

    if [ "$download_status" -ne 0 ] || [ ! -s "$output" ]; then
        debug_log "Removing failed or empty download ${output}"
        rm -f "$output" >> "$LOG_FILE" 2>&1
        prompt_error "Download unsuccessful. Check the URL and try again"
        return 1
    fi

    debug_log "Downloaded bytes=$(wc -c < "$output" 2>/dev/null)"
    log_success "Theme ZIP downloaded"
}

get_url() {
    local entered_url picker_status

    entered_url=$(TEXT_PICKER "Theme ZIP URL?" "")
    picker_status=$?
    debug_log "Theme URL picker exit status=${picker_status}"
    [ "$picker_status" -eq 0 ] || return 1

    [ -n "$entered_url" ] || {
        prompt_error "A URL is required"
        return 1
    }

    case "$entered_url" in
        [Hh][Tt][Tt][Pp]://*|[Hh][Tt][Tt][Pp][Ss]://*)
            THEME_URL="$entered_url"
            ;;
        *://*)
            prompt_error "Only HTTP and HTTPS URLs are supported"
            return 1
            ;;
        *)
            THEME_URL="https://${entered_url}"
            ;;
    esac

    debug_log "Normalized theme URL (query omitted)=${THEME_URL%%\?*}"
}

confirm_overwrite() {
    local message="$1"
    local response dialog_status

    debug_log "Displaying overwrite confirmation: ${message}"
    response=$(CONFIRMATION_DIALOG "$message")
    dialog_status=$?
    debug_log "Overwrite confirmation exit status=${dialog_status}; response=${response:-empty}"

    if [ "$dialog_status" -ne 0 ] || [ "$response" != "${DUCKYSCRIPT_USER_CONFIRMED:-1}" ]; then
        log_info "ThemeNab installation cancelled"
        return 1
    fi

    debug_log "Overwrite confirmed"
}

validate_theme_name() {
    case "$1" in
        ""|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

install_from_url() {
    local downloaded_zip extract_root theme_list seen_names theme_json theme_dir
    local theme_name destination root_theme_name="" manifest_count picker_status
    local collision=0 installed=0 unzip_status root_theme=0
    local root_items=()

    log_info "Starting URL theme installation"
    PROMPT "Enter the URL to a hosted theme ZIP file. HTTPS:// will be automatically prepended. Short links (e.g. tinyurl) are supported. The ZIP must contain at least one theme.json file."

    for required_command in unzip find cp mv dirname grep wc; do
        if ! command -v "$required_command" >/dev/null 2>&1; then
            prompt_error "ERROR: ${required_command} is required"
            return
        fi
    done

    get_url || return
    reset_temp_root || return

    downloaded_zip="${TEMP_ROOT}/theme.zip"
    extract_root="${TEMP_ROOT}/extracted"
    theme_list="${TEMP_ROOT}/themes.txt"
    seen_names="${TEMP_ROOT}/theme-names.txt"

    download_to "$THEME_URL" "$downloaded_zip" || return
    mkdir -p "$extract_root" 2>> "$LOG_FILE" || {
        prompt_error "ERROR: Unable to create the extraction directory"
        return
    }

    log_info "Extracting theme ZIP on ${TEMP_BASE}"
    unzip -q "$downloaded_zip" -d "$extract_root" >> "$LOG_FILE" 2>&1
    unzip_status=$?
    debug_log "unzip exit status=${unzip_status}"
    if [ "$unzip_status" -ne 0 ]; then
        prompt_error "ERROR: Unable to extract theme ZIP"
        return
    fi

    find "$extract_root" -type f -name theme.json > "$theme_list" 2>> "$LOG_FILE"
    manifest_count=$(wc -l < "$theme_list" 2>/dev/null)
    debug_log "Theme manifests found=${manifest_count}"
    if [ ! -s "$theme_list" ]; then
        prompt_error "ERROR: Theme ZIP does not contain a theme.json file"
        return
    fi

    if [ -f "${extract_root}/theme.json" ]; then
        if [ "$manifest_count" -ne 1 ]; then
            prompt_error "ERROR: A root-level theme ZIP may only contain one theme"
            return
        fi

        root_theme=1
        root_theme_name=$(TEXT_PICKER "Payload name?" "")
        picker_status=$?
        debug_log "Root theme name picker exit status=${picker_status}; value=${root_theme_name:-empty}"
        [ "$picker_status" -eq 0 ] || return

        if ! validate_theme_name "$root_theme_name"; then
            prompt_error "ERROR: Invalid theme name. Use letters, numbers, periods, underscores, or hyphens"
            return
        fi

        debug_log "Root-level theme ZIP detected; selected name=${root_theme_name}"
    fi

    : > "$seen_names"
    while IFS= read -r theme_json; do
        theme_dir=$(dirname "$theme_json")
        if [ "$theme_dir" = "$extract_root" ]; then
            theme_name="$root_theme_name"
        else
            theme_name="${theme_dir##*/}"
        fi
        debug_log "Discovered theme manifest=${theme_json}; name=${theme_name}"

        if ! validate_theme_name "$theme_name"; then
            prompt_error "ERROR: Invalid theme directory name: ${theme_name}"
            return
        fi

        if grep -Fx "$theme_name" "$seen_names" >/dev/null 2>&1; then
            prompt_error "ERROR: Theme ZIP contains duplicate theme directory names"
            return
        fi
        printf '%s\n' "$theme_name" >> "$seen_names"

        destination="${DEST_ROOT}/${theme_name}"
        debug_log "Theme mapping: ${theme_dir} -> ${destination}"
        if [ -e "$destination" ] || [ -L "$destination" ]; then
            collision=1
            debug_log "Existing destination detected: ${destination}"
        fi
    done < "$theme_list"

    if [ "$collision" -eq 1 ]; then
        confirm_overwrite "One or more themes already exist. Overwrite them?" || return
    fi

    mkdir -p "$DEST_ROOT" 2>> "$LOG_FILE" || {
        prompt_error "ERROR: Unable to create ${DEST_ROOT}"
        return
    }

    log_info "Installing extracted themes"
    while IFS= read -r theme_json; do
        theme_dir=$(dirname "$theme_json")
        if [ "$theme_dir" = "$extract_root" ]; then
            theme_name="$root_theme_name"
        else
            theme_name="${theme_dir##*/}"
        fi
        destination="${DEST_ROOT}/${theme_name}"

        debug_log "Removing destination before URL install: ${destination}"
        rm -rf "$destination" >> "$LOG_FILE" 2>&1 || {
            prompt_error "ERROR: Unable to replace ${theme_name}"
            return
        }

        if [ "$root_theme" -eq 1 ]; then
            debug_log "Creating root-theme destination ${destination}"
            mkdir -p "$destination" 2>> "$LOG_FILE" || {
                prompt_error "ERROR: Unable to create ${destination}"
                return
            }

            shopt -s dotglob nullglob
            root_items=("$theme_dir"/*)
            shopt -u dotglob nullglob
            debug_log "Moving ${#root_items[@]} root-level items into ${destination}"
            if [ "${#root_items[@]}" -eq 0 ] || ! mv "${root_items[@]}" "$destination/" >> "$LOG_FILE" 2>&1; then
                rm -rf "$destination" >> "$LOG_FILE" 2>&1
                prompt_error "ERROR: Unable to install ${theme_name}"
                return
            fi
        else
            debug_log "Copying ${theme_dir} to ${destination}"
            if ! cp -R "$theme_dir" "$destination" >> "$LOG_FILE" 2>&1; then
                rm -rf "$destination" >> "$LOG_FILE" 2>&1
                prompt_error "ERROR: Unable to install ${theme_name}"
                return
            fi
        fi

        debug_log "Installed file count for ${theme_name}=$(find "$destination" -type f 2>/dev/null | wc -l)"
        log_info "Installed theme: ${theme_name}"
        installed=$((installed + 1))
    done < "$theme_list"

    log_success "Installed ${installed} theme(s) from URL"
    RINGTONE yeah
    PROMPT "Theme installation complete. Installed ${installed} theme(s)."
}

select_json_backend() {
    if command -v jsonfilter >/dev/null 2>&1; then
        JSON_BACKEND="jsonfilter"
    elif command -v jq >/dev/null 2>&1; then
        JSON_BACKEND="jq"
    else
        prompt_error "ERROR: ThemeNab requires jsonfilter or jq to read GitHub API responses"
        return 1
    fi

    debug_log "JSON backend=${JSON_BACKEND}"
}

fetch_api_page() {
    local url="$1"
    local output="$2"
    local request_status=1

    debug_log "GitHub API request=${url}"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL \
            --connect-timeout 15 \
            --max-time 120 \
            -H "Accept: application/vnd.github+json" \
            -H "User-Agent: ThemeNab/1.0" \
            -o "$output" \
            "$url" 2>> "$LOG_FILE"
        request_status=$?
    elif command -v wget >/dev/null 2>&1; then
        wget -q \
            --header="Accept: application/vnd.github+json" \
            --header="User-Agent: ThemeNab/1.0" \
            -O "$output" \
            "$url" 2>> "$LOG_FILE"
        request_status=$?
    fi

    debug_log "GitHub API request exit status=${request_status}"
    [ "$request_status" -eq 0 ] && [ -s "$output" ]
}

parse_api_page() {
    local page_file="$1"
    local records_file="$2"
    local json_indexes index_exports field_exports parse_status index
    local status filename raw_url

    : > "$records_file"
    PARSED_RECORD_COUNT=0

    case "$JSON_BACKEND" in
        jsonfilter)
            json_indexes=""
            index_exports=$(jsonfilter -q -i "$page_file" -e 'JSON_INDEXES=@' 2>> "$LOG_FILE")
            parse_status=$?
            debug_log "jsonfilter index parse exit status=${parse_status}"
            if [ "$parse_status" -ne 0 ]; then
                return 1
            fi

            unset JSON_INDEXES
            eval "$index_exports"
            json_indexes="${JSON_INDEXES:-}"
            debug_log "jsonfilter array indexes=${json_indexes:-none}"

            for index in $json_indexes; do
                case "$index" in
                    ""|*[!0-9]*)
                        debug_log "Invalid jsonfilter array index=${index}"
                        return 1
                        ;;
                esac

                unset STATUS FILENAME RAW_URL
                field_exports=$(jsonfilter -q -i "$page_file" \
                    -e "STATUS=@[${index}].status" \
                    -e "FILENAME=@[${index}].filename" \
                    -e "RAW_URL=@[${index}].raw_url" 2>> "$LOG_FILE")
                parse_status=$?
                if [ "$parse_status" -ne 0 ]; then
                    debug_log "jsonfilter field parse failed; index=${index}; exit status=${parse_status}"
                    return 1
                fi
                eval "$field_exports"

                status="${STATUS:-}"
                filename="${FILENAME:-}"
                raw_url="${RAW_URL:-}"
                if [ -z "$status" ] || [ -z "$filename" ]; then
                    debug_log "Missing required API fields at index=${index}"
                    return 1
                fi

                case "$status" in
                    added|modified|removed|renamed|copied|changed|unchanged) ;;
                    *)
                        debug_log "Unexpected PR file status=${status}; index=${index}"
                        return 1
                        ;;
                esac

                case "$filename" in
                    *"$(printf '\t')"*|*"
"*)
                        debug_log "Rejected control character in PR filename; index=${index}"
                        return 1
                        ;;
                esac

                printf '%s\t%s\t%s\n' "$status" "$filename" "$raw_url" >> "$records_file"
                PARSED_RECORD_COUNT=$((PARSED_RECORD_COUNT + 1))
            done
            ;;
        jq)
            if ! jq -e 'type == "array"' "$page_file" >/dev/null 2>> "$LOG_FILE"; then
                return 1
            fi
            if ! jq -r \
                '.[] | [.status, .filename, (.raw_url // "")] | @tsv' \
                "$page_file" > "$records_file" 2>> "$LOG_FILE"; then
                return 1
            fi
            PARSED_RECORD_COUNT=$(wc -l < "$records_file" 2>/dev/null)
            ;;
        *)
            return 1
            ;;
    esac

    debug_log "Parsed API records=${PARSED_RECORD_COUNT}"
}

validate_repo_theme_path() {
    local repository_path="$1"
    local relative_path theme_name

    case "$repository_path" in
        themes/*/*) ;;
        *) return 1 ;;
    esac

    relative_path="${repository_path#themes/}"
    theme_name="${relative_path%%/*}"
    validate_theme_name "$theme_name" || return 1

    case "$relative_path" in
        /*|../*|*/../*|*/..|./*|*/./*|*/.) return 1 ;;
    esac

    return 0
}

download_changed_file() {
    local url="$1"
    local output="$2"
    local download_status=1

    case "$url" in
        https://github.com/hak5/wifipineapplepager-themes/raw/*|https://raw.githubusercontent.com/hak5/wifipineapplepager-themes/*)
            ;;
        *)
            debug_log "Rejected unexpected raw URL=${url%%\?*}"
            return 1
            ;;
    esac

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL \
            --retry 2 \
            --connect-timeout 15 \
            --max-time 120 \
            -o "$output" \
            "$url" 2>> "$LOG_FILE"
        download_status=$?
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$output" "$url" 2>> "$LOG_FILE"
        download_status=$?
    fi

    return "$download_status"
}

install_from_pr() {
    local pr picker_status page=1 per_page=30 api_url api_page page_records
    local all_records install_records status filename raw_url tab
    local theme_path theme_name theme_root destination staged_file required_command
    local response dialog_status file_count=0 relevant_count=0 removed_count=0
    local installed=0 downloaded=0 collision=0 download_status api_bytes

    PROMPT "This payload is intended for developers. Installing themes from a github PR may take 10-20 minutes, depending on connection and asset sizes. Using 'scp' or ZIP URL is faster. You have been warned."

    pr=$(NUMBER_PICKER "Pull Request Number?" "1")
    picker_status=$?
    debug_log "PR number picker exit status=${picker_status}; value=${pr:-empty}"
    [ "$picker_status" -eq 0 ] || return

    case "$pr" in
        ""|*[!0-9]*)
            prompt_error "ERROR: A valid pull request number is required"
            return
            ;;
    esac

    log_info "Preparing changed-file download for PR #${pr}"
    for required_command in mktemp dirname mkdir mv rm find wc grep; do
        if ! command -v "$required_command" >/dev/null 2>&1; then
            prompt_error "ERROR: ${required_command} not found"
            return
        fi
        debug_log "Dependency available: ${required_command}=$(command -v "$required_command")"
    done
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        prompt_error "ERROR: curl or wget is required"
        return
    fi
    select_json_backend || return

    log_system_state
    reset_temp_root || return
    STAGE="${TEMP_ROOT}/pr-${pr}-stage"
    all_records="${TEMP_ROOT}/pr-${pr}-all-files.tsv"
    install_records="${TEMP_ROOT}/pr-${pr}-theme-files.tsv"
    : > "$all_records"
    : > "$install_records"
    mkdir -p "$STAGE" "$DEST_ROOT" 2>> "$LOG_FILE" || {
        prompt_error "ERROR: Unable to create PR staging directories"
        return
    }
    debug_log "PR stage=${STAGE}"

    log_info "Requesting PR #${pr} changed-file list"
    while :; do
        api_page="${TEMP_ROOT}/api-page-${page}.json"
        page_records="${TEMP_ROOT}/api-page-${page}.tsv"
        api_url="${API_ROOT}/pulls/${pr}/files?per_page=${per_page}&page=${page}"

        if ! fetch_api_page "$api_url" "$api_page"; then
            prompt_error "ERROR: Could not retrieve changed files for PR #${pr}"
            return
        fi

        api_bytes=$(wc -c < "$api_page" 2>/dev/null)
        debug_log "API page=${page}; bytes=${api_bytes}"
        if ! parse_api_page "$api_page" "$page_records"; then
            prompt_error "ERROR: Could not parse GitHub response for PR #${pr}"
            return
        fi

        cat "$page_records" >> "$all_records"
        file_count=$((file_count + PARSED_RECORD_COUNT))
        debug_log "API cumulative changed files=${file_count}"
        rm -f "$api_page" "$page_records" >> "$LOG_FILE" 2>&1

        [ "$PARSED_RECORD_COUNT" -lt "$per_page" ] && break
        page=$((page + 1))
    done

    if [ "$file_count" -eq 0 ]; then
        prompt_error "ERROR: Pull request ${pr} contains no changed files"
        return
    fi

    log_info "Validating ${file_count} changed PR files"
    tab=$(printf '\t')
    while IFS="$tab" read -r status filename raw_url; do
        [ -n "$filename" ] || continue
        debug_log "PR file: status=${status}; path=${filename}"

        case "$status" in
            removed)
                if validate_repo_theme_path "$filename"; then
                    removed_count=$((removed_count + 1))
                    debug_log "Skipping removed theme file=${filename}"
                else
                    debug_log "Skipping removed non-theme file=${filename}"
                fi
                continue
                ;;
        esac

        case "$filename" in
            themes/*/*)
                if ! validate_repo_theme_path "$filename"; then
                    prompt_error "ERROR: Invalid theme path in PR: ${filename}"
                    return
                fi
                ;;
            *)
                debug_log "Skipping changed non-theme file=${filename}"
                continue
                ;;
        esac

        [ -n "$raw_url" ] || {
            prompt_error "ERROR: GitHub did not provide a download URL for ${filename}"
            return
        }

        theme_path="${filename#themes/}"
        theme_name="${theme_path%%/*}"
        theme_root="${DEST_ROOT}/${theme_name}"
        if [ -L "$theme_root" ]; then
            prompt_error "ERROR: Theme destination may not be a symbolic link: ${theme_name}"
            return
        fi

        destination="${DEST_ROOT}/${theme_path}"
        debug_log "PR mapping: ${filename} -> ${destination}"
        if [ -e "$destination" ] || [ -L "$destination" ]; then
            collision=1
            debug_log "Existing destination file detected: ${destination}"
        fi

        printf '%s\t%s\t%s\n' "$filename" "$raw_url" "$destination" >> "$install_records"
        relevant_count=$((relevant_count + 1))
    done < "$all_records"

    debug_log "Relevant changed theme files=${relevant_count}; removed theme files skipped=${removed_count}"
    if [ "$relevant_count" -eq 0 ]; then
        prompt_error "ERROR: Pull request ${pr} contains no downloadable files under themes/"
        return
    fi

    if [ "$collision" -eq 1 ]; then
        response=$(CONFIRMATION_DIALOG "One or more destination files already exist. Overwrite them?")
        dialog_status=$?
        debug_log "PR overwrite confirmation exit status=${dialog_status}; response=${response:-empty}"
        if [ "$dialog_status" -ne 0 ] || [ "$response" != "${DUCKYSCRIPT_USER_CONFIRMED:-1}" ]; then
            log_info "ThemeNab PR installation cancelled"
            return
        fi
    fi

    log_info "Downloading ${relevant_count} changed theme files to ${TEMP_BASE}"
    while IFS="$tab" read -r filename raw_url destination; do
        staged_file="${STAGE}/${filename}"
        mkdir -p "$(dirname "$staged_file")" 2>> "$LOG_FILE" || {
            prompt_error "ERROR: Unable to stage ${filename}"
            return
        }

        debug_log "Downloading changed file=${filename}; raw URL=${raw_url%%\?*}"
        download_changed_file "$raw_url" "$staged_file"
        download_status=$?
        debug_log "Changed-file download exit status=${download_status}; path=${filename}"
        if [ "$download_status" -ne 0 ] || [ ! -f "$staged_file" ]; then
            prompt_error "ERROR: Unable to download ${filename}"
            return
        fi

        downloaded=$((downloaded + 1))
        if [ $((downloaded % 25)) -eq 0 ] || [ "$downloaded" -eq "$relevant_count" ]; then
            log_info "Downloaded ${downloaded} of ${relevant_count} changed files"
        fi
    done < "$install_records"

    debug_log "Staged changed-file bytes=$(du -sk "$STAGE" 2>/dev/null | awk '{print $1}') KiB"
    log_info "Installing ${relevant_count} changed files from PR #${pr}"
    installed=0
    while IFS="$tab" read -r filename raw_url destination; do
        staged_file="${STAGE}/${filename}"
        mkdir -p "$(dirname "$destination")" 2>> "$LOG_FILE" || {
            prompt_error "ERROR: Unable to create theme directory"
            return
        }
        mv "$staged_file" "$destination" 2>> "$LOG_FILE" || {
            prompt_error "ERROR: Unable to install ${filename}"
            return
        }
        installed=$((installed + 1))
        debug_log "Installed PR file: ${destination}"
    done < "$install_records"

    log_system_state
    rm -rf "$STAGE" >> "$LOG_FILE" 2>&1
    STAGE=""
    log_success "Pull request ${pr} theme installation complete; files=${installed}"
    RINGTONE yeah
    PROMPT "Theme installed successfully from PR #${pr}"
}

main() {
    local selection picker_status

    init_logging || exit 1
    trap 'cleanup $?' EXIT
    trap 'handle_signal SIGINT' INT
    trap 'handle_signal SIGTERM' TERM

    log_info "ThemeNab v1.0 ready"

    while true; do
        selection=$(LIST_PICKER \
            "ThemeNab Theme Sideloader" \
            "Side-Load from PR #" \
            "Side-Load from URL" \
            "About" \
            "Exit" \
            "Side-Load from PR #")
        picker_status=$?
        debug_log "Main menu exit status=${picker_status}; selection=${selection:-empty}"
        [ "$picker_status" -eq 0 ] || exit 0

        case "$selection" in
            "Side-Load from PR #")
                log_info "Selected PR installation"
                verify_connection
                install_from_pr
                ;;
            "Side-Load from URL")
                log_info "Selected URL installation"
                verify_connection
                install_from_url
                ;;
            "About")
                debug_log "Displaying About text"
                PROMPT "This payload is intended for developers to side-load themes from pending pull requests on the Hak5 WiFi Pineapple Pager themes repository, or from ZIP files by URL."
                ;;
            "Exit")
                log_info "User selected Exit"
                exit 0
                ;;
            *)
                log_error "Unknown selection: ${selection}"
                ;;
        esac
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main
fi
