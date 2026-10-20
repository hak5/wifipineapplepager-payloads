#!/bin/bash
# Title: O.MG Flasher
# Description: Flash official v3 stable or v4 alpha firmware with offline caching
# Author: Gas Station Hot Dog
# Based on the official O.MG WebFlasher:
# https://github.com/O-MG/WebFlasher
# Version: 1.0.11
# Category: General
# Requires: Internet for first download/setup, EMMC space, official O.MG Programmer, compatible device
# Firmware/configuration and payload slots are replaced as in WebFlasher.

# The Pager executes a generated script in /tmp, so its script location is
# not the installed payload directory. Prefer the Pager-provided home.
PAYLOAD_DIR="${_PAYLOAD_HOME:-${PAYLOAD_HOME:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}}"
export PAYLOAD_HOME="$PAYLOAD_DIR"
if [ ! -f "$PAYLOAD_DIR/setup.sh" ] || [ ! -f "$PAYLOAD_DIR/omg_flasher.py" ]; then
    ERROR_DIALOG "Payload files missing from $PAYLOAD_DIR. Reinstall the entire omg-flasher directory."
    exit 1
fi
export PATH="/mmc/usr/bin:/mmc/usr/sbin:$PATH"
export LD_LIBRARY_PATH="/mmc/usr/lib:${LD_LIBRARY_PATH:-}"
export PYTHONPATH="$PAYLOAD_DIR/lib${PYTHONPATH:+:$PYTHONPATH}"
RESET_MODE="web_reset" # Official WebFlasher timing; no_reset for manual flashing mode.
LOOT_DIR="${OMG_LOOT_DIR:-/mmc/root/loot/omg-flasher}"
CACHE_DIR="$PAYLOAD_DIR/cache"
mkdir -p "$LOOT_DIR" || exit 1
LOCK="$LOOT_DIR/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    ERROR_DIALOG "O.MG Flasher is already running. If a previous run crashed, remove $LOCK over SSH."
    exit 1
fi
RUN_DIR=$(mktemp -d "$LOOT_DIR/run-XXXXXXXX") || { rmdir "$LOCK"; exit 1; }
LOG_FILE="$RUN_DIR/flash.log"
SPINNER=""
WORKER=""
cleanup() {
    if [ -n "$WORKER" ]; then
        kill "$WORKER" 2>/dev/null
        wait "$WORKER" 2>/dev/null
        [ ! -f "$RUN_DIR/current.log" ] || cat "$RUN_DIR/current.log" >> "$LOG_FILE"
    fi
    [ -z "$SPINNER" ] || STOP_SPINNER "$SPINNER"
    if [ ! -f "$LOG_FILE" ]; then
        if [ -f "$RUN_DIR/current.log" ]; then
            cp "$RUN_DIR/current.log" "$LOG_FILE"
        else
            : > "$LOG_FILE"
        fi
    fi
    python3 "$PAYLOAD_DIR/omg_flasher.py" trim-runs --loot-dir "$LOOT_DIR" \
        --current-run "$RUN_DIR" || LOG yellow "Could not clean up run logs; check EMMC permissions."
    rmdir "$LOCK" 2>/dev/null
    LED OFF
}
trap cleanup EXIT
trap 'exit 130' INT TERM
confirm() {
    local response
    response=$(CONFIRMATION_DIALOG "$1") || return 1
    [ "$response" = "${DUCKYSCRIPT_USER_CONFIRMED:-1}" ]
}
start_logged() {
    "$@" >"$RUN_DIR/current.log" 2>&1 &
    WORKER=$!
    LOG_CURSOR=0
}
log_pending_output() {
    local count line
    count=$(wc -l < "$RUN_DIR/current.log")
    if [ "$count" -gt "$LOG_CURSOR" ]; then
        while IFS= read -r line; do LOG "$line"; done < <(sed -n "$((LOG_CURSOR + 1)),${count}p" "$RUN_DIR/current.log")
        LOG_CURSOR=$count
    fi
}
finish_logged() {
    local result
    while kill -0 "$WORKER" 2>/dev/null; do
        log_pending_output
        sleep 1
    done
    wait "$WORKER"
    result=$?
    WORKER=""
    log_pending_output
    cat "$RUN_DIR/current.log" >> "$LOG_FILE"
    return "$result"
}
run_logged() {
    # Avoid pipeline status masking: check the worker process itself.
    start_logged "$@"
    finish_logged
}

