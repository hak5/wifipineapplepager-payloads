#!/bin/bash
# Title: AP Client Mode WiFi GUI
# Author: Hak5Darren
# Description: GUI to scan for and connect to nearby WiFi networks, save or reconnect saved networks. Front-end for WIFI_CONNECT.
# Version: 1.0

PAYLOAD_HOME="${_PAYLOAD_HOME:-$(cd "$(dirname "$0")" 2>/dev/null && pwd)}"
CONFIG_FILE="${PAYLOAD_HOME}/payload.cfg"
LOG_FILE="${PAYLOAD_HOME}/payload.log"
SCAN_FILE="${TMPDIR:-/tmp}/wifi-client-gui-scan.$$"
CONFIG_TMP="${CONFIG_FILE}.tmp.$$"
SPINNER_ID=""

SCAN_SSIDS=()
SCAN_BSSIDS=()
SCAN_CHANNELS=()
SCAN_SIGNALS=()
SCAN_ENCRYPTIONS=()
SCAN_NORMALIZED=()
SCAN_UNIQUE_COUNT=0

SAVED_SSIDS=()
SAVED_ENCRYPTIONS=()
SAVED_KEYS=()
SAVED_BSSIDS=()

log_message() {
    local message="$1"
    local timestamp

    LOG "$message"
    timestamp=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    [ -n "$timestamp" ] || timestamp="unknown-time"
    printf '%s %s\n' "$timestamp" "$message" >> "$LOG_FILE" 2>/dev/null || true
}

start_spinner() {
    stop_spinner
    SPINNER_ID=$(START_SPINNER "$1")
}

stop_spinner() {
    if [ -n "$SPINNER_ID" ]; then
        STOP_SPINNER "$SPINNER_ID" 2>/dev/null || true
        SPINNER_ID=""
    fi
}

cleanup() {
    stop_spinner
    rm -f "$SCAN_FILE" "$CONFIG_TMP"
}

dialog_was_confirmed() {
    local response="$1"
    local status="$2"

    [ "$status" -eq 0 ] && [ "$response" = "${DUCKYSCRIPT_USER_CONFIRMED:-1}" ]
}

shell_escape_value() {
    local value="$1"

    # A single quote inside a single-quoted shell word is encoded as: '\''
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

normalize_encryption() {
    local description

    description=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')

    case "$description" in
        *ENTERPRISE*|*802.1X*|*8021X*|*EAP*)
            printf '%s' "enterprise"
            ;;
        "NONE"|"OPEN"|"UNENCRYPTED"|*"NO ENCRYPTION"*)
            printf '%s' "open"
            ;;
        *WPA3*|*SAE*)
            printf '%s' "sae"
            ;;
        *WPA2*PSK*)
            printf '%s' "psk2"
            ;;
        *WPA1*PSK*|*WPA*PSK*)
            printf '%s' "psk"
            ;;
        *)
            printf '%s' "unsupported"
            ;;
    esac
}

