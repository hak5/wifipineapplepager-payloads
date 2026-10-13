#!/bin/bash
# Title: Starchorus
# Author: Starchorus
# Description: Strictly passive, receive-only Wi-Fi observation tool; visualises the radio environment and never transmits.
# Version: 0.1.0
# Category: reconnaissance
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs the installed collector (/root/loot/starchorus; see BUNDLE below) over a 1 h window of the recon record (STARCHORUS_MAX_AGE 3600,
# one cycle every 30 s) and, if a static web server is available, serves the visualiser on :8199 (never 1471/80) of the management
# address only (br-lan: USB-C and management Wi-Fi; see BIND below). It reads the recon database of
# the device's running recon engine read-only and writes starchorus.json -- access points as stars, clients as orbiting
# satellites. It NEVER transmits: no deauthentication, no access point of its own, no injection, no association, no
# active features. It does not change the device LED. On the device it also opens an on-screen dashboard
# (starchorus-display.sh) with seven screens: a summary (AP/client counts, band split, freshness, crowding), the
# strongest networks, bands & security, logical devices/merged SSIDs, probe requests, stations and air quality
# (channel crowding), with a button menu.
#
# INTERFACE: on the device (no arguments, LIST_PICKER present, STARCHORUS_PAYLOAD_PLAIN not 1) a menu:
#   Start | Dashboard | Services (collector, web page: On/Off) | Options (window, interval, port, vendor, own radios,
#   survey, auto dashboard, defaults) | Status | Stop | Exit.   Back on the main menu = Exit; nothing is started.
# Everywhere else, and with any argument, no UI command runs:
#   payload.sh [start]          start per settings (the dashboard only opens from the menu); exit 1 if both services are off
#   payload.sh stop             stop the collector and our page server (our port, the port last served, our directory, our pidfiles only)
#   payload.sh status           status lines on stdout
#   payload.sh get [KEY]        KEY=VALUE (env|file|default) for one key or all
#   payload.sh set KEY VALUE    validate and save; exit 2 on an unknown key or an invalid value (file untouched)
#   payload.sh reset            delete the settings file (all keys back to their defaults)
# SETTINGS: $STARCHORUS_DIR/settings.conf, plain KEY=VALUE lines, only the keys that were changed. The file is PARSED
# (a fixed key list, every value validated), never sourced or evaluated; unknown keys and invalid values are skipped.
# Precedence: environment, then file, then default. Keys (menu and CLI share one validator and one writer):
#   window 0|60-86400 (STARCHORUS_MAX_AGE), interval 5-3600 (STARCHORUS_INTERVAL), port 1024-65535 but not 1471
#   (STARCHORUS_PORT), bind auto|all|IPv4 address (STARCHORUS_BIND; CLI only, no menu entry), vendor/own/survey on|off (STARCHORUS_VENDOR/_OWN/_SURVEY 1|0), collector/page/dashboard on|off
#   (STARCHORUS_COLLECTOR/_PAGE/_DASHBOARD 1|0, read by this payload only). No key reaches the collector's opt-in
#   transmitting source: it stays an environment-only switch of the collector, passed through untouched.
#
# WINDOW: the recon record is cumulative and never shrinks. The device's CPU cannot turn the whole record into
# starchorus.json every cycle (the collector and the dashboard's jq calls fall behind and the screen stops updating),
# so this payload reads only observations of the last hour and writes every 30 s. The page dims entries by their
# freshness within that window. Override per run: STARCHORUS_MAX_AGE=0 reads the whole record, STARCHORUS_INTERVAL=N
# sets the cycle.
#
# BIND: the page server listens on one address. auto (default) = the IPv4 address of br-lan (USB-C and management Wi-Fi);
# without br-lan 172.16.52.1 when some interface has it, else 127.0.0.1 with a note on stderr. An explicit IPv4 address
# binds that one. all = 0.0.0.0, every interface: the page and starchorus.json (every captured MAC and SSID) are then
# reachable from every network the device is on, a joined client-mode network included (the stock firewall accepts input
# there). Nothing ever falls back to all interfaces on its own.
#
# BUNDLE: the collector, the page and the dashboard normally live in /root/loot/starchorus (tools/install.sh, INSTALL.md).
# A self-contained payload directory (Hak5's library layout, built by tools/hak5-package.sh) carries them next to this
# file instead: starchorus-collect.sh, index.html, starchorus-display.sh, starchorus-serve.sh. When this directory
# ($_PAYLOAD_HOME, else the directory of $0) holds the collector and index.html and STARCHORUS_DIR has no collector yet,
# the first run copies them into STARCHORUS_DIR and carries on from there. An installed collector is never overwritten;
# to take a newer bundle, delete $STARCHORUS_DIR/starchorus-collect.sh (settings.conf is kept).
#
# SERVER: uhttpd may be present on the device (installed, not enabled at boot); the payload uses it when present,
# else python3, else the bundled nc mini-server. Without any server it still collects to starchorus.json; view it
# from a connected computer.
#
# POSIX sh on purpose (BusyBox ash on the device, dash/sh in the tests): no local, no arrays, no eval.

STARCHORUS_DIR=${STARCHORUS_DIR:-/root/loot/starchorus}
# Resolve a relative directory to an absolute path before deriving SETTINGS (set/get/reset compute SETTINGS before the cd
# below, and the page sweep matches uhttpd by our -h directory, which must be the same absolute path uhttpd is launched with).
case $STARCHORUS_DIR in
    /*) ;;
    *)  pl_abs=$(cd "$STARCHORUS_DIR" 2>/dev/null && pwd) && STARCHORUS_DIR=$pl_abs ;;
esac
SETTINGS=$STARCHORUS_DIR/settings.conf
# Which settings the environment sets: read BEFORE any default is applied (the environment beats the settings file).
# ${VAR:+x}, not ${VAR+x}: an empty variable counts as unset, so it matches the ${VAR:-default} expansions below (an
# empty STARCHORUS_PORT= must not hide the file value and then report the default as (env)).
PL_ENV=""
[ -z "${STARCHORUS_MAX_AGE:+x}" ] || PL_ENV="$PL_ENV window"
[ -z "${STARCHORUS_INTERVAL:+x}" ] || PL_ENV="$PL_ENV interval"
[ -z "${STARCHORUS_PORT:+x}" ] || PL_ENV="$PL_ENV port"
[ -z "${STARCHORUS_BIND:+x}" ] || PL_ENV="$PL_ENV bind"
[ -z "${STARCHORUS_VENDOR:+x}" ] || PL_ENV="$PL_ENV vendor"
[ -z "${STARCHORUS_OWN:+x}" ] || PL_ENV="$PL_ENV own"
[ -z "${STARCHORUS_SURVEY:+x}" ] || PL_ENV="$PL_ENV survey"
[ -z "${STARCHORUS_COLLECTOR:+x}" ] || PL_ENV="$PL_ENV collector"
[ -z "${STARCHORUS_PAGE:+x}" ] || PL_ENV="$PL_ENV page"
[ -z "${STARCHORUS_DASHBOARD:+x}" ] || PL_ENV="$PL_ENV dashboard"
STARCHORUS_PORT=${STARCHORUS_PORT:-8199}
STARCHORUS_BIND=${STARCHORUS_BIND:-auto}                  # payload only: the page server's address (see BIND above)
export STARCHORUS_DIR STARCHORUS_PORT
export STARCHORUS_OUTDIR="$STARCHORUS_DIR"
export STARCHORUS_MAX_AGE="${STARCHORUS_MAX_AGE:-3600}"   # seconds of recon record per cycle (1 h, see WINDOW above); 0 = the whole record
export STARCHORUS_INTERVAL="${STARCHORUS_INTERVAL:-30}"   # seconds between two cycles
export STARCHORUS_VENDOR="${STARCHORUS_VENDOR:-1}"        # 1 = local vendor lookup (collector default)
export STARCHORUS_OWN="${STARCHORUS_OWN:-0}"              # 1 = own interface MACs from sysfs (read-only)
export STARCHORUS_SURVEY="${STARCHORUS_SURVEY:-0}"        # 1 = channel busy time from the survey dump (read-only)
STARCHORUS_COLLECTOR=${STARCHORUS_COLLECTOR:-1}           # payload only: start the collector
STARCHORUS_PAGE=${STARCHORUS_PAGE:-1}                     # payload only: serve the page
STARCHORUS_DASHBOARD=${STARCHORUS_DASHBOARD:-1}           # payload only: open the dashboard after Start (menu)

PL_KEYS="window interval port bind vendor own survey collector page dashboard"
PL_FILE=""                     # keys that the settings file set with a valid value
PL_CR=$(printf '\r')

pl_has() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }   # pl_has "WORD LIST" WORD
pl_bit() { if [ "$1" = on ]; then echo 1; else echo 0; fi; }
pl_onoff() { if [ "$1" = 1 ]; then echo on; else echo off; fi; }
# pl_ipv4 TEXT -> 0 iff TEXT is a dotted-quad IPv4 address (four parts 0-255, no leading zero)
pl_ipv4() {
    printf '%s\n' "$1" | awk -F. 'NR == 1 && NF == 4 { for (i = 1; i <= 4; i++) if ($i !~ /^(0|[1-9][0-9]?[0-9]?)$/ || $i + 0 > 255) exit 1; ok = 1 }
        END { exit !(ok && NR == 1) }'
}

# pl_valid KEY VALUE -> 0 iff KEY is a settings key and VALUE is valid for it. The ONE validator of file, CLI and menu.
pl_valid() {
    case $1 in
        window|interval|port)
            case $2 in ''|*[!0-9]*|0?*|??????*) return 1 ;; esac   # digits only, no leading zero, at most 5 digits
            case $1 in
                window)   [ "$2" = 0 ] || { [ "$2" -ge 60 ] && [ "$2" -le 86400 ]; } ;;
                interval) [ "$2" -ge 5 ] && [ "$2" -le 3600 ] ;;
                *)        [ "$2" -ge 1024 ] && [ "$2" -le 65535 ] && [ "$2" != 1471 ] ;;
            esac ;;
        bind) case $2 in auto|all) return 0 ;; 0.0.0.0) return 1 ;; esac; pl_ipv4 "$2" ;;   # every interface only as `all`
        vendor|own|survey|collector|page|dashboard) [ "$2" = on ] || [ "$2" = off ] ;;
        *) return 1 ;;
    esac
}

# pl_assign KEY VALUE -> the variable behind KEY takes a validated settings value (on/off become 1/0)
pl_assign() {
    case $1 in
        window)    STARCHORUS_MAX_AGE=$2 ;;
        interval)  STARCHORUS_INTERVAL=$2 ;;
        port)      STARCHORUS_PORT=$2 ;;
        bind)      STARCHORUS_BIND=$2 ;;
        vendor)    STARCHORUS_VENDOR=$(pl_bit "$2") ;;
        own)       STARCHORUS_OWN=$(pl_bit "$2") ;;
        survey)    STARCHORUS_SURVEY=$(pl_bit "$2") ;;
        collector) STARCHORUS_COLLECTOR=$(pl_bit "$2") ;;
        page)      STARCHORUS_PAGE=$(pl_bit "$2") ;;
        dashboard) STARCHORUS_DASHBOARD=$(pl_bit "$2") ;;
    esac
}

# pl_value KEY -> the effective value in settings form
pl_value() {
    case $1 in
        window)    printf '%s\n' "$STARCHORUS_MAX_AGE" ;;
        interval)  printf '%s\n' "$STARCHORUS_INTERVAL" ;;
        port)      printf '%s\n' "$STARCHORUS_PORT" ;;
        bind)      printf '%s\n' "$STARCHORUS_BIND" ;;
        vendor)    pl_onoff "$STARCHORUS_VENDOR" ;;
        own)       pl_onoff "$STARCHORUS_OWN" ;;
        survey)    pl_onoff "$STARCHORUS_SURVEY" ;;
        collector) pl_onoff "$STARCHORUS_COLLECTOR" ;;
        page)      pl_onoff "$STARCHORUS_PAGE" ;;
        dashboard) pl_onoff "$STARCHORUS_DASHBOARD" ;;
    esac
}

pl_src() { if pl_has "$PL_ENV" "$1"; then echo env; elif pl_has "$PL_FILE" "$1"; then echo file; else echo default; fi; }

# The defaults of every key the environment does not set, taken before the file is applied (used by reset).
pl_snapshot() {
    PL_DEF=""
    for pl_k in $PL_KEYS; do pl_has "$PL_ENV" "$pl_k" || PL_DEF="$PL_DEF $pl_k=$(pl_value "$pl_k")"; done
}

# Parse the settings file (never source it): KEY=VALUE lines, CR stripped, a fixed key list, every value validated,
# the last valid line of a key wins; everything else is skipped. A key the environment sets is left alone. A leading
# UTF-8 BOM on the first line is stripped, and a file far larger than a real settings file is ignored (a single
# multi-MB line can stall the shell's read loop under bash 3.2; a real file has at most nine short lines).
PL_BOM=$(printf '\357\273\277')
pl_load() {
    [ -f "$SETTINGS" ] || return 0
    pl_sz=$(wc -c < "$SETTINGS" 2>/dev/null || echo 0)
    [ "${pl_sz:-0}" -le 65536 ] 2>/dev/null || return 0
    pl_first=1
    while IFS= read -r pl_l || [ -n "$pl_l" ]; do
        [ "$pl_first" = 1 ] && { pl_l=${pl_l#"$PL_BOM"}; pl_first=0; }
        pl_l=${pl_l%"$PL_CR"}
        case $pl_l in *=*) ;; *) continue ;; esac
        pl_k=${pl_l%%=*}; pl_v=${pl_l#*=}
        pl_valid "$pl_k" "$pl_v" || continue
        pl_has "$PL_FILE" "$pl_k" || PL_FILE="$PL_FILE $pl_k"
        pl_has "$PL_ENV" "$pl_k" || pl_assign "$pl_k" "$pl_v"
    done < "$SETTINGS"
}

# pl_set KEY VALUE -> validate, then write the settings file atomically (temp file + rename). The ONE writer of CLI
# and menu. 2 = unknown key or invalid value (nothing written), 1 = the file could not be written. A grep that cannot
# read the old file (exit >= 2) fails the write, so the old keys are never silently dropped: the file keeps its old
# content (rename never runs). A stale .tmp (a symlink, or an interrupted earlier write) is removed before the write,
# so it is never followed. A leftover .tmp is otherwise harmless: load ignores it, the next set overwrites it, reset removes it.
pl_set() {
    pl_valid "$1" "$2" || return 2
    rm -f "$SETTINGS.tmp"
    if ! (
        if [ -f "$SETTINGS" ]; then grep -v "^$1=" "$SETTINGS"; [ $? -le 1 ] || exit 1; fi
        printf '%s=%s\n' "$1" "$2"
    ) > "$SETTINGS.tmp" 2>/dev/null || ! mv -f "$SETTINGS.tmp" "$SETTINGS" 2>/dev/null; then
        rm -f "$SETTINGS.tmp"
        return 1
    fi
    pl_has "$PL_FILE" "$1" || PL_FILE="$PL_FILE $1"
    pl_has "$PL_ENV" "$1" || pl_assign "$1" "$2"
    return 0
}

pl_reset() {   # delete the settings file; every key the environment does not set is back at its default
    rm -f "$SETTINGS" "$SETTINGS.tmp"
    PL_FILE=""
    for pl_kv in $PL_DEF; do pl_assign "${pl_kv%%=*}" "${pl_kv#*=}"; done
}

# The environment is validated like the settings file: an invalid numeric override (out of range, six or more digits,
# and for the port also 1471) is not honoured -- it falls back to the file or the default and is no longer reported as
# (env). This keeps the page sweep off :1471, and keeps a menu label from showing an over-long unchecked value. An invalid
# STARCHORUS_BIND (0.0.0.0 included: every interface is spelt `all`) falls back the same way, never to all interfaces.
for pl_k in window interval port bind; do
    if pl_has "$PL_ENV" "$pl_k" && ! pl_valid "$pl_k" "$(pl_value "$pl_k")"; then
        pl_ne=""; for pl_e in $PL_ENV; do [ "$pl_e" = "$pl_k" ] || pl_ne="$pl_ne $pl_e"; done; PL_ENV=$pl_ne
        case $pl_k in
            window) STARCHORUS_MAX_AGE=3600 ;; interval) STARCHORUS_INTERVAL=30 ;; port) STARCHORUS_PORT=8199 ;;
            bind) echo "Starchorus: note: STARCHORUS_BIND ignored (auto, all or an IPv4 address)" >&2; STARCHORUS_BIND=auto ;;
        esac
    fi
done

pl_snapshot
pl_load

# ------------------------------------------------------------------ device UI shims
# On the device these call the UI commands; off the device (and in plain mode) nothing blocks: a picker returns its
# default, a number picker its default, a confirmation says yes, logs and errors print. Every answer is read
# defensively: a non-zero exit, an empty answer or an answer that is not one of the offered labels means Back.
if [ $# = 0 ] && [ "${STARCHORUS_PAYLOAD_PLAIN:-0}" != 1 ] && command -v LIST_PICKER >/dev/null 2>&1; then ONDEV=1; else ONDEV=0; fi

ui_pick() {   # ui_pick TITLE OPTION... DEFAULT -> the chosen option; 1 = Back
    if [ "$ONDEV" = 1 ]; then
        pl_a=$(LIST_PICKER "$@") || return 1
        [ -n "$pl_a" ] || return 1
        shift
        for pl_o; do [ "$pl_o" = "$pl_a" ] && { printf '%s\n' "$pl_a"; return 0; }; done
        return 1
    fi
    for pl_o; do :; done
    printf '%s\n' "$pl_o"
}
ui_num() {    # ui_num TITLE DEFAULT -> the number entered; 1 = unchanged
    if [ "$ONDEV" = 1 ]; then
        pl_a=$(NUMBER_PICKER "$1" "$2") || return 1
        [ -n "$pl_a" ] || return 1
        printf '%s\n' "$pl_a"
    else printf '%s\n' "$2"; fi
}
ui_confirm() {   # ui_confirm MESSAGE -> 0 = yes (exit 0 AND answer 1); anything else = no
    [ "$ONDEV" = 1 ] || return 0
    pl_a=$(CONFIRMATION_DIALOG "$1") || return 1
    [ "$pl_a" = 1 ]
}
ui_err() { if [ "$ONDEV" = 1 ]; then ERROR_DIALOG "$1" >/dev/null 2>&1; else printf 'ERROR: %s\n' "$1" >&2; fi; return 0; }
ui_log() {    # ui_log [blue|red|green] TEXT
    case $1 in blue|red|green) pl_col=$1; shift ;; *) pl_col= ;; esac
    if [ "$ONDEV" = 1 ]; then LOG ${pl_col:+"$pl_col"} "$*" >/dev/null 2>&1; else printf '%s\n' "$*"; fi
}
ui_spin_start() { [ "$ONDEV" = 1 ] && START_SPINNER "$1" 2>/dev/null; return 0; }
ui_spin_stop() { [ "$ONDEV" = 1 ] && [ -n "$1" ] && STOP_SPINNER "$1" >/dev/null 2>&1; return 0; }

# pl_install -> first run from a self-contained payload directory (see BUNDLE above): when this payload's own directory
# holds the collector and index.html, and STARCHORUS_DIR has no collector yet, copy the bundled files into STARCHORUS_DIR
# (a temporary file each, made executable before the rename; the collector last, so a half-finished copy is completed on
# the next run). An installed collector is never overwritten; nothing is copied when the two directories are the same.
# 1 = a copy failed.
pl_install() {
    [ -n "$PL_HOME" ] && [ "$PL_HOME" != "$STARCHORUS_DIR" ] || return 0
    [ -f "$PL_HOME/starchorus-collect.sh" ] && [ -f "$PL_HOME/index.html" ] || return 0
    [ -e "$STARCHORUS_DIR/starchorus-collect.sh" ] && return 0
    mkdir -p "$STARCHORUS_DIR" 2>/dev/null || return 1
    for pl_f in $PL_BUNDLE; do
        [ -f "$PL_HOME/$pl_f" ] || continue
        rm -f "$STARCHORUS_DIR/$pl_f.tmp"
        cp "$PL_HOME/$pl_f" "$STARCHORUS_DIR/$pl_f.tmp" 2>/dev/null || { rm -f "$STARCHORUS_DIR/$pl_f.tmp"; return 1; }
        case $pl_f in *.sh) chmod 755 "$STARCHORUS_DIR/$pl_f.tmp" 2>/dev/null || { rm -f "$STARCHORUS_DIR/$pl_f.tmp"; return 1; } ;; esac
        mv -f "$STARCHORUS_DIR/$pl_f.tmp" "$STARCHORUS_DIR/$pl_f" 2>/dev/null || { rm -f "$STARCHORUS_DIR/$pl_f.tmp"; return 1; }
    done
    if [ "$ONDEV" = 1 ]; then ui_log "Installed"; else echo "Starchorus: installed from $PL_HOME into $STARCHORUS_DIR" >&2; fi
}
# The Pager UI runs a payload from a copy at /tmp/payload-<id>.sh, so dirname "$0" may be /tmp: take the first
# candidate that actually holds the bundled collector (_PAYLOAD_HOME, the script's own directory, the install paths).
PL_HOME=
for pl_d in "${_PAYLOAD_HOME:-}" "$(cd "$(dirname "$0")" 2>/dev/null && pwd)" \
            /root/payloads/user/reconnaissance/starchorus /mmc/root/payloads/user/reconnaissance/starchorus; do
    [ -n "$pl_d" ] && [ -f "$pl_d/starchorus-collect.sh" ] && { PL_HOME=$pl_d; break; }
done
[ -n "$PL_HOME" ] || PL_HOME=${_PAYLOAD_HOME:-$(cd "$(dirname "$0")" 2>/dev/null && pwd)}
PL_BUNDLE="index.html starchorus-display.sh starchorus-serve.sh starchorus-collect.sh"   # the collector last
pl_install || echo "Starchorus: could not copy the bundled files into $STARCHORUS_DIR" >&2
[ -x "$STARCHORUS_DIR/starchorus-collect.sh" ] || { echo "Starchorus not installed in $STARCHORUS_DIR" >&2; exit 1; }
cd "$STARCHORUS_DIR" || exit 1

# pl_own PID TEXT -> 0 iff PID is a running process whose command line (BusyBox `ps w`) contains TEXT. A pid read from
# a pidfile is only ours while it still is what we started; a stale pid reused by another process is not (same idea as
# starchorus-serve.sh own_pid).
pl_own() {
    case $1 in ''|*[!0-9]*) return 1 ;; esac
    # shellcheck disable=SC2009  # busybox-safe; pgrep/pkill unreliable here
    ps w 2>/dev/null | awk -v p="$1" -v t="$2" '$1 == p && index($0, t) { f = 1 } END { exit !f }'
}

# pl_pids PORT -> the pids of OUR OWN page server(s) listening on PORT: a uhttpd -p [ADDR:]PORT -h our-dir, or a
# python -m http.server PORT [--bind ADDR] --directory our-dir. It matches the listening argument only, not the whole `ps w` line, so
# a PID/USER/VSZ column or an unrelated argument that happens to equal PORT is never mistaken for it; and it requires our
# own directory, so the device's own uhttpd on :80/:1471 (a different -h) is never touched even if PORT collides with it.
pl_pids() {
    # shellcheck disable=SC2009  # busybox-safe; pgrep/pkill unreliable here
    ps w 2>/dev/null | awk -v p="$1" -v d="$STARCHORUS_DIR" '
        !/uhttpd|http\.server/ || /awk/ { next }
        {
            uh = 0; py = 0; dir = 0
            for (i = 2; i <= NF; i++) {
                if (($i == "-h" || $i == "--directory") && $(i + 1) == d) dir = 1
                if ($i == ("--directory=" d)) dir = 1
                if ($i ~ ("^([0-9.]*:)?" p "$") && $(i - 1) == "-p") uh = 1
                if ($i ~ ("^([0-9.]*:)?" p "$") && $(i - 1) ~ /http\.server$/) py = 1
            }
            if ((uh || py) && dir) print $1
        }'
}

# Stop ONLY our own Starchorus web server(s): the current port, and the port that was actually served when the page last
# started (recorded in page.port, so a port change while the page ran does not orphan the old server). It never touches
# the device's own uhttpd on :80/:1471 (pl_pids requires our own -h directory). pkill -f is unreliable on busybox.
stop_servers() {
    pl_hp=$(cat "$STARCHORUS_DIR/httpd.pid" 2>/dev/null)
    pl_own "$pl_hp" "http.server" && kill "$pl_hp" 2>/dev/null   # only while it still is our python server
    rm -f "$STARCHORUS_DIR/httpd.pid"
    [ -x "$STARCHORUS_DIR/starchorus-serve.sh" ] && "$STARCHORUS_DIR/starchorus-serve.sh" stop >/dev/null 2>&1
    pl_pp=$(cat "$STARCHORUS_DIR/page.port" 2>/dev/null)
    for pl_pt in "$STARCHORUS_PORT" "$pl_pp"; do
        if [ -z "$pl_pt" ] || ! pl_valid port "$pl_pt"; then continue; fi
        for pl_sp in $(pl_pids "$pl_pt"); do kill "$pl_sp" 2>/dev/null; done
    done
    rm -f "$STARCHORUS_DIR/page.port" "$STARCHORUS_DIR/page.addr"
}

case "$1" in
    stop)
        ./starchorus-collect.sh --stop
        stop_servers
        echo "Starchorus stopped" >&2
        exit 0 ;;
esac

# ------------------------------------------------------------------ start, status
# pl_addr [quiet] -> the IPv4 address the page server binds to, per STARCHORUS_BIND (see BIND above). auto reads
# `ip -4 -o addr` (read-only): the first inet address of br-lan; else 172.16.52.1 when an interface has it; else
# 127.0.0.1 with a note on stderr (not with quiet). all -> 0.0.0.0, the only way to every interface.
pl_addr() {
    case $STARCHORUS_BIND in
        all)  echo 0.0.0.0; return 0 ;;
        auto) ;;
        *)    printf '%s\n' "$STARCHORUS_BIND"; return 0 ;;
    esac
    pl_ips=$(ip -4 -o addr 2>/dev/null)
    pl_a=$(printf '%s\n' "$pl_ips" | awk '$2 == "br-lan" || $2 ~ /^br-lan@/ { for (i = 3; i < NF; i++) if ($i == "inet") { a = $(i + 1); sub(/\/.*/, "", a); print a; exit } }')
    if [ "$pl_a" != 0.0.0.0 ] && pl_ipv4 "$pl_a"; then printf '%s\n' "$pl_a"; return 0; fi
    if printf '%s\n' "$pl_ips" | awk '{ for (i = 3; i < NF; i++) if ($i == "inet" && index($(i + 1), "172.16.52.1/") == 1) f = 1 } END { exit !f }'; then
        echo 172.16.52.1; return 0
    fi
    [ "$1" = quiet ] || echo "Starchorus: note: no br-lan address; the page listens on 127.0.0.1 only (set bind to an address, or to all)" >&2
    echo 127.0.0.1
}

