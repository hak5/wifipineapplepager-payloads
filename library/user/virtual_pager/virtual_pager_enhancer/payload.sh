#!/bin/bash
# Title: Virtual Pager Enhancer
# Author: Rektile404
# Description: Tool used to add functionality to the virtual pager
# Version: 2.3.2

CONFIG_PATH="./config"
CONFIG_FILE="config.json"
PAYLOAD="./payload.js"
API_FILE="./api.sh"
IMAGE_OVERWRITE_DIR="./img_overwrite"

VIRTUAL_PAGER_DIR="/pineapple/ui"
BACKUP_VIRTUAL_PAGER_DIR="/rom/pineapple/ui"
IMG_DIR="images"
INDEX_FILE="index.html"


VIRTUAL_PAGER_ENHANCER_TAG="<!-- Virtual Pager Enhancer BEGIN -->"
VIRTUAL_PAGER_ENHANCER_END="<!-- Virtual Pager Enhancer END -->"

CURRENT_VERSION="2.3.2"
SERVER_PORT=4040
SERVICE_FILE="/etc/init.d/virtual_pager_enhancer_server"

# Absolute paths
SCRIPT_ABS_PATH="$(pwd)"
WWW_ABS_PATH="$SCRIPT_ABS_PATH/www"
CGI_ABS_PATH="$WWW_ABS_PATH/cgi-bin"

mkdir -p "$CONFIG_PATH"
mkdir -p "$WWW_ABS_PATH"
mkdir -p "$CGI_ABS_PATH"

# Prevent directory listing
echo "Nothing to see here :)" > "$WWW_ABS_PATH/index.html"

update() {
    LOG "Different version found. Upgrading..."

    if [ -f "$SERVICE_FILE" ]; then
        /etc/init.d/$(basename "$SERVICE_FILE") stop
        /etc/init.d/$(basename "$SERVICE_FILE") disable
    fi
    
    cp -rf "$BACKUP_VIRTUAL_PAGER_DIR/$IMG_DIR/." "$VIRTUAL_PAGER_DIR/$IMG_DIR/" 2>/dev/null
    cp -f "$BACKUP_VIRTUAL_PAGER_DIR/$INDEX_FILE" "$VIRTUAL_PAGER_DIR/$INDEX_FILE" 2>/dev/null
    echo "{\"version\":\"$CURRENT_VERSION\"}" > "$CONFIG_PATH/$CONFIG_FILE"
}

install_dependencies() {
    LOG "Checking dependencies..."
    if ! command -v uhttpd >/dev/null 2>&1; then
        LOG "Installing uhttpd..."
        opkg update >/dev/null 2>&1
        opkg install uhttpd || { LOG "Failed to install uhttpd"; exit 1; }
    fi
}

check_or_create_config() {
    local cfg="$CONFIG_PATH/$CONFIG_FILE"
    if [ ! -f "$cfg" ] || ! jq empty "$cfg" >/dev/null 2>&1 || ! jq -e '.version' "$cfg" >/dev/null 2>&1; then
        update
        return
    fi
    [ "$(jq -r '.version' "$cfg")" != "$CURRENT_VERSION" ] && update
}

is_enabled() {
    grep -q "$VIRTUAL_PAGER_ENHANCER_TAG" "$VIRTUAL_PAGER_DIR/$INDEX_FILE"
}

inject_payload() {
    is_enabled && return

    LOG "Injecting payload..."

    cp -rf "$IMAGE_OVERWRITE_DIR/." "$VIRTUAL_PAGER_DIR/$IMG_DIR/" 2>/dev/null

    sed -i "s|^PAYLOAD_WORKING_DIR=.*|PAYLOAD_WORKING_DIR=\"$SCRIPT_ABS_PATH\"|" "$API_FILE"

    local tmp
    tmp=$(mktemp)

    awk -v payload="$PAYLOAD" -v b="$VIRTUAL_PAGER_ENHANCER_TAG" -v e="$VIRTUAL_PAGER_ENHANCER_END" '
    /<head>/ {
        print
        print b "\n<script>"
        while ((getline l < payload) > 0) print l
        close(payload)
        print "</script>\n" e
        next
    } { print }
    ' "$VIRTUAL_PAGER_DIR/$INDEX_FILE" > "$tmp"

    mv "$tmp" "$VIRTUAL_PAGER_DIR/$INDEX_FILE"

    cat > "$SERVICE_FILE" << EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10

start() {
    cp -f "$SCRIPT_ABS_PATH/api.sh" "$CGI_ABS_PATH/api.sh"
    chmod 755 "$CGI_ABS_PATH/api.sh"
    uhttpd -f -p $SERVER_PORT -h "$WWW_ABS_PATH" -c "$CGI_ABS_PATH" -x /cgi-bin -T 60 &
}

stop() {
    PID=\$(ps | grep "uhttpd" | grep "\-p $SERVER_PORT" | grep -v grep | awk '{print \$1}')
    [ -n "\$PID" ] && kill -9 \$PID
}
EOF

    chmod +x "$SERVICE_FILE"
    /etc/init.d/$(basename "$SERVICE_FILE") enable
    /etc/init.d/$(basename "$SERVICE_FILE") start

    LOG "Payload injected and server started on port $SERVER_PORT."
}

remove_payload() {
    LOG "Removing payload..."

    cp -rf "$BACKUP_VIRTUAL_PAGER_DIR/$IMG_DIR/." "$VIRTUAL_PAGER_DIR/$IMG_DIR/" 2>/dev/null

    local tmp
    tmp=$(mktemp)

    awk -v b="$VIRTUAL_PAGER_ENHANCER_TAG" -v e="$VIRTUAL_PAGER_ENHANCER_END" '
    $0 ~ b {s=1;next} s && $0 ~ e {s=0;next} !s {print}
    ' "$VIRTUAL_PAGER_DIR/$INDEX_FILE" > "$tmp"

    mv "$tmp" "$VIRTUAL_PAGER_DIR/$INDEX_FILE"

    rm -f "$CGI_ABS_PATH/$(basename "$API_FILE")"

    [ -f "$SERVICE_FILE" ] && {
        /etc/init.d/$(basename "$SERVICE_FILE") stop
        /etc/init.d/$(basename "$SERVICE_FILE") disable
    }

    LOG "Payload removed and server stopped."
}

handle_menu() {
    LOG "=========================="
    if is_enabled; then
        LOG "Current state: ENABLED."
        LOG "Press 'A' to DISABLE!"
    else
        LOG "Current state: DISABLED."
        LOG "Press 'A' to ENABLE!"
    fi
    LOG "Press other to EXIT!"

    sleep 0.5
    BTN=$(WAIT_FOR_INPUT)
    [ "$BTN" != "A" ] && { LOG "Exiting..."; exit 0; }

    if is_enabled; then
        LOG "DISABLING..."
        remove_payload
    else
        LOG "ENABLING..."
        inject_payload
    fi
}

LOG "=========================="
LOG "Virtual Pager Enhancer"
LOG "By Rektile404"
LOG "=========================="

install_dependencies
check_or_create_config

LOG "=========================="

LOG "This script acts as a toggle to enable or disable Virtual Pager Enhancer."
LOG "The changes that are made are persistant, even after reboot."
LOG "Once you have enabled or disabled, feel free to stop the payload and HARD refresh your browser."



while true; do
    handle_menu
done