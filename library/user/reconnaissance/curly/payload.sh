#!/bin/bash
# Title: Curly - Web Recon & Vuln Scanner
# Description: Curl-based web reconnaissance and vulnerability testing for pentesting and bug bounty hunting
# Author: curtthecoder - github.com/curthayman
# Version: 4.0

# === CONFIG ===
LOOTDIR=/root/loot/curly
INPUT=/dev/input/event0
TIMEOUT=10
DISCORD_WEBHOOK=""  # Set your Discord webhook URL here
SLACK_WEBHOOK=""    # Set your Slack incoming webhook URL here
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

        local timestamp=$(date)
        local header_json=$(cat <<EOF
{
  "content": "**🎯 Curly Scan Complete**\n\`\`\`\nTarget: $TARGET_URL\nMode: $SCAN_MODE\nTime: $timestamp\n\`\`\`"
}
EOF
)

        LOG "Sending header message..."
        local header_response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -H "Content-Type: application/json" \
             -d "$header_json" \
             "$DISCORD_WEBHOOK" 2>&1)
        local header_code=$(echo "$header_response" | grep "HTTP_CODE:" | cut -d: -f2)
        LOG "Header response code: $header_code"

        LOG "Extracting findings from loot file..."
        local findings=$(awk '
            /^\[\+\]/ {
                section = $0
                in_finding = 0
                next
            }
            /^\[!!!\]|^\[!!\]|^\[!\]/ {
                if (section != "" && section != last_section) {
                    print ""
                    print section
                    last_section = section
                }
                print
                in_finding = 1
                detail_count = 0
                next
            }
            in_finding && detail_count < 3 {
                if (/^[[:space:]]*$/ || /^\[/) {
                    in_finding = 0
                    next
                }
                print
                detail_count++
                next
            }
            /^\[/ { in_finding = 0 }
        ' "$LOOTFILE")

        local findings_lines=$(echo -e "$findings" | wc -l | tr -d ' ')
        LOG "Extracted $findings_lines lines of findings"

        if [ -n "$findings" ]; then
            LOG "Sending findings to Discord..."

            local tmpfile="/tmp/curly_results_$$"
            echo "$findings" > "$tmpfile"

            LOG "Uploading results file..."
            local upload_response=$(curl -s -w "\nHTTP:%{http_code}" \
                 -F "content=**📊 Scan Results**" \
                 -F "file=@$tmpfile;filename=results.txt" \
                 "$DISCORD_WEBHOOK" 2>&1)
            local upload_code=$(echo "$upload_response" | grep "HTTP:" | cut -d: -f2)
            LOG "Upload response: $upload_code"

            rm -f "$tmpfile"

            LOG "Results sent to Discord!"
        else
            LOG "No findings extracted, sending summary..."
            local summary_json='{"content":"**Scan Complete** - No significant findings"}'
            curl -s -H "Content-Type: application/json" \
                 -d "$summary_json" \
                 "$DISCORD_WEBHOOK" >/dev/null 2>&1
            LOG "Summary sent to Discord!"
        fi
}

# === SLACK NOTIFICATION ===
send_to_slack() {
    if [ -z "$SLACK_WEBHOOK" ]; then
        LOG "No Slack webhook configured, skipping"
        return
    fi

    if [ ! -f "$LOOTFILE" ]; then
        return
    fi

    LOG "Sending results to Slack..."

    local timestamp total
    timestamp=$(date)
    total=$((CRITICAL_FINDINGS + HIGH_FINDINGS + MEDIUM_FINDINGS + LOW_FINDINGS + INFO_FINDINGS))

    json_esc() {
        echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}' | tr -d '\n'
    }

    local header_text
    header_text=$(json_esc "*Curly Scan Complete*
\`\`\`Target: $TARGET_URL
Mode:   $SCAN_MODE
Time:   $timestamp\`\`\`")
    curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"text\":\"${header_text}\"}" \
        "$SLACK_WEBHOOK" >/dev/null 2>&1
    local header_code=$?
    LOG "Slack header sent (exit $header_code)"

    local summary_text
    summary_text=$(json_esc "\`\`\`SEVERITY SUMMARY
🔴 CRITICAL : $CRITICAL_FINDINGS
🟠 HIGH      : $HIGH_FINDINGS
🟡 MEDIUM    : $MEDIUM_FINDINGS
🟢 LOW       : $LOW_FINDINGS
ℹ️  INFO     : $INFO_FINDINGS
─────────────────
TOTAL        : $total\`\`\`")
    curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"text\":\"${summary_text}\"}" \
        "$SLACK_WEBHOOK" >/dev/null 2>&1

    if [ $((CRITICAL_FINDINGS + HIGH_FINDINGS)) -gt 0 ]; then
        local raw_findings
        raw_findings=$(grep -E "^\[!!!\]|^\[!!\]" "$LOOTFILE" | head -20)
        if [ -n "$raw_findings" ]; then
            local findings_text
            findings_text=$(json_esc "*Key Findings:*
\`\`\`$(echo "$raw_findings" | head -c 1800)\`\`\`")
            curl -s -X POST -H "Content-Type: application/json" \
                -d "{\"text\":\"${findings_text}\"}" \
                "$SLACK_WEBHOOK" >/dev/null 2>&1
        fi
    fi

    LOG "Results sent to Slack!"
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
    GPS_COORDS=$(GPS_GET 2>/dev/null | head -1)
    if [ -n "$GPS_COORDS" ] && ! echo "$GPS_COORDS" | grep -qE "^[0[:space:]]+$"; then
        echo "GPS: $GPS_COORDS" >> "$LOOTFILE"
    fi
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
    TARGET_HOST=$(echo "$url" | sed -E 's|^https?://||' | cut -d'/' -f1 | cut -d':' -f1)
    TARGET_PROTO=$(echo "$url" | grep -q "https://" && echo "https" || echo "http")
}

# Follow redirects to get final URL
follow_redirects() {
    LOG "Following redirects..."
    local final_url=$(curl -sIL -m $TIMEOUT "$TARGET_URL" 2>/dev/null | grep -i "^location:" | tail -1 | cut -d' ' -f2 | tr -d '\r')

    if [ -n "$final_url" ]; then
        LOG "Redirect detected: $final_url"

        if [[ "$final_url" =~ ^/ ]]; then
            TARGET_URL="${TARGET_PROTO}://${TARGET_HOST}${final_url}"
            LOG "Relative redirect resolved to: $TARGET_URL"
        else
            TARGET_URL="$final_url"
            parse_url "$TARGET_URL"
            TARGET_URL="${TARGET_PROTO}://${TARGET_HOST}"
            LOG "Updated target: $TARGET_URL"
        fi
    fi
}

# Compare two version strings: returns 0 if v1 < v2, 1 if v1 >= v2
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

    LOG "Resolving IP address..."
    local target_ip=$(nslookup "$TARGET_HOST" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | tail -1 | awk '{print $2}')

    if [ -z "$target_ip" ]; then
        target_ip=$(host "$TARGET_HOST" 2>/dev/null | grep "has address" | head -1 | awk '{print $4}')
    fi

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

    LOG "Querying ipinfo.io..."
    local ipinfo=$(curl -s -m $TIMEOUT "https://ipinfo.io/${target_ip}/json" 2>/dev/null)

    if [ -z "$ipinfo" ]; then
        log_result "[*] Could not retrieve IP info"
        log_result ""
        return
    fi

    local hostname=$(echo "$ipinfo" | grep -o '"hostname"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local city=$(echo "$ipinfo" | grep -o '"city"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local region=$(echo "$ipinfo" | grep -o '"region"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local country=$(echo "$ipinfo" | grep -o '"country"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local loc=$(echo "$ipinfo" | grep -o '"loc"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local org=$(echo "$ipinfo" | grep -o '"org"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local postal=$(echo "$ipinfo" | grep -o '"postal"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    local timezone=$(echo "$ipinfo" | grep -o '"timezone"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)

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

    local apex_domain=$(echo "$TARGET_HOST" | awk -F'.' '{if(NF>2) print $(NF-1)"."$NF; else print $0}')

    local rdap_json=$(curl -s -L -m $TIMEOUT "https://rdap.org/domain/${apex_domain}" 2>/dev/null)

    local raw_date=$(echo "$rdap_json" | jq -r '.events[] | select(.eventAction=="registration") | .eventDate' 2>/dev/null)

    if [ -z "$raw_date" ] || [ "$raw_date" = "null" ]; then
        raw_date=$(echo "$rdap_json" | jq -r '.events[] | select(.eventAction | ascii_downcase == "registration") | .eventDate' 2>/dev/null | head -1)
    fi

    if [ -z "$raw_date" ] || [ "$raw_date" = "null" ]; then
        log_result "[*] Creation date unavailable"
        log_result ""
        return
    fi

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

    if [ "$TARGET_PROTO" != "https" ]; then
        log_finding "INFO" "Target uses HTTP - skipping SSL/TLS checks"
        log_result ""
        return
    fi

    LOG "Analyzing SSL/TLS configuration..."

    local ssl_info=$(echo | timeout 5 openssl s_client -connect "${TARGET_HOST}:443" -servername "$TARGET_HOST" 2>/dev/null)

    if [ -z "$ssl_info" ]; then
        log_result "[*] Could not connect via SSL/TLS"
        log_result ""
        return
    fi

    local cert_dates=$(echo "$ssl_info" | openssl x509 -noout -dates 2>/dev/null)
    local not_after=$(echo "$cert_dates" | grep "notAfter" | cut -d'=' -f2)

    if [ -n "$not_after" ]; then
        log_result "[*] Certificate expires: $not_after"

        if ! echo "$ssl_info" | openssl x509 -noout -checkend 0 2>/dev/null; then
            log_finding "CRITICAL" "SSL Certificate EXPIRED! ($not_after)"
            play_found; led_found
        elif ! echo "$ssl_info" | openssl x509 -noout -checkend 2592000 2>/dev/null; then
            log_finding "HIGH" "SSL Certificate expires within 30 days: $not_after"
            play_found
        elif ! echo "$ssl_info" | openssl x509 -noout -checkend 5184000 2>/dev/null; then
            log_finding "MEDIUM" "SSL Certificate expires within 60 days: $not_after"
            play_found
        else
            log_finding "INFO" "SSL Certificate valid"
        fi
    fi

    if echo "$ssl_info" | grep -q "self signed certificate"; then
        log_finding "HIGH" "Self-signed certificate detected"
        play_found
    fi

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

    local cipher=$(echo "$ssl_info" | grep "Cipher is" | awk '{print $NF}' | tr -d '\r')
    if [ -z "$cipher" ]; then
        cipher=$(echo "$ssl_info" | grep -E "^\s+Cipher\s*:" | awk '{print $NF}' | tr -d '\r')
    fi

    if [ -n "$cipher" ]; then
        log_result "[*] Cipher Suite: $cipher"

        if echo "$cipher" | grep -qiE "(NULL|EXPORT|DES|RC4|MD5|anon)"; then
            log_finding "CRITICAL" "Weak cipher detected: $cipher"
            play_found
            led_found
        fi
    fi

    if echo "$ssl_info" | grep -q "Verify return code: 0"; then
        log_result "[*] Certificate chain valid"
    else
        local verify_error=$(echo "$ssl_info" | grep "Verify return code:" | cut -d':' -f2-)
        if [ -n "$verify_error" ]; then
            log_finding "MEDIUM" "Certificate chain issue:$verify_error"
        fi
    fi

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

    local http_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT --connect-timeout 5 "$http_url" 2>/dev/null)
    local http_available=false
    if [ -n "$http_status" ] && [ "$http_status" != "000" ]; then
        http_available=true
    fi

    local https_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT --connect-timeout 5 "$https_url" 2>/dev/null)
    local https_available=false
    if [ -n "$https_status" ] && [ "$https_status" != "000" ]; then
        https_available=true
    fi

    if [ "$http_available" = "true" ] && [ "$https_available" = "true" ]; then
        log_result "[*] HTTP available  (port 80):  HTTP $http_status"
        log_result "[*] HTTPS available (port 443): HTTP $https_status"

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

    log_result "--- Response Headers ---"
    curl -sI -m $TIMEOUT "$TARGET_URL" 2>/dev/null | tr -d '\r' | tee -a "$LOOTFILE" | head -5 | while read line; do LOG "$line"; done

    log_result ""
    log_result "--- Security Headers Check ---"
    local headers=$(curl -sI -m $TIMEOUT "$TARGET_URL" 2>/dev/null)

    [ -z "$(echo "$headers" | grep -i 'X-Frame-Options')" ] && LOG "green" "Missing: X-Frame-Options" && log_finding "MEDIUM" "Missing: X-Frame-Options" && play_found
    [ -z "$(echo "$headers" | grep -i 'X-Content-Type-Options')" ] && LOG "green" "Missing: X-Content-Type-Options" && log_finding "MEDIUM" "Missing: X-Content-Type-Options" && play_found
    local hsts_header
    hsts_header=$(echo "$headers" | grep -i 'Strict-Transport-Security')
    if [ -z "$hsts_header" ]; then
        LOG "green" "Missing: HSTS" && log_finding "MEDIUM" "Missing: HSTS" && play_found
    else
        local hsts_age
        hsts_age=$(echo "$hsts_header" | grep -oE 'max-age=[0-9]+' | grep -oE '[0-9]+')
        if [ -n "$hsts_age" ] && [ "$hsts_age" -lt 31536000 ]; then
            log_finding "LOW" "HSTS max-age=${hsts_age}s — too short (recommended: 31536000 / 1 year)"
            play_found
        fi
    fi
    [ -z "$(echo "$headers" | grep -i 'Content-Security-Policy')" ] && LOG "green" "Missing: CSP" && log_finding "MEDIUM" "Missing: CSP" && play_found

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
        "/admin"
        "/admin.php"
        "/administrator"
        "/login"
        "/console"
        "/api"
        "/api/v1"
        "/api/v2"
        "/api/docs"
        "/swagger.json"
        "/swagger-ui.html"
        "/openapi.json"
        "/graphql"
        "/graphiql"
        "/actuator"
        "/actuator/env"
        "/actuator/health"
        "/actuator/metrics"
        "/actuator/mappings"
        "/actuator/trace"
        "/debug"
        "/trace"
        "/metrics"
        "/health"
        "/status"
        "/info"
        "/telescope"
        "/__debug__/"
        "/manager/html"
        "/manager/status"
    )

    LOG "Checking ${#endpoints[@]} endpoints..."
    local found=0

    local homepage_response=$(curl -s -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
    local homepage_hash=$(echo "$homepage_response" | md5sum | cut -d' ' -f1)
    local homepage_size=${#homepage_response}
    local homepage_title=$(echo "$homepage_response" | grep -oiE '<title>[^<]+</title>' | head -1)

    LOG "Baseline: size=$homepage_size, hash=$homepage_hash"

    for endpoint in "${endpoints[@]}"; do
        local url="${TARGET_PROTO}://${TARGET_HOST}${endpoint}"
        local status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "$url" 2>/dev/null)

        if [ "$status" = "200" ]; then
            local response=$(curl -s -m $TIMEOUT "$url" 2>/dev/null)
            local response_hash=$(echo "$response" | md5sum | cut -d' ' -f1)
            local response_size=${#response}

            local is_real=1
            local severity="INFO"

            if [ "$response_hash" = "$homepage_hash" ]; then
                is_real=0
            fi

            if [ $is_real -eq 1 ]; then
                local response_title=$(echo "$response" | grep -oiE '<title>[^<]+</title>' | head -1)
                if [ -n "$homepage_title" ] && [ "$response_title" = "$homepage_title" ]; then
                    local size_diff=$((response_size - homepage_size))
                    size_diff=${size_diff#-}  # Absolute value
                    local threshold=$((homepage_size / 20))
                    if [ $size_diff -lt $threshold ] || [ $size_diff -lt 500 ]; then
                        is_real=0
                    fi
                fi
            fi

            if [ $is_real -eq 1 ]; then
                if [[ "$endpoint" =~ ^/\.env$ ]]; then
                    if echo "$response" | grep -qiE "<!DOCTYPE|<html|<head"; then
                        is_real=0
                    elif ! echo "$response" | grep -qE "^[A-Z_]+=" ; then
                        is_real=0
                    else
                        severity="CRITICAL"
                    fi
                elif [[ "$endpoint" =~ phpinfo\.php$ ]]; then
                    if ! echo "$response" | grep -qi "php version\|phpinfo()"; then
                        is_real=0
                    else
                        severity="CRITICAL"
                    fi
                elif [[ "$endpoint" =~ ^/\.(git|aws) ]]; then
                    if echo "$response" | grep -qiE "<!DOCTYPE|<html|<head"; then
                        is_real=0
                    else
                        severity="CRITICAL"
                    fi
                elif [[ "$endpoint" =~ /swagger\.json$|/openapi\.json$ ]]; then
                    if ! echo "$response" | grep -qiE "\"swagger\":|\"openapi\":"; then
                        is_real=0
                    fi
                elif [[ "$endpoint" =~ /robots\.txt$ ]]; then
                    if ! echo "$response" | grep -qiE "user-agent|disallow|allow|sitemap"; then
                        is_real=0
                    fi
                elif [[ "$endpoint" =~ /sitemap.*\.xml$ ]]; then
                    if ! echo "$response" | grep -qiE "<urlset|<sitemapindex|<\?xml"; then
                        is_real=0
                    fi
                elif [[ "$endpoint" =~ /actuator ]]; then
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
                    if echo "$response" | grep -qiE "graphql\|graphiql\|\"data\":\|\"errors\":"; then
                        severity="INFO"
                    else
                        is_real=0
                    fi
                elif [[ "$endpoint" =~ /(admin|console|login|administrator) ]]; then
                    if echo "$response" | grep -qiE "login|password|username|sign.?in|admin|dashboard|authenticate"; then
                        severity="MEDIUM"
                    else
                        is_real=0  # Just the homepage, not a real admin page
                    fi
                elif [[ "$endpoint" =~ /api(/|$) ]]; then
                    if echo "$response" | grep -qiE "<!DOCTYPE|<html|<head"; then
                        if ! echo "$response" | grep -qiE "swagger|api.?doc|openapi"; then
                            is_real=0
                        fi
                    fi
                elif [[ "$endpoint" =~ /(debug|trace|metrics|health|status|info)$ ]]; then
                    if echo "$response" | grep -qiE "<!DOCTYPE|<html|<head"; then
                        is_real=0
                    fi
                elif [[ "$endpoint" =~ /\.svn|/\.hg ]]; then
                    if echo "$response" | grep -qiE "<!DOCTYPE|<html|<head"; then
                        is_real=0
                    else
                        severity="HIGH"
                    fi
                elif [[ "$endpoint" =~ /manager/(html|status) ]]; then
                    if echo "$response" | grep -qiE "tomcat|manager|application|deploy"; then
                        severity="HIGH"
                    else
                        is_real=0
                    fi
                elif [[ "$endpoint" =~ /telescope|/__debug__ ]]; then
                    if echo "$response" | grep -qiE "telescope|laravel|django|debug.?toolbar"; then
                        severity="HIGH"
                    else
                        is_real=0
                    fi
                elif [[ "$endpoint" =~ /\.well-known/security\.txt$ ]]; then
                    if ! echo "$response" | grep -qiE "contact:|expires:|encryption:|preferred-languages:"; then
                        is_real=0
                    fi
                fi
            fi

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
            local redirect_location=$(curl -sI -m $TIMEOUT "$url" 2>/dev/null | grep -i "^location:" | cut -d' ' -f2 | tr -d '\r')
            if [ -n "$redirect_location" ] && ! echo "$redirect_location" | grep -qE "^/?$|^${TARGET_URL}/?$"; then
                LOG "green" "REDIRECT [$status]: $endpoint -> $redirect_location"
                log_result "[*] REDIRECT [$status]: $endpoint -> $redirect_location"
                found=$((found + 1))
            fi
        fi
        sleep 0.05
    done

    local robots_content
    robots_content=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/robots.txt" 2>/dev/null)
    if echo "$robots_content" | grep -qiE "^(Disallow|Allow):"; then
        log_result ""
        log_result "[*] Probing paths discovered in robots.txt..."
        local robots_paths
        robots_paths=$(echo "$robots_content" | grep -iE "^(Disallow|Allow):" | \
            awk '{print $2}' | sed 's/\*.*//' | grep -v '^/$' | grep -v '^$' | sort -u)
        local robots_tested=0
        while IFS= read -r rpath; do
            [ -z "$rpath" ] && continue
            local already=0
            for ep in "${endpoints[@]}"; do [ "$ep" = "$rpath" ] && already=1 && break; done
            [ $already -eq 1 ] && continue
            [ $robots_tested -ge 30 ] && break
            robots_tested=$((robots_tested + 1))
            local rurl="${TARGET_PROTO}://${TARGET_HOST}${rpath}"
            local rstatus=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "$rurl" 2>/dev/null)
            if [ "$rstatus" = "200" ]; then
                local rresp_hash=$(curl -s -m $TIMEOUT "$rurl" 2>/dev/null | md5sum | cut -d' ' -f1)
                if [ "$rresp_hash" != "$homepage_hash" ]; then
                    log_finding "INFO" "FOUND [$rstatus]: $rpath (robots.txt)"
                    found=$((found + 1))
                fi
            elif [ "$rstatus" = "301" ] || [ "$rstatus" = "302" ]; then
                local rloc=$(curl -sI -m $TIMEOUT "$rurl" 2>/dev/null | grep -i "^location:" | cut -d' ' -f2 | tr -d '\r')
                if [ -n "$rloc" ] && ! echo "$rloc" | grep -qE "^/?$|^${TARGET_URL}/?$"; then
                    log_result "[*] REDIRECT [$rstatus]: $rpath -> $rloc (robots.txt)"
                    found=$((found + 1))
                fi
            elif [ "$rstatus" = "401" ] || [ "$rstatus" = "403" ]; then
                log_result "[-] PROTECTED [$rstatus]: $rpath (robots.txt)"
                found=$((found + 1))
            fi
            sleep 0.05
        done <<< "$robots_paths"
    fi

    local sitemap_content
    sitemap_content=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/sitemap.xml" 2>/dev/null)
    if ! echo "$sitemap_content" | grep -qiE "<loc>|<urlset|<sitemapindex"; then
        sitemap_content=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/sitemap_index.xml" 2>/dev/null)
    fi
    if echo "$sitemap_content" | grep -qi "<sitemapindex"; then
        local child_url
        child_url=$(echo "$sitemap_content" | grep -oE '<loc>[^<]+</loc>' | \
            sed 's|<loc>||;s|</loc>||' | grep -iE 'page-sitemap|post-sitemap' | head -1)
        [ -z "$child_url" ] && child_url=$(echo "$sitemap_content" | \
            grep -oE '<loc>[^<]+</loc>' | sed 's|<loc>||;s|</loc>||' | head -1)
        if [ -n "$child_url" ]; then
            sitemap_content=$(curl -s -m $TIMEOUT "$child_url" 2>/dev/null)
        fi
    fi
    if echo "$sitemap_content" | grep -qiE "<loc>"; then
        log_result ""
        log_result "[*] Probing unique top-level paths from sitemap..."
        local sitemap_paths
        sitemap_paths=$(echo "$sitemap_content" | grep -oE '<loc>[^<]+</loc>' | \
            sed 's|<loc>||;s|</loc>||' | \
            sed "s|${TARGET_PROTO}://${TARGET_HOST}||g" | \
            grep -v '^$' | grep -v '\.xml' | \
            awk -F'/' 'NF>=2 && $2!="" {print "/"$2}' | sort -u | head -20)
        local sitemap_tested=0
        local sitemap_found=0
        while IFS= read -r spath; do
            [ -z "$spath" ] && continue
            local already=0
            for ep in "${endpoints[@]}"; do [ "$ep" = "$spath" ] && already=1 && break; done
            [ $already -eq 1 ] && continue
            [ $sitemap_tested -ge 20 ] && break
            sitemap_tested=$((sitemap_tested + 1))
            local surl="${TARGET_PROTO}://${TARGET_HOST}${spath}"
            local sstatus=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "$surl" 2>/dev/null)
            if [ "$sstatus" = "200" ]; then
                local sresp_hash=$(curl -s -m $TIMEOUT "$surl" 2>/dev/null | md5sum | cut -d' ' -f1)
                if [ "$sresp_hash" != "$homepage_hash" ]; then
                    log_finding "INFO" "FOUND [$sstatus]: $spath (sitemap)"
                    found=$((found + 1))
                    sitemap_found=$((sitemap_found + 1))
                fi
            elif [ "$sstatus" = "301" ] || [ "$sstatus" = "302" ]; then
                local sloc=$(curl -sI -m $TIMEOUT "$surl" 2>/dev/null | grep -i "^location:" | cut -d' ' -f2 | tr -d '\r')
                local surl_stripped=$(echo "$surl" | sed 's|/$||')
                local sloc_stripped=$(echo "$sloc" | sed 's|/$||')
                if [ -n "$sloc" ] && ! echo "$sloc" | grep -qE "^/?$|^${TARGET_URL}/?$" && \
                   [ "$sloc_stripped" != "$surl_stripped" ]; then
                    log_result "[*] REDIRECT [$sstatus]: $spath -> $sloc (sitemap)"
                    found=$((found + 1))
                    sitemap_found=$((sitemap_found + 1))
                fi
            elif [ "$sstatus" = "401" ] || [ "$sstatus" = "403" ]; then
                log_result "[-] PROTECTED [$sstatus]: $spath (sitemap)"
                found=$((found + 1))
                sitemap_found=$((sitemap_found + 1))
            fi
            sleep 0.05
        done <<< "$sitemap_paths"
        [ $sitemap_found -eq 0 ] && log_result "[*] No unique paths found in sitemap"
    fi

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

    local baseline_headers=$(curl -sI -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
    local baseline_length=$(echo "$baseline_headers" | grep -i "^Content-Length:" | tr -d '\r' | awk '{print $2}')
    local baseline_type=$(echo "$baseline_headers" | grep -i "^Content-Type:" | tr -d '\r' | cut -d':' -f2 | cut -d';' -f1 | tr -d ' ')

    for method in "${methods[@]}"; do
        local response=$(curl -sI -X "$method" -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
        local status=$(echo "$response" | head -1 | grep -o "[0-9]\{3\}")

        case "$status" in
            200|201|204)
                if [ "$method" = "OPTIONS" ]; then
                    local allow_header=$(echo "$response" | grep -i "^Allow:")
                    if [ -z "$allow_header" ]; then
                        continue
                    fi
                    log_finding "MEDIUM" "$method ENABLED: HTTP $status"
                    log_result "    $allow_header"
                    play_found
                    led_found
                    found_vuln=1
                    found_methods+=("$method")
                elif [ "$method" = "PUT" ] || [ "$method" = "DELETE" ] || [ "$method" = "PATCH" ]; then
                    local method_length=$(echo "$response" | grep -i "^Content-Length:" | tr -d '\r' | awk '{print $2}')
                    local method_type=$(echo "$response" | grep -i "^Content-Type:" | tr -d '\r' | cut -d':' -f2 | cut -d';' -f1 | tr -d ' ')

                    if [ "$method_length" = "$baseline_length" ] && echo "$method_type" | grep -qi "text/html"; then
                        continue
                    fi

                    if [ "$status" = "201" ]; then
                        log_finding "HIGH" "$method ENABLED: HTTP $status (Created)"
                        play_found
                        led_found
                        found_vuln=1
                        found_methods+=("$method")
                    elif [ "$status" = "204" ]; then
                        log_finding "MEDIUM" "$method ENABLED: HTTP $status (No Content)"
                        play_found
                        led_found
                        found_vuln=1
                        found_methods+=("$method")
                    elif [ "$method_type" != "$baseline_type" ] && [ -n "$method_type" ]; then
                        log_finding "MEDIUM" "$method may be enabled: HTTP $status (different response type: $method_type)"
                        play_found
                        found_vuln=1
                        found_methods+=("$method")
                    fi
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
                log_finding "INFO" "$method rate limited: HTTP $status"
                rate_limited=1
                ;;
            405|501)
                ;;
            000|"")
                ;;
            *)
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

    if [ ${#found_methods[@]} -gt 0 ] || [ ${#unexpected_methods[@]} -gt 0 ]; then
        log_result ""
        log_result "━━━ HOW TO VERIFY HTTP METHODS ━━━"
        log_result ""

        if [[ " ${found_methods[*]} " =~ " OPTIONS " ]]; then
            log_result "OPTIONS ENABLED:"
            log_result "  View allowed methods:"
            log_result "    curl -X OPTIONS -i \"$TARGET_URL\""
            log_result "  Look for 'Allow:' header listing permitted methods"
            log_result "  Risk: Information disclosure about server capabilities"
            log_result ""
        fi

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

        if [[ " ${found_methods[*]} " =~ " DELETE " ]]; then
            log_result "DELETE METHOD:"
            log_result "  Test deletion (CAREFUL - use non-existent file):"
            log_result "    curl -X DELETE -i \"$TARGET_URL/nonexistent_file_12345.txt\""
            log_result "  Risk: Arbitrary file deletion, data destruction"
            log_result "  WARNING: Do NOT test on real files without authorization!"
            log_result ""
        fi

        if [[ " ${found_methods[*]} " =~ " TRACE " ]]; then
            log_result "TRACE METHOD (XST - Cross-Site Tracing):"
            log_result "  Test for request reflection:"
            log_result "    curl -X TRACE -H \"X-Test: sensitive_data\" \"$TARGET_URL\""
            log_result "  If response contains your headers, XST is possible"
            log_result "  Risk: Cookie theft via XSS+XST, credential harvesting"
            log_result "  Combined with XSS, can bypass HttpOnly cookie protection"
            log_result ""
        fi

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

    local xff_resp=$(curl -s -m $TIMEOUT -H "X-Forwarded-For: 127.0.0.1" "$TARGET_URL" 2>/dev/null)
    if echo "$xff_resp" | grep -q "127.0.0.1"; then
        log_finding "MEDIUM" "X-Forwarded-For may be reflected"
        play_found
    fi

    local host_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT -H "Host: evil.com" "$TARGET_URL" 2>/dev/null)
    if [ "$host_status" = "200" ]; then
        log_finding "MEDIUM" "Host header accepted: evil.com"
        play_found
    fi

    LOG "Testing X-Original-URL bypass..."

    local baseline_content=$(curl -s -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
    local baseline_size=${#baseline_content}

    local test_paths="/admin /console /dashboard /wp-admin /manager /settings /config"
    local bypass_detected=false
    local bypass_path=""

    for path in $test_paths; do
        local bypass_response=$(curl -s -m $TIMEOUT -H "X-Original-URL: $path" "$TARGET_URL" 2>/dev/null)
        local bypass_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT -H "X-Original-URL: $path" "$TARGET_URL" 2>/dev/null)
        local bypass_size=${#bypass_response}

        [ "$bypass_status" != "200" ] && continue

        local size_diff=0
        if [ $baseline_size -gt 0 ]; then
            size_diff=$(( (bypass_size - baseline_size) * 100 / baseline_size ))
            [ $size_diff -lt 0 ] && size_diff=$(( size_diff * -1 ))
        fi

        local admin_keywords="admin panel|dashboard|control panel|administration|logout|sign out|user management|settings panel|admin area|configuration|manage users|admin menu|cpanel|administrator"
        local has_admin_content=false

        if echo "$bypass_response" | grep -qiE "$admin_keywords"; then
            if ! echo "$baseline_content" | grep -qiE "$admin_keywords"; then
                has_admin_content=true
            fi
        fi

        local auth_indicators="welcome admin|logged in as|my account|profile settings|admin dashboard"
        local has_auth_bypass=false

        if echo "$bypass_response" | grep -qiE "$auth_indicators"; then
            if ! echo "$baseline_content" | grep -qiE "$auth_indicators"; then
                has_auth_bypass=true
            fi
        fi

        if [ $size_diff -gt 20 ] && ([ "$has_admin_content" = "true" ] || [ "$has_auth_bypass" = "true" ]); then
            bypass_detected=true
            bypass_path="$path"
            break
        fi

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

    local params=("url" "redirect" "next" "return" "dest" "destination" "redir" "redirect_uri")
    local found=0

    LOG "Testing ${#params[@]} redirect params..."
    for param in "${params[@]}"; do
        local test_url="${TARGET_URL}?${param}=https://evil.com"
        local location=$(curl -s -m $TIMEOUT -I "$test_url" 2>/dev/null | grep -i "^Location:" | cut -d' ' -f2 | tr -d '\r')

        if [ -n "$location" ]; then
            if echo "$location" | grep -qE '^https?://evil\.com(/|$)'; then
                LOG "green" "Open redirect found via: $param -> $location"
                log_finding "HIGH" "Open redirect via: $param"
                log_result "    Redirects to: $location"
                play_found
                led_found
                found=1
                sleep 0.5
            elif echo "$location" | grep -qE '^//evil\.com(/|$)'; then
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

    local params=(
        "debug" "test" "dev" "admin" "trace" "verbose"
        "user" "username" "role" "access" "auth" "token"
        "id" "uid" "pid" "page" "data" "item" "file" "doc"
        "config" "settings" "env" "mode" "format" "lang"
        "callback" "continue" "back" "source"
        "api_key" "apikey" "key" "secret" "filter" "sort"
        "version" "v" "type" "category" "query" "search"
    )

    local found_params=()
    local baseline_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
    local baseline_size=$(curl -s -m $TIMEOUT "$TARGET_URL" 2>/dev/null | wc -c | tr -d ' ')

    LOG "Baseline: HTTP $baseline_status, Size: $baseline_size bytes"

    local canary="curlytest$(date +%s | tail -c 6)"
    LOG "Using canary value: $canary"

    local size_threshold=1000

    for param in "${params[@]}"; do
        local test_url="${TARGET_URL}?${param}=${canary}"
        local response=$(curl -s -m $TIMEOUT "$test_url" 2>/dev/null)
        local status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "$test_url" 2>/dev/null)
        local size=$(echo "$response" | wc -c | tr -d ' ')

        local size_diff=$((size - baseline_size))
        size_diff=${size_diff#-}  # Absolute value


        if [ "$status" != "$baseline_status" ]; then
            if [ "$status" = "429" ] || [ "$status" = "000" ]; then
                continue
            fi
            log_finding "MEDIUM" "Parameter '$param' changes response status: $baseline_status → $status"
            found_params+=("$param")
        elif [ $size_diff -gt $size_threshold ]; then
            log_finding "LOW" "Parameter '$param' affects response (size change: ${size_diff} bytes)"
            found_params+=("$param")
        fi

        sleep 0.05
    done

    LOG "Testing parameter pollution..."
    local hpp_test="${TARGET_URL}?id=1&id=2"
    local hpp_response=$(curl -s -m $TIMEOUT "$hpp_test" 2>/dev/null)

    if echo "$hpp_response" | grep -qE "(id.*1.*2|id.*2.*1)"; then
        log_finding "LOW" "Possible parameter pollution vulnerability (multiple 'id' params processed)"
    fi

    if [ ${#found_params[@]} -gt 0 ]; then
        log_result ""
        log_result "[*] SUMMARY: Found ${#found_params[@]} interesting parameter(s):"
        for param in "${found_params[@]}"; do
            log_result "    - $param"
        done

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

            if [ "$resp_hash" = "$homepage_hash" ]; then
                continue  # Identical to homepage, skip
            fi

            local size_diff=$((resp_size - homepage_size))
            size_diff=${size_diff#-}  # Absolute value
            local threshold=$((homepage_size / 20))  # 5% threshold
            if [ $size_diff -lt $threshold ] && [ $size_diff -lt 500 ]; then
                continue  # Too similar to homepage
            fi

            if echo "$resp" | grep -qiE "<!DOCTYPE|<html|<head|<body"; then
                if echo "$resp" | grep -qiE "swagger|api.?doc|openapi|graphi?ql"; then
                    is_real_api=1
                fi
            else
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

                local has_sensitive=0

                if echo "$resp" | grep -qiE '"password"\s*:\s*"[^"]+"|"secret"\s*:\s*"[^"]+"|"api_key"\s*:\s*"[^"]+"'; then
                    has_sensitive=1
                fi

                if echo "$resp" | grep -qE 'AKIA[0-9A-Z]{16}|[a-zA-Z0-9/+=]{40}'; then
                    has_sensitive=1
                fi

                if echo "$resp" | grep -qE 'eyJ[a-zA-Z0-9_-]+\.eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+'; then
                    has_sensitive=1
                fi

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

    local base_files=("index" "config" "database" "db" "backup" "admin" "login" "wp-config")
    local extensions=(".bak" ".old" ".backup" "~" ".save" ".copy" ".orig" ".sql" ".tar.gz" ".zip")
    local found=0

    LOG "Hunting for backup files..."

    for base in "${base_files[@]}"; do
        for ext in "${extensions[@]}"; do
            local file="${base}${ext}"
            local url="${TARGET_PROTO}://${TARGET_HOST}/${file}"

            local response=$(curl -s -I -m $TIMEOUT "$url" 2>/dev/null)
            local status=$(echo "$response" | head -1 | grep -o "[0-9]\{3\}")
            local content_type=$(echo "$response" | grep -i "^content-type:" | cut -d':' -f2 | tr -d ' \r')

            if [ "$status" = "200" ]; then
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

    LOG "Checking for cookie consent mechanisms..."
    if echo "$body" | grep -qiE 'cookie.?consent|consent.?cookie|gdpr|cookiebot|onetrust|trustarc|cookielaw|cookie.?banner|cookie.?notice|cookie.?policy|accept.?cookie|cookie.?accept|tarteaucitron|klaro|osano|quantcast|didomi|iubenda|complianz'; then
        consent_detected=1
        log_result "[*] Cookie consent mechanism detected"
        log_result "    NOTE: Cookies may only be set AFTER user consents in browser"
    fi

    if [ -z "$cookies" ]; then
        log_result "[*] No cookies in HTTP headers (Set-Cookie)"
    else
        log_result "[*] HTTP Set-Cookie headers detected, analyzing..."
        local cookie_count=$(echo "$cookies" | wc -l | tr -d ' ')
        log_result "[*] Found $cookie_count cookie(s) in headers"

        while IFS= read -r cookie; do
            local cookie_name=$(echo "$cookie" | awk -F': ' '{print $2}' | cut -d'=' -f1 | tr -d '\r')

            if ! echo "$cookie" | grep -qi "HttpOnly"; then
                log_finding "MEDIUM" "Cookie '$cookie_name' missing HttpOnly flag"
                play_found
            fi

            if ! echo "$cookie" | grep -qi "Secure"; then
                log_finding "MEDIUM" "Cookie '$cookie_name' missing Secure flag"
                play_found
            fi

            if ! echo "$cookie" | grep -qi "SameSite"; then
                log_finding "LOW" "Cookie '$cookie_name' missing SameSite flag"
            fi
        done <<< "$cookies"
    fi

    log_result ""
    log_result "[*] Checking for JavaScript cookie operations..."

    local js_cookie_sets=$(echo "$body" | grep -oE 'document\.cookie\s*=' | wc -l | tr -d ' ')
    local js_cookie_reads=$(echo "$body" | grep -oE 'document\.cookie[^=]|document\.cookie$' | wc -l | tr -d ' ')

    if [ "$js_cookie_sets" -gt 0 ]; then
        js_cookies_found=1
        log_finding "INFO" "Found $js_cookie_sets JavaScript cookie assignment(s) (document.cookie=)"
        log_result "    These cookies are set via JS and won't appear in HTTP headers"

        local cookie_patterns=$(echo "$body" | grep -oE "document\.cookie\s*=\s*['\"][^'\"]{1,100}" | head -5)
        if [ -n "$cookie_patterns" ]; then
            log_result "    Sample JS cookie operations found:"
            while IFS= read -r pattern; do
                local cleaned=$(echo "$pattern" | sed "s/document\.cookie\s*=\s*['\"]//g" | cut -c1-60)
                [ -n "$cleaned" ] && log_result "      - $cleaned..."
            done <<< "$cookie_patterns"
        fi

        log_finding "LOW" "JS-set cookies cannot have HttpOnly flag (XSS risk if sensitive)"
    fi

    if [ "$js_cookie_reads" -gt 0 ]; then
        log_result "[*] Found $js_cookie_reads JavaScript cookie read(s) (document.cookie)"
        log_result "    Site actively reads cookies via JavaScript"
    fi

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

    local cloudflare_detected=0

    if echo "$headers" | grep -qi "cloudflare\|cf-ray"; then
        cloudflare_detected=1
    fi

    if [ $cloudflare_detected -eq 0 ]; then
        LOG "Checking DNS nameservers for Cloudflare..."

        local apex_domain=$(echo "$TARGET_HOST" | awk -F. '{if(NF>2){print $(NF-1)"."$NF}else{print $0}}')
        LOG "Checking NS records for apex domain: $apex_domain"

        local nameservers=$(nslookup -type=NS "$apex_domain" 2>/dev/null | grep -i "cloudflare")

        if [ -n "$nameservers" ]; then
            cloudflare_detected=1
            LOG "Cloudflare nameservers found via nslookup"
        fi

        if [ $cloudflare_detected -eq 0 ]; then
            local dns_response=$(curl -s -m 5 "https://dns.google/resolve?name=${apex_domain}&type=NS" 2>/dev/null)

            if echo "$dns_response" | grep -qi "cloudflare"; then
                cloudflare_detected=1
                LOG "Cloudflare nameservers found via DNS-over-HTTPS"
            fi
        fi

        if [ $cloudflare_detected -eq 0 ]; then
            LOG "Checking Cloudflare IP ranges..."
            local dns_a_response=$(curl -s -m 5 "https://dns.google/resolve?name=${TARGET_HOST}&type=A" 2>/dev/null)
            local target_ip=$(echo "$dns_a_response" | grep -oE '"data":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | cut -d'"' -f4)

            if [ -n "$target_ip" ]; then
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

    if echo "$headers" | grep -qi "akamai"; then
        log_result "[*] CDN: Akamai detected"
        found_waf=1
    fi

    if echo "$headers" | grep -qi "cloudfront\|x-amz-cf-id"; then
        log_result "[*] CDN: AWS CloudFront detected"
        found_waf=1
    fi

    if echo "$headers" | grep -qi "incapsula\|x-iinfo"; then
        log_result "[*] WAF: Incapsula detected"
        found_waf=1
    fi

    if echo "$headers" | grep -qi "sucuri"; then
        log_result "[*] WAF: Sucuri detected"
        found_waf=1
    fi

    if echo "$headers" | grep -qi "mod_security\|NOYB"; then
        log_result "[*] WAF: ModSecurity detected"
        found_waf=1
    fi

    if echo "$headers" | grep -qi "WordPress VIP\|wpvip"; then
        log_result "[*] Platform: WordPress VIP detected (enterprise managed hosting with edge layer)"
        found_waf=1
    fi

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
    local body=$(curl -s -m $TIMEOUT "$TARGET_URL" 2>/dev/null | head -c 50000)

    local server=$(echo "$headers" | grep -i "^Server:" | cut -d':' -f2- | tr -d '\r' | sed 's/^ //')
    [ -n "$server" ] && log_result "[*] Web Server: $server"

    if echo "$headers" | grep -qi "X-Powered-By.*PHP"; then
        local php_ver=$(echo "$headers" | grep -i "X-Powered-By" | grep -o "PHP/[0-9.]*" | tr -d '\r')
        log_result "[*] Backend: $php_ver"
    fi

    local is_wordpress=0

    if echo "$body" | grep -qE '<meta name="generator" content="WordPress|/wp-content/themes/|/wp-content/plugins/|/wp-includes/'; then
        is_wordpress=1
    fi

    if echo "$headers" | grep -qi "pantheon\|x-pantheon"; then
        is_wordpress=1
        log_result "[*] Pantheon hosting detected (WordPress platform)"
    fi

    if [ $is_wordpress -eq 0 ]; then
        local wp_api_response=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/wp-json/" 2>/dev/null)
        if echo "$wp_api_response" | grep -qi "namespace.*wp/v2\|\"name\":.*\"wordpress\""; then
            is_wordpress=1
        fi
    fi

    if [ $is_wordpress -eq 0 ]; then
        local wp_login_response=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/wp-login.php" 2>/dev/null)
        if echo "$wp_login_response" | grep -qi "wp-submit\|user_login\|\"log in to \|powered by wordpress"; then
            is_wordpress=1
        fi
    fi

    if [ $is_wordpress -eq 1 ]; then
        log_result "[*] CMS: WordPress detected"

        local wp_ver=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/readme.html" 2>/dev/null | \
            grep -i "Stable tag\|Version [0-9]" | sed 's/<[^>]*>//g' | \
            grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
        [ -n "$wp_ver" ] && log_result "[*] WP version (readme.html): $wp_ver"

        log_result "[*] Running WordPress tests..."

        local wp_users=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/wp-json/wp/v2/users?per_page=100" 2>/dev/null)
        if echo "$wp_users" | grep -qiE '"slug"|"name"'; then
            log_finding "MEDIUM" "WP REST API user enumeration enabled!"
            play_found
            led_found
            local slugs=$(echo "$wp_users" | grep -oE '"slug":"[^"]*"' | cut -d'"' -f4)
            if [ -n "$slugs" ]; then
                log_result "  Usernames:"
                echo "$slugs" | while IFS= read -r slug; do
                    log_result "    - $slug"
                done
            fi
        fi

        local author_redirect=$(curl -s -o /dev/null -w "%{redirect_url}" -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/?author=1" 2>/dev/null)
        local author_username=""

        if echo "$author_redirect" | grep -q "/author/"; then
            author_username=$(echo "$author_redirect" | sed -n 's|.*/author/\([^/]*\).*|\1|p')
        fi

        if [ -z "$author_username" ]; then
            local author_page=$(curl -s -m $TIMEOUT -L "${TARGET_PROTO}://${TARGET_HOST}/?author=1" 2>/dev/null)
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

        local xmlrpc_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/xmlrpc.php" 2>/dev/null)
        if [ "$xmlrpc_status" = "200" ]; then
            LOG "green" "xmlrpc.php accessible"
            log_finding "LOW" "xmlrpc.php accessible"
            play_found
        fi

        local debug_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/wp-content/debug.log" 2>/dev/null)
        if [ "$debug_status" = "200" ]; then
            LOG "green" "debug.log exposed!"
            log_finding "CRITICAL" "debug.log exposed!"
            play_found
            led_found
        fi

        local admin_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/wp-admin/" 2>/dev/null)
        if [ "$admin_status" = "200" ] || [ "$admin_status" = "302" ]; then
            log_result "[*] wp-admin accessible"
        fi

        local login_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/wp-login.php" 2>/dev/null)
        if [ "$login_status" = "200" ]; then
            log_result "[*] wp-login.php accessible"
        fi
    fi

    if echo "$body" | grep -qi "drupal"; then
        log_result "[*] CMS: Drupal detected"
    fi

    if echo "$body" | grep -qi "joomla"; then
        log_result "[*] CMS: Joomla detected"
    fi

    if echo "$body" | grep -qi "react"; then
        log_result "[*] Frontend: React detected"
    fi

    if echo "$body" | grep -qi "vue\.js\|__vue__"; then
        log_result "[*] Frontend: Vue.js detected"
    fi

    if echo "$body" | grep -qi "ng-app\|angular"; then
        log_result "[*] Frontend: Angular detected"
    fi

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

    LOG "Checking RSS feed..."
    local rss_response=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/feed/" 2>/dev/null)
    local rss_version=$(echo "$rss_response" | grep -oE '<generator>https://wordpress\.org/\?v=[0-9.]+</generator>' | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')

    if [ -n "$rss_version" ]; then
        wp_version="$rss_version"
        wp_detected_by="Rss Generator (Aggressive Detection)"
        wp_evidence="${TARGET_PROTO}://${TARGET_HOST}/feed/"
        LOG "Found WP version $wp_version via RSS feed"
    fi

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

    LOG "Checking OPML link..."
    local opml_response=$(curl -s -m $TIMEOUT "${TARGET_PROTO}://${TARGET_HOST}/wp-links-opml.php" 2>/dev/null)
    local opml_version=""

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

    if [ -z "$wp_version" ]; then
        LOG "Checking WP core asset version strings..."
        local asset_version=$(echo "$body" | grep -oE '/wp-includes/[^"'"'"' >]+\?ver=[0-9]+\.[0-9]+(\.[0-9]+)?' | grep -oE 'ver=[0-9]+\.[0-9]+(\.[0-9]+)?' | sort | uniq -c | sort -rn | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')

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

    if [ -z "$wp_version" ]; then
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

        log_result "[*] BASIC VERSION CHECK (without API):"

        local major=$(echo "$wp_version" | cut -d. -f1)
        local minor=$(echo "$wp_version" | cut -d. -f2)
        local patch=$(echo "$wp_version" | cut -d. -f3)
        [ -z "$patch" ] && patch="0"

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

    local api_version=$(echo "$wp_version" | tr -d '.')
    LOG "Querying WPScan API for WordPress $wp_version..."

    local api_response=$(curl -s -m $TIMEOUT \
        -H "Authorization: Token token=$WPSCAN_API_TOKEN" \
        "https://wpscan.com/api/v3/wordpresses/$api_version" 2>/dev/null)

    if [ -z "$api_response" ]; then
        log_result " | [*] Could not reach WPScan API"
        log_result ""
        return
    fi

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

    local vuln_count=$(echo "$api_response" | grep -oE '"title":"[^"]*"' | wc -l | tr -d ' ')

    if [ "$vuln_count" -eq 0 ] || [ -z "$vuln_count" ]; then
        local major=$(echo "$wp_version" | cut -d. -f1)
        local minor=$(echo "$wp_version" | cut -d. -f2)
        local base_api_version="${major}${minor}"

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

    local release_status=""

    if echo "$api_response" | grep -q '"status":"insecure"'; then
        release_status="Insecure"
    elif echo "$api_response" | grep -q '"status":"latest"'; then
        release_status="Latest"
    else
        release_status="Unknown"
    fi

    local release_date=$(echo "$api_response" | grep -oE '"release_date":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ "$release_status" = "Insecure" ]; then
        log_result " | Status: Insecure$([ -n "$release_date" ] && echo ", released on $release_date")"
        log_finding "HIGH" "WordPress $wp_version is marked INSECURE by WPScan"
        play_found
    elif [ "$release_status" = "Latest" ]; then
        log_result " | Status: Latest$([ -n "$release_date" ] && echo ", released on $release_date")"
        log_finding "INFO" "WordPress $wp_version is the latest version"
    fi

    local all_titles=$(echo "$api_response" | grep -oE '"title":"[^"]*"' | cut -d'"' -f4)
    local all_fixed=$(echo "$api_response" | grep -oE '"fixed_in":"[^"]*"' | cut -d'"' -f4)
    local all_cves=$(echo "$api_response" | grep -oE '"cve":\["[0-9-]+"\]|"cve":"[0-9-]+"' | grep -oE '[0-9][0-9-]+[0-9]')

    local affecting_count=0
    local affecting_indices=""
    local total_from_api=$(echo "$all_titles" | grep -c '.' 2>/dev/null)
    local check_index=0

    while IFS= read -r check_title; do
        check_index=$((check_index + 1))
        [ -z "$check_title" ] && continue

        local check_fixed=$(echo "$all_fixed" | sed -n "${check_index}p")

        if [ -z "$check_fixed" ]; then
            affecting_count=$((affecting_count + 1))
            affecting_indices="$affecting_indices $check_index"
        elif version_less_than "$wp_version" "$check_fixed"; then
            affecting_count=$((affecting_count + 1))
            affecting_indices="$affecting_indices $check_index"
        fi
    done <<< "$all_titles"

    local patched_count=$((total_from_api - affecting_count))

    if [ "$affecting_count" -gt 0 ]; then
        log_result " |"
        log_result " | [!] $affecting_count vulnerabilit$([ "$affecting_count" -eq 1 ] && echo "y" || echo "ies") affecting $wp_version:"
        [ "$patched_count" -gt 0 ] && log_result " | [*] ($patched_count additional vulnerabilit$([ "$patched_count" -eq 1 ] && echo "y" || echo "ies") already patched in $wp_version)"
        log_result " |"

        for vuln_index in $affecting_indices; do
            local title=$(echo "$all_titles" | sed -n "${vuln_index}p")
            [ -z "$title" ] && continue

            log_result " | [!] Title: $title"

            local fixed_in=$(echo "$all_fixed" | sed -n "${vuln_index}p")
            if [ -n "$fixed_in" ]; then
                log_result " |     Fixed in: $fixed_in"
            else
                log_result " |     Fixed in: No known fix"
            fi

            local cve=$(echo "$all_cves" | sed -n "${vuln_index}p")

            log_result " |     References:"

            local wpscan_url=$(echo "$api_response" | grep -oE '"url":"https://wpscan\.com/vulnerability/[^"]*"' | cut -d'"' -f4 | sed -n "${vuln_index}p")
            [ -n "$wpscan_url" ] && log_result " |      - $wpscan_url"

            if [ -n "$cve" ]; then
                log_result " |      - https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-$cve"
            fi

            echo "$api_response" | grep -oE '"url":"https://(patchstack|wordpress\.org|nvd\.nist\.gov)[^"]*"' | cut -d'"' -f4 | while IFS= read -r ref_url; do
                [ -n "$ref_url" ] && log_result " |      - $ref_url"
            done

            log_result " |"

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

            local plugin_readme=$(curl -s -m 5 "${TARGET_PROTO}://${TARGET_HOST}/wp-content/plugins/${plugin_slug}/readme.txt" 2>/dev/null)
            local plugin_version=""

            if [ -n "$plugin_readme" ] && ! echo "$plugin_readme" | grep -qiE "<!DOCTYPE|<html"; then
                plugin_version=$(echo "$plugin_readme" | grep -iE "^Stable tag:" | head -1 | sed 's/[Ss]table [Tt]ag:[[:space:]]*//' | tr -d '[:space:]')
            fi

            if [ -n "$plugin_version" ] && [ "$plugin_version" != "trunk" ]; then
                log_result " | [*] $plugin_slug (v$plugin_version)"

                if [ -n "$WPSCAN_API_TOKEN" ]; then
                    local plugin_api=$(curl -s -m $TIMEOUT \
                        -H "Authorization: Token token=$WPSCAN_API_TOKEN" \
                        "https://wpscan.com/api/v3/plugins/$plugin_slug" 2>/dev/null)

                    if [ -n "$plugin_api" ] && ! echo "$plugin_api" | grep -qiE '"error"'; then
                        local plugin_vuln_titles=$(echo "$plugin_api" | grep -oE '"title":"[^"]*"' | cut -d'"' -f4)
                        local plugin_vuln_fixed=$(echo "$plugin_api" | grep -oE '"fixed_in":"[^"]*"' | cut -d'"' -f4)
                        local plugin_vuln_count=$(echo "$plugin_vuln_titles" | grep -c '.' 2>/dev/null)

                        if [ "$plugin_vuln_count" -gt 0 ]; then
                            local pv_index=0
                            while IFS= read -r pv_title; do
                                pv_index=$((pv_index + 1))
                                [ -z "$pv_title" ] && continue
                                local pv_fixed=$(echo "$plugin_vuln_fixed" | sed -n "${pv_index}p")

                                if [ -n "$pv_fixed" ]; then
                                    if [ "$pv_fixed" != "$plugin_version" ]; then
                                        log_result " |   [!] $pv_title"
                                        log_result " |       Fixed in: $pv_fixed"
                                        log_finding "HIGH" "Plugin $plugin_slug vuln: $pv_title"
                                        play_found
                                    fi
                                else
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

    log_result ""
    log_result "[+] WORDPRESS THEME DETECTION"
    local theme=$(echo "$body" | grep -oE '/wp-content/themes/[^/\"'"'"'?]+' | sort -u | head -1 | sed 's|/wp-content/themes/||')

    if [ -n "$theme" ]; then
        log_result "[*] Active theme: $theme"

        local theme_css=$(curl -s -m 5 "${TARGET_PROTO}://${TARGET_HOST}/wp-content/themes/${theme}/style.css" 2>/dev/null | head -30)
        local theme_version=$(echo "$theme_css" | grep -iE "^[[:space:]]*Version:" | head -1 | sed 's/.*Version:[[:space:]]*//' | tr -d '[:space:]')

        [ -n "$theme_version" ] && log_result " | Version: $theme_version"

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

# 13. HTML Source Analysis
scan_html_source() {
    log_result "[+] HTML SOURCE ANALYSIS"
    led_scanning

    LOG "Analyzing HTML source..."
    local body=$(curl -s -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
    local found=0

    local comments=$(echo "$body" | grep -o '<!--.*-->' | head -10)
    if [ -n "$comments" ]; then
        log_result "[*] HTML Comments found:"
        while IFS= read -r comment; do
            comment=$(echo "$comment" | sed 's/<!--//g; s/-->//g' | tr -d '\r' | head -c 100)
            [ -n "$comment" ] && log_result "    $comment"
            found=1
        done <<< "$comments"
    fi

    local emails=$(echo "$body" | grep -oE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | sort -u | head -5)
    if [ -n "$emails" ]; then
        LOG "green" "Email addresses found!"
        log_finding "INFO" "Email addresses found:"
        while IFS= read -r email; do
            log_result "    $email"
            found=1
        done <<< "$emails"
    fi

    if echo "$body" | grep -qiE 'api[_-]?key|apikey|access[_-]?token|secret[_-]?key'; then
        log_finding "CRITICAL" "Possible API key references in source!"
        play_found
        led_found
        found=1
    fi

    local internal_urls=$(echo "$body" | grep -oE '(https?://[^"'"'"' >]+|/[a-zA-Z0-9/_-]+)' | \
        grep -E '(internal|dev|staging|test|admin|api)' | \
        grep -vE '(googleapis\.com|gstatic\.com|cdnjs\.cloudflare\.com|jsdelivr\.net|unpkg\.com|fontawesome\.com|jquery\.com|bootstrapcdn\.com|w3\.org|schema\.org)' | \
        sort -u | head -5)
    if [ -n "$internal_urls" ]; then
        log_finding "MEDIUM" "Internal URLs found:"
        while IFS= read -r url; do
            log_result "    $url"
            found=1
            play_found
        done <<< "$internal_urls"
    fi

    if echo "$comments" | grep -qiE 'TODO|FIXME|HACK|XXX|BUG'; then
        log_finding "LOW" "Developer comments (TODO/FIXME) in HTML comments"
        local dev_comments=$(echo "$comments" | grep -iE 'TODO|FIXME|HACK|XXX|BUG' | head -3)
        while IFS= read -r comment; do
            [ -n "$comment" ] && log_result "    $(echo "$comment" | sed 's/<!--//g; s/-->//g' | tr -d '\r' | head -c 80)"
        done <<< "$dev_comments"
        found=1
        play_found
    fi

    if echo "$body" | grep -qiE '<pre[^>]*>.*[Ss]tack [Tt]race|<div[^>]*>[Ee]xception|Fatal error:|Uncaught [A-Z][a-zA-Z]*Error|Notice:.*on line [0-9]|Warning:.*on line [0-9]'; then
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

    LOG "Getting baseline response..."
    local baseline_response=$(curl -s -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
    local baseline_size=${#baseline_response}
    LOG "Baseline size: $baseline_size bytes"

    check_metadata_content() {
        local response="$1"
        local provider="$2"
        local baseline="$3"

        if echo "$response" | grep -qiE '<!DOCTYPE|<html'; then
            return 1
        fi

        if [ "$provider" = "aws" ]; then
            for kw in 'ami-id' 'instance-id' 'instance-type' 'local-ipv4' 'public-hostname' 'security-credentials'; do
                if echo "$response" | grep -q "$kw" && ! echo "$baseline" | grep -q "$kw"; then
                    return 0  # Found metadata not in baseline
                fi
            done
        fi

        if [ "$provider" = "gcp" ]; then
            for kw in 'computeMetadata' 'instance/id' 'instance/zone' 'service-accounts'; do
                if echo "$response" | grep -q "$kw" && ! echo "$baseline" | grep -q "$kw"; then
                    return 0
                fi
            done
        fi

        if [ "$provider" = "azure" ]; then
            for kw in '"vmId"' '"subscriptionId"' '"resourceGroupName"'; do
                if echo "$response" | grep -q "$kw" && ! echo "$baseline" | grep -q "$kw"; then
                    return 0
                fi
            done
        fi

        return 1  # No metadata found
    }

    log_result "[*] Testing AWS metadata..."
    local aws_meta="${TARGET_URL}?url=http://169.254.169.254/latest/meta-data/"
    local aws_response=$(curl -s -m $TIMEOUT "$aws_meta" 2>/dev/null)
    local aws_size=${#aws_response}
    local aws_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "$aws_meta" 2>/dev/null)

    if [ "$aws_status" = "200" ]; then
        local size_diff=$((aws_size - baseline_size))
        size_diff=${size_diff#-}  # Absolute value

        if check_metadata_content "$aws_response" "aws" "$baseline_response"; then
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

    local aws_direct=$(curl -s -m 2 "http://169.254.169.254/latest/meta-data/" 2>/dev/null)
    if [ -n "$aws_direct" ] && check_metadata_content "$aws_direct" "aws" ""; then
        LOG "green" "Direct AWS metadata access detected!"
        log_finding "CRITICAL" "Direct AWS metadata access (scanner running on AWS instance)"
        play_found
        led_found
        found=1
    fi

    log_result "[*] Testing GCP metadata..."
    local gcp_meta="${TARGET_URL}?url=http://metadata.google.internal/computeMetadata/v1/"
    local gcp_response=$(curl -s -m $TIMEOUT "$gcp_meta" 2>/dev/null)
    local gcp_size=${#gcp_response}
    local gcp_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "$gcp_meta" 2>/dev/null)

    if [ "$gcp_status" = "200" ]; then
        local size_diff=$((gcp_size - baseline_size))
        size_diff=${size_diff#-}

        if check_metadata_content "$gcp_response" "gcp" "$baseline_response"; then
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

    log_result "[*] Testing Azure metadata..."
    local azure_meta="${TARGET_URL}?url=http://169.254.169.254/metadata/instance?api-version=2021-02-01"
    local azure_response=$(curl -s -m $TIMEOUT "$azure_meta" 2>/dev/null)
    local azure_size=${#azure_response}
    local azure_status=$(curl -s -o /dev/null -w "%{http_code}" -m $TIMEOUT "$azure_meta" 2>/dev/null)

    if [ "$azure_status" = "200" ]; then
        local size_diff=$((azure_size - baseline_size))
        size_diff=${size_diff#-}

        if check_metadata_content "$azure_response" "azure" "$baseline_response"; then
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

            if check_metadata_content "$param_response" "aws" "$baseline_response" || \
               check_metadata_content "$param_response" "gcp" "$baseline_response" || \
               check_metadata_content "$param_response" "azure" "$baseline_response"; then
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
    local total=$((CRITICAL_FINDINGS + HIGH_FINDINGS + MEDIUM_FINDINGS + LOW_FINDINGS + INFO_FINDINGS))

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

# === DNS-OVER-HTTPS HELPER ===
# Shared by scan_dns_enum and scan_email_security
# Usage: doh_query <name> [type]  — outputs one data value per line
doh_query() {
    local name="$1"
    local type="${2:-A}"
    local resp
    resp=$(curl -s -m 5 "https://dns.google/resolve?name=${name}&type=${type}" 2>/dev/null)
    if command -v jq >/dev/null 2>&1; then
        echo "$resp" | jq -r '.Answer[]?.data // empty' 2>/dev/null
    else
        echo "$resp" | sed 's/"Authority".*//' | grep -oE '"data":"[^"]*"' | cut -d'"' -f4
    fi
}

# ============================================================================
# 15. PORT SCAN
# ============================================================================
scan_ports() {
    log_result "[+] PORT SCAN (nmap)"
    led_scanning

    if ! command -v nmap >/dev/null 2>&1; then
        log_result "[*] nmap not available on this device"
        log_result ""
        return
    fi

    LOG "Scanning common ports on $TARGET_HOST..."
    log_result "[*] Scanning web, service, and database ports..."

    local ports="21,22,23,25,53,80,110,143,443,445,3000,3306,4848,5000,5432,5672,6379,7001,8080,8443,8888,9000,9090,9200,15672,27017"

    local nmap_out
    nmap_out=$(timeout 180 nmap -Pn -T4 --open -p "$ports" "$TARGET_HOST" 2>/dev/null)

    if [ -z "$nmap_out" ]; then
        log_result "[*] Port scan failed or timed out"
        log_result ""
        return
    fi

    echo "$nmap_out" >> "$LOOTFILE"

    local open_ports
    open_ports=$(echo "$nmap_out" | grep "^[0-9]" | grep "open")

    if [ -z "$open_ports" ]; then
        log_result "[*] No additional open ports found"
        log_result ""
        return
    fi

    log_result ""
    log_result "[*] Open ports:"

    while IFS= read -r line; do
        local port service
        port=$(echo "$line" | awk '{print $1}' | cut -d'/' -f1)
        service=$(echo "$line" | awk '{print $3}')
        log_result "  $port/tcp  ($service)"

        case "$port" in
            21)
                log_finding "MEDIUM" "FTP open ($port) — check for anonymous login"
                ;;
            22)
                log_finding "INFO" "SSH open ($port)"
                ;;
            23)
                log_finding "HIGH" "Telnet open ($port) — unencrypted remote access!"
                play_found; led_found
                ;;
            25)
                log_finding "MEDIUM" "SMTP open ($port) — check for open relay"
                ;;
            110|143)
                log_finding "MEDIUM" "Mail port $port open — check for plaintext auth"
                ;;
            445)
                log_finding "HIGH" "SMB open ($port) — check for EternalBlue/misconfiguration"
                play_found; led_found
                ;;
            3306)
                log_finding "CRITICAL" "MySQL exposed on port $port!"
                play_found; led_found
                ;;
            4848)
                log_finding "HIGH" "GlassFish admin console on port $port"
                play_found; led_found
                ;;
            5432)
                log_finding "CRITICAL" "PostgreSQL exposed on port $port!"
                play_found; led_found
                ;;
            5672)
                log_finding "HIGH" "RabbitMQ (AMQP) open on port $port"
                play_found
                ;;
            6379)
                log_finding "CRITICAL" "Redis exposed on port $port — likely unauthenticated!"
                play_found; led_found
                ;;
            7001)
                log_finding "HIGH" "WebLogic admin port $port open"
                play_found; led_found
                ;;
            8080|8443)
                log_finding "MEDIUM" "Alternate web port $port open — check for admin panels"
                play_found
                ;;
            3000|5000|8888)
                log_finding "INFO" "Development server port $port open"
                ;;
            9000)
                log_finding "MEDIUM" "Port $port open — check for PHP-FPM, SonarQube, or Portainer"
                play_found
                ;;
            9090)
                log_finding "MEDIUM" "Port $port open — check for Prometheus, Cockpit, or WebSphere"
                play_found
                ;;
            9200)
                log_finding "CRITICAL" "Elasticsearch exposed on port $port!"
                play_found; led_found
                ;;
            15672)
                log_finding "HIGH" "RabbitMQ management UI on port $port"
                play_found
                ;;
            27017)
                log_finding "CRITICAL" "MongoDB exposed on port $port!"
                play_found; led_found
                ;;
        esac
    done <<< "$open_ports"

    log_result ""
}

# ============================================================================
# 16. CERTIFICATE TRANSPARENCY SUBDOMAIN DISCOVERY
# ============================================================================
scan_crt_sh() {
    log_result "[+] CERTIFICATE TRANSPARENCY (crt.sh)"
    led_scanning

    local apex_domain
    apex_domain=$(echo "$TARGET_HOST" | awk -F'.' '{if(NF>2) print $(NF-1)"."$NF; else print $0}')

    LOG "Querying crt.sh for *.${apex_domain}..."
    log_result "[*] Querying certificate transparency logs..."

    local tmpf1 tmpf2
    tmpf1="/tmp/crt1_$$.json"
    tmpf2="/tmp/crt2_$$.json"

    curl -s -m 45 --max-filesize 1000000 "https://crt.sh/?q=%25.${apex_domain}&output=json" -o "$tmpf1" 2>/dev/null
    curl -s -m 45 --max-filesize 1000000 "https://crt.sh/?q=${apex_domain}&output=json"      -o "$tmpf2" 2>/dev/null

    local f1size f2size
    f1size=$(wc -c < "$tmpf1" 2>/dev/null || echo 0)
    f2size=$(wc -c < "$tmpf2" 2>/dev/null || echo 0)

    if [ "${f1size:-0}" -lt 3 ] && [ "${f2size:-0}" -lt 3 ]; then
        log_result "[*] Could not reach crt.sh (check internet connection)"
        rm -f "$tmpf1" "$tmpf2"
        log_result ""
        return
    fi

    local apex_escaped
    apex_escaped=$(echo "$apex_domain" | sed 's/\./\\./g')

    local subdomains
    if command -v jq >/dev/null 2>&1; then
        subdomains=$(jq -r '.[].name_value' "$tmpf1" "$tmpf2" 2>/dev/null)
    fi
    if [ -z "$subdomains" ]; then
        subdomains=$(grep -ohE '"name_value":"[^"]*"' "$tmpf1" "$tmpf2" | \
            cut -d'"' -f4 | awk '{gsub(/\\n/,"\n"); print}')
    fi

    rm -f "$tmpf1" "$tmpf2"

    subdomains=$(printf '%s\n' "$subdomains" | \
        sed 's/^\*\.//' | \
        grep -E "(^|\.)${apex_escaped}$" | \
        grep -v "^$" | \
        sort -u)

    if [ -z "$subdomains" ]; then
        log_result "[*] No subdomains found via certificate transparency"
        log_result ""
        return
    fi

    local count
    count=$(echo "$subdomains" | grep -c '.' 2>/dev/null)

    local PROBE_CAP=25
    log_result "[*] Found $count unique subdomain(s) in CT logs:"
    if [ "$count" -gt "$PROBE_CAP" ]; then
        log_result "[*] Large target — probing first $PROBE_CAP, listing remainder without probing"
    fi
    log_result ""

    local probe_list
    probe_list=$(echo "$subdomains" | head -n "$PROBE_CAP")

    local alive=0
    local probed=0
    while IFS= read -r sub; do
        [ -z "$sub" ] && continue

        local status
        status=$(curl -s -o /dev/null -w "%{http_code}" -m 4 --connect-timeout 3 "https://${sub}" 2>/dev/null)
        if [ -z "$status" ] || [ "$status" = "000" ]; then
            status=$(curl -s -o /dev/null -w "%{http_code}" -m 4 --connect-timeout 3 "http://${sub}" 2>/dev/null)
        fi

        case "$status" in
            200|301|302|307|308|401|403)
                log_result "  [ALIVE] $sub  (HTTP $status)"
                log_finding "INFO" "Active subdomain: $sub (HTTP $status)"
                alive=$((alive + 1))
                play_found
                ;;
            ""|000)
                log_result "  [----]  $sub"
                ;;
            *)
                log_result "  [HTTP $status]  $sub"
                ;;
        esac
        probed=$((probed + 1))
        sleep 0.1
    done <<< "$probe_list"

    log_result ""
    if [ "$count" -gt "$PROBE_CAP" ]; then
        log_result "[*] $alive/$PROBE_CAP probed responding ($(( count - PROBE_CAP )) additional not probed — run targeted scan for full enumeration)"
    else
        log_result "[*] $alive/$count subdomains responding"
    fi
    log_result ""
}

# ============================================================================
# 17. DNS RECORD ENUMERATION
# ============================================================================
scan_dns_enum() {
    log_result "[+] DNS RECORD ENUMERATION"
    led_scanning

    local apex_domain
    apex_domain=$(echo "$TARGET_HOST" | awk -F'.' '{if(NF>2) print $(NF-1)"."$NF; else print $0}')
    log_result "[*] Apex domain: $apex_domain"
    log_result ""

    # --- A Records ---
    log_result "━━━ A Records ━━━"
    local a_records
    a_records=$(nslookup -type=A "$TARGET_HOST" 2>/dev/null | grep "Address:" | grep -vE "#53|:53" | awk '{print $2}')
    [ -z "$a_records" ] && a_records=$(doh_query "$TARGET_HOST" "A")
    if [ -n "$a_records" ]; then
        echo "$a_records" | while IFS= read -r ip; do
            [ -n "$ip" ] && log_result "  A    $ip"
        done
    else
        log_result "  (no A records found)"
    fi

    # --- AAAA Records ---
    log_result ""
    log_result "━━━ AAAA Records (IPv6) ━━━"
    local aaaa_records
    aaaa_records=$(doh_query "$TARGET_HOST" "AAAA" | grep ':')
    if [ -n "$aaaa_records" ]; then
        echo "$aaaa_records" | while IFS= read -r ip6; do
            [ -n "$ip6" ] && log_result "  AAAA $ip6"
        done
    else
        log_result "  (none)"
    fi

    # --- NS Records ---
    log_result ""
    log_result "━━━ NS Records ━━━"
    local ns_records
    ns_records=$(nslookup -type=NS "$apex_domain" 2>/dev/null | grep "nameserver" | awk '{print $NF}')
    [ -z "$ns_records" ] && ns_records=$(doh_query "$apex_domain" "NS")
    if [ -n "$ns_records" ]; then
        echo "$ns_records" | while IFS= read -r ns; do
            [ -n "$ns" ] && log_result "  NS   $ns"
        done
        if echo "$ns_records" | grep -qi "cloudflare"; then
            log_finding "INFO" "Cloudflare nameservers (WAF/CDN active)"
        fi
        if echo "$ns_records" | grep -qi "awsdns"; then
            log_finding "INFO" "AWS Route53 nameservers"
        fi
        if echo "$ns_records" | grep -qi "googledomains\|google\."; then
            log_finding "INFO" "Google Cloud DNS nameservers"
        fi
    else
        log_result "  (none)"
    fi

    # --- MX Records ---
    log_result ""
    log_result "━━━ MX Records ━━━"
    local mx_records
    mx_records=$(nslookup -type=MX "$apex_domain" 2>/dev/null | grep "mail exchanger" | sed 's/.*= //')
    [ -z "$mx_records" ] && mx_records=$(doh_query "$apex_domain" "MX")
    if [ -n "$mx_records" ]; then
        echo "$mx_records" | while IFS= read -r mx; do
            [ -n "$mx" ] && log_result "  MX   $mx"
        done
        if echo "$mx_records" | grep -qiE "google|aspmx"; then
            log_finding "INFO" "Email: Google Workspace"
        fi
        if echo "$mx_records" | grep -qiE "outlook|protection\.outlook"; then
            log_finding "INFO" "Email: Microsoft 365"
        fi
        if echo "$mx_records" | grep -qi "protonmail"; then
            log_finding "INFO" "Email: ProtonMail"
        fi
        if echo "$mx_records" | grep -qi "mimecast"; then
            log_finding "INFO" "Email: Mimecast (email security gateway)"
        fi
    else
        log_result "  (none)"
    fi

    # --- TXT Records ---
    log_result ""
    log_result "━━━ TXT Records ━━━"
    local txt_records
    txt_records=$(nslookup -type=TXT "$apex_domain" 2>/dev/null | grep '"' | sed 's/.*= //')
    [ -z "$txt_records" ] && txt_records=$(doh_query "$apex_domain" "TXT")
    if [ -n "$txt_records" ]; then
        echo "$txt_records" | while IFS= read -r txt; do
            [ -n "$txt" ] && log_result "  TXT  $(echo "$txt" | cut -c1-100)"
        done
        log_result ""
        if echo "$txt_records" | grep -qi "v=spf1"; then
            log_finding "INFO" "SPF record present"
            if echo "$txt_records" | grep -qi "+all"; then
                log_finding "HIGH" "SPF +all — anyone can send as this domain!"
                play_found; led_found
            fi
        else
            log_finding "MEDIUM" "No SPF record — domain may be spoofable"
            play_found
        fi
        if echo "$txt_records" | grep -qi "google-site-verification"; then
            log_finding "INFO" "Google Search Console verified"
        fi
        if echo "$txt_records" | grep -qiE "MS=ms|microsoft-domain-verification"; then
            log_finding "INFO" "Microsoft 365 verified"
        fi
        if echo "$txt_records" | grep -qi "atlassian-domain-verification"; then
            log_finding "INFO" "Atlassian (Jira/Confluence) verified"
        fi
        if echo "$txt_records" | grep -qi "stripe-verification"; then
            log_finding "INFO" "Stripe payments verified"
        fi
        if echo "$txt_records" | grep -qi "facebook-domain-verification"; then
            log_finding "INFO" "Facebook domain verified"
        fi
    else
        log_result "  (none)"
        log_finding "MEDIUM" "No TXT records retrieved"
    fi

    # --- CNAME Records ---
    log_result ""
    log_result "━━━ CNAME Records ━━━"
    local cname
    cname=$(nslookup -type=CNAME "$TARGET_HOST" 2>/dev/null | grep "canonical name" | awk '{print $NF}')
    if [ -z "$cname" ]; then
        local cname_raw
        cname_raw=$(doh_query "$TARGET_HOST" "CNAME" | head -1)
        cname_raw=$(echo "$cname_raw" | sed 's/\.$//')
        if [ -n "$cname_raw" ] && ! echo "$cname_raw" | grep -q " " && [ "$cname_raw" != "$TARGET_HOST" ]; then
            cname="$cname_raw"
        fi
    fi
    if [ -n "$cname" ]; then
        log_result "  CNAME $cname"
        if echo "$cname" | grep -qiE "github\.io|\.s3\.amazonaws\.com|\.azurewebsites\.net|\.azureedge\.net|cloudfront\.net|herokuapp\.com|netlify\.app|vercel\.app|\.pages\.dev"; then
            log_finding "HIGH" "CNAME points to cloud service — potential subdomain takeover!"
            play_found; led_found
        fi
    else
        log_result "  (none / using A record directly)"
    fi

    # --- SOA Record ---
    log_result ""
    log_result "━━━ SOA Record ━━━"
    local soa
    soa=$(nslookup -type=SOA "$apex_domain" 2>/dev/null | grep "origin\|serial\|mail addr" | head -3)
    if [ -n "$soa" ]; then
        echo "$soa" | while IFS= read -r line; do log_result "  $line"; done
    else
        local soa_doh
        soa_doh=$(doh_query "$apex_domain" "SOA" | head -1)
        [ -n "$soa_doh" ] && log_result "  $soa_doh" || log_result "  (none)"
    fi

    # --- Zone Transfer Attempt (AXFR) ---
    log_result ""
    log_result "━━━ Zone Transfer (AXFR) ━━━"
    local ns_list
    ns_list=$(doh_query "$apex_domain" "NS" | head -3)
    local axfr_found=0

    if [ -z "$ns_list" ]; then
        log_result "  [*] Could not retrieve NS records for AXFR attempt"
    else
        local ns_count
        ns_count=$(echo "$ns_list" | grep -c '.' 2>/dev/null)
        log_result "  [*] Attempting AXFR against $ns_count nameserver(s)..."

        while IFS= read -r ns_server; do
            [ -z "$ns_server" ] && continue
            ns_server=$(echo "$ns_server" | sed 's/\.$//')
            log_result "  → $ns_server"
            LOG "Attempting AXFR via $ns_server..."

            local axfr
            axfr=$(timeout 8 nslookup -type=AXFR "$apex_domain" "$ns_server" 2>/dev/null)

            if [ -z "$axfr" ]; then
                log_result "    No response (timeout or connection refused)"
                continue
            fi

            if echo "$axfr" | grep -qiE "REFUSED|Transfer failed|not authoritative|cannot find|NOTAUTH|SERVFAIL"; then
                local reason
                reason=$(echo "$axfr" | grep -iEo "REFUSED|Transfer failed|not authoritative|cannot find|NOTAUTH|SERVFAIL" | head -1)
                log_result "    Rejected: $reason"
                continue
            fi

            local record_count line_count
            record_count=$(echo "$axfr" | grep -cE "IN[[:space:]]+(A|AAAA|MX|CNAME|TXT|NS|SOA|PTR)" 2>/dev/null)
            line_count=$(echo "$axfr" | wc -l | tr -d ' ')

            if [ "${record_count:-0}" -ge 3 ] || [ "${line_count:-0}" -ge 10 ]; then
                log_finding "CRITICAL" "Zone Transfer SUCCESSFUL via $ns_server! ($record_count records)"
                log_result "    Full zone dump saved to loot file"
                {
                    echo "--- AXFR ZONE DUMP via $ns_server ---"
                    echo "$axfr"
                    echo "--- END AXFR ---"
                } >> "$LOOTFILE"
                play_found; led_found
                axfr_found=1
            else
                log_result "    Rejected (no zone data in response)"
            fi
        done <<< "$ns_list"
    fi

    if [ $axfr_found -eq 0 ]; then
        log_result ""
        log_result "  [*] All zone transfers rejected (expected — good security)"
    fi

    log_result ""
}

# ============================================================================
# 18. EMAIL SECURITY (SPF / DMARC / DKIM / BIMI)
# ============================================================================
scan_email_security() {
    log_result "[+] EMAIL SECURITY CHECK"
    led_scanning

    local apex_domain
    apex_domain=$(echo "$TARGET_HOST" | awk -F'.' '{if(NF>2) print $(NF-1)"."$NF; else print $0}')
    LOG "Checking email security for $apex_domain..."

    # --- SPF ---
    log_result "━━━ SPF (Sender Policy Framework) ━━━"
    local spf
    spf=$(doh_query "$apex_domain" "TXT" | grep -i "v=spf1" | head -1)
    [ -z "$spf" ] && spf=$(nslookup -type=TXT "$apex_domain" 2>/dev/null | grep -i "v=spf1" | sed 's/.*= //' | head -1)

    if [ -n "$spf" ]; then
        log_result "[*] SPF: $spf"
        if echo "$spf" | grep -q "+all"; then
            log_finding "HIGH" "SPF +all — anyone can send email as this domain!"
            play_found; led_found
        elif echo "$spf" | grep -q "\?all"; then
            log_finding "MEDIUM" "SPF ?all (neutral) — effectively no protection"
            play_found
        elif echo "$spf" | grep -q "~all"; then
            log_finding "MEDIUM" "SPF ~all (softfail) — receivers may not reject spoofed mail"
            play_found
        elif echo "$spf" | grep -q "\-all"; then
            log_finding "INFO" "SPF -all (hardfail) — strong policy, spoofed mail rejected"
        fi
    else
        log_finding "HIGH" "No SPF record — domain spoofable for phishing!"
        play_found; led_found
    fi

    # --- DMARC ---
    log_result ""
    log_result "━━━ DMARC ━━━"
    local dmarc
    dmarc=$(doh_query "_dmarc.${apex_domain}" "TXT" | grep -i "v=DMARC1" | head -1)
    [ -z "$dmarc" ] && dmarc=$(nslookup -type=TXT "_dmarc.${apex_domain}" 2>/dev/null | grep -i "v=DMARC1" | sed 's/.*= //' | head -1)

    if [ -n "$dmarc" ]; then
        log_result "[*] DMARC: $dmarc"
        local dmarc_policy
        dmarc_policy=$(echo "$dmarc" | grep -oiE '[^a-z]p=(none|quarantine|reject)' | grep -oiE '(none|quarantine|reject)' | head -1 | tr '[:upper:]' '[:lower:]')
        local dmarc_pct
        dmarc_pct=$(echo "$dmarc" | grep -oiE 'pct=[0-9]+' | cut -d'=' -f2)
        local dmarc_rua
        dmarc_rua=$(echo "$dmarc" | grep -oiE 'rua=mailto:[^;[:space:]]+' | head -1)

        case "$dmarc_policy" in
            none)
                log_finding "MEDIUM" "DMARC p=none — monitoring only, spoofed emails NOT blocked"
                play_found
                ;;
            quarantine)
                log_finding "INFO" "DMARC p=quarantine — spoofed mail goes to spam"
                ;;
            reject)
                log_finding "INFO" "DMARC p=reject — strongest policy, spoofed mail rejected"
                ;;
            *)
                log_finding "MEDIUM" "DMARC record found but policy is unclear"
                ;;
        esac
        if [ -n "$dmarc_pct" ] && [ "$dmarc_pct" != "100" ]; then
            log_finding "LOW" "DMARC pct=$dmarc_pct% — policy only applies to $dmarc_pct% of messages"
        fi
        [ -n "$dmarc_rua" ] && log_result "  Reports: $dmarc_rua"
    else
        log_finding "HIGH" "No DMARC record — no email authentication enforcement"
        play_found; led_found
    fi

    # --- DKIM (common selectors) ---
    log_result ""
    log_result "━━━ DKIM (common selectors) ━━━"
    local selectors="default google mail k1 selector1 selector2 dkim smtp email mailjet sendgrid amazonses"
    local dkim_found=0

    for selector in $selectors; do
        local dkim_rec
        dkim_rec=$(doh_query "${selector}._domainkey.${apex_domain}" "TXT" | grep -iE "v=DKIM1|k=rsa|p=" | head -1)
        if [ -n "$dkim_rec" ]; then
            log_result "[*] DKIM selector '$selector' found"
            log_result "    $(echo "$dkim_rec" | cut -c1-80)..."
            log_finding "INFO" "DKIM configured (selector: $selector)"
            dkim_found=1
            local dkim_key
            dkim_key=$(echo "$dkim_rec" | grep -oE 'p=[A-Za-z0-9+/=]+' | cut -d'=' -f2-)
            if [ -n "$dkim_key" ] && [ ${#dkim_key} -lt 172 ]; then
                log_finding "HIGH" "DKIM key for '$selector' may be 512/768-bit (crackable!)"
                play_found
            fi
            sleep 0.2
        fi
    done

    if [ $dkim_found -eq 0 ]; then
        log_finding "MEDIUM" "No DKIM selectors found (checked common selectors)"
    fi

    # --- BIMI ---
    log_result ""
    log_result "━━━ BIMI (Brand Indicators) ━━━"
    local bimi
    bimi=$(doh_query "default._bimi.${apex_domain}" "TXT" | grep -i "v=BIMI1" | head -1)
    if [ -n "$bimi" ]; then
        log_result "[*] BIMI configured: $(echo "$bimi" | cut -c1-80)"
        log_finding "INFO" "BIMI present (brand logo in email clients — requires DMARC p=reject)"
    else
        log_result "[*] No BIMI record (optional)"
    fi

    log_result ""
}

# ============================================================================
# 19. CSP DEEP ANALYSIS
# ============================================================================
scan_csp_analysis() {
    log_result "[+] CSP DEEP ANALYSIS"
    led_scanning

    LOG "Fetching CSP for $TARGET_URL..."
    local headers
    headers=$(curl -sI -m $TIMEOUT "$TARGET_URL" 2>/dev/null)
    local body
    body=$(curl -s -m $TIMEOUT "$TARGET_URL" 2>/dev/null | head -c 20000)

    local csp
    csp=$(echo "$headers" | grep -i "^Content-Security-Policy:" | cut -d':' -f2- | tr -d '\r' | sed 's/^ //')
    local csp_ro
    csp_ro=$(echo "$headers" | grep -i "^Content-Security-Policy-Report-Only:" | cut -d':' -f2- | tr -d '\r' | sed 's/^ //')

    if [ -z "$csp" ]; then
        csp=$(echo "$body" | grep -oi '<meta[^>]*http-equiv[^>]*Content-Security-Policy[^>]*>' | \
            grep -oi 'content="[^"]*"' | cut -d'"' -f2 | head -1)
        [ -n "$csp" ] && log_result "[*] CSP found in HTML meta tag"
    fi

    if [ -z "$csp" ]; then
        if [ -n "$csp_ro" ]; then
            log_finding "MEDIUM" "Only Content-Security-Policy-Report-Only set — not enforced"
            log_result "[*] Report-Only value: $(echo "$csp_ro" | cut -c1-120)"
        else
            log_finding "MEDIUM" "No Content-Security-Policy header found"
            log_result "  Recommendation: Implement CSP to mitigate XSS attacks"
        fi
        log_result ""
        return
    fi

    log_result "[*] CSP header found"
    log_result "[*] Value: $(echo "$csp" | cut -c1-150)..."
    log_result ""

    local issues=0


    if echo "$csp" | grep -qiE "script-src[^;]*'unsafe-inline'|default-src[^;]*'unsafe-inline'"; then
        log_finding "HIGH" "CSP 'unsafe-inline' in script-src — inline XSS not blocked"
        log_result "  Any <script> tag or on* event handler can execute"
        play_found; led_found
        issues=$((issues + 1))
    fi

    if echo "$csp" | grep -qiE "script-src[^;]*'unsafe-eval'|default-src[^;]*'unsafe-eval'"; then
        log_finding "HIGH" "CSP 'unsafe-eval' in script-src — eval() / new Function() allowed"
        play_found
        issues=$((issues + 1))
    fi

    if echo "$csp" | grep -qiE "script-src[^;]* \*( |;|$)|default-src[^;]* \*( |;|$)"; then
        log_finding "HIGH" "CSP wildcard (*) in script-src — scripts loadable from any domain"
        play_found
        issues=$((issues + 1))
    fi

    if echo "$csp" | grep -qiE "script-src[^;]*data:|default-src[^;]*data:"; then
        log_finding "HIGH" "CSP data: URI in script-src — data URI scripts allowed"
        play_found
        issues=$((issues + 1))
    fi

    if echo "$csp" | grep -qiE "script-src[^;]*http:|default-src[^;]*http:"; then
        log_finding "HIGH" "CSP http: scheme in script-src — any HTTP URL can serve scripts"
        play_found
        issues=$((issues + 1))
    fi

    local jsonp_cdns="cdn.jsdelivr.net ajax.googleapis.com cdnjs.cloudflare.com code.jquery.com unpkg.com"
    for cdn in $jsonp_cdns; do
        if echo "$csp" | grep -qiE "script-src[^;]*${cdn}|default-src[^;]*${cdn}"; then
            log_finding "MEDIUM" "CSP whitelists $cdn — JSONP callback bypass may be possible"
            issues=$((issues + 1))
        fi
    done


    if ! echo "$csp" | grep -qiE "(default-src|script-src)"; then
        log_finding "HIGH" "CSP: no default-src or script-src directive"
        play_found
        issues=$((issues + 1))
    fi

    if ! echo "$csp" | grep -qi "frame-ancestors"; then
        log_finding "MEDIUM" "CSP: no frame-ancestors directive — clickjacking risk"
        issues=$((issues + 1))
    fi

    if ! echo "$csp" | grep -qi "form-action"; then
        log_finding "LOW" "CSP: no form-action directive — form submissions unrestricted"
        issues=$((issues + 1))
    fi

    if ! echo "$csp" | grep -qi "base-uri"; then
        log_finding "LOW" "CSP: no base-uri directive — <base> tag injection possible"
        issues=$((issues + 1))
    fi

    if ! echo "$csp" | grep -qi "object-src"; then
        log_finding "LOW" "CSP: no object-src directive — plugin/Flash XSS vectors unrestricted"
        issues=$((issues + 1))
    fi


    if echo "$csp" | grep -qiE "'nonce-"; then
        log_finding "INFO" "CSP uses nonce-based policy (good — harder to bypass)"
    fi

    if echo "$csp" | grep -qiE "'sha(256|384|512)-"; then
        log_finding "INFO" "CSP uses hash-based policy (good — harder to bypass)"
    fi

    if echo "$csp" | grep -qi "upgrade-insecure-requests"; then
        log_finding "INFO" "CSP upgrade-insecure-requests present"
    fi

    if echo "$csp" | grep -qi "report-uri\|report-to"; then
        log_finding "INFO" "CSP violation reporting configured"
    fi

    log_result ""
    if [ $issues -eq 0 ]; then
        log_finding "INFO" "CSP appears well-configured (no bypass vectors found)"
    else
        log_result "[*] CSP issues found: $issues"
    fi

    [ -n "$csp_ro" ] && log_result "[*] Report-Only CSP also present alongside enforced CSP"

    log_result ""
}

# === MAIN MENU ===

show_menu() {
    PROMPT "=== CURLY SCANNER ===\n\nSelect scan mode:\n\n1. Quick Scan\n2. Full Scan (All Modules)\n3. API Recon\n4. Security Audit\n5. Tech Fingerprint\n6. Subdomain Enum\n7. DNS Recon\n8. Port Scan"
}

# === MAIN ===

LOG "green" "================================"
LOG "green" "     CURLY - Web Recon Scanner"
LOG "green" "        by curtthecoder"
LOG "green" "================================"
LOG ""

# === CONNECTION CHECK ===
LOG "yellow" "[*] Checking internet connection..."

CONN_TEST=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "https://dns.google/resolve?name=google.com&type=A" 2>/dev/null)

if [ "$CONN_TEST" != "200" ]; then
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

CURRENT_VERSION="4.0"
VERSION_CHECK_URL="https://raw.githubusercontent.com/hak5/wifipineapplepager-payloads/master/library/user/reconnaissance/curly/VERSION"
ENABLE_UPDATE_CHECK=true  # Set to false to disable

if [ "$ENABLE_UPDATE_CHECK" = true ]; then
    LOG "yellow" "[*] Checking for updates..."

    HTTP_RESPONSE=$(timeout 3 curl -s -w "\n%{http_code}" "$VERSION_CHECK_URL" 2>/dev/null)
    HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -1)
    LATEST_VERSION=$(echo "$HTTP_RESPONSE" | head -1 | tr -d '[:space:]')

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
        LOG "    [OK] Running current version (v${CURRENT_VERSION})"
    fi
fi
LOG ""

LOG "Please enter target URL..."
LOG "(e.g., example.com)"
TARGET_URL=$(TEXT_PICKER "Enter target URL" "example.com")

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

show_menu
SCAN_MODE=$(NUMBER_PICKER "Select scan mode" "1")

case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG "Operation cancelled"
        exit 1
        ;;
esac

LOG ""

case $SCAN_MODE in
    1) LOG "Starting Quick Scan (estimated: ~30-45 seconds)..." ;;
    2) LOG "Starting Full Scan (estimated: ~10-35 minutes)..." ;;
    3) LOG "Starting API Recon (estimated: ~45-60 seconds)..." ;;
    4) LOG "Starting Security Audit (estimated: ~90-120 seconds)..." ;;
    5) LOG "Starting Tech Fingerprint (estimated: ~20-30 seconds)..." ;;
    6) LOG "Starting Subdomain Enumeration (estimated: ~30-45 seconds)..." ;;
    7) LOG "Starting DNS Recon (estimated: ~45-90 seconds)..." ;;
    8) LOG "Starting Port Scan (estimated: ~3-8 minutes)..." ;;
esac

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
        scan_dns_enum
        scan_email_security
        scan_ssl_tls
        scan_waf
        scan_tech
        scan_wordpress_vulns
        scan_crt_sh
        scan_info
        scan_csp_analysis
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
        scan_ports
        ;;
    3)  # API Recon
        scan_crt_sh
        scan_endpoints
        scan_api
        ;;
    4)  # Security Audit
        scan_ip_geolocation
        scan_protocol_availability
        scan_whois
        scan_dns_enum
        scan_email_security
        scan_ssl_tls
        scan_tech
        scan_wordpress_vulns
        scan_info
        scan_csp_analysis
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
        scan_crt_sh
        ;;
    7)  # DNS Recon
        scan_dns_enum
        scan_email_security
        scan_crt_sh
        ;;
    8)  # Port Scan
        scan_ip_geolocation
        scan_ports
        scan_ssl_tls
        ;;
    *)
        LOG "Invalid scan mode!"
        exit 1
        ;;
esac

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

send_to_discord
send_to_slack

LOG "Check loot dir for details"
