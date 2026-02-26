#!/bin/bash
# Title: Wordlist Manager
# Author: sinX
# Description: Download and manage wordlists for password cracking
# Version: 1.0
# Category: user/general

# ============================================
# CONFIGURATION
# ============================================
WORDLIST_DIR="/root/wordlists"
TEMP_DIR="/tmp/wordlists"
COMMON_WORDLIST_URL="https://example.com/common-passwords.txt"
TOP10K_WORDLIST_URL="https://example.com/rockyou-top10k.txt"

# ============================================
# MAIN EXECUTION
# ============================================

LOG green "=== Wordlist Manager ==="

# Create directories
mkdir -p "$WORDLIST_DIR"
mkdir -p "$TEMP_DIR"

# Check current wordlists
CURRENT_COUNT=$(find "$WORDLIST_DIR" -name "*.txt" -o -name "*.lst" 2>/dev/null | wc -l)
LOG blue "Current wordlists: $CURRENT_COUNT"

# Show menu
LOG ""
LOG "Available actions:"
LOG "1. Download common wordlists"
LOG "2. View current wordlists"
LOG "3. Remove wordlists"
LOG "4. Create custom wordlist"

# For now, implement download function
resp=$(CONFIRMATION_DIALOG "Download common wordlists?")
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED)
        LOG "Cancelled"
        exit 0
        ;;
esac

if [ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
    exit 0
fi

# Check internet connectivity
if ! ping -c 1 8.8.8.8 &>/dev/null; then
    ERROR_DIALOG "No internet connection"
    exit 1
fi

LOG yellow "Downloading wordlists..."
SPINNER "Downloading..."

# Download common wordlists
# The end user must host these files and update the URLs above.

# Small wordlist for testing (example)
if ! wget -q -O "$WORDLIST_DIR/common-passwords.txt" "$COMMON_WORDLIST_URL" 2>/dev/null; then
    LOG yellow "Failed to download common-passwords.txt"
fi

# Download rockyou sample (top 10k)
if ! wget -q -O "$WORDLIST_DIR/rockyou-top10k.txt" "$TOP10K_WORDLIST_URL" 2>/dev/null; then
    LOG yellow "Failed to download rockyou-top10k.txt"
fi

# Count downloaded
NEW_COUNT=$(find "$WORDLIST_DIR" -name "*.txt" -o -name "*.lst" 2>/dev/null | wc -l)

if [ "$NEW_COUNT" -gt "$CURRENT_COUNT" ]; then
    LOG green "Successfully downloaded wordlists!"
    LOG green "Total wordlists: $NEW_COUNT"

    # List wordlists with sizes
    LOG ""
    LOG "Available wordlists:"
    for wl in "$WORDLIST_DIR"/*.txt; do
        if [ -f "$wl" ]; then
            SIZE=$(wc -l < "$wl")
            LOG "  - $(basename $wl): $SIZE passwords"
        fi
    done

    ALERT "Wordlists downloaded!\n$NEW_COUNT total wordlists"
    VIBRATE
else
    LOG yellow "No new wordlists downloaded"
    LOG yellow "You may need to manually upload wordlists"
fi

# Cleanup
rm -rf "$TEMP_DIR"

LOG blue "Wordlist directory: $WORDLIST_DIR"
LOG "Done!"

exit 0
