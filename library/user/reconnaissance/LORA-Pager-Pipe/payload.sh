#!/bin/bash
# Title: LORA-Pager-Pipe
# Description: Receive-only LoRa observations, local session logs, and wardrive exports.
# Author: Valleytech Solutions
# Version: 0.1.0
# Category: reconnaissance
# Dependencies: Python 3; see docs/INSTALL.md for radio and export dependencies.
# Options: Region and optional upload settings are configured from this payload.
# Credentials are private local configuration; none are included in this payload.

set +x
set -u
umask 077

PAYLOAD_DIR="${_PAYLOAD_HOME:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
CLI="$PAYLOAD_DIR/lpp.py"
export PATH="/mmc/usr/bin:/mmc/bin:$PATH"
export LD_LIBRARY_PATH="/mmc/usr/lib:/mmc/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PYTHONDONTWRITEBYTECODE=1

CAPTURE_PID=''
UPLOAD_PID=''
UPLOAD_SPINNER=''
SESSION=''
WIFI_CSV_OWNED=0
WIFI_PCAP_OWNED=0
CLEANING_UP=0
PACKAGE_INDEX_READY=0

if ! command -v LOG >/dev/null 2>&1; then
    LOG() { printf '%s\n' "$*"; }
fi

confirm() {
    local answer
    answer=$(CONFIRMATION_DIALOG "$1") || return 1
    [[ "$answer" == "${DUCKYSCRIPT_USER_CONFIRMED:-1}" ]]
}

message() {
    if command -v PROMPT >/dev/null 2>&1; then
        PROMPT "$1" >/dev/null 2>&1 || true
    else
        LOG "$1"
    fi
}

cli() { python3 "$CLI" "$@"; }

capture_running() {
    [[ -n "$CAPTURE_PID" ]] && kill -0 "$CAPTURE_PID" 2>/dev/null
}

close_owned_wifi() {
    if [[ "$WIFI_CSV_OWNED" == 1 ]]; then
        WIGLE_STOP >/dev/null 2>&1 || LOG red 'Could not close this session Wi-Fi CSV.'
        WIFI_CSV_OWNED=0
    fi
    if [[ "$WIFI_PCAP_OWNED" == 1 ]]; then
        WIFI_PCAP_STOP >/dev/null 2>&1 || LOG red 'Could not close this session Wi-Fi PCAP.'
        WIFI_PCAP_OWNED=0
    fi
}

stop_capture() {
    local attempt rc=0 stopped=0
    if [[ -n "$CAPTURE_PID" ]]; then
        stopped=1
        if capture_running; then
            kill -TERM "$CAPTURE_PID" 2>/dev/null || true
            for ((attempt=0; attempt<100; attempt++)); do
                capture_running || break
                sleep 0.1
            done
            if capture_running; then
                LOG red 'Capture did not close in time. Session may be incomplete.'
                kill -KILL "$CAPTURE_PID" 2>/dev/null || true
            fi
        fi
        wait "$CAPTURE_PID" || rc=$?
        CAPTURE_PID=''
        [[ "$rc" == 0 || "$rc" == 143 ]] || LOG yellow "Capture exited with status $rc."
    fi
    close_owned_wifi
    if [[ "$stopped" == 1 && "$rc" == 0 && "$CLEANING_UP" == 0 && -n "$SESSION" ]]; then
        automatic_upload
    fi
}

stop_upload() {
    local attempt
    if [[ -n "$UPLOAD_PID" ]]; then
        kill -TERM "$UPLOAD_PID" 2>/dev/null || true
        for ((attempt=0; attempt<50; attempt++)); do
            kill -0 "$UPLOAD_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL "$UPLOAD_PID" 2>/dev/null || true
        wait "$UPLOAD_PID" 2>/dev/null || true
        UPLOAD_PID=''
    fi
    if [[ -n "$UPLOAD_SPINNER" ]]; then
        STOP_SPINNER "$UPLOAD_SPINNER" >/dev/null 2>&1 || true
        UPLOAD_SPINNER=''
    fi
}

automatic_upload() { run_upload --automatic; }

run_upload() {
    local attempt rc=0
    if command -v START_SPINNER >/dev/null 2>&1; then
        UPLOAD_SPINNER=$(START_SPINNER 'Checking enabled uploads...') || UPLOAD_SPINNER=''
    fi
    python3 "$CLI" upload --session "$SESSION" "$@" >"$SESSION/upload-status.log" 2>&1 &
    UPLOAD_PID=$!
    for ((attempt=0; attempt<1200; attempt++)); do
        kill -0 "$UPLOAD_PID" 2>/dev/null || break
        sleep 0.25
    done
    if kill -0 "$UPLOAD_PID" 2>/dev/null; then
        LOG yellow 'Upload time limit reached. Check saved receipts before retrying.'
        stop_upload
        return
    fi
    wait "$UPLOAD_PID" || rc=$?
    UPLOAD_PID=''
    stop_upload
    LOG "$(head -n 20 "$SESSION/upload-status.log")"
    [[ "$rc" == 0 ]] || LOG yellow 'Some uploads did not complete. Local logs and upload states were retained.'
}