if [ ! -e "$CACHE_DIR" ] && [ -d "$LOOT_DIR/cache" ]; then
    if ! mv -- "$LOOT_DIR/cache" "$CACHE_DIR"; then
        ERROR_DIALOG "Cannot move firmware cache into $PAYLOAD_DIR. Check EMMC space and permissions."
        exit 1
    fi
fi

if ! python3 -c 'import esptool, serial, intelhex; assert esptool.__version__ == "4.8.1"' >/dev/null 2>&1 \
    || ! opkg list-installed | grep -q '^kmod-usb-serial-cp210x '; then
    if ! confirm "Install dependencies to EMMC? This can take several minutes and the Pager may lag. Internet is required."; then exit 0; fi
    LOG yellow "Dependency installation can take several minutes; the Pager may lag. Please wait."
    LOG "Live dependency log: $RUN_DIR/current.log"
    SPINNER=$(START_SPINNER "Installing dependencies - please wait")
    run_logged bash "$PAYLOAD_DIR/setup.sh"
    RESULT=$?
    STOP_SPINNER "$SPINNER"; SPINNER=""
    if [ "$RESULT" -ne 0 ]; then
        ERROR_DIALOG "Dependency installation failed. See $LOG_FILE"
        exit 1
    fi
fi

LOG cyan "O.MG Flasher"
LOG "Connect the official O.MG Programmer to the Pager USB host port."
LOG "Attach the O.MG device; PWR, USB and OMG lights must be ON."
PROMPT "Connect programmer and device, then continue."
PORT_TEXT=$(python3 "$PAYLOAD_DIR/omg_flasher.py" ports 2>"$RUN_DIR/ports.log")
if [ $? -ne 0 ]; then
    ERROR_DIALOG "Cannot enumerate programmers. See $RUN_DIR/ports.log"
    exit 1
fi
mapfile -t PORTS < <(printf '%s\n' "$PORT_TEXT" | sed '/^$/d')
if [ "${#PORTS[@]}" -eq 0 ]; then
    ERROR_DIALOG "No Silicon Labs USB programmer found. Check USB host cable and CP210x driver."
    exit 1
fi
INDEX=0
if [ "${#PORTS[@]}" -gt 1 ]; then
    LOG "Choose programmer: UP/DOWN, A select, B exit"
    LOG "${PORTS[$INDEX]}"
    while true; do
        BUTTON=$(WAIT_FOR_INPUT)
        case "$BUTTON" in
            UP) INDEX=$(((INDEX + ${#PORTS[@]} - 1) % ${#PORTS[@]})); LOG "${PORTS[$INDEX]}" ;;
            DOWN) INDEX=$(((INDEX + 1) % ${#PORTS[@]})); LOG "${PORTS[$INDEX]}" ;;
            A) break ;;
            B) exit 0 ;;
        esac
    done
fi
PORT="${PORTS[$INDEX]}"
FIRMWARE=$(LIST_PICKER "Choose firmware" "v3 stable" "v4 alpha (Elite only)" "Exit" "v3 stable") || exit 0
case "$FIRMWARE" in
    "v3 stable") CHANNEL=v3 ;;
    "v4 alpha (Elite only)") CHANNEL=v4 ;;
    *) exit 0 ;;
esac
EXTRA=()
CACHED_TAG=$(python3 "$PAYLOAD_DIR/omg_flasher.py" cache-info --channel "$CHANNEL" \
    --cache-dir "$CACHE_DIR" --flash-kb 2048 2>"$RUN_DIR/cache-info.log")
if [ $? -ne 0 ]; then
    ERROR_DIALOG "Cannot inspect firmware cache. See $RUN_DIR/cache-info.log"
    exit 1
fi
# The supported O.MG eFuse gate currently accepts only 2048 KB hardware.
if [ "$CACHED_TAG" = none ]; then
    CACHE_OPTION="Cache: None"
else
    CACHE_OPTION="Cache: $CACHED_TAG"
fi
SOURCE=$(LIST_PICKER "Firmware source" "Online: Latest" "$CACHE_OPTION" "Exit" "Online: Latest") || exit 0
case "$SOURCE" in
    "Online: Latest") ;;
    "$CACHE_OPTION") EXTRA+=(--offline) ;;
    *) exit 0 ;;