add_scan_record() {
    local ssid="$1"
    local bssid="$2"
    local channel="$3"
    local signal="$4"
    local encryption="$5"
    local normalized existing i

    [ -n "$ssid" ] || return
    case "$ssid" in
        [Uu][Nn][Kk][Nn][Oo][Ww][Nn]) return ;;
    esac
    [[ "$signal" =~ ^-?[0-9]+$ ]] || return

    normalized=$(normalize_encryption "$encryption")
    [ "$normalized" != "enterprise" ] || return
    [ -n "$bssid" ] || bssid="unknown"
    [ -n "$channel" ] || channel="unknown"
    [ -n "$encryption" ] || encryption="unknown"

    existing=-1
    for ((i = 0; i < ${#SCAN_SSIDS[@]}; i++)); do
        if [ "${SCAN_SSIDS[$i]}" = "$ssid" ]; then
            existing=$i
            break
        fi
    done

    if [ "$existing" -ge 0 ]; then
        if [ "$signal" -gt "${SCAN_SIGNALS[$existing]}" ]; then
            SCAN_BSSIDS[$existing]="$bssid"
            SCAN_CHANNELS[$existing]="$channel"
            SCAN_SIGNALS[$existing]="$signal"
            SCAN_ENCRYPTIONS[$existing]="$encryption"
            SCAN_NORMALIZED[$existing]="$normalized"
        fi
        return
    fi

    SCAN_SSIDS+=("$ssid")
    SCAN_BSSIDS+=("$bssid")
    SCAN_CHANNELS+=("$channel")
    SCAN_SIGNALS+=("$signal")
    SCAN_ENCRYPTIONS+=("$encryption")
    SCAN_NORMALIZED+=("$normalized")
}

sort_and_limit_scan_results() {
    local i j tmp
    local count=${#SCAN_SSIDS[@]}

    # Selection sort keeps every field aligned and needs no delimiter-based files.
    for ((i = 0; i < count; i++)); do
        for ((j = i + 1; j < count; j++)); do
            if [ "${SCAN_SIGNALS[$j]}" -gt "${SCAN_SIGNALS[$i]}" ]; then
                tmp="${SCAN_SSIDS[$i]}"; SCAN_SSIDS[$i]="${SCAN_SSIDS[$j]}"; SCAN_SSIDS[$j]="$tmp"
                tmp="${SCAN_BSSIDS[$i]}"; SCAN_BSSIDS[$i]="${SCAN_BSSIDS[$j]}"; SCAN_BSSIDS[$j]="$tmp"
                tmp="${SCAN_CHANNELS[$i]}"; SCAN_CHANNELS[$i]="${SCAN_CHANNELS[$j]}"; SCAN_CHANNELS[$j]="$tmp"
                tmp="${SCAN_SIGNALS[$i]}"; SCAN_SIGNALS[$i]="${SCAN_SIGNALS[$j]}"; SCAN_SIGNALS[$j]="$tmp"
                tmp="${SCAN_ENCRYPTIONS[$i]}"; SCAN_ENCRYPTIONS[$i]="${SCAN_ENCRYPTIONS[$j]}"; SCAN_ENCRYPTIONS[$j]="$tmp"
                tmp="${SCAN_NORMALIZED[$i]}"; SCAN_NORMALIZED[$i]="${SCAN_NORMALIZED[$j]}"; SCAN_NORMALIZED[$j]="$tmp"
            fi
        done
    done

    if [ "$count" -gt 20 ]; then
        SCAN_SSIDS=("${SCAN_SSIDS[@]:0:20}")
        SCAN_BSSIDS=("${SCAN_BSSIDS[@]:0:20}")
        SCAN_CHANNELS=("${SCAN_CHANNELS[@]:0:20}")
        SCAN_SIGNALS=("${SCAN_SIGNALS[@]:0:20}")
        SCAN_ENCRYPTIONS=("${SCAN_ENCRYPTIONS[@]:0:20}")
        SCAN_NORMALIZED=("${SCAN_NORMALIZED[@]:0:20}")
    fi
}

parse_scan_results() {
    local line in_cell=0
    local ssid="" bssid="" channel="" signal="" encryption=""
    local raw new_bssid

    SCAN_SSIDS=()
    SCAN_BSSIDS=()
    SCAN_CHANNELS=()
    SCAN_SIGNALS=()
    SCAN_ENCRYPTIONS=()
    SCAN_NORMALIZED=()
    SCAN_UNIQUE_COUNT=0

    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}

        if [[ "$line" =~ ^[[:space:]]*Cell[[:space:]]+[0-9]+[[:space:]]*-[[:space:]]*Address:[[:space:]]*(.*)$ ]]; then
            new_bssid="${BASH_REMATCH[1]}"
            if [ "$in_cell" -eq 1 ]; then
                add_scan_record "$ssid" "$bssid" "$channel" "$signal" "$encryption"
            fi
            in_cell=1
            ssid=""
            bssid="$new_bssid"
            channel=""
            signal=""
            encryption=""
            continue
        fi

        [ "$in_cell" -eq 1 ] || continue

        if [[ "$line" =~ ^[[:space:]]*ESSID:[[:space:]]*(.*)$ ]]; then
            raw="${BASH_REMATCH[1]}"
            if [ "${#raw}" -ge 2 ] && [ "${raw:0:1}" = '"' ] && [ "${raw: -1}" = '"' ]; then
                raw="${raw:1:${#raw}-2}"
            fi
            ssid="$raw"
        elif [[ "$line" =~ ^[[:space:]]*Mode:.*[[:space:]]Channel:[[:space:]]*([0-9]+) ]]; then
            channel="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*Signal:[[:space:]]*(-?[0-9]+)[[:space:]]*dBm ]]; then
            signal="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*Encryption:[[:space:]]*(.*)$ ]]; then
            encryption="${BASH_REMATCH[1]}"
        fi
    done < "$SCAN_FILE"

    if [ "$in_cell" -eq 1 ]; then
        add_scan_record "$ssid" "$bssid" "$channel" "$signal" "$encryption"
    fi

    SCAN_UNIQUE_COUNT=${#SCAN_SSIDS[@]}
    sort_and_limit_scan_results
}

scan_networks() {
    log_message "WiFi scan started on wlan0cli"
    start_spinner "Scanning..."

    if ! iwinfo wlan0cli scan > "$SCAN_FILE" 2>> "$LOG_FILE"; then
        stop_spinner
        log_message "WiFi scan failed on wlan0cli"
        PROMPT "Unable to scan for networks"
        return 1
    fi

    if ! parse_scan_results; then
        stop_spinner
        log_message "Unexpected error while parsing WiFi scan results"
        PROMPT "Unable to scan for networks"
        return 1
    fi

    stop_spinner
    log_message "WiFi scan completed on wlan0cli"
    log_message "Usable unique networks found: ${SCAN_UNIQUE_COUNT}"
    return 0
}

get_client_ip() {
    local address

    address=$(ip -4 addr show dev wlan0cli 2>/dev/null | grep inet | awk '{print $2}')
    address=${address%%$'\n'*}
    [ -n "$address" ] || address="unknown"
    printf '%s' "$address"
}

client_is_associated() {
    iwinfo wlan0cli assoclist 2>> "$LOG_FILE" |
        grep -qE '[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}'
}

test_connectivity() {
    local response dialog_status

    response=$(CONFIRMATION_DIALOG "Test connection?")
    dialog_status=$?
    dialog_was_confirmed "$response" "$dialog_status" || return 0

    log_message "Connectivity test started for wlan0cli"
    if ping -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log_message "Connectivity test successful for wlan0cli"
        PROMPT "Connection test successful"
    else
        log_message "Connectivity test failed for wlan0cli"
        PROMPT "Connection test failed"
    fi
}

perform_wifi_connection() {
    local ssid="$1"
    local encryption="$2"
    local key="$3"
    local bssid="$4"
    local address

    log_message "Connection attempt: SSID=${ssid}; encryption=${encryption}; BSSID=${bssid}"
    start_spinner "Connecting..."

    if WIFI_CONNECT wlan0cli "$ssid" "$encryption" "$key" "$bssid"; then
        sleep 60
    else
        stop_spinner
        log_message "Connection failed: SSID=${ssid}; encryption=${encryption}; BSSID=${bssid}"
        PROMPT "Unable to associate with ${ssid}"
        return 1
    fi

    if client_is_associated; then
        stop_spinner
        address=$(get_client_ip)
        log_message "Connection successful: SSID=${ssid}; BSSID=${bssid}; IP=${address}"
        PROMPT "Association to ${ssid} successful"$'\n\n'"wlan0cli IP address: ${address}"
        test_connectivity
        return 0
    fi

    stop_spinner
    log_message "Connection failed: SSID=${ssid}; encryption=${encryption}; BSSID=${bssid}"
    PROMPT "Unable to associate with ${ssid}"
    return 1
}

choose_bssid() {
    local bssid="$1"
    local selection picker_status

    selection=$(LIST_PICKER \
        "Limit BSSID?" \
        "Only ${bssid}" \
        "Any BSSID (Roaming)" \
        "Only ${bssid}")
    picker_status=$?
    [ "$picker_status" -eq 0 ] || return 1

    case "$selection" in
        "Only ${bssid}")
            printf '%s' "$bssid"
            ;;
        "Any BSSID (Roaming)")
            printf '%s' "ANY"
            ;;
        *)
            return 1
            ;;
    esac
}

