#!/bin/bash
# Title: Client WiFi Picker
# Author: TheDadNerd
# Description: Switches client mode WiFi between a selection of saved networks
# Version: 1.0
# Category: general

# =============================================================================
# INTERNALS: helpers and config storage
# =============================================================================

handle_picker_status() {
    # Normalize DuckyScript dialog exit codes.
    local status="$1"
    case "$status" in
        "$DUCKYSCRIPT_CANCELLED")
            LOG "User cancelled"
            exit 1
            ;;
        "$DUCKYSCRIPT_REJECTED")
            LOG "Dialog rejected"
            exit 1
            ;;
        "$DUCKYSCRIPT_ERROR")
            ERROR_DIALOG "An error occurred"
            exit 1
            ;;
    esac
}

# Pager CONFIG storage key namespace.
PAYLOAD_NAME="switch_client_wifi"

get_payload_config() {
    # Wrapper for payload config reads.
    PAYLOAD_GET_CONFIG "$PAYLOAD_NAME" "$1" 2>/dev/null
}

# Load configured networks from payload storage.
SSIDS=()
PASSWORDS=()
ENCRYPTIONS=()
config_count=$(get_payload_config "count")
if ! [[ "$config_count" =~ ^[0-9]+$ ]] || [[ "$config_count" -lt 1 ]]; then
    LOG "No saved WiFi profiles. Run Client Wifi Picker Configuration first."
    ALERT "No saved WiFi profiles.\nRun Client Wifi Picker Configuration first."
    exit 0
fi
for idx in $(seq 1 "$config_count"); do
    ssid=$(get_payload_config "ssid_$idx")
    password=$(get_payload_config "pass_$idx")
    encryption=$(get_payload_config "enc_$idx")
    SSIDS+=("$ssid")
    PASSWORDS+=("$password")
    ENCRYPTIONS+=("${encryption:-psk2}")
done

# Validate config arrays.
if [[ "${#SSIDS[@]}" -eq 0 ]]; then
    ERROR_DIALOG "No SSIDs configured. Re-run the payload to configure."
    exit 1
fi

if [[ "${#SSIDS[@]}" -ne "${#PASSWORDS[@]}" ]]; then
    ERROR_DIALOG "SSID/PASSWORD list mismatch. Ensure arrays are the same length."
    exit 1
fi

if [[ "${#ENCRYPTIONS[@]}" -ne 0 && "${#ENCRYPTIONS[@]}" -ne "${#SSIDS[@]}" ]]; then
    ERROR_DIALOG "SSID/ENCRYPTION list mismatch. Ensure arrays are the same length."
    exit 1
fi

# Build menu text for the selection dialog.
MENU="Select a client WiFi profile:\n"
for i in "${!SSIDS[@]}"; do
    MENU+="\n$((i + 1))) ${SSIDS[$i]}"
done

LOG "Building network list..."
ack=$(PROMPT "$MENU" "")
handle_picker_status $?

LOG "Awaiting user selection..."
choice=$(NUMBER_PICKER "Pick a network (1-${#SSIDS[@]})" 1)
handle_picker_status $?

# Validate selection and map to profile index.
if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#SSIDS[@]} )); then
    ERROR_DIALOG "Invalid selection: $choice"
    exit 1
fi

index=$((choice - 1))
ssid="${SSIDS[$index]}"
password="${PASSWORDS[$index]}"
encryption="${ENCRYPTIONS[$index]:-psk2}"

if [[ -z "$password" || "$encryption" == "none" ]]; then
    encryption="none"
fi

# Confirm before applying changes.
confirm=$(CONFIRMATION_DIALOG "Connect to \"$ssid\" now?")
case "$confirm" in
    "$DUCKYSCRIPT_USER_DENIED")
        LOG "Operation cancelled by user."
        exit 0
        ;;
    "$DUCKYSCRIPT_USER_CONFIRMED")
        ;;
    1) ;; # fallback confirmation
    *) exit 0 ;;
esac

# =============================================================================
# APPLY WIRELESS CONFIGURATION
# =============================================================================

LOG "Preparing client mode configuration..."
# Use the Pager client-mode interface section.
CLIENT_SECTION="wlan0cli"

# Apply SSID and security settings.
LOG "Updating client profile: $ssid"
uci set wireless."$CLIENT_SECTION".ssid="$ssid"
uci set wireless."$CLIENT_SECTION".encryption="$encryption"
uci set wireless."$CLIENT_SECTION".disabled="0"

if [[ "$encryption" == "none" ]]; then
    uci -q delete wireless."$CLIENT_SECTION".key
else
    uci set wireless."$CLIENT_SECTION".key="$password"
fi

uci commit wireless

LOG "Applying WiFi settings..."
wifi reload

LOG "WiFi settings applied for $ssid"
ALERT "WiFi settings applied.\nSelected network: $ssid"
