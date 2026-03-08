#!/bin/bash
# Title: Curly - Web Recon & Vuln Scanner
# Description: Curl-based web reconnaissance and vulnerability testing for pentesting and bug bounty hunting
# Author: curtthecoder
# Version: 3.8

# === CONFIG ===
LOOTDIR=/root/loot/curly
INPUT=/dev/input/event0
TIMEOUT=10
DISCORD_WEBHOOK=""  # Set your Discord webhook URL here
WPSCAN_API_TOKEN="" # Free API token from https://wpscan.com/register

# Severity tracking
CRITICAL_FINDINGS=0
HIGH_FINDINGS=0
MEDIUM_FINDINGS=0
LOW_FINDINGS=0
INFO_FINDINGS=0

# === CLEANUP ===
cleanup() {
    led_off 2>/dev/null
    dd if=$INPUT of=/dev/null bs=16 count=200 iflag=nonblock 2>/dev/null
    sleep 0.2
}

trap cleanup EXIT INT TERM

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

# === SOUNDS ===
play_scan() { RINGTONE "scan:d=4,o=5,b=180:c,e,g" & }
play_found() { RINGTONE "found:d=8,o=6,b=200:c,e,g,c7" & }
play_complete() { RINGTONE "xp" & }

# === DISCORD NOTIFICATION ===
send_to_discord() {
    # Debug logging
    LOG "Discord function called"
    LOG "Webhook set: $([ -n "$DISCORD_WEBHOOK" ] && echo "YES" || echo "NO")"
    LOG "Loot file exists: $([ -f "$LOOTFILE" ] && echo "YES" || echo "NO")"

    if [ -z "$DISCORD_WEBHOOK" ]; then
        LOG "No Discord webhook configured, skipping"
        return
    fi

    if [ ! -f "$LOOTFILE" ]; then
        LOG "Loot file not found: $LOOTFILE"
        return
    fi

    LOG "Sending results to Discord..."

        # Build header message with proper JSON escaping
        local timestamp=$(date)
        local header_json=$(cat <<EOF
{
  "content": "**🎯 Curly Scan Complete**\n\`\`\`\nTarget: $TARGET_URL\nMode: $SCAN_MODE\nTime: $timestamp\n\`\`\`"
}
EOF
)

        # Send header
        LOG "Sending header message..."
        local header_response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -H "Content-Type: application/json" \
             -d "$header_json" \
             "$DISCORD_WEBHOOK" 2>&1)
        local header_code=$(echo "$header_response" | grep "HTTP_CODE:" | cut -d: -f2)
        LOG "Header response code: $header_code"

        # Use awk to extract findings with details
        LOG "Extracting findings from loot file..."
        local findings=$(awk '
            /^\[\+\]/ {
                if ($0 ~ /IP GEOLOCATION|WAF.*CDN|TECHNOLOGY/) {
                    in_info_section=1
                    print
                    next
                } else {
                    in_info_section=0
                    next
                }
            }
            in_info_section {
                print
                next
            }
            /^\[!\]|^\[!!!\]/ {
                print
                found_marker=1
                detail_count=0
                next
            }
            found_marker && detail_count < 5 {
                if (/^[[:space:]]*$/) {
                    found_marker=0
                    next
                }
                if (/^\[\+\]|^\[!\]|^\[!!!\]/) {
                    found_marker=0
                    next
                }
                print
                detail_count++
                next
            }
            /^\[\+\]|^\[!\]|^\[!!!\]/ {
                found_marker=0
            }
        ' "$LOOTFILE")

        local findings_lines=$(echo -e "$findings" | wc -l | tr -d ' ')
        LOG "Extracted $findings_lines lines of findings"

        if [ -n "$findings" ]; then
            LOG "Sending findings to Discord..."

            # Write findings to temp file for upload
            local tmpfile="/tmp/curly_results_$$"
            echo "$findings" > "$tmpfile"

            # Upload as file attachment with message
            LOG "Uploading results file..."
            local upload_response=$(curl -s -w "\nHTTP:%{http_code}" \
                 -F "content=**📊 Scan Results**" \
                 -F "file=@$tmpfile;filename=results.txt" \
                 "$DISCORD_WEBHOOK" 2>&1)
            local upload_code=$(echo "$upload_response" | grep "HTTP:" | cut -d: -f2)
            LOG "Upload response: $upload_code"

            # Cleanup
            rm -f "$tmpfile"

            LOG "Results sent to Discord!"
        else
            # No findings, send summary
            LOG "No findings extracted, sending summary..."
            local summary_json='{"content":"**Scan Complete** - No significant findings"}'
            curl -s -H "Content-Type: application/json" \
                 -d "$summary_json" \
                 "$DISCORD_WEBHOOK" >/dev/null 2>&1
            LOG "Summary sent to Discord!"
        fi
}

# === CORE FUNCTIONS ===

# Initialize loot directory
init_loot() {
    mkdir -p "$LOOTDIR"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    LOOTFILE="$LOOTDIR/${TARGET_HOST}_${TIMESTAMP}.txt"
    echo "=== CURLY WEB RECON SCAN ===" > "$LOOTFILE"
    echo "Target: $TARGET_URL" >> "$LOOTFILE"
    echo "Date: $(date)" >> "$LOOTFILE"
    echo "================================" >> "$LOOTFILE"
    echo "" >> "$LOOTFILE"
}

# Log to both screen and file
log_result() {
    local msg="$1"
    echo "$msg" >> "$LOOTFILE"
    LOG "$msg"
}

# Log finding with severity tracking
log_finding() {
    local severity="$1"  # CRITICAL, HIGH, MEDIUM, LOW, INFO
    local msg="$2"

    case "$severity" in
        CRITICAL)
            CRITICAL_FINDINGS=$((CRITICAL_FINDINGS + 1))
            log_result "[!!!] $msg"
            ;;
        HIGH)
            HIGH_FINDINGS=$((HIGH_FINDINGS + 1))
            log_result "[!!] $msg"
            ;;
        MEDIUM)
            MEDIUM_FINDINGS=$((MEDIUM_FINDINGS + 1))
            log_result "[!] $msg"
            ;;
        LOW)
            LOW_FINDINGS=$((LOW_FINDINGS + 1))
            log_result "[-] $msg"
            ;;
        INFO)
            INFO_FINDINGS=$((INFO_FINDINGS + 1))
            log_result "[*] $msg"
            ;;
    esac
}

# Extract base info from URL
parse_url() {
    local url="$1"
    # Remove protocol
    TARGET_HOST=$(echo "$url" | sed -E 's|^https?://||' | cut -d'/' -f1 | cut -d':' -f1)
    TARGET_PROTO=$(echo "$url" | grep -q "https://" && echo "https" || echo "http")
}

# Follow redirects to get final URL
follow_redirects() {
    LOG "Following redirects..."
    # Use -I for HEAD request, -L to follow redirects, get final URL
    local final_url=$(curl -sIL -m $TIMEOUT "$TARGET_URL" 2>/dev/null | grep -i "^location:" | tail -1 | cut -d' ' -f2 | tr -d '\r')

    if [ -n "$final_url" ]; then
        # Update to final destination
        LOG "Redirect detected: $final_url"

        # Check if redirect is relative (starts with /)
        if [[ "$final_url" =~ ^/ ]]; then
            # Relative redirect - prepend original protocol and host
            TARGET_URL="${TARGET_PROTO}://${TARGET_HOST}${final_url}"
            LOG "Relative redirect resolved to: $TARGET_URL"
        else
            # Absolute redirect
            TARGET_URL="$final_url"
            parse_url "$TARGET_URL"
            TARGET_URL="${TARGET_PROTO}://${TARGET_HOST}"
            LOG "Updated target: $TARGET_URL"
        fi
    fi
}

# Compare two version strings: returns 0 if v1 < v2, 1 if v1 >= v2
# Used to check if installed version is still vulnerable (fixed_in > installed)
version_less_than() {
    local v1="$1"  # installed version
    local v2="$2"  # fixed_in version

    local v1_major=$(echo "$v1" | cut -d. -f1)
    local v1_minor=$(echo "$v1" | cut -d. -f2)
    local v1_patch=$(echo "$v1" | cut -d. -f3)
    [ -z "$v1_patch" ] && v1_patch=0

    local v2_major=$(echo "$v2" | cut -d. -f1)
    local v2_minor=$(echo "$v2" | cut -d. -f2)
    local v2_patch=$(echo "$v2" | cut -d. -f3)
    [ -z "$v2_patch" ] && v2_patch=0

    if [ "$v1_major" -lt "$v2_major" ] 2>/dev/null; then return 0; fi
    if [ "$v1_major" -gt "$v2_major" ] 2>/dev/null; then return 1; fi
    if [ "$v1_minor" -lt "$v2_minor" ] 2>/dev/null; then return 0; fi
    if [ "$v1_minor" -gt "$v2_minor" ] 2>/dev/null; then return 1; fi
    if [ "$v1_patch" -lt "$v2_patch" ] 2>/dev/null; then return 0; fi
    return 1  # equal or greater = not vulnerable
}

# === SCAN MODULES ===

# 0. IP Geolocation Lookup
scan_ip_geolocation() {
    log_result "[+] IP GEOLOCATION LOOKUP"
    led_scanning

    # Resolve domain to IP
    LOG "Resolving IP address..."
    local target_ip=$(nslookup "$TARGET_HOST" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | tail -1 | awk '{print $2}')

    # Fallback method if nslookup format differs
    if [ -z "$target_ip" ]; then
        target_ip=$(host "$TARGET_HOST" 2>/dev/null | grep "has address" | head -1 | awk '{print $4}')
    fi

    # Fallback: Use Google DNS-over-HTTPS (works on BusyBox where nslookup/host may be limited)
    if [ -z "$target_ip" ]; then
        LOG "Using DNS-over-HTTPS fallback..."
        target_ip=$(curl -s -m 5 "https://dns.google/resolve?name=${TARGET_HOST}&type=A" 2>/dev/null | grep -oE '"data":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | cut -d'"' -f4)
    fi

    if [ -z "$target_ip" ]; then
        log_result "[*] Could not resolve IP address"
        log_result ""
        return
    fi

    log_result "[*] Target IP: $target_ip"

    # Query ipinfo.io
    LOG "Querying ipinfo.io..."
    local ipinfo=$(curl -s -m $TIMEOUT "https://ipinfo.io/${target_ip}/json" 2>/dev/null)

    if [ -z "$ipinfo" ]; then
        log_result "[*] Could not retrieve IP info"
        log_result ""
        return
    fi

    # Parse JSON fields (bash-friendly parsing)
    local hostname=$(echo "$ipinfo" | grep -o '"hostname"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local city=$(echo "$ipinfo" | grep -o '"city"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local region=$(echo "$ipinfo" | grep -o '"region"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local country=$(echo "$ipinfo" | grep -o '"country"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local loc=$(echo "$ipinfo" | grep -o '"loc"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local org=$(echo "$ipinfo" | grep -o '"org"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local postal=$(echo "$ipinfo" | grep -o '"postal"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local timezone=$(echo "$ipinfo" | grep -o '"timezone"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)

    # Format output nicely
    log_result ""
    log_result "━━━ IP Information ━━━"
    [ -n "$hostname" ] && log_result "  Hostname    : $hostname"
    [ -n "$city" ] && [ -n "$region" ] && log_result "  Location    : $city, $region"
    [ -n "$country" ] && log_result "  Country     : $country"
    [ -n "$postal" ] && log_result "  Postal Code : $postal"
    [ -n "$loc" ] && log_result "  Coordinates : $loc"
    [ -n "$org" ] && log_result "  Organization: $org"
    [ -n "$timezone" ] && log_result "  Timezone    : $timezone"
    log_result "━━━━━━━━━━━━━━━━━━━━━━"

    log_result ""
}

# WHOIS Domain Registration Info
scan_whois() {
    log_result "[+] WHOIS DOMAIN INFO"
    led_scanning

    LOG "Querying WHOIS for $TARGET_HOST..."

    # Strip to apex domain (e.g. sub.example.com -> example.com)
    local apex_domain=$(echo "$TARGET_HOST" | awk -F'.' '{if(NF>2) print $(NF-1)"."$NF; else print $0}')

    # Query RDAP — follow redirects (-L) since rdap.org redirects to the authoritative registry
    local rdap_json=$(curl -s -L -m $TIMEOUT "https://rdap.org/domain/${apex_domain}" 2>/dev/null)

    # Try exact match first, then case-insensitive fallback
    local raw_date=$(echo "$rdap_json" | jq -r '.events[] | select(.eventAction=="registration") | .eventDate' 2>/dev/null)

    if [ -z "$raw_date" ] || [ "$raw_date" = "null" ]; then
        raw_date=$(echo "$rdap_json" | jq -r '.events[] | select(.eventAction | ascii_downcase == "registration") | .eventDate' 2>/dev/null | head -1)
    fi

    if [ -z "$raw_date" ] || [ "$raw_date" = "null" ]; then
        log_result "[*] Creation date unavailable"
        log_result ""
        return
    fi

    # Format ISO 8601 (2018-01-24T05:00:00Z) -> "January 24, 2018"
    local year=$(echo "$raw_date" | cut -d'-' -f1)
    local month_num=$(echo "$raw_date" | cut -d'-' -f2)
    local day=$(echo "$raw_date" | cut -d'-' -f3 | cut -c1-2 | sed 's/^0//')
    local month
    case "$month_num" in
        01) month="January"   ;;
        02) month="February"  ;;
        03) month="March"     ;;
        04) month="April"     ;;
        05) month="May"       ;;
        06) month="June"      ;;
        07) month="July"      ;;
        08) month="August"    ;;
        09) month="September" ;;
        10) month="October"   ;;
        11) month="November"  ;;
        12) month="December"  ;;
        *)  month="$month_num" ;;
    esac

    log_result "[*] Creation Date: $month $day, $year"
    log_result ""
}

