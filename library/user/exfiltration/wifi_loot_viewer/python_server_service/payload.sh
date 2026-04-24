#!/bin/bash

# ============================================================
# Name: python_server
# Author: f3bandit
# Version: 4.1
# ============================================================

SCRIPT_VERSION="4.1"

BASE_DIR="/mmc/root/payloads/user/exfiltration/python_server"
DEPS_DIR="$BASE_DIR/deps"
SERVE_DIR="/mmc/root/scripts"
UPLOAD_DIR="/mmc/root/loot/wifi"

LOG_FILE="/tmp/python_transfer_server.log"
PID_FILE="/tmp/python_transfer_server.pid"

PY_SERVER_FILE="$BASE_DIR/upload_server.py"
LAUNCHER_FILE="$BASE_DIR/python_transfer_server_launcher.sh"

BOOTSTRAP_VERSION_FILE="$BASE_DIR/.bootstrap_version"
SERVICE_INSTALL_STATE_FILE="$BASE_DIR/.service_installed"
PORT_FILE="$BASE_DIR/.port"

LEGACY_BOOTSTRAP_FILE="$BASE_DIR/.bootstrap_done"

SERVICE_NAME="python_transfer_server"
INIT_SCRIPT="/etc/init.d/$SERVICE_NAME"

PYTHON_BIN="/mmc/usr/bin/python3"
LIB_DIR_PRIMARY="/mmc/usr/lib"
LIB_DIR_FALLBACK="/mmc/lib"

DEFAULT_HTTP_PORT=42

log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
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

    echo "unknown"
}

server_is_running() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid="$(cat "$PID_FILE" 2>/dev/null)"
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
        return $?
    fi
    return 1
}

server_status() {
    if server_is_running; then
        echo "started"
    else
        echo "stopped"
    fi
}

build_status_message() {
    local status ip port prefix
    prefix="$1"

    status="$(server_status)"
    ip="$(get_current_ip)"
    port="$(get_http_port)"

    if [ -n "$prefix" ]; then
        printf "%s\n\nServer status: %s\nIP: %s\nPort: %s\n\nPress any button to continue" \
            "$prefix" "$status" "$ip" "$port"
    else
        printf "Server status: %s\nIP: %s\nPort: %s\n\nPress any button to continue" \
            "$status" "$ip" "$port"
    fi
}

show_prompt_message() {
    local msg="$1"

    if type PROMPT >/dev/null 2>&1; then
        PROMPT "$msg"
        return 0
    fi

    if type ALERT_DIALOG >/dev/null 2>&1; then
        ALERT_DIALOG "$msg"
        return 0
    fi

    if have_cmd whiptail; then
        whiptail --title "Python Transfer Server" --msgbox "$msg" 20 72
        return 0
    fi

    if have_cmd dialog; then
        dialog --title "Python Transfer Server" --msgbox "$msg" 20 72
        return 0
    fi

    echo "$msg"
    return 0
}

show_status_prompt() {
    local msg
    msg="$(build_status_message "$1")"
    show_prompt_message "$msg"
}

main_menu() {
    local current_port choice
    current_port="$(get_http_port)"

    if type LIST_PICKER >/dev/null 2>&1; then
        choice=$(LIST_PICKER "Python Transfer Server" \
            "Start server" \
            "Stop server" \
            "Server status" \
            "Change port ($current_port)" \
            "Debug" \
            "Exit" \
            "Start server")
        case "$choice" in
            "Start server") echo "start" ;;
            "Stop server") echo "stop" ;;
            "Server status") echo "status" ;;
            "Change port ($current_port)") echo "change_port" ;;
            "Debug") echo "debug" ;;
            *) echo "exit" ;;
        esac
        return
    fi

    if have_cmd whiptail; then
        choice=$(whiptail --title "Python Transfer Server" \
            --menu "Choose action:" 20 70 6 \
            "1" "Start server" \
            "2" "Stop server" \
            "3" "Server status" \
            "4" "Change port ($current_port)" \
            "5" "Debug" \
            "6" "Exit" \
            3>&1 1>&2 2>&3)
        case "$choice" in
            1) echo "start" ;;
            2) echo "stop" ;;
            3) echo "status" ;;
            4) echo "change_port" ;;
            5) echo "debug" ;;
            *) echo "exit" ;;
        esac
        return
    fi

    echo "1) Start server"
    echo "2) Stop server"
    echo "3) Server status"
    echo "4) Change port ($current_port)"
    echo "5) Debug"
    echo "6) Exit"
    printf "Choose: "
    read -r choice
    case "$choice" in
        1) echo "start" ;;
        2) echo "stop" ;;
        3) echo "status" ;;
        4) echo "change_port" ;;
        5) echo "debug" ;;
        *) echo "exit" ;;
    esac
}