cleanup() {
    [[ "$CLEANING_UP" == 0 ]] || return
    CLEANING_UP=1
    stop_upload
    stop_capture
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

package_installed() {
    opkg status "$1" 2>/dev/null | grep -q '^Status:.* installed$' ||
        opkg -d mmc status "$1" 2>/dev/null | grep -q '^Status:.* installed$'
}

install_runtime_package() {
    local package="$1" necessity="$2"
    case "$package" in
        python3|libusb-1.0-0|python3-pyserial|python3-cryptography) ;;
        *) return 1 ;;
    esac
    if ! command -v opkg >/dev/null 2>&1; then
        message 'The package manager is unavailable. See docs/INSTALL.md.'
        return 1
    fi
    if package_installed "$package"; then
        message "$package is installed but unavailable. Check MMC package paths and firmware compatibility; it will not be replaced."
        return 1
    fi
    if [[ "$necessity" == optional ]]; then
        confirm 'Optional decoding support is missing. Install python3-cryptography to MMC? Raw capture works without it. Internet access is needed.' || return 1
    else
        confirm "$package is required for the selected backend. Install it to MMC now? Internet access is needed." || return 1
    fi
    if [[ "$PACKAGE_INDEX_READY" == 0 ]]; then
        if ! opkg update >/dev/null 2>&1; then
            message 'Package feed refresh failed. Check Internet access and MMC space.'
            return 1
        fi
        PACKAGE_INDEX_READY=1
    fi
    if ! opkg install -d mmc "$package" >/dev/null 2>&1; then
        message "$package installation failed. Check Internet access, the configured feed, and MMC space."
        return 1
    fi
}

dependency_report() {
    local output line
    output=$(cli dependencies 2>/dev/null) || return 1
    [[ -n "$output" && ${#output} -le 160 ]] || return 1
    while IFS= read -r line; do
        case "$line" in
            'ready'|'required libusb-1.0-0'|'required python3-pyserial'|'optional python3-cryptography'|'reinstall pyusb') ;;
            *) return 1 ;;
        esac
    done <<< "$output"
    printf '%s\n' "$output"
}

ensure_dependencies() {
    local output line
    output=$(dependency_report) || {
        message 'Dependency checks could not run. Check the private configuration and reinstall the complete payload if needed.'
        return 1
    }
    if [[ "$output" == *'reinstall pyusb'* ]]; then
        message 'Bundled PyUSB source is missing. Reinstall the complete payload directory; no PyUSB package will be downloaded.'
        return 1
    fi
    while IFS= read -r line; do
        case "$line" in
            'required libusb-1.0-0') install_runtime_package libusb-1.0-0 required || return 1 ;;
            'required python3-pyserial') install_runtime_package python3-pyserial required || return 1 ;;
            'optional python3-cryptography') install_runtime_package python3-cryptography optional || true ;;
        esac
    done <<< "$output"
    output=$(dependency_report) || {
        message 'The dependency recheck failed. See docs/INSTALL.md.'
        return 1
    }
    if [[ "$output" == *'required '* || "$output" == *'reinstall '* ]]; then
        message 'A required runtime dependency remains unavailable. See docs/INSTALL.md; capture has not started.'
        return 1
    fi
    if [[ "$output" == *'optional '* ]]; then
        message 'Raw capture is available. Some payload decoding or signature verification remains unavailable; Capture checks report the details.'
    fi
}

ensure_runtime() {
    local command_name
    for command_name in LIST_PICKER CONFIRMATION_DIALOG TEXT_PICKER; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            LOG "Missing $command_name. Launch from the Pager Payloads menu."
            return 1
        fi
    done
    if ! command -v python3 >/dev/null 2>&1; then
        install_runtime_package python3 required || return 1
        if ! command -v python3 >/dev/null 2>&1; then
            message 'Python is still unavailable after installation. Check the MMC package paths.'
            return 1
        fi
    fi
    if [[ ! -f "$CLI" ]]; then
        message 'The payload is incomplete: lpp.py is missing. Install the complete payload directory.'
        return 1
    fi
    ensure_dependencies
}