# pl_url ADDR PORT -> the address to open in a browser
pl_url() { if [ "$1" = 0.0.0.0 ]; then echo "http://<device-ip>:$2/ (all interfaces)"; else echo "http://$1:$2/"; fi; }

# Best-effort static server for the visualiser. Prefer a real server (uhttpd/python3); else use the bundled nc
# mini-server. start-stop-daemon detaches it cleanly so the payload runner returns. 1 = no server available.
# Every server listens on PL_ADDR (pl_addr) only; the address and port served are recorded in page.addr and page.port.
pl_serve() {
    if command -v uhttpd >/dev/null 2>&1; then
        PL_ADDR=$(pl_addr)
        # uhttpd daemonises itself (no -f), so it detaches cleanly and stop_servers sweeps it by port and our directory.
        uhttpd -p "$PL_ADDR:$STARCHORUS_PORT" -h "$STARCHORUS_DIR" || { echo "Starchorus: uhttpd could not listen on $PL_ADDR:$STARCHORUS_PORT" >&2; return 1; }
        pl_srvn=""
    elif command -v python3 >/dev/null 2>&1; then
        PL_ADDR=$(pl_addr)
        python3 -m http.server "$STARCHORUS_PORT" --bind "$PL_ADDR" --directory "$STARCHORUS_DIR" >/dev/null 2>&1 & echo $! > "$STARCHORUS_DIR/httpd.pid"
        pl_srvn=""
    elif [ -x "$STARCHORUS_DIR/starchorus-serve.sh" ] && command -v nc >/dev/null 2>&1; then
        # the mini-server gets the resolved address (or all), so it binds the same one; STARCHORUS_DIR/PORT are exported
        PL_ADDR=$(pl_addr)
        pl_sb=$PL_ADDR; [ "$PL_ADDR" = 0.0.0.0 ] && pl_sb=all
        if command -v start-stop-daemon >/dev/null 2>&1; then
            STARCHORUS_BIND=$pl_sb start-stop-daemon -S -b -x "$STARCHORUS_DIR/starchorus-serve.sh"
        else
            STARCHORUS_BIND=$pl_sb setsid "$STARCHORUS_DIR/starchorus-serve.sh" </dev/null >/dev/null 2>&1 &
        fi
        pl_srvn=" (nc mini-server)"
    else
        echo "Starchorus: no web server for the page -> $STARCHORUS_DIR/starchorus.json (view from a connected computer, or 'opkg install -d mmc uhttpd')" >&2
        return 1
    fi
    printf '%s\n' "$STARCHORUS_PORT" > "$STARCHORUS_DIR/page.port" 2>/dev/null
    printf '%s\n' "$PL_ADDR" > "$STARCHORUS_DIR/page.addr" 2>/dev/null
    echo "Starchorus (passive) -> $(pl_url "$PL_ADDR" "$STARCHORUS_PORT")$pl_srvn" >&2
}

