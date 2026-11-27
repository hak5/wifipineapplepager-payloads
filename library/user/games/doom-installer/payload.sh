#!/bin/bash
# Title: DOOM Installer/Deathmatch
# Author: Hak5Darren Credit LMacken
# Description: Install DOOM and launch Deathmatch on Hak5 servers from PR 130 by @LMacken
# Version: 1.0

set -u

REPO="hak5/wifipineapplepager-payloads"
REMOTE_URL="https://github.com/${REPO}.git"
PR="130"
DEST_ROOT="/root/payloads"
PAYLOAD_DIR="/root/payloads/user/games/doom"

player="PagerGuy"
PAYLOAD_CONFIG="${_PAYLOAD_HOME}/payload.cfg"

if [ -f "$PAYLOAD_CONFIG" ]; then
    # shellcheck source=/dev/null
    source "$PAYLOAD_CONFIG"
fi

custom_ip="127.0.0.1"
custom_dns="doom.hak5.org"

SPINNER_ID=""
STAGE=""
GITDIR=""
SERVICES_STOPPED=0
WAD_FILE=""

save_player() {
    if ! printf 'player=%q\n' "$player" > "$PAYLOAD_CONFIG"; then
        LOG red "ERROR: Unable to save player name"
        PROMPT "Unable to save player name"
        return 1
    fi
}

stop_spinner() {
    if [ -n "$SPINNER_ID" ]; then
        STOP_SPINNER "$SPINNER_ID" 2>/dev/null
        SPINNER_ID=""
    fi
}

restore_services() {
    [ "$SERVICES_STOPPED" -eq 1 ] || return
    SERVICES_STOPPED=0

    /etc/init.d/php8-fpm start 2>/dev/null &
    /etc/init.d/nginx start 2>/dev/null &
    /etc/init.d/bluetoothd start 2>/dev/null &
    /etc/init.d/pineapplepager start 2>/dev/null &
    /etc/init.d/pineapd start 2>/dev/null &
}

cleanup() {
    stop_spinner
    restore_services
    [ -z "$GITDIR" ] || rm -rf "$GITDIR"
    [ -z "$STAGE" ] || rm -rf "$STAGE"
}

die() {
    LOG red "Doom install failed: $*"
    stop_spinner
    ERROR_DIALOG "Doom installation failed: $*"
    exit 1
}

stop_services() {
    SERVICES_STOPPED=1
    /etc/init.d/php8-fpm stop 2>/dev/null
    /etc/init.d/nginx stop 2>/dev/null
    /etc/init.d/bluetoothd stop 2>/dev/null
    /etc/init.d/pineapplepager stop 2>/dev/null
    /etc/init.d/pineapd stop 2>/dev/null
}

