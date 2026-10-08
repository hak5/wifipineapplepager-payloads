#!/bin/bash
# Title: Glytch Mod Loader
# Author: Glytch
# Description: Browse and download individual Glytch mod payloads
# Version: 0.4.0
# Category: general
# Based on AirNab by Hak5Darren

REPO="https://github.com/glytchtech/GlytchModPayloads.git"
DEST_ROOT="${GLYTCH_DEST_ROOT:-/root/payloads}"

fail() {
    LOG red "$1"
    ERROR_DIALOG "$1"
    exit 0
}

check_connection() {
    curl -fsS --connect-timeout 5 --max-time 15 -o /dev/null https://github.com 2>/dev/null ||
        fail "Cannot reach repo. Check connection and try again"
}

command -v curl >/dev/null 2>&1 || fail "Curl is required"
command -v git >/dev/null 2>&1 || fail "Git is required"
command -v LIST_PICKER >/dev/null 2>&1 || fail "Pager firmware 1.0.8 or newer is required"
TEMP_ROOT=$(mktemp -d /tmp/glytch-mod-loader.XXXXXX) || fail "Cannot create temporary directory"
trap 'rm -rf "$TEMP_ROOT"' EXIT
trap 'exit 1' INT TERM

LOG "Checking connection"
check_connection

LOG "Loading available payloads"
git clone --depth 1 --filter=blob:none --no-checkout "$REPO" "$TEMP_ROOT/repo" || {
    check_connection
    fail "Cannot load the payload list. The repository may be unavailable; try again later."
}
git -C "$TEMP_ROOT/repo" ls-tree -r --name-only -z HEAD > "$TEMP_ROOT/files" || fail "Cannot list payloads"

# Only mod-type/payload-name/payload.sh entries belong in the menus.
FOLDERS=()
PAYLOADS=()
LAST_FOLDER=""
while IFS= read -r -d '' FILE; do
    case "$FILE" in */*/payload.sh) ;; *) continue ;; esac
    ENTRY="${FILE%/payload.sh}"
    FOLDER="${ENTRY%%/*}"
    NAME="${ENTRY#*/}"
    case "$FOLDER/$NAME" in .*|*/.*) continue ;; esac
    case "$NAME" in */*) continue ;; esac
    PAYLOADS+=("$ENTRY")
    if [ "$FOLDER" != "$LAST_FOLDER" ]; then
        FOLDERS+=("$FOLDER")
        LAST_FOLDER="$FOLDER"
    fi
done < "$TEMP_ROOT/files"
[ "${#PAYLOADS[@]}" -gt 0 ] || fail "No payloads found"

while true; do
    FOLDER=$(LIST_PICKER "Choose folder" "${FOLDERS[@]}" "[Exit]" "${FOLDERS[0]}") || exit 0
    [ "$FOLDER" != "[Exit]" ] || exit 0
    NAMES=()
    for ENTRY in "${PAYLOADS[@]}"; do
        [ "${ENTRY%%/*}" != "$FOLDER" ] || NAMES+=("${ENTRY#*/}")
    done
    [ "${#NAMES[@]}" -gt 0 ] || fail "Invalid folder selection"

    NAME=$(LIST_PICKER "$FOLDER" "${NAMES[@]}" "[Back]" "${NAMES[0]}") || continue
    [ "$NAME" != "[Back]" ] || continue
    SELECTED=""
    for ENTRY in "${PAYLOADS[@]}"; do
        [ "$ENTRY" != "$FOLDER/$NAME" ] || SELECTED="$ENTRY"
    done
    [ -n "$SELECTED" ] || fail "Invalid payload selection"

    LOG "Downloading $NAME"
    git -C "$TEMP_ROOT/repo" --literal-pathspecs checkout HEAD -- "$SELECTED" || {
        check_connection
        fail "Payload download failed. Please try again."
    }
    # Read metadata from the opening comment block; never execute the payload.
    CATEGORY="general"
    while IFS= read -r LINE || [ -n "$LINE" ]; do
        [[ "$LINE" =~ ^[[:space:]]*$ ]] && continue
        [[ "$LINE" =~ ^[[:space:]]*# ]] || break
        if [[ "$LINE" =~ ^[[:space:]]*#[[:space:]]*Category:(.*)$ ]]; then
            CATEGORY="${BASH_REMATCH[1]}"
            CATEGORY="${CATEGORY#"${CATEGORY%%[![:space:]]*}"}"
            CATEGORY="${CATEGORY%"${CATEGORY##*[![:space:]]}"}"
            break
        fi
    done < "$TEMP_ROOT/repo/$SELECTED/payload.sh"
    case "$CATEGORY" in
        ""|*[!A-Za-z0-9_-]*) fail "Invalid Category header in $NAME" ;;
    esac
    [ -d "$DEST_ROOT/user/$CATEGORY" ] && [ ! -L "$DEST_ROOT/user/$CATEGORY" ] ||
        fail "Unknown category: $CATEGORY. Check the payload header."

    DEST="$DEST_ROOT/user/$CATEGORY/$NAME"
    if [ -e "$DEST" ] || [ -L "$DEST" ]; then
        ANSWER=$(CONFIRMATION_DIALOG "Update $NAME?") || continue
        [ "$ANSWER" = "${DUCKYSCRIPT_USER_CONFIRMED:-1}" ] || continue
    fi

    mkdir -p "$DEST" || fail "Cannot create payload directory"
    cp -a "$TEMP_ROOT/repo/$SELECTED/." "$DEST/" || fail "Installation failed; some files may have been copied"
    chmod 755 "$DEST/payload.sh" || fail "Cannot set payload permissions"
    LOG green "Installed $NAME in $CATEGORY"
    exit 0
done