# Start per settings: clean restart (re-running never stacks duplicate collectors/servers), then the services that
# are switched on. Sets PL_SERVED (1 = a page server was started). With both services off it does NOT run the clean
# restart (that would stop what is running and start nothing): it prints a note and returns 1, as the menu's start
# flow does. The menu calls this only after its own "No service on" guard, so this note is for plain/CLI start.
pl_start() {
    PL_SERVED=0
    if [ "$STARCHORUS_COLLECTOR" != 1 ] && [ "$STARCHORUS_PAGE" != 1 ]; then
        echo "Starchorus: no service on (collector=off, page=off)" >&2
        return 1
    fi
    ./starchorus-collect.sh --stop >/dev/null 2>&1
    stop_servers
    sleep 1
    if [ "$STARCHORUS_COLLECTOR" = 1 ]; then
        # passive collector loop, detached so it survives the payload runner returning
        setsid ./starchorus-collect.sh </dev/null >/dev/null 2>collect.log &
    fi
    if [ "$STARCHORUS_PAGE" = 1 ] && pl_serve; then PL_SERVED=1; fi
    [ "$STARCHORUS_COLLECTOR" = 1 ] && [ "$STARCHORUS_PAGE" != 1 ] && echo "Starchorus: collecting, no page -> $STARCHORUS_DIR/starchorus.json" >&2
    return 0
}

