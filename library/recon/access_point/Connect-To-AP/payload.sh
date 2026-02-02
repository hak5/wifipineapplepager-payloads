#!/bin/bash
# Title: Connect to 2.4GHz AP
# Author: spencershepard (GRIMM)
# Description: Connect to selected 2.4GHz access point via Recon with SSID and password memory
# Version: 1.0

# Configuration
REMEMBERED_APS="/mmc/root/.wifi_remembered_aps"
IP_RETRY_COUNT=20
IP_RETRY_DELAY=5

# MetaPayload is optional, but if installed, you will have the option to update the global TARGET_SUBNET on connection
METAPAYLOAD_DIR="/root/payloads/user/metapayload" 

#=== Log previous AP details ===
LOG "wlan0cli currently configured for:"
CURRENT_SSID=$(uci get wireless.wlan0cli.ssid 2>/dev/null)
if [ -n "$CURRENT_SSID" ]; then
    LOG "SSID: $CURRENT_SSID"
    CURRENT_ENC=$(uci get wireless.wlan0cli.encryption 2>/dev/null)
    LOG "Encryption: $CURRENT_ENC"
    CURRENT_BSSID=$(uci get wireless.wlan0cli.bssid 2>/dev/null)
    LOG "BSSID: $CURRENT_BSSID"
else
    LOG "No current configuration found."
fi
LOG "\n"
LOG "=== Newly selected AP Details ==="

# === Handle Hidden SSID ===
if [ "$_RECON_SELECTED_AP_HIDDEN" = "true" ] || [ "$_RECON_SELECTED_AP_HIDDEN" = "1" ] || \
   [ -z "$_RECON_SELECTED_AP_SSID" ] || [ "$_RECON_SELECTED_AP_SSID" = "(hidden)" ]; then
    LOG "Hidden network detected"
    TARGET_SSID=$(TEXT_PICKER "Enter SSID for hidden network" "")
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            LOG "User cancelled or error occurred"
            exit 1
            ;;
    esac
    if [ -z "$TARGET_SSID" ]; then
        ALERT "SSID cannot be empty"
        exit 1
    fi
else
    TARGET_SSID="$_RECON_SELECTED_AP_SSID"
fi

LOG orange "Target SSID: $TARGET_SSID"
LOG orange "BSSID: $_RECON_SELECTED_AP_BSSID"
LOG orange "Encryption: $_RECON_SELECTED_AP_ENCRYPTION_TYPE\n"

# === Check if AP is on 2.4GHz (wlan0cli only supports 2.4GHz) ===
AP_FREQ="$_RECON_SELECTED_AP_FREQ"
AP_CHANNEL="$_RECON_SELECTED_AP_CHANNEL"

# Check frequency (2.4GHz is 2400-2500 MHz range)
if [ -n "$AP_FREQ" ]; then
    if [ "$AP_FREQ" -ge 5000 ]; then
        ALERT "Error: Only 2.4GHz supported."
        LOG red "Cannot connect: AP frequency is ${AP_FREQ}MHz (5GHz)"
        exit 1
    fi
# Fallback to channel check (2.4GHz is channels 1-14)
elif [ -n "$AP_CHANNEL" ]; then
    if [ "$AP_CHANNEL" -ge 36 ]; then
        ALERT "Error: Only 2.4GHz supported."
        LOG red "Cannot connect: AP channel is ${AP_CHANNEL} (5GHz)"
        exit 1
    fi
fi

LOG "AP is on 2.4GHz (Channel: $AP_CHANNEL, Freq: ${AP_FREQ}MHz)"

# === Map encryption type for WIFI_CONNECT ===
NEW_ENC="$_RECON_SELECTED_AP_ENCRYPTION_TYPE"
case "$NEW_ENC" in
    *WPA2*|*PSK2*|*psk2*) NEW_ENC="psk2";;
    *WPA3*|*SAE*|*sae*) NEW_ENC="sae";;
    *WPA*|*PSK*|*psk*) NEW_ENC="psk";;
    *Open*|*open*|*NONE*|*none*|"") NEW_ENC="open";;
esac

LOG "Mapped encryption: $NEW_ENC"

# === Check for saved credentials ===
SAVED_PASSWORD=""
if [ -f "$REMEMBERED_APS" ]; then
    SAVED_ENTRY=$(grep "^${TARGET_SSID}|" "$REMEMBERED_APS" | head -n 1)
    if [ -n "$SAVED_ENTRY" ]; then
        SAVED_PASSWORD=$(echo "$SAVED_ENTRY" | cut -d'|' -f3)
        LOG "Found saved credentials for $TARGET_SSID"
    fi
fi

# === Get password based on encryption type ===
if [ "$NEW_ENC" = "open" ]; then
    LOG "Open network - no password required"
    WIFI_PASSWORD="NONE"
else
    # Prompt for password with saved password pre-populated
    WIFI_PASSWORD=$(TEXT_PICKER "Password for $TARGET_SSID" "$SAVED_PASSWORD")
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            LOG "User cancelled or error occurred"
            exit 1
            ;;
    esac
    
    if [ -z "$WIFI_PASSWORD" ]; then
        ALERT "Password cannot be empty"
        exit 1
    fi
fi

# === Clear previous connection ===
LOG "\n=== Resetting wlan0cli interface ===\n"
WIFI_CLEAR wlan0cli
sleep 10

# === Connect to network ===
LOG blue "=== Connecting to $TARGET_SSID ===\n"


