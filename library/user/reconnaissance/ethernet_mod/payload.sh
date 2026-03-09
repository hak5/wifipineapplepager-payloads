#!/bin/bash
# Title: Ethernet Mod Nmap Recon Payload
# Author: Hackazillarex
# Description: Gateway + 5 Host Recon (Top 10 Ports) - Compatible with non GMO (Glitch Mod Only) 
# Version: 2.0

ETH_IF="eth1"
USB_ETH_ID="0bda:8152"

LOOT_DIR="/root/loot/ethernet_nmap"
TIMESTAMP=$(date +%F_%H%M%S)
LOOT_FILE="$LOOT_DIR/ethernet_nmap_$TIMESTAMP.txt"
LOG_VIEWER="/root/payloads/user/general/log_viewer/payload.sh"

LOG blue "Starting Ethernet NMAP Recon"
LOG green "------------------------------"

# ------------------------------------------------------------------
# USB Ethernet Adapter Check
# ------------------------------------------------------------------

if ! lsusb 2>/dev/null | grep -qi "$USB_ETH_ID"; then
    LOG red "USB Ethernet Adapter NOT Found"

    resp=$(CONFIRMATION_DIALOG \
        "USB Adapter not found or non-Hak5 mod detected. Proceed anyway?")

    case $? in
        $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            LED FAIL; exit 1 ;;
    esac

    [ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ] && { LED FAIL; exit 1; }
fi

LOG blue "Bringing up Ethernet and Gathering Network Info"

# ------------------------------------------------------------------
# Bring up Ethernet
# ------------------------------------------------------------------

ip link set "$ETH_IF" up || { LED FAIL; exit 1; }
udhcpc -i "$ETH_IF" -q || { LED FAIL; exit 1; }

# ------------------------------------------------------------------
# Network Info
# ------------------------------------------------------------------

GATEWAY=$(ip route show dev "$ETH_IF" | awk '/default/ {print $3}')
NET=$(ip -4 route show dev "$ETH_IF" | awk '/scope link/ {print $1}')

[ -z "$GATEWAY" ] || [ -z "$NET" ] && { LED FAIL; exit 1; }

mkdir -p "$LOOT_DIR"

PUBLIC_IP=$(nslookup myip.opendns.com resolver1.opendns.com 2>/dev/null \
           | awk '/Address: / {print $2}' | tail -n1)
[ -z "$PUBLIC_IP" ] && PUBLIC_IP="unavailable"

# ------------------------------------------------------------------
# Loot Header
# ------------------------------------------------------------------

cat <<EOF > "$LOOT_FILE"
Ethernet Limited Recon Scan
===========================
Timestamp : $(date)
Interface : $ETH_IF
Gateway   : $GATEWAY
Subnet    : $NET
Public IP : $PUBLIC_IP
Hostname  : $(hostname)

--- Live Host Discovery (Gateway + 5 Hosts) ---
EOF

# ------------------------------------------------------------------
# Host Discovery (Gateway + 4 Others)
# ------------------------------------------------------------------

LOG blue "Discovering Hosts"

HOSTS=$(nmap -sn -PR -n -e "$ETH_IF" "$NET" \
        | awk '/Nmap scan report for/ {print $NF}' \
        | grep -v "^$GATEWAY$" \
        | head -n 4)

TARGETS="$GATEWAY $HOSTS"

for h in $TARGETS; do
    echo "$h" >> "$LOOT_FILE"
done

# ------------------------------------------------------------------
# FAST SINGLE-PASS PORT SCAN (TOP 10 PORTS)
# ------------------------------------------------------------------

LOG blue "Fast scanning top 10 ports (single-pass)"

SCAN_OUTPUT=$(nmap -n -Pn -T5 \
    --min-rate 3000 \
    --max-retries 1 \
    --host-timeout 20s \
    --top-ports 10 \
    $TARGETS)

cat <<EOF >> "$LOOT_FILE"

==============================
Per-Host Open Port Results
==============================
EOF

CURRENT=""

echo "$SCAN_OUTPUT" | while read -r line; do
    if [[ "$line" == Nmap\ scan\ report* ]]; then
        CURRENT=$(echo "$line" | awk '{print $NF}')
        echo "" >> "$LOOT_FILE"
        echo "--- Open Ports for $CURRENT ---" >> "$LOOT_FILE"
        FOUND=0
    elif [[ "$line" =~ ^[0-9]+/tcp ]]; then
        echo "$line" >> "$LOOT_FILE"
        FOUND=1
    elif [[ "$line" == "" && "$FOUND" == "0" ]]; then
        :
    fi
done

# ------------------------------------------------------------------
# Wrap Up
# ------------------------------------------------------------------

LOG blue "Recon complete — launching Log Viewer"

[ -f "$LOG_VIEWER" ] && source "$LOG_VIEWER"

LED FINISH
exit 0