report() {
    local output
    output=$(cli "$@" 2>&1)
    local rc=$?
    LOG "$output"
    # Keep the native dialog readable; complete reports remain in the console.
    message "$(printf '%s\n' "$output" | head -n 8)"
    return "$rc"
}

choose_region() {
    local selected region
    if capture_running; then
        message 'Stop capture before changing the LoRa region.'
        return
    fi
    selected=$(LIST_PICKER 'LoRa region / mode' 'US / Canada' 'Europe 868 MHz' 'Australia / New Zealand' 'LoRa mode' 'Back' 'Back') || return
    case "$selected" in
        'US / Canada') region=US ;;
        'Europe 868 MHz') region=EU_868 ;;
        'Australia / New Zealand') region=ANZ ;;
        'LoRa mode') choose_mode; return ;;
        *) return ;;
    esac
    if cli config set region "$region"; then
        message 'Region saved. Use hardware and an antenna suitable for the selected band.'
    else
        message 'Could not save this region. Check the payload console.'
    fi
}

choose_mode() {
    local selected mode
    selected=$(LIST_PICKER 'Receive protocol' 'Meshtastic' 'MeshCore' 'Both / slow scan' 'Back' 'Back') || return
    case "$selected" in
        'Meshtastic') mode=meshtastic ;;
        'MeshCore') mode=meshcore ;;
        'Both / slow scan') mode=both ;;
        *) return ;;
    esac
    if cli config set mode "$mode"; then
        message 'Receive mode saved. Both mode alternates profiles; it does not receive them simultaneously.'
    else
        message 'Could not save the receive mode.'
    fi
}

