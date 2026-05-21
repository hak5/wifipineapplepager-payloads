#!/bin/bash
# Title:       Jelly Sentinel
# Author:      hackagocthi
# Category:    Recon
# Description: Authorized network security assessment for home and SMB environments. Discovers devices, audits WiFi, checks vulnerabilities, inspects SSL, scans Bluetooth, captures traffic, and generates a scored loot report.
# version: 1.1

# CONFIGURATION
LOOT_BASE="/root/loot/jelly_sentinel"
TS=$(date +"%Y-%m-%d_%H%M%S")
LOOT_DIR="$LOOT_BASE/$TS"
REPORT="$LOOT_DIR/report.txt"
EXEC_SUMMARY="$LOOT_DIR/executive_summary.txt"
DEVICES_FILE="$LOOT_DIR/devices.txt"
FINDINGS_FILE="$LOOT_DIR/findings.txt"
WIFI_FILE="$LOOT_DIR/wifi.txt"
RAW_FILE="$LOOT_DIR/raw.txt"
CSV_FILE="$LOOT_DIR/findings.csv"
FP_FILE="$LOOT_DIR/fingerprint.txt"
DNS_FILE="$LOOT_DIR/dns_queries.txt"
TALKERS_FILE="$LOOT_DIR/top_talkers.txt"
BANNER_CVE_FILE="$LOOT_DIR/banner_cves.txt"
BT_FILE="$LOOT_DIR/bluetooth.txt"
SSL_FILE="$LOOT_DIR/ssl_certs.txt"
RECON_DB="/mmc/root/recon/recon.db"

mkdir -p "$LOOT_DIR"
for f in "$DEVICES_FILE" "$FINDINGS_FILE" "$WIFI_FILE" "$RAW_FILE" \
          "$FP_FILE" "$DNS_FILE" "$TALKERS_FILE" "$BANNER_CVE_FILE" \
          "$BT_FILE" "$SSL_FILE"; do
    > "$f"
done

IFACE="wlan0cli"
MON_IFACE="wlan0mon"
MON_IFACE_5="wlan1mon"
EXCLUDE_SUBNET="172.16.52"
OUR_IP=""
RISK_SCORE=0
CRITICAL_COUNT=0
HIGH_COUNT=0
MEDIUM_COUNT=0
LOW_COUNT=0
DEVICE_COUNT=0
SCAN_MODE="FULL"
TRAFFIC_DURATION=60
TESTER=""
TARGET=""
GPS_COORDS="N/A"
PORT_TIMEOUT=2
WIFI_SCAN_TIME=30

# GRACEFUL INTERRUPT
cleanup_on_exit() {
    trap - EXIT SIGINT SIGTERM
    LOG yellow "Interrupted — saving partial report..."
    WIFI_PCAP_STOP 2>/dev/null
    phase_executive_summary 2>/dev/null
    phase_report 2>/dev/null
    LOG yellow "Partial report: $LOOT_DIR"
    LED FAIL
    exit 0
}
trap cleanup_on_exit SIGINT SIGTERM

# HELPERS

add_finding() {
    local severity="$1" title="$2" detail="$3" cvss="$4" cve="$5" fix="$6"
    echo "$severity|$title|$detail|$cvss|$cve|$fix" >> "$FINDINGS_FILE"

    # CVSS-weighted scoring — higher CVSS scores contribute more within each tier
    local cvss_int score_add
    cvss_int=$(echo "${cvss:-5}" | cut -d. -f1)
    case "$severity" in
        CRITICAL) score_add=$(( 15 + (cvss_int > 9 ? 10 : cvss_int) )); CRITICAL_COUNT=$((CRITICAL_COUNT + 1)) ;;
        HIGH)     score_add=$(( 8  + (cvss_int > 7 ? 7  : cvss_int) )); HIGH_COUNT=$((HIGH_COUNT + 1)) ;;
        MEDIUM)   score_add=$(( 3  + (cvss_int > 5 ? 4  : cvss_int) )); MEDIUM_COUNT=$((MEDIUM_COUNT + 1)) ;;
        LOW)      score_add=3; LOW_COUNT=$((LOW_COUNT + 1)) ;;
    esac
    RISK_SCORE=$((RISK_SCORE + score_add))
    [ $RISK_SCORE -gt 100 ] && RISK_SCORE=100

    local total=$((CRITICAL_COUNT + HIGH_COUNT + MEDIUM_COUNT + LOW_COUNT))
    LOG blue "Findings: $total [C:$CRITICAL_COUNT H:$HIGH_COUNT M:$MEDIUM_COUNT L:$LOW_COUNT]"
}

oui_vendor() {
    local tmp="/tmp/jn_oui_$$.txt"
    whoismac -m "$1" > "$tmp" 2>/dev/null
    local result
    result=$(grep -m1 "^VENDOR:" "$tmp" \
        | sed 's/^VENDOR: //' \
        | sed 's/ (UAA).*//' \
        | sed 's/ (MAL).*//' \
        | sed 's/ (IAB).*//' \
        | cut -c1-25)
    rm -f "$tmp"
    echo "$result"
}

categorize_device() {
    local vendor="$1" ports="$2" hostname="$3" ip="$4"
    local combined
    combined=$(echo "$vendor $hostname" | tr 'A-Z' 'a-z')

    # Gateway IP = router regardless of vendor
    local gw
    gw=$(ip route | grep default | grep "$IFACE" | awk '{print $3}' | head -1)
    [ -n "$gw" ] && [ "$ip" = "$gw" ] && echo "ROUTER" && return

    # Vendor-based router classification ONLY if open management ports confirm it
    # This prevents TP-Link/ASUS EasyMesh nodes and other networking gear from
    # being misclassified as routers when they're acting as APs or switches
    local has_mgmt_ports=0
    echo "$ports" | grep -qE "\b80\b|\b443\b|\b8080\b|\b8443\b" && has_mgmt_ports=1

    if [ "$has_mgmt_ports" -eq 1 ]; then
        echo "$combined" | grep -qiE \
            "asus|netgear|tp-link|tplink|dlink|d-link|linksys|ubiquiti|mikrotik|openwrt|zyxel|arris|motorola|technicolor|router|gateway|airport|fritzbox|fritz" \
            && echo "ROUTER" && return
    else
        # Without open management ports, only classify as ROUTER if hostname/title
        # strongly implies it (not just vendor match)
        echo "$combined" | grep -qiE \
            "router|gateway|openwrt|fritzbox|fritz|mikrotik" \
            && echo "ROUTER" && return
    fi

    echo "$combined" | grep -qiE \
        "hikvision|dahua|axis|reolink|nest|ring|amcrest|lorex|camera|cam|nvr|dvr|ipcam|vivotek|foscam|wyze|eufy|arlo" \
        && echo "CAMERA" && return
    echo "$combined" | grep -qiE \
        "synology|qnap|western.digital|wd|buffalo|drobo|nas|diskstation|readynas|terramaster|seagate" \
        && echo "NAS" && return
    echo "$combined" | grep -qiE \
        "hp|hewlett|canon|epson|brother|xerox|ricoh|lexmark|kyocera|print|printer" \
        && echo "PRINTER" && return
    echo "$combined" | grep -qiE \
        "philips|hue|wemo|belkin|kasa|shelly|tasmota|sonoff|tuya|iot|espressif|esp8266|esp32|arduino" \
        && echo "IOT" && return
    echo "$combined" | grep -qiE \
        "roku|chromecast|firetv|fire.tv|appletv|apple.tv|samsung|lg|vizio|sony|bravia|shield|kodi|plex" \
        && echo "SMARTTV" && return
    echo "$combined" | grep -qiE \
        "cisco|polycom|grandstream|yealink|sip|voip|obihai" \
        && echo "VOIP" && return
    echo "$combined" | grep -qiE \
        "apple|iphone|ipad|android|oneplus|pixel|mobile|phone" \
        && echo "MOBILE" && return

    # Port-based classification — catches devices with no vendor match
    echo "$ports" | grep -qE "\b554\b|8000|8554" && echo "CAMERA"  && return
    echo "$ports" | grep -qE "5000|5001"          && echo "NAS"     && return
    echo "$ports" | grep -qE "9100|515\b"          && echo "PRINTER" && return
    echo "$ports" | grep -qE "5060|5061"           && echo "VOIP"    && return
    echo "$ports" | grep -qE "\b1883\b"            && echo "IOT"     && return
    echo "$ports" | grep -qE "\b8080\b|\b8443\b"   && echo "HOST"    && return
    echo "HOST"
}

device_icon() {
    case "$1" in
        ROUTER)  echo "[R]" ;; CAMERA)  echo "[C]" ;; NAS)     echo "[N]" ;;
        PRINTER) echo "[P]" ;; IOT)     echo "[I]" ;; SMARTTV) echo "[T]" ;;
        VOIP)    echo "[V]" ;; MOBILE)  echo "[M]" ;; *)       echo "[H]" ;;
    esac
}

