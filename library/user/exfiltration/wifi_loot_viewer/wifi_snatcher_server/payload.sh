#!/bin/bash

# Title: wifi_snatcher_server
# Author: f3bandit
# Description: First-run dependency bootstrap + local file server + menu control
# Version: 3.0

BASE_DIR="/mmc/root/payloads/user/exfiltration/wifi_loot_viewer"
DEPS_DIR="$BASE_DIR/deps"
SERVE_DIR="/mmc/root/scripts"
UPLOAD_DIR="/mmc/root/loot/wifi"

LOG_FILE="/tmp/webserver.log"
PID_FILE="/tmp/webserver.pid"
PY_FILE="/tmp/upload_server.py"
STATE_FILE="$BASE_DIR/.wifi_snatcher_bootstrap_done"
PORT_FILE="$BASE_DIR/.port"

PYTHON_BIN="/mmc/usr/bin/python3"
LIB_DIR_PRIMARY="/mmc/usr/lib"
LIB_DIR_FALLBACK="/mmc/lib"

DEFAULT_HTTP_PORT=42

LED SETUP
mkdir -p "$BASE_DIR" "$SERVE_DIR" "$UPLOAD_DIR"
: > "$LOG_FILE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

get_http_port() {
    local port
    if [ -f "$PORT_FILE" ]; then
        read -r port < "$PORT_FILE"
        case "$port" in
            ''|*[!0-9]*) echo "$DEFAULT_HTTP_PORT" ;;
            *)
                if [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                    echo "$port"
                else
                    echo "$DEFAULT_HTTP_PORT"
                fi
                ;;
        esac
    else
        echo "$DEFAULT_HTTP_PORT"
    fi
}

set_http_port() {
    echo "$1" > "$PORT_FILE"
}

get_current_ip() {
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [ -n "$ip" ]; then
        echo "$ip"
        return
    fi

    ip="$(ip addr 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {sub(/\/.*/, "", $2); print $2; exit}')"
    if [ -n "$ip" ]; then
        echo "$ip"
        return
    fi

    echo "172.16.52.1"
}

python_works() {
    export LD_LIBRARY_PATH="$LIB_DIR_PRIMARY:$LIB_DIR_FALLBACK:$LD_LIBRARY_PATH"
    "$PYTHON_BIN" --version >/dev/null 2>&1
}

