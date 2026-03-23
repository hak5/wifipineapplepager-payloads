#!/bin/bash
# Title:                SpeedTest
# Description:          Performs an internet speed test and logs the results
# Author:               billyjbryant
# Version:              1.0

# Options
LOOTDIR=/root/loot/speedtest
SPEEDTEST_CLI_PATH=/usr/local/bin/speedtest-cli
SPEEDTEST_CLI_URL="https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py"

# Check if pager has a valid IP address (not loopback, not 172.16.52.0/24)
is_valid_ip() {
    local ip=$1
    if [ -z "$ip" ] || [ "$ip" = "127.0.0.1" ]; then
        return 1
    fi
    # Exclude 172.16.52.0/24 subnet (Pineapple management network)
    if echo "$ip" | grep -qE '^172\.16\.52\.'; then
        return 1
    fi
    return 0
}

has_ip=false
if command -v hostname >/dev/null 2>&1; then
    ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
    if is_valid_ip "$ip_addr"; then
        has_ip=true
    fi
fi

if [ "$has_ip" = false ]; then
    # Try alternative method using ip command
    if command -v ip >/dev/null 2>&1; then
        for ip_addr in $(ip -4 addr show | grep -E 'inet [0-9]' | awk '{print $2}' | cut -d'/' -f1); do
            if is_valid_ip "$ip_addr"; then
                has_ip=true
                break
            fi
        done
    fi
fi

if [ "$has_ip" = false ]; then
    LOG red "ERROR: No valid IP detected"
    ERROR_DIALOG "No valid IP detected. Enable client mode and connect to a network."
    LOG red "Exiting - client mode required"
    exit 1
fi

# Check for internet connectivity
LOG cyan "Probing connectivity..."
if ! ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1; then
    LOG red "ERROR: No route to host"
    ERROR_DIALOG "No route to host. Make sure the pager has internet access to perform a speed test."
    LOG red "Exiting - internet connection required"
    exit 1
fi

LOG green "Link established..."

LOG blue "Checking dependencies..."
# Check if Python is available
if ! command -v python >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    LOG yellow "Python missing. Installing..."
    spinner_id=$(START_SPINNER "Installing")
    opkg update
    if ! opkg install python3 python3-pip; then
        STOP_SPINNER $spinner_id
        LOG red "ERROR: Python install failed"
        ERROR_DIALOG "Python install failed. Try to install it manually via opkg."
        exit 1
    fi
    STOP_SPINNER $spinner_id
    LOG green "Python installed"
fi

# Determine Python command
PYTHON_CMD=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_CMD="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_CMD="python"
else
    LOG red "ERROR: Python unavailable"
    ERROR_DIALOG "Python unavailable. Try to install it manually via opkg."
    exit 1
fi

# Check if speedtest-cli is installed, if not download it
if [ ! -f "$SPEEDTEST_CLI_PATH" ]; then
    LOG yellow "speedtest-cli not found. Downloading..."
    spinner_id=$(START_SPINNER "Downloading")
    mkdir -p "$(dirname "$SPEEDTEST_CLI_PATH")"
    
    if command -v wget >/dev/null 2>&1; then
        if ! wget -q --no-check-certificate "$SPEEDTEST_CLI_URL" -O "$SPEEDTEST_CLI_PATH"; then
            STOP_SPINNER $spinner_id
            LOG red "ERROR: Download failed"
            ERROR_DIALOG "Download failed. Make sure the pager has access to the internet."
            exit 1
        fi
    elif command -v curl >/dev/null 2>&1; then
        if ! curl -s -k -o "$SPEEDTEST_CLI_PATH" "$SPEEDTEST_CLI_URL"; then
            STOP_SPINNER $spinner_id
            LOG red "ERROR: Download failed"
            ERROR_DIALOG "Download failed. Make sure the pager has access to the internet."
            exit 1
        fi
    else
        STOP_SPINNER $spinner_id
        LOG red "ERROR: No download tool available"
        ERROR_DIALOG "No download tool available. Try to install wget or curl."
        exit 1
    fi
    
    chmod +x "$SPEEDTEST_CLI_PATH"
    STOP_SPINNER $spinner_id
    LOG green "speedtest-cli acquired"
else
    LOG green "speedtest-cli cached at $SPEEDTEST_CLI_PATH"
fi
LOG green "All systems go..."

# Check if user wants loot generated (stored in config)
PAYLOAD_NAME="speedtest"
generate_loot=$(PAYLOAD_GET_CONFIG "$PAYLOAD_NAME" "generate_loot" 2>/dev/null)

# If not configured, ask user on first run
if [ -z "$generate_loot" ]; then
    LOG cyan "First run detected"
    if CONFIRMATION_DIALOG "Generate loot files with test results?"; then
        generate_loot="yes"
        PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" "generate_loot" "yes"
        LOG green "Loot generation enabled"
    else
        generate_loot="no"
        PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" "generate_loot" "no"
        LOG yellow "Loot generation disabled"
    fi
fi

