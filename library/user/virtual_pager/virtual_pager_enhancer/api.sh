#!/bin/bash
echo "Access-Control-Allow-Origin: *"


# This value will be set dynamically by payload.sh
PAYLOAD_WORKING_DIR=""

CONFIG_PATH="$PAYLOAD_WORKING_DIR/config"
IMG_FOLDER="$PAYLOAD_WORKING_DIR/img"
SKINNER_CONFIG_FILE="$CONFIG_PATH/skinnerconfig.json"

mkdir -p "$CONFIG_PATH"
if [ ! -f "$SKINNER_CONFIG_FILE" ]; then
    echo "{}" > "$SKINNER_CONFIG_FILE"
fi

url_decode() {
    local encoded="$1"
    printf '%b' "${encoded//%/\\x}" | sed 's/+/ /g'
}

update_payloads(){

    local TEMP_DIR="/tmp/payload_update"
    local PAYLOADS_URL="https://github.com/hak5/wifipineapplepager-payloads/archive/refs/heads/master.zip"

    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"

    if ! command -v unzip >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1
        opkg install unzip || { 
            echo "Content-Type: application/json"
            echo ""
            echo '{"okay":false,"error":"Failed To Install Unzip"}'
            exit 0; 
        }
    fi

    if ! wget -q --no-check-certificate "$PAYLOADS_URL" -O "$TEMP_DIR/master.zip"; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"okay":false,"error":"Failed To Download Payloads"}'
        exit 0
    fi

    unzip -q "$TEMP_DIR/master.zip" -d "$TEMP_DIR" >/dev/null 2>&1

    local UNPACKED_PAYLOAD_DIR="$TEMP_DIR/wifipineapplepager-payloads-master/library"
    local PAYLOAD_DIR="/mmc/root/payloads/"


    if [ -d "$PAYLOAD_DIR" ]; then
        cp -rf "$UNPACKED_PAYLOAD_DIR/." "$PAYLOAD_DIR/" 2>/dev/null
        echo "Content-Type: application/json"
        echo ""
        echo '{"okay":true,"message":"Updated Successfully"}'
    else
        echo "Content-Type: application/json"
        echo ""
        echo '{"okay":false,"error":"Could Not Unzip Payloads"}'
    fi

    rm -rf "$TEMP_DIR"
}

check_authentication() {
    local token="$1"
    local serverid="$2"
    local cookie_name="AUTH_$serverid"
    local cookie_value="$token"
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" -b "$cookie_name=$cookie_value" http://localhost:1471/api/api_ping)

    if [ "$status" -eq 200 ]; then
        return 0
    else
        echo "Content-Type: application/json"
        echo ""
        echo '{"status":"unauthorized"}'
        exit 0
    fi
}

get_system_info() {
    local disk_info
    disk_info=$(df -h | grep '^/dev/' | awk '{printf "%s %s %s %s, ", $1, $2, $3, $4}' | sed 's/, $//')
    
    local mem_info
    mem_info=$(free -h | grep "Mem:" | awk '{print "Total: "$2", Used: "$3", Free: "$4}')
    
    local cpu_load
    cpu_load=$(uptime | awk -F'load average:' '{ print $2 }' | sed 's/^ //')

    echo "Content-Type: application/json"
    echo ""
    echo "{"
    echo "  \"status\": \"ok\","
    echo "  \"data\": {"
    echo "    \"disk\": \"$disk_info\","
    echo "    \"memory\": \"$mem_info\","
    echo "    \"cpu_load\": \"$cpu_load\""
    echo "  }"
    echo "}"
}

run_command() {
    local cmd="$1"
    if [ -z "$cmd" ]; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"status":"no_command"}'
        return
    fi
    local output
    output=$(eval "$cmd" 2>&1)
    echo "Content-Type: application/json"
    echo ""
    echo "{\"status\":\"done\",\"output\":\"$(echo "$output" | sed 's/"/\\"/g' | tr -d '\n')\"}"
}

list_config() {
    echo "Content-Type: application/json"
    echo ""
    if [ ! -s "$SKINNER_CONFIG_FILE" ]; then
        echo '{"status":"empty_config","config":{}}'
    else
        echo -n "{\"status\":\"ok\",\"config\":"
        cat "$SKINNER_CONFIG_FILE"
        echo -n "}"
    fi
}

set_config() {
    local body
    body=$(cat)
    echo "Content-Type: application/json"
    echo ""
    if [ -z "$body" ]; then
        echo '{"status":"empty_body"}'
        return
    fi
    echo "$body" > "$SKINNER_CONFIG_FILE"
    echo '{"status":"ok","message":"config_updated"}'
}

get_image() {
    local filename="$1"
    if [[ "$filename" == *"/"* ]] || [[ -z "$filename" ]]; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"status":"invalid_filename"}'
        return
    fi
    local file_path="$IMG_FOLDER/$filename"
    if [ -f "$file_path" ]; then
        echo "Content-Type: image/$(echo "${filename##*.}" | tr '[:upper:]' '[:lower:]')"
        echo ""
        cat "$file_path"
        exit 0
    else
        echo "Content-Type: application/json"
        echo ""
        echo '{"status":"file_not_found"}'
    fi
}

for param in $(echo "$QUERY_STRING" | tr '&' ' '); do
    key=$(echo "$param" | cut -d= -f1)
    value=$(echo "$param" | cut -d= -f2-)
    value=$(url_decode "$value")
    case "$key" in
        token) TOKEN="$value" ;;
        serverid) SERVERID="$value" ;;
        action) ACTION="$value" ;;
        data) DATA="$value" ;;
    esac
done

AUTH_ACTIONS=("command" "setconfig" "systeminfo" "updatepayloads")
UNAUTH_ACTIONS=("listconfig" "getimage")

if [[ " ${AUTH_ACTIONS[*]} " =~ " $ACTION " ]]; then
    if [ -z "$TOKEN" ] || [ -z "$SERVERID" ]; then
        echo "Content-Type: application/json"
        echo ""
        echo '{"status":"missing_auth"}'
        exit 0
    fi
    check_authentication "$TOKEN" "$SERVERID"
fi

case "$ACTION" in
    command)
        run_command "$DATA"
        ;;
    listconfig)
        list_config
        ;;
    setconfig)
        set_config
        ;;
    systeminfo)
        get_system_info
        ;;
    getimage)
        get_image "$DATA"
        ;;
    updatepayloads)
        update_payloads
        ;;
    *)
        echo "Content-Type: application/json"
        echo ""
        echo '{"status":"unknown_action"}'
        ;;
esac