http_banner()       { curl -sk --max-time "$PORT_TIMEOUT" --connect-timeout 2 -o /dev/null -w "%{http_code}" "${3:-http}://$1:$2/" 2>/dev/null; }
grab_title()        { curl -sk --max-time "$PORT_TIMEOUT" --connect-timeout 2 "${3:-http}://$1:$2/" 2>/dev/null | grep -oi '<title>[^<]*' | head -1 | sed 's/<title>//i' | cut -c1-50; }
grab_server_header(){ curl -skI --max-time "$PORT_TIMEOUT" --connect-timeout 2 "http://$1:$2/" 2>/dev/null | grep -i "^Server:" | cut -d' ' -f2- | tr -d '\r' | cut -c1-60; }
port_open()         { nc -z -w"$PORT_TIMEOUT" "$1" "$2" 2>/dev/null; }

show_progress() {
    local current="$1" total="$2" label="$3"
    [ "${total:-0}" -eq 0 ] && return
    local pct=$(( current * 100 / total ))
    local filled=$(( pct / 10 ))
    local bar="" i=0
    while [ $i -lt 10 ]; do
        [ $i -lt $filled ] && bar="${bar}#" || bar="${bar}-"
        i=$((i+1))
    done
    LOG blue "[$bar] $pct% $label"
}

# CVE BANNER LOOKUP ENGINE

lookup_banner_cve() {
    local banner="$1" ip="$2" port="$3"
    [ -z "$banner" ] && return
    local banner_l
    banner_l=$(echo "$banner" | tr 'A-Z' 'a-z')

    # HIGH confidence — exact vulnerable version string
    echo "$banner_l" | grep -q "apache/2\.4\.49" && {
        _emit_banner_cve "$ip" "$port" "$banner" "CVE-2021-41773" "9.8" \
            "Apache 2.4.49 path traversal and possible RCE" "Update Apache to 2.4.51+" "HIGH"
        return
    }
    echo "$banner_l" | grep -q "apache/2\.4\.50" && {
        _emit_banner_cve "$ip" "$port" "$banner" "CVE-2021-42013" "9.8" \
            "Apache 2.4.50 path traversal bypass" "Update Apache to 2.4.51+" "HIGH"
        return
    }
    echo "$banner_l" | grep -qE "nginx/1\.(1[0-7])\." && {
        _emit_banner_cve "$ip" "$port" "$banner" "CVE-2021-23017" "7.7" \
            "nginx version in affected range for DNS resolver overflow" "Upgrade nginx to 1.20.1+" "HIGH"
        return
    }
    echo "$banner_l" | grep -q "microsoft-iis/6" && {
        _emit_banner_cve "$ip" "$port" "$banner" "CVE-2017-7269" "10.0" \
            "IIS 6.0 is end-of-life and affected by buffer overflow RCE" "Decommission IIS 6.0 immediately" "HIGH"
        return
    }
    echo "$banner_l" | grep -qE "php/7\.(0|1|2|3)\." && {
        _emit_banner_cve "$ip" "$port" "$banner" "CVE-2019-11043" "9.8" \
            "PHP version in end-of-life range affected by PHP-FPM RCE" "Upgrade to PHP 8.1+" "HIGH"
        return
    }
    echo "$banner_l" | grep -qE "openssl/1\.0\." && {
        _emit_banner_cve "$ip" "$port" "$banner" "CVE-2014-0160" "7.5" \
            "OpenSSL version in Heartbleed-affected range" "Upgrade OpenSSL to 1.1.1+" "HIGH"
        return
    }
    echo "$banner_l" | grep -qi "uhttpd" && {
        _emit_banner_cve "$ip" "$port" "$banner" "CVE-2021-20090" "9.9" \
            "uhttpd identified — affected by path traversal in multiple router firmwares" "Update router firmware" "HIGH"
        return
    }

    # MEDIUM confidence — EOL software, version range match
    echo "$banner_l" | grep -qE "apache/2\.2\." && {
        _emit_eol "$ip" "$port" "$banner" \
            "Apache 2.2.x" "Apache 2.2.x is end-of-life with multiple unpatched CVEs" "Upgrade to Apache 2.4.x"
        return
    }
    echo "$banner_l" | grep -qE "php/5\." && {
        _emit_eol "$ip" "$port" "$banner" \
            "PHP 5.x" "PHP 5.x is end-of-life with multiple unpatched RCE vulnerabilities" "Upgrade to PHP 8.x"
        return
    }
    echo "$banner_l" | grep -qi "hikvision\|dvrdvs\|webs/1\.0" && {
        _emit_banner_cve "$ip" "$port" "$banner" "CVE-2021-36260" "9.8" \
            "Hikvision product observed — known to be affected by command injection RCE" "Update Hikvision firmware" "MEDIUM"
        return
    }
    echo "$banner_l" | grep -qi "mikrotik\|routeros" && {
        _emit_banner_cve "$ip" "$port" "$banner" "CVE-2018-14847" "9.1" \
            "MikroTik device observed — review RouterOS version for Winbox credential extraction" "Update RouterOS to 6.49.x+" "MEDIUM"
        return
    }
    echo "$banner_l" | grep -qi "zyxel\|zywall" && {
        _emit_banner_cve "$ip" "$port" "$banner" "CVE-2023-28771" "9.8" \
            "Zyxel device observed — review firmware version for OS command injection" "Apply Zyxel security patch" "MEDIUM"
        return
    }
    echo "$banner_l" | grep -qi "qnap\|qts" && {
        _emit_banner_cve "$ip" "$port" "$banner" "CVE-2022-27596" "9.8" \
            "QNAP device observed — review QTS version for SQL injection ransomware vector" "Update QNAP firmware" "MEDIUM"
        return
    }
    echo "$banner_l" | grep -qi "synology\|diskstation" && {
        _emit_banner_cve "$ip" "$port" "$banner" "CVE-2021-31439" "8.8" \
            "Synology device observed — review DSM version for Netatalk heap overflow" "Update to DSM 7.x" "MEDIUM"
        return
    }
    echo "$banner_l" | grep -qi "wordpress" && {
        _emit_banner_cve "$ip" "$port" "$banner" "CVE-2022-21661" "8.8" \
            "WordPress observed — review version for SQL injection via WP_Query" "Update WordPress to 5.8.3+" "MEDIUM"
        return
    }

    # LOW confidence — vendor/product mention only, no version
    echo "$banner_l" | grep -qi "dahua" && {
        _emit_banner_cve "$ip" "$port" "$banner" "CVE-2021-33044" "9.8" \
            "Dahua device observed — review firmware version for authentication bypass" "Update Dahua firmware" "LOW"
        return
    }
    echo "$banner_l" | grep -qi "cisco" && {
        _emit_banner_cve "$ip" "$port" "$banner" "CVE-2023-20198" "10.0" \
            "Cisco device observed — review IOS XE version for privilege escalation" "Disable HTTP server or apply Cisco patch" "LOW"
        return
    }

    # Version disclosure — no specific CVE but version info exposed
    echo "$banner_l" | grep -qE "[0-9]+\.[0-9]+" && {
        echo "$ip:$port|$banner|VERSION_DISCLOSURE|N/A|LOW|N/A|Version string in banner aids attacker fingerprinting|Remove version from Server header" \
            >> "$BANNER_CVE_FILE"
        add_finding "LOW" \
            "Version Disclosure: $ip:$port" \
            "Observed banner exposes version information: $banner" \
            "3.7" "N/A" "Remove version string from Server header"
        return
    }
}

_emit_banner_cve() {
    local ip="$1" port="$2" banner="$3" cve="$4" cvss="$5" desc="$6" fix="$7" confidence="${8:-MEDIUM}"
    echo "$ip:$port|$banner|$cve|$cvss|$confidence|$desc|$fix" >> "$BANNER_CVE_FILE"
    local sev="LOW"
    local cvss_int
    cvss_int=$(echo "$cvss" | cut -d. -f1)
    [ "$cvss_int" -ge 9 ] 2>/dev/null && sev="CRITICAL"
    [ "$cvss_int" -ge 7 ] && [ "$cvss_int" -lt 9 ] 2>/dev/null && sev="HIGH"
    [ "$cvss_int" -ge 4 ] && [ "$cvss_int" -lt 7 ] 2>/dev/null && sev="MEDIUM"

    # Adjust severity based on confidence level
    case "$confidence" in
        MEDIUM) [ "$sev" = "CRITICAL" ] && sev="HIGH" ;;
        LOW)    [ "$sev" = "CRITICAL" ] && sev="HIGH"
                [ "$sev" = "HIGH" ]     && sev="MEDIUM" ;;
    esac

    # Use softer language for low-confidence matches
    local title
    if [ "$confidence" = "LOW" ]; then
        title="Potential relevance to $cve [$confidence]: $ip:$port"
    else
        title="Possible $cve exposure [$confidence]: $ip:$port"
    fi

    add_finding "$sev" "$title" \
        "Observed banner suggests possible exposure to $cve. $desc. Observed banner: $banner" \
        "$cvss" "$cve" "$fix"
}

_emit_eol() {
    local ip="$1" port="$2" banner="$3" product="$4" desc="$5" fix="$6"
    echo "$ip:$port|$banner|EOL|N/A|MEDIUM|$desc|$fix" >> "$BANNER_CVE_FILE"
    add_finding "HIGH" \
        "End-of-life software: $product at $ip:$port" \
        "$desc. Multiple known CVEs may apply. Observed banner: $banner" \
        "N/A" "N/A" "$fix"
}