prepare_doom() {
    cd "$PAYLOAD_DIR" || {
        LOG red "ERROR: $PAYLOAD_DIR not found"
        exit 1
    }

    [ ! -f "./doomgeneric" ] && {
        LOG red "ERROR: doomgeneric not found"
        exit 1
    }
    chmod +x /root/payloads/user/games/doom/doomgeneric

    WAD_FILE=$(ls "$PAYLOAD_DIR"/*.wad 2>/dev/null | head -1)
    [ -z "$WAD_FILE" ] && {
        LOG red "ERROR: No .wad file found"
        exit 1
    }
}

show_doom_controls() {
    LOG "DOOM

D-pad=Move  Red=Fire  Power=Weapon
Green+Up=Use  Green+L/R=Strafe
Green+Pwr=Save  Red+Pwr=Load
Red+Green=Menu

Press any button to start..."
    WAIT_FOR_INPUT >/dev/null 2>&1
}

launch_single_player() {
    prepare_doom
    show_doom_controls

    SPINNER_ID=$(START_SPINNER "Loading DOOM...")
    stop_services
    stop_spinner
    sleep 0.5

    /root/payloads/user/games/doom/doomgeneric -iwad "$WAD_FILE" >/tmp/doom.log 2>&1

    restore_services
    LOG "DOOM exited. Press any button..."
    WAIT_FOR_INPUT >/dev/null 2>&1
}

launch_deathmatch_game() {
    server="$1"
    map="$2"

    prepare_doom
    show_doom_controls

    SPINNER_ID=$(START_SPINNER "Loading DOOM...")
    stop_services
    stop_spinner
    sleep 0.5

    /root/payloads/user/games/doom/doomgeneric \
        -iwad "$WAD_FILE" \
        -name "$player" \
        -warp 1 "$map" \
        -altdeath \
        -skill 3 \
        -nomonsters \
        -connect "$server" \
        >/tmp/doom.log 2>&1

    restore_services
    LOG "DOOM exited. Press any button..."
    WAIT_FOR_INPUT >/dev/null 2>&1
}

ensure_commit() {
    git -C "$GITDIR" cat-file -e "$1^{commit}" 2>/dev/null
}

install_doom() {
    DEPTH="50"

    SPINNER_ID=$(START_SPINNER "Checking Internet Access")
    if ! command -v ping >/dev/null 2>&1 || ! ping -c 1 example.com >/dev/null 2>&1; then
        stop_spinner
        LOG "Error: Internet access unavailable. Reconnect and try again"
        exit 1
    fi
    stop_spinner

    PROMPT "This installs an unreviewed DOOM binary from github.com/lmacken. Provided AS-IS without warranty; use at your own risk. Interim solution while Hak5 develops an official binary PR process. Audit source & build from: github.com/ hak5/ wifipineapplepager-payloads/ pull/ 130"

    resp=$(CONFIRMATION_DIALOG "Install Doom from PR 130?")
    dialog_status=$?

    case "$dialog_status" in
        "$DUCKYSCRIPT_REJECTED")
            LOG "User cancelled install"
            exit 0
            ;;
        "$DUCKYSCRIPT_ERROR")
            LOG red "Confirmation dialog error"
            exit 1
            ;;
    esac

    if [ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        LOG "User cancelled install"
        exit 0
    fi

    SPINNER_ID=$(START_SPINNER "Installing Doom")
    LOG "Installing Doom from ${REPO} PR ${PR}"

    for command in git mktemp dirname mkdir mv rm find; do
        command -v "$command" >/dev/null 2>&1 || die "$command not found"
    done

    STAGE=$(mktemp -d "/tmp/pr-${PR}-stage.XXXXXX" 2>/dev/null || mktemp -d -t "pr-${PR}-stage") \
        || die "Could not create staging directory"
    GITDIR=$(mktemp -d 2>/dev/null || mktemp -d -t prgit) \
        || die "Could not create git directory"

    mkdir -p "$DEST_ROOT" || die "Could not create $DEST_ROOT"

    git -C "$GITDIR" init -q || die "git init failed"
    git -C "$GITDIR" remote add origin "$REMOTE_URL" || die "git remote add failed"

    if ! git -C "$GITDIR" fetch -q --no-tags --depth="$DEPTH" origin "pull/${PR}/merge"; then
        die "Could not fetch PR ${PR}"
    fi

    MERGE_SHA=$(git -C "$GITDIR" rev-parse FETCH_HEAD 2>/dev/null || true)
    [ -n "$MERGE_SHA" ] || die "Could not resolve PR ${PR}"

    attempt=0
    while ! ensure_commit "${MERGE_SHA}^1" || ! ensure_commit "${MERGE_SHA}^2"; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 3 ] || die "Could not resolve PR merge parents"

        git -C "$GITDIR" fetch -q --no-tags --deepen=$((DEPTH * 5)) origin "pull/${PR}/merge" \
            || die "Could not deepen PR fetch"
        DEPTH=$((DEPTH * 5))
    done

    CHANGES_FILE="$GITDIR/changes.txt"
    git -C "$GITDIR" diff --name-status "${MERGE_SHA}^1" "$MERGE_SHA" > "$CHANGES_FILE" \
        || die "Could not list changed files"

    written=0
    TAB=$(printf '\t')

    while IFS="$TAB" read -r status path1 path2; do
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

        mkdir -p "$STAGE/$(dirname "$srcpath")" || die "Could not stage $srcpath"

        if git -C "$GITDIR" cat-file -e "${MERGE_SHA}:${srcpath}" 2>/dev/null; then
            git -C "$GITDIR" show "${MERGE_SHA}:${srcpath}" > "$STAGE/$srcpath" \
                || die "Could not export $srcpath"
            written=$((written + 1))
        fi
    done < "$CHANGES_FILE"

    [ "$written" -gt 0 ] || die "PR ${PR} contains no installable changes"

    STAGED_FILES="$GITDIR/staged-files.txt"
    find "$STAGE" -type f > "$STAGED_FILES" || die "Could not scan staged files"

    installed=0
    while IFS= read -r file; do
        relative_path="${file#$STAGE/}"

        case "$relative_path" in
            library/*)
                payload_path="${relative_path#library/}"
                destination="$DEST_ROOT/$payload_path"
                mkdir -p "$(dirname "$destination")" || die "Could not create payload directory"
                mv "$file" "$destination" || die "Could not install $payload_path"
                LOG "Installed: $destination"
                installed=$((installed + 1))
                ;;
            *)
                LOG "Skipped non-payload file: $relative_path"
                ;;
        esac
    done < "$STAGED_FILES"

    [ "$installed" -gt 0 ] || die "PR ${PR} contains no files under library/"

    stop_spinner
    rm -rf "$GITDIR" "$STAGE"
    GITDIR=""
    STAGE=""

    LOG green "Doom installation complete"
    PROMPT "DOOM Installed. Find DOOM from Payloads > Games"
}

deathmatch_menu() {
    while true; do
        name_entry="Name: $player"
        selection=$(LIST_PICKER \
            "Launch Deathmatch" \
            "$name_entry" \
            "doom.hak5.org Lobby1 E1M1" \
            "doom.hak5.org Lobby2 E1M7" \
            "doom.hak5.org Lobby3 E1M2" \
            "doom.hak5.org Lobby4 E1M8" \
            "Custom IP" \
            "Custom DNS" \
            "Back" \
            "$name_entry")

        case "$selection" in
            "$name_entry")
                new_player=$(TEXT_PICKER "Player Name?" "$player")
                picker_status=$?
                case "$picker_status" in
                    "$DUCKYSCRIPT_CANCELLED"|"$DUCKYSCRIPT_REJECTED"|"$DUCKYSCRIPT_ERROR")
                        continue
                        ;;
                esac
                if [ -n "$new_player" ]; then
                    player="$new_player"
                    save_player
                fi
                ;;
            "doom.hak5.org Lobby1 E1M1")
                launch_deathmatch_game "doom.hak5.org:2342" "1"
                ;;
            "doom.hak5.org Lobby2 E1M7")
                launch_deathmatch_game "doom.hak5.org:2343" "7"
                ;;
            "doom.hak5.org Lobby3 E1M2")
                launch_deathmatch_game "doom.hak5.org:2344" "2"
                ;;
            "doom.hak5.org Lobby4 E1M8")
                launch_deathmatch_game "doom.hak5.org:2345" "8"
                ;;
            "Custom IP")
                new_ip=$(IP_PICKER "IP Address?" "$custom_ip")
                picker_status=$?
                case "$picker_status" in
                    "$DUCKYSCRIPT_CANCELLED"|"$DUCKYSCRIPT_REJECTED"|"$DUCKYSCRIPT_ERROR")
                        continue
                        ;;
                esac
                if [ -n "$new_ip" ]; then
                    custom_ip="$new_ip"
                    launch_deathmatch_game "${custom_ip}:2342"
                fi
                ;;
            "Custom DNS")
                new_dns=$(TEXT_PICKER "Doom Server?" "$custom_dns")
                picker_status=$?
                case "$picker_status" in
                    "$DUCKYSCRIPT_CANCELLED"|"$DUCKYSCRIPT_REJECTED"|"$DUCKYSCRIPT_ERROR")
                        continue
                        ;;
                esac
                if [ -n "$new_dns" ]; then
                    custom_dns="$new_dns"
                    launch_deathmatch_game "${custom_dns}:2342"
                fi
                ;;
            "Back")
                return
                ;;
            *)
                LOG "[!] Unknown selection: $selection"
                ;;
        esac
    done
}

trap cleanup EXIT
trap 'exit 1' INT TERM

while true; do
    selection=$(LIST_PICKER \
        "Doom Portal" \
        "Install Doom" \
        "Single Player" \
        "Deathmatch" \
        "Exit" \
        "Install Doom")

    case "$selection" in
        "Install Doom")
            install_doom
            ;;
        "Single Player")
            launch_single_player
            ;;
        "Deathmatch")
            deathmatch_menu
            ;;
        "Exit")
            exit 0
            ;;
        *)
            LOG "[!] Unknown selection: $selection"
            ;;
    esac
done
