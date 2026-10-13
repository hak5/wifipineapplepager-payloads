#!/bin/sh
#
# Title:        Starchorus mini HTTP server (nc)
# Description:  Dependency-free static server for the Starchorus page, for devices without
#               uhttpd, BusyBox httpd or python3 (offline, nothing to install). Serves ONLY
#               index.html and starchorus.json from STARCHORUS_DIR over GNU netcat, one connection at a
#               time. Read-only and passive: it just hands out two local files.
# Version:      0.1.0
# SPDX-License-Identifier: GPL-3.0-or-later
#
# USAGE:  ./starchorus-serve.sh [start]   # serve on STARCHORUS_BIND:STARCHORUS_PORT (auto:8199), foreground
#         ./starchorus-serve.sh stop      # stop a backgrounded server for this dir/port
#
# BIND: STARCHORUS_BIND auto (default) = the IPv4 address of br-lan (USB-C and management Wi-Fi), else 172.16.52.1 when an
# interface has it, else 127.0.0.1 (with a note); an explicit IPv4 address; or all = every interface. Binding one address
# needs an nc whose listener honours -s (GNU netcat 0.7.1: `nc -l -n -s ADDR -p PORT`). An nc without -s cannot bind one
# address, so with anything but `all` it does not start at all, rather than listen on every interface.
#
# NOTE: GNU netcat 0.7.1 has no keep-alive listen and its -e does not wire the socket to the
# program's stdio in listen mode. So we use the portable FIFO pattern: the client's request
# flows nc-stdout -> FIFO -> handler, and the handler's response flows handler-stdout -> nc-stdin
# -> client, with -c closing the connection on handler EOF. One request at a time, re-listening
# in a loop -- fine for a single browser polling every few seconds, not a concurrent web server.

DIR=${STARCHORUS_DIR:-/root/loot/starchorus}
PORT=${STARCHORUS_PORT:-8199}
BIND=${STARCHORUS_BIND:-auto}
NC=$(command -v nc || echo /usr/bin/nc)
HANDLER=$DIR/.starchorus-http-handler.sh
FIFO=$DIR/.starchorus-http.fifo
SERVE_PIDFILE=$DIR/starchorus-serve.pid
NC_PIDFILE=$DIR/.starchorus-http-nc.pid

# own_pid PID TEXT -> 0 iff PID is a running process whose command line (BusyBox `ps w`) contains TEXT. A pid read
# from one of our pidfiles is only killed when it still is what we started (a stale pid may belong to anything by now).
own_pid() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    ps w 2>/dev/null | awk -v p="$1" -v t="$2" '$1 == p && index($0, t) { f = 1 } END { exit !f }'
}

stop_serve() {   # stop what THIS script started for this dir/port, and nothing else
    # Only our own processes: the serve loop (SERVE_PIDFILE), the nc of its current connection (NC_PIDFILE, checked
    # against our exact nc arguments) and the handler instances (they run OUR handler file, $HANDLER). No sweep by
    # program name: a `ps | grep netcat` would kill every netcat on the device, whoever had started it.
    sp=$(sed -n 1p "$SERVE_PIDFILE" 2>/dev/null); np=$(sed -n 1p "$NC_PIDFILE" 2>/dev/null)
    own_pid "$sp" starchorus-serve && kill "$sp" 2>/dev/null       # its TERM trap stops its own nc and handler too
    own_pid "$np" "-p $PORT -c" && kill "$np" 2>/dev/null   # in case the loop is gone already (-p PORT -c with any -s)
    # shellcheck disable=SC2009  # busybox-safe; pgrep -f unavailable/unreliable here
    for p in $(ps w 2>/dev/null | awk -v h="$HANDLER" 'index($0, h) && !/awk/ { print $1 }'); do
        [ "$p" = "$$" ] || kill "$p" 2>/dev/null
    done
    # a handler still blocked in open() on the FIFO (no writer yet) returns and sees EOF: opening read-write never blocks
    [ -p "$FIFO" ] && : 2>/dev/null <> "$FIFO"
    rm -f "$SERVE_PIDFILE" "$NC_PIDFILE" "$FIFO" 2>/dev/null
    echo "[starchorus-serve] stopped (port $PORT)" >&2
}

case "$1" in
    stop) stop_serve; exit 0 ;;
esac

[ -f "$DIR/index.html" ] || { echo "[starchorus-serve] no index.html in $DIR" >&2; exit 1; }
[ -x "$NC" ] || { echo "[starchorus-serve] no nc at $NC" >&2; exit 1; }

# ipv4 TEXT -> 0 iff TEXT is a dotted-quad IPv4 address (four parts 0-255, no leading zero)
ipv4() {
    printf '%s\n' "$1" | awk -F. 'NR == 1 && NF == 4 { for (i = 1; i <= 4; i++) if ($i !~ /^(0|[1-9][0-9]?[0-9]?)$/ || $i + 0 > 255) exit 1; ok = 1 }
        END { exit !(ok && NR == 1) }'
}
# The listening address (see BIND above). auto reads `ip -4 -o addr` (read-only); 0.0.0.0 only ever comes from `all`.
case $BIND in
    all)  ADDR=0.0.0.0 ;;
    auto) ADDR="" ;;
    *)    if [ "$BIND" != 0.0.0.0 ] && ipv4 "$BIND"; then ADDR=$BIND
          else echo "[starchorus-serve] STARCHORUS_BIND=$BIND ignored (auto, all or an IPv4 address); using auto" >&2; ADDR=""; fi ;;