start_capture() {
    if capture_running; then
        message 'A capture is already running.'
        return
    fi
    if [[ -n "$CAPTURE_PID" ]]; then stop_capture; fi
    if ! cli doctor; then
        message 'The capture checks did not pass. See the console and installation guide.'
        return
    fi
    SESSION=$(cli session new) || { message 'Could not create a session.'; return; }
    if [[ "$SESSION" != /* || ! -d "$SESSION" ]]; then
        message 'The capture service returned an invalid session path.'
        SESSION=''
        return
    fi
    cli config set last_session "$SESSION" >/dev/null || true
    python3 "$CLI" capture --session "$SESSION" >>"$SESSION/worker.log" 2>&1 &
    CAPTURE_PID=$!
    sleep 0.3
    if ! capture_running; then
        stop_capture
        message 'Capture could not start. See worker.log in the new session directory.'
        return
    fi
    LOG green "Capture started: $SESSION"
    message 'LoRa capture started. Use Status to check reception and GPS. Capture continues while this menu is open.'
}

combined_capture() {
    message 'Use Recon to start native Wi-Fi recording, then start LoRa here. Existing Wi-Fi recordings stay under Recon control.'
    start_capture
}

capture_menu() {
    local selected
    selected=$(LIST_PICKER 'Capture' 'Start LoRa' 'LoRa + existing Wi-Fi' 'Stop LoRa' 'Back' 'Back') || return
    case "$selected" in
        'Start LoRa') start_capture ;;
        'LoRa + existing Wi-Fi') combined_capture ;;
        'Stop LoRa') stop_capture; message 'LoRa capture stopped. Local session files have been retained.' ;;
    esac
}

session_status() {
    if [[ -z "$SESSION" ]]; then SESSION=$(cli config get last_session 2>/dev/null) || SESSION=''; fi
    if [[ -n "$SESSION" && -d "$SESSION" ]]; then
        report status --session "$SESSION" || true
    else
        report doctor || true
    fi
}

observations_menu() {
    local selected
    if [[ -z "$SESSION" ]]; then SESSION=$(cli config get last_session 2>/dev/null) || SESSION=''; fi
    if [[ -z "$SESSION" || ! -d "$SESSION" ]]; then message 'No local session is available.'; return; fi
    selected=$(LIST_PICKER 'Local observations' 'Recent packets' 'Device summaries' 'Back' 'Back') || return
    case "$selected" in
        'Recent packets') report observations --session "$SESSION" || true ;;
        'Device summaries') report devices --session "$SESSION" || true ;;
    esac
}

set_secret() {
    local key=$1 title=$2 secret
    secret=$(TEXT_PICKER "$title" '') || return
    if [[ -z "$secret" ]]; then message 'No value entered. Existing setting retained.'; return; fi
    if printf '%s\n' "$secret" | cli config set "$key" --stdin >/dev/null; then
        message 'Credential saved in private local configuration.'
    else
        message 'Could not save the credential.'
    fi
    unset secret
}

service_settings() {
    local service=$1 display=$2 selected enabled
    selected=$(LIST_PICKER "$display settings" 'Credentials' 'Allow uploads' 'Automatic uploads' 'Back' 'Back') || return
    case "$selected" in
        'Credentials')
            message 'Native text entry is visible on screen. Credentials are not printed to the payload log.'
            if [[ "$service" == wigle ]]; then
                set_secret 'uploads.wigle.api_name' 'WiGLE API name'
                set_secret 'uploads.wigle.api_token' 'WiGLE API token'
            else
                set_secret "uploads.$service.api_key" "$display API key"
            fi
            ;;
        'Allow uploads')
            selected=$(LIST_PICKER "$display uploads" 'Enable' 'Disable' 'Back' 'Back') || return
            case "$selected" in
                'Enable')
                    confirm "Allow compatible captures and locations to be sent to $display when you request an upload?" || return
                    enabled=true ;;
                'Disable') enabled=false ;;
                *) return ;;
            esac
            cli config set "uploads.$service.enabled" "$enabled" || message 'Setting was not saved.'
            ;;
        'Automatic uploads')
            selected=$(LIST_PICKER 'Automatic uploads' 'Enable after capture' 'Disable' 'Back' 'Back') || return
            case "$selected" in
                'Enable after capture')
                    confirm "Automatically send completed compatible logs and their locations to $display?" || return
                    enabled=true
                    cli config set "uploads.$service.enabled" true || return ;;
                'Disable') enabled=false ;;
                *) return ;;
            esac
            cli config set "uploads.$service.auto" "$enabled" || message 'Setting was not saved.'
            ;;
    esac
}

upload_last_session() {
    local selected service native_path kind
    if capture_running; then message 'Stop capture before exporting or uploading this session.'; return; fi
    if [[ -z "$SESSION" ]]; then SESSION=$(cli config get last_session 2>/dev/null) || SESSION=''; fi
    if [[ -z "$SESSION" || ! -d "$SESSION" ]]; then message 'No local session is available.'; return; fi
    selected=$(LIST_PICKER 'Session export' 'Attach Wi-Fi CSV' 'Attach Wi-Fi PCAP' 'Export local files' 'Upload to WiGLE' 'Upload to Wardrift' 'Upload to WDGWars' 'Back' 'Back') || return
    case "$selected" in
        'Attach Wi-Fi CSV'|'Attach Wi-Fi PCAP')
            confirm 'Stop the native recording in Recon first. Is the selected recording now closed?' || return
            [[ "$selected" == 'Attach Wi-Fi CSV' ]] && kind=wifi_csv || kind=wifi_pcap
            native_path=$(TEXT_PICKER 'Absolute native capture file path' '/root/loot/') || return
            if report session attach --session "$SESSION" --kind "$kind" --path "$native_path"; then
                automatic_upload
            fi
            return ;;
        'Export local files') report export --session "$SESSION" || true; return ;;
        'Upload to WiGLE') service=wigle ;;
        'Upload to Wardrift') service=wardrift ;;
        'Upload to WDGWars') service=wdgwars ;;
        *) return ;;
    esac
    confirm "Send compatible session records and their locations to $service? Original logs will be retained." || return
    run_upload --service "$service"
}

upload_settings() {
    local selected
    selected=$(LIST_PICKER 'Uploads and exports' 'Export / upload session' 'WiGLE' 'Wardrift' 'WDGWars' 'Back' 'Back') || return
    case "$selected" in
        'Export / upload session') upload_last_session ;;
        'WiGLE') service_settings wigle WiGLE ;;
        'Wardrift') service_settings wardrift Wardrift ;;
        'WDGWars') service_settings wdgwars WDGWars ;;
    esac
}

main() {
    local selected
    ensure_runtime || return 1
    if command -v PROMPT_IMAGE >/dev/null 2>&1 && [[ -f "$PAYLOAD_DIR/assets/splash.png" ]]; then
        PROMPT_IMAGE "$PAYLOAD_DIR/assets/splash.png" >/dev/null 2>&1 || true
    fi
    while true; do
        selected=$(LIST_PICKER 'LORA-Pager-Pipe' 'Capture' 'Observations' 'Status' 'Region' 'Upload settings' 'About' 'Exit' 'Capture') || break
        case "$selected" in
            'Capture') capture_menu ;;
            'Observations') observations_menu ;;
            'Status') session_status ;;
            'Region') choose_region ;;
            'Upload settings') upload_settings ;;
            'About') message 'LORA-Pager-Pipe | Valleytech Solutions
Receive-only LoRa observations and wardrive logs.
Built from LoRaPipe concepts for the Glytch radio.
See README and third-party notices for attribution.' ;;
            'Exit')
                if capture_running; then confirm 'Stop this LoRa capture and exit?' || continue; fi
                break ;;
        esac
    done
    stop_capture
    return 0
}

main "$@"
