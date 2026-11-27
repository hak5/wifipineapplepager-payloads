#!/bin/bash
# Title: AirNab Payload Sideloader
# Author: Hak5Darren
# Description: Side-load Pager payloads from pending pull requests or URLs
# Version: 1.0

REPO="hak5/wifipineapplepager-payloads"
REMOTE_URL="${AIRNAB_REMOTE_URL:-https://github.com/${REPO}.git}"
DEST_ROOT="${AIRNAB_DEST_ROOT:-/root/payloads}"
USER_ROOT="${DEST_ROOT}/user"

SPINNER_ID=""
TEMP_ROOT=""
GITDIR=""
STAGE=""
SELECTED_CATEGORY=""

stop_spinner() {
    if [ -n "$SPINNER_ID" ]; then
        STOP_SPINNER "$SPINNER_ID" 2>/dev/null
        SPINNER_ID=""
    fi
}

cleanup() {
    stop_spinner
    [ -z "$GITDIR" ] || rm -rf "$GITDIR"
    [ -z "$STAGE" ] || rm -rf "$STAGE"
    [ -z "$TEMP_ROOT" ] || rm -rf "$TEMP_ROOT"
}

reset_temp_root() {
    [ -z "$TEMP_ROOT" ] || rm -rf "$TEMP_ROOT"
    TEMP_ROOT=$(mktemp -d "/tmp/airnab.XXXXXX" 2>/dev/null || mktemp -d -t airnab) || {
        PROMPT "ERROR: Unable to create a temporary directory"
        return 1
    }
}

verify_connection() {
    SPINNER_ID=$(START_SPINNER "Verifying Connection")

    if ! command -v ping >/dev/null 2>&1 || ! ping -c 1 example.com >/dev/null 2>&1; then
        stop_spinner
        PROMPT "Internet access unavailable. Check the connection and try again"
        exit 1
    fi

    stop_spinner
}

download_to() {
    local url="$1"
    local output="$2"
    local label="$3"
    local download_status=1

    SPINNER_ID=$(START_SPINNER "Downloading ${label}")

    if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 15 --max-time 180 -o "$output" "$url" >/dev/null 2>&1
        download_status=$?
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$output" "$url" >/dev/null 2>&1
        download_status=$?
    else
        stop_spinner
        PROMPT "ERROR: curl or wget is required"
        return 1
    fi

    stop_spinner

    if [ "$download_status" -ne 0 ] || [ ! -s "$output" ]; then
        rm -f "$output"
        PROMPT "Download unsuccessful. Check the URL and try again"
        return 1
    fi

    return 0
}

get_url() {
    local entered_url
    local picker_status

    entered_url=$(TEXT_PICKER "Payload URL?" "")
    picker_status=$?
    [ "$picker_status" -eq 0 ] || return 1
    [ -n "$entered_url" ] || {
        PROMPT "A URL is required"
        return 1
    }

    case "$entered_url" in
        [Hh][Tt][Tt][Pp]://*|[Hh][Tt][Tt][Pp][Ss]://*)
            PAYLOAD_URL="$entered_url"
            ;;
        *://*)
            PROMPT "Only HTTP and HTTPS URLs are supported"
            return 1
            ;;
        *)
            PAYLOAD_URL="https://${entered_url}"
            ;;
    esac

    return 0
}

choose_category() {
    local categories=()
    local directory
    local category
    local selection
    local picker_status

    [ -d "$USER_ROOT" ] || {
        PROMPT "No payload categories are available"
        return 1
    }

    for directory in "$USER_ROOT"/*; do
        [ -d "$directory" ] || continue
        [ -L "$directory" ] && continue
        category="${directory##*/}"
        categories+=("$category")
    done

    [ "${#categories[@]}" -gt 0 ] || {
        PROMPT "No payload categories are available"
        return 1
    }

    selection=$(LIST_PICKER \
        "Choose a category" \
        "${categories[@]}" \
        "${categories[0]}")
    picker_status=$?
    [ "$picker_status" -eq 0 ] || return 1

    for category in "${categories[@]}"; do
        if [ "$selection" = "$category" ]; then
            SELECTED_CATEGORY="$category"
            return 0
        fi
    done

    PROMPT "Invalid category selection"
    return 1
}