rewrite_saved_networks() {
    local i number

    number=${#SAVED_SSIDS[@]}
    umask 077

    {
        printf 'NETWORK_COUNT=%d\n\n' "$number"
        for ((i = 0; i < number; i++)); do
            printf 'NETWORK_%d_SSID=' "$((i + 1))"
            shell_escape_value "${SAVED_SSIDS[$i]}"
            printf '\nNETWORK_%d_ENCRYPTION=' "$((i + 1))"
            shell_escape_value "${SAVED_ENCRYPTIONS[$i]}"
            printf '\nNETWORK_%d_KEY=' "$((i + 1))"
            shell_escape_value "${SAVED_KEYS[$i]}"
            printf '\nNETWORK_%d_BSSID=' "$((i + 1))"
            shell_escape_value "${SAVED_BSSIDS[$i]}"
            printf '\n\n'
        done
    } > "$CONFIG_TMP" || {
        rm -f "$CONFIG_TMP"
        log_message "Unable to write saved network configuration"
        return 1
    }

    if ! mv -f "$CONFIG_TMP" "$CONFIG_FILE"; then
        rm -f "$CONFIG_TMP"
        log_message "Unable to replace saved network configuration"
        return 1
    fi
    return 0
}

load_saved_networks() {
    local count i name ssid encryption key bssid

    SAVED_SSIDS=()
    SAVED_ENCRYPTIONS=()
    SAVED_KEYS=()
    SAVED_BSSIDS=()

    [ -f "$CONFIG_FILE" ] || return 0

    NETWORK_COUNT=0
    if ! . "$CONFIG_FILE"; then
        log_message "Unable to load saved network configuration"
        return 1
    fi

    count="${NETWORK_COUNT:-0}"
    case "$count" in
        ''|*[!0-9]*)
            log_message "Saved network configuration has an invalid profile count"
            return 1
            ;;
    esac

    for ((i = 1; i <= count; i++)); do
        name="NETWORK_${i}_SSID"; ssid="${!name-}"
        name="NETWORK_${i}_ENCRYPTION"; encryption="${!name-}"
        name="NETWORK_${i}_KEY"; key="${!name-}"
        name="NETWORK_${i}_BSSID"; bssid="${!name-}"

        [ -n "$ssid" ] || continue
        case "$encryption" in
            open|psk|psk2|sae) ;;
            *) continue ;;
        esac
        [ -n "$bssid" ] || continue

        SAVED_SSIDS+=("$ssid")
        SAVED_ENCRYPTIONS+=("$encryption")
        SAVED_KEYS+=("$key")
        SAVED_BSSIDS+=("$bssid")
    done
    return 0
}