# SSL/TLS Security Analysis
scan_ssl_tls() {
    log_result "[+] SSL/TLS SECURITY ANALYSIS"
    led_scanning

    # Only scan HTTPS sites
    if [ "$TARGET_PROTO" != "https" ]; then
        log_finding "INFO" "Target uses HTTP - skipping SSL/TLS checks"
        log_result ""
        return
    fi

    LOG "Analyzing SSL/TLS configuration..."

    # Get SSL info using openssl
    local ssl_info=$(echo | timeout 5 openssl s_client -connect "${TARGET_HOST}:443" -servername "$TARGET_HOST" 2>/dev/null)

    if [ -z "$ssl_info" ]; then
        log_result "[*] Could not connect via SSL/TLS"
        log_result ""
        return
    fi

    # Certificate expiration check
    local cert_dates=$(echo "$ssl_info" | openssl x509 -noout -dates 2>/dev/null)
    local not_after=$(echo "$cert_dates" | grep "notAfter" | cut -d'=' -f2)

    if [ -n "$not_after" ]; then
        log_result "[*] Certificate expires: $not_after"

        # Check if expiring soon (within 30 days) - portable date parsing
        local expiry_epoch=$(echo "$ssl_info" | openssl x509 -noout -enddate 2>/dev/null | cut -d'=' -f2 | xargs -I{} date -d {} +%s 2>/dev/null || echo "")

        # Fallback for systems without -d flag (like macOS)
        if [ -z "$expiry_epoch" ]; then
            expiry_epoch=$(echo "$ssl_info" | openssl x509 -noout -enddate 2>/dev/null | cut -d'=' -f2 | xargs -I{} date -j -f "%b %d %T %Y %Z" {} +%s 2>/dev/null || echo "")
        fi

        if [ -n "$expiry_epoch" ] && [ "$expiry_epoch" != "" ]; then
            local current_epoch=$(date +%s)
            local days_until_expiry=$(( (expiry_epoch - current_epoch) / 86400 ))

            if [ $days_until_expiry -lt 0 ]; then
                log_finding "CRITICAL" "SSL Certificate EXPIRED!"
                play_found
                led_found
            elif [ $days_until_expiry -lt 30 ]; then
                log_finding "HIGH" "SSL Certificate expires in $days_until_expiry days"
                play_found
            else
                log_finding "INFO" "SSL Certificate valid for $days_until_expiry days"
            fi
        fi
    fi

    # Self-signed certificate check
    if echo "$ssl_info" | grep -q "self signed certificate"; then
        log_finding "HIGH" "Self-signed certificate detected"
        play_found
    fi

    # Check TLS version
    local tls_version=$(echo | timeout 3 openssl s_client -connect "${TARGET_HOST}:443" -servername "$TARGET_HOST" 2>/dev/null | grep "Protocol" | awk '{print $3}')

    if [ -n "$tls_version" ]; then
        log_result "[*] TLS Version: $tls_version"

        case "$tls_version" in
            "TLSv1"|"TLSv1.0"|"TLSv1.1")
                log_finding "HIGH" "Outdated TLS version: $tls_version (should use TLS 1.2+)"
                play_found
                ;;
            "SSLv2"|"SSLv3")
                log_finding "CRITICAL" "Insecure SSL/TLS version: $tls_version"
                play_found
                led_found
                ;;
        esac
    fi

    # Check cipher suites
    local cipher=$(echo "$ssl_info" | grep "Cipher" | head -1 | awk '{print $3}')

    if [ -n "$cipher" ]; then
        log_result "[*] Cipher Suite: $cipher"

        # Check for weak ciphers
        if echo "$cipher" | grep -qiE "(NULL|EXPORT|DES|RC4|MD5|anon)"; then
            log_finding "CRITICAL" "Weak cipher detected: $cipher"
            play_found
            led_found
        fi
    fi

    # Certificate chain validation
    if echo "$ssl_info" | grep -q "Verify return code: 0"; then
        log_result "[*] Certificate chain valid"
    else
        local verify_error=$(echo "$ssl_info" | grep "Verify return code:" | cut -d':' -f2-)
        if [ -n "$verify_error" ]; then
            log_finding "MEDIUM" "Certificate chain issue:$verify_error"
        fi
    fi

    # Test TLS 1.0/1.1 support (should be disabled)
    LOG "Testing deprecated TLS versions..."
    local tls10_test=$(echo | timeout 2 openssl s_client -connect "${TARGET_HOST}:443" -tls1 2>/dev/null | grep "Protocol")
    if [ -n "$tls10_test" ]; then
        log_finding "MEDIUM" "TLS 1.0 still supported (should be disabled)"
    fi

    local tls11_test=$(echo | timeout 2 openssl s_client -connect "${TARGET_HOST}:443" -tls1_1 2>/dev/null | grep "Protocol")
    if [ -n "$tls11_test" ]; then
        log_finding "MEDIUM" "TLS 1.1 still supported (should be disabled)"
    fi

    log_result ""
}

# Protocol Availability Check (HTTP/HTTPS)
scan_protocol_availability() {
    log_result "[+] PROTOCOL AVAILABILITY CHECK"
    led_scanning

    LOG "Checking HTTP and HTTPS availability..."

    local http_url="http://${TARGET_HOST}"
    local https_url="https://${TARGET_HOST}"

    # Test HTTP availability
    local http_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT --connect-timeout 5 "$http_url" 2>/dev/null)
    local http_available=false
    if [ -n "$http_status" ] && [ "$http_status" != "000" ]; then
        http_available=true
    fi

    # Test HTTPS availability
    local https_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT --connect-timeout 5 "$https_url" 2>/dev/null)
    local https_available=false
    if [ -n "$https_status" ] && [ "$https_status" != "000" ]; then
        https_available=true
    fi

    # Report findings
    if [ "$http_available" = "true" ] && [ "$https_available" = "true" ]; then
        log_result "[*] HTTP available  (port 80):  HTTP $http_status"
        log_result "[*] HTTPS available (port 443): HTTP $https_status"

        # Check if HTTP redirects to HTTPS
        local http_final=$(curl -s -o /dev/null -w "%{url_effective}" -m $TIMEOUT --connect-timeout 5 -L "$http_url" 2>/dev/null)

        if echo "$http_final" | grep -q "^https://"; then
            log_finding "INFO" "HTTP redirects to HTTPS (good practice)"
        else
            log_finding "MEDIUM" "HTTP does NOT redirect to HTTPS - mixed content risk"
            log_result "  Recommendation: Configure HTTP to HTTPS redirect"
            play_found
        fi

    elif [ "$http_available" = "true" ] && [ "$https_available" = "false" ]; then
        log_result "[*] HTTP available  (port 80):  HTTP $http_status"
        log_result "[*] HTTPS not available (port 443)"
        log_finding "HIGH" "Site only available via HTTP - no encryption!"
        log_result "  All traffic is unencrypted and can be intercepted"
        play_found

    elif [ "$http_available" = "false" ] && [ "$https_available" = "true" ]; then
        log_result "[*] HTTP not available (port 80)"
        log_result "[*] HTTPS available (port 443): HTTP $https_status"
        log_finding "INFO" "HTTPS only - HTTP not available (secure configuration)"

    else
        log_result "[*] Neither HTTP nor HTTPS responding"
        log_finding "INFO" "Site may be down or blocking requests"
    fi

    log_result ""
}

# 1. Information Gathering
scan_info() {
    log_result "[+] INFORMATION GATHERING"
    led_scanning

    # Get headers
    log_result "--- Response Headers ---"
    curl -sI -m $TIMEOUT "$TARGET_URL" 2>/dev/null | tr -d '\r' | tee -a "$LOOTFILE" | head -5 | while read line; do LOG "$line"; done

    # Check for security headers
    log_result ""
    log_result "--- Security Headers Check ---"
    local headers=$(curl -sI -m $TIMEOUT "$TARGET_URL" 2>/dev/null)

    [ -z "$(echo "$headers" | grep -i 'X-Frame-Options')" ] && LOG "green" "Missing: X-Frame-Options" && log_finding "MEDIUM" "Missing: X-Frame-Options" && play_found
    [ -z "$(echo "$headers" | grep -i 'X-Content-Type-Options')" ] && LOG "green" "Missing: X-Content-Type-Options" && log_finding "MEDIUM" "Missing: X-Content-Type-Options" && play_found
    [ -z "$(echo "$headers" | grep -i 'Strict-Transport-Security')" ] && LOG "green" "Missing: HSTS" && log_finding "MEDIUM" "Missing: HSTS" && play_found
    [ -z "$(echo "$headers" | grep -i 'Content-Security-Policy')" ] && LOG "green" "Missing: CSP" && log_finding "MEDIUM" "Missing: CSP" && play_found

    # Server fingerprinting
    local server=$(echo "$headers" | grep -i "^Server:" | cut -d':' -f2- | tr -d '\r')
    [ -n "$server" ] && log_finding "INFO" "Server:$server"

    local powered=$(echo "$headers" | grep -i "^X-Powered-By:" | cut -d':' -f2- | tr -d '\r')
    [ -n "$powered" ] && log_finding "HIGH" "X-Powered-By:$powered" && play_found

    log_result ""
}

