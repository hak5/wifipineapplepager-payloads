#!/bin/sh

PAYLOAD_ROOT="/root/payloads/user"
PID_FILE="/tmp/nautilus_payload.pid"
OUTPUT_FILE="/tmp/nautilus_output.log"
CACHE_FILE="/tmp/nautilus_cache.json"
AUTH_CHALLENGE_FILE="/tmp/nautilus_auth_challenge"
AUTH_SESSION_FILE="/tmp/nautilus_auth_session"
SESSION_TIMEOUT=3600

generate_challenge() {
    local challenge=$(head -c 32 /dev/urandom 2>/dev/null | md5sum | cut -d' ' -f1)
    local timestamp=$(date +%s)
    echo "${challenge}:${timestamp}" > "$AUTH_CHALLENGE_FILE"
    echo "Content-Type: application/json"
    echo ""
    echo "{\"challenge\":\"$challenge\"}"
}

verify_auth() {
    local nonce="$1"
    local encrypted_b64="$2"

    if [ ! -f "$AUTH_CHALLENGE_FILE" ]; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"error":"No challenge issued"}'
        exit 1
    fi

    local stored=$(cat "$AUTH_CHALLENGE_FILE")
    local stored_challenge="${stored%%:*}"
    local stored_time="${stored##*:}"
    local now=$(date +%s)

    if [ $((now - stored_time)) -gt 60 ]; then
        rm -f "$AUTH_CHALLENGE_FILE"
        echo "Content-Type: application/json"
        echo ""
        echo '{"error":"Challenge expired"}'
        exit 1
    fi

    if [ "$nonce" != "$stored_challenge" ]; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"error":"Invalid challenge"}'
        exit 1
    fi

    rm -f "$AUTH_CHALLENGE_FILE"

    local key_hex=$(printf '%s' "$nonce" | openssl dgst -sha256 -hex 2>/dev/null | cut -d' ' -f2)
    local encrypted_hex=$(echo "$encrypted_b64" | base64 -d 2>/dev/null | hexdump -ve '1/1 "%02x"' 2>/dev/null)

    if [ -z "$encrypted_hex" ]; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"error":"Decode failed"}'
        exit 1
    fi

    if [ ${#encrypted_hex} -gt 256 ]; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"error":"Password too long"}'
        exit 1
    fi

    local password=""
    local i=0
    local len=${#encrypted_hex}
    local key_len=${#key_hex}
    while [ $i -lt $len ]; do
        local enc_byte=$(expr substr "$encrypted_hex" $((i + 1)) 2)
        local key_pos=$(( (i % key_len) + 1 ))
        local key_byte=$(expr substr "$key_hex" $key_pos 2)
        local dec_byte=$(printf '%02x' $((0x$enc_byte ^ 0x$key_byte)))
        password="${password}$(printf "\\x${dec_byte}")"
        i=$((i + 2))
    done

    local shadow_entry=$(grep '^root:' /etc/shadow 2>/dev/null)
    local shadow_hash=$(echo "$shadow_entry" | cut -d: -f2)
    local salt=$(echo "$shadow_hash" | cut -d'$' -f1-3)

    local test_hash=$(openssl passwd -1 -salt "$(echo "$salt" | cut -d'$' -f3)" "$password" 2>/dev/null)

    if [ "$test_hash" = "$shadow_hash" ]; then
        local session=$(head -c 32 /dev/urandom 2>/dev/null | md5sum | cut -d' ' -f1)
        local session_time=$(date +%s)
        echo "${session}:${session_time}" > "$AUTH_SESSION_FILE"
        echo "Content-Type: application/json"
        echo "Set-Cookie: nautilus_session=$session; Path=/; HttpOnly; SameSite=Strict"
        echo ""
        echo '{"success":true}'
    else
        echo "Content-Type: application/json"
        echo ""
        echo '{"error":"Invalid password"}'
    fi
}

check_session() {
    local session=""
    local cookies="$HTTP_COOKIE"
    local IFS=';'
    for cookie in $cookies; do
        cookie=$(echo "$cookie" | sed 's/^ *//')
        case "$cookie" in
            nautilus_session=*)
                session="${cookie#nautilus_session=}"
                ;;
        esac
    done
    unset IFS

    if [ -z "$session" ]; then
        return 1
    fi

    if [ ! -f "$AUTH_SESSION_FILE" ]; then
        return 1
    fi

    local stored=$(cat "$AUTH_SESSION_FILE")
    local stored_session="${stored%%:*}"
    local stored_time="${stored##*:}"
    local now=$(date +%s)

    if [ $((now - stored_time)) -gt $SESSION_TIMEOUT ]; then
        rm -f "$AUTH_SESSION_FILE"
        return 1
    fi

    if [ "$session" = "$stored_session" ]; then
        return 0
    fi

    return 1
}

require_auth() {
    if ! check_session; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"error":"Authentication required","code":"AUTH_REQUIRED"}'
        exit 1
    fi
}

csrf_check() {
    local action="$1"

    case "$action" in
        list) return 0 ;;
    esac

    local origin="$HTTP_ORIGIN"
    local referer="$HTTP_REFERER"
    local host="$HTTP_HOST"

    if [ -n "$origin" ]; then
        local origin_host=$(echo "$origin" | sed 's|^https\?://||' | sed 's|/.*||')
        if [ "$origin_host" != "$host" ]; then
            echo "Content-Type: application/json"
            echo ""
            echo '{"error":"CSRF protection: Origin mismatch"}'
            exit 1
        fi
        return 0
    fi

    if [ -n "$referer" ]; then
        local referer_host=$(echo "$referer" | sed 's|^https\?://||' | sed 's|/.*||')
        if [ "$referer_host" != "$host" ]; then
            echo "Content-Type: application/json"
            echo ""
            echo '{"error":"CSRF protection: Referer mismatch"}'
            exit 1
        fi
        return 0
    fi

    echo "Content-Type: application/json"
    echo ""
    echo '{"error":"CSRF protection: Missing Origin/Referer"}'
    exit 1
}

urldecode() {
    printf '%b' "$(echo "$1" | sed 's/+/ /g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"
}

TOKEN_FILE="/tmp/nautilus_csrf_token"

generate_token() {
    local token=$(head -c 16 /dev/urandom 2>/dev/null | md5sum | cut -d' ' -f1)
    if [ -z "$token" ]; then
        token=$(date +%s%N | md5sum | cut -d' ' -f1)
    fi
    echo "$token" > "$TOKEN_FILE"
    echo "Content-Type: application/json"
    echo ""
    echo "{\"token\":\"$token\"}"
}

validate_token() {
    local provided="$1"
    if [ ! -f "$TOKEN_FILE" ]; then
        return 1
    fi
    local stored=$(cat "$TOKEN_FILE")
    rm -f "$TOKEN_FILE"
    if [ "$provided" = "$stored" ] && [ -n "$stored" ]; then
        return 0
    fi
    return 1
}

list_payloads() {
    echo "Content-Type: application/json"
    echo ""
    if [ -f "$CACHE_FILE" ]; then
        cat "$CACHE_FILE"
    else
        echo '{"error":"Cache not ready. Refresh page."}'
    fi
}

delete_payload() {
    local payload_path="$1"

    case "$payload_path" in
        *..*)
            echo "Content-Type: application/json"
            echo ""
            echo '{"error":"Security: Path traversal not allowed"}'
            exit 1
            ;;
    esac

    case "$payload_path" in
        /root/payloads/user/*) ;;
        *)
            echo "Content-Type: application/json"
            echo ""
            echo '{"error":"Invalid path: must be in /root/payloads/user/"}'
            exit 1
            ;;
    esac

    case "$payload_path" in
        */payload.sh) ;;
        *)
            echo "Content-Type: application/json"
            echo ""
            echo '{"error":"Invalid payload file"}'
            exit 1
            ;;
    esac

    local payload_dir=$(dirname "$payload_path")

    if [ "$payload_dir" = "/root/payloads/user/remote_access/nautilus" ]; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"error":"Cannot delete Nautilus"}'
        exit 1
    fi

    if [ ! -d "$payload_dir" ]; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"error":"Payload not found"}'
        exit 1
    fi

    rm -rf "$payload_dir"

    /root/payloads/user/remote_access/nautilus/build_cache.sh >/dev/null 2>&1

    echo "Content-Type: application/json"
    echo ""
    echo '{"status":"deleted","path":"'"$payload_dir"'"}'
}

