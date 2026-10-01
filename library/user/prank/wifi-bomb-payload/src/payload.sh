#!/bin/bash

# ================================================
# Title: Wi-Fi Beacon Bomb (1000 Fake APs)
# Author: turkkat284
# Description: Sets monitor mode and launches core/core.py for WiFi Pineapple Pager
# Version: 2.0
# Category: Prank
# Target: WiFi Pineapple Pager
# ================================================
#
# DESCRIPTION:
# This payload initializes the WiFi Pineapple Pager for beacon bombing operations.
# It prepares the environment by installing necessary Python dependencies and
# setting up monitor mode on the wireless interface, then launches the core 
# beacon bomb script that generates 1000+ fake access points.
#
# REQUIREMENTS:
# - WiFi Pineapple Pager
# - aircrack-ng suite (airmon-ng)
# - Python 3 with pip
# - Scapy library (will be auto-installed)
#
# LED INDICATORS:
# - Magenta Solid - Configuring environment and dependencies
# - Amber Blink - Monitor mode activated
# - Green Solid - Beacon bomb core script launched
# - Red Blink - Error during setup
#
# CONFIGURATION:
# Modify these variables to customize the payload behavior

# Detect the payload script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PAYLOAD_DIR="$(dirname "$SCRIPT_DIR")"  # Parent directory containing core/

# Network Interface Configuration
IFACE="${WIFI_IFACE:-wlan0}"           # Primary wireless interface (override with env var)
MON_IFACE="${WIFI_MON_IFACE:-}"        # Monitor mode interface name (auto-detect if empty)

# Logging
LOG_FILE="${WIFI_LOG_FILE:-/tmp/wifi_bomb.log}"

# ================================================
# FUNCTIONS
# ================================================

# Logging function
log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOG_FILE"
}

# Error handler
error_exit() {
    log_message "ERROR: $1"
    exit 1
}

# Auto-detect wireless interfaces
detect_interface() {
    log_message "Auto-detecting wireless interface..."
    
    # Try to find a wireless interface
    local iface=$(ip link show | grep -E "^\d+:\s+(wlan|wlo|ath)" | head -1 | awk '{print $2}' | tr -d ':')
    
    if [ -z "$iface" ]; then
        error_exit "No wireless interface found. Available interfaces: $(ip link show | grep -E '^\d+:' | awk '{print $2}' | tr -d ':' | tr '\n' ' ')"
    fi
    
    log_message "Detected wireless interface: $iface"
    IFACE="$iface"
}

# Prepare environment with dependencies
prepare_environment() {
    log_message "Starting environment preparation..."
    
    # Update package lists (best effort, non-blocking)
    log_message "Updating package lists..."
    apt-get update > /dev/null 2>&1 || log_message "Warning: apt-get update failed (non-blocking)"
    
    # Install pip if not available
    log_message "Ensuring pip3 is installed..."
    apt-get install -y python3-pip > /dev/null 2>&1 || log_message "Warning: pip3 installation attempted"
    
    # Upgrade pip
    log_message "Upgrading pip..."
    python3 -m pip install --upgrade pip > /dev/null 2>&1 || log_message "Warning: pip upgrade attempted"
    
    # Install Scapy (required for packet crafting)
    log_message "Installing Scapy library..."
    python3 -m pip install scapy > /dev/null 2>&1 || log_message "Warning: Scapy installation attempted"
    
    log_message "Environment preparation complete"
}