pl_col_up() {   # read-only: the collector loop runs, per its own --status (works for the real collector and the test stand-in)
    ./starchorus-collect.sh --status 2>/dev/null | grep -iv 'not running' | grep -qi running
}

pl_wlab() {   # seconds -> short window label: All, N h, N min or N s
    case $1 in 0) echo All; return 0 ;; ''|*[!0-9]*|0?*) printf '%s\n' "$1"; return 0 ;; esac
    if [ $(($1 % 3600)) = 0 ]; then echo "$(($1 / 3600)) h"
    elif [ $(($1 % 60)) = 0 ]; then echo "$(($1 / 60)) min"
    else echo "$1 s"; fi
}

# read-only: our page server runs. Its pidfile (identity-checked, so a stale pid reused by another process does not
# count), or the same directory-scoped ps match stop_servers uses, on the current port and the port last served.
# Sets PL_UPPORT and PL_UPADDR to the port and address actually being served (the recorded page.port and page.addr when
# present), so Status reports the right ones.
pl_page_up() {
    pl_pp=$(cat "$STARCHORUS_DIR/page.port" 2>/dev/null)
    if [ -n "$pl_pp" ] && pl_valid port "$pl_pp"; then PL_UPPORT=$pl_pp; else PL_UPPORT=$STARCHORUS_PORT; fi
    PL_UPADDR=$(cat "$STARCHORUS_DIR/page.addr" 2>/dev/null)
    pl_ipv4 "$PL_UPADDR" || PL_UPADDR=$(pl_addr quiet)
    [ -f "$STARCHORUS_DIR/httpd.pid" ] && pl_own "$(cat "$STARCHORUS_DIR/httpd.pid" 2>/dev/null)" "http.server" && return 0
    [ -f "$STARCHORUS_DIR/starchorus-serve.pid" ] && pl_own "$(cat "$STARCHORUS_DIR/starchorus-serve.pid" 2>/dev/null)" "starchorus-serve" && return 0
    for pl_pt in "$STARCHORUS_PORT" "$pl_pp"; do
        if [ -z "$pl_pt" ] || ! pl_valid port "$pl_pt"; then continue; fi
        if [ -n "$(pl_pids "$pl_pt")" ]; then PL_UPPORT=$pl_pt; return 0; fi
    done
    return 1
}