esac
if [ "$CHANNEL" = v4 ]; then
    if ! confirm "v4 is experimental and currently supports Elite Cable, Plug and Adapter only. Is this an Elite device?"; then exit 0; fi
    EXTRA+=(--elite-confirmed)
fi
LED cyan solid
start_logged python3 -u "$PAYLOAD_DIR/omg_flasher.py" session --channel "$CHANNEL" \
    --port "$PORT" --reset "$RESET_MODE" --directory "$RUN_DIR" --cache-dir "$CACHE_DIR" "${EXTRA[@]}"
CACHE_CHOICE_HANDLED=false
while [ ! -f "$RUN_DIR/ready" ]; do
    log_pending_output
    if [ -f "$RUN_DIR/cache-request.json" ] && [ "$CACHE_CHOICE_HANDLED" = false ]; then
        CACHE_CHOICE_HANDLED=true
        CHOICE=$(LIST_PICKER "No cached $CHANNEL firmware" "Download firmware" "Exit" "Exit")
        if [ "$CHOICE" = "Download firmware" ]; then
            LOG "Downloading $CHANNEL firmware. Internet is required."
            printf '{"action":"download"}\n' > "$RUN_DIR/cache-decision.tmp"
            mv "$RUN_DIR/cache-decision.tmp" "$RUN_DIR/cache-decision.json"
        else
            printf '{"action":"cancel"}\n' > "$RUN_DIR/cache-decision.tmp"
            mv "$RUN_DIR/cache-decision.tmp" "$RUN_DIR/cache-decision.json"
            finish_logged
            exit 0
        fi
    fi
    if ! kill -0 "$WORKER" 2>/dev/null; then
        finish_logged
        LED red blink
        ERROR_DIALOG "Preparation failed. No firmware written. See $LOG_FILE"
        exit 1
    fi
    sleep 1
done
log_pending_output
SUMMARY=$(python3 "$PAYLOAD_DIR/omg_flasher.py" summary --directory "$RUN_DIR") || exit 1
LOG green "$SUMMARY"
PRE_ERASE=false
if confirm "Pre-erase before flashing? Optional, matching WebFlasher's Erase Before Flash. Default: No."; then
    PRE_ERASE=true
fi
if ! confirm "Flash $SUMMARY on $PORT? Existing configuration and payload slots will be replaced. Keep USB connected until complete."; then
    printf '{"action":"cancel"}\n' > "$RUN_DIR/decision.tmp"
    mv "$RUN_DIR/decision.tmp" "$RUN_DIR/decision.json"
    finish_logged
    exit 0
fi
LED amber solid
printf '{"action":"flash","pre_erase":%s}\n' "$PRE_ERASE" > "$RUN_DIR/decision.tmp"
mv "$RUN_DIR/decision.tmp" "$RUN_DIR/decision.json"
finish_logged
if [ $? -ne 0 ]; then
    LED red blink
    ERROR_DIALOG "Flash failed. Reconnect programmer and rerun payload. See $LOG_FILE"
    exit 1
fi
LED green solid
PROMPT "Flash complete and verified. Unplug programmer; connect O.MG to a normal USB port."