view_source() {
    local payload_path="$1"

    case "$payload_path" in
        *..*)
            echo "Content-Type: application/json"
            echo ""
            echo '{"error":"Security: Path traversal not allowed"}'
            exit 1
            ;;
    esac

    case "$payload_path" in
        /root/payloads/user/*) ;;
        *)
            echo "Content-Type: application/json"
            echo ""
            echo '{"error":"Invalid path: must be in /root/payloads/user/"}'
            exit 1
            ;;
    esac

    case "$payload_path" in
        */payload.sh) ;;
        *)
            echo "Content-Type: application/json"
            echo ""
            echo '{"error":"Invalid payload file"}'
            exit 1
            ;;
    esac

    if [ ! -f "$payload_path" ]; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"error":"Payload not found"}'
        exit 1
    fi

    echo "Content-Type: application/json"
    echo ""

    local content=$(cat "$payload_path" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | awk '{printf "%s\\n", $0}')
    echo "{\"content\":\"$content\",\"path\":\"$payload_path\"}"
}

run_payload() {
    rpath="$1"
    token="$2"

    if ! validate_token "$token"; then
        echo "Content-Type: text/plain"
        echo ""
        echo "CSRF protection: Invalid or missing token. Refresh and try again."
        exit 1
    fi

    case "$rpath" in
        *..*)
            echo "Content-Type: text/plain"
            echo ""
            echo "Security: Path traversal not allowed"
            exit 1
            ;;
    esac

    case "$rpath" in
        /root/payloads/user/*) ;;
        *) echo "Content-Type: text/plain"; echo ""; echo "Invalid path"; exit 1 ;;
    esac

    case "$rpath" in
        */payload.sh) ;;
        *) echo "Content-Type: text/plain"; echo ""; echo "Invalid payload file"; exit 1 ;;
    esac

    [ ! -f "$rpath" ] && { echo "Content-Type: text/plain"; echo ""; echo "Not found"; exit 1; }
    [ -f "$PID_FILE" ] && { kill $(cat "$PID_FILE") 2>/dev/null; rm -f "$PID_FILE"; }

    echo "Content-Type: text/event-stream"
    echo "Cache-Control: no-cache"
    echo ""

    WRAPPER="/tmp/nautilus_wrapper_$$.sh"
    cat > "$WRAPPER" << 'WRAPPER_EOF'
#!/bin/bash

_nautilus_emit() {
    local color="$1"
    shift
    local text="$*"
    if [ -n "$color" ]; then
        echo "[${color}] ${text}"
    else
        echo "$text"
    fi
}

LOG() {
    local color=""
    if [ "$#" -gt 1 ]; then
        color="$1"
        shift
    fi
    _nautilus_emit "$color" "$@"
    /usr/bin/LOG ${color:+"$color"} "$@" 2>/dev/null || true
}

ALERT() {
    echo "[PROMPT:alert] $*" >&2
    sleep 0.1
    _wait_response ""
}

ERROR_DIALOG() {
    echo "[PROMPT:error] $*" >&2
    sleep 0.1
    _wait_response ""
}

LED() {
    _nautilus_emit "blue" "LED: $*"
    /usr/bin/LED "$@" 2>/dev/null || true
}

_wait_response() {
    local resp_file="/tmp/nautilus_response"
    local default="$1"
    rm -f "$resp_file"
    local timeout=300
    while [ ! -f "$resp_file" ] && [ $timeout -gt 0 ]; do
        sleep 0.5
        timeout=$((timeout - 1))
    done
    if [ -f "$resp_file" ]; then
        cat "$resp_file"
        rm -f "$resp_file"
    else
        echo -n "$default"
    fi
}

CONFIRMATION_DIALOG() {
    local msg="$*"
    echo "[PROMPT:confirm] $msg" >&2
    sleep 0.1
    local resp=$(_wait_response "0")
    if [ "$resp" = "1" ]; then
        echo -n "1"
    else
        echo -n "0"
    fi
}

PROMPT() {
    local msg="$*"
    echo "[PROMPT:prompt] $msg" >&2
    _wait_response ""
}

TEXT_PICKER() {
    local title="$1"
    local default="$2"
    echo "[PROMPT:text:$default] $title" >&2
    _wait_response "$default"
}

NUMBER_PICKER() {
    local title="$1"
    local default="$2"
    echo "[PROMPT:number:$default] $title" >&2
    _wait_response "$default"
}

IP_PICKER() {
    local title="$1"
    local default="$2"
    echo "[PROMPT:ip:$default] $title" >&2
    _wait_response "$default"
}

MAC_PICKER() {
    local title="$1"
    local default="$2"
    echo "[PROMPT:mac:$default] $title" >&2
    _wait_response "$default"
}

SPINNER() {
    echo "[SPINNER:start] $*" >&2
}

SPINNER_STOP() {
    echo "[SPINNER:stop]" >&2
}

START_SPINNER() {
    local msg="$1"
    local id="nautilus_$$_$RANDOM"
    echo "[SPINNER:start:$id] $msg" >&2
    echo "$id"
}

STOP_SPINNER() {
    local id="$1"
    echo "[SPINNER:stop:$id]" >&2
}

WAIT_FOR_INPUT() {
    echo "[BUTTON_WAIT:ANY]" >&2
    sleep 0.1
    local btn=$(_wait_response "A")
    echo -n "$btn"
}

WAIT_FOR_BUTTON_PRESS() {
    local expected="$*"
    echo "[BUTTON_WAIT:$expected]" >&2
    sleep 0.1
    local btn=$(_wait_response "${1:-A}")
    echo -n "$btn"
}

export -f LOG ALERT ERROR_DIALOG LED CONFIRMATION_DIALOG PROMPT TEXT_PICKER NUMBER_PICKER IP_PICKER MAC_PICKER SPINNER SPINNER_STOP START_SPINNER STOP_SPINNER WAIT_FOR_INPUT WAIT_FOR_BUTTON_PRESS _nautilus_emit _wait_response

cd "$(dirname "$1")"
source "$1"
WRAPPER_EOF
    chmod +x "$WRAPPER"

    : > "$OUTPUT_FILE"

    /bin/bash "$WRAPPER" "$rpath" >> "$OUTPUT_FILE" 2>&1 &
    WRAPPER_PID=$!
    echo $WRAPPER_PID > "$PID_FILE"

    sent_lines=0

    while kill -0 $WRAPPER_PID 2>/dev/null || [ $(wc -l < "$OUTPUT_FILE") -gt $sent_lines ]; do
        current_lines=$(wc -l < "$OUTPUT_FILE")
        if [ $current_lines -gt $sent_lines ]; then
            tail -n +$((sent_lines + 1)) "$OUTPUT_FILE" | head -n $((current_lines - sent_lines)) | while IFS= read -r line; do
            escaped=$(printf '%s' "$line" | sed 's/\\/\\\\/g; s/"/\\"/g')
            case "$line" in
                "[PROMPT:"*)
                    inner="${line#\[PROMPT:}"
                    type="${inner%%\]*}"
                    msg="${inner#*\] }"
                    if echo "$type" | grep -q ':'; then
                        default="${type#*:}"
                        type="${type%%:*}"
                    else
                        default=""
                    fi
                    escaped_msg=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
                    escaped_def=$(printf '%s' "$default" | sed 's/\\/\\\\/g; s/"/\\"/g')
                    printf 'event: prompt\ndata: {"type":"%s","message":"%s","default":"%s"}\n\n' "$type" "$escaped_msg" "$escaped_def"
                    continue ;;
                "[SPINNER:start"*)
                    inner="${line#\[SPINNER:start}"
                    if [ "${inner:0:1}" = ":" ]; then
                        inner="${inner:1}"
                        spinner_id="${inner%%\]*}"
                        spinner_msg="${inner#*\] }"
                    else
                        spinner_id=""
                        spinner_msg="${inner#\] }"
                    fi
                    escaped_msg=$(printf '%s' "$spinner_msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
                    printf 'event: spinner\ndata: {"action":"start","id":"%s","message":"%s"}\n\n' "$spinner_id" "$escaped_msg"
                    continue ;;
                "[SPINNER:stop"*)
                    inner="${line#\[SPINNER:stop}"
                    if [ "${inner:0:1}" = ":" ]; then
                        spinner_id="${inner:1}"
                        spinner_id="${spinner_id%%\]*}"
                    else
                        spinner_id=""
                    fi
                    printf 'event: spinner\ndata: {"action":"stop","id":"%s"}\n\n' "$spinner_id"
                    continue ;;
                "[BUTTON_WAIT:"*)
                    inner="${line#\[BUTTON_WAIT:}"
                    expected="${inner%%\]*}"
                    printf 'event: button_wait\ndata: {"expected":"%s"}\n\n' "$expected"
                    continue ;;
            esac
            color=""
            case "$line" in
                "[red]"*) color="red" ;;
                "[green]"*) color="green" ;;
                "[yellow]"*) color="yellow" ;;
                "[cyan]"*) color="cyan" ;;
                "[blue]"*) color="blue" ;;
                "[magenta]"*) color="magenta" ;;
            esac
                if [ -n "$color" ]; then
                    printf 'data: {"text":"%s","color":"%s"}\n\n' "$escaped" "$color"
                else
                    printf 'data: {"text":"%s"}\n\n' "$escaped"
                fi
            done
            sent_lines=$current_lines
        fi
        sleep 0.2
    done
    printf 'event: done\ndata: {"status":"complete"}\n\n'
    rm -f "$WRAPPER" "$PID_FILE"
}