save_network() {
    local ssid="$1"
    local encryption="$2"
    local key="$3"
    local bssid="$4"
    local i existing=-1 action

    load_saved_networks || true

    for ((i = 0; i < ${#SAVED_SSIDS[@]}; i++)); do
        if [ "${SAVED_SSIDS[$i]}" = "$ssid" ]; then
            existing=$i
            break
        fi
    done

    if [ "$existing" -ge 0 ]; then
        SAVED_ENCRYPTIONS[$existing]="$encryption"
        SAVED_KEYS[$existing]="$key"
        SAVED_BSSIDS[$existing]="$bssid"
        action="updated"
    else
        SAVED_SSIDS+=("$ssid")
        SAVED_ENCRYPTIONS+=("$encryption")
        SAVED_KEYS+=("$key")
        SAVED_BSSIDS+=("$bssid")
        action="created"
    fi

    if rewrite_saved_networks; then
        if [ "$action" = "updated" ]; then
            log_message "Existing saved profile overwritten: SSID=${ssid}; BSSID=${bssid}"
        else
            log_message "Saved profile created: SSID=${ssid}; BSSID=${bssid}"
        fi
        PROMPT "Entry ${ssid} Saved"
        return 0
    fi

    PROMPT "Unable to save connection"
    return 1
}

connect_scanned_network() {
    local index="$1"
    local ssid="${SCAN_SSIDS[$index]}"
    local bssid="${SCAN_BSSIDS[$index]}"
    local encryption="${SCAN_NORMALIZED[$index]}"
    local key selected_bssid response dialog_status

    case "$encryption" in
        open)
            key="NONE"
            selected_bssid=$(choose_bssid "$bssid") || return 1
            ;;
        psk|psk2|sae)
            while true; do
                key=$(TEXT_PICKER "Passphrase?" "")
                [ "$?" -eq 0 ] || return 1
                selected_bssid=$(choose_bssid "$bssid") && break
                # Cancelling BSSID selection returns to the passphrase stage.
            done
            ;;
        *)
            PROMPT "Unsupported encryption type"
            return 1
            ;;
    esac

    perform_wifi_connection "$ssid" "$encryption" "$key" "$selected_bssid" || return 1

    response=$(CONFIRMATION_DIALOG "Save connection?")
    dialog_status=$?
    if dialog_was_confirmed "$response" "$dialog_status"; then
        save_network "$ssid" "$encryption" "$key" "$selected_bssid"
    else
        PROMPT "${ssid} not saved"
    fi
    return 0
}