# PHASE 0 — PREFLIGHT

phase_preflight() {
    LOG ""
    LOG yellow "===== Jelly Sentinel v1.1 ====="
    LOG ""

    local batt
    batt=$(BATTERY_PERCENT 2>/dev/null)
    if [ -n "$batt" ]; then
        LOG "Battery: $batt%"
        if [ "${batt:-100}" -lt 20 ] 2>/dev/null; then
            local low_ok
            low_ok=$(CONFIRMATION_DIALOG "Battery low ($batt%). Continue?")
            [ "$low_ok" != "$DUCKYSCRIPT_USER_CONFIRMED" ] && \
                { LOG red "Cancelled — charge first"; exit 0; }
        fi
    fi

    local gps
    gps=$(GPS_GET 2>/dev/null)
    if [ -n "$gps" ] && [ "$gps" != "0 0 0 0" ]; then
        GPS_COORDS="$gps"
        LOG green "GPS: $GPS_COORDS"
    else
        GPS_COORDS="Not available"
    fi

    local cli_disabled
    cli_disabled=$(uci get wireless.wlan0cli.disabled 2>/dev/null)
    if [ "$cli_disabled" = "1" ]; then
        LOG yellow "Enabling wlan0cli..."
        uci set wireless.wlan0cli.disabled=0
        uci commit wireless
        wifi reload
        sleep 8
    fi

    ip link show "$IFACE" >/dev/null 2>&1 && ip link set "$IFACE" up 2>/dev/null

    local waited=0
    LOG yellow "Waiting for IP on $IFACE..."
    while [ $waited -lt 20 ]; do
        ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q inet && break
        sleep 2; waited=$((waited + 2))
    done

    if ! ip -4 addr show dev "$IFACE" 2>/dev/null | grep -q inet; then
        LOG red "No IP on $IFACE after ${waited}s"
        LED FAIL; exit 1
    fi

    OUR_IP=$(ip -4 addr show dev "$IFACE" 2>/dev/null \
        | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
    LOG green "Interface OK — $OUR_IP"
    sleep 1
}

# PHASE 0B — AUTHORIZATION

phase_authorization() {
    LOG ""
    LOG "Home & SMB Network Audit"
    LOG "Authorized use only"
    LOG ""

    local tester
    tester=$(TEXT_PICKER "Tester name" "Tester")
    case $? in "$DUCKYSCRIPT_CANCELLED"|"$DUCKYSCRIPT_REJECTED"|"$DUCKYSCRIPT_ERROR")
        LOG red "Cancelled"; exit 0 ;; esac
    [ -z "$tester" ] && tester="Unknown"

    local target
    target=$(TEXT_PICKER "Network / client name" "HomeNetwork")
    case $? in "$DUCKYSCRIPT_CANCELLED"|"$DUCKYSCRIPT_REJECTED"|"$DUCKYSCRIPT_ERROR")
        LOG red "Cancelled"; exit 0 ;; esac
    [ -z "$target" ] && target="Unknown"

    local mode
    mode=$(NUMBER_PICKER "1=Quick 2=Full 3=Stealth" 2)
    case $? in "$DUCKYSCRIPT_CANCELLED"|"$DUCKYSCRIPT_REJECTED"|"$DUCKYSCRIPT_ERROR")
        mode=2 ;; esac
    case "$mode" in
        1) SCAN_MODE="QUICK";   PORT_TIMEOUT=1; WIFI_SCAN_TIME=15; TRAFFIC_DURATION=30 ;;
        3) SCAN_MODE="STEALTH"; PORT_TIMEOUT=3; WIFI_SCAN_TIME=0;  TRAFFIC_DURATION=0  ;;
        *) SCAN_MODE="FULL";    PORT_TIMEOUT=2; WIFI_SCAN_TIME=30; TRAFFIC_DURATION=60 ;;
    esac

    local consent
    consent=$(CONFIRMATION_DIALOG "I am authorized to test this network")
    [ "$consent" != "$DUCKYSCRIPT_USER_CONFIRMED" ] && \
        { LOG red "Authorization denied. Exiting."; exit 0; }

    TESTER="$tester"
    TARGET="$target"

    {
        echo "================================================"
        echo "         JELLY SENTINEL SECURITY ASSESSMENT"
        echo "================================================"
        echo "Tester   : $TESTER"
        echo "Target   : $TARGET"
        echo "Date     : $(date)"
        echo "Scan Mode: $SCAN_MODE"
        echo "GPS      : $GPS_COORDS"
        echo "Consent  : CONFIRMED"
        echo "Tool     : Jelly Sentinel v1.1 / WiFi Pineapple Pager"
        echo "================================================"
        echo ""
    } > "$REPORT"

    echo "Severity,Title,Detail,CVSS,CVE,Remediation" > "$CSV_FILE"
    LOG green "Auth logged | Mode: $SCAN_MODE"
    sleep 1
}

# PHASE 1 — WIFI AUDIT (Native Pineapple Recon)