respond() {
    echo "Content-Type: application/json"
    echo ""
    local response="$1"

    case "$response" in
        *[\$\`\;\|\&\>\<\(\)\{\}\[\]\!\#\*\?\\]*)
            echo '{"status":"error","message":"Invalid characters in response"}'
            exit 1
            ;;
    esac

    if [ ${#response} -gt 256 ]; then
        echo '{"status":"error","message":"Response too long"}'
        exit 1
    fi

    echo "$response" > "/tmp/nautilus_response"
    echo '{"status":"ok"}'
}

stop_payload() {
    echo "Content-Type: application/json"
    echo ""
    if [ -f "$PID_FILE" ]; then
        kill $(cat "$PID_FILE") 2>/dev/null
        rm -f "$PID_FILE"
    fi

    rm -rf /tmp/nautilus_github_* 2>/dev/null
    rm -f /tmp/nautilus_queue_* 2>/dev/null
    rm -f /tmp/nautilus_entries_* 2>/dev/null
    rm -f /tmp/nautilus_wrapper_* 2>/dev/null
    rm -f /tmp/nautilus_github_log_* 2>/dev/null

    if [ -f /tmp/nautilus_install_target ]; then
        target=$(cat /tmp/nautilus_install_target)
        rm -rf "$target" 2>/dev/null
        rm -f /tmp/nautilus_install_target
    fi
    rm -rf /tmp/nautilus_install_* 2>/dev/null

    pkill -f "curl.*nautilus_github" 2>/dev/null
    pkill -f "wget.*nautilus_github" 2>/dev/null
    pkill -f "curl.*nautilus_install" 2>/dev/null
    pkill -f "wget.*nautilus_install" 2>/dev/null

    echo '{"status":"stopped"}'
}

wifi_status() {
    echo "Content-Type: application/json"
    echo ""

    local disabled=$(uci -q get wireless.wlan0cli.disabled 2>/dev/null)
    local client_mode_enabled="false"
    [ "$disabled" != "1" ] && client_mode_enabled="true"

    local connected="false"
    local ssid=""
    local signal=""
    local quality=""
    local bssid=""
    local channel=""
    local mode=""
    local interface_exists="false"

    if ip link show wlan0cli >/dev/null 2>&1; then
        interface_exists="true"

        local info=$(iwinfo wlan0cli info 2>/dev/null)

        if [ -n "$info" ]; then
            local essid_line=$(echo "$info" | grep "ESSID:")
            if echo "$essid_line" | grep -q '"'; then
                ssid=$(echo "$essid_line" | sed 's/.*ESSID: "\([^"]*\)".*/\1/')
                if [ -n "$ssid" ]; then
                    connected="true"
                    signal=$(echo "$info" | grep "Signal:" | sed 's/.*Signal: \([^ ]*\).*/\1/')
                    quality=$(echo "$info" | grep "Link Quality:" | sed 's/.*Link Quality: \([^ ]*\).*/\1/')
                    bssid=$(echo "$info" | grep "Access Point:" | sed 's/.*Access Point: \([^ ]*\).*/\1/')
                    channel=$(echo "$info" | grep "Channel:" | sed 's/.*Channel: \([0-9]*\).*/\1/')
                    mode=$(echo "$info" | grep "Mode:" | sed 's/.*Mode: \([^ ]*\).*/\1/')
                fi
            fi
        fi
    fi

    ssid=$(printf '%s' "$ssid" | sed 's/\\/\\\\/g; s/"/\\"/g')

    cat << EOF
{
    "client_mode_enabled": $client_mode_enabled,
    "interface_exists": $interface_exists,
    "connected": $connected,
    "ssid": "$ssid",
    "signal": "$signal",
    "quality": "$quality",
    "bssid": "$bssid",
    "channel": "$channel",
    "mode": "$mode"
}
EOF
}

wifi_scan() {
    echo "Content-Type: text/event-stream"
    echo "Cache-Control: no-cache"
    echo ""

    sse_msg() {
        local type="$1"
        local data="$2"
        printf 'data: {"type":"%s",%s}\n\n' "$type" "$data"
    }

    sse_msg "status" '"message":"Starting WiFi scan..."'

    local scan_file="/tmp/nautilus_wifi_scan_$$"
    local iface=""

    if ip link show wlan0cli >/dev/null 2>&1; then
        iface="wlan0cli"
        sse_msg "status" '"message":"Scanning on client interface..."'
        iwinfo "$iface" scan 2>/dev/null > "$scan_file"
    fi

    if [ ! -s "$scan_file" ]; then
        iface="wlan0mon"
        sse_msg "status" '"message":"Scanning on 2.4GHz radio..."'
        iwinfo "$iface" scan 2>/dev/null > "$scan_file"
    fi

    if [ ! -s "$scan_file" ]; then
        iface="wlan1mon"
        sse_msg "status" '"message":"Scanning on 5GHz radio..."'
        iwinfo "$iface" scan 2>/dev/null > "$scan_file"
    fi

    if [ ! -s "$scan_file" ]; then
        sse_msg "error" '"message":"No scan results. Check WiFi interfaces."'
        rm -f "$scan_file"
        printf 'event: done\ndata: {"networks":[]}\n\n'
        return
    fi

    sse_msg "status" '"message":"Processing scan results..."'

    local networks="["
    local first=1
    local current_bssid=""
    local current_ssid=""
    local current_channel=""
    local current_signal=""
    local current_quality=""
    local current_encryption=""
    local current_mode=""

    while IFS= read -r line; do
        case "$line" in
            *"Cell "*" - Address: "*)
                if [ -n "$current_bssid" ] && [ -n "$current_ssid" ]; then
                    [ "$first" = "0" ] && networks="$networks,"
                    first=0
                    current_ssid=$(printf '%s' "$current_ssid" | sed 's/\\/\\\\/g; s/"/\\"/g')
                    networks="$networks{\"bssid\":\"$current_bssid\",\"ssid\":\"$current_ssid\",\"channel\":\"$current_channel\",\"signal\":\"$current_signal\",\"quality\":\"$current_quality\",\"encryption\":\"$current_encryption\",\"mode\":\"$current_mode\"}"
                fi
                current_bssid=$(echo "$line" | sed 's/.*Address: \([^ ]*\).*/\1/')
                current_ssid=""
                current_channel=""
                current_signal=""
                current_quality=""
                current_encryption="Open"
                current_mode=""
                ;;
            *"ESSID: "*)
                current_ssid=$(echo "$line" | sed 's/.*ESSID: "\([^"]*\)".*/\1/')
                ;;
            *"Channel: "*)
                current_channel=$(echo "$line" | sed 's/.*Channel: \([0-9]*\).*/\1/')
                current_mode=$(echo "$line" | sed 's/.*Mode: \([^ ]*\).*/\1/')
                ;;
            *"Signal: "*)
                current_signal=$(echo "$line" | sed 's/.*Signal: \([^ ]*\).*/\1/')
                current_quality=$(echo "$line" | sed 's/.*Quality: \([^ ]*\).*/\1/')
                ;;
            *"Encryption: "*)
                current_encryption=$(echo "$line" | sed 's/.*Encryption: \(.*\)/\1/' | sed 's/[[:space:]]*$//')
                ;;
        esac
    done < "$scan_file"

    if [ -n "$current_bssid" ] && [ -n "$current_ssid" ]; then
        [ "$first" = "0" ] && networks="$networks,"
        current_ssid=$(printf '%s' "$current_ssid" | sed 's/\\/\\\\/g; s/"/\\"/g')
        networks="$networks{\"bssid\":\"$current_bssid\",\"ssid\":\"$current_ssid\",\"channel\":\"$current_channel\",\"signal\":\"$current_signal\",\"quality\":\"$current_quality\",\"encryption\":\"$current_encryption\",\"mode\":\"$current_mode\"}"
    fi

    networks="$networks]"

    rm -f "$scan_file"

    sse_msg "status" '"message":"Scan complete"'
    printf 'event: done\ndata: {"networks":%s}\n\n' "$networks"
}

wifi_connect() {
    local ssid="$1"
    local password="$2"
    local encryption="$3"
    local bssid="$4"

    echo "Content-Type: text/event-stream"
    echo "Cache-Control: no-cache"
    echo ""

    sse_msg() {
        local type="$1"
        local msg="$2"
        printf 'data: {"type":"%s","message":"%s"}\n\n' "$type" "$msg"
    }

    if [ -z "$ssid" ]; then
        sse_msg "error" "SSID is required"
        printf 'event: done\ndata: {"success":false,"error":"SSID required"}\n\n'
        return
    fi

    local enc_type="psk2"
    case "$encryption" in
        *"WPA3"*|*"SAE"*)
            enc_type="sae"
            ;;
        *"WPA2"*|*"WPA "*|*"PSK"*)
            enc_type="psk2"
            ;;
        *"WEP"*)
            enc_type="wep"
            ;;
        *"Open"*|*"none"*|"")
            enc_type="open"
            password=""
            ;;
    esac

    sse_msg "status" "Connecting to $ssid..."

    sse_msg "status" "Enabling client interface..."
    uci -q set wireless.wlan0cli.disabled=0 2>/dev/null
    uci commit wireless 2>/dev/null

    sse_msg "status" "Configuring network..."
    uci -q set wireless.wlan0cli.ssid="$ssid" 2>/dev/null

    if [ "$enc_type" = "open" ] || [ -z "$password" ]; then
        uci -q set wireless.wlan0cli.encryption='none' 2>/dev/null
        uci -q delete wireless.wlan0cli.key 2>/dev/null
    else
        uci -q set wireless.wlan0cli.encryption="$enc_type" 2>/dev/null
        uci -q set wireless.wlan0cli.key="$password" 2>/dev/null
    fi

    if [ -n "$bssid" ] && [ "$bssid" != "ANY" ]; then
        uci -q set wireless.wlan0cli.bssid="$bssid" 2>/dev/null
    else
        uci -q delete wireless.wlan0cli.bssid 2>/dev/null
    fi

    uci commit wireless 2>/dev/null

    sse_msg "status" "Reloading WiFi..."
    wifi reload 2>/dev/null
    sleep 2

    sse_msg "status" "Waiting for interface..."

    local iface_attempts=0
    while [ $iface_attempts -lt 10 ]; do
        if ip link show wlan0cli >/dev/null 2>&1; then
            break
        fi
        sleep 1
        iface_attempts=$((iface_attempts + 1))
        sse_msg "status" "Waiting for interface... ($iface_attempts/10)"
    done

    if ! ip link show wlan0cli >/dev/null 2>&1; then
        sse_msg "error" "Interface failed to come up"
        printf 'event: done\ndata: {"success":false,"error":"Interface failed"}\n\n'
        return
    fi

    sse_msg "status" "Interface up, waiting for connection..."

    local attempts=0
    local connected=0
    while [ $attempts -lt 20 ]; do
        sleep 1
        attempts=$((attempts + 1))

        local info=$(iwinfo wlan0cli info 2>/dev/null)
        if echo "$info" | grep -q '"'; then
            local cur_ssid=$(echo "$info" | grep "ESSID:" | sed 's/.*ESSID: "\([^"]*\)".*/\1/')
            if [ "$cur_ssid" = "$ssid" ]; then
                connected=1
                break
            fi
        fi
        sse_msg "status" "Waiting for connection... ($attempts/20)"
    done

    if [ "$connected" = "1" ]; then
        local signal=$(iwinfo wlan0cli info 2>/dev/null | grep "Signal:" | sed 's/.*Signal: \([^ ]*\).*/\1/')
        sse_msg "success" "Connected to $ssid ($signal)"
        printf 'event: done\ndata: {"success":true,"ssid":"%s","signal":"%s"}\n\n' "$ssid" "$signal"
    else
        sse_msg "status" "Connection failed, cleaning up..."
        uci -q delete wireless.wlan0cli.ssid 2>/dev/null
        uci -q delete wireless.wlan0cli.key 2>/dev/null
        uci -q delete wireless.wlan0cli.bssid 2>/dev/null
        uci -q set wireless.wlan0cli.disabled=1 2>/dev/null
        uci commit wireless 2>/dev/null
        wifi reload 2>/dev/null
        sleep 1
        sse_msg "error" "Connection timeout - check password"
        printf 'event: done\ndata: {"success":false,"error":"Connection timeout"}\n\n'
    fi
}

wifi_disconnect() {
    echo "Content-Type: application/json"
    echo ""

    if WIFI_CLEAR wlan0cli 2>&1 >/dev/null; then
        echo '{"success":true,"message":"Disconnected from WiFi"}'
    else
        uci -q delete wireless.wlan0cli.ssid 2>/dev/null
        uci -q delete wireless.wlan0cli.key 2>/dev/null
        uci -q set wireless.wlan0cli.disabled=1 2>/dev/null
        uci commit wireless 2>/dev/null
        wifi reload 2>/dev/null
        echo '{"success":true,"message":"Disconnected from WiFi"}'
    fi
}

wifi_toggle_client_mode() {
    local enable="$1"

    echo "Content-Type: application/json"
    echo ""

    if [ "$enable" = "1" ]; then
        uci -q set wireless.wlan0cli.disabled=0 2>/dev/null
        uci commit wireless 2>/dev/null
        wifi reload 2>/dev/null
        sleep 2
        echo '{"success":true,"enabled":true,"message":"Client mode enabled"}'
    else
        uci -q set wireless.wlan0cli.disabled=1 2>/dev/null
        uci commit wireless 2>/dev/null
        wifi reload 2>/dev/null
        sleep 1
        echo '{"success":true,"enabled":false,"message":"Client mode disabled"}'
    fi
}

check_local_exists() {
    local github_path="$1"

    local rel_path="${github_path#library/}"
    local local_path="/root/payloads/${rel_path}"

    echo "Content-Type: application/json"
    echo ""

    if [ -d "$local_path" ]; then
        echo "{\"exists\":true,\"path\":\"$local_path\"}"
    else
        echo "{\"exists\":false,\"path\":\"$local_path\"}"
    fi
}

install_github() {
    github_url="$1"
    token="$2"
    force="$3"

    if ! validate_token "$token"; then
        echo "Content-Type: text/plain"
        echo ""
        echo "CSRF protection: Invalid or missing token. Refresh and try again."
        exit 1
    fi

    case "$github_url" in
        https://raw.githubusercontent.com/*/wifipineapplepager-payloads/*/payload.sh)
            ;;
        *)
            echo "Content-Type: text/plain"
            echo ""
            echo "Security: Only wifipineapplepager-payloads repos allowed"
            exit 1
            ;;
    esac

    case "$github_url" in
        *..* | *%2e%2e* | *%2E%2E* | *%2e%2E* | *%2E%2e*)
            echo "Content-Type: text/plain"
            echo ""
            echo "Security: Path traversal not allowed"
            exit 1
            ;;
    esac

    [ -f "$PID_FILE" ] && { kill $(cat "$PID_FILE") 2>/dev/null; rm -f "$PID_FILE"; }

    url_path="${github_url#https://raw.githubusercontent.com/}"
    repo_owner="${url_path%%/*}"
    url_path="${url_path#*/wifipineapplepager-payloads/}"
    branch="${url_path%%/*}"
    folder_path="${url_path#*/}"
    folder_path="${folder_path%/payload.sh}"
    full_repo="${repo_owner}/wifipineapplepager-payloads"

    local rel_path="${folder_path#library/}"
    local target_path="/root/payloads/${rel_path}"
    local payload_name="${rel_path##*/}"

    INSTALL_DIR="/tmp/nautilus_install_$$"
    mkdir -p "$INSTALL_DIR"

    echo "$target_path" > /tmp/nautilus_install_target

    echo "Content-Type: text/event-stream"
    echo "Cache-Control: no-cache"
    echo ""

    sse_msg() {
        local color="$1"
        local text="$2"
        local escaped=$(printf '%s' "$text" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')
        printf 'data: {"text":"[%s] %s","color":"%s"}\n\n' "$color" "$escaped" "$color"
    }

    if [ -d "$target_path" ] && [ "$force" != "1" ]; then
        sse_msg "yellow" "[Install] Payload already exists at $target_path"
        printf 'event: exists\ndata: {"path":"%s"}\n\n' "$target_path"
        rm -rf "$INSTALL_DIR"
        rm -f /tmp/nautilus_install_target
        return
    fi

    if [ -d "$target_path" ] && [ "$force" = "1" ]; then
        sse_msg "yellow" "[Install] Removing existing payload..."
        rm -rf "$target_path"
    fi

    download_folder="$folder_path"
    sse_msg "cyan" "[Install] Downloading: $payload_name"

    queue_file="/tmp/nautilus_install_queue_$$"
    download_count=0
    download_errors=0
    api_failed=0

    echo "$download_folder|" > "$queue_file"

    while [ -s "$queue_file" ]; do
        read -r queue_entry < "$queue_file"
        sed -i '1d' "$queue_file" 2>/dev/null || { tail -n +2 "$queue_file" > "$queue_file.tmp" && mv "$queue_file.tmp" "$queue_file"; }

        api_path="${queue_entry%%|*}"
        rel_path="${queue_entry#*|}"

        [ -z "$api_path" ] && continue

        local_dir="$INSTALL_DIR"
        [ -n "$rel_path" ] && local_dir="$INSTALL_DIR/$rel_path"
        mkdir -p "$local_dir"

        api_url="https://api.github.com/repos/${full_repo}/contents/${api_path}?ref=${branch}"
        json=""
        if command -v curl >/dev/null 2>&1; then
            json=$(curl -sf "$api_url" 2>/dev/null)
        elif command -v wget >/dev/null 2>&1; then
            json=$(wget -qO- "$api_url" 2>/dev/null)
        fi

        if [ -z "$json" ]; then
            api_failed=1
            break
        fi

        entries_file="/tmp/nautilus_install_entries_$$"

        echo "$json" | sed 's/},/}\n/g' | while IFS= read -r obj; do
            n=$(echo "$obj" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            t=$(echo "$obj" | sed -n 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            [ -n "$n" ] && echo "$n|$t"
        done > "$entries_file"

        while IFS='|' read -r name type; do
            [ -z "$name" ] && continue

            if [ "$type" = "dir" ]; then
                if [ -n "$rel_path" ]; then
                    echo "$api_path/$name|$rel_path/$name" >> "$queue_file"
                else
                    echo "$api_path/$name|$name" >> "$queue_file"
                fi
                sse_msg "cyan" "[Install] Scanning: $name/"
            elif [ "$type" = "file" ]; then
                file_url="https://raw.githubusercontent.com/${full_repo}/${branch}/${api_path}/${name}"
                dl_ok=0
                if command -v curl >/dev/null 2>&1; then
                    curl -sf -o "$local_dir/$name" "$file_url" 2>/dev/null && dl_ok=1
                elif command -v wget >/dev/null 2>&1; then
                    wget -q -O "$local_dir/$name" "$file_url" 2>/dev/null && dl_ok=1
                fi
                if [ "$dl_ok" = "1" ]; then
                    download_count=$((download_count + 1))
                    disp_name="$name"
                    [ -n "$rel_path" ] && disp_name="$rel_path/$name"
                    sse_msg "green" "[Install] Downloaded: $disp_name"
                else
                    download_errors=$((download_errors + 1))
                    sse_msg "red" "[Install] Failed: $name"
                fi
            else
                file_url="https://raw.githubusercontent.com/${full_repo}/${branch}/${api_path}/${name}"
                dl_ok=0
                if command -v curl >/dev/null 2>&1; then
                    curl -sf -o "$local_dir/$name" "$file_url" 2>/dev/null && dl_ok=1
                elif command -v wget >/dev/null 2>&1; then
                    wget -q -O "$local_dir/$name" "$file_url" 2>/dev/null && dl_ok=1
                fi
                if [ "$dl_ok" = "1" ]; then
                    download_count=$((download_count + 1))
                    sse_msg "green" "[Install] Downloaded: $name"
                else
                    if [ -n "$rel_path" ]; then
                        echo "$api_path/$name|$rel_path/$name" >> "$queue_file"
                    else
                        echo "$api_path/$name|$name" >> "$queue_file"
                    fi
                    sse_msg "cyan" "[Install] Scanning: $name/"
                fi
            fi
        done < "$entries_file"
        rm -f "$entries_file"
    done
    rm -f "$queue_file"

    if [ "$api_failed" = "1" ] && [ "$download_count" = "0" ]; then
        sse_msg "yellow" "[Install] API unavailable, downloading payload.sh only..."
        dl_ok=0
        if command -v wget >/dev/null 2>&1; then
            wget -q -O "$INSTALL_DIR/payload.sh" "$github_url" 2>/dev/null && dl_ok=1
        fi
        if [ "$dl_ok" != "1" ] && command -v curl >/dev/null 2>&1; then
            curl -sf -o "$INSTALL_DIR/payload.sh" "$github_url" 2>/dev/null && dl_ok=1
        fi
        if [ "$dl_ok" = "1" ]; then
            download_count=1
            sse_msg "green" "[Install] Downloaded: payload.sh"
        else
            sse_msg "red" "[Install] Failed to download payload.sh"
            printf 'event: done\ndata: {"status":"error","message":"Download failed"}\n\n'
            rm -rf "$INSTALL_DIR"
            rm -f /tmp/nautilus_install_target
            exit 1
        fi
    fi

    if [ ! -f "$INSTALL_DIR/payload.sh" ]; then
        sse_msg "red" "[Install] payload.sh not found in downloaded files"
        printf 'event: done\ndata: {"status":"error","message":"payload.sh not found"}\n\n'
        rm -rf "$INSTALL_DIR"
        rm -f /tmp/nautilus_install_target
        exit 1
    fi

    sse_msg "cyan" "[Install] Installing to $target_path..."
    mkdir -p "$(dirname "$target_path")"
    mv "$INSTALL_DIR" "$target_path"
    chmod +x "$target_path/payload.sh"

    rm -f /tmp/nautilus_install_target

    sse_msg "green" "[Install] Successfully installed $payload_name!"
    sse_msg "cyan" "[Install] Location: $target_path"
    sse_msg "cyan" "[Install] Files: $download_count downloaded, $download_errors errors"

    /root/payloads/user/remote_access/nautilus/build_cache.sh >/dev/null 2>&1

    printf 'event: done\ndata: {"status":"success","path":"%s","name":"%s"}\n\n' "$target_path" "$payload_name"
}

install_pr() {
    github_url="$1"
    token="$2"
    force="$3"
    pr_path="$4"

    if ! validate_token "$token"; then
        echo "Content-Type: text/plain"
        echo ""
        echo "CSRF protection: Invalid or missing token. Refresh and try again."
        exit 1
    fi

    case "$github_url" in
        https://raw.githubusercontent.com/*/wifipineapplepager-payloads/*/payload.sh)
            ;;
        *)
            echo "Content-Type: text/plain"
            echo ""
            echo "Security: Only wifipineapplepager-payloads repos allowed"
            exit 1
            ;;
    esac

    case "$github_url" in
        *..* | *%2e%2e* | *%2E%2E* | *%2e%2E* | *%2E%2e*)
            echo "Content-Type: text/plain"
            echo ""
            echo "Security: Path traversal not allowed"
            exit 1
            ;;
    esac

    [ -f "$PID_FILE" ] && { kill $(cat "$PID_FILE") 2>/dev/null; rm -f "$PID_FILE"; }

    local rel_path="${pr_path#library/}"
    local target_path="/root/payloads/${rel_path}"
    local payload_name="${rel_path##*/}"

    url_path="${github_url#https://raw.githubusercontent.com/}"
    repo_owner="${url_path%%/*}"
    url_path="${url_path#*/wifipineapplepager-payloads/}"
    commit_sha="${url_path%%/*}"
    folder_path="${url_path#*/}"
    folder_path="${folder_path%/payload.sh}"
    full_repo="${repo_owner}/wifipineapplepager-payloads"

    INSTALL_DIR="/tmp/nautilus_install_$$"
    mkdir -p "$INSTALL_DIR"

    echo "$target_path" > /tmp/nautilus_install_target

    echo "Content-Type: text/event-stream"
    echo "Cache-Control: no-cache"
    echo ""

    sse_msg() {
        local color="$1"
        local text="$2"
        local escaped=$(printf '%s' "$text" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')
        printf 'data: {"text":"[%s] %s","color":"%s"}\n\n' "$color" "$escaped" "$color"
    }

    if [ -d "$target_path" ] && [ "$force" != "1" ]; then
        sse_msg "yellow" "[Install] Payload already exists at $target_path"
        printf 'event: exists\ndata: {"path":"%s"}\n\n' "$target_path"
        rm -rf "$INSTALL_DIR"
        rm -f /tmp/nautilus_install_target
        return
    fi

    if [ -d "$target_path" ] && [ "$force" = "1" ]; then
        sse_msg "yellow" "[Install] Removing existing payload..."
        rm -rf "$target_path"
    fi

    download_folder="$folder_path"
    sse_msg "cyan" "[Install] Downloading PR payload: $payload_name"

    queue_file="/tmp/nautilus_install_queue_$$"
    download_count=0
    download_errors=0
    api_failed=0

    echo "$download_folder|" > "$queue_file"

    while [ -s "$queue_file" ]; do
        read -r queue_entry < "$queue_file"
        sed -i '1d' "$queue_file" 2>/dev/null || { tail -n +2 "$queue_file" > "$queue_file.tmp" && mv "$queue_file.tmp" "$queue_file"; }

        api_path="${queue_entry%%|*}"
        rel_path="${queue_entry#*|}"

        [ -z "$api_path" ] && continue

        local_dir="$INSTALL_DIR"
        [ -n "$rel_path" ] && local_dir="$INSTALL_DIR/$rel_path"
        mkdir -p "$local_dir"

        api_url="https://api.github.com/repos/${full_repo}/contents/${api_path}?ref=${commit_sha}"
        json=""
        if command -v curl >/dev/null 2>&1; then
            json=$(curl -sf "$api_url" 2>/dev/null)
        elif command -v wget >/dev/null 2>&1; then
            json=$(wget -qO- "$api_url" 2>/dev/null)
        fi

        if [ -z "$json" ]; then
            api_failed=1
            break
        fi

        entries_file="/tmp/nautilus_install_entries_$$"

        echo "$json" | sed 's/},/}\n/g' | while IFS= read -r obj; do
            n=$(echo "$obj" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            t=$(echo "$obj" | sed -n 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            [ -n "$n" ] && echo "$n|$t"
        done > "$entries_file"

        while IFS='|' read -r name type; do
            [ -z "$name" ] && continue

            if [ "$type" = "dir" ]; then
                if [ -n "$rel_path" ]; then
                    echo "$api_path/$name|$rel_path/$name" >> "$queue_file"
                else
                    echo "$api_path/$name|$name" >> "$queue_file"
                fi
                sse_msg "cyan" "[Install] Scanning: $name/"
            elif [ "$type" = "file" ]; then
                file_url="https://raw.githubusercontent.com/${full_repo}/${commit_sha}/${api_path}/${name}"
                dl_ok=0
                if command -v curl >/dev/null 2>&1; then
                    curl -sf -o "$local_dir/$name" "$file_url" 2>/dev/null && dl_ok=1
                elif command -v wget >/dev/null 2>&1; then
                    wget -q -O "$local_dir/$name" "$file_url" 2>/dev/null && dl_ok=1
                fi
                if [ "$dl_ok" = "1" ]; then
                    download_count=$((download_count + 1))
                    disp_name="$name"
                    [ -n "$rel_path" ] && disp_name="$rel_path/$name"
                    sse_msg "green" "[Install] Downloaded: $disp_name"
                else
                    download_errors=$((download_errors + 1))
                    sse_msg "red" "[Install] Failed: $name"
                fi
            else
                file_url="https://raw.githubusercontent.com/${full_repo}/${commit_sha}/${api_path}/${name}"
                dl_ok=0
                if command -v curl >/dev/null 2>&1; then
                    curl -sf -o "$local_dir/$name" "$file_url" 2>/dev/null && dl_ok=1
                elif command -v wget >/dev/null 2>&1; then
                    wget -q -O "$local_dir/$name" "$file_url" 2>/dev/null && dl_ok=1
                fi
                if [ "$dl_ok" = "1" ]; then
                    download_count=$((download_count + 1))
                    sse_msg "green" "[Install] Downloaded: $name"
                else
                    if [ -n "$rel_path" ]; then
                        echo "$api_path/$name|$rel_path/$name" >> "$queue_file"
                    else
                        echo "$api_path/$name|$name" >> "$queue_file"
                    fi
                    sse_msg "cyan" "[Install] Scanning: $name/"
                fi
            fi
        done < "$entries_file"
        rm -f "$entries_file"
    done
    rm -f "$queue_file"

    if [ "$api_failed" = "1" ] && [ "$download_count" = "0" ]; then
        sse_msg "yellow" "[Install] API unavailable, downloading payload.sh only..."
        dl_ok=0
        if command -v wget >/dev/null 2>&1; then
            wget -q -O "$INSTALL_DIR/payload.sh" "$github_url" 2>/dev/null && dl_ok=1
        fi
        if [ "$dl_ok" != "1" ] && command -v curl >/dev/null 2>&1; then
            curl -sf -o "$INSTALL_DIR/payload.sh" "$github_url" 2>/dev/null && dl_ok=1
        fi
        if [ "$dl_ok" = "1" ]; then
            download_count=1
            sse_msg "green" "[Install] Downloaded: payload.sh"
        else
            sse_msg "red" "[Install] Failed to download payload.sh"
            printf 'event: done\ndata: {"status":"error","message":"Download failed"}\n\n'
            rm -rf "$INSTALL_DIR"
            rm -f /tmp/nautilus_install_target
            exit 1
        fi
    fi

    if [ ! -f "$INSTALL_DIR/payload.sh" ]; then
        sse_msg "red" "[Install] payload.sh not found in downloaded files"
        printf 'event: done\ndata: {"status":"error","message":"payload.sh not found"}\n\n'
        rm -rf "$INSTALL_DIR"
        rm -f /tmp/nautilus_install_target
        exit 1
    fi

    sse_msg "cyan" "[Install] Installing to $target_path..."
    mkdir -p "$(dirname "$target_path")"
    mv "$INSTALL_DIR" "$target_path"
    chmod +x "$target_path/payload.sh"

    rm -f /tmp/nautilus_install_target

    sse_msg "green" "[Install] Successfully installed $payload_name from PR!"
    sse_msg "cyan" "[Install] Location: $target_path"
    sse_msg "cyan" "[Install] Files: $download_count downloaded, $download_errors errors"

    /root/payloads/user/remote_access/nautilus/build_cache.sh >/dev/null 2>&1

    printf 'event: done\ndata: {"status":"success","path":"%s","name":"%s"}\n\n' "$target_path" "$payload_name"
}

run_github() {
    github_url="$1"
    token="$2"

    if ! validate_token "$token"; then
        echo "Content-Type: text/plain"
        echo ""
        echo "CSRF protection: Invalid or missing token. Refresh and try again."
        exit 1
    fi

    case "$github_url" in
        https://raw.githubusercontent.com/*/wifipineapplepager-payloads/*/payload.sh)
            ;;
        *)
            echo "Content-Type: text/plain"
            echo ""
            echo "Security: Only wifipineapplepager-payloads repos allowed"
            exit 1
            ;;
    esac

    case "$github_url" in
        *..* | *%2e%2e* | *%2E%2E* | *%2e%2E* | *%2E%2e*)
            echo "Content-Type: text/plain"
            echo ""
            echo "Security: Path traversal not allowed"
            exit 1
            ;;
    esac

    [ -f "$PID_FILE" ] && { kill $(cat "$PID_FILE") 2>/dev/null; rm -f "$PID_FILE"; }

    url_path="${github_url#https://raw.githubusercontent.com/}"
    repo_owner="${url_path%%/*}"
    url_path="${url_path#*/wifipineapplepager-payloads/}"
    branch="${url_path%%/*}"
    folder_path="${url_path#*/}"
    folder_path="${folder_path%/payload.sh}"
    full_repo="${repo_owner}/wifipineapplepager-payloads"

    payload_folder_name="${folder_path##*/}"

    GITHUB_DIR="/tmp/nautilus_github_$$"
    mkdir -p "$GITHUB_DIR"

    echo "Content-Type: text/event-stream"
    echo "Cache-Control: no-cache"
    echo ""

    sse_msg() {
        local color="$1"
        local text="$2"
        local escaped=$(printf '%s' "$text" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')
        printf 'data: {"text":"[%s] %s","color":"%s"}\n\n' "$color" "$escaped" "$color"
    }

    download_folder="$folder_path"
    sse_msg "cyan" "[GitHub] Fetching payload: $download_folder/"

    queue_file="/tmp/nautilus_queue_$$"
    download_count=0
    download_errors=0
    api_failed=0

    echo "$download_folder|" > "$queue_file"

    while [ -s "$queue_file" ]; do
        read -r queue_entry < "$queue_file"
        sed -i '1d' "$queue_file" 2>/dev/null || tail -n +2 "$queue_file" > "$queue_file.tmp" && mv "$queue_file.tmp" "$queue_file"

        api_path="${queue_entry%%|*}"
        rel_path="${queue_entry#*|}"

        [ -z "$api_path" ] && continue

        local_dir="$GITHUB_DIR"
        [ -n "$rel_path" ] && local_dir="$GITHUB_DIR/$rel_path"
        mkdir -p "$local_dir"

        api_url="https://api.github.com/repos/${full_repo}/contents/${api_path}?ref=${branch}"
        json=""
        if command -v curl >/dev/null 2>&1; then
            json=$(curl -sf "$api_url" 2>/dev/null)
        elif command -v wget >/dev/null 2>&1; then
            json=$(wget -qO- "$api_url" 2>/dev/null)
        fi

        if [ -z "$json" ]; then
            api_failed=1
            break
        fi

        entries_file="/tmp/nautilus_entries_$$"

        echo "$json" | sed 's/},/}\n/g' | while IFS= read -r obj; do
            n=$(echo "$obj" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            t=$(echo "$obj" | sed -n 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            [ -n "$n" ] && echo "$n|$t"
        done > "$entries_file"

        while IFS='|' read -r name type; do
            [ -z "$name" ] && continue

            if [ "$type" = "dir" ]; then
                if [ -n "$rel_path" ]; then
                    echo "$api_path/$name|$rel_path/$name" >> "$queue_file"
                else
                    echo "$api_path/$name|$name" >> "$queue_file"
                fi
                sse_msg "cyan" "[GitHub] Scanning: $name/"
            elif [ "$type" = "file" ]; then
                file_url="https://raw.githubusercontent.com/${full_repo}/${branch}/${api_path}/${name}"
                dl_ok=0
                if command -v curl >/dev/null 2>&1; then
                    curl -sf -o "$local_dir/$name" "$file_url" 2>/dev/null && dl_ok=1
                elif command -v wget >/dev/null 2>&1; then
                    wget -q -O "$local_dir/$name" "$file_url" 2>/dev/null && dl_ok=1
                fi
                if [ "$dl_ok" = "1" ]; then
                    download_count=$((download_count + 1))
                    disp_name="$name"
                    [ -n "$rel_path" ] && disp_name="$rel_path/$name"
                    sse_msg "green" "[GitHub] Downloaded: $disp_name"
                else
                    download_errors=$((download_errors + 1))
                    sse_msg "red" "[GitHub] Failed: $name"
                fi
            else
                file_url="https://raw.githubusercontent.com/${full_repo}/${branch}/${api_path}/${name}"
                dl_ok=0
                if command -v curl >/dev/null 2>&1; then
                    curl -sf -o "$local_dir/$name" "$file_url" 2>/dev/null && dl_ok=1
                elif command -v wget >/dev/null 2>&1; then
                    wget -q -O "$local_dir/$name" "$file_url" 2>/dev/null && dl_ok=1
                fi
                if [ "$dl_ok" = "1" ]; then
                    download_count=$((download_count + 1))
                    sse_msg "green" "[GitHub] Downloaded: $name"
                else
                    if [ -n "$rel_path" ]; then
                        echo "$api_path/$name|$rel_path/$name" >> "$queue_file"
                    else
                        echo "$api_path/$name|$name" >> "$queue_file"
                    fi
                    sse_msg "cyan" "[GitHub] Scanning: $name/"
                fi
            fi
        done < "$entries_file"
        rm -f "$entries_file"
    done
    rm -f "$queue_file"

    if [ "$api_failed" = "1" ] && [ "$download_count" = "0" ]; then
        sse_msg "yellow" "[GitHub] API unavailable, downloading payload.sh only..."
        dl_ok=0
        if command -v wget >/dev/null 2>&1; then
            wget -q -O "$GITHUB_DIR/payload.sh" "$github_url" 2>/dev/null && dl_ok=1
        fi
        if [ "$dl_ok" != "1" ] && command -v curl >/dev/null 2>&1; then
            curl -sf -o "$GITHUB_DIR/payload.sh" "$github_url" 2>/dev/null && dl_ok=1
        fi
        if [ "$dl_ok" = "1" ]; then
            download_count=1
            sse_msg "green" "[GitHub] Downloaded: payload.sh"
        else
            sse_msg "red" "[GitHub] Failed to download payload.sh"
            printf 'event: done\ndata: {"status":"error"}\n\n'
            rm -rf "$GITHUB_DIR"
            exit 1
        fi
    fi

    sse_msg "cyan" "[GitHub] Download complete: $download_count files, $download_errors errors"

    GITHUB_PAYLOAD="$GITHUB_DIR/payload.sh"

    if [ ! -f "$GITHUB_PAYLOAD" ]; then
        sse_msg "red" "[GitHub] payload.sh not found in downloaded files"
        printf 'event: done\ndata: {"status":"error"}\n\n'
        rm -rf "$GITHUB_DIR"
        exit 1
    fi
    chmod +x "$GITHUB_PAYLOAD"

    sse_msg "cyan" "[GitHub] Starting payload execution..."

    WRAPPER="/tmp/nautilus_wrapper_$$.sh"
    cat > "$WRAPPER" << 'WRAPPER_EOF'
#!/bin/bash

_nautilus_emit() {
    local color="$1"
    shift
    local text="$*"
    if [ -n "$color" ]; then
        echo "[${color}] ${text}"
    else
        echo "$text"
    fi
}

LOG() {
    local color=""
    if [ "$#" -gt 1 ]; then
        color="$1"
        shift
    fi
    _nautilus_emit "$color" "$@"
    /usr/bin/LOG ${color:+"$color"} "$@" 2>/dev/null || true
}

ALERT() {
    echo "[PROMPT:alert] $*" >&2
    sleep 0.1
    _wait_response ""
}

ERROR_DIALOG() {
    echo "[PROMPT:error] $*" >&2
    sleep 0.1
    _wait_response ""
}

SPINNER() {
    echo "[SPINNER:start] $*" >&2
}

SPINNER_STOP() {
    echo "[SPINNER:stop]" >&2
}

START_SPINNER() {
    local msg="$1"
    local id="nautilus_$$_$RANDOM"
    echo "[SPINNER:start:$id] $msg" >&2
    echo "$id"
}

STOP_SPINNER() {
    local id="$1"
    echo "[SPINNER:stop:$id]" >&2
}

LED() {
    _nautilus_emit "magenta" "[LED] $*"
    /usr/bin/LED "$@" 2>/dev/null || true
}

_wait_response() {
    local default="$1"
    rm -f /tmp/nautilus_response
    local timeout=300
    while [ $timeout -gt 0 ]; do
        if [ -f /tmp/nautilus_response ]; then
            cat /tmp/nautilus_response
            rm -f /tmp/nautilus_response
            return 0
        fi
        sleep 0.2
        timeout=$((timeout - 1))
    done
    echo "$default"
}

CONFIRMATION_DIALOG() {
    echo "[PROMPT:confirm] $1" >&2
    sleep 0.1
    _wait_response "0"
}

TEXT_PICKER() {
    local title="$1"
    local default="$2"
    echo "[PROMPT:text:$default] $title" >&2
    sleep 0.1
    _wait_response "$default"
}

NUMBER_PICKER() {
    local title="$1"
    local default="$2"
    echo "[PROMPT:number:$default] $title" >&2
    sleep 0.1
    _wait_response "$default"
}

IP_PICKER() {
    local title="$1"
    local default="$2"
    echo "[PROMPT:ip:$default] $title" >&2
    sleep 0.1
    _wait_response "$default"
}

MAC_PICKER() {
    local title="$1"
    local default="$2"
    echo "[PROMPT:mac:$default] $title" >&2
    sleep 0.1
    _wait_response "$default"
}

PROMPT() {
    echo "[PROMPT:prompt] $1" >&2
    sleep 0.1
    _wait_response ""
}

WAIT_FOR_INPUT() {
    echo "[BUTTON_WAIT:ANY]" >&2
    sleep 0.1
    local btn=$(_wait_response "A")
    echo -n "$btn"
}

WAIT_FOR_BUTTON_PRESS() {
    local expected="$*"
    echo "[BUTTON_WAIT:$expected]" >&2
    sleep 0.1
    local btn=$(_wait_response "${1:-A}")
    echo -n "$btn"
}

export -f LOG LED ALERT ERROR_DIALOG SPINNER SPINNER_STOP START_SPINNER STOP_SPINNER
export -f CONFIRMATION_DIALOG TEXT_PICKER NUMBER_PICKER IP_PICKER MAC_PICKER PROMPT
export -f WAIT_FOR_INPUT WAIT_FOR_BUTTON_PRESS
export -f _nautilus_emit _wait_response

echo "[cyan] [GitHub] Running payload..."
cd "$(dirname "$1")"
source "$1"
echo "[green] [GitHub] Payload complete"
WRAPPER_EOF

    chmod +x "$WRAPPER"

    LOG_FILE="/tmp/nautilus_github_log_$$.txt"
    rm -f "$LOG_FILE"
    touch "$LOG_FILE"

    /bin/bash "$WRAPPER" "$GITHUB_PAYLOAD" >> "$LOG_FILE" 2>&1 &

    echo $! > "$PID_FILE"

    send_log_lines() {
        current_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$current_lines" -gt "$sent_lines" ]; then
            tail -n +$((sent_lines + 1)) "$LOG_FILE" | head -n $((current_lines - sent_lines)) | while IFS= read -r line; do
                escaped=$(printf '%s' "$line" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')
                case "$line" in
                    "[PROMPT:"*)
                        inner="${line#\[PROMPT:}"
                        type="${inner%%\]*}"
                        msg="${inner#*\] }"
                        if echo "$type" | grep -q ':'; then
                            default="${type#*:}"
                            type="${type%%:*}"
                        else
                            default=""
                        fi
                        escaped_msg=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
                        escaped_def=$(printf '%s' "$default" | sed 's/\\/\\\\/g; s/"/\\"/g')
                        printf 'event: prompt\ndata: {"type":"%s","message":"%s","default":"%s"}\n\n' "$type" "$escaped_msg" "$escaped_def"
                        continue ;;
                    "[SPINNER:start"*)
                        inner="${line#\[SPINNER:start}"
                        if [ "${inner:0:1}" = ":" ]; then
                            inner="${inner:1}"
                            spinner_id="${inner%%\]*}"
                            spinner_msg="${inner#*\] }"
                        else
                            spinner_id=""
                            spinner_msg="${inner#\] }"
                        fi
                        escaped_msg=$(printf '%s' "$spinner_msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
                        printf 'event: spinner\ndata: {"action":"start","id":"%s","message":"%s"}\n\n' "$spinner_id" "$escaped_msg"
                        continue ;;
                    "[SPINNER:stop"*)
                        inner="${line#\[SPINNER:stop}"
                        if [ "${inner:0:1}" = ":" ]; then
                            spinner_id="${inner:1}"
                            spinner_id="${spinner_id%%\]*}"
                        else
                            spinner_id=""
                        fi
                        printf 'event: spinner\ndata: {"action":"stop","id":"%s"}\n\n' "$spinner_id"
                        continue ;;
                    "[BUTTON_WAIT:"*)
                        inner="${line#\[BUTTON_WAIT:}"
                        expected="${inner%%\]*}"
                        printf 'event: button_wait\ndata: {"expected":"%s"}\n\n' "$expected"
                        continue ;;
                esac
                color=""
                case "$line" in
                    "[red]"*) color="red" ;;
                    "[green]"*) color="green" ;;
                    "[yellow]"*) color="yellow" ;;
                    "[cyan]"*) color="cyan" ;;
                    "[blue]"*) color="blue" ;;
                    "[magenta]"*) color="magenta" ;;
                esac
                if [ -n "$color" ]; then
                    printf 'data: {"text":"%s","color":"%s"}\n\n' "$escaped" "$color"
                else
                    printf 'data: {"text":"%s"}\n\n' "$escaped"
                fi
            done
            sent_lines=$current_lines
        fi
    }

    sent_lines=0
    while [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; do
        send_log_lines
        sleep 0.2
    done

    sleep 0.1
    send_log_lines

    printf 'event: done\ndata: {"status":"complete"}\n\n'
    rm -f "$WRAPPER" "$PID_FILE" "$LOG_FILE"
    rm -rf "$GITHUB_DIR"
}

get_config() {
    local key="$1"
    if [ -z "$key" ]; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"error":"Missing key parameter"}'
        return
    fi
    local value=$(PAYLOAD_GET_CONFIG nautilus "$key" 2>/dev/null)
    echo "Content-Type: application/json"
    echo ""
    if [ -n "$value" ]; then
        printf '{"key":"%s","value":"%s"}\n' "$key" "$value"
    else
        printf '{"key":"%s","value":null}\n' "$key"
    fi
}

set_config() {
    local key="$1"
    local value="$2"
    if [ -z "$key" ]; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"error":"Missing key parameter"}'
        return
    fi
    PAYLOAD_SET_CONFIG nautilus "$key" "$value" 2>/dev/null
    local rc=$?
    echo "Content-Type: application/json"
    echo ""
    if [ $rc -eq 0 ]; then
        printf '{"success":true,"key":"%s","value":"%s"}\n' "$key" "$value"
    else
        echo '{"error":"Failed to save config"}'
    fi
}

get_favourites() {
    local value=$(PAYLOAD_GET_CONFIG nautilus "favourites" 2>/dev/null)
    echo "Content-Type: application/json"
    echo ""
    if [ -n "$value" ]; then
        printf '{"success":true,"favourites":%s}\n' "$value"
    else
        echo '{"success":true,"favourites":[]}'
    fi
}

set_favourites() {
    local json_data
    if [ "$REQUEST_METHOD" = "POST" ]; then
        json_data=$(cat)
    fi
    local favourites=$(echo "$json_data" | jsonfilter -e '@.favourites' 2>/dev/null)
    if [ -z "$favourites" ]; then
        favourites="[]"
    fi
    PAYLOAD_SET_CONFIG nautilus "favourites" "$favourites" 2>/dev/null
    local rc=$?
    echo "Content-Type: application/json"
    echo ""
    if [ $rc -eq 0 ]; then
        echo '{"success":true}'
    else
        echo '{"error":"Failed to save favourites"}'
    fi
}

del_config() {
    local key="$1"
    if [ -z "$key" ]; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"error":"Missing key parameter"}'
        return
    fi
    PAYLOAD_DEL_CONFIG nautilus "$key" 2>/dev/null
    echo "Content-Type: application/json"
    echo ""
    printf '{"success":true,"key":"%s"}\n' "$key"
}

action=""
rpath=""
response=""
token=""
nonce=""
data=""
github_url=""
github_path=""
force=""
pr_path=""
wifi_ssid=""
wifi_password=""
wifi_encryption=""
wifi_bssid=""
wifi_enable=""
config_key=""
config_value=""
IFS='&'
for param in $QUERY_STRING; do
    key="${param%%=*}"
    val="${param#*=}"
    case "$key" in
        action) action="$val" ;;
        path) rpath=$(urldecode "$val") ;;
        response) response=$(urldecode "$val") ;;
        token) token=$(urldecode "$val") ;;
        nonce) nonce=$(urldecode "$val") ;;
        data) data=$(urldecode "$val") ;;
        github_url) github_url=$(urldecode "$val") ;;
        github_path) github_path=$(urldecode "$val") ;;
        force) force=$(urldecode "$val") ;;
        pr_path) pr_path=$(urldecode "$val") ;;
        ssid) wifi_ssid=$(urldecode "$val") ;;
        password) wifi_password=$(urldecode "$val") ;;
        encryption) wifi_encryption=$(urldecode "$val") ;;
        bssid) wifi_bssid=$(urldecode "$val") ;;
        enable) wifi_enable=$(urldecode "$val") ;;
        key) config_key=$(urldecode "$val") ;;
        value) config_value=$(urldecode "$val") ;;
    esac
done
unset IFS

case "$action" in
    challenge|auth|check_session) ;;
    run|run_github|install_github|install_pr|wifi_scan|wifi_connect) ;;
    *)
        csrf_check "$action"
        require_auth
        ;;
esac

case "$action" in
    challenge) generate_challenge ;;
    auth) verify_auth "$nonce" "$data" ;;
    check_session)
        if check_session; then
            echo "Content-Type: application/json"
            echo ""
            echo '{"authenticated":true}'
        else
            echo "Content-Type: application/json"
            echo ""
            echo '{"authenticated":false}'
        fi
        ;;
    list) require_auth; list_payloads ;;
    token) require_auth; generate_token ;;
    run) require_auth; run_payload "$rpath" "$token" ;;
    run_github) require_auth; run_github "$github_url" "$token" ;;
    install_github) require_auth; install_github "$github_url" "$token" "$force" ;;
    install_pr) require_auth; install_pr "$github_url" "$token" "$force" "$pr_path" ;;
    check_local) require_auth; check_local_exists "$github_path" ;;
    stop) require_auth; stop_payload ;;
    delete_payload) require_auth; delete_payload "$rpath" ;;
    view_source) require_auth; view_source "$rpath" ;;
    respond) require_auth; respond "$response" ;;
    refresh) require_auth; /root/payloads/user/remote_access/nautilus/build_cache.sh; echo "Content-Type: application/json"; echo ""; echo '{"status":"refreshed"}' ;;
    wifi_status) require_auth; wifi_status ;;
    wifi_scan) require_auth; wifi_scan ;;
    wifi_connect) require_auth; wifi_connect "$wifi_ssid" "$wifi_password" "$wifi_encryption" "$wifi_bssid" ;;
    wifi_disconnect) require_auth; wifi_disconnect ;;
    wifi_toggle) require_auth; wifi_toggle_client_mode "$wifi_enable" ;;
    get_config) require_auth; get_config "$config_key" ;;
    set_config) require_auth; set_config "$config_key" "$config_value" ;;
    del_config) require_auth; del_config "$config_key" ;;
    get_favourites) require_auth; get_favourites ;;
    set_favourites) require_auth; set_favourites ;;
    *) echo "Content-Type: application/json"; echo ""; echo '{"error":"Unknown action"}' ;;
esac