debug_menu() {
    local choice
    if type LIST_PICKER >/dev/null 2>&1; then
        choice=$(LIST_PICKER "Debug Menu" \
            "Show debug status" \
            "Repair generated files" \
            "Reinstall service" \
            "Reset install state" \
            "Show last log lines" \
            "Back" \
            "Show debug status")
        case "$choice" in
            "Show debug status") echo "status" ;;
            "Repair generated files") echo "repair" ;;
            "Reinstall service") echo "reinstall_service" ;;
            "Reset install state") echo "reset_state" ;;
            "Show last log lines") echo "logs" ;;
            *) echo "back" ;;
        esac
        return
    fi

    if have_cmd whiptail; then
        choice=$(whiptail --title "Debug Menu" \
            --menu "Choose action:" 18 70 6 \
            "1" "Show debug status" \
            "2" "Repair generated files" \
            "3" "Reinstall service" \
            "4" "Reset install state" \
            "5" "Show last log lines" \
            "6" "Back" \
            3>&1 1>&2 2>&3)
        case "$choice" in
            1) echo "status" ;;
            2) echo "repair" ;;
            3) echo "reinstall_service" ;;
            4) echo "reset_state" ;;
            5) echo "logs" ;;
            *) echo "back" ;;
        esac
        return
    fi

    echo "back"
}

pick_port_with_number_picker() {
    local current_port resp rc
    current_port="$1"

    if type NUMBER_PICKER >/dev/null 2>&1; then
        resp=$(NUMBER_PICKER "Enter port number" "$current_port")
        rc=$?
        case $rc in
            $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                return 1
                ;;
        esac
        printf "%s" "$resp"
        return 0
    fi

    if have_cmd whiptail; then
        resp=$(whiptail --title "Change Port" --inputbox "Enter port number:" 10 50 "$current_port" 3>&1 1>&2 2>&3) || return 1
        printf "%s" "$resp"
        return 0
    fi

    return 1
}

port_action_menu() {
    local candidate="$1"
    local choice

    if type LIST_PICKER >/dev/null 2>&1; then
        choice=$(LIST_PICKER "Port $candidate" \
            "Save port $candidate" \
            "Edit port" \
            "Cancel" \
            "Save port $candidate")
        case "$choice" in
            "Save port $candidate") echo "save" ;;
            "Edit port") echo "edit" ;;
            *) echo "cancel" ;;
        esac
        return
    fi

    if have_cmd whiptail; then
        choice=$(whiptail --title "Port $candidate" \
            --menu "Choose action:" 14 60 3 \
            "1" "Save port $candidate" \
            "2" "Edit port" \
            "3" "Cancel" \
            3>&1 1>&2 2>&3)
        case "$choice" in
            1) echo "save" ;;
            2) echo "edit" ;;
            *) echo "cancel" ;;
        esac
        return
    fi

    echo "save"
}