get_directory_name() {
    local directory_name
    local picker_status

    directory_name=$(TEXT_PICKER "Directory name?" "")
    picker_status=$?
    [ "$picker_status" -eq 0 ] || return 1

    case "$directory_name" in
        ""|.|..|*[!A-Za-z0-9._-]*)
            PROMPT "Invalid directory name. Use letters, numbers, periods, underscores, or hyphens"
            return 1
            ;;
    esac

    PAYLOAD_DIRECTORY_NAME="$directory_name"
    return 0
}

confirm_destination() {
    local destination="$1"
    local response
    local dialog_status

    if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
        return 0
    fi

    response=$(CONFIRMATION_DIALOG "Destination already exists. Overwrite it?")
    dialog_status=$?

    if [ "$dialog_status" -ne 0 ] || [ "$response" != "${DUCKYSCRIPT_USER_CONFIRMED:-1}" ]; then
        LOG "AirNab installation cancelled"
        return 1
    fi

    rm -rf "$destination" || {
        PROMPT "ERROR: Unable to remove the existing destination"
        return 1
    }

    return 0
}

prepare_url_destination() {
    choose_category || return 1
    get_directory_name || return 1

    PAYLOAD_DESTINATION="${USER_ROOT}/${SELECTED_CATEGORY}/${PAYLOAD_DIRECTORY_NAME}"
    confirm_destination "$PAYLOAD_DESTINATION" || return 1

    mkdir -p "$PAYLOAD_DESTINATION" || {
        PROMPT "ERROR: Unable to create the payload directory"
        return 1
    }

    return 0
}

install_single_file() {
    local downloaded_file

    PROMPT "Enter the URL to the hosted payload.sh file. HTTPS:// will be automatically prepended. Short links (e.g. tinyurl) are supported. You will be prompted for category and directory name"

    get_url || return
    reset_temp_root || return
    downloaded_file="${TEMP_ROOT}/payload.sh"

    download_to "$PAYLOAD_URL" "$downloaded_file" "payload.sh" || return
    prepare_url_destination || return

    if ! mv "$downloaded_file" "${PAYLOAD_DESTINATION}/payload.sh"; then
        rm -rf "$PAYLOAD_DESTINATION"
        PROMPT "ERROR: Unable to install payload.sh"
        return
    fi

    chmod 755 "${PAYLOAD_DESTINATION}/payload.sh" 2>/dev/null
    LOG green "Installed: ${PAYLOAD_DESTINATION}/payload.sh"
    PROMPT "Payload installed successfully"
}

install_zip_file() {
    local downloaded_file
    local installed_zip

    PROMPT "Enter the URL to the hosted payload.zip file. HTTPS:// will be automatically prepended. Short links (e.g. tinyurl) are supported. You will be prompted for category and directory name"

    command -v unzip >/dev/null 2>&1 || {
        PROMPT "ERROR: unzip is required"
        return
    }

    get_url || return
    reset_temp_root || return
    downloaded_file="${TEMP_ROOT}/payload.zip"

    download_to "$PAYLOAD_URL" "$downloaded_file" "payload.zip" || return

    if ! unzip -p "$downloaded_file" payload.sh >/dev/null 2>&1; then
        PROMPT "ERROR: payload.zip does not contain a payload.sh file in its root"
        exit 1
    fi

    prepare_url_destination || return
    installed_zip="${PAYLOAD_DESTINATION}/payload.zip"

    if ! mv "$downloaded_file" "$installed_zip"; then
        rm -rf "$PAYLOAD_DESTINATION"
        PROMPT "ERROR: Unable to install payload.zip"
        return
    fi

    SPINNER_ID=$(START_SPINNER "Extracting payload.zip")
    if ! unzip -q "$installed_zip" -d "$PAYLOAD_DESTINATION" >/dev/null 2>&1; then
        stop_spinner
        rm -rf "$PAYLOAD_DESTINATION"
        PROMPT "ERROR: Unable to extract payload.zip"
        return
    fi
    stop_spinner

    rm -f "$installed_zip"
    chmod 755 "${PAYLOAD_DESTINATION}/payload.sh" 2>/dev/null
    LOG green "Installed: ${PAYLOAD_DESTINATION}"
    PROMPT "Payload installed successfully"
}

