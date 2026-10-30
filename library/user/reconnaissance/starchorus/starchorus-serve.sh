#!/bin/sh
#
# Title:        Starchorus mini HTTP server (nc)
# Description:  Dependency-free static server for the Starchorus page, for devices without
#               uhttpd, BusyBox httpd or python3 (offline, nothing to install). Serves ONLY
#               index.html and starchorus.json from STARCHORUS_DIR over GNU netcat, one connection at a
#               time. Read-only and passive: it just hands out two local files.
# Version:      0.2.6.2
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
#
# LIMITS: one silent client must not hold the one connection. The handler starts together with its nc, before anybody has
# connected, so "no request yet" is also what a client that connects and says nothing looks like: after IDLE s of it the
# handler stops its nc and the loop listens anew (once per IDLE s of quiet; the old nc listens until it is stopped). The whole
# round from the request line to the nc's close gets LIFE s. Both are watchdogs inside the handler, not `timeout` around it: a
# wrapper that stays until the handler is gone (coreutils' does) keeps the nc's stdin open after the handler has closed it.
# A watchdog needs no `read -t`, so these two hold in any shell. Each header line also gets SLOW s with `read -t` (BusyBox ash,
# bash); a shell without it (dash) is held to LIFE there.
# FILES: one RAM copy (mode 600) per answer; see the handler.
# CORS: no Access-Control-Allow-Origin. The page and starchorus.json are one origin; the header would let any web page open
# in the browser of someone who can reach the Pager read every MAC address and SSID in starchorus.json.

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
    # The serve loop (SERVE_PIDFILE), the nc of its current connection (NC_PIDFILE, checked against our exact nc arguments)
    # and the handler instances (they run OUR handler file, $HANDLER). No sweep by program name: a `ps | grep netcat` would
    # kill every netcat on the device, whoever had started it.
    sp=$(sed -n 1p "$SERVE_PIDFILE" 2>/dev/null); np=$(sed -n 1p "$NC_PIDFILE" 2>/dev/null)
    own_pid "$sp" starchorus-serve && kill "$sp" 2>/dev/null       # its TERM trap stops its own nc and handler too
    own_pid "$np" "-p $PORT -c" && kill "$np" 2>/dev/null   # in case the loop is gone already (-p PORT -c with any -s)
    # shellcheck disable=SC2009  # busybox-safe; pgrep -f unavailable/unreliable here
    for p in $(ps w 2>/dev/null | awk -v h="$HANDLER" 'index($0, h) && !/awk/ { print $1 }'); do
        [ "$p" = "$$" ] || kill "$p" 2>/dev/null
    done
    # a handler still blocked in open() on the FIFO (no writer yet) returns and sees EOF: opening read-write never blocks
    [ -p "$FIFO" ] && : 2>/dev/null <> "$FIFO"
    rm -f "$SERVE_PIDFILE" "$NC_PIDFILE" "$FIFO" "${TMPDIR:-/tmp}"/starchorus-http-"$PORT".* 2>/dev/null   # and the copy of a killed handler
    echo "[starchorus-serve] stopped (port $PORT)" >&2
}

case "$1" in
    stop) stop_serve; exit 0 ;;
esac

# PORT and DIR are baked into the handler by sed (below). A port that is not all digits, or a directory holding a character that sed
# (& # \) or the handler's double quotes (" $ `) would read as syntax, gives a handler that serves nothing: refused here.
case $PORT in ''|*[!0-9]*) echo "[starchorus-serve] STARCHORUS_PORT is not a port number: $PORT" >&2; exit 1 ;; esac
case $DIR in
    *'&'*|*'#'*|*\\*|*'"'*|*'$'*|*'`'*) printf '%s\n' '[starchorus-serve] STARCHORUS_DIR must not contain & # \ " $ or a backtick' >&2; exit 1 ;;