validate_port() {
    local port="$1"
    case "$port" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

set_python_env() {
    export LD_LIBRARY_PATH="$LIB_DIR_PRIMARY:$LIB_DIR_FALLBACK:$LD_LIBRARY_PATH"
}

python_works() {
    set_python_env
    [ -x "$PYTHON_BIN" ] || return 1
    "$PYTHON_BIN" --version >/dev/null 2>&1
}

install_deps_from_bundle() {
    [ -d "$DEPS_DIR" ] || return 1

    mkdir -p "$(dirname "$PYTHON_BIN")" "$LIB_DIR_PRIMARY" "$LIB_DIR_FALLBACK"

    if [ -f "$DEPS_DIR/python3" ] && [ ! -x "$PYTHON_BIN" ]; then
        cp "$DEPS_DIR/python3" "$PYTHON_BIN" 2>/dev/null || return 1
        chmod 755 "$PYTHON_BIN"
    fi

    if [ -f "$DEPS_DIR/libpython3.11.so.1.0" ] && [ ! -f "$LIB_DIR_PRIMARY/libpython3.11.so.1.0" ]; then
        cp "$DEPS_DIR/libpython3.11.so.1.0" "$LIB_DIR_PRIMARY/libpython3.11.so.1.0" 2>/dev/null || return 1
        chmod 644 "$LIB_DIR_PRIMARY/libpython3.11.so.1.0"
    fi

    local sofile base
    for sofile in "$DEPS_DIR"/*.so "$DEPS_DIR"/*.so.*; do
        [ -e "$sofile" ] || continue
        base="$(basename "$sofile")"
        if [ ! -f "$LIB_DIR_PRIMARY/$base" ]; then
            cp "$sofile" "$LIB_DIR_PRIMARY/$base" 2>/dev/null || continue
            chmod 644 "$LIB_DIR_PRIMARY/$base"
        fi
    done

    return 0
}

current_bootstrap_version() {
    if [ -f "$BOOTSTRAP_VERSION_FILE" ]; then
        cat "$BOOTSTRAP_VERSION_FILE" 2>/dev/null
        return
    fi

    if [ -f "$LEGACY_BOOTSTRAP_FILE" ]; then
        echo "legacy"
        return
    fi

    echo "none"
}

bootstrap_needed() {
    local current
    current="$(current_bootstrap_version)"

    if [ "$current" = "$SCRIPT_VERSION" ]; then
        return 1
    fi

    return 0
}

mark_bootstrap_complete() {
    echo "$SCRIPT_VERSION" > "$BOOTSTRAP_VERSION_FILE"
    rm -f "$LEGACY_BOOTSTRAP_FILE"
}

write_python_server() {
    local HTTP_PORT
    HTTP_PORT="$(get_http_port)"

cat > "$PY_SERVER_FILE" <<EOF
#!/usr/bin/env python3
import http.server
import socketserver
import os
import traceback
from urllib.parse import unquote

UPLOAD_DIR = "${UPLOAD_DIR}"
SERVE_DIR = "${SERVE_DIR}"
LOG_FILE = "${LOG_FILE}"
PID_FILE = "${PID_FILE}"
PORT = ${HTTP_PORT}

os.makedirs(UPLOAD_DIR, exist_ok=True)
os.makedirs(SERVE_DIR, exist_ok=True)

def log(msg):
    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(msg + "\\n")

class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        log(fmt % args)

    def send_text(self, text, code=200, content_type="text/plain; charset=utf-8"):
        data = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def send_html(self, html, code=200):
        self.send_text(html, code, "text/html; charset=utf-8")

    def do_GET(self):
        try:
            if self.path == "/":
                items = []
                for name in sorted(os.listdir(SERVE_DIR)):
                    full = os.path.join(SERVE_DIR, name)
                    if os.path.isfile(full):
                        items.append(f'<li><a href="/files/{name}">{name}</a></li>')

                self.send_html(
                    "<html><head><title>Python Transfer Server</title></head>"
                    "<body><h2>Python Transfer Server</h2>"
                    f"<p>Port: {PORT}</p>"
                    "<p>Upload with POST to <code>/upload</code> and header <code>X-Filename</code>.</p>"
                    f"<ul>{''.join(items)}</ul>"
                    "</body></html>"
                )
                return

            if self.path.startswith("/files/"):
                filename = os.path.basename(unquote(self.path[len("/files/"):]))
                filepath = os.path.join(SERVE_DIR, filename)

                if not os.path.isfile(filepath):
                    self.send_text("Not found\\n", 404)
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
                return

            self.send_text("Not found\\n", 404)

        except Exception as e:
            log(f"GET error: {e}\\n{traceback.format_exc()}")
            try:
                self.send_text("Server error\\n", 500)
            except Exception:
                pass

    def do_POST(self):
        try:
            if self.path != "/upload":
                self.send_text("Not found\\n", 404)
                return

            filename = self.headers.get("X-Filename", "").strip()
            if not filename:
                self.send_text("Missing X-Filename header\\n", 400)
                return

            filename = os.path.basename(filename)
            content_length = self.headers.get("Content-Length")
            if not content_length:
                self.send_text("Missing Content-Length\\n", 411)
                return

            total = int(content_length)
            if total < 0:
                self.send_text("Bad Content-Length\\n", 400)
                return

            filepath = os.path.join(UPLOAD_DIR, filename)
            remaining = total

            with open(filepath, "wb") as f:
                while remaining > 0:
                    chunk = self.rfile.read(min(65536, remaining))
                    if not chunk:
                        break
                    f.write(chunk)
                    remaining -= len(chunk)

            if remaining != 0:
                self.send_text("Incomplete upload\\n", 400)
                return

            self.send_text(f"Upload successful: {filename}\\n", 200)

        except Exception as e:
            log(f"POST error: {e}\\n{traceback.format_exc()}")
            try:
                self.send_text("Server error\\n", 500)
            except Exception:
                pass

if __name__ == "__main__":
    with open(PID_FILE, "w", encoding="utf-8") as f:
        f.write(str(os.getpid()))
    try:
        with ReusableTCPServer(("0.0.0.0", PORT), Handler) as httpd:
            httpd.serve_forever()
    finally:
        try:
            if os.path.exists(PID_FILE):
                os.remove(PID_FILE)
        except Exception:
            pass
EOF

    chmod 755 "$PY_SERVER_FILE"
}

write_launcher_script() {
cat > "$LAUNCHER_FILE" <<EOF
#!/bin/sh
export LD_LIBRARY_PATH="${LIB_DIR_PRIMARY}:${LIB_DIR_FALLBACK}:\$LD_LIBRARY_PATH"
exec "${PYTHON_BIN}" "${PY_SERVER_FILE}" >> "${LOG_FILE}" 2>&1
EOF
    chmod 755 "$LAUNCHER_FILE"
}

write_init_script() {
cat > "$INIT_SCRIPT" <<EOF
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=0

NAME="${SERVICE_NAME}"
PID_FILE="${PID_FILE}"
LAUNCHER="${LAUNCHER_FILE}"

start() {
    if [ -f "\$PID_FILE" ] && kill -0 "\$(cat "\$PID_FILE" 2>/dev/null)" 2>/dev/null; then
        return 0
    fi

    "\$LAUNCHER" &
    sleep 1
}

stop() {
    if [ -f "\$PID_FILE" ]; then
        kill "\$(cat "\$PID_FILE" 2>/dev/null)" 2>/dev/null
        sleep 1
        if [ -f "\$PID_FILE" ] && kill -0 "\$(cat "\$PID_FILE" 2>/dev/null)" 2>/dev/null; then
            kill -9 "\$(cat "\$PID_FILE" 2>/dev/null)" 2>/dev/null
        fi
        rm -f "\$PID_FILE"
    fi

    if command -v fuser >/dev/null 2>&1; then
        fuser -k \$(cat "${PORT_FILE}" 2>/dev/null || echo "${DEFAULT_HTTP_PORT}")/tcp >/dev/null 2>&1
    fi
}
EOF

    chmod 755 "$INIT_SCRIPT"
}

validate_python_server_file() {
    [ -f "$PY_SERVER_FILE" ] || return 1

    if grep -q '^export LD_LIBRARY_PATH=' "$PY_SERVER_FILE" 2>/dev/null; then
        return 1
    fi

    if ! grep -q '^#!/usr/bin/env python3' "$PY_SERVER_FILE" 2>/dev/null; then
        return 1
    fi

    if ! grep -q '^import http.server' "$PY_SERVER_FILE" 2>/dev/null; then
        return 1
    fi

    if ! grep -q "PID_FILE = \"${PID_FILE}\"" "$PY_SERVER_FILE" 2>/dev/null; then
        return 1
    fi

    set_python_env
    "$PYTHON_BIN" -m py_compile "$PY_SERVER_FILE" >/dev/null 2>&1 || return 1

    return 0
}

validate_launcher_file() {
    [ -f "$LAUNCHER_FILE" ] || return 1
    grep -q "exec \"${PYTHON_BIN}\" \"${PY_SERVER_FILE}\"" "$LAUNCHER_FILE" 2>/dev/null || return 1
    return 0
}

validate_init_script() {
    [ -f "$INIT_SCRIPT" ] || return 1
    grep -q "PID_FILE=\"${PID_FILE}\"" "$INIT_SCRIPT" 2>/dev/null || return 1
    grep -q "LAUNCHER=\"${LAUNCHER_FILE}\"" "$INIT_SCRIPT" 2>/dev/null || return 1
    return 0
}

heal_generated_files() {
    if ! validate_python_server_file; then
        write_python_server
    fi

    if ! validate_launcher_file; then
        write_launcher_script
    fi

    if [ -d "/etc/init.d" ] && [ -w "/etc/init.d" ]; then
        if ! validate_init_script; then
            write_init_script
            "$INIT_SCRIPT" enable >/dev/null 2>&1
            touch "$SERVICE_INSTALL_STATE_FILE"
        fi
    fi
}

bootstrap_or_upgrade() {
    mkdir -p "$BASE_DIR" "$DEPS_DIR" "$SERVE_DIR" "$UPLOAD_DIR"

    if bootstrap_needed; then
        if ! python_works; then
            install_deps_from_bundle || return 1
        fi

        if ! python_works; then
            return 1
        fi

        write_python_server
        write_launcher_script
        install_service_if_possible || return 1
        mark_bootstrap_complete
        return 0
    fi

    heal_generated_files
    return 0
}

install_service_if_possible() {
    write_python_server
    write_launcher_script

    if [ ! -d "/etc/init.d" ] || [ ! -w "/etc/init.d" ]; then
        touch "$SERVICE_INSTALL_STATE_FILE"
        return 0
    fi

    write_init_script
    "$INIT_SCRIPT" enable >/dev/null 2>&1
    touch "$SERVICE_INSTALL_STATE_FILE"
    return 0
}

server_start_manual() {
    set_python_env
    write_python_server
    write_launcher_script

    if server_is_running; then
        return 0
    fi

    "$LAUNCHER_FILE" &
    sleep 2
    server_is_running
}

server_start() {
    mkdir -p "$BASE_DIR" "$DEPS_DIR" "$SERVE_DIR" "$UPLOAD_DIR"

    if server_is_running; then
        return 0
    fi

    bootstrap_or_upgrade || return 1
    heal_generated_files

    if [ -x "$INIT_SCRIPT" ]; then
        write_init_script
        "$INIT_SCRIPT" start >/dev/null 2>&1
        sleep 2
        if server_is_running; then
            return 0
        fi
    fi

    server_start_manual
}

server_stop() {
    local current_port pid
    current_port="$(get_http_port)"

    if [ -x "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" stop >/dev/null 2>&1
    fi

    if server_is_running; then
        pid="$(cat "$PID_FILE" 2>/dev/null)"
        kill "$pid" 2>/dev/null
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$PID_FILE"
    fi

    if have_cmd fuser; then
        fuser -k "${current_port}/tcp" >/dev/null 2>&1
    fi

    return 0
}

change_port() {
    local current_port candidate_port port_choice changed
    current_port="$(get_http_port)"
    candidate_port="$current_port"
    changed=0

    while true; do
        candidate_port="$(pick_port_with_number_picker "$candidate_port")" || return 0

        if ! validate_port "$candidate_port"; then
            show_prompt_message "Invalid port.\n\nEnter a value from 1 to 65535."
            continue
        fi

        port_choice="$(port_action_menu "$candidate_port")"

        case "$port_choice" in
            save)
                server_stop >/dev/null 2>&1
                set_http_port "$candidate_port"
                write_python_server
                write_launcher_script
                if [ -d "/etc/init.d" ] && [ -w "/etc/init.d" ]; then
                    write_init_script
                fi
                server_start >/dev/null 2>&1
                changed=1
                break
                ;;
            edit)
                continue
                ;;
            cancel|*)
                return 0
                ;;
        esac
    done

    if [ "$changed" -eq 1 ]; then
        show_status_prompt "Port updated"
    fi

    return 0
}

bool_text() {
    if [ "$1" = "1" ]; then
        echo "yes"
    else
        echo "no"
    fi
}

debug_status_message() {
    local bootstrap_ver bootstrap_ok service_ok pid_text port ip py_ok launcher_ok init_ok log_ok

    bootstrap_ver="$(current_bootstrap_version)"
    [ "$bootstrap_ver" != "none" ] && bootstrap_ok=1 || bootstrap_ok=0
    [ -f "$SERVICE_INSTALL_STATE_FILE" ] && service_ok=1 || service_ok=0

    if [ -f "$PID_FILE" ]; then
        pid_text="$(cat "$PID_FILE" 2>/dev/null)"
        [ -n "$pid_text" ] || pid_text="missing"
    else
        pid_text="missing"
    fi

    port="$(get_http_port)"
    ip="$(get_current_ip)"

    validate_python_server_file && py_ok=1 || py_ok=0
    validate_launcher_file && launcher_ok=1 || launcher_ok=0
    validate_init_script && init_ok=1 || init_ok=0
    [ -f "$LOG_FILE" ] && log_ok=1 || log_ok=0

    printf "Debug status\n\n"
    printf "Script version: %s\n" "$SCRIPT_VERSION"
    printf "Bootstrap version: %s\n" "$bootstrap_ver"
    printf "Bootstrap complete: %s\n" "$(bool_text "$bootstrap_ok")"
    printf "Service installed: %s\n" "$(bool_text "$service_ok")"
    printf "Server status: %s\n" "$(server_status)"
    printf "PID: %s\n" "$pid_text"
    printf "Port: %s\n" "$port"
    printf "IP: %s\n" "$ip"
    printf "\n"
    printf "upload_server.py: %s\n" "$( [ "$py_ok" = "1" ] && echo valid || echo corrupted_or_missing )"
    printf "launcher: %s\n" "$( [ "$launcher_ok" = "1" ] && echo valid || echo missing_or_bad )"
    printf "init script: %s\n" "$( [ "$init_ok" = "1" ] && echo valid || echo missing_or_bad )"
    printf "log file: %s\n" "$( [ "$log_ok" = "1" ] && echo present || echo missing )"
    printf "\nPress any button to continue"
}

show_debug_status() {
    show_prompt_message "$(debug_status_message)"
}

show_log_tail() {
    local msg
    if [ -f "$LOG_FILE" ]; then
        msg="Last log lines\n\n$(tail -n 15 "$LOG_FILE" 2>/dev/null)\n\nPress any button to continue"
    else
        msg="Last log lines\n\nLog file is missing.\n\nPress any button to continue"
    fi
    show_prompt_message "$msg"
}

repair_generated_files() {
    server_stop >/dev/null 2>&1
    write_python_server
    write_launcher_script
    if [ -d "/etc/init.d" ] && [ -w "/etc/init.d" ]; then
        write_init_script
        "$INIT_SCRIPT" enable >/dev/null 2>&1
        touch "$SERVICE_INSTALL_STATE_FILE"
    fi
    show_status_prompt "Generated files repaired"
}

reinstall_service() {
    rm -f "$SERVICE_INSTALL_STATE_FILE"
    rm -f "$INIT_SCRIPT"
    install_service_if_possible
    show_status_prompt "Service reinstalled"
}

reset_install_state() {
    rm -f "$BOOTSTRAP_VERSION_FILE"
    rm -f "$LEGACY_BOOTSTRAP_FILE"
    rm -f "$SERVICE_INSTALL_STATE_FILE"
    show_status_prompt "Install state reset"
}

run_debug_menu() {
    local action
    while true; do
        action="$(debug_menu)"
        case "$action" in
            status)
                show_debug_status
                ;;
            repair)
                repair_generated_files
                ;;
            reinstall_service)
                reinstall_service
                ;;
            reset_state)
                reset_install_state
                ;;
            logs)
                show_log_tail
                ;;
            back|*)
                return 0
                ;;
        esac
    done
}

run_menu() {
    local action

    while true; do
        action="$(main_menu)"

        case "$action" in
            start)
                server_start >/dev/null 2>&1
                show_status_prompt
                ;;
            stop)
                server_stop >/dev/null 2>&1
                show_status_prompt
                ;;
            status)
                show_status_prompt
                ;;
            change_port)
                change_port
                ;;
            debug)
                run_debug_menu
                ;;
            exit)
                LOG clear 2>/dev/null || true
                exit 0
                ;;
            *)
                LOG clear 2>/dev/null || true
                exit 0
                ;;
        esac
    done
}

mkdir -p "$BASE_DIR" "$DEPS_DIR" "$SERVE_DIR" "$UPLOAD_DIR"

if [ ! -f "$PORT_FILE" ]; then
    echo "$DEFAULT_HTTP_PORT" > "$PORT_FILE"
fi

case "$1" in
    start)
        server_start >/dev/null 2>&1
        show_status_prompt
        exit 0
        ;;
    stop)
        server_stop >/dev/null 2>&1
        show_status_prompt
        exit 0
        ;;
    status)
        show_status_prompt
        exit 0
        ;;
    debug)
        show_debug_status
        exit 0
        ;;
    *)
        run_menu
        ;;
esac
