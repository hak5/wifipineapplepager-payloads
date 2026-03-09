#!/bin/bash
# Title: SMB Spy
# Author: Hackazillarex
# Description: Discovers SMB hosts using nmap and logs results with next-step suggestions
# Version: 1.0

#############################
# Setup loot
#############################
LOOT_BASE="/root/loot/smb_discovery"
mkdir -p "$LOOT_BASE"

TS=$(date +%F_%H-%M-%S)
OUTFILE="$LOOT_BASE/smb_hosts_$TS.txt"
RAWFILE="$LOOT_BASE/nmap_raw_$TS.txt"

touch "$OUTFILE" "$RAWFILE" || {
    LOG "ERROR: Cannot write to /root"
    exit 1
}

log_both() {
    LOG "$1"
    echo "$1" >> "$OUTFILE"
}

############################
# Interface picker
############################
LOG "Launching interface picker..."
iface_pick=$(NUMBER_PICKER "1 = wlan0cli, 2 = eth1 (USB Ethernet)" 1)

case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG "User cancelled or error"
        exit 1
        ;;
esac

case "$iface_pick" in
    1) IFACE="wlan0cli" ;;
    2) IFACE="eth1" ;;
    *)
        LOG "Invalid selection"
        exit 1
        ;;
esac

log_both "Using interface: $IFACE"

############################
# Handle eth1 (USB Ethernet)
############################
if [ "$IFACE" = "eth1" ]; then

    # Verify interface exists
    if ! ip link show eth1 >/dev/null 2>&1; then
        log_both "eth1 not present — USB Ethernet adapter not detected"
        exit 1
    fi

    log_both "Bringing eth1 up"
    ip link set eth1 up

    log_both "Requesting DHCP lease on eth1"
    udhcpc -i eth1 -q || {
        log_both "DHCP failed on eth1"
        exit 1
    }

    # Give kernel a moment to install routes
    sleep 2
fi

############################
# Determine CIDR
############################
CIDR=$(ip -4 route show dev "$IFACE" | awk '/scope link/ {print $1}')

if [ -z "$CIDR" ]; then
    log_both "Failed to obtain IPv4 network on $IFACE"
    exit 1
fi

log_both "Detected network: $CIDR"
log_both "--------------------------------"
log_both "Starting SMB discovery scan..."

############################
# SMB discovery scan
############################
nmap -p 445 -n "$CIDR" > "$RAWFILE" 2>&1

############################
# Parse nmap results
############################
CURRENT_IP=""
FOUND=0
SMB_IPS=()

while read -r line; do
    if echo "$line" | grep -q "Nmap scan report for"; then
        CURRENT_IP=$(echo "$line" | awk '{print $NF}')
    fi

    if echo "$line" | grep -q "445/tcp open"; then
        log_both ""
        log_both "SMB OPEN: $CURRENT_IP"
        SMB_IPS+=("$CURRENT_IP")
        FOUND=1
    fi

    if echo "$line" | grep -q "MAC Address" && [ "$FOUND" -eq 1 ]; then
        MAC=$(echo "$line" | cut -d '(' -f1 | awk '{print $3}')
        VENDOR=$(echo "$line" | sed 's/.*(//;s/)//')
        log_both "  MAC: $MAC"
        log_both "  Vendor: $VENDOR"
        FOUND=0
    fi
done < "$RAWFILE"

############################
# Next-step suggestions
############################
log_both ""
log_both "================================"
log_both "NEXT STEP SUGGESTIONS"
log_both "================================"

if [ "${#SMB_IPS[@]}" -eq 0 ]; then
    log_both "No SMB hosts found — no follow-up actions suggested."
else
    for ip in "${SMB_IPS[@]}"; do
        log_both ""
        log_both "Target: $ip"
        log_both "  smbclient -L //$ip -U user"
        log_both "  smbmap -H $ip -u user -p pass"
        log_both "  crackmapexec smb $ip"
    done
fi

############################
# Finish
############################
log_both ""
log_both "Scan complete"
log_both "Loot saved to:"
log_both "$OUTFILE"
log_both "$RAWFILE"

exit 0