ensure_commit() {
    git -C "$GITDIR" cat-file -e "$1^{commit}" 2>/dev/null
}

install_from_pr() {
    local pr
    local picker_status
    local depth=50
    local merge_sha
    local attempt
    local changes_file
    local status
    local path1
    local path2
    local srcpath
    local written=0
    local installed=0
    local tab
    local staged_files
    local file
    local relative_path
    local payload_path
    local destination
    local collision=0
    local response
    local dialog_status

    pr=$(NUMBER_PICKER "Pull Request Number?" "1")
    picker_status=$?
    [ "$picker_status" -eq 0 ] || return

    case "$pr" in
        ""|*[!0-9]*)
            PROMPT "ERROR: A valid pull request number is required"
            return
            ;;
    esac

    for required_command in git mktemp dirname mkdir mv rm find; do
        command -v "$required_command" >/dev/null 2>&1 || {
            PROMPT "ERROR: ${required_command} not found"
            return
        }
    done

    reset_temp_root || return
    STAGE="${TEMP_ROOT}/pr-${pr}-stage"
    GITDIR="${TEMP_ROOT}/pr-${pr}-git"
    mkdir -p "$STAGE" "$GITDIR" "$DEST_ROOT" || {
        PROMPT "ERROR: Unable to create PR staging directories"
        return
    }

    SPINNER_ID=$(START_SPINNER "Downloading PR #${pr}")
    LOG "Installing files from ${REPO} PR ${pr}"

    git -C "$GITDIR" init -q || {
        stop_spinner
        PROMPT "ERROR: git init failed"
        return
    }
    git -C "$GITDIR" remote add origin "$REMOTE_URL" || {
        stop_spinner
        PROMPT "ERROR: git remote add failed"
        return
    }

    if ! git -C "$GITDIR" fetch -q --no-tags --depth="$depth" origin "pull/${pr}/merge"; then
        stop_spinner
        PROMPT "ERROR: Could not fetch pull/${pr}/merge"
        return
    fi

    merge_sha=$(git -C "$GITDIR" rev-parse FETCH_HEAD 2>/dev/null || true)
    if [ -z "$merge_sha" ]; then
        stop_spinner
        PROMPT "ERROR: Could not resolve pull request ${pr}"
        return
    fi

    attempt=0
    while ! ensure_commit "${merge_sha}^1" || ! ensure_commit "${merge_sha}^2"; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 3 ]; then
            stop_spinner
            PROMPT "ERROR: Could not resolve pull request merge parents"
            return
        fi

        if ! git -C "$GITDIR" fetch -q --no-tags --deepen=$((depth * 5)) origin "pull/${pr}/merge"; then
            stop_spinner
            PROMPT "ERROR: Could not deepen pull request fetch"
            return
        fi
        depth=$((depth * 5))
    done

    changes_file="${GITDIR}/changes.txt"
    if ! git -C "$GITDIR" diff --name-status "${merge_sha}^1" "$merge_sha" > "$changes_file"; then
        stop_spinner
        PROMPT "ERROR: Could not list pull request files"
        return
    fi

    tab=$(printf '\t')
    while IFS="$tab" read -r status path1 path2; do
        [ -n "${status:-}" ] || continue

        case "$status" in
            D*)
                continue
                ;;
            R*|C*)
                srcpath="${path2:-}"
                ;;
            *)
                srcpath="${path1:-}"
                ;;
        esac

        [ -n "$srcpath" ] || continue
        mkdir -p "$STAGE/$(dirname "$srcpath")" || {
            stop_spinner
            PROMPT "ERROR: Unable to stage ${srcpath}"
            return
        }

        if git -C "$GITDIR" cat-file -e "${merge_sha}:${srcpath}" 2>/dev/null; then
            if ! git -C "$GITDIR" show "${merge_sha}:${srcpath}" > "$STAGE/$srcpath"; then
                stop_spinner
                PROMPT "ERROR: Unable to export ${srcpath}"
                return
            fi
            written=$((written + 1))
        fi
    done < "$changes_file"

    if [ "$written" -eq 0 ]; then
        stop_spinner
        PROMPT "ERROR: Pull request ${pr} contains no installable changes"
        return
    fi

    staged_files="${GITDIR}/staged-files.txt"
    find "$STAGE" -type f > "$staged_files"

    while IFS= read -r file; do
        relative_path="${file#$STAGE/}"
        case "$relative_path" in
            library/*)
                payload_path="${relative_path#library/}"
                destination="${DEST_ROOT}/${payload_path}"
                if [ -e "$destination" ] || [ -L "$destination" ]; then
                    collision=1
                    break
                fi
                ;;
        esac
    done < "$staged_files"

    stop_spinner

    if [ "$collision" -eq 1 ]; then
        response=$(CONFIRMATION_DIALOG "One or more destination files already exist. Overwrite them?")
        dialog_status=$?
        if [ "$dialog_status" -ne 0 ] || [ "$response" != "${DUCKYSCRIPT_USER_CONFIRMED:-1}" ]; then
            LOG "AirNab PR installation cancelled"
            return
        fi
    fi

    SPINNER_ID=$(START_SPINNER "Installing PR #${pr}")

    while IFS= read -r file; do
        relative_path="${file#$STAGE/}"

        case "$relative_path" in
            library/*)
                payload_path="${relative_path#library/}"
                destination="${DEST_ROOT}/${payload_path}"
                mkdir -p "$(dirname "$destination")" || {
                    stop_spinner
                    PROMPT "ERROR: Unable to create payload directory"
                    return
                }
                mv "$file" "$destination" || {
                    stop_spinner
                    PROMPT "ERROR: Unable to install ${payload_path}"
                    return
                }
                LOG "Installed: ${destination}"
                installed=$((installed + 1))
                ;;
            *)
                LOG "Skipped non-payload file: ${relative_path}"
                ;;
        esac
    done < "$staged_files"

    stop_spinner

    if [ "$installed" -eq 0 ]; then
        PROMPT "ERROR: Pull request ${pr} contains no files under library/"
        return
    fi

    rm -rf "$GITDIR" "$STAGE"
    GITDIR=""
    STAGE=""
    LOG green "Pull request ${pr} installation complete"
    PROMPT "Payload installed successfully from PR #${pr}"
}

url_menu() {
    local selection

    while true; do
        selection=$(LIST_PICKER \
            "Side-Load from URL" \
            "payload.sh (single file)" \
            "payload.zip (multiple files)" \
            "Back" \
            "payload.sh (single file)") || return

        case "$selection" in
            "payload.sh (single file)")
                install_single_file
                return
                ;;
            "payload.zip (multiple files)")
                install_zip_file
                return
                ;;
            "Back")
                return
                ;;
            *)
                LOG "Unknown selection: ${selection}"
                ;;
        esac
    done
}

main() {
    local selection

    trap cleanup EXIT
    trap 'exit 1' INT TERM

    while true; do
        selection=$(LIST_PICKER \
            "AirNab Payload Sideloader" \
            "Side-Load from PR #" \
            "Side-Load from URL" \
            "About" \
            "Exit" \
            "Side-Load from PR #") || exit

        case "$selection" in
            "Side-Load from PR #")
                verify_connection
                install_from_pr
                ;;
            "Side-Load from URL")
                verify_connection
                url_menu
                ;;
            "About")
                PROMPT "This payload is intended for developers to side-load payloads from pending pull requests on the Hak5 WiFi Pineapple Pager payload repository, or by URL (single payload.sh file or zip containing multiple files), in the event that the payload in question is not available over-the-air from the Pager Portal"
                ;;
            "Exit")
                exit
                ;;
            *)
                LOG "Unknown selection: ${selection}"
                ;;
        esac
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main
fi
