#!/bin/bash

# ============================================================
#  ______         _   _                   _
# |  ____|       | | | |                 | |
# | |__ _____  __| |_| | _   _  _____  __| |__ 
# |  __/ _ \ \/ /|  _  || | | |(  _  )(__   __)
# | | | (_) >  < | | | || |_| || | | |   | |
# |_|  \___/_/\_\|_| |_||_____||_| |_|   |_|
#
# Title:       FoxHunter
# Description: Passive Deauth Flood Detection — Terminal Version
# Author:      0x00
# Version:     1.0
# Target:      WiFi Pineapple (OpenWrt)
# ============================================================

# ----------------------------------------------
#                 CONFIGURATION
# ----------------------------------------------
IFACE=""                   # Leave blank to auto-detect monitor interface
THRESHOLD=50               # Deauth packets per window to trigger alert
WINDOW_SIZE=30             # Detection window in seconds
LOG_DIR="/root/loot/foxhunter"   # Working directory for logs
ALERT_SOUND=true           # Play a beep on alert (if supported)
MAX_LOG_LINES=500          # Cap log file size to avoid filling /tmp

# ----------------------------------------------
#               COLORS & STYLING
# ----------------------------------------------
RED='\033[1;31m'
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
BLINK='\033[5m'
RESET='\033[0m'
BOLD='\033[1m'

# ----------------------------------------------
#                     PATHS
# ----------------------------------------------
PACKET_LOG="$LOG_DIR/deauth_packets.txt"
EVENT_LOG="$LOG_DIR/events.log"
PID_FILE="$LOG_DIR/tcpdump.pid"
ALERT_PIPE="$LOG_DIR/alert.pipe"

# ----------------------------------------------
#                     BANNER
# ----------------------------------------------
print_banner() {
    clear
    echo -e "${RED}"
    echo -e "   ______         _   _                   _    "
    echo -e "  |  ____|       | | | |                 | |   "
    echo -e "  | |__ _____  __| |_| | _   _  _____  __| |__ "
    echo -e "  |  __/ _ \ \/ /|  _  || | | |(  _  )(__   __)"
    echo -e "  | | | (_) >  < | | | || |_| || | | |   | |   "
    echo -e "  |_|  \___/_/\_\|_| |_||_____||_| |_|   |_|   "
    echo -e "${RESET}"
    echo -e "${DIM}  -----------------------------------------------------------------------------${RESET}"
    echo -e "${WHITE}  Passive Deauth Flood Detection Payload ${DIM}│${RESET}${CYAN} WiFi Pineapple ${DIM}│${RESET}${WHITE} v1.0 by 0x00${RESET}"
    echo -e "${DIM}  -----------------------------------------------------------------------------${RESET}"
    echo ""
}

# ----------------------------------------------
#                    LOGGING
# ----------------------------------------------
log_event() {
    local level="$1"
    local msg="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $msg" >> "$EVENT_LOG"
}

# ----------------------------------------------
#  ALERT — Interrupts any screen with a full-terminal overlay
# ----------------------------------------------
trigger_alert() {
    local count="$1"
    local rate="$2"
    local top_attacker="$3"
    local ts
    ts=$(date '+%H:%M:%S')

    clear

    echo -e ""
    echo -e "${RED}${BOLD}"
    echo -e "  |--------------------------------------------------------------|"
    echo -e "  |                                                              |"
    echo -e "  |   ${BLINK}⚠  DEAUTH FLOOD DETECTED  ⚠${RESET}${RED}${BOLD}   |"
    echo -e "  |                                                              |"
    echo -e "  |--------------------------------------------------------------|"
    echo -e "  |                                                              |"
    echo -e "  |  ${YELLOW}Time      :${RESET}${RED}${BOLD}  $ts                                        |"
    echo -e "  |  ${YELLOW}Packets   :${RESET}${RED}${BOLD}  $count deauth frames in ${WINDOW_SIZE}s window              |"
    echo -e "  |  ${YELLOW}Rate      :${RESET}${RED}${BOLD}  ${rate} packets/min                   |"
    echo -e "  |  ${YELLOW}Threshold :${RESET}${RED}${BOLD}  $THRESHOLD packets          |"
    if [ -n "$top_attacker" ]; then
    echo -e "  |  ${YELLOW}Source    :${RESET}${RED}${BOLD}  $top_attacker                     |"
    fi
    echo -e "  |                                                              |"
    echo -e "  |--------------------------------------------------------------|"
    echo -e "  |                                                              |"
    echo -e "  |  ${WHITE}A wireless deauthentication flood has been detected.         ${RED}${BOLD}|"
    echo -e "  |  ${WHITE}A nearby device may be running an attack tool.               ${RED}${BOLD}|"
    echo -e "  |                                                              |"
    echo -e "  |--------------------------------------------------------------|"
    echo -e "${RESET}"
    echo -e "${DIM}  Press ${RESET}${WHITE}[ENTER]${RESET}${DIM} to dismiss and return to monitoring...${RESET}"
    echo ""

    # Beep if enabled and /dev/console is accessible
    if [ "$ALERT_SOUND" = true ]; then
        printf '\a' 2>/dev/null
        sleep 0.3
        printf '\a' 2>/dev/null
        sleep 0.3
        printf '\a' 2>/dev/null
    fi

    log_event "ALERT" "Deauth flood: $count packets | Rate: ${rate}/min | Top source: ${top_attacker:-unknown}"

    # Wait for user to acknowledge
    read -r -s

    # Return to monitoring view
    print_status_screen
}