# Enable monitor mode on the wireless interface
enable_monitor_mode() {
    log_message "Enabling monitor mode on $IFACE..."
    
    # Check if interface exists
    if ! ip link show "$IFACE" > /dev/null 2>&1; then
        error_exit "Interface $IFACE not found"
    fi
    
    # Kill interfering processes
    log_message "Killing interfering processes..."
    airmon-ng check kill > /dev/null 2>&1 || true
    
    # Attempt to enable monitor mode with airmon-ng
    if command -v airmon-ng &> /dev/null; then
        log_message "Using airmon-ng to enable monitor mode..."
        local airmon_output=$(airmon-ng start "$IFACE" 2>&1)
        log_message "airmon-ng output: $airmon_output"
        
        # Try to detect the monitor interface created by airmon-ng
        # It might be wlan0mon, wlan0-mon, or the original interface name
        sleep 1
        
        if [ -z "$MON_IFACE" ]; then
            # Auto-detect monitor interface
            MON_IFACE=$(iwconfig 2>/dev/null | grep "Mode:Monitor" | awk '{print $1}' | head -1)
            
            if [ -z "$MON_IFACE" ]; then
                # Fallback: try common naming patterns
                for candidate in "${IFACE}mon" "${IFACE}-mon" "${IFACE}"; do
                    if iwconfig "$candidate" 2>/dev/null | grep -q "Mode:Monitor"; then
                        MON_IFACE="$candidate"
                        break
                    fi
                done
            fi
        fi
        
        # Verify monitor mode is active
        if [ -n "$MON_IFACE" ] && iwconfig "$MON_IFACE" 2>/dev/null | grep -q "Mode:Monitor"; then
            log_message "Monitor mode successfully enabled on $MON_IFACE"
        else
            log_message "Warning: Monitor mode may not be active on $MON_IFACE, attempting manual configuration..."
            # Set MON_IFACE to the original interface as fallback
            MON_IFACE="${MON_IFACE:-$IFACE}"
        fi
    else
        log_message "airmon-ng not found, attempting manual iwconfig method..."
        ip link set "$IFACE" down
        iwconfig "$IFACE" mode monitor
        ip link set "$IFACE" up
        MON_IFACE="$IFACE"
        
        if iwconfig "$IFACE" 2>/dev/null | grep -q "Mode:Monitor"; then
            log_message "Monitor mode successfully enabled via iwconfig on $IFACE"
        else
            error_exit "Failed to enable monitor mode"
        fi
    fi
    
    # Final validation
    if ! iwconfig "$MON_IFACE" 2>/dev/null | grep -q "Mode:Monitor"; then
        log_message "Warning: Monitor mode validation failed, but continuing anyway..."
    fi
}

# Launch the core beacon bomb script
run_core_script() {
    log_message "Launching core beacon bomb script..."
    
    # Verify payload directory exists
    if [ ! -d "$PAYLOAD_DIR" ]; then
        error_exit "Payload directory not found: $PAYLOAD_DIR"
    fi
    
    # Verify core script exists
    if [ ! -f "$PAYLOAD_DIR/core/core.py" ]; then
        error_exit "Core script not found: $PAYLOAD_DIR/core/core.py"
    fi
    
    # Verify Python is available
    if ! command -v python3 &> /dev/null; then
        error_exit "Python3 is not installed"
    fi
    
    # Change to payload directory and launch script in background
    log_message "Changing to $PAYLOAD_DIR and starting core.py..."
    cd "$PAYLOAD_DIR" || error_exit "Cannot change to $PAYLOAD_DIR"
    
    # Launch with environment variable for monitor interface
    log_message "Launching: env WIFI_BOMB_IFACE='$MON_IFACE' python3 core/core.py"
    nohup env WIFI_BOMB_IFACE="$MON_IFACE" python3 core/core.py > "$LOG_FILE" 2>&1 &
    local pid=$!
    
    log_message "Core script launched with PID: $pid"
    log_message "Beacon bomb is now running in background"
}

# Cleanup function
cleanup() {
    log_message "Cleaning up resources..."
    # Add any cleanup operations here if needed
}

# ================================================
# MAIN EXECUTION
# ================================================

main() {
    log_message "================================================"
    log_message "WiFi Beacon Bomb Payload - WiFi Pineapple Pager"
    log_message "================================================"
    log_message "Starting payload execution..."
    log_message "Payload directory: $PAYLOAD_DIR"
    log_message "Log file: $LOG_FILE"
    
    # Auto-detect interface if needed
    if [ -z "$IFACE" ] || [ "$IFACE" = "wlan0" ]; then
        if ! ip link show wlan0 > /dev/null 2>&1; then
            detect_interface
        fi
    fi
    
    # Execute setup phases
    prepare_environment || error_exit "Environment preparation failed"
    
    log_message "Waiting for dependencies to settle..."
    sleep 2
    
    enable_monitor_mode || error_exit "Monitor mode activation failed"
    
    log_message "Waiting before launching core script..."
    sleep 2
    
    run_core_script || error_exit "Core script launch failed"
    
    log_message "================================================"
    log_message "WiFi Beacon Bomb payload setup complete!"
    log_message "Monitor interface: $MON_IFACE"
    log_message "Payload directory: $PAYLOAD_DIR"
    log_message "Log file: $LOG_FILE"
    log_message "Run 'tail -f $LOG_FILE' to monitor execution"
    log_message "================================================"
    
    cleanup
    exit 0
}

# Execute main function
main "$@"