pl_status() {
    ui_log blue "Status"
    ./starchorus-collect.sh --status 2>&1 | while IFS= read -r pl_sl; do ui_log "${pl_sl#\[starchorus\] }"; done
    [ "$STARCHORUS_COLLECTOR" = 1 ] || ui_log "Collector: off"
    if [ "$STARCHORUS_PAGE" != 1 ]; then ui_log "Page: off"
    elif pl_page_up; then ui_log "Page: $PL_UPADDR:$PL_UPPORT running"
    else ui_log "Page: $(pl_addr quiet):$STARCHORUS_PORT not running"; fi
    ui_log "Window $(pl_wlab "$STARCHORUS_MAX_AGE"), every $STARCHORUS_INTERVAL s"
}

# ------------------------------------------------------------------ menu (device only)
pl_lab() { if [ "$(pl_value "$1")" = on ]; then echo On; else echo Off; fi; }

pl_change() {   # pl_change KEY VALUE -> save unless it is already the effective value
    [ "$(pl_value "$1")" = "$2" ] && return 0
    pl_set "$1" "$2" || { ui_err "Not saved"; return 0; }
    pl_has "$PL_ENV" "$1" && ui_log "Set by environment"
    # a change to a collector/page parameter takes effect only on the next Start; say so while the collector runs
    case $1 in window|interval|port|vendor|own|survey) pl_col_up && ui_log "Applies on next Start" ;; esac
    return 0
}

