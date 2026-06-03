#!/bin/bash
# USB PHY Auto-Bind for WiFi Pineapple Pager
# Author: Notorious Squirrel
# Purpose: Detect USB PHY and create wlan2mon automatically

set -e

TITLE() { echo "=== $* ==="; }
LOG()   { echo "[USB-AUTO] $*"; }

MON_IFACE="wlan2mon"

TITLE "USB PHY Auto-Bind"

# ----------------------------
# Step 1: List PHYs
# ----------------------------
LOG "Enumerating PHY devices..."
PHYS=$(ls /sys/class/ieee80211)

if [ -z "$PHYS" ]; then
    LOG "No PHY devices found"
    exit 1
fi

# ----------------------------
# Step 2: Identify internal PHYs
# ----------------------------
INTERNAL_PHYS=()
for iface in wlan0 wlan1 wlan0mon wlan1mon; do
    if iw dev "$iface" info >/dev/null 2>&1; then
        PHY=$(iw dev "$iface" info | awk '/wiphy/{print "phy"$2}')
        INTERNAL_PHYS+=("$PHY")
    fi
done

LOG "Internal PHYs detected: ${INTERNAL_PHYS[*]:-none}"

# ----------------------------
# Step 3: Find USB PHY
# ----------------------------
USB_PHY=""

for phy in $PHYS; do
    skip=0
    for intphy in "${INTERNAL_PHYS[@]}"; do
        [ "$phy" = "$intphy" ] && skip=1
    done
    [ "$skip" -eq 0 ] && USB_PHY="$phy"
done

if [ -z "$USB_PHY" ]; then
    LOG "No USB PHY detected"
    exit 1
fi

LOG "USB PHY identified as: $USB_PHY"

# ----------------------------
# Step 4: Remove old monitor iface if present
# ----------------------------
if iw dev "$MON_IFACE" info >/dev/null 2>&1; then
    LOG "Removing existing $MON_IFACE"
    ip link set "$MON_IFACE" down 2>/dev/null || true
    iw dev "$MON_IFACE" del 2>/dev/null || true
fi

# ----------------------------
# Step 5: Create monitor interface
# ----------------------------
LOG "Creating monitor interface $MON_IFACE on $USB_PHY"
iw phy "$USB_PHY" interface add "$MON_IFACE" type monitor

ip link set "$MON_IFACE" up

# ----------------------------
# Step 6: Verify
# ----------------------------
if iw dev "$MON_IFACE" info >/dev/null 2>&1; then
    LOG "SUCCESS: $MON_IFACE is UP on $USB_PHY"
else
    LOG "FAILED: Monitor interface not created"
    exit 1
fi

TITLE "USB PHY Auto-Bind Complete"
exit 0