# ----------------------------------------------
#  STATUS SCREEN — Live monitoring dashboard
# ----------------------------------------------
print_status_screen() {
    clear
    print_banner
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local total_alerts
    total_alerts=$(grep -c "\[ALERT\]" "$EVENT_LOG" 2>/dev/null || echo 0)
    local packet_count
    packet_count=$(wc -l < "$PACKET_LOG" 2>/dev/null || echo 0)

    echo -e "  ${DIM}|-------------------------------------------------------------|${RESET}"
    echo -e "  ${DIM}|${RESET} ${CYAN}${BOLD}LIVE MONITOR${RESET}                                                ${DIM}|${RESET}"
    echo -e "  ${DIM}|-------------------------------------------------------------|${RESET}"
    echo -e "  ${DIM}|${RESET}  Interface   : ${GREEN}${IFACE}${RESET}"
    echo -e "  ${DIM}|${RESET}  Threshold   : ${WHITE}${THRESHOLD} packets / ${WINDOW_SIZE}s${RESET}"
    echo -e "  ${DIM}|${RESET}  Started     : ${WHITE}${START_TIME}${RESET}"
    echo -e "  ${DIM}|${RESET}  Last Check  : ${WHITE}${ts}${RESET}"
    echo -e "  ${DIM}|${RESET}  Deauth Pkts : ${YELLOW}${packet_count}${RESET} captured total"
    echo -e "  ${DIM}|${RESET}  Alerts      : ${RED}${total_alerts}${RESET} triggered"
    echo -e "  ${DIM}|-------------------------------------------------------------|${RESET}"
    echo ""
    echo -e "  ${DIM}Press Ctrl+C to stop FoxHunter${RESET}"
    echo ""

    if [ -s "$EVENT_LOG" ]; then
        echo -e "  ${DIM}-- Recent Events ------------------------------------------${RESET}"
        tail -5 "$EVENT_LOG" | while IFS= read -r line; do
            if echo "$line" | grep -q "\[ALERT\]"; then
                echo -e "  ${RED}${line}${RESET}"
            else
                echo -e "  ${DIM}${line}${RESET}"
            fi
        done
        echo ""
    fi
}

# ----------------------------------------------
#           INTERFACE AUTO-DETECTION
# ----------------------------------------------
detect_interface() {
    if [ -n "$IFACE" ]; then
        if ! ip link show "$IFACE" &>/dev/null; then
            echo -e "${RED}[ERROR]${RESET} Interface '${IFACE}' not found. Check your config."
            exit 1
        fi
        return
    fi

    # Try to find a monitor-mode interface automatically
    IFACE=$(iw dev 2>/dev/null | awk '/Interface/{iface=$2} /type monitor/{print iface; exit}')

    if [ -z "$IFACE" ]; then
        echo -e "${RED}[ERROR]${RESET} No monitor-mode interface detected."
        echo -e "${WHITE}        Set IFACE manually at the top of this script, or run:${RESET}"
        echo -e "${DIM}        airmon-ng start wlan0${RESET}"
        exit 1
    fi

    echo -e "  ${GREEN}[✓]${RESET} Auto-detected monitor interface: ${CYAN}${IFACE}${RESET}"
    sleep 1
}