pl_switch() {   # pl_switch KEY TITLE -> On/Off with the current state preselected
    pl_s=$(ui_pick "$2" "On" "Off" "$(pl_lab "$1")") || return 0
    case $pl_s in On) pl_change "$1" on ;; Off) pl_change "$1" off ;; esac
}

pl_heavy() {    # pl_heavy SECONDS -> 0 = use it (a small window, or the user confirmed a large one)
    if [ "$1" = 0 ]; then ui_confirm "All may lag. Use it?"
    elif [ "$1" -gt 21600 ]; then ui_confirm "Over 6 h may lag. Use it?"
    fi
}

pl_window() {
    pl_cur=$(pl_value window)
    case $pl_cur in 120) pl_d="2 min" ;; 600) pl_d="10 min" ;; 3600) pl_d="1 h" ;; 21600) pl_d="6 h" ;; 0) pl_d=All ;; *) pl_d=Other ;; esac
    pl_s=$(ui_pick "Window" "2 min" "10 min" "1 h" "6 h" "All" "Other" "$pl_d") || return 0
    case $pl_s in
        "2 min") pl_n=120 ;; "10 min") pl_n=600 ;; "1 h") pl_n=3600 ;; "6 h") pl_n=21600 ;; All) pl_n=0 ;;
        Other) pl_n=$(ui_num "Window (s)" "$pl_cur") || return 0 ;;
        *) return 0 ;;
    esac
    pl_valid window "$pl_n" || { ui_err "Window: 60-86400 s"; return 0; }
    [ "$pl_n" = "$pl_cur" ] && return 0
    pl_heavy "$pl_n" || return 0
    pl_change window "$pl_n"
}