install_deps_from_bundle() {
    log "Checking bundled dependencies in $DEPS_DIR"

    if [ ! -d "$DEPS_DIR" ]; then
        log "Deps directory not found: $DEPS_DIR"
        return 1
    fi

    mkdir -p "$LIB_DIR_PRIMARY" "$LIB_DIR_FALLBACK" "$(dirname "$PYTHON_BIN")"

    if [ -f "$DEPS_DIR/python3" ] && [ ! -f "$PYTHON_BIN" ]; then
        cp "$DEPS_DIR/python3" "$PYTHON_BIN" 2>>"$LOG_FILE"
        chmod 755 "$PYTHON_BIN"
        log "Installed bundled python3 to $PYTHON_BIN"
    fi

    if [ -f "$DEPS_DIR/libpython3.11.so.1.0" ] && [ ! -f "$LIB_DIR_PRIMARY/libpython3.11.so.1.0" ]; then
        cp "$DEPS_DIR/libpython3.11.so.1.0" "$LIB_DIR_PRIMARY/libpython3.11.so.1.0" 2>>"$LOG_FILE"
        chmod 644 "$LIB_DIR_PRIMARY/libpython3.11.so.1.0"
        log "Installed libpython3.11.so.1.0 to $LIB_DIR_PRIMARY"
    fi

    for sofile in "$DEPS_DIR"/*.so "$DEPS_DIR"/*.so.*; do
        [ -e "$sofile" ] || continue
        base="$(basename "$sofile")"
        if [ ! -f "$LIB_DIR_PRIMARY/$base" ]; then
            cp "$sofile" "$LIB_DIR_PRIMARY/$base" 2>>"$LOG_FILE"
            chmod 644 "$LIB_DIR_PRIMARY/$base"
            log "Installed shared library $base"
        fi
    done

    return 0
}

bootstrap_first_launch() {
    log "Starting dependency bootstrap"

    export LD_LIBRARY_PATH="$LIB_DIR_PRIMARY:$LIB_DIR_FALLBACK:$LD_LIBRARY_PATH"

    if python_works; then
        log "Python already working"
        touch "$STATE_FILE"
        return 0
    fi

    log "Python not working, attempting local dependency install"
    install_deps_from_bundle || log "Bundled dependency install did not complete cleanly"

    export LD_LIBRARY_PATH="$LIB_DIR_PRIMARY:$LIB_DIR_FALLBACK:$LD_LIBRARY_PATH"

    if python_works; then
        log "Python working after bootstrap"
        touch "$STATE_FILE"
        return 0
    fi

    log "Python still not working after bootstrap"
    return 1
}

write_python_server() {
    local HTTP_PORT
    HTTP_PORT="$(get_http_port)"

cat > "$PY_FILE" <<EOF
#!/usr/bin/env python3
import http.server
import socketserver
import os
import traceback
from datetime import datetime
from urllib.parse import unquote

UPLOAD_DIR = "${UPLOAD_DIR}"
SERVE_DIR = "${SERVE_DIR}"
LOG_FILE = "${LOG_FILE}"
PORT = ${HTTP_PORT}

os.makedirs(UPLOAD_DIR, exist_ok=True)
os.makedirs(SERVE_DIR, exist_ok=True)

def log(msg):
    with open(LOG_FILE, "a") as f:
        f.write(f"{datetime.now()}: {msg}\\n")

class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        log(fmt % args)

    def _send_text(self, text, code=200, content_type="text/plain; charset=utf-8"):
        data = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def _send_html(self, html, code=200):
        self._send_text(html, code, "text/html; charset=utf-8")

    def do_GET(self):
        try:
            if self.path == "/":
                items = []
                for f in sorted(os.listdir(SERVE_DIR)):
                    full = os.path.join(SERVE_DIR, f)
                    if os.path.isfile(full):
                        items.append(f'<li><a href="/files/{f}">{f}</a></li>')

                self._send_html(f"""<html>
<head><title>wifi snatcher server</title></head>
<body>
<h2>Theme Transfer Server</h2>
<p>Upload with HTTP POST to <code>/upload</code> using header <code>X-Filename</code>.</p>
<p>Downloads are available below.</p>
<p>Port: {PORT}</p>
<ul>{''.join(items)}</ul>
</body>
</html>""")
                return

            if self.path.startswith("/files/"):
                filename = os.path.basename(unquote(self.path[len("/files/"):]))
                filepath = os.path.join(SERVE_DIR, filename)

                if not os.path.isfile(filepath):
                    self._send_text("Not found\\n", 404)
                    return

                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
                self.send_header("Content-Length", str(os.path.getsize(filepath)))
                self.send_header("Connection", "close")
                self.end_headers()

                with open(filepath, "rb") as f:
                    while True:
                        chunk = f.read(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)

                log(f"Downloaded {filename}")
                return

            self._send_text("Not found\\n", 404)

        except Exception as e:
            log(f"GET error: {e}")
            log(traceback.format_exc())
            try:
                self._send_text("GET error\\n", 500)
            except:
                pass

    def do_POST(self):
        try:
            if self.path != "/upload":
                self._send_text("Not found\\n", 404)
                return

            filename = self.headers.get("X-Filename", "").strip()
            if not filename:
                self._send_text("Missing X-Filename header\\n", 400)
                return

            filename = os.path.basename(filename)

            cl = self.headers.get("Content-Length")
            if not cl:
                self._send_text("Missing Content-Length\\n", 411)
                return

            content_length = int(cl)
            if content_length < 0:
                self._send_text("Bad Content-Length\\n", 400)
                return

            filepath = os.path.join(UPLOAD_DIR, filename)

            remaining = content_length
            with open(filepath, "wb") as f:
                while remaining > 0:
                    chunk = self.rfile.read(min(65536, remaining))
                    if not chunk:
                        break
                    f.write(chunk)
                    remaining -= len(chunk)

            if remaining != 0:
                log(f"Upload incomplete for {filename}, {remaining} bytes missing")
                self._send_text("Incomplete upload\\n", 400)
                return

            log(f"Uploaded {filename} ({content_length} bytes)")
            self._send_text(f"Upload successful: {filename}\\n", 200)

        except Exception as e:
            log(f"POST error: {e}")
            log(traceback.format_exc())
            try:
                self._send_text("POST error\\n", 500)
            except:
                pass

if __name__ == "__main__":
    try:
        log(f"Starting Python HTTP server on port {PORT}")
        with ReusableTCPServer(("0.0.0.0", PORT), Handler) as httpd:
            log(f"Server running on port {PORT}")
            httpd.serve_forever()
    except Exception as e:
        log(f"Fatal server error: {e}")
        log(traceback.format_exc())
        raise
EOF

    chmod +x "$PY_FILE"
}

server_is_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

server_status() {
    if server_is_running; then
        echo "started"
    else
        echo "stopped"
    fi
}

start_python_server() {
    export LD_LIBRARY_PATH="$LIB_DIR_PRIMARY:$LIB_DIR_FALLBACK:$LD_LIBRARY_PATH"
    write_python_server
    "$PYTHON_BIN" "$PY_FILE" >>"$LOG_FILE" 2>&1 &
    SERVER_PID=$!
    echo "$SERVER_PID" > "$PID_FILE"
    sleep 2
    kill -0 "$SERVER_PID" 2>/dev/null
}

start_busybox_fallback() {
    local HTTP_PORT
    HTTP_PORT="$(get_http_port)"

    if have_cmd busybox; then
        log "Starting BusyBox fallback server on port $HTTP_PORT"
        busybox httpd -f -p "$HTTP_PORT" -h "$SERVE_DIR" >>"$LOG_FILE" 2>&1 &
        SERVER_PID=$!
        echo "$SERVER_PID" > "$PID_FILE"
        sleep 2
        kill -0 "$SERVER_PID" 2>/dev/null
        return $?
    fi
    return 1
}

start_server() {
    LED SOLID GREEN

    if [ ! -f "$STATE_FILE" ]; then
        log "First launch detected"
        bootstrap_first_launch
    else
        log "Bootstrap already completed previously"
    fi

    if server_is_running; then
        log "Server already running"
        return 0
    fi

    if python_works; then
        if start_python_server; then
            log "Python server started successfully"
            return 0
        else
            log "Python server failed to start"
        fi
    fi

    if start_busybox_fallback; then
        log "BusyBox fallback server started successfully"
        return 0
    fi

    LED OFF
    ERROR_DIALOG "Server failed to start

Check:
$LOG_FILE"
    return 1
}

stop_server() {
    local pid
    local http_port

    http_port="$(get_http_port)"

    if [ -f "$PID_FILE" ]; then
        pid="$(cat "$PID_FILE" 2>/dev/null)"
        kill "$pid" 2>/dev/null
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null
        fi
    fi

    if have_cmd fuser; then
        fuser -k "${http_port}/tcp" >/dev/null 2>&1
    fi

    rm -f "$PID_FILE" "$PY_FILE"
    LED OFF
    log "Server stopped"
    return 0
}

show_status_prompt() {
    local ip port status
    ip="$(get_current_ip)"
    port="$(get_http_port)"
    status="$(server_status)"

    PROMPT "Server status: $status

IP: $ip
Port: $port"
}

pick_new_port() {
    local current_port resp rc
    current_port="$(get_http_port)"

    resp=$(NUMBER_PICKER "Enter port number" "$current_port")
    rc=$?
    case $rc in
        $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
            return 1
            ;;
    esac

    printf "%s" "$resp"
    return 0
}

validate_port() {
    local port="$1"
    case "$port" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

change_port_menu() {
    local original_port working_port choice was_running=0

    original_port="$(get_http_port)"
    working_port="$original_port"

    while true; do
        choice=$(LIST_PICKER "Change Port" \
            "Save port ($working_port)" \
            "Edit port" \
            "Cancel" \
            "Edit port")

        case "$choice" in
            "Edit port")
                new_port="$(pick_new_port)" || continue
                if validate_port "$new_port"; then
                    working_port="$new_port"
                else
                    ERROR_DIALOG "Invalid port number"
                fi
                ;;
            "Save port ($working_port)")
                if ! validate_port "$working_port"; then
                    ERROR_DIALOG "Invalid port number"
                    continue
                fi

                if [ "$working_port" != "$original_port" ]; then
                    if server_is_running; then
                        was_running=1
                        stop_server
                    fi

                    set_http_port "$working_port"
                    log "Port changed to $working_port"

                    if [ "$was_running" -eq 1 ]; then
                        start_server
                    fi
                fi

                ip="$(get_current_ip)"
                port="$(get_http_port)"
                status="$(server_status)"
                PROMPT "Port updated

Server status: $status
IP: $ip
Port: $port"
                return 0
                ;;
            *)
                return 0
                ;;
        esac
    done
}

cleanup_and_exit() {
    stop_server
    exit 0
}

run_menu() {
    local port choice

    while true; do
        port="$(get_http_port)"
        choice=$(LIST_PICKER "Theme Transfer Server" \
            "Start server" \
            "Stop server" \
            "Change port ($port)" \
            "Exit" \
            "Start server")

        case "$choice" in
            "Start server")
                start_server
                show_status_prompt
                ;;
            "Stop server")
                stop_server
                show_status_prompt
                ;;
            "Change port ($port)")
                change_port_menu
                ;;
            *)
                cleanup_and_exit
                ;;
        esac
    done
}

if [ ! -f "$PORT_FILE" ]; then
    set_http_port "$DEFAULT_HTTP_PORT"
fi

run_menu