# Create loot destination if needed (only if loot generation is enabled)
if [ "$generate_loot" = "yes" ]; then
    mkdir -p $LOOTDIR
    lootfile=$LOOTDIR/$(date -Is)_speedtest.txt
    
    # Gather network information
    LOG cyan "Gathering network intel..."
    spinner_id=$(START_SPINNER "Gathering")
{
    echo "=== NETWORK INFORMATION ==="
    echo "Timestamp: $(date -Is)"
    echo ""
    
    # Get SSID
    ssid=""
    if command -v iwinfo >/dev/null 2>&1; then
        wifi_info=$(iwinfo wlan0cli info 2>/dev/null)
        if [ -n "$wifi_info" ]; then
            essid_line=$(echo "$wifi_info" | grep "ESSID:")
            if echo "$essid_line" | grep -q '"'; then
                ssid=$(echo "$essid_line" | sed 's/.*ESSID: "\([^"]*\)".*/\1/')
            else
                ssid=$(echo "$essid_line" | sed 's/.*ESSID: \([^ ]*\).*/\1/')
            fi
            if [ -z "$ssid" ] || [ "$ssid" = "unknown" ] || [ "$ssid" = "off/any" ]; then
                ssid="Not connected"
            fi
        else
            ssid="Not connected"
        fi
    else
        ssid="Unknown (iwinfo not available)"
    fi
    echo "SSID: $ssid"
    
    # Get local IP (exclude loopback and management network)
    local_ip=""
    if command -v hostname >/dev/null 2>&1; then
        for ip in $(hostname -I 2>/dev/null); do
            if is_valid_ip "$ip"; then
                local_ip="$ip"
                break
            fi
        done
    fi
    if [ -z "$local_ip" ] && command -v ip >/dev/null 2>&1; then
        for ip in $(ip -4 addr show | grep -E 'inet [0-9]' | awk '{print $2}' | cut -d'/' -f1); do
            if is_valid_ip "$ip"; then
                local_ip="$ip"
                break
            fi
        done
    fi
    [ -z "$local_ip" ] && local_ip="Unknown"
    echo "Local IP: $local_ip"
    
    # Get public IP and geo info
    echo ""
    echo "=== PUBLIC IP & GEOLOCATION ==="
    if command -v curl >/dev/null 2>&1; then
        geo_data=$(curl -s -k "http://ip-api.com/json/?fields=status,message,query,country,countryCode,region,regionName,city,zip,lat,lon,timezone,isp,org,as" 2>/dev/null)
        if [ -n "$geo_data" ]; then
            public_ip=$(echo "$geo_data" | grep -o '"query":"[^"]*"' | cut -d'"' -f4)
            country=$(echo "$geo_data" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
            city=$(echo "$geo_data" | grep -o '"city":"[^"]*"' | cut -d'"' -f4)
            lat=$(echo "$geo_data" | grep -o '"lat":[0-9.-]*' | cut -d':' -f2)
            lon=$(echo "$geo_data" | grep -o '"lon":[0-9.-]*' | cut -d':' -f2)
            isp=$(echo "$geo_data" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)
            
            if [ -n "$public_ip" ] && [ "$public_ip" != "null" ]; then
                echo "Public IP: $public_ip"
                [ -n "$country" ] && [ "$country" != "null" ] && echo "Country: $country"
                [ -n "$city" ] && [ "$city" != "null" ] && echo "City: $city"
                if [ -n "$lat" ] && [ "$lat" != "null" ] && [ -n "$lon" ] && [ "$lon" != "null" ]; then
                    echo "Coordinates: $lat, $lon"
                fi
                [ -n "$isp" ] && [ "$isp" != "null" ] && echo "ISP: $isp"
            else
                echo "Public IP: Failed to retrieve"
            fi
        else
            # Fallback to simple IP lookup
            public_ip=$(curl -s -k "http://ifconfig.me" 2>/dev/null || curl -s -k "http://icanhazip.com" 2>/dev/null)
            if [ -n "$public_ip" ]; then
                echo "Public IP: $public_ip"
                echo "Geolocation: Not available"
            else
                echo "Public IP: Failed to retrieve"
            fi
        fi
    elif command -v wget >/dev/null 2>&1; then
        public_ip=$(wget -qO- --no-check-certificate "http://ifconfig.me" 2>/dev/null || wget -qO- --no-check-certificate "http://icanhazip.com" 2>/dev/null)
        if [ -n "$public_ip" ]; then
            echo "Public IP: $public_ip"
            echo "Geolocation: Not available (curl required for geo)"
        else
            echo "Public IP: Failed to retrieve"
        fi
    else
        echo "Public IP: Not available (no download tool)"
    fi
    
    echo ""
    echo "=== SPEED TEST RESULTS ==="
} > "$lootfile"
    STOP_SPINNER $spinner_id
    
    LOG green "Network intel gathered"
    LOG blue "Results will be dumped to ${LOOTDIR}"
else
    LOG blue "Loot generation disabled (results will only be displayed)"
fi

LOG cyan "Starting speed test..."

# Check if user wants to skip upload test (stored in config)
skip_upload=$(PAYLOAD_GET_CONFIG "$PAYLOAD_NAME" "skip_upload" 2>/dev/null)

# Run speedtest using speedtest-cli
speedtest_output=$(mktemp)
spinner_id=$(START_SPINNER "Testing")

# Run speedtest-cli with pipefail to catch errors in pipeline
# --no-pre-allocate prevents memory pre-allocation which can cause OOM kills on the pager.
set -o pipefail
if [ "$skip_upload" = "yes" ]; then
    LOG blue "Upload test disabled (configured)"
    $PYTHON_CMD "$SPEEDTEST_CLI_PATH" --simple --no-pre-allocate --no-upload 2>&1 | tee "$speedtest_output" | tr '\n' '\0' | xargs -0 -n 1 LOG
else
    $PYTHON_CMD "$SPEEDTEST_CLI_PATH" --simple --no-pre-allocate 2>&1 | tee "$speedtest_output" | tr '\n' '\0' | xargs -0 -n 1 LOG
fi
speedtest_exit=$?
set +o pipefail
STOP_SPINNER $spinner_id

# Check if process was killed
was_killed=false
if [ $speedtest_exit -eq 137 ] || [ $speedtest_exit -eq 130 ]; then
    was_killed=true
elif [ $speedtest_exit -ne 0 ]; then
    if grep -q "Killed" "$speedtest_output" 2>/dev/null; then
        was_killed=true
    fi
fi

if [ "$was_killed" = true ]; then
    LOG yellow "WARNING: Speed test was killed (likely OOM)"
    if [ "$generate_loot" = "yes" ]; then
        echo "" >> "$lootfile"
        echo "NOTE: Speed test was killed during execution" >> "$lootfile"
    fi
fi

# Parse speedtest results for alert before removing temp file
speedtest_section=""
if [ "$generate_loot" = "yes" ]; then
    cat "$speedtest_output" >> "$lootfile"
    speedtest_section=$(sed -n '/=== SPEED TEST RESULTS ===/,$p' "$lootfile")
else
    # If loot is disabled, parse from the speedtest output directly
    speedtest_section=$(cat "$speedtest_output" 2>/dev/null || echo "")
fi
rm -f "$speedtest_output"

LOG green "\nSpeed test complete"
if [ "$generate_loot" = "yes" ] && [ -s "$lootfile" ]; then
    LOG green "Results dumped to: $lootfile"
fi

# Extract geolocation (only if loot is enabled)
geo_section=""
city=""
country=""
coordinates=""
if [ "$generate_loot" = "yes" ]; then
    geo_section=$(sed -n '/=== PUBLIC IP & GEOLOCATION ===/,/=== SPEED TEST RESULTS ===/p' "$lootfile")
    city=$(echo "$geo_section" | grep -i "City:" | sed 's/.*City:[[:space:]]*//' | head -n 1)
    country=$(echo "$geo_section" | grep -i "Country:" | sed 's/.*Country:[[:space:]]*//' | head -n 1)
    coordinates=$(echo "$geo_section" | grep -i "Coordinates:" | sed 's/.*Coordinates:[[:space:]]*//' | head -n 1)
fi

ping_line=$(echo "$speedtest_section" | grep -i "ping:" | head -n 1)
download_line=$(echo "$speedtest_section" | grep -i "download:" | head -n 1)
upload_line=$(echo "$speedtest_section" | grep -i "upload:" | head -n 1)

# Build alert message
alert_msg="Speed Test Results\n(speedtest.net)\n\n"

# Add geolocation if available
if [ -n "$city" ] && [ -n "$country" ]; then
    alert_msg="${alert_msg}Location: ${city}, ${country}\n\n"
elif [ -n "$coordinates" ]; then
    alert_msg="${alert_msg}Location: ${coordinates}\n\n"
elif [ -n "$city" ]; then
    alert_msg="${alert_msg}Location: ${city}\n\n"
elif [ -n "$country" ]; then
    alert_msg="${alert_msg}Location: ${country}\n\n"
fi

if [ -n "$ping_line" ]; then
    ping_clean=$(echo "$ping_line" | sed 's/.*Ping:[[:space:]]*//' | tr -d '\r\n')
    alert_msg="${alert_msg}Ping: ${ping_clean}\n"
fi

if [ -n "$download_line" ]; then
    download_clean=$(echo "$download_line" | sed 's/.*Download:[[:space:]]*//' | tr -d '\r\n')
    alert_msg="${alert_msg}Download: ${download_clean}\n"
fi

if [ -n "$upload_line" ]; then
    upload_clean=$(echo "$upload_line" | sed 's/.*Upload:[[:space:]]*//' | tr -d '\r\n')
    alert_msg="${alert_msg}Upload: ${upload_clean}"
fi

if [ -n "$ping_line" ] || [ -n "$download_line" ] || [ -n "$upload_line" ]; then
    ALERT "$alert_msg"
else
    LOG yellow "WARNING: No speed results found in output"
    ERROR_DIALOG "Speed test completed but no results found. Check logs for details."
fi