phase_wifi_audit() {
    local spinner
    spinner=$(START_SPINNER "Phase 1: WiFi Audit")

    { echo "--- PHASE 1: WIFI AUDIT ---"; echo ""; } >> "$REPORT"

    local ssid bssid channel ip gw
    ssid=$(iwgetid "$IFACE" -r 2>/dev/null)
    bssid=$(iwgetid "$IFACE" --ap 2>/dev/null | awk '{print $NF}')
    channel=$(iwgetid "$IFACE" --channel 2>/dev/null | awk '{print $NF}')
    ip=$(ip -4 addr show dev "$IFACE" 2>/dev/null | grep inet | awk '{print $2}' | head -1)
    gw=$(ip route | grep default | grep "$IFACE" | awk '{print $3}' | head -1)

    {
        echo "Connected SSID : ${ssid:-Not available}"
        echo "BSSID          : ${bssid:-Not available}"
        echo "Channel        : ${channel:-Not available}"
        echo "Our IP         : $ip"
        echo "Gateway        : $gw"
        echo ""
    } >> "$REPORT"

    if [ "$SCAN_MODE" != "STEALTH" ]; then
        LOG blue "Starting Pineapple recon ($WIFI_SCAN_TIME""s)..."
        PINEAPPLE_HOPPING_START 2>/dev/null
        PINEAPPLE_RECON_NEW "$WIFI_SCAN_TIME" 2>/dev/null
        PINEAPPLE_HOPPING_STOP 2>/dev/null
        sleep 2

        if [ -f "$RECON_DB" ]; then
            # Scope to current scan session — time is unix epoch in this DB
            local scan_start_epoch
            scan_start_epoch=$(( $(date +%s) - WIFI_SCAN_TIME - 30 ))

            local ap_count
            ap_count=$(sqlite3 "$RECON_DB" \
                "SELECT COUNT(DISTINCT bssid) FROM ssid
                 WHERE bssid != '' AND time >= $scan_start_epoch;" 2>/dev/null)
            # Fall back to last 5 minutes if scan window returns nothing
            if [ "${ap_count:-0}" -eq 0 ]; then
                local fallback_epoch=$(( $(date +%s) - 300 ))
                ap_count=$(sqlite3 "$RECON_DB" \
                    "SELECT COUNT(DISTINCT bssid) FROM ssid
                     WHERE bssid != '' AND time >= $fallback_epoch;" 2>/dev/null)
            fi
            LOG green "Recon DB: ${ap_count:-0} unique APs (this scan)"

            # Export current scan AP list to wifi file
            sqlite3 "$RECON_DB" \
                "SELECT bssid, ssid, channel, signal, encryption, hidden
                 FROM ssid WHERE bssid != '' AND time >= $scan_start_epoch
                 GROUP BY bssid HAVING signal = MAX(signal)
                 ORDER BY signal DESC;" 2>/dev/null \
                > "$WIFI_FILE"

            # Check for open networks
            local open_count
            open_count=$(sqlite3 "$RECON_DB" \
                "SELECT COUNT(DISTINCT bssid) FROM ssid
                 WHERE encryption = 0 AND bssid != ''
                 AND time >= $scan_start_epoch;" 2>/dev/null)
            [ "${open_count:-0}" -gt 0 ] && \
                add_finding "HIGH" "Open WiFi Networks ($open_count)" \
                    "$open_count unencrypted network(s) detected in range" \
                    "7.4" "N/A" "Enable WPA2/WPA3 on all wireless networks"

            # Check for WPS
            local wps_count
            wps_count=$(sqlite3 "$RECON_DB" \
                "SELECT COUNT(DISTINCT bssid) FROM ssid
                 WHERE (encryption & 4096) != 0 AND bssid != ''
                 AND time >= $scan_start_epoch;" 2>/dev/null)
            [ "${wps_count:-0}" -gt 0 ] && \
                add_finding "HIGH" "WPS Enabled ($wps_count APs)" \
                    "WPS detected on $wps_count AP(s) — Pixie Dust attack possible" \
                    "7.5" "CVE-2011-5053" "Disable WPS in router admin panel"

            # Hidden SSIDs
            local hidden_count
            hidden_count=$(sqlite3 "$RECON_DB" \
                "SELECT COUNT(DISTINCT bssid) FROM ssid
                 WHERE hidden = 1 AND bssid != ''
                 AND time >= $scan_start_epoch;" 2>/dev/null)
            [ "${hidden_count:-0}" -gt 0 ] && \
                add_finding "LOW" "Hidden SSIDs ($hidden_count)" \
                    "$hidden_count hidden network(s) — security through obscurity" \
                    "2.6" "N/A" "Hidden SSIDs provide no real security"

            {
                echo "APs in range   : ${ap_count:-0}"
                echo "Open networks  : ${open_count:-0}"
                echo "WPS enabled    : ${wps_count:-0}"
                echo "Hidden SSIDs   : ${hidden_count:-0}"
                echo ""
            } >> "$REPORT"
        fi

        PINEAPPLE_SSID_POOL_COLLECT_START 2>/dev/null
        sleep 5
        PINEAPPLE_SSID_POOL_COLLECT_STOP 2>/dev/null
        local probe_pool
        probe_pool=$(PINEAPPLE_SSID_POOL_LIST 2>/dev/null)
        if [ -n "$probe_pool" ]; then
            local probe_count
            probe_count=$(echo "$probe_pool" | wc -l)
            LOG blue "Probe SSIDs: $probe_count networks being sought"
            echo "--- PROBE SSIDS ($probe_count) ---" >> "$WIFI_FILE"
            echo "$probe_pool" >> "$WIFI_FILE"
        fi
    fi

    local scan_out
    scan_out=$(iw dev "$IFACE" scan 2>/dev/null | head -400)

    # Get connected BSSID to scope security checks to our AP only
    local connected_bssid
    connected_bssid=$(iw dev "$IFACE" link 2>/dev/null | grep "Connected to" | awk '{print $3}')

    # Scope PMF check to connected AP only
    if [ -n "$connected_bssid" ]; then
        local ap_block has_wpa2 has_wpa3 has_pmf
        # Extract the scan block for our connected AP
        ap_block=$(echo "$scan_out" | awk "/BSS ${connected_bssid}/,/^BSS /" | head -50)
        has_wpa2=$(echo "$ap_block" | grep -cE "WPA2|RSN" 2>/dev/null)
        has_wpa3=$(echo "$ap_block" | grep -cE "SAE|WPA3|PSK-SHA256" 2>/dev/null)
        has_pmf=$(echo "$ap_block" | grep -cE "MFP|MFPC|MFPR|80211w|ieee80211w|PMF" 2>/dev/null)
        if [ "${has_wpa2:-0}" -gt 0 ] && [ "${has_pmf:-0}" -eq 0 ] && [ "${has_wpa3:-0}" -eq 0 ]; then
            add_finding "MEDIUM" "PMF Not Enabled" \
                "Protected Management Frames disabled on connected AP — deauth attacks possible" \
                "5.3" "CVE-2019-16275" "Enable 802.11w in router WiFi settings"
        fi
    fi

    local cur_gw
    cur_gw=$(ip route | grep default | grep "$IFACE" | awk '{print $3}' | head -1)
    if [ -n "$cur_gw" ]; then
        local subnet
        subnet=$(echo "$cur_gw" | cut -d. -f1-3)
        local can_reach=0
        for test_ip in "$subnet.1" "$subnet.254" "$subnet.100"; do
            [ "$test_ip" = "$cur_gw" ] && continue
            ping -c1 -W1 "$test_ip" >/dev/null 2>&1 && { can_reach=1; break; }
        done
        [ "$can_reach" -eq 1 ] && add_finding "CRITICAL" \
            "Guest Network Not Isolated" \
            "Can reach internal LAN — no client isolation" \
            "9.1" "N/A" "Enable AP/client isolation on guest SSID"
    fi

    STOP_SPINNER "$spinner"
    LOG green "Phase 1 done"
}

# PHASE 2 — DEVICE DISCOVERY (nmap)

phase_discovery() {
    local spinner
    spinner=$(START_SPINNER "Phase 2: Discovery")

    { echo "--- PHASE 2: DEVICE DISCOVERY ---"; echo ""; } >> "$REPORT"

    local gw
    gw=$(ip route | grep default | grep "$IFACE" | awk '{print $3}' | head -1)
    local subnet
    subnet=$(echo "$gw" | cut -d. -f1-3)

    if [ -z "$subnet" ]; then
        STOP_SPINNER "$spinner"; LOG red "Cannot determine subnet"; return 1
    fi

    LOG blue "nmap sweep: $subnet.0/24..."

    local nmap_timing="-T4"
    [ "$SCAN_MODE" = "STEALTH" ] && nmap_timing="-T2"

    nmap -sn $nmap_timing --host-timeout 3s \
        "$subnet.0/24" -oG /tmp/jn_nmap.txt >/dev/null 2>&1

    grep "Status: Up" /tmp/jn_nmap.txt | while read -r line; do
        local dip
        dip=$(echo "$line" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1)
        [ -n "$dip" ] && ping -c1 -W1 "$dip" >/dev/null 2>&1 &
    done
    wait; sleep 1

    ip neigh show | grep -vE "FAILED|INCOMPLETE" \
        | grep -vE "^fe80:|^fd[0-9a-f]" > /tmp/jn_arp.txt 2>/dev/null

    ip -6 neigh show 2>/dev/null | grep -v FAILED > /tmp/jn_ipv6.txt 2>/dev/null
    local ipv6_count
    ipv6_count=$(wc -l < /tmp/jn_ipv6.txt 2>/dev/null)

    > /tmp/jn_mdns.txt
    if [ "$SCAN_MODE" = "FULL" ]; then
        timeout 5 tcpdump -i "$IFACE" -n udp port 5353 2>/dev/null \
            | grep -oE "[a-zA-Z0-9._-]+\.local" | sort -u > /tmp/jn_mdns.txt &
        sleep 5
    fi

    DEVICE_COUNT=0
    while IFS= read -r line; do
        local dip mac vendor hostname
        dip=$(echo "$line" | awk '{print $1}')
        mac=$(echo "$line" | grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}" | head -1)
        [ -z "$dip" ] || [ -z "$mac" ] && continue
        [ "$dip" = "$OUR_IP" ] && continue
        case "$dip" in "$EXCLUDE_SUBNET".*) continue ;; esac

        vendor=$(oui_vendor "$mac")

        hostname="N/A"
        if [ "$SCAN_MODE" = "FULL" ]; then
            hostname=$(nslookup "$dip" 2>/dev/null | grep "name = " \
                | awk '{print $NF}' | sed 's/\.$//' | head -1)
            [ -z "$hostname" ] && \
                hostname=$(grep -i "${dip##*.}" /tmp/jn_mdns.txt 2>/dev/null | head -1)
            [ -z "$hostname" ] && hostname="N/A"
            # Trim UUID-style or overly long hostnames
            echo "$hostname" | grep -qE "^[0-9a-f]{8}-" && hostname="N/A"
            [ ${#hostname} -gt 30 ] && hostname="${hostname:0:30}"
        fi

        echo "$dip|$mac|$vendor|$hostname" >> "$DEVICES_FILE"
        DEVICE_COUNT=$((DEVICE_COUNT + 1))
        show_progress "$DEVICE_COUNT" 30 "$dip"
    done < /tmp/jn_arp.txt

    if [ "$SCAN_MODE" != "STEALTH" ]; then
        local dhcp_count
        dhcp_count=$(timeout 3 tcpdump -i "$IFACE" -n "port 67 or port 68" 2>/dev/null \
            | grep -c "DHCP Offer" 2>/dev/null)
        [ "${dhcp_count:-0}" -gt 1 ] && add_finding "CRITICAL" \
            "Multiple DHCP Servers" "Rogue DHCP server detected — MITM risk" \
            "9.8" "N/A" "Enable DHCP snooping. Investigate all DHCP servers"
    fi

    [ "${ipv6_count:-0}" -gt 0 ] && {
        add_finding "LOW" "IPv6 Devices ($ipv6_count)" \
            "$ipv6_count device(s) on IPv6 — verify IPv6 firewall rules" \
            "3.1" "N/A" "Review router IPv6 firewall — often left open"
        cp /tmp/jn_ipv6.txt "$LOOT_DIR/ipv6.txt"
    }

    STOP_SPINNER "$spinner"
    { echo "Subnet    : $subnet.0/24"; echo "Devices   : $DEVICE_COUNT"
      echo "IPv6      : ${ipv6_count:-0}"; echo ""; } >> "$REPORT"
    LOG green "Phase 2 done — $DEVICE_COUNT devices"
}

# PHASE 3 — FINGERPRINTING + CVE BANNER + SSL INSPECTION

phase_fingerprint() {
    local spinner
    spinner=$(START_SPINNER "Phase 3: Fingerprint + CVE + SSL")

    { echo "--- PHASE 3: FINGERPRINTING ---"; echo ""
      printf "%-15s %-17s %-8s %-22s %s\n" "IP" "MAC" "TYPE" "VENDOR" "HOSTNAME"
      echo "--------------------------------------------------------------------"; } >> "$REPORT"

    local total_dev current_dev=0
    total_dev=$(wc -l < "$DEVICES_FILE" 2>/dev/null)

    local port_list="21,22,23,25,80,443,445,554,515,631,1883,3306,5000,5001,5060,7547,8080,8443,9100"
    [ "$SCAN_MODE" = "QUICK" ] && port_list="21,22,23,80,443,445,5000,8080"

    local nmap_timing="-T4"
    [ "$SCAN_MODE" = "STEALTH" ] && nmap_timing="-T2"

    local targets
    targets=$(awk -F'|' '{print $1}' "$DEVICES_FILE" | tr '\n' ' ')
    [ -z "$targets" ] && { STOP_SPINNER "$spinner"; return; }

    # Batch nmap in groups of 20 — keeps it fast on any network size
    > /tmp/jn_portscan.txt
    local batch=() count=0
    for target in $targets; do
        batch+=("$target")
        count=$((count + 1))
        if [ $count -ge 20 ]; then
            timeout 60 nmap $nmap_timing -p "$port_list" --open \
                --host-timeout 10s -oG - \
                "${batch[@]}" >> /tmp/jn_portscan.txt 2>/dev/null
            batch=(); count=0
        fi
    done
    # Remaining targets
    [ ${#batch[@]} -gt 0 ] && \
        timeout 60 nmap $nmap_timing -p "$port_list" --open \
            --host-timeout 10s -oG - \
            "${batch[@]}" >> /tmp/jn_portscan.txt 2>/dev/null

    while IFS='|' read -r dip mac vendor hostname; do
        current_dev=$((current_dev + 1))
        show_progress "$current_dev" "$total_dev" "$dip"

        local open_ports=""
        local nmap_line
        nmap_line=$(grep "Host: $dip " /tmp/jn_portscan.txt 2>/dev/null | head -1)
        [ -n "$nmap_line" ] && \
            open_ports=$(echo "$nmap_line" | grep -oE "[0-9]+/open" \
                | cut -d/ -f1 | tr '\n' ' ' | xargs)


        local http_title="" server_header=""
        for port in 80 8080 8443 443; do
            echo "$open_ports" | grep -q "$port" || continue
            local proto="http"
            [ "$port" = "443" ] && proto="https"
            local ph ps
            ph=$(grab_server_header "$dip" "$port")
            ps=$(grab_title "$dip" "$port" "$proto")
            [ -n "$ph" ] && lookup_banner_cve "$ph" "$dip" "$port"
            [ -n "$ps" ] && lookup_banner_cve "$ps" "$dip" "$port"
            [ -z "$server_header" ] && server_header="$ph"
            [ -z "$http_title" ]    && http_title="$ps"
        done

        if echo "$open_ports" | grep -qE "443|8443"; then
            local ssl_port=443
            echo "$open_ports" | grep -q "8443" && ssl_port=8443
            local ssl_info
            ssl_info=$(echo | timeout "$PORT_TIMEOUT" openssl s_client \
                -connect "$dip:$ssl_port" -brief 2>/dev/null \
                | grep -E "subject|issuer|expire|Verify" | head -5)
            if [ -n "$ssl_info" ]; then
                echo "=== $dip:$ssl_port ===" >> "$SSL_FILE"
                echo "$ssl_info" >> "$SSL_FILE"
                echo "" >> "$SSL_FILE"
                local issuer subject
                issuer=$(echo "$ssl_info" | grep "issuer" | head -1)
                subject=$(echo "$ssl_info" | grep "subject" | head -1)
                [ -n "$issuer" ] && [ "$issuer" = "$subject" ] && \
                    add_finding "MEDIUM" "Self-Signed SSL Cert: $dip:$ssl_port" \
                        "Device using self-signed certificate — MITM risk" \
                        "5.3" "N/A" "Install valid SSL certificate"
                echo "$ssl_info" | grep -qi "expired\|verify error" && \
                    add_finding "HIGH" "Expired SSL Cert: $dip:$ssl_port" \
                        "SSL certificate has expired" \
                        "7.5" "N/A" "Renew SSL certificate immediately"
            fi
        fi


        [ "$vendor" = "Unknown" ] && [ -n "$http_title" ] && vendor="$http_title"

        local category icon
        category=$(categorize_device "$vendor" "$open_ports" "$hostname $http_title" "$dip")
        icon=$(device_icon "$category")

        echo "$dip|$mac|$vendor|$hostname|$category|$open_ports|$http_title|$server_header" \
            >> "$FP_FILE"
        printf "%-15s %-17s %-8s %-22s %s\n" \
            "$dip" "$mac" "$icon $category" "${vendor:0:22}" "${hostname:0:25}" >> "$REPORT"

    done < "$DEVICES_FILE"

    echo "" >> "$REPORT"

    if [ -s "$BANNER_CVE_FILE" ]; then
        { echo "--- CVE BANNER MATCHES ---"; echo ""; } >> "$REPORT"
        while IFS='|' read -r target banner cve cvss confidence desc fix; do
            { echo "  [$target] $cve (CVSS $cvss)"
              echo "    Banner     : $banner"
              echo "    Confidence : $confidence"
              echo "    Issue      : $desc"
              echo "    Fix        : $fix"
              echo ""; } >> "$REPORT"
        done < "$BANNER_CVE_FILE"
    fi

    STOP_SPINNER "$spinner"
    LOG green "Phase 3 done"
}

# PHASE 4 — RISK CHECKS

phase_risk_checks() {
    local spinner
    spinner=$(START_SPINNER "Phase 4: Risk Checks")

    { echo "--- PHASE 4: RISK CHECKS ---"; echo ""; } >> "$REPORT"

    local total_dev current_dev=0
    total_dev=$(wc -l < "$FP_FILE" 2>/dev/null)
    local gw
    gw=$(ip route | grep default | grep "$IFACE" | awk '{print $3}' | head -1)

    while IFS='|' read -r dip mac vendor hostname category open_ports http_title server_header; do
        current_dev=$((current_dev + 1))
        show_progress "$current_dev" "$total_dev" "$dip ($category)"

        echo "$open_ports" | grep -qE "(^| )23( |$)" && \
            add_finding "CRITICAL" "Telnet Open ($category): $dip" \
                "$dip${vendor:+ ($vendor)} Telnet enabled — cleartext credentials" \
                "9.8" "N/A" "Disable Telnet. Use SSH"

        if echo "$open_ports" | grep -qE "(^| )21( |$)"; then
            local ftp_anon
            ftp_anon=$(curl -sk --max-time "$PORT_TIMEOUT" "ftp://$dip/" \
                --user "anonymous:anonymous" -w "%{http_code}" -o /dev/null 2>/dev/null)
            if [ "$ftp_anon" = "200" ] || [ "$ftp_anon" = "226" ]; then
                add_finding "CRITICAL" "Anonymous FTP ($category): $dip" \
                    "$dip allows unauthenticated FTP access" \
                    "9.1" "N/A" "Disable anonymous FTP"
            else
                add_finding "HIGH" "FTP Open ($category): $dip" \
                    "$dip${vendor:+ ($vendor)} FTP open — cleartext credentials" \
                    "7.5" "N/A" "Disable FTP. Use SFTP"
            fi
        fi

        local upnp_desc
        upnp_desc=$(curl -sk --max-time "$PORT_TIMEOUT" \
            "http://$dip:5000/rootDesc.xml" \
            "http://$dip:49152/rootDesc.xml" 2>/dev/null \
            | grep -oi "<modelName>[^<]*\|<manufacturer>[^<]*" | head -2 | tr '\n' ' ')
        [ -n "$upnp_desc" ] && add_finding "HIGH" "UPnP/IGD Exposed ($category): $dip" \
            "$dip UPnP responding — port mapping abuse. $upnp_desc" \
            "8.1" "CVE-2020-12695" "Disable UPnP on router"

        for port in 80 8080 8443; do
            echo "$open_ports" | grep -qE "(^| )$port( |$)" || continue
            local code
            code=$(http_banner "$dip" "$port")
            [ "$code" != "200" ] && continue
            local page
            page=$(curl -sk --max-time "$PORT_TIMEOUT" "http://$dip:$port/" 2>/dev/null)
            local is_admin has_auth
            is_admin=$(echo "$page" | grep -ciE "admin|management|dashboard|config|router|gateway" 2>/dev/null)
            has_auth=$(echo "$page" | grep -ciE "input.*type.*password|<form.*login" 2>/dev/null)
            [ "${is_admin:-0}" -gt 0 ] && [ "${has_auth:-0}" -eq 0 ] && \
                add_finding "CRITICAL" "Unauth Admin Panel ($category): $dip:$port" \
                    "Admin interface at $dip:$port — no login required" \
                    "9.8" "N/A" "Enable authentication immediately"
        done

        if [ "$category" = "ROUTER" ]; then
            local creds="admin:admin admin:password admin: admin:1234 root:root"
            local vendor_l
            vendor_l=$(echo "$vendor" | tr 'A-Z' 'a-z')
            echo "$vendor_l" | grep -qi "asus"     && creds="admin:admin $creds"
            echo "$vendor_l" | grep -qi "netgear"  && creds="admin:password $creds"
            echo "$vendor_l" | grep -qi "tplink\|tp-link" && creds="admin:admin $creds"
            echo "$vendor_l" | grep -qi "mikrotik" && creds="admin: $creds"
            echo "$vendor_l" | grep -qi "zyxel"    && creds="admin:1234 $creds"

            # Vendor-specific auth check — returns 0 if credentials worked
            _check_router_auth() {
                local ip="$1" user="$2" pass="$3" vl="$4"

                # TP-Link: POST to stok API, check for stok token in response
                if echo "$vl" | grep -qi "tplink\|tp-link"; then
                    local tplink_resp
                    tplink_resp=$(curl -sk --max-time "$PORT_TIMEOUT" \
                        -X POST "http://$ip/cgi-bin/luci/;stok=/login" \
                        -H "Content-Type: application/json" \
                        -d "{\"method\":\"do\",\"login\":{\"password\":\"$pass\"}}" \
                        2>/dev/null)
                    echo "$tplink_resp" | grep -q '"stok":"[a-f0-9]\+' && return 0
                    return 1
                fi

                # ASUS: POST to login.cgi, look for asus_token cookie
                if echo "$vl" | grep -qi "asus"; then
                    local asus_resp
                    asus_resp=$(curl -sk --max-time "$PORT_TIMEOUT" -c /tmp/jn_asus_cookie \
                        -X POST "http://$ip/login.cgi" \
                        -d "login_authorization=$(echo -n "$user:$pass" | base64)" \
                        -D - 2>/dev/null)
                    echo "$asus_resp" | grep -qi "asus_token" && return 0
                    return 1
                fi

                # Netgear: POST to check.php or basic auth to setup.cgi
                if echo "$vl" | grep -qi "netgear"; then
                    local ng_resp
                    ng_resp=$(curl -sk --max-time "$PORT_TIMEOUT" \
                        -u "$user:$pass" "http://$ip/setup.cgi?next_file=BAS_ether.htm" \
                        2>/dev/null)
                    echo "$ng_resp" | grep -qi "NETGEAR\|router\|firmware" && \
                        ! echo "$ng_resp" | grep -qi "login\|password\|unauthorized" && return 0
                    return 1
                fi

                # MikroTik: basic auth to /webfig/
                if echo "$vl" | grep -qi "mikrotik"; then
                    local mt_code
                    mt_code=$(curl -sk --max-time "$PORT_TIMEOUT" \
                        -u "$user:$pass" "http://$ip/webfig/" \
                        -w "%{http_code}" -o /tmp/jn_mt_body 2>/dev/null)
                    [ "$mt_code" = "200" ] && \
                        grep -qi "RouterOS\|webfig\|menu" /tmp/jn_mt_body 2>/dev/null && return 0
                    return 1
                fi

                # Generic fallback: basic auth + verify body looks like dashboard not login page
                local body code
                body=$(curl -sk --max-time "$PORT_TIMEOUT" \
                    -u "$user:$pass" "http://$ip/" \
                    -w "\n%{http_code}" 2>/dev/null)
                code=$(echo "$body" | tail -1)
                body=$(echo "$body" | head -n -1)
                # Must get 200/302 AND body must NOT look like a login page
                if [ "$code" = "200" ] || [ "$code" = "302" ]; then
                    echo "$body" | grep -qiE \
                        "logout|dashboard|connected.devices|firmware|wan.status|lan.status|dhcp.lease" \
                        && ! echo "$body" | grep -qiE \
                        "type=['\"]password['\"]|login.form|sign.in|enter.password|local.password" \
                        && return 0
                fi
                return 1
            }

            for cred in $creds; do
                local u p
                u=$(echo "$cred" | cut -d: -f1)
                p=$(echo "$cred" | cut -d: -f2)
                if _check_router_auth "$dip" "$u" "$p" "$vendor_l"; then
                    add_finding "CRITICAL" "Default Router Creds (ROUTER): $dip" \
                        "$dip${vendor:+ ($vendor)} accepts $u:$p" \
                        "9.8" "N/A" "Change router password immediately"
                    break
                fi
            done
        fi

        if [ "$category" = "CAMERA" ]; then
            local cam_creds="admin:admin admin:12345 admin:123456 root:root admin:"
            local vendor_l
            vendor_l=$(echo "$vendor $http_title" | tr 'A-Z' 'a-z')
            echo "$vendor_l" | grep -qi "hikvision" && cam_creds="admin:12345 $cam_creds"
            echo "$vendor_l" | grep -qi "dahua"     && cam_creds="admin:admin888 $cam_creds"
            for cred in $cam_creds; do
                local u p r1 r2
                u=$(echo "$cred" | cut -d: -f1); p=$(echo "$cred" | cut -d: -f2)
                r1=$(curl -sk --max-time "$PORT_TIMEOUT" -u "$u:$p" \
                    "http://$dip/ISAPI/System/deviceInfo" \
                    -w "%{http_code}" -o /dev/null 2>/dev/null)
                r2=$(curl -sk --max-time "$PORT_TIMEOUT" -u "$u:$p" \
                    "http://$dip/cgi-bin/magicBox.cgi?action=getSystemInfo" \
                    -w "%{http_code}" -o /dev/null 2>/dev/null)
                if [ "$r1" = "200" ] || [ "$r2" = "200" ]; then
                    add_finding "CRITICAL" "Default Camera Creds (CAMERA): $dip" \
                        "$dip${vendor:+ ($vendor)} accepts $u:$p" \
                        "9.8" "CVE-2017-7921" "Change camera password. Update firmware"
                    break
                fi
            done
            echo "$open_ports" | grep -qE "(^| )554( |$)" && \
                add_finding "HIGH" "RTSP Exposed (CAMERA): $dip" \
                    "Camera RTSP port 554 open — live video accessible" \
                    "7.5" "N/A" "Require RTSP auth. Firewall port 554"
        fi

        if [ "$category" = "NAS" ]; then
            for port in 5000 5001 8080; do
                echo "$open_ports" | grep -qE "(^| )$port( |$)" || continue
                local nas_code
                nas_code=$(http_banner "$dip" "$port")
                [ "$nas_code" = "200" ] && add_finding "MEDIUM" "NAS Admin Exposed (NAS): $dip:$port" \
                    "NAS management panel accessible" \
                    "5.3" "N/A" "Restrict NAS admin to trusted IPs"
            done
        fi

        if echo "$open_ports" | grep -qE "(^| )445( |$)"; then
            local smb_out
            smb_out=$(smbclient -L "$dip" -N 2>&1 | head -5)
            echo "$smb_out" | grep -ciE "NT1|LANMAN|SMB1" 2>/dev/null | grep -q "^[1-9]" && \
                add_finding "CRITICAL" "SMBv1 Enabled: $dip" \
                    "$dip has SMBv1 — EternalBlue vulnerable" \
                    "9.8" "CVE-2017-0144" "Disable SMBv1. Apply MS17-010"
            local shares
            shares=$(echo "$smb_out" | grep -c "Disk" 2>/dev/null)
            [ "${shares:-0}" -gt 0 ] && add_finding "HIGH" "Open SMB Shares: $dip" \
                "$dip has $shares anonymous share(s)" \
                "7.5" "N/A" "Require auth on all SMB shares"
        fi

        [ "$category" = "PRINTER" ] && {
            echo "$open_ports" | grep -qE "(^| )631( |$)" && \
                add_finding "MEDIUM" "Printer IPP (PRINTER): $dip" \
                    "IPP print service exposed" "5.3" "N/A" "Restrict printer access"
            echo "$open_ports" | grep -qE "(^| )9100( |$)" && \
                add_finding "HIGH" "Raw Print Port (PRINTER): $dip" \
                    "Port 9100 — unauthenticated printing possible" \
                    "7.5" "N/A" "Firewall port 9100"
        }

        [ "$category" = "IOT" ] && \
            echo "$open_ports" | grep -qE "(^| )1883( |$)" && \
            add_finding "HIGH" "MQTT Unencrypted (IOT): $dip" \
                "$dip${vendor:+ ($vendor)} cleartext MQTT on port 1883" \
                "7.5" "N/A" "Use MQTT-TLS port 8883. Require auth"

        echo "$open_ports" | grep -qE "(^| )5060( |$)|(^| )5061( |$)" && \
            add_finding "MEDIUM" "SIP Exposed (VOIP): $dip" \
                "$dip VoIP SIP port open — toll fraud risk" \
                "5.9" "N/A" "Restrict SIP to known endpoints"

        echo "$open_ports" | grep -qE "(^| )7547( |$)" && \
            add_finding "HIGH" "TR-069 Exposed ($category): $dip" \
                "ISP remote management port open" \
                "8.1" "CVE-2014-9222" "Block port 7547 at firewall"

        if port_open "$dip" 161; then
            local snmp_resp
            snmp_resp=$(snmpwalk -v1 -c public -t "$PORT_TIMEOUT" \
                "$dip" sysDescr.0 2>/dev/null | head -1)
            [ -n "$snmp_resp" ] && add_finding "HIGH" "SNMP Default Community ($category): $dip" \
                "$dip responds to 'public': $snmp_resp" \
                "7.5" "CVE-2002-0013" "Change SNMP community. Use SNMPv3"
        fi

        if [ "$dip" = "$gw" ]; then
            # Use a real external domain that should NEVER resolve to a private IP
            # If it does, the router's DNS is rebinding external names to LAN space
            local dns_test dns_hit=0
            for test_domain in "doubleclick.net" "google.com" "example.com"; do
                dns_test=$(nslookup "$test_domain" "$dip" 2>/dev/null \
                    | grep "Address" | grep -v "#53" | tail -1 | awk '{print $2}')
                [ -z "$dns_test" ] && continue
                if echo "$dns_test" | grep -qE \
                    "^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[01])\."; then
                    dns_hit=1
                    break
                fi
            done
            [ "$dns_hit" -eq 1 ] && \
                add_finding "HIGH" "DNS Rebinding Confirmed (ROUTER): $dip" \
                    "Router DNS resolved $test_domain to LAN IP $dns_test — active rebinding" \
                    "8.1" "N/A" "Enable DNS rebinding protection in router"
        fi

    done < "$FP_FILE"

    STOP_SPINNER "$spinner"
    LOG green "Phase 4 done"
}

# PHASE 5 — BLUETOOTH SCAN (native bluetoothctl)

phase_bluetooth() {
    [ "$SCAN_MODE" = "STEALTH" ] && return
    [ "$SCAN_MODE" = "QUICK" ] && return

    local spinner
    spinner=$(START_SPINNER "Phase 5: Bluetooth Scan")

    { echo "--- PHASE 5: BLUETOOTH SCAN ---"; echo ""; } >> "$REPORT"

    bluetoothctl power on 2>/dev/null
    sleep 1
    bluetoothctl scan on 2>/dev/null &
    local bt_pid=$!
    sleep 15
    kill $bt_pid 2>/dev/null

    local bt_devices
    bt_devices=$(bluetoothctl devices 2>/dev/null)
    local bt_count
    bt_count=$(echo "$bt_devices" | grep -c "Device" 2>/dev/null)

    if [ "${bt_count:-0}" -gt 0 ]; then
        {
            echo "Bluetooth devices found: $bt_count"
            echo ""
            echo "$bt_devices"
            echo ""
        } >> "$BT_FILE"

        { echo "  BT Devices Found: $bt_count"
          echo "$bt_devices" | head -10 | while read -r line; do
              echo "  $line"
          done
          echo ""; } >> "$REPORT"

        add_finding "LOW" "Bluetooth Devices Visible ($bt_count)" \
            "$bt_count Bluetooth device(s) discoverable nearby" \
            "3.1" "N/A" "Disable Bluetooth discoverability on devices not in use"
    else
        echo "No Bluetooth devices found" >> "$BT_FILE"
        echo "  No BT devices found" >> "$REPORT"
    fi

    bluetoothctl power off 2>/dev/null
    STOP_SPINNER "$spinner"
    LOG green "Phase 5 done — $bt_count BT devices"
}

# PHASE 6 — PASSIVE TRAFFIC ANALYSIS (native WIFI_PCAP)

phase_traffic_analysis() {
    [ "$SCAN_MODE" = "STEALTH" ] && return
    [ "${TRAFFIC_DURATION:-0}" -eq 0 ] && return

    local spinner
    spinner=$(START_SPINNER "Phase 6: Traffic ($TRAFFIC_DURATION""s)")

    { echo "--- PHASE 6: PASSIVE TRAFFIC ANALYSIS ---"; echo ""; } >> "$REPORT"

    local pcap_file="$LOOT_DIR/traffic.pcap"

    LOG blue "Capturing ${TRAFFIC_DURATION}s..."
    WIFI_PCAP_START "$pcap_file" "$IFACE" 2>/dev/null
    sleep "$TRAFFIC_DURATION"
    WIFI_PCAP_STOP 2>/dev/null

    if [ ! -s "$pcap_file" ]; then
        STOP_SPINNER "$spinner"
        LOG yellow "No traffic captured"
        return
    fi

    tcpdump -r "$pcap_file" -n 2>/dev/null \
        | awk '{
            if ($3 ~ /^[0-9]/) src=$3
            if ($5 ~ /^[0-9]/) dst=$5
            if (src && dst) {
                gsub(/\.[0-9]+:?$/, "", src)
                gsub(/\.[0-9]+:?$/, "", dst)
                count[src " -> " dst]++
            }
          }
          END { for (k in count) print count[k], k }' \
        | sort -rn | head -15 > "$TALKERS_FILE" 2>/dev/null

    tcpdump -r "$pcap_file" -n "udp port 53" 2>/dev/null \
        | grep -oE "A\? [a-zA-Z0-9._-]+" | sed 's/A? //' \
        | sort | uniq -c | sort -rn > "$DNS_FILE" 2>/dev/null
    local dns_count
    dns_count=$(wc -l < "$DNS_FILE" 2>/dev/null)

    local total_pkts https_pkts http_pkts dns_pkts smb_pkts mdns_pkts
    total_pkts=$(tcpdump -r "$pcap_file" -n 2>/dev/null | wc -l)
    https_pkts=$(tcpdump -r "$pcap_file" -n "tcp port 443" 2>/dev/null | wc -l)
    http_pkts=$(tcpdump -r "$pcap_file" -n "tcp port 80" 2>/dev/null | wc -l)
    dns_pkts=$(tcpdump -r "$pcap_file" -n "udp port 53" 2>/dev/null | wc -l)
    smb_pkts=$(tcpdump -r "$pcap_file" -n "tcp port 445" 2>/dev/null | wc -l)
    mdns_pkts=$(tcpdump -r "$pcap_file" -n "udp port 5353" 2>/dev/null | wc -l)

    local top_domain top_count
    top_domain=$(head -1 "$DNS_FILE" | awk '{print $2}')
    top_count=$(head -1 "$DNS_FILE" | awk '{print $1}')
    if [ "${top_count:-0}" -gt 30 ] 2>/dev/null; then
        add_finding "MEDIUM" "Possible C2 Beaconing: $top_domain" \
            "Domain queried ${top_count}x in ${TRAFFIC_DURATION}s — possible malware" \
            "5.9" "N/A" "Investigate which device is querying $top_domain repeatedly"
    fi

    local dga_count=0
    while IFS= read -r domain; do
        local label
        label=$(echo "$domain" | awk '{print $2}' | cut -d. -f1)
        local len=${#label}
        local vowels
        vowels=$(echo "$label" | tr -cd 'aeiou' | wc -c)
        [ "$len" -gt 12 ] && [ "${vowels:-0}" -eq 0 ] 2>/dev/null && \
            dga_count=$((dga_count + 1))
    done < "$DNS_FILE"
    [ "$dga_count" -gt 0 ] && add_finding "HIGH" \
        "Possible DGA/Malware Domains ($dga_count)" \
        "Random-looking DNS queries detected — possible malware C2" \
        "7.5" "N/A" "Investigate devices querying anomalous domains. Run malware scan"

    [ "${http_pkts:-0}" -gt 20 ] 2>/dev/null && \
        add_finding "MEDIUM" "Cleartext HTTP Traffic ($http_pkts pkts)" \
            "${http_pkts} HTTP packets observed — data may be unencrypted" \
            "5.3" "N/A" "Enforce HTTPS. Enable HSTS"

    {
        echo "  Total packets  : ${total_pkts:-0}"
        echo "  HTTPS          : ${https_pkts:-0}"
        echo "  HTTP           : ${http_pkts:-0}"
        echo "  DNS            : ${dns_pkts:-0}"
        echo "  SMB            : ${smb_pkts:-0}"
        echo "  mDNS           : ${mdns_pkts:-0}"
        echo "  DNS domains    : $dns_count unique"
        echo ""
        echo "  Top Talkers:"
        head -8 "$TALKERS_FILE" | while read -r cnt pair; do
            printf "    %-6s %s\n" "$cnt" "$pair"
        done
        echo ""
        echo "  Top DNS Queries:"
        head -8 "$DNS_FILE" | while read -r cnt domain; do
            printf "    %-6s %s\n" "$cnt" "$domain"
        done
        echo ""
    } >> "$REPORT"

    STOP_SPINNER "$spinner"

    local top_talker top_dns
    top_talker=$(head -1 "$TALKERS_FILE" 2>/dev/null | awk '{$1=""; print}' | xargs)
    top_dns=$(head -1 "$DNS_FILE" 2>/dev/null | awk '{print $2}')

    LOG green "Phase 6 done"
    LOG "Packets  : ${total_pkts:-0}"
    [ -n "$top_talker" ] && LOG "Top talk : $top_talker"
    [ -n "$top_dns"    ] && LOG "Top DNS  : $top_dns"
}

# PHASE 7 — DELTA REPORT

phase_delta() {
    local prev_scan
    prev_scan=$(ls -d "$LOOT_BASE"/[0-9]* 2>/dev/null | grep -v "$TS" | sort | tail -1)
    [ -z "$prev_scan" ] || [ ! -f "$prev_scan/findings.txt" ] && return

    { echo "--- DELTA vs PREVIOUS SCAN ---"
      echo "Previous: $(basename "$prev_scan")"; echo ""; } >> "$REPORT"

    local new_count=0 resolved_count=0 new_devices=0
    while IFS='|' read -r sev title rest; do
        grep -qF "$title" "$prev_scan/findings.txt" 2>/dev/null || {
            echo "  NEW: [$sev] $title" >> "$REPORT"
            new_count=$((new_count + 1))
        }
    done < "$FINDINGS_FILE"

    while IFS='|' read -r sev title rest; do
        grep -qF "$title" "$FINDINGS_FILE" 2>/dev/null || {
            echo "  RESOLVED: [$sev] $title" >> "$REPORT"
            resolved_count=$((resolved_count + 1))
        }
    done < "$prev_scan/findings.txt"

    while IFS='|' read -r dip mac vendor hostname; do
        grep -qF "$mac" "$prev_scan/devices.txt" 2>/dev/null || {
            echo "  NEW DEVICE: $dip ($vendor)" >> "$REPORT"
            new_devices=$((new_devices + 1))
        }
    done < "$DEVICES_FILE"

    { echo ""
      echo "New findings  : $new_count"
      echo "Resolved      : $resolved_count"
      echo "New devices   : $new_devices"
      echo ""; } >> "$REPORT"

    LOG blue "Delta: +$new_count new | $resolved_count resolved | +$new_devices new devices"
}

# PHASE 8 — EXECUTIVE SUMMARY

phase_executive_summary() {
    [ $RISK_SCORE -gt 100 ] && RISK_SCORE=100
    local risk_label="LOW"
    [ $RISK_SCORE -ge 75 ] && risk_label="CRITICAL"
    [ $RISK_SCORE -ge 50 ] && [ $RISK_SCORE -lt 75 ] && risk_label="HIGH"
    [ $RISK_SCORE -ge 25 ] && [ $RISK_SCORE -lt 50 ] && risk_label="MEDIUM"

    local top5="" rank=1
    for sev in CRITICAL HIGH MEDIUM LOW; do
        [ $rank -gt 5 ] && break
        while IFS='|' read -r severity title detail cvss cve fix; do
            [ $rank -gt 5 ] && break
            [ "$severity" != "$sev" ] && continue
            top5="$top5    $rank. [$sev] $title\n"
            rank=$((rank + 1))
        done < "$FINDINGS_FILE"
    done

    local total=$((CRITICAL_COUNT + HIGH_COUNT + MEDIUM_COUNT + LOW_COUNT))

    {
        echo "================================================"
        echo "            EXECUTIVE SUMMARY"
        echo "================================================"
        echo ""
        printf "  Network Security Score : %d / 100\n" "$RISK_SCORE"
        printf "  Risk Level             : %s\n"        "$risk_label"
        printf "  Total Findings         : %d\n"        "$total"
        printf "  Devices Assessed       : %d\n"        "$DEVICE_COUNT"
        printf "  Tester                 : %s\n"        "$TESTER"
        printf "  Target                 : %s\n"        "$TARGET"
        printf "  Date                   : %s\n"        "$(date)"
        printf "  GPS                    : %s\n"        "$GPS_COORDS"
        printf "  Scan Mode              : %s\n"        "$SCAN_MODE"
        echo ""
        echo "  Top Issues:"
        printf "%b" "$top5"
        echo ""
        printf "  %-10s %d findings\n" "CRITICAL" "$CRITICAL_COUNT"
        printf "  %-10s %d findings\n" "HIGH"     "$HIGH_COUNT"
        printf "  %-10s %d findings\n" "MEDIUM"   "$MEDIUM_COUNT"
        printf "  %-10s %d findings\n" "LOW"      "$LOW_COUNT"
        echo ""
        echo "================================================"
        echo ""
    } > "$EXEC_SUMMARY"

    local tmp_report="/tmp/jn_report_merged.txt"
    cat "$EXEC_SUMMARY" "$REPORT" > "$tmp_report" 2>/dev/null
    mv "$tmp_report" "$REPORT" 2>/dev/null
}

# PHASE 9 — FINAL REPORT + CSV

phase_report() {
    local spinner
    spinner=$(START_SPINNER "Generating report")

    phase_delta

    [ $RISK_SCORE -gt 100 ] && RISK_SCORE=100
    local risk_label="LOW"
    [ $RISK_SCORE -ge 75 ] && risk_label="CRITICAL"
    [ $RISK_SCORE -ge 50 ] && [ $RISK_SCORE -lt 75 ] && risk_label="HIGH"
    [ $RISK_SCORE -ge 25 ] && [ $RISK_SCORE -lt 50 ] && risk_label="MEDIUM"

    {
        echo ""
        echo "================================================"
        echo "              RISK SUMMARY"
        echo "================================================"
        echo ""
        printf "  Risk Score   : %d / 100 (%s)\n" "$RISK_SCORE" "$risk_label"
        printf "  Critical     : %d\n" "$CRITICAL_COUNT"
        printf "  High         : %d\n" "$HIGH_COUNT"
        printf "  Medium       : %d\n" "$MEDIUM_COUNT"
        printf "  Low          : %d\n" "$LOW_COUNT"
        printf "  Devices      : %d\n" "$DEVICE_COUNT"
        printf "  Scan Mode    : %s\n" "$SCAN_MODE"
        printf "  GPS          : %s\n" "$GPS_COORDS"
        echo ""
        echo "================================================"
        echo "              FINDINGS"
        echo "================================================"
        echo ""
    } >> "$REPORT"

    # Findings sorted by severity + CSV
    for sev in CRITICAL HIGH MEDIUM LOW; do
        while IFS='|' read -r severity title detail cvss cve fix; do
            [ "$severity" != "$sev" ] && continue
            # Extract confidence if present in title
            local conf=""
            echo "$title" | grep -qE "\[(HIGH|MEDIUM|LOW)\]" && \
                conf=$(echo "$title" | grep -oE "\[(HIGH|MEDIUM|LOW)\]" | tr -d '[]')
            {
                echo "[$severity] $title"
                [ -n "$conf" ] && echo "  Confidence : $conf"
                echo "  Detail : $detail"
                echo "  CVSS   : $cvss"
                [ "$cve" != "N/A" ] && echo "  CVE    : $cve"
                echo "  Fix    : $fix"
                echo ""
            } >> "$REPORT"
            local d_csv f_csv
            d_csv=$(echo "$detail" | sed 's/,/;/g')
            f_csv=$(echo "$fix"    | sed 's/,/;/g')
            echo "$severity,\"$title\",\"$d_csv\",$cvss,$cve,\"$f_csv\"" >> "$CSV_FILE"
        done < "$FINDINGS_FILE"
    done

    # Device inventory
    {
        echo "================================================"
        echo "             DEVICE INVENTORY"
        echo "================================================"
        echo ""
    } >> "$REPORT"

    while IFS='|' read -r dip mac vendor hostname category open_ports http_title server; do
        local icon
        icon=$(device_icon "$category")
        printf "%s %-8s %-15s %-17s %-22s %s\n" \
            "$icon" "$category" "$dip" "$mac" "${vendor:0:22}" "${hostname:0:25}" >> "$REPORT"
        [ -n "$open_ports" ]  && printf "          Ports  : %s\n" "$open_ports"  >> "$REPORT"
        [ -n "$http_title" ]  && printf "          Title  : %s\n" "$http_title"  >> "$REPORT"
        [ -n "$server" ]      && printf "          Server : %s\n" "$server"      >> "$REPORT"
        echo "" >> "$REPORT"
    done < "$FP_FILE"

    {
        echo "================================================"
        echo "Generated by Jelly Sentinel v1.1 / WiFi Pineapple Pager"
        echo "Tester: $TESTER | Target: $TARGET"
        echo "For authorized security testing only"
        echo "================================================"
    } >> "$REPORT"

    # Build and prepend executive summary
    phase_executive_summary

    STOP_SPINNER "$spinner"

    LOG ""
    LOG yellow "===== JELLY SENTINEL RESULTS ====="
    LOG ""
    LOG "Devices    : $DEVICE_COUNT"
    LOG "Mode       : $SCAN_MODE"
    LOG "Risk Score : $RISK_SCORE/100"
    LOG yellow "Risk Level : $risk_label"
    LOG ""
    LOG red    "Critical : $CRITICAL_COUNT"
    LOG yellow "High     : $HIGH_COUNT"
    LOG blue   "Medium   : $MEDIUM_COUNT"
    LOG        "Low      : $LOW_COUNT"
    LOG ""
    LOG green  "Loot: $LOOT_DIR"
}

# MAIN

LED SETUP

phase_preflight
phase_authorization

LED SPECIAL

phase_wifi_audit
phase_discovery
phase_fingerprint
phase_risk_checks
phase_bluetooth
phase_traffic_analysis
phase_report

trap - EXIT SIGINT SIGTERM

LED FINISH
RINGTONE "success"

LOG ""
LOG green "===== JELLY SENTINEL v1.1 COMPLETE ====="
LOG ""
LOG green "Loot saved to:"
LOG "$LOOT_DIR"
LOG ""
LOG "report.txt       — full report"
LOG "executive_summary.txt — summary"
LOG "findings.csv     — findings"
LOG "fingerprint.txt  — devices"
LOG "bluetooth.txt    — BT devices"
LOG "ssl_certs.txt    — SSL certs"
LOG "traffic.pcap     — packet capture"
LOG "dns_queries.txt  — DNS log"
LOG "top_talkers.txt  — top talkers"
LOG ""

LOG "Mode: $SCAN_MODE | Duration: ${TRAFFIC_DURATION}s | Interface: $IFACE"

exit 0
