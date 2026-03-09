#!/bin/bash
# Title: PagerBoy Controller
# Author: Brandon Starkweather

# --- CONFIGURATION ---
TARGET_FILE="/pineapple/ui/index.html"
BACKUP_FILE="/pineapple/ui/index.html.original"
PAYLOAD_DIR="/root/payloads/user/general/PagerBoy"
MOBILE_FILE="$PAYLOAD_DIR/index.html"

# --- HELPER FUNCTIONS ---

check_state() {
    if [ -f "$BACKUP_FILE" ]; then
        echo "PAGERBOY"
    else
        echo "CLASSIC"
    fi
}

enable_mobile() {
    LOG white "[*] Activating PagerBoy Theme..."
    LOG ""
    
    if [ -f "$BACKUP_FILE" ]; then
        LOG red "[!] PagerBoy Theme Already Active."
        return
    fi

    if [ ! -f "$MOBILE_FILE" ]; then
        LOG red "[X] ERROR: Missing Payload File"
        return
    fi

    cp "$TARGET_FILE" "$BACKUP_FILE"
    cp "$MOBILE_FILE" "$TARGET_FILE"
    LOG yellow "[+] THEME SWITCHED: PagerBoy Active"
}

disable_mobile() {
    LOG white "[*] Restoring Classic Theme..."
    LOG ""

    if [ ! -f "$BACKUP_FILE" ]; then
        LOG red "[!] Classic Theme Already Active."
        return
    fi

    mv "$BACKUP_FILE" "$TARGET_FILE"
    LOG blue "[+] THEME SWITCHED: Classic Mode Active"
}

# --- MAIN EXECUTION ---

# 1. Check State
CURRENT_STATE=$(check_state)

# 2. Display Interface
LOG "== PAGERBOY THEME CONTROLLER =="

if [ "$CURRENT_STATE" == "PAGERBOY" ]; then
    
    LOG ""
    LOG yellow " [PAGERBOY MODE ACTIVE] "
    LOG ""
    LOG yellow " UP   | Keep PagerBoy"
    LOG ""
    LOG blue  " DOWN | Switch to Classic"
else
    LOG ""
    LOG blue " [CLASSIC MODE ACTIVE] "
    LOG ""
    LOG yellow  " UP   | Switch to PagerBoy"
    LOG ""
    LOG blue " DOWN | Keep Classic"
fi

LOG ""
LOG "========================"
LOG ""

# 3. Wait for Input
BUTTON=$(WAIT_FOR_INPUT)

case "$BUTTON" in
    "UP")
        enable_mobile
        ;;
    "DOWN")
        disable_mobile
        ;;
    *)
        LOG red "Aborted."
        ;;
esac