# 2. Enhanced Endpoints Discovery
scan_endpoints() {
    log_result "[+] ENHANCED ENDPOINTS DISCOVERY"
    led_scanning

    local endpoints=(
        # Common files
        "/robots.txt"
        "/sitemap.xml"
        "/sitemap_index.xml"
        "/.git/config"
        "/.git/HEAD"
        "/.git/index"
        "/.svn/entries"
        "/.hg/"
        "/.env"
        "/.aws/credentials"
        "/phpinfo.php"
        "/.well-known/security.txt"
        # Admin & Auth
        "/admin"
        "/admin.php"
        "/administrator"
        "/login"
        "/console"
        # API endpoints
        "/api"
        "/api/v1"
        "/api/v2"
        "/api/docs"
        "/swagger.json"
        "/swagger-ui.html"
        "/openapi.json"
        "/graphql"
        "/graphiql"
        # Spring Boot Actuator
        "/actuator"
        "/actuator/env"
        "/actuator/health"
        "/actuator/metrics"
        "/actuator/mappings"
        "/actuator/trace"
        # Debug & Monitoring
        "/debug"
        "/trace"
        "/metrics"
        "/health"
        "/status"
        "/info"
        # Laravel
        "/telescope"
        # Django
        "/__debug__/"
        # Tomcat
        "/manager/html"
        "/manager/status"
    )

    LOG "Checking ${#endpoints[@]} endpoints..."
    local found=0

    # Get baseline homepage content for comparison (use hash for efficient comparison)
    local homepage_response=$(curl -s -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
    local homepage_hash=$(echo "$homepage_response" | md5sum | cut -d' ' -f1)
    local homepage_size=${#homepage_response}
    local homepage_title=$(echo "$homepage_response" | grep -oiE '<title>[^<]+</title>' | head -1)

    LOG "Baseline: size=$homepage_size, hash=$homepage_hash"

    for endpoint in "${endpoints[@]}"; do
        local url="${TARGET_PROTO}://${TARGET_HOST}${endpoint}"
        local status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "$url" 2>/dev/null)

        if [ "$status" = "200" ]; then
            # Fetch response content for verification
            local response=$(curl -s -m $TIMEOUT "$url" 2>/dev/null)
            local response_hash=$(echo "$response" | md5sum | cut -d' ' -f1)
            local response_size=${#response}

            # FALSE POSITIVE CHECK: Compare against homepage
            # If response is identical or nearly identical to homepage, it's a soft-404
            local is_real=1
            local severity="INFO"

            # Check 1: Identical content hash (exact match = definitely fake)
            if [ "$response_hash" = "$homepage_hash" ]; then
                is_real=0
            fi

            # Check 2: Same title tag (likely same page)
            if [ $is_real -eq 1 ]; then
                local response_title=$(echo "$response" | grep -oiE '<title>[^<]+</title>' | head -1)
                if [ -n "$homepage_title" ] && [ "$response_title" = "$homepage_title" ]; then
                    # Same title - likely soft-404, but verify with size
                    local size_diff=$((response_size - homepage_size))
                    size_diff=${size_diff#-}  # Absolute value
                    # If size difference is < 5%, probably the same page
                    local threshold=$((homepage_size / 20))
                    if [ $size_diff -lt $threshold ] || [ $size_diff -lt 500 ]; then
                        is_real=0
                    fi
                fi
            fi

            # CONTENT-SPECIFIC VALIDATION for files that should have specific formats
            if [ $is_real -eq 1 ]; then
                if [[ "$endpoint" =~ ^/\.env$ ]]; then
                    # .env should contain KEY=value patterns, not HTML
                    if echo "$response" | grep -qiE "<!DOCTYPE|<html|<head"; then
                        is_real=0
                    elif ! echo "$response" | grep -qE "^[A-Z_]+=" ; then
                        is_real=0
                    else
                        severity="CRITICAL"
                    fi
                elif [[ "$endpoint" =~ phpinfo\.php$ ]]; then
                    # phpinfo.php should contain "PHP Version"
                    if ! echo "$response" | grep -qi "php version\|phpinfo()"; then
                        is_real=0
                    else
                        severity="CRITICAL"
                    fi
                elif [[ "$endpoint" =~ ^/\.(git|aws) ]]; then
                    # Git/AWS files shouldn't be HTML
                    if echo "$response" | grep -qiE "<!DOCTYPE|<html|<head"; then
                        is_real=0
                    else
                        severity="CRITICAL"
                    fi
                elif [[ "$endpoint" =~ /swagger\.json$|/openapi\.json$ ]]; then
                    # Swagger/OpenAPI should be valid JSON with specific keys
                    if ! echo "$response" | grep -qiE "\"swagger\":|\"openapi\":"; then
                        is_real=0
                    fi
                elif [[ "$endpoint" =~ /robots\.txt$ ]]; then
                    # robots.txt should have User-agent or Disallow
                    if ! echo "$response" | grep -qiE "user-agent|disallow|allow|sitemap"; then
                        is_real=0
                    fi
                elif [[ "$endpoint" =~ /sitemap.*\.xml$ ]]; then
                    # Sitemap should be XML with urlset or sitemapindex
                    if ! echo "$response" | grep -qiE "<urlset|<sitemapindex|<\?xml"; then
                        is_real=0
                    fi
                elif [[ "$endpoint" =~ /actuator ]]; then
                    # Spring Boot actuator returns JSON, not HTML
                    if echo "$response" | grep -qiE "<!DOCTYPE|<html|<head"; then
                        is_real=0
                    elif ! echo "$response" | grep -qE '^\s*\{|\['; then
                        is_real=0  # Not JSON
                    else
                        if [[ "$endpoint" =~ /actuator/(env|trace|mappings) ]]; then
                            severity="HIGH"
                        fi
                    fi
                elif [[ "$endpoint" =~ /graphql|/graphiql ]]; then
                    # GraphQL endpoints return JSON or have GraphQL UI
                    if echo "$response" | grep -qiE "graphql\|graphiql\|\"data\":\|\"errors\":"; then
                        severity="INFO"
                    else
                        is_real=0
                    fi
                elif [[ "$endpoint" =~ /(admin|console|login|administrator) ]]; then
                    # Admin pages should have login forms or admin-specific content
                    if echo "$response" | grep -qiE "login|password|username|sign.?in|admin|dashboard|authenticate"; then
                        severity="MEDIUM"
                    else
                        is_real=0  # Just the homepage, not a real admin page
                    fi
                elif [[ "$endpoint" =~ /api(/|$) ]]; then
                    # API endpoints should return JSON or API-specific content
                    if echo "$response" | grep -qiE "<!DOCTYPE|<html|<head"; then
                        # It's HTML - check if it's API documentation
                        if ! echo "$response" | grep -qiE "swagger|api.?doc|openapi"; then
                            is_real=0
                        fi
                    fi
                elif [[ "$endpoint" =~ /(debug|trace|metrics|health|status|info)$ ]]; then
                    # These should return JSON/plaintext, not HTML homepage
                    if echo "$response" | grep -qiE "<!DOCTYPE|<html|<head"; then
                        is_real=0
                    fi
                elif [[ "$endpoint" =~ /\.svn|/\.hg ]]; then
                    # SVN/Mercurial files shouldn't be HTML
                    if echo "$response" | grep -qiE "<!DOCTYPE|<html|<head"; then
                        is_real=0
                    else
                        severity="HIGH"
                    fi
                elif [[ "$endpoint" =~ /manager/(html|status) ]]; then
                    # Tomcat manager should have specific content
                    if echo "$response" | grep -qiE "tomcat|manager|application|deploy"; then
                        severity="HIGH"
                    else
                        is_real=0
                    fi
                elif [[ "$endpoint" =~ /telescope|/__debug__ ]]; then
                    # Laravel Telescope / Django Debug should have specific content
                    if echo "$response" | grep -qiE "telescope|laravel|django|debug.?toolbar"; then
                        severity="HIGH"
                    else
                        is_real=0
                    fi
                elif [[ "$endpoint" =~ /\.well-known/security\.txt$ ]]; then
                    # security.txt should have Contact: or other fields
                    if ! echo "$response" | grep -qiE "contact:|expires:|encryption:|preferred-languages:"; then
                        is_real=0
                    fi
                fi
            fi

            # Only report if it's real (not homepage/soft-404)
            if [ $is_real -eq 1 ]; then
                LOG "green" "FOUND [$status]: $endpoint"
                log_finding "$severity" "FOUND [$status]: $endpoint"
                found=$((found + 1))
                if [ "$severity" = "CRITICAL" ] || [ "$severity" = "HIGH" ]; then
                    play_found
                    led_found
                fi
                sleep 0.3
            fi
        elif [ "$status" = "301" ] || [ "$status" = "302" ]; then
            # Redirects - only log if redirecting to a different path (not back to homepage)
            local redirect_location=$(curl -sI -m $TIMEOUT "$url" 2>/dev/null | grep -i "^location:" | cut -d' ' -f2 | tr -d '\r')
            # Don't report if redirecting to homepage or root
            if [ -n "$redirect_location" ] && ! echo "$redirect_location" | grep -qE "^/?$|^${TARGET_URL}/?$"; then
                LOG "green" "REDIRECT [$status]: $endpoint -> $redirect_location"
                log_result "[*] REDIRECT [$status]: $endpoint -> $redirect_location"
                found=$((found + 1))
            fi
        fi
        sleep 0.05
    done

    if [ $found -eq 0 ]; then
        log_result "[*] No endpoints found"
    fi

    log_result ""
}

# 3. HTTP Methods Testing
scan_methods() {
    log_result "[+] HTTP METHODS TESTING"
    led_scanning

    local methods=("OPTIONS" "PUT" "DELETE" "TRACE" "PATCH")
    local found_vuln=0
    local rate_limited=0
    local found_methods=()
    local unexpected_methods=()

    LOG "Testing ${#methods[@]} HTTP methods..."

    # Get baseline GET response for comparison
    local baseline_headers=$(curl -sI -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
    local baseline_length=$(echo "$baseline_headers" | grep -i "^Content-Length:" | tr -d '\r' | awk '{print $2}')
    local baseline_type=$(echo "$baseline_headers" | grep -i "^Content-Type:" | tr -d '\r' | cut -d':' -f2 | cut -d';' -f1 | tr -d ' ')

    for method in "${methods[@]}"; do
        local response=$(curl -sI -X "$method" -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
        local status=$(echo "$response" | head -1 | grep -o "[0-9]\{3\}")

        case "$status" in
            200|201|204)
                # For OPTIONS, verify Allow header exists
                if [ "$method" = "OPTIONS" ]; then
                    local allow_header=$(echo "$response" | grep -i "^Allow:")
                    if [ -z "$allow_header" ]; then
                        # No Allow header = not a real OPTIONS response
                        continue
                    fi
                    log_finding "MEDIUM" "$method ENABLED: HTTP $status"
                    log_result "    $allow_header"
                    play_found
                    led_found
                    found_vuln=1
                    found_methods+=("$method")
                # For PUT/DELETE/PATCH, check if response differs from baseline GET
                elif [ "$method" = "PUT" ] || [ "$method" = "DELETE" ] || [ "$method" = "PATCH" ]; then
                    local method_length=$(echo "$response" | grep -i "^Content-Length:" | tr -d '\r' | awk '{print $2}')
                    local method_type=$(echo "$response" | grep -i "^Content-Type:" | tr -d '\r' | cut -d':' -f2 | cut -d';' -f1 | tr -d ' ')

                    # If response is identical to GET (same size, same type=HTML), server is just ignoring the method
                    if [ "$method_length" = "$baseline_length" ] && echo "$method_type" | grep -qi "text/html"; then
                        # Server returned homepage - not a real vulnerability
                        continue
                    fi

                    # 201 Created is a strong indicator the method actually works
                    if [ "$status" = "201" ]; then
                        log_finding "HIGH" "$method ENABLED: HTTP $status (Created)"
                        play_found
                        led_found
                        found_vuln=1
                        found_methods+=("$method")
                    # 204 No Content suggests method was processed
                    elif [ "$status" = "204" ]; then
                        log_finding "MEDIUM" "$method ENABLED: HTTP $status (No Content)"
                        play_found
                        led_found
                        found_vuln=1
                        found_methods+=("$method")
                    # Different content-type (e.g., JSON) suggests API endpoint
                    elif [ "$method_type" != "$baseline_type" ] && [ -n "$method_type" ]; then
                        log_finding "MEDIUM" "$method may be enabled: HTTP $status (different response type: $method_type)"
                        play_found
                        found_vuln=1
                        found_methods+=("$method")
                    fi
                    # If none of the above, it's likely a false positive - skip it
                # For TRACE, any 200 response is concerning (XST)
                elif [ "$method" = "TRACE" ]; then
                    log_finding "MEDIUM" "$method ENABLED: HTTP $status"
                    play_found
                    led_found
                    found_vuln=1
                    found_methods+=("$method")
                fi
                sleep 0.3
                ;;
            429|503)
                # Rate limited or service unavailable
                log_finding "INFO" "$method rate limited: HTTP $status"
                rate_limited=1
                ;;
            405|501)
                # Properly blocked - this is good (405=Not Allowed, 501=Not Implemented)
                # Don't log these, they're secure
                ;;
            000|"")
                # Timeout or no response - don't log
                ;;
            *)
                # Other status codes - might be interesting
                log_finding "LOW" "$method unexpected: HTTP $status"
                unexpected_methods+=("$method:$status")
                ;;
        esac
        sleep 0.1
    done

    if [ $found_vuln -eq 0 ] && [ $rate_limited -eq 0 ]; then
        log_result "[*] All methods properly blocked"
    elif [ $found_vuln -eq 0 ] && [ $rate_limited -eq 1 ]; then
        log_result "[*] No unsafe methods detected (some rate limited)"
    fi

    # Add verification guide if any methods were found
    if [ ${#found_methods[@]} -gt 0 ] || [ ${#unexpected_methods[@]} -gt 0 ]; then
        log_result ""
        log_result "━━━ HOW TO VERIFY HTTP METHODS ━━━"
        log_result ""

        # OPTIONS method explanation
        if [[ " ${found_methods[*]} " =~ " OPTIONS " ]]; then
            log_result "OPTIONS ENABLED:"
            log_result "  View allowed methods:"
            log_result "    curl -X OPTIONS -i \"$TARGET_URL\""
            log_result "  Look for 'Allow:' header listing permitted methods"
            log_result "  Risk: Information disclosure about server capabilities"
            log_result ""
        fi

        # PUT method explanation
        if [[ " ${found_methods[*]} " =~ " PUT " ]] || [[ " ${unexpected_methods[*]} " =~ "PUT:" ]]; then
            log_result "PUT METHOD:"
            log_result "  Test file upload (use safe filename):"
            log_result "    curl -X PUT -d 'test content' \"$TARGET_URL/test_upload_deleteme.txt\""
            log_result "  Then verify: curl \"$TARGET_URL/test_upload_deleteme.txt\""
            log_result "  Risk: Arbitrary file upload, web shell deployment, defacement"
            log_result "  Note: HTTP 411 means server requires Content-Length header:"
            log_result "    curl -X PUT -H \"Content-Length: 12\" -d 'test content' \"$TARGET_URL/test.txt\""
            log_result ""
        fi

        # DELETE method explanation
        if [[ " ${found_methods[*]} " =~ " DELETE " ]]; then
            log_result "DELETE METHOD:"
            log_result "  Test deletion (CAREFUL - use non-existent file):"
            log_result "    curl -X DELETE -i \"$TARGET_URL/nonexistent_file_12345.txt\""
            log_result "  Risk: Arbitrary file deletion, data destruction"
            log_result "  WARNING: Do NOT test on real files without authorization!"
            log_result ""
        fi

        # TRACE method explanation
        if [[ " ${found_methods[*]} " =~ " TRACE " ]]; then
            log_result "TRACE METHOD (XST - Cross-Site Tracing):"
            log_result "  Test for request reflection:"
            log_result "    curl -X TRACE -H \"X-Test: sensitive_data\" \"$TARGET_URL\""
            log_result "  If response contains your headers, XST is possible"
            log_result "  Risk: Cookie theft via XSS+XST, credential harvesting"
            log_result "  Combined with XSS, can bypass HttpOnly cookie protection"
            log_result ""
        fi

        # PATCH method explanation
        if [[ " ${found_methods[*]} " =~ " PATCH " ]]; then
            log_result "PATCH METHOD:"
            log_result "  Test partial resource modification:"
            log_result "    curl -X PATCH -H \"Content-Type: application/json\" -d '{\"field\":\"value\"}' \"$TARGET_URL\""
            log_result "  Risk: Unauthorized data modification"
            log_result "  Often used in REST APIs - check if authentication is required"
            log_result ""
        fi

        log_result "GENERAL TESTING TIPS:"
        log_result "  1. Test methods on specific endpoints, not just root:"
        log_result "     curl -X PUT \"$TARGET_URL/api/users/1\""
        log_result "     curl -X DELETE \"$TARGET_URL/api/posts/1\""
        log_result "  2. Try with authentication headers if you have creds:"
        log_result "     curl -X DELETE -H \"Authorization: Bearer TOKEN\" \"$TARGET_URL/resource\""
        log_result "  3. Check if WebDAV is enabled (common with PUT/DELETE):"
        log_result "     curl -X PROPFIND -H \"Depth: 1\" \"$TARGET_URL\""
        log_result "  4. Test for method override headers:"
        log_result "     curl -X POST -H \"X-HTTP-Method-Override: DELETE\" \"$TARGET_URL\""
        log_result "     curl -X POST -H \"X-Method-Override: PUT\" \"$TARGET_URL\""
        log_result "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi

    log_result ""
}

# 4. Header Injection Tests
scan_headers() {
    log_result "[+] HEADER INJECTION TESTS"
    led_scanning

    # X-Forwarded-For
    local xff_resp=$(curl -s -m $TIMEOUT -H "X-Forwarded-For: 127.0.0.1" "$TARGET_URL" 2>/dev/null)
    if echo "$xff_resp" | grep -q "127.0.0.1"; then
        log_finding "MEDIUM" "X-Forwarded-For may be reflected"
        play_found
    fi

    # Host header
    local host_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT -H "Host: evil.com" "$TARGET_URL" 2>/dev/null)
    if [ "$host_status" = "200" ]; then
        log_finding "MEDIUM" "Host header accepted: evil.com"
        play_found
    fi

    # X-Original-URL bypass attempt (with content verification to reduce false positives)
    LOG "Testing X-Original-URL bypass..."

    # Get baseline response (normal request without header)
    local baseline_content=$(curl -s -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
    local baseline_size=${#baseline_content}

    # Test paths that commonly require authentication
    local test_paths="/admin /console /dashboard /wp-admin /manager /settings /config"
    local bypass_detected=false
    local bypass_path=""

    for path in $test_paths; do
        # Request with X-Original-URL header
        local bypass_response=$(curl -s -m $TIMEOUT -H "X-Original-URL: $path" "$TARGET_URL" 2>/dev/null)
        local bypass_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT -H "X-Original-URL: $path" "$TARGET_URL" 2>/dev/null)
        local bypass_size=${#bypass_response}

        # Skip if not HTTP 200
        [ "$bypass_status" != "200" ] && continue

        # Calculate size difference percentage
        local size_diff=0
        if [ $baseline_size -gt 0 ]; then
            size_diff=$(( (bypass_size - baseline_size) * 100 / baseline_size ))
            # Get absolute value
            [ $size_diff -lt 0 ] && size_diff=$(( size_diff * -1 ))
        fi

        # Check for admin-specific keywords in response that wouldn't be on homepage
        local admin_keywords="admin panel|dashboard|control panel|administration|logout|sign out|user management|settings panel|admin area|configuration|manage users|admin menu|cpanel|administrator"
        local has_admin_content=false

        if echo "$bypass_response" | grep -qiE "$admin_keywords"; then
            # Make sure these keywords aren't in the baseline too
            if ! echo "$baseline_content" | grep -qiE "$admin_keywords"; then
                has_admin_content=true
            fi
        fi

        # Check for login/auth bypass indicators
        local auth_indicators="welcome admin|logged in as|my account|profile settings|admin dashboard"
        local has_auth_bypass=false

        if echo "$bypass_response" | grep -qiE "$auth_indicators"; then
            if ! echo "$baseline_content" | grep -qiE "$auth_indicators"; then
                has_auth_bypass=true
            fi
        fi

        # Determine if this is a real bypass
        # Criteria: significant size difference AND (admin content OR auth bypass indicators)
        if [ $size_diff -gt 20 ] && ([ "$has_admin_content" = "true" ] || [ "$has_auth_bypass" = "true" ]); then
            bypass_detected=true
            bypass_path="$path"
            break
        fi

        # Also flag if we see completely different content structure (like a login form appearing)
        if echo "$bypass_response" | grep -qiE "<form.*login|<form.*password|type=['\"]password['\"]"; then
            if ! echo "$baseline_content" | grep -qiE "<form.*login|<form.*password|type=['\"]password['\"]"; then
                bypass_detected=true
                bypass_path="$path"
                log_result "[*] Login form detected with X-Original-URL: $path"
                break
            fi
        fi
    done

    if [ "$bypass_detected" = "true" ]; then
        log_finding "HIGH" "X-Original-URL bypass CONFIRMED for: $bypass_path"
        log_result "  Content changed significantly when header was sent"
        log_result "  This may allow bypassing access controls!"
        log_result ""
        log_result "  HOW TO EXPLOIT:"
        log_result "  curl -H \"X-Original-URL: $bypass_path\" \"$TARGET_URL\""
        play_found
        led_found
    else
        # Check if server even processes the header (for informational purposes)
        local header_test=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT -H "X-Original-URL: /admin" "$TARGET_URL" 2>/dev/null)
        if [ "$header_test" = "200" ]; then
            log_result "[*] X-Original-URL header accepted but no bypass detected"
            log_result "  Server returned normal content (likely ignores the header)"
        fi
    fi

    log_result ""
}

# 5. CORS Misconfiguration
scan_cors() {
    log_result "[+] CORS MISCONFIGURATION CHECK"
    led_scanning

    LOG "Testing CORS policy..."
    local cors=$(curl -s -m $TIMEOUT -H "Origin: https://evil.com" -I "$TARGET_URL" 2>/dev/null | grep -i "Access-Control-Allow-Origin")

    if echo "$cors" | grep -q "evil.com"; then
        log_finding "HIGH" "CORS reflects arbitrary origin!"
        play_found
        led_found
    elif echo "$cors" | grep -q "*"; then
        log_finding "HIGH" "CORS allows wildcard (*)"
        play_found
    else
        log_result "[*] No CORS issues detected"
    fi

    log_result ""
}

# 6. Redirect & SSRF Tests
scan_redirects() {
    log_result "[+] REDIRECT & SSRF TESTS"
    led_scanning

    # Test common redirect parameters
    local params=("url" "redirect" "next" "return" "dest" "destination" "redir" "redirect_uri")
    local found=0

    LOG "Testing ${#params[@]} redirect params..."
    for param in "${params[@]}"; do
        local test_url="${TARGET_URL}?${param}=https://evil.com"
        local location=$(curl -s -m $TIMEOUT -I "$test_url" 2>/dev/null | grep -i "^Location:" | cut -d' ' -f2 | tr -d '\r')

        if [ -n "$location" ]; then
            # Extract the redirect destination (the actual domain being redirected TO)
            # Check if it starts with http:// or https:// followed by evil.com
            if echo "$location" | grep -qE '^https?://evil\.com(/|$)'; then
                LOG "green" "Open redirect found via: $param -> $location"
                log_finding "HIGH" "Open redirect via: $param"
                log_result "    Redirects to: $location"
                play_found
                led_found
                found=1
                sleep 0.5
            elif echo "$location" | grep -qE '^//evil\.com(/|$)'; then
                # Protocol-relative URL (//evil.com)
                LOG "green" "Open redirect found via: $param -> $location"
                log_finding "HIGH" "Open redirect via: $param"
                log_result "    Redirects to: $location"
                play_found
                led_found
                found=1
                sleep 0.5
            fi
        fi
    done

    if [ $found -eq 0 ]; then
        log_result "[*] No open redirects found"
    fi

    log_result ""
}

# Parameter Discovery
scan_parameters() {
    log_result "[+] PARAMETER DISCOVERY"
    led_scanning

    LOG "Testing common parameters..."

    # Common parameter names to test (~30 parameters for balanced approach)
    local params=(
        # Debug/Dev parameters
        "debug" "test" "dev" "admin" "trace" "verbose"
        # Access control
        "user" "username" "role" "access" "auth" "token"
        # Data retrieval
        "id" "uid" "pid" "page" "data" "item" "file" "doc"
        # Configuration
        "config" "settings" "env" "mode" "format" "lang"
        # Redirects (with different values than scan_redirects)
        "callback" "continue" "back" "source"
        # API-specific
        "api_key" "apikey" "key" "secret" "filter" "sort"
        # Other
        "version" "v" "type" "category" "query" "search"
    )

    local found_params=()
    local baseline_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
    local baseline_size=$(curl -s -m $TIMEOUT "$TARGET_URL" 2>/dev/null | wc -c | tr -d ' ')

    LOG "Baseline: HTTP $baseline_status, Size: $baseline_size bytes"

    # Generate a unique canary value that won't naturally appear on websites
    local canary="curlytest$(date +%s | tail -c 6)"
    LOG "Using canary value: $canary"

    # Calculate minimum size threshold: URL echo can add 500+ bytes from canonical/og:url/analytics
    # Real content changes should be significantly larger
    local size_threshold=1000

    for param in "${params[@]}"; do
        # Test with canary value to detect reflection, plus common values for behavior changes
        local test_url="${TARGET_URL}?${param}=${canary}"
        local response=$(curl -s -m $TIMEOUT "$test_url" 2>/dev/null)
        local status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "$test_url" 2>/dev/null)
        local size=$(echo "$response" | wc -c | tr -d ' ')

        # Check if response is different from baseline
        local size_diff=$((size - baseline_size))
        size_diff=${size_diff#-}  # Absolute value

        # Consider parameter "interesting" if:
        # 1. Status code changes (but ignore rate limiting 429)
        # 2. Response size differs significantly (>1000 bytes to avoid URL echo false positives)
        # 3. Canary value is reflected in dangerous context (potential XSS)

        if [ "$status" != "$baseline_status" ]; then
            # Ignore rate limiting (429) and connection failures (000) - they're just noise
            if [ "$status" = "429" ] || [ "$status" = "000" ]; then
                # Skip rate limited or timed out responses
                continue
            fi
            log_finding "MEDIUM" "Parameter '$param' changes response status: $baseline_status → $status"
            found_params+=("$param")
        elif [ $size_diff -gt $size_threshold ]; then
            log_finding "LOW" "Parameter '$param' affects response (size change: ${size_diff} bytes)"
            found_params+=("$param")
        fi
        # NOTE: Reflection detection disabled - too many false positives from URL echo
        # in canonical tags, og:url, analytics, etc. Status and size changes are more reliable.

        sleep 0.05
    done

    # Test for parameter pollution (HPP)
    LOG "Testing parameter pollution..."
    local hpp_test="${TARGET_URL}?id=1&id=2"
    local hpp_response=$(curl -s -m $TIMEOUT "$hpp_test" 2>/dev/null)

    if echo "$hpp_response" | grep -qE "(id.*1.*2|id.*2.*1)"; then
        log_finding "LOW" "Possible parameter pollution vulnerability (multiple 'id' params processed)"
    fi

    # Summary
    if [ ${#found_params[@]} -gt 0 ]; then
        log_result ""
        log_result "[*] SUMMARY: Found ${#found_params[@]} interesting parameter(s):"
        for param in "${found_params[@]}"; do
            log_result "    - $param"
        done

        # Add manual verification guide
        log_result ""
        log_result "━━━ HOW TO VERIFY MANUALLY ━━━"
        log_result "Parameters marked 'may be reflected' could indicate XSS vulnerabilities."
        log_result ""
        log_result "Test in browser:"
        log_result "  1. Visit: ${TARGET_URL}?PARAM=TESTVALUE123"
        log_result "  2. View source (Ctrl+U), search for 'TESTVALUE123'"
        log_result "  3. If found in HTML context, test XSS:"
        log_result "     ${TARGET_URL}?PARAM=<script>alert(1)</script>"
        log_result ""
        log_result "Test with curl:"
        log_result "  curl \"${TARGET_URL}?PARAM=TEST\" | grep -i \"TEST\""
        log_result ""
        log_result "Parameters with 'size change' may accept values - test functionality:"
        log_result "  ${TARGET_URL}?page=1"
        log_result "  ${TARGET_URL}?page=2"
        log_result "  ${TARGET_URL}?page=999999 (test for errors/edge cases)"
        log_result "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        log_result "[*] No interesting parameters discovered"
    fi

    log_result ""
}

# 7. API Testing
scan_api() {
    log_result "[+] API ENDPOINT TESTING"
    led_scanning

    local api_endpoints=(
        "/api"
        "/api/v1/users"
        "/api/v1/config"
        "/api/v1/admin"
        "/api/debug"
        "/api/swagger"
        "/v1/graphql"
    )

    LOG "Checking ${#api_endpoints[@]} API endpoints..."
    local found=0

    # Get baseline homepage for comparison
    local homepage_response=$(curl -s -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
    local homepage_hash=$(echo "$homepage_response" | md5sum | cut -d' ' -f1)
    local homepage_size=${#homepage_response}

    for endpoint in "${api_endpoints[@]}"; do
        local url="${TARGET_PROTO}://${TARGET_HOST}${endpoint}"
        local resp=$(curl -s -m $TIMEOUT "$url" 2>/dev/null)
        local status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "$url" 2>/dev/null)

        if [ "$status" = "200" ]; then
            local resp_hash=$(echo "$resp" | md5sum | cut -d' ' -f1)
            local resp_size=${#resp}
            local is_real_api=0

            # FALSE POSITIVE CHECK: Don't report if response matches homepage
            if [ "$resp_hash" = "$homepage_hash" ]; then
                continue  # Identical to homepage, skip
            fi

            # Check if size is suspiciously similar to homepage
            local size_diff=$((resp_size - homepage_size))
            size_diff=${size_diff#-}  # Absolute value
            local threshold=$((homepage_size / 20))  # 5% threshold
            if [ $size_diff -lt $threshold ] && [ $size_diff -lt 500 ]; then
                continue  # Too similar to homepage
            fi

            # CONTENT CHECK: Verify this is actually an API response
            # Real APIs return JSON, XML, or plaintext - not HTML homepages
            if echo "$resp" | grep -qiE "<!DOCTYPE|<html|<head|<body"; then
                # It's HTML - only accept if it's API documentation
                if echo "$resp" | grep -qiE "swagger|api.?doc|openapi|graphi?ql"; then
                    is_real_api=1
                fi
                # Otherwise skip - it's just the homepage
            else
                # Not HTML - check if it looks like JSON/API response
                if echo "$resp" | grep -qE '^\s*[\{\[]|"[a-zA-Z_]+":'; then
                    is_real_api=1  # Looks like JSON
                elif echo "$resp" | grep -qiE '<\?xml|<response|<result'; then
                    is_real_api=1  # Looks like XML
                elif echo "$resp" | grep -qiE "error|message|status|data|result"; then
                    is_real_api=1  # Common API response keywords
                fi
            fi

            if [ $is_real_api -eq 1 ]; then
                LOG "green" "API FOUND [$status]: $endpoint"
                log_finding "INFO" "API FOUND [$status]: $endpoint"
                found=1

                # Check for sensitive data - be more specific to avoid false positives
                # Look for actual credential patterns, not just words that appear in JS
                local has_sensitive=0

                # Check for actual password/secret values (not just the words)
                if echo "$resp" | grep -qiE '"password"\s*:\s*"[^"]+"|"secret"\s*:\s*"[^"]+"|"api_key"\s*:\s*"[^"]+"'; then
                    has_sensitive=1
                fi

                # Check for AWS-style keys
                if echo "$resp" | grep -qE 'AKIA[0-9A-Z]{16}|[a-zA-Z0-9/+=]{40}'; then
                    has_sensitive=1
                fi

                # Check for JWT tokens
                if echo "$resp" | grep -qE 'eyJ[a-zA-Z0-9_-]+\.eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+'; then
                    has_sensitive=1
                fi

                # Check for user data exposure (arrays of user objects)
                if echo "$resp" | grep -qiE '"users"\s*:\s*\[|"email"\s*:\s*"[^"]+@|"username"\s*:\s*"[^"]+"'; then
                    has_sensitive=1
                fi

                if [ $has_sensitive -eq 1 ]; then
                    LOG "green" "Possible sensitive data in API response!"
                    log_finding "CRITICAL" "Possible sensitive data in API response!"
                    play_found
                    led_found
                    sleep 0.5
                fi
            fi
        fi
        sleep 0.1
    done

    if [ $found -eq 0 ]; then
        log_result "[*] No API endpoints found"
    fi

    log_result ""
}

# 8. Backup File Hunter
scan_backups() {
    log_result "[+] BACKUP FILE HUNTER"
    led_scanning

    # Common backup extensions and patterns
    local base_files=("index" "config" "database" "db" "backup" "admin" "login" "wp-config")
    local extensions=(".bak" ".old" ".backup" "~" ".save" ".copy" ".orig" ".sql" ".tar.gz" ".zip")
    local found=0

    LOG "Hunting for backup files..."

    for base in "${base_files[@]}"; do
        for ext in "${extensions[@]}"; do
            local file="${base}${ext}"
            local url="${TARGET_PROTO}://${TARGET_HOST}/${file}"

            # Get both status and content-type to avoid false positives from redirects
            local response=$(curl -s -I -m $TIMEOUT "$url" 2>/dev/null)
            local status=$(echo "$response" | head -1 | grep -o "[0-9]\{3\}")
            local content_type=$(echo "$response" | grep -i "^content-type:" | cut -d':' -f2 | tr -d ' \r')

            # Only flag if 200 AND not HTML (backup files shouldn't be HTML)
            if [ "$status" = "200" ]; then
                # Ignore if it's HTML (likely a redirect to main page)
                if ! echo "$content_type" | grep -qi "text/html"; then
                    LOG "green" "BACKUP FOUND: /$file (${content_type})"
                    log_finding "CRITICAL" "BACKUP FOUND: /$file (${content_type})"
                    play_found
                    led_found
                    found=1
                    sleep 0.3
                fi
            fi
        done
    done

    if [ $found -eq 0 ]; then
        log_result "[*] No backup files found"
    fi

    log_result ""
}

# 9. Cookie Security Analysis
scan_cookies() {
    log_result "[+] COOKIE SECURITY ANALYSIS"
    led_scanning

    LOG "Analyzing cookies..."
    local cookies=$(curl -s -I -m $TIMEOUT "$TARGET_URL" 2>/dev/null | grep -i "^Set-Cookie:")
    local body=$(curl -s -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
    local js_cookies_found=0
    local consent_detected=0

    # Check for cookie consent banners/scripts (may prevent cookies until user consents)
    LOG "Checking for cookie consent mechanisms..."
    if echo "$body" | grep -qiE 'cookie.?consent|consent.?cookie|gdpr|cookiebot|onetrust|trustarc|cookielaw|cookie.?banner|cookie.?notice|cookie.?policy|accept.?cookie|cookie.?accept|tarteaucitron|klaro|osano|quantcast|didomi|iubenda|complianz'; then
        consent_detected=1
        log_result "[*] Cookie consent mechanism detected"
        log_result "    NOTE: Cookies may only be set AFTER user consents in browser"
    fi

    # Check HTTP Set-Cookie headers
    if [ -z "$cookies" ]; then
        log_result "[*] No cookies in HTTP headers (Set-Cookie)"
    else
        log_result "[*] HTTP Set-Cookie headers detected, analyzing..."
        local cookie_count=$(echo "$cookies" | wc -l | tr -d ' ')
        log_result "[*] Found $cookie_count cookie(s) in headers"

        # Check each cookie for security flags
        while IFS= read -r cookie; do
            local cookie_name=$(echo "$cookie" | sed 's/Set-Cookie: //' | cut -d'=' -f1 | tr -d '\r')

            # Check for HttpOnly flag
            if ! echo "$cookie" | grep -qi "HttpOnly"; then
                log_finding "MEDIUM" "Cookie '$cookie_name' missing HttpOnly flag"
                play_found
            fi

            # Check for Secure flag
            if ! echo "$cookie" | grep -qi "Secure"; then
                log_finding "MEDIUM" "Cookie '$cookie_name' missing Secure flag"
                play_found
            fi

            # Check for SameSite
            if ! echo "$cookie" | grep -qi "SameSite"; then
                log_finding "LOW" "Cookie '$cookie_name' missing SameSite flag"
            fi
        done <<< "$cookies"
    fi

    # Check for JavaScript-based cookie setting (document.cookie)
    # This catches cookies that wouldn't appear in HTTP headers
    log_result ""
    log_result "[*] Checking for JavaScript cookie operations..."

    # Look for document.cookie assignments in the HTML/JS
    local js_cookie_sets=$(echo "$body" | grep -oE 'document\.cookie\s*=' | wc -l | tr -d ' ')
    local js_cookie_reads=$(echo "$body" | grep -oE 'document\.cookie[^=]|document\.cookie$' | wc -l | tr -d ' ')

    if [ "$js_cookie_sets" -gt 0 ]; then
        js_cookies_found=1
        log_finding "INFO" "Found $js_cookie_sets JavaScript cookie assignment(s) (document.cookie=)"
        log_result "    These cookies are set via JS and won't appear in HTTP headers"

        # Try to extract what cookies are being set
        local cookie_patterns=$(echo "$body" | grep -oE "document\.cookie\s*=\s*['\"][^'\"]{1,100}" | head -5)
        if [ -n "$cookie_patterns" ]; then
            log_result "    Sample JS cookie operations found:"
            while IFS= read -r pattern; do
                # Clean up and display
                local cleaned=$(echo "$pattern" | sed "s/document\.cookie\s*=\s*['\"]//g" | cut -c1-60)
                [ -n "$cleaned" ] && log_result "      - $cleaned..."
            done <<< "$cookie_patterns"
        fi

        # Check if JS cookies lack security (they can't set HttpOnly via JS)
        log_finding "LOW" "JS-set cookies cannot have HttpOnly flag (XSS risk if sensitive)"
    fi

    if [ "$js_cookie_reads" -gt 0 ]; then
        log_result "[*] Found $js_cookie_reads JavaScript cookie read(s) (document.cookie)"
        log_result "    Site actively reads cookies via JavaScript"
    fi

    # Summary and manual verification instructions
    log_result ""
    if [ -z "$cookies" ] && [ $js_cookies_found -eq 0 ]; then
        if [ $consent_detected -eq 1 ]; then
            log_result "[*] No cookies detected - likely blocked by consent mechanism"
            log_result ""
            log_result "━━━ MANUAL VERIFICATION REQUIRED ━━━"
            log_result "This site has cookie consent. To see actual cookies:"
            log_result ""
            log_result "1. Open the site in a browser"
            log_result "2. Accept cookies via the consent banner"
            log_result "3. Open DevTools (F12) → Console tab"
            log_result "4. Type: document.cookie"
            log_result "5. Check Application tab → Cookies for full details"
            log_result ""
            log_result "Or use DevTools Network tab to see Set-Cookie headers"
            log_result "after accepting consent."
            log_result "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        else
            log_result "[*] No cookies detected in headers or JavaScript"
            log_result ""
            log_result "━━━ MANUAL VERIFICATION ━━━"
            log_result "curl cannot execute JavaScript or interact with consent dialogs."
            log_result "To verify cookies exist:"
            log_result ""
            log_result "1. Open site in browser → DevTools (F12)"
            log_result "2. Console tab → type: document.cookie"
            log_result "3. Application tab → Storage → Cookies"
            log_result ""
            log_result "If browser shows cookies but this scan doesn't, they're"
            log_result "either set via JavaScript or require user interaction."
            log_result "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        fi
    elif [ $js_cookies_found -eq 1 ]; then
        log_result "━━━ IMPORTANT NOTE ━━━"
        log_result "This site sets cookies via JavaScript (document.cookie)."
        log_result "These cookies:"
        log_result "  - Cannot have HttpOnly flag (accessible to XSS attacks)"
        log_result "  - May contain tracking/analytics data"
        log_result "  - Won't appear in curl HTTP header checks"
        log_result ""
        log_result "To analyze JS-set cookies:"
        log_result "  1. Open site in browser"
        log_result "  2. DevTools (F12) → Console → document.cookie"
        log_result "  3. Check Application → Cookies for security flags"
        log_result "━━━━━━━━━━━━━━━━━━━━━━━━"
    fi

    log_result ""
}

# 10. WAF/CDN Detection
scan_waf() {
    log_result "[+] WAF/CDN DETECTION"
    led_scanning

    LOG "Detecting protection..."
    local headers=$(curl -s -I -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
    local found_waf=0

    # Cloudflare - Check both headers AND nameservers
    local cloudflare_detected=0

    # Check headers first
    if echo "$headers" | grep -qi "cloudflare\|cf-ray"; then
        cloudflare_detected=1
    fi

    # Check DNS nameservers as fallback (Cloudflare nameservers typically end in .ns.cloudflare.com)
    if [ $cloudflare_detected -eq 0 ]; then
        LOG "Checking DNS nameservers for Cloudflare..."

        # NS records only exist on the apex/root domain, not subdomains
        # e.g., www.powermag.com has no NS records, but powermag.com does
        # Strip subdomain to get apex domain (handles www.example.com, sub.example.com, etc.)
        local apex_domain=$(echo "$TARGET_HOST" | awk -F. '{if(NF>2){print $(NF-1)"."$NF}else{print $0}}')
        LOG "Checking NS records for apex domain: $apex_domain"

        # Method 1: nslookup -type=NS on the apex domain
        local nameservers=$(nslookup -type=NS "$apex_domain" 2>/dev/null | grep -i "cloudflare")

        if [ -n "$nameservers" ]; then
            cloudflare_detected=1
            LOG "Cloudflare nameservers found via nslookup"
        fi

        # Method 2: DNS-over-HTTPS fallback (in case nslookup fails)
        if [ $cloudflare_detected -eq 0 ]; then
            local dns_response=$(curl -s -m 5 "https://dns.google/resolve?name=${apex_domain}&type=NS" 2>/dev/null)

            if echo "$dns_response" | grep -qi "cloudflare"; then
                cloudflare_detected=1
                LOG "Cloudflare nameservers found via DNS-over-HTTPS"
            fi
        fi

        # Method 3: Check if target IP is in Cloudflare's IP ranges
        if [ $cloudflare_detected -eq 0 ]; then
            LOG "Checking Cloudflare IP ranges..."
            local dns_a_response=$(curl -s -m 5 "https://dns.google/resolve?name=${TARGET_HOST}&type=A" 2>/dev/null)
            local target_ip=$(echo "$dns_a_response" | grep -oE '"data":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | cut -d'"' -f4)

            if [ -n "$target_ip" ]; then
                # Cloudflare published IP ranges
                if echo "$target_ip" | grep -qE '^104\.(1[6-9]|2[0-9]|3[01])\.|^172\.(6[4-9]|7[01])\.|^103\.2[12]\.|^141\.101\.|^108\.162\.|^190\.93\.|^188\.114\.|^197\.234\.|^198\.41\.|^162\.158\.|^131\.0\.72\.'; then
                    cloudflare_detected=1
                    LOG "Target IP $target_ip is in Cloudflare IP range"
                fi
            fi
        fi
    fi

    if [ $cloudflare_detected -eq 1 ]; then
        log_result "[*] WAF/CDN: Cloudflare detected"
        found_waf=1
    fi

    # Akamai
    if echo "$headers" | grep -qi "akamai"; then
        log_result "[*] CDN: Akamai detected"
        found_waf=1
    fi

    # AWS CloudFront
    if echo "$headers" | grep -qi "cloudfront\|x-amz-cf-id"; then
        log_result "[*] CDN: AWS CloudFront detected"
        found_waf=1
    fi

    # Incapsula
    if echo "$headers" | grep -qi "incapsula\|x-iinfo"; then
        log_result "[*] WAF: Incapsula detected"
        found_waf=1
    fi

    # Sucuri
    if echo "$headers" | grep -qi "sucuri"; then
        log_result "[*] WAF: Sucuri detected"
        found_waf=1
    fi

    # ModSecurity
    if echo "$headers" | grep -qi "mod_security\|NOYB"; then
        log_result "[*] WAF: ModSecurity detected"
        found_waf=1
    fi

    # Generic WAF detection via suspicious blocks
    local test_payload="${TARGET_URL}?test=<script>alert(1)</script>"
    local test_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "$test_payload" 2>/dev/null)

    if [ "$test_status" = "403" ] || [ "$test_status" = "406" ]; then
        log_result "[*] Possible WAF detected (blocks XSS test)"
        found_waf=1
    fi

    if [ $found_waf -eq 0 ]; then
        log_result "[*] No WAF/CDN detected"
    fi

    log_result ""
}

# 11. Technology Fingerprinting
scan_tech() {
    log_result "[+] TECHNOLOGY FINGERPRINTING"
    led_scanning

    LOG "Fingerprinting tech stack..."
    local headers=$(curl -s -I -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
    # Get first 50KB of HTML (enough to catch WP indicators)
    local body=$(curl -s -m $TIMEOUT "$TARGET_URL" 2>/dev/null | head -c 50000)

    # Web servers
    local server=$(echo "$headers" | grep -i "^Server:" | cut -d':' -f2- | tr -d '\r' | sed 's/^ //')
    [ -n "$server" ] && log_result "[*] Web Server: $server"

    # PHP version
    if echo "$headers" | grep -qi "X-Powered-By.*PHP"; then
        local php_ver=$(echo "$headers" | grep -i "X-Powered-By" | grep -o "PHP/[0-9.]*" | tr -d '\r')
        log_result "[*] Backend: $php_ver"
    fi

    # WordPress Detection (multiple methods)
    local is_wordpress=0

    # Method 1: Check HTML for ACTUAL WordPress technical indicators (not just mentions)
    # Look for WordPress-specific paths and generator tags, not just the word "wordpress"
    if echo "$body" | grep -qE '<meta name="generator" content="WordPress|/wp-content/themes/|/wp-content/plugins/|/wp-includes/'; then
        is_wordpress=1
    fi

    # Method 2: Check headers for Pantheon (WordPress hosting)
    if echo "$headers" | grep -qi "pantheon\|x-pantheon"; then
        is_wordpress=1
        log_result "[*] Pantheon hosting detected (WordPress platform)"
    fi

    # Method 3: Test for wp-json API endpoint (with content verification)
    if [ $is_wordpress -eq 0 ]; then
        local wp_api_response=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/wp-json/" 2>/dev/null)
        # Check if response is valid JSON and contains WordPress REST API namespace
        if echo "$wp_api_response" | grep -qi "namespace.*wp/v2\|\"name\":.*\"wordpress\""; then
            is_wordpress=1
        fi
    fi

    # Method 4: Test for wp-login.php (with content verification)
    if [ $is_wordpress -eq 0 ]; then
        local wp_login_response=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/wp-login.php" 2>/dev/null)
        # Check if response contains actual WordPress login form elements
        if echo "$wp_login_response" | grep -qi "wp-submit\|user_login\|\"log in to \|powered by wordpress"; then
            is_wordpress=1
        fi
    fi

    # If WordPress detected by any method, run tests
    if [ $is_wordpress -eq 1 ]; then
        log_result "[*] CMS: WordPress detected"

        # Try to get version
        local wp_ver=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/readme.html" 2>/dev/null | grep -i "Version" | head -1)
        [ -n "$wp_ver" ] && log_result "[*] $wp_ver"

        # WordPress-specific tests
        log_result "[*] Running WordPress tests..."

        # Test for user enumeration via REST API
        local wp_users=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/wp-json/wp/v2/users" 2>/dev/null)
        if echo "$wp_users" | grep -qi "slug\|name"; then
            log_finding "MEDIUM" "WP REST API user enumeration enabled!"
            play_found
            led_found
        fi

        # Test for user enumeration via ?author=1
        # WordPress redirects /?author=1 to /author/username/ revealing the username
        local author_redirect=$(curl -s -o /dev/null -w "%{redirect_url}" -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/?author=1" 2>/dev/null)
        local author_username=""

        if echo "$author_redirect" | grep -q "/author/"; then
            # Extract username from redirect URL (e.g., /author/admin/ -> admin)
            author_username=$(echo "$author_redirect" | sed -n 's|.*/author/\([^/]*\).*|\1|p')
        fi

        # If no redirect, check page content for author info
        if [ -z "$author_username" ]; then
            local author_page=$(curl -s -m $TIMEOUT -L "${TARGET_PROTO}://${TARGET_HOST}/?author=1" 2>/dev/null)
            # Try to extract from author archive page title or URL in content
            if echo "$author_page" | grep -qiE "author/|posts by"; then
                author_username=$(echo "$author_page" | grep -oE 'author/[^/"]+' | head -1 | sed 's|author/||')
            fi
        fi

        if [ -n "$author_username" ]; then
            LOG "green" "WP user enumeration via ?author=1"
            log_finding "MEDIUM" "WP user enumeration via ?author=1"
            log_result "  Username (author=1): $author_username"
            play_found
        fi

        # Test for xmlrpc
        local xmlrpc_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/xmlrpc.php" 2>/dev/null)
        if [ "$xmlrpc_status" = "200" ]; then
            LOG "green" "xmlrpc.php accessible"
            log_finding "LOW" "xmlrpc.php accessible"
            play_found
        fi

        # Test for debug log
        local debug_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/wp-content/debug.log" 2>/dev/null)
        if [ "$debug_status" = "200" ]; then
            LOG "green" "debug.log exposed!"
            log_finding "CRITICAL" "debug.log exposed!"
            play_found
            led_found
        fi

        # Test for wp-admin
        local admin_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/wp-admin/" 2>/dev/null)
        if [ "$admin_status" = "200" ] || [ "$admin_status" = "302" ]; then
            log_result "[*] wp-admin accessible"
        fi

        # Test for wp-login.php
        local login_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/wp-login.php" 2>/dev/null)
        if [ "$login_status" = "200" ]; then
            log_result "[*] wp-login.php accessible"
        fi
    fi

    # Drupal
    if echo "$body" | grep -qi "drupal"; then
        log_result "[*] CMS: Drupal detected"
    fi

    # Joomla
    if echo "$body" | grep -qi "joomla"; then
        log_result "[*] CMS: Joomla detected"
    fi

    # React
    if echo "$body" | grep -qi "react"; then
        log_result "[*] Frontend: React detected"
    fi

    # Vue.js
    if echo "$body" | grep -qi "vue\.js\|__vue__"; then
        log_result "[*] Frontend: Vue.js detected"
    fi

    # Angular
    if echo "$body" | grep -qi "ng-app\|angular"; then
        log_result "[*] Frontend: Angular detected"
    fi

    # jQuery
    if echo "$body" | grep -qi "jquery"; then
        local jquery_ver=$(echo "$body" | grep -o "jquery[/-][0-9.]*" | head -1 | tr -d '\r')
        [ -n "$jquery_ver" ] && log_result "[*] Library: $jquery_ver"
    fi

    log_result ""
}

# 11b. WordPress Version & Vulnerability Scanner
scan_wordpress_vulns() {
    log_result "[+] WORDPRESS VERSION & VULNERABILITY SCAN"
    led_scanning

    LOG "Detecting WordPress version..."

    local wp_version=""
    local wp_detected_by=""
    local wp_evidence=""

    # Method 1: RSS Feed generator tag (most reliable, same as WPScan "Rss Generator")
    LOG "Checking RSS feed..."
    local rss_response=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/feed/" 2>/dev/null)
    local rss_version=$(echo "$rss_response" | grep -oE '<generator>https://wordpress\.org/\?v=[0-9.]+</generator>' | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')

    if [ -n "$rss_version" ]; then
        wp_version="$rss_version"
        wp_detected_by="Rss Generator (Aggressive Detection)"
        wp_evidence="${TARGET_PROTO}://${TARGET_HOST}/feed/"
        LOG "Found WP version $wp_version via RSS feed"
    fi

    # Method 2: Atom Feed generator tag (confirmation, same as WPScan "Atom Generator")
    # Match specifically: <generator uri="https://wordpress.org/" version="6.7.2">WordPress</generator>
    # Do NOT match generic version= attributes (like Atom spec version="1.0")
    LOG "Checking Atom feed..."
    local atom_response=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/feed/atom/" 2>/dev/null)
    local atom_version=$(echo "$atom_response" | grep -oE '<generator[^>]*uri="https://wordpress\.org/"[^>]*version="[0-9]+\.[0-9]+(\.[0-9]+)?"' | grep -oE 'version="[0-9]+\.[0-9]+(\.[0-9]+)?"' | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
    local atom_confirmed=""

    if [ -n "$atom_version" ]; then
        if [ -z "$wp_version" ]; then
            wp_version="$atom_version"
            wp_detected_by="Atom Generator (Aggressive Detection)"
            wp_evidence="${TARGET_PROTO}://${TARGET_HOST}/feed/atom/"
        else
            atom_confirmed="yes"
        fi
        LOG "Found WP version $atom_version via Atom feed"
    fi

    # Method 3: Meta generator tag in HTML source
    LOG "Checking meta generator tag..."
    local body=$(curl -s -m $TIMEOUT "$TARGET_URL" 2>/dev/null | head -c 50000)
    local meta_version=$(echo "$body" | grep -oiE '<meta name="generator" content="WordPress [0-9.]+"' | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')

    if [ -n "$meta_version" ]; then
        if [ -z "$wp_version" ]; then
            wp_version="$meta_version"
            wp_detected_by="Meta Generator (Passive Detection)"
            wp_evidence="HTML source meta tag"
        fi
        LOG "Found WP version $meta_version via meta tag"
    fi

    # Method 4: wp-links-opml.php
    # Output contains: <!--  generator="WordPress/6.9.1"  -->
    LOG "Checking OPML link..."
    local opml_response=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/wp-links-opml.php" 2>/dev/null)
    local opml_version=""

    # Only process if response looks like valid OPML (not a soft-404 HTML page)
    if echo "$opml_response" | grep -qiE '<opml|generator.*WordPress'; then
        opml_version=$(echo "$opml_response" | grep -oE 'WordPress/[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
    fi

    if [ -n "$opml_version" ]; then
        if [ -z "$wp_version" ]; then
            wp_version="$opml_version"
            wp_detected_by="OPML Link (Aggressive Detection)"
            wp_evidence="${TARGET_PROTO}://${TARGET_HOST}/wp-links-opml.php"
        fi
        LOG "Found WP version $opml_version via OPML"
    fi

    # Method 5: readme.html (often removed but worth checking)
    LOG "Checking readme.html..."
    local readme_response=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/readme.html" 2>/dev/null)
    local readme_version=$(echo "$readme_response" | grep -oiE 'Version [0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')

    if [ -n "$readme_version" ]; then
        if [ -z "$wp_version" ]; then
            wp_version="$readme_version"
            wp_detected_by="Readme (Aggressive Detection)"
            wp_evidence="${TARGET_PROTO}://${TARGET_HOST}/readme.html"
        fi
        LOG "Found WP version $readme_version via readme.html"
    fi

    # Method 6: CSS/JS version query strings from WP CORE assets only (e.g., /wp-includes/js/jquery.min.js?ver=6.7.2)
    # Only check /wp-includes/ and /wp-admin/ URLs - theme/plugin assets use their own version numbers
    if [ -z "$wp_version" ]; then
        LOG "Checking WP core asset version strings..."
        local asset_version=$(echo "$body" | grep -oE '/wp-includes/[^"'"'"' >]+\?ver=[0-9]+\.[0-9]+(\.[0-9]+)?' | grep -oE 'ver=[0-9]+\.[0-9]+(\.[0-9]+)?' | sort | uniq -c | sort -rn | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')

        # Also check wp-admin assets if nothing found
        if [ -z "$asset_version" ]; then
            asset_version=$(echo "$body" | grep -oE '/wp-admin/[^"'"'"' >]+\?ver=[0-9]+\.[0-9]+(\.[0-9]+)?' | grep -oE 'ver=[0-9]+\.[0-9]+(\.[0-9]+)?' | sort | uniq -c | sort -rn | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
        fi

        if [ -n "$asset_version" ]; then
            wp_version="$asset_version"
            wp_detected_by="WP Core Asset Versions (Passive Detection)"
            wp_evidence="Most common ?ver= on /wp-includes/ assets"
            LOG "Found likely WP version $asset_version via core asset versions"
        fi
    fi

    # If no WordPress version found, check if it's even WordPress
    if [ -z "$wp_version" ]; then
        # Quick check if this is WordPress at all
        if echo "$body" | grep -qE '/wp-content/|/wp-includes/'; then
            log_result "[*] WordPress detected but version could not be determined"
            log_result "    Version may be hidden by security plugin"
            log_result ""
        else
            log_result "[*] WordPress not detected on this target"
            log_result ""
        fi
        return
    fi

    # === Display version info (WPScan-style output) ===
    log_result ""
    log_result "[+] WordPress version $wp_version identified"
    log_result " | Found By: $wp_detected_by"
    log_result " |  - $wp_evidence"

    if [ "$atom_confirmed" = "yes" ]; then
        log_result " | Confirmed By: Atom Generator (Aggressive Detection)"
        log_result " |  - ${TARGET_PROTO}://${TARGET_HOST}/feed/atom/"
    fi

    log_result " |"

    # === Query WPScan API for vulnerabilities ===
    if [ -z "$WPSCAN_API_TOKEN" ]; then
        log_result " | [*] No WPScan API token configured - skipping vulnerability lookup"
        log_result " |     Get a free token at: https://wpscan.com/register"
        log_result " |     Then set WPSCAN_API_TOKEN in payload config"
        log_result ""

        # Still provide basic version risk assessment without API
        log_result "[*] BASIC VERSION CHECK (without API):"

        # Extract major.minor for comparison
        local major=$(echo "$wp_version" | cut -d. -f1)
        local minor=$(echo "$wp_version" | cut -d. -f2)
        local patch=$(echo "$wp_version" | cut -d. -f3)
        [ -z "$patch" ] && patch="0"

        # Check if version is very old (rough heuristic)
        if [ "$major" -lt 5 ]; then
            log_finding "CRITICAL" "WordPress $wp_version is severely outdated (WP 5.0+ released Dec 2018)"
            play_found
            led_found
        elif [ "$major" -eq 5 ] && [ "$minor" -lt 9 ]; then
            log_finding "HIGH" "WordPress $wp_version is significantly outdated"
            play_found
        elif [ "$major" -eq 6 ] && [ "$minor" -lt 4 ]; then
            log_finding "MEDIUM" "WordPress $wp_version may be outdated - check for updates"
            play_found
        fi

        log_result "    For full vulnerability details, configure WPSCAN_API_TOKEN"
        log_result ""
        return
    fi

    # Format version for API: 6.7.2 -> 672
    local api_version=$(echo "$wp_version" | tr -d '.')
    LOG "Querying WPScan API for WordPress $wp_version..."

    local api_response=$(curl -s -m $TIMEOUT \
        -H "Authorization: Token token=$WPSCAN_API_TOKEN" \
        "https://wpscan.com/api/v3/wordpresses/$api_version" 2>/dev/null)

    # Check for API errors
    if [ -z "$api_response" ]; then
        log_result " | [*] Could not reach WPScan API"
        log_result ""
        return
    fi

    # Check for auth errors
    if echo "$api_response" | grep -qiE '"error"|"Forbidden"|"Unauthorized"'; then
        local api_error=$(echo "$api_response" | grep -oE '"message":"[^"]*"' | cut -d'"' -f4)
        if [ -n "$api_error" ]; then
            log_result " | [*] WPScan API error: $api_error"
        else
            log_result " | [*] WPScan API authentication failed - check your token"
        fi
        log_result ""
        return
    fi

    # WPScan API stores vulns under the base version (major.minor), not the patch version
    # e.g., vulns for 6.0.11 are listed under "60" (6.0), not "6011"
    # If the full version returns no vulnerabilities, fall back to major.minor
    local vuln_count=$(echo "$api_response" | grep -oE '"title":"[^"]*"' | wc -l | tr -d ' ')

    if [ "$vuln_count" -eq 0 ] || [ -z "$vuln_count" ]; then
        local major=$(echo "$wp_version" | cut -d. -f1)
        local minor=$(echo "$wp_version" | cut -d. -f2)
        local base_api_version="${major}${minor}"

        # Only retry if base version is different from what we already tried
        if [ "$base_api_version" != "$api_version" ]; then
            LOG "No vulns found for $wp_version, trying base version ${major}.${minor}..."

            api_response=$(curl -s -m $TIMEOUT \
                -H "Authorization: Token token=$WPSCAN_API_TOKEN" \
                "https://wpscan.com/api/v3/wordpresses/$base_api_version" 2>/dev/null)

            if [ -n "$api_response" ] && ! echo "$api_response" | grep -qiE '"error"'; then
                vuln_count=$(echo "$api_response" | grep -oE '"title":"[^"]*"' | wc -l | tr -d ' ')
                LOG "Found $vuln_count vulnerabilities under base version ${major}.${minor}"
            fi
        fi
    fi

    # Parse vulnerabilities from JSON response
    # WPScan API returns: {"672": {"release_date":"...","changelog_url":"...","status":"insecure","vulnerabilities":[...]}}
    local release_status=""

    # Check if version is marked insecure
    if echo "$api_response" | grep -q '"status":"insecure"'; then
        release_status="Insecure"
    elif echo "$api_response" | grep -q '"status":"latest"'; then
        release_status="Latest"
    else
        release_status="Unknown"
    fi

    # Get release date if available
    local release_date=$(echo "$api_response" | grep -oE '"release_date":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ "$release_status" = "Insecure" ]; then
        log_result " | Status: Insecure$([ -n "$release_date" ] && echo ", released on $release_date")"
        log_finding "HIGH" "WordPress $wp_version is marked INSECURE by WPScan"
        play_found
    elif [ "$release_status" = "Latest" ]; then
        log_result " | Status: Latest$([ -n "$release_date" ] && echo ", released on $release_date")"
        log_finding "INFO" "WordPress $wp_version is the latest version"
    fi

    # Parse all vulnerabilities, then filter to only those affecting the installed version
    # Extract titles and fixed_in versions
    local all_titles=$(echo "$api_response" | grep -oE '"title":"[^"]*"' | cut -d'"' -f4)
    local all_fixed=$(echo "$api_response" | grep -oE '"fixed_in":"[^"]*"' | cut -d'"' -f4)
    local all_cves=$(echo "$api_response" | grep -oE '"cve":\["[0-9-]+"\]|"cve":"[0-9-]+"' | grep -oE '[0-9][0-9-]+[0-9]')

    # First pass: count only vulnerabilities that actually affect the installed version
    # A vuln affects the installed version if:
    #   - fixed_in is GREATER than installed version (not yet patched), OR
    #   - fixed_in is empty/null (no fix available)
    local affecting_count=0
    local affecting_indices=""
    local total_from_api=$(echo "$all_titles" | grep -c '.' 2>/dev/null)
    local check_index=0

    while IFS= read -r check_title; do
        check_index=$((check_index + 1))
        [ -z "$check_title" ] && continue

        local check_fixed=$(echo "$all_fixed" | sed -n "${check_index}p")

        if [ -z "$check_fixed" ]; then
            # No fix available - still vulnerable
            affecting_count=$((affecting_count + 1))
            affecting_indices="$affecting_indices $check_index"
        elif version_less_than "$wp_version" "$check_fixed"; then
            # Installed version is older than the fix - still vulnerable
            affecting_count=$((affecting_count + 1))
            affecting_indices="$affecting_indices $check_index"
        fi
        # Otherwise: fixed_in <= installed version, already patched - skip
    done <<< "$all_titles"

    local patched_count=$((total_from_api - affecting_count))

    if [ "$affecting_count" -gt 0 ]; then
        log_result " |"
        log_result " | [!] $affecting_count vulnerabilit$([ "$affecting_count" -eq 1 ] && echo "y" || echo "ies") affecting $wp_version:"
        [ "$patched_count" -gt 0 ] && log_result " | [*] ($patched_count additional vulnerabilit$([ "$patched_count" -eq 1 ] && echo "y" || echo "ies") already patched in $wp_version)"
        log_result " |"

        # Second pass: display only the affecting vulnerabilities
        for vuln_index in $affecting_indices; do
            local title=$(echo "$all_titles" | sed -n "${vuln_index}p")
            [ -z "$title" ] && continue

            log_result " | [!] Title: $title"

            # Get corresponding fixed_in version
            local fixed_in=$(echo "$all_fixed" | sed -n "${vuln_index}p")
            if [ -n "$fixed_in" ]; then
                log_result " |     Fixed in: $fixed_in"
            else
                log_result " |     Fixed in: No known fix"
            fi

            # Get corresponding CVE
            local cve=$(echo "$all_cves" | sed -n "${vuln_index}p")

            # Build references
            log_result " |     References:"

            # Always try to find wpscan.com reference
            local wpscan_url=$(echo "$api_response" | grep -oE '"url":"https://wpscan\.com/vulnerability/[^"]*"' | cut -d'"' -f4 | sed -n "${vuln_index}p")
            [ -n "$wpscan_url" ] && log_result " |      - $wpscan_url"

            # Add CVE reference
            if [ -n "$cve" ]; then
                log_result " |      - https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-$cve"
            fi

            # Add any other reference URLs (patchstack, wordpress.org, etc)
            echo "$api_response" | grep -oE '"url":"https://(patchstack|wordpress\.org|nvd\.nist\.gov)[^"]*"' | cut -d'"' -f4 | while IFS= read -r ref_url; do
                [ -n "$ref_url" ] && log_result " |      - $ref_url"
            done

            log_result " |"

            # Track severity based on title keywords
            if echo "$title" | grep -qiE "RCE|remote code|SQL injection|authentication bypass|privilege escalation|deserialization"; then
                log_finding "CRITICAL" "Vuln: $title"
                play_found
                led_found
            elif echo "$title" | grep -qiE "XSS|cross.site|CSRF|SSRF|file upload|arbitrary|injection|traversal"; then
                log_finding "HIGH" "Vuln: $title"
                play_found
            elif echo "$title" | grep -qiE "disclosure|sensitive|exposure|enumeration|redirect"; then
                log_finding "MEDIUM" "Vuln: $title"
            else
                log_finding "MEDIUM" "Vuln: $title"
            fi
        done
    else
        log_result " |"
        if [ "$total_from_api" -gt 0 ]; then
            log_result " | [*] $total_from_api known vulnerabilities for this branch, all patched in $wp_version"
        else
            log_result " | [*] No known vulnerabilities found for this version"
        fi
    fi

    # WordPress plugin vulnerability check (bonus - enumerate visible plugins)
    log_result ""
    log_result "[+] WORDPRESS PLUGIN ENUMERATION"
    LOG "Enumerating WordPress plugins..."

    local plugins=$(echo "$body" | grep -oE '/wp-content/plugins/[^/\"'"'"'?]+' | sort -u | sed 's|/wp-content/plugins/||')
    local plugin_count=0

    if [ -n "$plugins" ]; then
        log_result "[*] Plugins detected in page source:"

        while IFS= read -r plugin_slug; do
            [ -z "$plugin_slug" ] && continue
            plugin_count=$((plugin_count + 1))

            # Try to get plugin version from readme.txt
            local plugin_readme=$(curl -s -m 5 "${TARGET_PROTO}://${TARGET_HOST}/wp-content/plugins/${plugin_slug}/readme.txt" 2>/dev/null)
            local plugin_version=""

            if [ -n "$plugin_readme" ] && ! echo "$plugin_readme" | grep -qiE "<!DOCTYPE|<html"; then
                plugin_version=$(echo "$plugin_readme" | grep -iE "^Stable tag:" | head -1 | sed 's/[Ss]table [Tt]ag:[[:space:]]*//' | tr -d '[:space:]')
            fi

            if [ -n "$plugin_version" ] && [ "$plugin_version" != "trunk" ]; then
                log_result " | [*] $plugin_slug (v$plugin_version)"

                # Query WPScan API for plugin vulns if token is set
                if [ -n "$WPSCAN_API_TOKEN" ]; then
                    local plugin_api=$(curl -s -m $TIMEOUT \
                        -H "Authorization: Token token=$WPSCAN_API_TOKEN" \
                        "https://wpscan.com/api/v3/plugins/$plugin_slug" 2>/dev/null)

                    if [ -n "$plugin_api" ] && ! echo "$plugin_api" | grep -qiE '"error"'; then
                        # Count vulns that affect this version (fixed_in > current version or no fix yet)
                        local plugin_vuln_titles=$(echo "$plugin_api" | grep -oE '"title":"[^"]*"' | cut -d'"' -f4)
                        local plugin_vuln_fixed=$(echo "$plugin_api" | grep -oE '"fixed_in":"[^"]*"' | cut -d'"' -f4)
                        local plugin_vuln_count=$(echo "$plugin_vuln_titles" | grep -c '.' 2>/dev/null)

                        if [ "$plugin_vuln_count" -gt 0 ]; then
                            # Show vulnerabilities that may affect installed version
                            local pv_index=0
                            while IFS= read -r pv_title; do
                                pv_index=$((pv_index + 1))
                                [ -z "$pv_title" ] && continue
                                local pv_fixed=$(echo "$plugin_vuln_fixed" | sed -n "${pv_index}p")

                                # Simple version compare: if fixed_in exists and is newer, flag it
                                if [ -n "$pv_fixed" ]; then
                                    # Compare versions (basic: if fixed_in != current, might be vulnerable)
                                    if [ "$pv_fixed" != "$plugin_version" ]; then
                                        log_result " |   [!] $pv_title"
                                        log_result " |       Fixed in: $pv_fixed"
                                        log_finding "HIGH" "Plugin $plugin_slug vuln: $pv_title"
                                        play_found
                                    fi
                                else
                                    # No fix available
                                    log_result " |   [!] $pv_title"
                                    log_result " |       Fixed in: No known fix"
                                    log_finding "CRITICAL" "Plugin $plugin_slug unpatched vuln: $pv_title"
                                    play_found
                                    led_found
                                fi
                            done <<< "$plugin_vuln_titles"
                        fi
                    fi
                fi
            else
                log_result " | [*] $plugin_slug (version unknown)"
            fi
        done <<< "$plugins"

        log_result " |"
        log_result " | [*] $plugin_count plugin(s) found"
    else
        log_result "[*] No plugins detected in page source"
        log_result "    Plugins may be hidden or loaded dynamically"
    fi

    # WordPress theme detection
    log_result ""
    log_result "[+] WORDPRESS THEME DETECTION"
    local theme=$(echo "$body" | grep -oE '/wp-content/themes/[^/\"'"'"'?]+' | sort -u | head -1 | sed 's|/wp-content/themes/||')

    if [ -n "$theme" ]; then
        log_result "[*] Active theme: $theme"

        # Try to get theme version
        local theme_css=$(curl -s -m 5 "${TARGET_PROTO}://${TARGET_HOST}/wp-content/themes/${theme}/style.css" 2>/dev/null | head -30)
        local theme_version=$(echo "$theme_css" | grep -iE "^[[:space:]]*Version:" | head -1 | sed 's/.*Version:[[:space:]]*//' | tr -d '[:space:]')

        [ -n "$theme_version" ] && log_result " | Version: $theme_version"

        # Query WPScan API for theme vulns
        if [ -n "$WPSCAN_API_TOKEN" ] && [ -n "$theme" ]; then
            local theme_api=$(curl -s -m $TIMEOUT \
                -H "Authorization: Token token=$WPSCAN_API_TOKEN" \
                "https://wpscan.com/api/v3/themes/$theme" 2>/dev/null)

            if [ -n "$theme_api" ] && ! echo "$theme_api" | grep -qiE '"error"'; then
                local theme_vuln_titles=$(echo "$theme_api" | grep -oE '"title":"[^"]*"' | cut -d'"' -f4)
                local theme_vuln_count=$(echo "$theme_vuln_titles" | grep -c '.' 2>/dev/null)

                if [ "$theme_vuln_count" -gt 0 ]; then
                    log_result " | [!] $theme_vuln_count known vulnerabilit$([ "$theme_vuln_count" -eq 1 ] && echo "y" || echo "ies"):"
                    echo "$theme_vuln_titles" | head -5 | while IFS= read -r tv_title; do
                        [ -n "$tv_title" ] && log_result " |   [!] $tv_title"
                    done
                    log_finding "MEDIUM" "Theme $theme has $theme_vuln_count known vulnerability/ies"
                    play_found
                fi
            fi
        fi
    else
        log_result "[*] Could not determine active theme"
    fi

    log_result ""
}

# 12. Common Subdomain Checker
scan_subdomains() {
    log_result "[+] SUBDOMAIN ENUMERATION"
    led_scanning

    # Common subdomains to test
    local subdomains=(
        "www" "api" "admin" "dev" "staging" "test"
        "beta" "demo" "portal" "dashboard" "app" "mail"
        "ftp" "vpn" "ssh" "remote" "store" "shop"
        "blog" "forum" "status" "help" "support" "cdn"
        "static" "assets" "images" "media" "upload" "files"
        "mobile" "m" "secure" "login" "auth" "sso"
        "sandbox" "uat" "qa" "prod" "old" "new"
        "v2" "api2" "backend" "server" "db" "database"
        "cloud" "git" "gitlab" "jenkins" "monitor"
    )

    LOG "Testing ${#subdomains[@]} subdomains..."
    local found=0
    local tested=0
    local found_list=()

    for subdomain in "${subdomains[@]}"; do
        tested=$((tested + 1))

        # Progress indicator every 10 subdomains
        if [ $((tested % 10)) -eq 0 ]; then
            LOG "Tested $tested/${#subdomains[@]}..."
        fi

        local test_url="${TARGET_PROTO}://${subdomain}.${TARGET_HOST}"
        local status=$(curl -s -o /dev/null -w "%{http_code}" -m 3 "$test_url" 2>/dev/null)

        # Consider these status codes as "subdomain exists"
        case "$status" in
            200|301|302|303|307|308|401|403)
                LOG "green" "FOUND: ${subdomain}.${TARGET_HOST} [HTTP $status]"
                log_result "[!] FOUND: ${subdomain}.${TARGET_HOST} [HTTP $status]"
                found=$((found + 1))
                found_list+=("${subdomain}")
                play_found
                led_found
                sleep 0.2
                ;;
            *)
                # Silent for 404, 000 (doesn't exist/timeout)
                ;;
        esac

        sleep 0.05
    done

    log_result ""
    if [ $found -eq 0 ]; then
        log_result "[*] No common subdomains found"
    else
        log_result "[*] SUMMARY: Found $found subdomain(s):"
        for sub in "${found_list[@]}"; do
            log_result "    - ${sub}.${TARGET_HOST}"
        done
    fi

    log_result ""
}

# 13. HTML Source Analysis
scan_html_source() {
    log_result "[+] HTML SOURCE ANALYSIS"
    led_scanning

    LOG "Analyzing HTML source..."
    local body=$(curl -s -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
    local found=0

    # Extract HTML comments
    local comments=$(echo "$body" | grep -o '<!--.*-->' | head -10)
    if [ -n "$comments" ]; then
        log_result "[*] HTML Comments found:"
        while IFS= read -r comment; do
            # Clean up and shorten
            comment=$(echo "$comment" | sed 's/<!--//g; s/-->//g' | tr -d '\r' | head -c 100)
            [ -n "$comment" ] && log_result "    $comment"
            found=1
        done <<< "$comments"
    fi

    # Extract email addresses
    local emails=$(echo "$body" | grep -oE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | sort -u | head -5)
    if [ -n "$emails" ]; then
        LOG "green" "Email addresses found!"
        log_finding "INFO" "Email addresses found:"
        while IFS= read -r email; do
            log_result "    $email"
            found=1
        done <<< "$emails"
    fi

    # Look for API keys (common patterns)
    if echo "$body" | grep -qiE 'api[_-]?key|apikey|access[_-]?token|secret[_-]?key'; then
        log_finding "CRITICAL" "Possible API key references in source!"
        play_found
        led_found
        found=1
    fi

    # Look for internal URLs/paths
    local internal_urls=$(echo "$body" | grep -oE '(https?://[^"'"'"' >]+|/[a-zA-Z0-9/_-]+)' | grep -E '(internal|dev|staging|test|admin|api)' | sort -u | head -5)
    if [ -n "$internal_urls" ]; then
        log_finding "MEDIUM" "Internal URLs found:"
        while IFS= read -r url; do
            log_result "    $url"
            found=1
            play_found
        done <<< "$internal_urls"
    fi

    # Look for TODO/FIXME in HTML comments only (not in JS libraries)
    if echo "$comments" | grep -qiE 'TODO|FIXME|HACK|XXX|BUG'; then
        log_finding "LOW" "Developer comments (TODO/FIXME) in HTML comments"
        # Show which ones were found
        local dev_comments=$(echo "$comments" | grep -iE 'TODO|FIXME|HACK|XXX|BUG' | head -3)
        while IFS= read -r comment; do
            [ -n "$comment" ] && log_result "    $(echo "$comment" | sed 's/<!--//g; s/-->//g' | tr -d '\r' | head -c 80)"
        done <<< "$dev_comments"
        found=1
        play_found
    fi

    # Look for stack traces or error messages (in visible HTML, not JS)
    # Only flag if we find actual stack traces, not just the word "error"
    if echo "$body" | grep -qiE '<pre.*stack|<div.*exception|Fatal error:|Uncaught|Notice:|Warning:.*line'; then
        log_finding "MEDIUM" "Possible stack trace/error in source"
        log_result "  What: Debug errors or crash details visible on the page"
        log_result "  Risk: May expose file paths, database info, or code structure"
        log_result "  Fix:  Disable debug mode in production, log errors server-side"
        found=1
        play_found
    fi

    if [ $found -eq 0 ]; then
        log_result "[*] No interesting data in HTML source"
    fi

    log_result ""
}

# 14. Cloud Metadata Endpoints
scan_cloud_metadata() {
    log_result "[+] CLOUD METADATA ENDPOINTS"
    led_scanning

    LOG "Testing cloud metadata APIs..."
    local found=0

    # Get baseline: normal page response for comparison
    LOG "Getting baseline response..."
    local baseline_response=$(curl -s -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
    local baseline_size=${#baseline_response}
    LOG "Baseline size: $baseline_size bytes"

    # Helper function to check if response contains metadata
    check_metadata_content() {
        local response="$1"
        local provider="$2"

        # AWS metadata keywords
        if [ "$provider" = "aws" ]; then
            if echo "$response" | grep -qE 'ami-id|instance-id|instance-type|local-hostname|local-ipv4|public-hostname|security-credentials'; then
                return 0  # Found metadata
            fi
        fi

        # GCP metadata keywords
        if [ "$provider" = "gcp" ]; then
            if echo "$response" | grep -qE 'computeMetadata|instance/id|instance/hostname|instance/zone|service-accounts'; then
                return 0  # Found metadata
            fi
        fi

        # Azure metadata keywords
        if [ "$provider" = "azure" ]; then
            if echo "$response" | grep -qE '"vmId"|"subscriptionId"|"resourceGroupName"|"compute":|"network":'; then
                return 0  # Found metadata
            fi
        fi

        return 1  # No metadata found
    }

    # AWS Metadata
    log_result "[*] Testing AWS metadata..."
    local aws_meta="${TARGET_URL}?url=http://169.254.169.254/latest/meta-data/"
    local aws_response=$(curl -s -m $TIMEOUT "$aws_meta" 2>/dev/null)
    local aws_size=${#aws_response}
    local aws_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "$aws_meta" 2>/dev/null)

    if [ "$aws_status" = "200" ]; then
        # Check if response is different from baseline
        local size_diff=$((aws_size - baseline_size))
        size_diff=${size_diff#-}  # Absolute value

        if check_metadata_content "$aws_response" "aws"; then
            LOG "green" "CONFIRMED AWS SSRF - Metadata content detected!"
            log_finding "CRITICAL" "CONFIRMED AWS SSRF - Metadata content detected!"
            play_found
            led_found
            found=1
        elif [ $size_diff -gt 1000 ]; then
            log_result "[?] Possible AWS SSRF (different response size: $aws_size vs $baseline_size) - VERIFY MANUALLY"
            found=1
        else
            log_result "[*] AWS test returned 200 but appears to be normal page (likely false positive)"
        fi
    fi

    # Try direct access (if scanner is running on AWS)
    local aws_direct=$(curl -s -m 2 "http://169.254.169.254/latest/meta-data/" 2>/dev/null)
    if [ -n "$aws_direct" ] && check_metadata_content "$aws_direct" "aws"; then
        LOG "green" "Direct AWS metadata access detected!"
        log_finding "CRITICAL" "Direct AWS metadata access (scanner running on AWS instance)"
        play_found
        led_found
        found=1
    fi

    # GCP Metadata
    log_result "[*] Testing GCP metadata..."
    local gcp_meta="${TARGET_URL}?url=http://metadata.google.internal/computeMetadata/v1/"
    local gcp_response=$(curl -s -m $TIMEOUT "$gcp_meta" 2>/dev/null)
    local gcp_size=${#gcp_response}
    local gcp_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "$gcp_meta" 2>/dev/null)

    if [ "$gcp_status" = "200" ]; then
        local size_diff=$((gcp_size - baseline_size))
        size_diff=${size_diff#-}

        if check_metadata_content "$gcp_response" "gcp"; then
            LOG "green" "CONFIRMED GCP SSRF - Metadata content detected!"
            log_finding "CRITICAL" "CONFIRMED GCP SSRF - Metadata content detected!"
            play_found
            led_found
            found=1
        elif [ $size_diff -gt 1000 ]; then
            log_result "[?] Possible GCP SSRF (different response size: $gcp_size vs $baseline_size) - VERIFY MANUALLY"
            found=1
        else
            log_result "[*] GCP test returned 200 but appears to be normal page (likely false positive)"
        fi
    fi

    # Azure Metadata
    log_result "[*] Testing Azure metadata..."
    local azure_meta="${TARGET_URL}?url=http://169.254.169.254/metadata/instance?api-version=2021-02-01"
    local azure_response=$(curl -s -m $TIMEOUT "$azure_meta" 2>/dev/null)
    local azure_size=${#azure_response}
    local azure_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "$azure_meta" 2>/dev/null)

    if [ "$azure_status" = "200" ]; then
        local size_diff=$((azure_size - baseline_size))
        size_diff=${size_diff#-}

        if check_metadata_content "$azure_response" "azure"; then
            LOG "green" "CONFIRMED Azure SSRF - Metadata content detected!"
            log_finding "CRITICAL" "CONFIRMED Azure SSRF - Metadata content detected!"
            play_found
            led_found
            found=1
        elif [ $size_diff -gt 1000 ]; then
            log_result "[?] Possible Azure SSRF (different response size: $azure_size vs $baseline_size) - VERIFY MANUALLY"
            found=1
        else
            log_result "[*] Azure test returned 200 but appears to be normal page (likely false positive)"
        fi
    fi

    # Test common SSRF parameters with smarter detection
    log_result "[*] Testing common SSRF parameters..."
    local ssrf_params=("url" "file" "path" "redirect" "uri" "link" "src")
    local param_found=0

    for param in "${ssrf_params[@]}"; do
        local test_url="${TARGET_URL}?${param}=http://169.254.169.254/"
        local param_response=$(curl -s -m $TIMEOUT "$test_url" 2>/dev/null)
        local param_size=${#param_response}
        local status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "$test_url" 2>/dev/null)

        if [ "$status" = "200" ]; then
            local size_diff=$((param_size - baseline_size))
            size_diff=${size_diff#-}

            # Check for metadata content or significant size difference
            if check_metadata_content "$param_response" "aws" || \
               check_metadata_content "$param_response" "gcp" || \
               check_metadata_content "$param_response" "azure"; then
                LOG "green" "CONFIRMED SSRF via parameter: $param"
                log_finding "CRITICAL" "CONFIRMED SSRF via parameter: $param (metadata content detected)"
                play_found
                led_found
                param_found=1
                found=1
            elif [ $size_diff -gt 1000 ]; then
                log_result "[?] Possible SSRF via parameter: $param (different response) - VERIFY MANUALLY"
                param_found=1
                found=1
            fi
        elif [ "$status" = "500" ]; then
            # 500 could indicate server tried to process the URL
            log_result "[?] Parameter '$param' caused 500 error (might process URLs) - VERIFY MANUALLY"
            param_found=1
            found=1
        fi
    done

    if [ $param_found -eq 0 ]; then
        log_result "[*] No SSRF parameters detected"
    fi

    if [ $found -eq 0 ]; then
        log_result "[*] No cloud metadata exposure detected"
    else
        # Add verification guide if findings were detected
        log_result ""
        log_result "━━━ HOW TO VERIFY SSRF ━━━"
        log_result "For findings marked [?], manually test SSRF vulnerabilities:"
        log_result ""
        log_result "Test with Burp Collaborator or webhook.site:"
        log_result "  1. Get a unique URL from webhook.site or Burp Collaborator"
        log_result "  2. Test: ${TARGET_URL}?url=http://YOUR-UNIQUE-URL.webhook.site"
        log_result "  3. Check if the server made a request to your URL"
        log_result ""
        log_result "Test internal network access:"
        log_result "  ${TARGET_URL}?url=http://127.0.0.1:80"
        log_result "  ${TARGET_URL}?url=http://localhost/admin"
        log_result "  ${TARGET_URL}?url=http://169.254.169.254/latest/meta-data/"
        log_result ""
        log_result "Test for AWS metadata (if on AWS):"
        log_result "  ${TARGET_URL}?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/"
        log_result "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_result ""
    fi

    log_result "NOTE: [!!!] = High confidence | [?] = Requires manual verification | [*] = Likely false positive"
    log_result ""
}

# Show severity summary
show_severity_summary() {
    local total=$((CRITICAL_FINDINGS + HIGH_FINDINGS + MEDIUM_FINDINGS + LOW_FINDINGS))

    # Format elapsed time
    local time_display=""
    if [ $ELAPSED_MINUTES -gt 0 ]; then
        time_display="${ELAPSED_MINUTES}m ${ELAPSED_SECS}s"
    else
        time_display="${ELAPSED_SECS}s"
    fi

    log_result ""
    log_result "╔════════════════════════════════════╗"
    log_result "║    SEVERITY SUMMARY               ║"
    log_result "╠════════════════════════════════════╣"
    log_result "║  🔴 CRITICAL: $CRITICAL_FINDINGS"
    log_result "║  🟠 HIGH:     $HIGH_FINDINGS"
    log_result "║  🟡 MEDIUM:   $MEDIUM_FINDINGS"
    log_result "║  🟢 LOW:      $LOW_FINDINGS"
    log_result "║  ℹ️  INFO:     $INFO_FINDINGS"
    log_result "╠════════════════════════════════════╣"
    log_result "║  TOTAL FINDINGS: $total"
    log_result "║  ⏱️  ELAPSED TIME: $time_display"
    log_result "╚════════════════════════════════════╝"
    log_result ""
}

# === MAIN MENU ===

show_menu() {
    PROMPT "=== CURLY SCANNER ===\n\nSelect scan mode:\n\n1. Quick Scan\n2. Full Scan (All Modules)\n3. API Recon\n4. Security Audit\n5. Tech Fingerprint\n6. Subdomain Enum"
}

# === MAIN ===

LOG "green" "================================"
LOG "green" "     CURLY - Web Recon Scanner"
LOG "green" "        by curtthecoder"
LOG "green" "================================"
LOG ""

# === CONNECTION CHECK ===
LOG "yellow" "[*] Checking internet connection..."

# Try to reach a reliable public endpoint (Google DNS responds fast)
CONN_TEST=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "https://dns.google/resolve?name=google.com&type=A" 2>/dev/null)

if [ "$CONN_TEST" != "200" ]; then
    # Try a second endpoint in case the first is blocked
    CONN_TEST=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null)
fi

if [ "$CONN_TEST" != "200" ]; then
    LOG ""
    LOG "red" "========================================"
    LOG "red" "  NO INTERNET CONNECTION DETECTED!"
    LOG "red" "========================================"
    LOG ""
    LOG "red" "  Curly requires an internet connection"
    LOG "red" "  to scan targets."
    LOG ""
    LOG "red" "  Please connect to WiFi first:"
    LOG "red" "    Settings -> WiFi Client Mode"
    LOG ""
    LOG "red" "  Then re-run this payload."
    LOG "red" "========================================"
    led_off
    VIBRATE 100
    sleep 1
    VIBRATE 100
    exit 1
fi

LOG "    [OK] Internet connection verified"
LOG ""

# Version check
CURRENT_VERSION="3.8"
VERSION_CHECK_URL="https://raw.githubusercontent.com/hak5/wifipineapplepager-payloads/master/library/user/reconnaissance/curly/VERSION"
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
            LOG "green" "  UPDATE AVAILABLE!"
            LOG "green" "  Current: v${CURRENT_VERSION} -> Latest: v${LATEST_VERSION}"
            LOG "green" "  Update at: github.com/hak5/wifipineapplepager-payloads"
            LOG "========================================================"
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

# Get target URL from user
LOG "Please enter target URL..."
LOG "(e.g., example.com)"
TARGET_URL=$(TEXT_PICKER "Enter target URL" "example.com")

# Check if user cancelled or rejected
case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG "User cancelled"
        exit 1
        ;;
    $DUCKYSCRIPT_REJECTED)
        LOG "Dialog rejected"
        exit 1
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG "An error occurred"
        exit 1
        ;;
esac

if [ -z "$TARGET_URL" ]; then
    LOG "No target provided!"
    exit 1
fi

# Ensure URL has protocol
if ! echo "$TARGET_URL" | grep -qE '^https?://'; then
    TARGET_URL="https://$TARGET_URL"
fi

parse_url "$TARGET_URL"
TARGET_URL="${TARGET_PROTO}://${TARGET_HOST}"

# Follow any redirects to get final destination (e.g., example.com -> www.example.com)
follow_redirects

init_loot

LOG ""
LOG "Target: $TARGET_URL"
LOG ""

# Menu selection
show_menu
SCAN_MODE=$(NUMBER_PICKER "Select scan mode" "1")

# Check if user cancelled
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG "Operation cancelled"
        exit 1
        ;;
esac

LOG ""

# Display estimated time for selected scan mode
case $SCAN_MODE in
    1) LOG "Starting Quick Scan (estimated: ~30-45 seconds)..." ;;
    2) LOG "Starting Full Scan (estimated: ~5-25 minutes)..." ;;
    3) LOG "Starting API Recon (estimated: ~45-60 seconds)..." ;;
    4) LOG "Starting Security Audit (estimated: ~90-120 seconds)..." ;;
    5) LOG "Starting Tech Fingerprint (estimated: ~20-30 seconds)..." ;;
    6) LOG "Starting Subdomain Enumeration (estimated: ~30-45 seconds)..." ;;
esac

# Capture start time
SCAN_START_TIME=$(date +%s)
play_scan

case $SCAN_MODE in
    1)  # Quick Scan
        scan_ip_geolocation
        scan_protocol_availability
        scan_whois
        scan_ssl_tls
        scan_waf
        scan_tech
        scan_wordpress_vulns
        scan_info
        scan_endpoints
        scan_html_source
        ;;
    2)  # Full Scan (All Modules)
        scan_ip_geolocation
        scan_protocol_availability
        scan_whois
        scan_ssl_tls
        scan_waf
        scan_tech
        scan_wordpress_vulns
        scan_subdomains
        scan_info
        scan_html_source
        scan_endpoints
        scan_backups
        scan_parameters
        scan_methods
        scan_headers
        scan_cookies
        scan_cors
        scan_redirects
        scan_cloud_metadata
        scan_api
        ;;
    3)  # API Recon
        scan_subdomains
        scan_endpoints
        scan_api
        ;;
    4)  # Security Audit
        scan_ip_geolocation
        scan_protocol_availability
        scan_whois
        scan_ssl_tls
        scan_tech
        scan_wordpress_vulns
        scan_info
        scan_html_source
        scan_parameters
        scan_methods
        scan_headers
        scan_cookies
        scan_cors
        scan_redirects
        scan_cloud_metadata
        ;;
    5)  # Tech Fingerprint
        scan_ip_geolocation
        scan_protocol_availability
        scan_whois
        scan_ssl_tls
        scan_waf
        scan_tech
        scan_wordpress_vulns
        scan_info
        ;;
    6)  # Subdomain Enumeration
        scan_subdomains
        ;;
    *)
        LOG "Invalid scan mode!"
        exit 1
        ;;
esac

# Calculate elapsed time
SCAN_END_TIME=$(date +%s)
ELAPSED_SECONDS=$((SCAN_END_TIME - SCAN_START_TIME))
ELAPSED_MINUTES=$((ELAPSED_SECONDS / 60))
ELAPSED_SECS=$((ELAPSED_SECONDS % 60))

# Show severity summary
show_severity_summary

led_success
play_complete
VIBRATE 50

LOG ""
LOG "Scan complete!"
LOG "Results: $LOOTFILE"
LOG ""

# Send results to Discord if webhook is configured
send_to_discord

LOG "Check loot dir for details"