esac
[ -f "$DIR/index.html" ] || { echo "[starchorus-serve] no index.html in $DIR" >&2; exit 1; }
[ -x "$NC" ] || { echo "[starchorus-serve] no nc at $NC" >&2; exit 1; }
# One server per directory: the handler, the FIFO and the pidfiles are shared, so a second start would break the first and leave
# it running unrecorded, where stop cannot find it, holding the port. (Not our own pid: a stale pidfile may carry it by chance.)
sp=$(sed -n 1p "$SERVE_PIDFILE" 2>/dev/null)
if [ "$sp" != "$$" ] && own_pid "$sp" starchorus-serve; then echo "[starchorus-serve] already running (pid $sp); stop it first" >&2; exit 1; fi

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
# The nc listening arguments (see BIND above).
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
init() {   # does nothing and is never called: a function head, so that tools/passivity-check.sh reads the lines below as code
    :
}
DIR="__DIR__"
PORT=__PORT__
CR=$(printf '\r')
IDLE=15     # s to a request line
SLOW=10     # s to each further request header line
LIFE=60     # s from the request line to the nc's close
# read -t (SLOW): see LIMITS in starchorus-serve.sh
RT=0; read -t 1 -r _x </dev/null 2>/dev/null; [ $? -le 1 ] && RT=1
rd() { _s=$1; shift; if [ "$RT" = 1 ]; then read -t "$_s" -r "$@" 2>/dev/null; else read -r "$@" 2>/dev/null; fi; }   # rd SECS NAME...
# /proc/PID/cmdline names one process without a list of them all (Linux); elsewhere ps does
PR=0; [ -r /proc/self/cmdline ] && PR=1
# stop_nc [PID]: end the nc in front of this handler (PID, else the one the loop keeps in the pidfile) if that pid still is
# our nc: a pid from a file may be anybody's by now. Quick on purpose: the nc of a quiet listener still accepts until it is
# stopped, and the next one cannot listen before this one is gone. A pid that is gone already costs no process at all.
stop_nc() {
    np=$1; [ -n "$np" ] || read -r np 2>/dev/null < "$DIR/.starchorus-http-nc.pid"
    case $np in ''|*[!0-9]*) return ;; esac
    kill -0 "$np" 2>/dev/null || return
    if [ "$PR" = 1 ]; then
        case $(tr '\0' ' ' < "/proc/$np/cmdline" 2>/dev/null) in *"-p $PORT -c"*) kill "$np" 2>/dev/null ;; esac
    else
        ps w 2>/dev/null | awk -v p="$np" -v t="-p $PORT -c" '$1 == p && index($0, t) { f = 1 } END { exit !f }' && kill "$np" 2>/dev/null
    fi
}
# guard SECS [PID]: after SECS s stop the nc (PID, else the one the loop keeps in the pidfile by then), which ends whatever the
# handler waits for, a read included, in any shell. It has no stdio of its own to hold (the nc must see EOF when the handler is
# done). unguard cancels it.
guard() {
    ( trap 'kill "$sp" 2>/dev/null; exit 0' TERM
      sleep "$1" & sp=$!; wait "$sp" && stop_nc "$2" ) </dev/null >/dev/null 2>&1 &
    wd=$!
}
unguard() { [ -z "$wd" ] || kill "$wd" 2>/dev/null; wd=""; }
short() {   # short STATUS TEXT: a plain-text answer
    printf '%s\r\n' "HTTP/1.0 $1" "Content-Type: text/plain" "Content-Length: ${#2}" "Connection: close" ""
    [ "$method" = HEAD ] || printf '%s' "$2"
}
snap=""; wd=""
trap 'rm -f "$snap"; [ -z "$wd" ] || kill "$wd" 2>/dev/null' EXIT
trap 'exit 1' HUP INT TERM PIPE
# request line: METHOD PATH PROTO. The read has no limit of its own: the watchdog (IDLE, see LIMITS in starchorus-serve.sh) is
# started first. The pidfile may still name the last round's nc at this point, so the watchdog looks at it only when it strikes.
guard "$IDLE"
read -r method path proto 2>/dev/null || { stop_nc; exit 0; }
unguard
# A client is there now. The rest of the round (headers, answer, the nc's close) gets LIFE s. The watchdog takes the pid of
# this round's nc now, so that a late one could only ever find a pid that is gone.
read -r n0 2>/dev/null < "$DIR/.starchorus-http-nc.pid"
guard "$LIFE" "$n0"
# drain request headers up to the blank line (strip trailing CR); a client that stalls here for SLOW s is answered all the same
while rd "$SLOW" h; do h=${h%"$CR"}; [ -z "$h" ] && break; done
path=${path%%\?*}          # strip any query string (e.g. starchorus.json?_=123)
case "$method" in GET|HEAD) : ;; *) path=__BAD__ ;; esac
case "$path" in
    /|/index.html) f=$DIR/index.html; ct="text/html; charset=utf-8"; cc="max-age=60" ;;   # changes only when installed
    /starchorus.json)   f=$DIR/starchorus.json;  ct="application/json"; cc="no-store" ;;
    *)             f="" ;;
