#!/bin/bash
# Title: External MediaTek Chip Loader/Remover
# Author: Huntz
# Version: 1.0

set -u

# --- Constants ---
# We strictly target the external USB port (1-1.1) interface 3 (.3)
TARGET_BUS_ID="1-1.1:1.3"
USB_SYS_PATH="/sys/bus/usb/devices/${TARGET_BUS_ID}"

# Radios
INT_IFACE="wlan1mon" # Internal
EXT_IFACE="wlan2mon" # External
EXT_RADIO="radio2"

# --- Helpers ---
have() { command -v "$1" >/dev/null 2>&1; }
log_y() { have LOG && LOG yellow "$1" || echo "[*] $1"; }
log_g() { have LOG && LOG green  "$1" || echo "[+] $1"; }
err() {
  if have ERROR_DIALOG; then ERROR_DIALOG "$1"; else echo "ERROR: $1" >&2; fi
  exit 1
}

# ==========================================
# 1. HARDWARE CHECK
# ==========================================

if [ ! -e "$USB_SYS_PATH" ]; then
    log_y "No device found at ${TARGET_BUS_ID}."
    log_y "Disabling External Radio..."
    
    # Disable External Radio Only
    uci set wireless.${EXT_RADIO}.disabled='1'
    uci set pineapd.${EXT_IFACE}.disable='1'
    uci set pineapd.${EXT_IFACE}.primary='0'
    uci set pineapd.${EXT_IFACE}.inject='0'

    # NOTE: We DO NOT touch wlan1mon (Internal). 
    # It stays exactly as you left it.

    uci commit wireless
    uci commit pineapd
    
    log_g "Restarting PineAP..."
    wifi reload && service pineapd restart
    
    exit 0
fi

# Device Found - Let's load it
log_g "Device detected at ${TARGET_BUS_ID}"

# Calculate relative path for UCI
REAL_PATH=$(readlink -f "$USB_SYS_PATH" | sed 's#^/sys/devices/##')

# Configure Radio 2 (External)
uci set wireless.${EXT_RADIO}=wifi-device
uci set wireless.${EXT_RADIO}.type='mac80211'
uci set wireless.${EXT_RADIO}.path="${REAL_PATH}"
uci set wireless.${EXT_RADIO}.disabled='0'
uci set wireless.${EXT_RADIO}.band='5g'
uci set wireless.${EXT_RADIO}.channel='auto'

# Configure Interface (wlan2mon)
uci set wireless.mon_${EXT_IFACE}=wifi-iface
uci set wireless.mon_${EXT_IFACE}.device="${EXT_RADIO}"
uci set wireless.mon_${EXT_IFACE}.ifname="${EXT_IFACE}"
uci set wireless.mon_${EXT_IFACE}.mode='monitor'
uci set wireless.mon_${EXT_IFACE}.disabled='0'

uci commit wireless
log_y "Reloading WiFi driver..."
wifi reload

# Wait a bit longer for modern drivers to initialize
sleep 8 

# ==========================================
# 2. DRIVER CHECK
# ==========================================
DRV=$(ethtool -i ${EXT_IFACE} 2>/dev/null | grep driver | cut -d' ' -f2)

if [ -z "$DRV" ]; then
    err "Driver Failed to Load!
    
Device at .3 exists, but no driver attached.
Your adapter might not be supported."
fi

log_g "Driver Loaded: $DRV"

# ==========================================
# 3. PINEAP CONFIG (Mirror Internal)
# ==========================================

# 1. READ Internal Settings (Do not touch them)
# We default to '2,5' if for some reason the config is empty
CURRENT_BANDS=$(uci -q get pineapd.${INT_IFACE}.bands)
[ -z "$CURRENT_BANDS" ] && CURRENT_BANDS="2,5"

log_y "Internal Radio is using bands: $CURRENT_BANDS"
log_y "Mirroring settings to External Radio..."

# 2. CONFIGURE External (Radio 2)
# We act as a helper (Primary=0, Inject=0) but match the bands
uci set pineapd.${EXT_IFACE}.disable='0'
uci set pineapd.${EXT_IFACE}.primary='0'
uci set pineapd.${EXT_IFACE}.inject='0'
uci set pineapd.${EXT_IFACE}.hop='1'
uci set pineapd.${EXT_IFACE}.bands="$CURRENT_BANDS"

uci commit pineapd

# ==========================================
# 4. RESTART
# ==========================================
log_g "Restarting PineAP Service..."
service pineapd restart

# ==========================================
# 5. VERIFICATION (Channel Hopping Check)
# ==========================================
log_y "Verifying Channel Hopping (3 Samples)..."
sleep 10 # Let daemon start hopping

for i in 1 2 3; do
   # Grab the raw channel/freq info
   INFO=$(iw dev ${EXT_IFACE} info 2>/dev/null | grep channel | awk '{print $2}')
   [ -z "$INFO" ] && INFO="Unknown"
   log_g "Sample $i: Channel $INFO"
   sleep 1
done

log_g "DONE."