pl_interval() {
    pl_cur=$(pl_value interval)
    case $pl_cur in 10|30|60|120) pl_d="$pl_cur s" ;; *) pl_d=Other ;; esac
    pl_s=$(ui_pick "Interval" "10 s" "30 s" "60 s" "120 s" "Other" "$pl_d") || return 0
    case $pl_s in
        "10 s") pl_n=10 ;; "30 s") pl_n=30 ;; "60 s") pl_n=60 ;; "120 s") pl_n=120 ;;
        Other) pl_n=$(ui_num "Interval (s)" "$pl_cur") || return 0 ;;
        *) return 0 ;;
    esac
    pl_valid interval "$pl_n" || { ui_err "Interval: 5-3600 s"; return 0; }
    pl_change interval "$pl_n"
}

pl_port() {
    pl_n=$(ui_num "Port" "$(pl_value port)") || return 0
    pl_valid port "$pl_n" || { ui_err "Port: 1024-65535, not 1471"; return 0; }
    pl_change port "$pl_n"
}

pl_services() {
    while :; do
        pl_c=$(ui_pick "Services" "Collector: $(pl_lab collector)" "Web page: $(pl_lab page)" "Back" "Back") || return 0
        case $pl_c in
            "Collector: "*) pl_switch collector "Collector" ;;
            "Web page: "*)  pl_switch page "Web page" ;;
            *) return 0 ;;
        esac
    done
}