esac
if [ -n "$f" ] && [ -f "$f" ]; then
    # One copy in RAM, measured and sent as one file: the collector replaces starchorus.json by mv at any moment, and the
    # length of the old file in front of the bytes of the new one would be a lie. Mode 600; gone with this process.
    if snap=$(mktemp "${TMPDIR:-/tmp}/starchorus-http-$PORT.XXXXXX" 2>/dev/null) && cp "$f" "$snap" 2>/dev/null \
       && len=$(wc -c < "$snap" 2>/dev/null) && [ -n "$len" ]; then
        printf '%s\r\n' "HTTP/1.0 200 OK" "Content-Type: $ct" "Content-Length: $((len))" \
            "Cache-Control: $cc" "Connection: close" ""
        [ "$method" = HEAD ] || cat "$snap"
    else
        short "503 Service Unavailable" "unavailable"
    fi
else
    short "404 Not Found" "not found"
fi
# Done. Closing stdout gives the nc its EOF (it sends what it still holds and closes); its exit is our EOF in turn, and the
# loop starts the next round only after both. An nc that stays (a client that stopped reading) is ended by the watchdog.
exec >&-
cat > /dev/null
HANDLER_EOF
# bake the directory and the port in: they are not exported, and the handler is a separate script
if ! { sed "s#__DIR__#$DIR#; s#__PORT__#$PORT#" "$HANDLER" > "$HANDLER.new" && mv "$HANDLER.new" "$HANDLER"; } || grep -qE '__(DIR|PORT)__' "$HANDLER"; then
    rm -f "$HANDLER.new"; echo "[starchorus-serve] cannot bake $DIR and port $PORT into $HANDLER" >&2; exit 1
fi
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
    rm -f "$SERVE_PIDFILE" "$NC_PIDFILE" "$FIFO"; exit "${1:-0}"
}
trap serve_exit INT TERM
if [ "$ADDR" = 0.0.0.0 ]; then URL="http://<device-ip>:$PORT/  (all interfaces)"; else URL="http://$ADDR:$PORT/"; fi
echo "[starchorus-serve] $URL  (nc, serving $DIR)" >&2
bad=0
while :; do
    t0=$(date +%s)
    # the FIFO flow: see NOTE in the header
    # shellcheck disable=SC2094  # reading+writing the FIFO in one pipeline IS the pattern here
    "$HANDLER" < "$FIFO" | "$NC" "$@" > "$FIFO" &   # "$@" = the listening arguments chosen above
    echo "$!" > "$NC_PIDFILE"
    wait "$!"; rc=$?
    wait   # and the handler: the next round starts only after both
    # An nc that cannot listen (an address the device does not hold, a port taken) ends at once with a status of its own, and
    # the loop would start it again at full speed while the page counts as up. A signal (129 to 192) is the handler's watchdog,
    # and an nc that ran for a while was listening. After five quick failures in a row the server ends; until then it backs off.
    if [ "$rc" -gt 0 ] && { [ "$rc" -le 128 ] || [ "$rc" -gt 192 ]; } && [ $(($(date +%s) - t0)) -lt 2 ]; then
        bad=$((bad + 1))
        sleep "$bad" &   # in the background, so that a TERM ends it at once; $! is then a live process for serve_exit
        [ "$bad" -lt 5 ] || { echo "[starchorus-serve] nc cannot listen on $ADDR:$PORT (status $rc); giving up" >&2; serve_exit 1; }
        wait "$!"
    else
        bad=0
    fi
done