esac
if [ -z "$ADDR" ]; then
    IPS=$(ip -4 -o addr 2>/dev/null)
    ADDR=$(printf '%s\n' "$IPS" | awk '$2 == "br-lan" || $2 ~ /^br-lan@/ { for (i = 3; i < NF; i++) if ($i == "inet") { a = $(i + 1); sub(/\/.*/, "", a); print a; exit } }')
    if [ "$ADDR" = 0.0.0.0 ] || ! ipv4 "$ADDR"; then
        if printf '%s\n' "$IPS" | awk '{ for (i = 3; i < NF; i++) if ($i == "inet" && index($(i + 1), "172.16.52.1/") == 1) f = 1 } END { exit !f }'; then
            ADDR=172.16.52.1
        else
            echo "[starchorus-serve] no br-lan address: listening on 127.0.0.1 only (set STARCHORUS_BIND to an address, or to all)" >&2
            ADDR=127.0.0.1
        fi
    fi
fi
# The nc listening arguments. One address needs -s (the nc's own help names it); without it, no start.
if [ "$ADDR" = 0.0.0.0 ]; then
    echo "[starchorus-serve] bind all: the page and starchorus.json are reachable from every network this device is on" >&2
    set -- -l -p "$PORT" -c
elif "$NC" -h 2>&1 </dev/null | grep -qE -- '(^|[[:space:]])-s([ ,]|$)'; then
    set -- -l -n -s "$ADDR" -p "$PORT" -c
else
    echo "[starchorus-serve] this nc cannot bind one address (no -s); not started. STARCHORUS_BIND=all would listen on every interface." >&2
    exit 1
fi

# The per-connection handler: HTTP request on stdin, response on stdout (wired to nc by the FIFO loop).
cat > "$HANDLER" <<'HANDLER_EOF'
#!/bin/sh
DIR=__DIR__
CR=$(printf '\r')
# request line: METHOD PATH PROTO
read -r method path proto 2>/dev/null || exit 0
# drain request headers up to the blank line (strip trailing CR)
while read -r h 2>/dev/null; do h=${h%"$CR"}; [ -z "$h" ] && break; done
path=${path%%\?*}          # strip any query string (e.g. starchorus.json?_=123)
case "$method" in GET|HEAD) : ;; *) path=__BAD__ ;; esac
case "$path" in
    /|/index.html) f=$DIR/index.html; ct="text/html; charset=utf-8" ;;
    /starchorus.json)   f=$DIR/starchorus.json;  ct="application/json" ;;
    *)             f="" ;;
esac
if [ -n "$f" ] && [ -f "$f" ]; then
    len=$(wc -c < "$f" 2>/dev/null)
    printf '%s\r\n' "HTTP/1.0 200 OK" "Content-Type: $ct" "Content-Length: ${len:-0}" \
        "Cache-Control: no-store" "Access-Control-Allow-Origin: *" "Connection: close" ""
    [ "$method" = HEAD ] || cat "$f"
else
    body="not found"
    printf '%s\r\n' "HTTP/1.0 404 Not Found" "Content-Type: text/plain" \
        "Content-Length: ${#body}" "Connection: close" ""
    [ "$method" = HEAD ] || printf '%s' "$body"
fi
HANDLER_EOF
# bake the directory in: DIR is not exported, and the handler is a separate script
sed -i "s#__DIR__#$DIR#" "$HANDLER"
chmod +x "$HANDLER"

rm -f "$FIFO" 2>/dev/null
mkfifo "$FIFO" 2>/dev/null || { echo "[starchorus-serve] cannot create FIFO $FIFO" >&2; exit 1; }

echo $$ > "$SERVE_PIDFILE"
# The pipeline runs in the background and the loop waits for it, so a TERM is handled at once (a trap on a
# foreground pipeline would only run after the next client) and the trap knows the nc it has to stop: $! is
# the pid of the pipeline's last process, the nc. Its handler then reads EOF from the FIFO and exits.
serve_exit() {
    [ -n "$!" ] && kill "$!" 2>/dev/null
    [ -p "$FIFO" ] && : 2>/dev/null <> "$FIFO"
    rm -f "$SERVE_PIDFILE" "$NC_PIDFILE" "$FIFO"; exit 0
}
trap serve_exit INT TERM
if [ "$ADDR" = 0.0.0.0 ]; then URL="http://<device-ip>:$PORT/  (all interfaces)"; else URL="http://$ADDR:$PORT/"; fi
echo "[starchorus-serve] $URL  (nc, serving $DIR)" >&2
while :; do
    # request:  nc stdout -> FIFO -> handler ;  response:  handler stdout -> nc stdin -> client
    # shellcheck disable=SC2094  # reading+writing the FIFO in one pipeline IS the pattern here
    "$HANDLER" < "$FIFO" | "$NC" "$@" > "$FIFO" &   # "$@" = the listening arguments chosen above
    echo "$!" > "$NC_PIDFILE"
    wait
done