# ----------------------------------------------
#                DEPENDENCY CHECK
# ----------------------------------------------
check_deps() {
    local missing=()
    for cmd in tcpdump iw ip grep awk wc date; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}[ERROR]${RESET} Missing required tools: ${missing[*]}"
        echo -e "${DIM}        Install with: opkg install ${missing[*]}${RESET}"
        exit 1
    fi
}

# ----------------------------------------------
#          CLEANUP — Runs on exit/Ctrl+C
# ----------------------------------------------
cleanup() {
    echo ""
    echo -e "${YELLOW}[FoxHunter]${RESET} Shutting down..."

    # Kill tcpdump
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        kill "$pid" 2>/dev/null
        rm -f "$PID_FILE"
    fi

    # Kill the named pipe listener
    rm -f "$ALERT_PIPE"

    # Kill background jobs
    jobs -p | xargs kill 2>/dev/null

    echo -e "${GREEN}[✓]${RESET} FoxHunter stopped. Event log saved to: ${CYAN}${EVENT_LOG}${RESET}"
    exit 0
}

# ----------------------------------------------
#  TRIM LOG — Keep packet log from filling /tmp
# ----------------------------------------------
trim_log() {
    local lines
    lines=$(wc -l < "$PACKET_LOG" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
        tail -$((MAX_LOG_LINES / 2)) "$PACKET_LOG" > "${PACKET_LOG}.tmp" \
            && mv "${PACKET_LOG}.tmp" "$PACKET_LOG"
    fi
}

# ----------------------------------------------
#  PACKET CAPTURE — Background tcpdump
# ----------------------------------------------
start_capture() {
    tcpdump -i "$IFACE" -l -e -n type mgt subtype deauth 2>/dev/null \
        >> "$PACKET_LOG" &
    echo $! > "$PID_FILE"
    log_event "INFO" "Capture started on $IFACE | Threshold: $THRESHOLD | Window: ${WINDOW_SIZE}s"
}

# ----------------------------------------------
#  GET TOP ATTACKER MAC — Most frequent source
# ----------------------------------------------
get_top_attacker() {
    # tcpdump -e prints source MAC in format: SA:xx:xx:xx:xx:xx or as 2nd address field
    # Extract source addresses and find the most common one
    grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' "$PACKET_LOG" 2>/dev/null \
        | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}

# ----------------------------------------------
#  ANALYSIS LOOP — Core detection engine
# ----------------------------------------------
analyze_loop() {
    local last_line_count=0

    while true; do
        sleep "$WINDOW_SIZE"

        # Count new packets since last window
        local current_line_count
        current_line_count=$(wc -l < "$PACKET_LOG" 2>/dev/null || echo 0)
        local count=$(( current_line_count - last_line_count ))
        last_line_count=$current_line_count

        # Trim log if needed
        trim_log

        # Calculate rate (packets per minute)
        local rate=0
        if [ "$WINDOW_SIZE" -gt 0 ]; then
            rate=$(( count * 60 / WINDOW_SIZE ))
        fi

        log_event "INFO" "Window check: $count deauth packets | Rate: ${rate}/min"

        # Refresh status screen between windows
        print_status_screen

        # Alert if threshold exceeded
        if [ "$count" -gt "$THRESHOLD" ]; then
            local top_attacker
            top_attacker=$(get_top_attacker)
            trigger_alert "$count" "$rate" "$top_attacker"
        fi
    done
}

# ----------------------------------------------
#                   ROOT CHECK
# ----------------------------------------------
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}[ERROR]${RESET} FoxHunter must be run as root."
        exit 1
    fi
}

# ----------------------------------------------
#                      MAIN
# ----------------------------------------------
main() {
    check_root
    check_deps

    # Setup working directory
    mkdir -p "$LOG_DIR"
    : > "$PACKET_LOG"
    : > "$EVENT_LOG"

    trap cleanup INT TERM EXIT

    print_banner

    echo -e "  ${CYAN}[*]${RESET} Initializing FoxHunter..."
    detect_interface

    START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    export START_TIME

    echo -e "  ${CYAN}[*]${RESET} Starting packet capture on ${CYAN}${IFACE}${RESET}..."
    start_capture

    sleep 1
    echo -e "  ${GREEN}[✓]${RESET} Capture running. Entering detection loop..."
    sleep 1

    print_status_screen
    analyze_loop
}

main