network_detail_menu() {
    local index="$1"
    local selection picker_status
    local ssid="${SCAN_SSIDS[$index]}"

    while true; do
        selection=$(LIST_PICKER \
            "$ssid" \
            "Connect" \
            "${SCAN_ENCRYPTIONS[$index]}" \
            "${SCAN_BSSIDS[$index]}" \
            "${SCAN_SIGNALS[$index]} dBm Chn ${SCAN_CHANNELS[$index]}" \
            "Back" \
            "Connect")
        picker_status=$?
        [ "$picker_status" -eq 0 ] || return 0

        case "$selection" in
            "Connect")
                if connect_scanned_network "$index"; then
                    return 2
                fi
                ;;
            "Back")
                return 0
                ;;
            *)
                # Informational rows are intentionally inert.
                ;;
        esac
    done
}

nearby_networks_menu() {
    local selection picker_status index result token candidate exists i
    local picker_items=() picker_tokens=()

    if [ "${#SCAN_SSIDS[@]}" -eq 0 ]; then
        while true; do
            selection=$(LIST_PICKER \
                "Nearby Networks" \
                "No networks found" \
                "Back" \
                "No networks found")
            picker_status=$?
            [ "$picker_status" -eq 0 ] || return
            [ "$selection" != "Back" ] || return
        done
    fi

    for ((index = 0; index < ${#SCAN_SSIDS[@]}; index++)); do
        token="${SCAN_SSIDS[$index]}"
        while true; do
            exists=0
            [ "$token" != "Back" ] || exists=1
            for candidate in "${picker_tokens[@]}"; do
                [ "$candidate" != "$token" ] || exists=1
            done
            [ "$exists" -eq 0 ] && break
            token="${token} "
        done
        picker_items+=("$token")
        picker_tokens+=("$token")
    done
    picker_items+=("Back")

    while true; do
        selection=$(LIST_PICKER "Nearby Networks" "${picker_items[@]}" "${picker_items[0]}")
        picker_status=$?
        [ "$picker_status" -eq 0 ] || return
        [ "$selection" != "Back" ] || return

        for ((i = 0; i < ${#picker_tokens[@]}; i++)); do
            if [ "$selection" = "${picker_tokens[$i]}" ]; then
                network_detail_menu "$i"
                result=$?
                [ "$result" -ne 2 ] || return
                break
            fi
        done
    done
}

connect_saved_network() {
    local index="$1"
    local ssid="${SAVED_SSIDS[$index]}"
    local response dialog_status

    response=$(CONFIRMATION_DIALOG "Connect to ${ssid} ?")
    dialog_status=$?
    dialog_was_confirmed "$response" "$dialog_status" || return 1

    perform_wifi_connection \
        "$ssid" \
        "${SAVED_ENCRYPTIONS[$index]}" \
        "${SAVED_KEYS[$index]}" \
        "${SAVED_BSSIDS[$index]}"
}

forget_saved_network() {
    local index="$1"
    local ssid="${SAVED_SSIDS[$index]}"
    local i
    local new_ssids=() new_encryptions=() new_keys=() new_bssids=()

    for ((i = 0; i < ${#SAVED_SSIDS[@]}; i++)); do
        [ "$i" -eq "$index" ] && continue
        new_ssids+=("${SAVED_SSIDS[$i]}")
        new_encryptions+=("${SAVED_ENCRYPTIONS[$i]}")
        new_keys+=("${SAVED_KEYS[$i]}")
        new_bssids+=("${SAVED_BSSIDS[$i]}")
    done

    SAVED_SSIDS=("${new_ssids[@]}")
    SAVED_ENCRYPTIONS=("${new_encryptions[@]}")
    SAVED_KEYS=("${new_keys[@]}")
    SAVED_BSSIDS=("${new_bssids[@]}")

    if rewrite_saved_networks; then
        log_message "Saved profile forgotten: SSID=${ssid}"
        PROMPT "${ssid} forgotten"
        return 0
    fi

    load_saved_networks || true
    PROMPT "Unable to forget network"
    return 1
}

saved_network_detail_menu() {
    local index="$1"
    local selection picker_status

    while true; do
        selection=$(LIST_PICKER \
            "${SAVED_SSIDS[$index]}" \
            "Connect" \
            "Forget" \
            "Back" \
            "Connect")
        picker_status=$?
        [ "$picker_status" -eq 0 ] || return 0

        case "$selection" in
            "Connect")
                if connect_saved_network "$index"; then
                    return 2
                fi
                ;;
            "Forget")
                forget_saved_network "$index"
                return 1
                ;;
            "Back")
                return 0
                ;;
        esac
    done
}

saved_networks_menu() {
    local selection picker_status token candidate exists index i result
    local picker_items picker_tokens

    while true; do
        load_saved_networks || true

        if [ "${#SAVED_SSIDS[@]}" -eq 0 ]; then
            selection=$(LIST_PICKER \
                "Saved Networks" \
                "No networks saved" \
                "Back" \
                "No networks saved")
            picker_status=$?
            [ "$picker_status" -eq 0 ] || return
            [ "$selection" != "Back" ] || return
            continue
        fi

        picker_items=()
        picker_tokens=()
        for ((index = 0; index < ${#SAVED_SSIDS[@]}; index++)); do
            token="${SAVED_SSIDS[$index]}"
            while true; do
                exists=0
                [ "$token" != "Back" ] || exists=1
                for candidate in "${picker_tokens[@]}"; do
                    [ "$candidate" != "$token" ] || exists=1
                done
                [ "$exists" -eq 0 ] && break
                token="${token} "
            done
            picker_items+=("$token")
            picker_tokens+=("$token")
        done
        picker_items+=("Back")

        selection=$(LIST_PICKER "Saved Networks" "${picker_items[@]}" "${picker_items[0]}")
        picker_status=$?
        [ "$picker_status" -eq 0 ] || return
        [ "$selection" != "Back" ] || return

        for ((i = 0; i < ${#picker_tokens[@]}; i++)); do
            if [ "$selection" = "${picker_tokens[$i]}" ]; then
                saved_network_detail_menu "$i"
                result=$?
                [ "$result" -ne 2 ] || return
                break
            fi
        done
    done
}

main_menu() {
    local selection picker_status

    while true; do
        selection=$(LIST_PICKER \
            "Main Menu" \
            "Scan for networks" \
            "Saved networks" \
            "About" \
            "Exit" \
            "Scan for networks")
        picker_status=$?
        [ "$picker_status" -eq 0 ] || return 0

        case "$selection" in
            "Scan for networks")
                if scan_networks; then
                    nearby_networks_menu
                fi
                ;;
            "Saved networks")
                saved_networks_menu
                ;;
            "About")
                PROMPT "Connect to nearby or saved WiFi networks.\n\n Uses the wlan0cli (2.4 GHz) interface.\n\nProfiles are stored in payload.cfg."
                ;;
            "Exit")
                return
                ;;
        esac
    done
}

main() {
    umask 077
    trap cleanup EXIT
    trap 'exit 1' INT TERM
    : >> "$LOG_FILE" 2>/dev/null || true
    log_message "WiFi Client GUI payload started"
    main_menu
}

if [ "${WIFI_CLIENT_GUI_LIBRARY_ONLY:-0}" != "1" ]; then
    main "$@"
fi
