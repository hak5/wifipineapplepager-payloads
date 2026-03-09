#!/bin/bash
# Title: IP_SUBNETTER_GETTER
# Author: THENRGLABS
# Description: Public IP, ARP discovery, CVE enumeration, detailed vulnerability scans, and risk level assessment
# Version: 1.0

LOOT_DIR="/root/loot/Smart_scanner"
mkdir -p "$LOOT_DIR"

# --- Public IP Detection ---
LOG "Detecting public IP address..."

PUBLIC_IP=""

# Try multiple services (fail-safe)
for svc in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://checkip.amazonaws.com"
do
    PUBLIC_IP=$(curl -s --max-time 5 "$svc")
    [ -n "$PUBLIC_IP" ] && break
done

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
PUBLIC_IP_FILE="$LOOT_DIR/public_ip_$TIMESTAMP.txt"

if echo "$PUBLIC_IP" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    LOG "Public IP detected: $PUBLIC_IP"
    echo "Public IP: $PUBLIC_IP" > "$PUBLIC_IP_FILE"
    LOG "Saved to $PUBLIC_IP_FILE"
else
    LOG "Public IP detection failed (no internet or blocked)"
    echo "Public IP: Not detected" > "$PUBLIC_IP_FILE"
fi

# --- Detect active interface & IP ---
ROUTE_INFO=$(ip route get 8.8.8.8 2>/dev/null)
ACTIVE_IFACE=$(echo "$ROUTE_INFO" | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}')
LOCAL_IP=$(echo "$ROUTE_INFO" | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')

[ -z "$ACTIVE_IFACE" ] || [ -z "$LOCAL_IP" ] && exit 1

NET_PREFIX=$(echo "$LOCAL_IP" | cut -d '.' -f 1-3)
TARGET_NET="${NET_PREFIX}.0/24"

LOG "Interface: $ACTIVE_IFACE"
LOG "Target network: $TARGET_NET"

# --- Confirm discovery ---
resp=$(CONFIRMATION_DIALOG "Do you want to run ARP discovery on $TARGET_NET?")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR) exit 1 ;;  # Exit if there's an error with the dialog
esac

if [ "$resp" = "$DUCKYSCRIPT_USER_DENIED" ]; then
    LOG "User denied ARP discovery. Skipping ARP discovery and proceeding with basic Nmap scan."
    # Skip ARP and just do a basic Nmap scan (ping sweep)
    $BUF nmap -sn "$TARGET_NET" -T4 -oN "$LOOT_DIR/basic_nmap_scan_$TIMESTAMP.txt"
    LOG "Basic Nmap scan completed."
else
    LOG "Starting ARP discovery..."
    # Proceed with ARP discovery if Yes
    $BUF nmap -PR -sn -T4 -e "$ACTIVE_IFACE" "$TARGET_NET" 2>&1 | tee "$LOOT_DIR/arp_discovery_$TIMESTAMP.txt" \
    | while read -r line; do
        echo "$line" | grep -q "Nmap scan report for" && LOG "$line"
    done
fi

LOG "Network discovery complete. Proceeding with port scanning."

# --- Confirm scan depth (fast or full) ---
resp=$(CONFIRMATION_DIALOG "Run a fast (top ports) or full port scan? (Fast = Top 100 ports, Full = All ports)")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR) exit 1 ;;  # Exit if there's an error with the dialog
esac

if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
    PORT_OPTS="--top-ports 100"
    LOG "Using top 100 ports for scanning."
else
    PORT_OPTS="-p-"
    LOG "Using full port range for scanning."
fi

PORT_FILE="$LOOT_DIR/open_ports_$TIMESTAMP.txt"
$BUF nmap -sS -T4 --open $PORT_OPTS -iL "$LOOT_DIR/live_hosts_$TIMESTAMP.txt" 2>&1 \
| tee "$PORT_FILE" \
| while read -r line; do
    echo "$line" | grep -E "Nmap scan report for|open" && LOG "$line"
done

LOG "Port scan completed."

# --- CVE Enumeration ---
resp=$(CONFIRMATION_DIALOG "Do you want to run CVE enumeration on the open ports?")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR) exit 1 ;;
esac

if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
    CVE_FILE="$LOOT_DIR/cve_enum_$TIMESTAMP.txt"
    LOG "Starting detailed CVE enumeration..."

    # Enhanced CVE Detection
    $BUF nmap -sV --script vuln,ssl*,smb* -T4 -iL "$LOOT_DIR/live_hosts_$TIMESTAMP.txt" 2>&1 \
    | tee "$CVE_FILE" \
    | while read -r line; do
        echo "$line" | grep -E "CVE-|VULNERABLE|State:" && LOG "$line"
    done

    LOG "CVE enumeration completed"
    LOG "CVE results saved to $CVE_FILE"
else
    LOG "User skipped CVE enumeration"
fi

# --- Final Summary ---
LOG "=============================="
LOG " RECON SUMMARY"
LOG "=============================="

for HOST in $(cat "$LOOT_DIR/live_hosts_$TIMESTAMP.txt"); do
    LOG "Host: $HOST"

    # MAC + Vendor
    MAC_LINE=$(grep "$HOST" "$LOOT_DIR/arp_discovery_$TIMESTAMP.txt" | grep "MAC Address" | head -n 1)
    if [ -n "$MAC_LINE" ]; then
        MAC=$(echo "$MAC_LINE" | awk '{print $3}')
        VENDOR=$(echo "$MAC_LINE" | cut -d '(' -f2 | cut -d ')' -f1)
        LOG "MAC: $MAC ($VENDOR)"
    else
        LOG "MAC: Unknown"
    fi

    # Open ports
    PORTS=$(grep -A5 "$HOST" "$PORT_FILE" | grep "/tcp.*open" | awk -F/ '{print $1}' | tr '\n' ',' | sed 's/,$//')
    LOG "Open ports: $PORTS"

    # CVEs
    CVES=$(grep -A5 "$HOST" "$CVE_FILE" | grep "CVE-" | sort -u | tr '\n' ',' | sed 's/,$//')
    LOG "Known CVEs: $CVES"
done

LOG "Recon summary complete"
LOG "Payload finished successfully"
