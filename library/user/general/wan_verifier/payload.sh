#!/bin/bash
# Title: WAN Verifier
# Description: Verifies WAN IP and ISP to ensure anonymity. Alerts if on a known 'Baseline' IP.
# Author: klownmovez
# Version: 0.1
# Category: General

# ====================================================================
# Configuration
# ====================================================================
API_URL_PRIMARY="http://ip-api.com/json"
API_URL_BACKUP="http://ipinfo.io/json"
TIMEOUT=5
CACHE_FILE="/tmp/wan_guard_cache.json"
CACHE_TTL=60 # Seconds
SAVED_IP_FILE="/root/wan_verifier_saved_ip"

# Global Variables for State
IP=""
ISP=""
COUNTRY=""
REGION=""
ORG=""
STATUS_COLOR="YELLOW"

# ====================================================================
# Helper Functions
# ====================================================================

# Checks if a file is older than X seconds
is_cache_valid() {
    local file=$1
    local ttl=$2
    if [ -f "$file" ]; then
        local now=$(date +%s)
        local mod=$(date -r "$file" +%s)
        local age=$((now - mod))
        if [ $age -lt $ttl ]; then
            return 0 # Valid
        fi
    fi
    return 1 # Invalid
}

# Saves the current IP as "Baseline" to compare against
save_current_ip() {
    local ip=$1
    echo "$ip" > "$SAVED_IP_FILE"
}

# Core Logic: Fetch and Parse
fetch_data() {
    local silent=$1
    
    # Check Internet Connectivity
    if ! ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1; then
        [ -z "$silent" ] && LOG "ERROR: No Internet Connection"
        return 2 # No Internet
    fi

    local data=""
    if is_cache_valid "$CACHE_FILE" "$CACHE_TTL"; then
        [ -z "$silent" ] && LOG "Loading from cache..."
        data=$(cat "$CACHE_FILE")
    else
        [ -z "$silent" ] && LOG "Fetching WAN details..."
        
        # Try Primary API
        if data=$(curl -s -m "$TIMEOUT" "$API_URL_PRIMARY") && [ -n "$data" ]; then
            # Primary Success
            echo "$data" > "$CACHE_FILE"
        else
            # Primary Failed
            [ -z "$silent" ] && LOG "Primary API failed. Trying backup..."
            
            # Try Backup
            if data=$(curl -s -m "$TIMEOUT" "$API_URL_BACKUP") && [ -n "$data" ]; then
                # Backup Success
                echo "$data" > "$CACHE_FILE"
            else
                # Both Failed
                [ -z "$silent" ] && LOG "ERROR: All APIs Failed"
                return 3 # API Error
            fi
        fi
    fi

    # Parse (Handle multiple API formats)
    # ip-api: query, isp, countryCode, regionName
    # ipinfo.io: ip, org, country, region
    IP=$(echo "$data" | jq -r '.query // .ip // "Unknown"')
    ISP=$(echo "$data" | jq -r '.isp // .org // "Unknown"')
    COUNTRY=$(echo "$data" | jq -r '.countryCode // .country // "Unknown"')
    REGION=$(echo "$data" | jq -r '.regionName // .region // "Unknown"')
    
    return 0
}

# Core Logic: Evaluate Identity
evaluate_identity() {
    local saved_ip=""
    if [ -f "$SAVED_IP_FILE" ]; then
        saved_ip=$(cat "$SAVED_IP_FILE")
    fi

    if [ -n "$saved_ip" ] && [ "$IP" == "$saved_ip" ]; then
        STATUS_COLOR="RED"
        return 1 # MATCH
    else
        STATUS_COLOR="GREEN"
        return 0 # NO MATCH
    fi
}

# ====================================================================
# Execution Mode Handler
# ====================================================================

# Check if running in "Check Mode" (called by another script)
if [ "$1" == "--check" ] || [ "$1" == "--silent" ]; then
    SILENT_MODE=""
    [ "$1" == "--silent" ] && SILENT_MODE="yes"
    
    fetch_data "$SILENT_MODE"
    FETCH_RES=$?
    
    if [ $FETCH_RES -ne 0 ]; then
        exit $FETCH_RES
    fi
    
    evaluate_identity
    IDENTITY_RES=$?
    
    if [ -z "$SILENT_MODE" ]; then
        if [ $IDENTITY_RES -eq 1 ]; then
            echo "MATCH: $IP"
        else
            echo "NO_MATCH: $IP"
        fi
    fi
    
    exit $IDENTITY_RES
fi

# ====================================================================
# Interactive User Interface (Default Mode)
# ====================================================================

LOG "Initializing WAN Verifier..."

# Initial Fetch
fetch_data
RES=$?
if [ $RES -ne 0 ]; then
    ALERT "Initialization Failed\nCheck Internet/API"
    exit 1
fi

evaluate_identity

while true; do
    # Calculate Cache Age safely
    CACHE_AGE="0"
    if [ -f "$CACHE_FILE" ]; then
        # Try to get file modification time. 
        # Busybox date -r might behave differently, so we suppress errors.
        FILE_TIME=$(date -r "$CACHE_FILE" +%s 2>/dev/null)
        if [ -n "$FILE_TIME" ]; then
            NOW=$(date +%s)
            CACHE_AGE=$((NOW - FILE_TIME))
        fi
    fi

    # 1. Display the "Dashboard"
    LOG ""
    LOG "=== WAN VERIFIER ==="
    LOG "IP:  $IP"
    LOG "ISP: $ISP"
    LOG "Loc: $REGION, $COUNTRY"
    LOG "Updated: ${CACHE_AGE}s ago"
    LOG "------------------"
    
    # Status Line
    if [ "$STATUS_COLOR" == "RED" ]; then
        LOG "STATUS: [ MATCH ]"
        LOG "Matches Baseline IP!"
    else
        LOG "STATUS: [ NO MATCH ]"
        LOG "Differs from Baseline."
    fi

    LOG ""
    LOG "[A] Refresh Data"
    LOG "[<] Save as Baseline"
    LOG "[B] Exit"

    # 2. Wait for user interaction
    BUTTON=$(WAIT_FOR_INPUT)
    
    case "$BUTTON" in
        "A"|"ENTER")
            # Refresh Action
            LOG "Refreshing..."
            rm -f "$CACHE_FILE"
            
            fetch_data
            if [ $? -ne 0 ]; then
                LOG "ERROR: Refresh failed."
                ALERT "Refresh Failed\nCheck Internet."
            else
                evaluate_identity
            fi
            ;;
            
        "LEFT")
            # Save Action
            save_current_ip "$IP"
            LOG "Saved $IP as Baseline."
            STATUS_COLOR="RED"
            ;;
            
        "B")
            # Exit Action
            LOG "Exiting..."
            exit 0
            ;;
            
        *)
            # Ignore other buttons
            ;;
    esac
done