pl_options() {
    while :; do
        pl_c=$(ui_pick "Options" "Window: $(pl_wlab "$(pl_value window)")" "Interval: $(pl_value interval) s" \
            "Port: $(pl_value port)" "Vendor: $(pl_lab vendor)" "Own radios: $(pl_lab own)" "Survey: $(pl_lab survey)" \
            "Auto dash: $(pl_lab dashboard)" "Defaults" "Back" "Back") || return 0
        case $pl_c in
            "Window: "*)         pl_window ;;
            "Interval: "*)       pl_interval ;;
            "Port: "*)           pl_port ;;
            "Vendor: "*)         pl_switch vendor "Vendor" ;;
            "Own radios: "*)     pl_switch own "Own radios" ;;
            "Survey: "*)         pl_switch survey "Survey" ;;
            "Auto dash: "*)      pl_switch dashboard "Auto dashboard" ;;
            Defaults)            ui_confirm "Reset all settings?" && pl_reset ;;
            *) return 0 ;;
        esac
    done
}

pl_dashboard() {   # view only: starts and stops nothing
    [ -x "$STARCHORUS_DIR/starchorus-display.sh" ] || { ui_err "No dashboard"; return 0; }
    exec sh "$STARCHORUS_DIR/starchorus-display.sh"
}

pl_start_flow() {
    ui_log blue "Window $(pl_wlab "$STARCHORUS_MAX_AGE"), every $STARCHORUS_INTERVAL s, port $STARCHORUS_PORT"
    if [ "$STARCHORUS_COLLECTOR" = 1 ] && [ "$STARCHORUS_PAGE" = 1 ]; then pl_what="collector, web page"
    elif [ "$STARCHORUS_COLLECTOR" = 1 ]; then pl_what="collector"
    elif [ "$STARCHORUS_PAGE" = 1 ]; then pl_what="web page"
    else ui_err "No service on"; return 0; fi
    ui_confirm "Start $pl_what?" || return 0
    pl_id=$(ui_spin_start "Starting")
    pl_start
    ui_spin_stop "$pl_id"
    if [ "$PL_SERVED" = 1 ]; then ui_log "Page: $PL_ADDR:$STARCHORUS_PORT"
    elif [ "$STARCHORUS_PAGE" = 1 ]; then ui_log red "No web server"
    fi
    [ "$STARCHORUS_COLLECTOR" = 1 ] && [ "$PL_SERVED" != 1 ] && ui_log "Collecting, no page"
    if [ "$STARCHORUS_DASHBOARD" = 1 ] && [ -x "$STARCHORUS_DIR/starchorus-display.sh" ]; then
        exec sh "$STARCHORUS_DIR/starchorus-display.sh"
    fi
    return 0
}

pl_menu() {
    while :; do
        pl_c=$(ui_pick "Starchorus" "Start" "Dashboard" "Services" "Options" "Status" "Stop" "Exit" "Start") || exit 0
        case $pl_c in
            Start)     pl_start_flow ;;
            Dashboard) pl_dashboard ;;
            Services)  pl_services ;;
            Options)   pl_options ;;
            Status)    pl_status ;;
            Stop)      ./starchorus-collect.sh --stop >/dev/null 2>&1; stop_servers; ui_log green "Stopped" ;;
            *)         { pl_col_up || pl_page_up; } && ui_log "Services keep running"; exit 0 ;;
        esac
    done
}

pl_usage() { echo "usage: payload.sh [start | stop | status | get [KEY] | set KEY VALUE | reset]   keys: $PL_KEYS" >&2; }

# ------------------------------------------------------------------ dispatch
case "$1" in
    "")
        [ "$ONDEV" = 1 ] && pl_menu
        pl_start; exit $? ;;
    start)
        pl_start; exit $? ;;
    status)
        pl_status ;;
    get)
        if [ $# -gt 2 ] || { [ $# = 2 ] && ! pl_has "$PL_KEYS" "$2"; }; then pl_usage; exit 2; fi
        for pl_k in ${2:-$PL_KEYS}; do printf '%s=%s (%s)\n' "$pl_k" "$(pl_value "$pl_k")" "$(pl_src "$pl_k")"; done ;;
    set)
        [ $# = 3 ] || { pl_usage; exit 2; }
        pl_set "$2" "$3"; pl_rc=$?
        [ "$pl_rc" = 0 ] && pl_has "$PL_ENV" "$2" && echo "Starchorus: note: $2 is set in the environment; the saved value applies only without it" >&2
        [ "$pl_rc" = 2 ] && { echo "Starchorus: refused: $2=$3 (unknown key or invalid value)" >&2; pl_usage; }
        [ "$pl_rc" = 1 ] && echo "Starchorus: cannot write $SETTINGS" >&2
        exit "$pl_rc" ;;
    reset)
        pl_reset ;;
    *)
        pl_usage; exit 2 ;;
esac
exit 0