if WIFI_CONNECT wlan0cli "$TARGET_SSID" "$NEW_ENC" "$WIFI_PASSWORD" "$_RECON_SELECTED_AP_BSSID"; then
    LOG green "=== Successfully connected to $TARGET_SSID ===\n"
    
    # === Save/Update password if different ===
    if [ "$NEW_ENC" != "open" ] && [ "$WIFI_PASSWORD" != "$SAVED_PASSWORD" ]; then
        resp=$(CONFIRMATION_DIALOG "Save password for $TARGET_SSID?")
        case $? in
            $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                LOG "Could not show save dialog"
                ;;
            *)
                case "$resp" in
                    $DUCKYSCRIPT_USER_CONFIRMED)
                        LOG "Saving credentials..."
                        # Remove old entry if exists
                        if [ -f "$REMEMBERED_APS" ]; then
                            grep -v "^${TARGET_SSID}|" "$REMEMBERED_APS" > "${REMEMBERED_APS}.tmp"
                            mv "${REMEMBERED_APS}.tmp" "$REMEMBERED_APS"
                        fi
                        # Add new entry
                        echo "${TARGET_SSID}|${NEW_ENC}|${WIFI_PASSWORD}|${_RECON_SELECTED_AP_BSSID}" >> "$REMEMBERED_APS"
                        LOG "Credentials saved"
                        ;;
                    $DUCKYSCRIPT_USER_DENIED)
                        LOG "Credentials not saved"
                        ;;
                esac
                ;;
        esac
    fi

    # Give interface time to reset and obtain new IP
    LOG "Waiting for interface to stabilize...\n"
    sleep 5
    
    # Wait for IP address assignment with retry
    LOG "Waiting for IP address...\n"
    IP_ADDR=""

    wait_msgs=(
        "...\n"
        "Still waiting for IP...\n"
        "...\n"
        "This part can take a while...\n"
        "...\n"
        "Come on DHCP, do your thing...\n"
        "...\n"
        "Checking again...\n"
        "...\n"
        "Umm...how about a joke?\n"
        "A SQL query walks into a bar..."
        "walks up to two tables and asks: 'Can I join you?'\n"
        "...\n"
        "Sorry, that was bad.\n"
        "...\n"
        "Still no IP though...\n"
        "...\n"
        "Almost ready to give up at this point...\n"
        "Still no IP...I'm done...\n"
    )

    for i in $(seq 1 $IP_RETRY_COUNT); do
        IP_ADDR=$(ifconfig wlan0cli | grep "inet addr" | awk '{print $2}' | cut -d':' -f2)
        if [ -n "$IP_ADDR" ]; then
            LOG green "IP address obtained: $IP_ADDR"
            break
        fi
        # Log silly messages while the user waits
        LOG "${wait_msgs[$(( (i - 1) % ${#wait_msgs[@]} ))]}"
        sleep $IP_RETRY_DELAY 
    done
    
    # Show connection info
    if [ -n "$IP_ADDR" ]; then
        
        # Quick test to see if internet is reachable
        LOG "Testing internet connectivity..."
        ping -c 1 1.1.1.1 > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            LOG green "Internet is reachable!"
            ALERT "Connected to $TARGET_SSID!\nIP: $IP_ADDR\nInternet: Reachable"
        else
            LOG yellow "Warning: Internet is NOT reachable"
            ALERT "Connected to $TARGET_SSID!\nIP: $IP_ADDR\nInternet: NOT Reachable"
        fi

        

        # === Update MetaPayload TARGET_SUBNET if MetaPayload is installed ===
        if [ -f "$METAPAYLOAD_DIR/.env" ]; then
            LOG "MetaPayload detected"
            # Calculate subnet (replace last octet with 0)
            NEW_SUBNET=$(echo "$IP_ADDR" | awk -F'.' '{print $1"."$2"."$3".0/24"}')
            
            # Check current TARGET_SUBNET value
            CURRENT_SUBNET=$(grep "^TARGET_SUBNET=" "$METAPAYLOAD_DIR/.env" 2>/dev/null | cut -d'=' -f2)
            
            if [ "$CURRENT_SUBNET" = "$NEW_SUBNET" ]; then
                LOG green "TARGET_SUBNET already set to $NEW_SUBNET"
            else
                resp=$(CONFIRMATION_DIALOG "Update TARGET_SUBNET to $NEW_SUBNET?")
                case $? in
                    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                        LOG "Could not show subnet update dialog"
                        ;;
                    *)
                        case "$resp" in
                            $DUCKYSCRIPT_USER_CONFIRMED)
                                LOG "Updating TARGET_SUBNET in MetaPayload..."
                                VAR_NAME="TARGET_SUBNET"
                                # Save to global .env
                                if grep -q "^${VAR_NAME}=" "$METAPAYLOAD_DIR/.env" 2>/dev/null; then
                                    sed -i "s|^${VAR_NAME}=.*|${VAR_NAME}=${NEW_SUBNET}|" "$METAPAYLOAD_DIR/.env"
                                else
                                    echo "${VAR_NAME}=${NEW_SUBNET}" >> "$METAPAYLOAD_DIR/.env"
                                fi
                                LOG green "TARGET_SUBNET updated to $NEW_SUBNET"
                                ;;
                            $DUCKYSCRIPT_USER_DENIED)
                                LOG "MetaPayload TARGET_SUBNET not updated"
                                ;;
                        esac
                        ;;
                esac
            fi
        fi
        
    else
        ALERT "Connected to $TARGET_SSID (No IP)"
        LOG yellow "Warning: No IP address assigned"
    fi
else
    ALERT "Failed to connect to $TARGET_SSID"
    LOG red "Connection failed"
    exit 1
fi
