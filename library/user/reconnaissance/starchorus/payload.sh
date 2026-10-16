#!/bin/bash
# Title: Starchorus
# Author: Starchorus
# Description: Strictly passive, receive-only Wi-Fi observation tool; visualises the radio environment and never transmits.
# Version: 0.1.1
# Contract: 2
# Category: reconnaissance
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs the installed collector (/root/loot/starchorus; see BUNDLE below) over a 1 h window of the recon record (STARCHORUS_MAX_AGE 3600,
# one cycle every 30 s) and, if a static web server is available, serves the visualiser on :8199 (never 1471/80) of the management
# address only (br-lan: USB-C and management Wi-Fi; see BIND below). It reads the recon database of
# the device's running recon engine read-only and writes starchorus.json -- access points as stars, clients as orbiting
# satellites. It NEVER transmits: no deauthentication, no access point of its own, no injection, no association, no
# active features. It does not change the device LED. On the device it also opens the Overview
# (starchorus-display.sh) with seven screens: a summary (AP/client counts, band split, freshness, crowding), the
# strongest networks, bands & security, logical devices/merged SSIDs, probe requests, stations and air quality
# (channel crowding).
#
# INTERFACE: on the device (no arguments, LIST_PICKER present, STARCHORUS_PAYLOAD_PLAIN not 1) a menu whose title shows the
#   state, worked out afresh at every draw: "Starchorus: Stopped" (Start | Settings) or "Starchorus: Running" (Overview |
#   Open on Phone or Start Web Page | Stop | Settings). Nothing starts on launch. B goes back one level; on the main menu it
#   leaves the payload, and whatever runs keeps running. See MENU below.
# Everywhere else, and with any argument, no UI command runs:
#   payload.sh [start]          start per settings (the Overview only opens from the menu); exit 1 if both services are off
#   payload.sh stop             stop the collector and our page server (our port, the port last served, our directory, our pidfiles only)
#   payload.sh status           status lines on stdout
#   payload.sh get [KEY]        KEY=VALUE (env|file|default) for one key or all
#   payload.sh set KEY VALUE    validate and save; exit 2 on an unknown key or an invalid value (file untouched)
#   payload.sh reset            delete the settings file (all keys back to their defaults)
# SETTINGS: $STARCHORUS_DIR/settings.conf, plain KEY=VALUE lines, only the keys that were changed. The file is PARSED
# (a fixed key list, every value validated), never sourced or evaluated; unknown keys and invalid values are skipped.
# Precedence: environment, then file, then default. Keys (menu and CLI share one validator and one writer):
#   window 0|60-86400 (STARCHORUS_MAX_AGE), interval 5-3600 (STARCHORUS_INTERVAL), port 1024-65535 but not 1471
#   (STARCHORUS_PORT), bind auto|all|IPv4 address (STARCHORUS_BIND; CLI only, no menu entry), vendor/survey on|off
#   (STARCHORUS_VENDOR/_SURVEY 1|0), page on|off (STARCHORUS_PAGE 1|0, read by this payload only). Three switches are
#   environment only, with no key and no menu row: STARCHORUS_OWN (own interface MACs), STARCHORUS_DASHBOARD (0 = the
#   Overview does not open after Start) and STARCHORUS_COLLECTOR (0 = no collector; the menu then refuses to run). No key
#   reaches the collector's opt-in transmitting source: it stays an environment-only switch of the collector, passed
#   through untouched.
#
# MENU (device only; the texts are the menu specification's, verbatim):
#   Launch: E1 without a collector, E12 with STARCHORUS_COLLECTOR=0; pidfiles whose pid is not ours are deleted (a pid read
#   from a file on eMMC can belong to anything after a reboot); "Starchorus listens only."; a version, or a "# Contract:"
#   number (the interface the three scripts share; a file without one is contract 1), that differs between this payload
#   and the installed collector or Overview is reported once. A dead loop with the marker present had
#   stopped by itself ("Collector had stopped."), and a page server left without a collector is stopped.
#   Start: no question; spinner; marker /tmp/starchorus.started = the epoch of this Start (tmpfs: a reboot clears it);
#   the collector (setsid, nice 19) and, with Web Page ON, the page server (nice 19); up to 5 s for both, then, when the
#   Overview is to open, up to 20 s more for the first capture of this Start (the spinner stays up, so the Overview opens
#   on numbers and not on "Waiting for the first scan."), then the Overview as a child process (no exec; nice 19), back to
#   RUNNING with the cursor on Overview. A spinner that is up when the payload gets TERM or INT is stopped first.
#   Stop: no question; --stop, our servers, the loop's sleep child (the trap runs at once), then up to 10 s for the loop
#   pid to go, kill -9 (identity-checked) and 2 s more.
#   Settings: every change is saved at once; leaving with B applies what changed while the collector runs (collector
#   keys: restart of the collector only, marker kept; port: restart of the page server only). Nothing is asked except
#   Reset to Defaults. A key set in the environment is shown "(locked)" and is not changed here.
#   Debounce: right after a spinner or the Overview, a Start, Stop or B that comes back within 0.6 s (/proc/uptime) is
#   taken for a queued press and ignored; the menu is drawn again. At most three in a row: a picker that keeps failing
#   at once ends the payload instead of being drawn for ever.
#
# WINDOW: the recon record is cumulative and never shrinks. The device's CPU cannot turn the whole record into
# starchorus.json every cycle (the collector and the Overview's jq calls fall behind and the screen stops updating),
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
# BUNDLE: the collector, the page and the Overview normally live in /root/loot/starchorus (tools/install.sh, INSTALL.md).
# A self-contained payload directory (Hak5's library layout, built by tools/hak5-package.sh) carries them next to this
# file instead: starchorus-collect.sh, index.html, starchorus-display.sh, starchorus-serve.sh. When this directory
# ($_PAYLOAD_HOME, else the directory of $0) holds the collector and index.html and STARCHORUS_DIR has no collector yet,
# the first run copies them into STARCHORUS_DIR and carries on from there. An installed collector is never overwritten;
# to take a newer bundle, delete $STARCHORUS_DIR/starchorus-collect.sh (settings.conf is kept).
#
# SERVER: uhttpd may be present on the device (installed, not enabled at boot); the payload uses it when present,
# else python3, else the bundled nc mini-server. Without any server it still collects to starchorus.json; view it
# from a connected computer. A port that already has a listener (/proc/net/tcp, read-only) is not tried.
#
# TESTS ONLY: STARCHORUS_PROC (default /proc: uptime, net/tcp, PID/cmdline, PID/stat) and STARCHORUS_MARKER (default
# /tmp/starchorus.started) point the payload at stand-ins; STARCHORUS_FIRST_CAP (tenths of a second, default 200) is how long
# Start waits for the first capture before it opens the Overview anyway.
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
[ -z "${STARCHORUS_SURVEY:+x}" ] || PL_ENV="$PL_ENV survey"
[ -z "${STARCHORUS_PAGE:+x}" ] || PL_ENV="$PL_ENV page"
STARCHORUS_PORT=${STARCHORUS_PORT:-8199}
STARCHORUS_BIND=${STARCHORUS_BIND:-auto}                  # payload only: the page server's address (see BIND above)
export STARCHORUS_DIR STARCHORUS_PORT
export STARCHORUS_OUTDIR="$STARCHORUS_DIR"
export STARCHORUS_MAX_AGE="${STARCHORUS_MAX_AGE:-3600}"   # seconds of recon record per cycle (1 h, see WINDOW above); 0 = the whole record
export STARCHORUS_INTERVAL="${STARCHORUS_INTERVAL:-30}"   # seconds between two cycles
export STARCHORUS_VENDOR="${STARCHORUS_VENDOR:-1}"        # 1 = local vendor lookup (collector default)
export STARCHORUS_OWN="${STARCHORUS_OWN:-0}"              # 1 = own interface MACs from sysfs (read-only); environment only
export STARCHORUS_SURVEY="${STARCHORUS_SURVEY:-0}"        # 1 = channel busy time from the survey dump (read-only)
STARCHORUS_COLLECTOR=${STARCHORUS_COLLECTOR:-1}           # payload only, environment only: start the collector
STARCHORUS_PAGE=${STARCHORUS_PAGE:-1}                     # payload only: serve the page
STARCHORUS_DASHBOARD=${STARCHORUS_DASHBOARD:-1}           # payload only, environment only: open the Overview after Start (menu)

PL_KEYS="window interval port bind vendor survey page"
PL_FILE=""                     # keys that the settings file set with a valid value
PL_CR=$(printf '\r')
PL_PROC=${STARCHORUS_PROC:-/proc}                         # tests only (see TESTS ONLY above)
PL_MARK=${STARCHORUS_MARKER:-/tmp/starchorus.started}     # R7: the epoch of the last Start; tmpfs, so a reboot clears it
PL_PIDDIR=${STARCHORUS_PIDDIR:-$STARCHORUS_DIR}           # where the collector keeps its pidfiles (its own default: OUTDIR)

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
        vendor|survey|page) [ "$2" = on ] || [ "$2" = off ] ;;
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
        survey)    STARCHORUS_SURVEY=$(pl_bit "$2") ;;
        page)      STARCHORUS_PAGE=$(pl_bit "$2") ;;
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
        survey)    pl_onoff "$STARCHORUS_SURVEY" ;;
        page)      pl_onoff "$STARCHORUS_PAGE" ;;
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
# multi-MB line can stall the shell's read loop under bash 3.2; a real file has at most seven short lines).
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
# Dialogue texts carry their line break as the two characters \n, which the device's dialogues turn into a new line.
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
ui_prompt() { if [ "$ONDEV" = 1 ]; then PROMPT "$1" >/dev/null 2>&1; else printf '%s\n' "$1"; fi; return 0; }
ui_log() {    # ui_log [blue|red|green] TEXT
    case $1 in blue|red|green) pl_col=$1; shift ;; *) pl_col= ;; esac
    if [ "$ONDEV" = 1 ]; then LOG ${pl_col:+"$pl_col"} "$*" >/dev/null 2>&1; else printf '%s\n' "$*"; fi
}
# A spinner left up when the payload ends hangs the payload runner (a START_SPINNER child keeps the payload's stdout pipe
# open) and leaves the dialogue on the screen. pl_id holds the id of the spinner that is up, so that a TERM, an INT or an exit
# while it is up stops it first. The traps exist only for as long as a spinner does: a trapped signal waits for the foreground
# command to end, and the Overview, which runs as a foreground child for minutes, must stay killable at once (it ends at its
# next key press after that, by its own parent_gone check, and holds none of the payload's pipes meanwhile: see pl_overview).
# The callers call ui_spin_start without a command substitution: pl_id is set here.
ui_spin_start() {   # ui_spin_start LABEL -> pl_id = the spinner's id (empty off the device); one-word labels (firmware 1.0.4 and older)
    pl_id=
    [ "$ONDEV" = 1 ] || return 0
    pl_id=$(START_SPINNER "$1" 2>/dev/null)
    [ -z "$pl_id" ] || { trap 'ui_spin_stop "${pl_id:-}"' EXIT; trap 'exit 143' TERM; trap 'exit 130' INT; }
    return 0
}
ui_spin_stop() {   # ui_spin_stop ID -> the spinner is stopped, and with it the traps that guarded it
    [ "$ONDEV" = 1 ] && [ -n "$1" ] && STOP_SPINNER "$1" >/dev/null 2>&1
    pl_id=; trap - EXIT TERM INT
    return 0
}

# ui_qr URL MESSAGE -> the QR code of URL with MESSAGE under it; PROMPT with MESSAGE when PROMPT_QR is absent or fails
# at once. The order of PROMPT_QR's two arguments is not documented anywhere the payload can read for sure, so pl_qr_probe
# reads it from the command's own text (its usage line, or the variable its first argument lands in) without running it;
# when that says nothing, or the name fits both roles (qr_message), the URL alone is passed, which shows the right code
# whichever role the first argument has.
PL_QRO=""
pl_qr_probe() {   # -> PL_QRO = url (PROMPT_QR URL MESSAGE), message (PROMPT_QR MESSAGE URL) or one (PROMPT_QR URL)
    [ -n "$PL_QRO" ] && return 0
    PL_QRO=one
    pl_qp=$(command -v PROMPT_QR 2>/dev/null)
    case $pl_qp in /*) [ -r "$pl_qp" ] || return 0 ;; *) return 0 ;; esac
    pl_qo=$(head -c 65536 "$pl_qp" 2>/dev/null | tr -c '[:print:]\n' '\n' | awk '
        function role(w,  u, m) { w = tolower(w)
            u = (w ~ /(url|uri|data|qr|content|link|code)/); m = (w ~ /(message|msg|text|title|prompt|caption|label)/)
            if (u && m) return "?"                   # qr_message, qr_text: both words, so no sign either way
            if (u) return "url"
            if (m) return "message"
            return "" }
        o == "" && toupper($0) ~ /PROMPT_QR[ \t]+[[<{"]/ { s = substr($0, index(toupper($0), "PROMPT_QR") + 9)
            sub(/^[ \t]+[[<{"]/, "", s); sub(/[^A-Za-z_].*/, "", s); o = role(s) }
        o == "" && /^[ \t]*(local[ \t]+)?[A-Za-z_][A-Za-z_0-9]*="?\$\{?1([}" \t;]|$)/ { s = $0
            sub(/^[ \t]*(local[ \t]+)?/, "", s); sub(/=.*/, "", s); o = role(s) }
        END { print o }')
    case $pl_qo in url|message) PL_QRO=$pl_qo ;; esac
    return 0
}
# A key that leaves the QR code ends the command with a non-zero status on the Pager's pickers (B: 3), and a person takes
# longer than 0.6 s to press it: only a command that is absent, or that returns non-zero at once, gets the PROMPT.
ui_qr() {
    if [ "$ONDEV" != 1 ]; then printf '%s\n' "$2"; return 0; fi
    command -v PROMPT_QR >/dev/null 2>&1 || { ui_prompt "$2"; return 0; }
    pl_qr_probe
    pl_q0=$(pl_cs)
    case $PL_QRO in
        url)     PROMPT_QR "$1" "$2" >/dev/null 2>&1 ;;
        message) PROMPT_QR "$2" "$1" >/dev/null 2>&1 ;;
        *)       PROMPT_QR "$1" >/dev/null 2>&1 ;;
    esac
    pl_qc=$?
    [ "$pl_qc" = 0 ] || ! pl_quick "$pl_q0" "$(pl_cs)" || ui_prompt "$2"
    return 0
}

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
if [ ! -x "$STARCHORUS_DIR/starchorus-collect.sh" ]; then
    echo "Starchorus not installed in $STARCHORUS_DIR" >&2
    [ "$ONDEV" = 1 ] && ui_err "Starchorus is not installed."           # E1
    exit 1
fi
cd "$STARCHORUS_DIR" || exit 1

# ------------------------------------------------------------------ processes: identity, pidfiles, servers
# nice 19 for everything this payload starts (collector, page server, Overview): the single MIPS core belongs to the
# device's own interface first. Unquoted on purpose where it is used, so that $! stays the started program itself.
PL_NICE=""; command -v nice >/dev/null 2>&1 && PL_NICE="nice -n 19"
PL_PROCOK=0; [ -r "$PL_PROC/self/stat" ] && PL_PROCOK=1      # Linux: /proc decides; elsewhere (a dev machine) `ps`

# pl_own PID TEXT -> 0 iff PID is a running process whose command line contains TEXT. A pid read from a pidfile counts as
# ours only while it still is what we started: the collector's pidfiles live on eMMC and survive a reboot, after which
# their pid may name anything. /proc/PID/cmdline on the device (empty for a zombie or a kernel thread: not ours), the
# command line in `ps w` elsewhere (same idea as starchorus-serve.sh own_pid).
pl_own() {
    case $1 in ''|*[!0-9]*) return 1 ;; esac
    if [ "$PL_PROCOK" = 1 ]; then
        [ -r "$PL_PROC/$1/cmdline" ] || return 1
        pl_cl=$(tr '\000' ' ' 2>/dev/null < "$PL_PROC/$1/cmdline") || return 1
        case $pl_cl in *"$2"*) return 0 ;; esac
        return 1
    fi
    # shellcheck disable=SC2009  # busybox-safe; pgrep/pkill unreliable here
    ps w 2>/dev/null | awk -v p="$1" -v t="$2" '$1 == p && index($0, t) { f = 1 } END { exit !f }'
}

pl_pidof() {   # pl_pidof FILE TEXT -> the pid in FILE if it passes pl_own TEXT, else nothing
    pl_pv=; read -r pl_pv 2>/dev/null < "$1" || :
    pl_own "$pl_pv" "$2" && printf '%s\n' "$pl_pv"
    return 0
}
pl_loop_pid() { pl_pidof "$PL_PIDDIR/starchorus-loop.pid" starchorus-collect; }
pl_ad_pid() { pl_pidof "$PL_PIDDIR/starchorus-airodump.pid" airodump; }
pl_col_up() { [ -n "$(pl_loop_pid)" ]; }   # R6 COLLECTOR_UP: the loop pidfile names a live collector

# pl_clean_pids -> 2.1 step 3: a pidfile whose pid is not ours (gone, or reused by another process after a reboot) is
# deleted before anything reads it, so neither a false RUNNING nor a wrong kill can follow from it.
pl_clean_pids() {
    [ -n "$(pl_loop_pid)" ] || rm -f "$PL_PIDDIR/starchorus-loop.pid"
    [ -n "$(pl_ad_pid)" ] || rm -f "$PL_PIDDIR/starchorus-airodump.pid"
}

# pl_kids PID -> the pids of PID's children whose command is sleep: /proc/*/stat field 4 is the parent, field 2 the
# command in brackets (read up to the LAST ")", a command may hold one itself); `ps` where there is no /proc.
pl_kids() {
    case $1 in ''|*[!0-9]*) return 0 ;; esac
    if [ "$PL_PROCOK" = 1 ]; then
        # shellcheck disable=SC2016   # awk program
        cat "$PL_PROC"/[0-9]*/stat 2>/dev/null | awk -v p="$1" '{
            l = $0; o = index(l, " ("); c = 0; t = l
            while ((k = index(t, ")")) > 0) { c += k; t = substr(t, k + 1) }
            if (o == 0 || c <= o) next
            split(substr(l, c + 1), f, " ")
            if (substr(l, o + 2, c - o - 2) == "sleep" && f[2] == p) print $1 }'
    else
        ps -A -o pid= -o ppid= -o comm= 2>/dev/null | awk -v p="$1" '$2 == p && ($3 == "sleep" || $3 ~ /\/sleep$/) { print $1 }'
    fi
}
# pl_kill_sleeps LOOP_PID -> the collector loop sleeps in the foreground and BusyBox ash runs its TERM trap only after
# that sleep returns, so a stop would wait out the refresh interval: end the sleep, and the trap runs at once.
pl_kill_sleeps() { for pl_sk in $(pl_kids "$1"); do kill "$pl_sk" 2>/dev/null; done; }

pl_nap() { if sleep 0.5 2>/dev/null; then PL_NAP=5; else sleep 1; PL_NAP=10; fi; }   # PL_NAP = tenths of a second slept

# pl_fast_stop all|collector -> 2.8 steps 2 to 5: --stop (and, with all, our page servers), then the loop's sleep child,
# then up to 10 s for the loop pid read beforehand to go; kill -9 to it and to the airodump (both identity-checked) and
# 2 s more. 0 = gone (or nothing of ours ran), 1 = still alive. Leftover temporary files are swept by the next start.
pl_fast_stop() {
    pl_lp=$(pl_loop_pid); pl_ap=$(pl_ad_pid)          # read BEFORE --stop deletes the pidfiles
    if [ "$ONDEV" = 1 ]; then ./starchorus-collect.sh --stop >/dev/null 2>&1; else ./starchorus-collect.sh --stop; fi
    [ "$1" = collector ] || stop_servers
    [ -n "$pl_lp" ] || return 0
    pl_w=0; pl_k9=0
    while pl_own "$pl_lp" starchorus-collect; do
        pl_kill_sleeps "$pl_lp"
        if [ "$pl_w" -ge 100 ] && [ "$pl_k9" = 0 ]; then
            pl_own "$pl_lp" starchorus-collect && kill -9 "$pl_lp" 2>/dev/null
            pl_own "$pl_ap" airodump && kill -9 "$pl_ap" 2>/dev/null
            pl_k9=1
        fi
        [ "$pl_w" -ge 120 ] && return 1
        pl_nap; pl_w=$((pl_w + PL_NAP))
    done
    return 0
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

# pl_port_gone PORT... -> after a stop signal: up to 3 s (polled every 0.5 s, shared by all the ports) for whatever still
# listens on these ports to let go. A server at nice 19 on the single core may take a moment to handle its TERM, and a page
# server started on the same port in the meantime would find the port taken (pl_port_busy). Always 0: what is still there
# after the cap is for the next start to report.
pl_port_gone() {
    pl_g=0
    for pl_gp; do
        pl_valid port "$pl_gp" || continue
        while pl_port_busy "$pl_gp" 0.0.0.0 && [ "$pl_g" -lt 30 ]; do pl_nap; pl_g=$((pl_g + PL_NAP)); done
    done
    return 0
}

# Stop ONLY our own Starchorus web server(s): the current port, and the port that was actually served when the page last
# started (recorded in page.port, so a port change while the page ran does not orphan the old server). It never touches
# the device's own uhttpd on :80/:1471 (pl_pids requires our own -h directory). pkill -f is unreliable on busybox.
# It returns once the ports it sent a stop to are free again (pl_port_gone), so a restart can bind the same port at once.
stop_servers() {
    pl_pp=$(cat "$STARCHORUS_DIR/page.port" 2>/dev/null)
    pl_held=""                                                  # the ports a server was sent a stop for
    pl_hp=$(cat "$STARCHORUS_DIR/httpd.pid" 2>/dev/null)
    if pl_own "$pl_hp" "http.server"; then kill "$pl_hp" 2>/dev/null; pl_held="$pl_held ${pl_pp:-$STARCHORUS_PORT}"; fi   # only while it still is our python server
    rm -f "$STARCHORUS_DIR/httpd.pid"
    if [ -x "$STARCHORUS_DIR/starchorus-serve.sh" ]; then
        pl_hs=$(cat "$STARCHORUS_DIR/starchorus-serve.pid" 2>/dev/null)
        pl_own "$pl_hs" "starchorus-serve" && pl_held="$pl_held ${pl_pp:-$STARCHORUS_PORT}"
        "$STARCHORUS_DIR/starchorus-serve.sh" stop >/dev/null 2>&1
    fi
    for pl_pt in "$STARCHORUS_PORT" "$pl_pp"; do
        if [ -z "$pl_pt" ] || ! pl_valid port "$pl_pt"; then continue; fi
        for pl_sp in $(pl_pids "$pl_pt"); do kill "$pl_sp" 2>/dev/null; pl_held="$pl_held $pl_pt"; done
    done
    rm -f "$STARCHORUS_DIR/page.port" "$STARCHORUS_DIR/page.addr"
    # shellcheck disable=SC2086   # a word list of ports on purpose
    pl_port_gone $pl_held
}

# ------------------------------------------------------------------ start, status
# pl_lanaddr [quiet] -> the management address: `ip -4 -o addr` (read-only), the first inet address of br-lan; else
# 172.16.52.1 when an interface has it; else 127.0.0.1 with a note on stderr (not with quiet).
pl_lanaddr() {
    pl_ips=$(ip -4 -o addr 2>/dev/null)
    pl_a=$(printf '%s\n' "$pl_ips" | awk '$2 == "br-lan" || $2 ~ /^br-lan@/ { for (i = 3; i < NF; i++) if ($i == "inet") { a = $(i + 1); sub(/\/.*/, "", a); print a; exit } }')
    if [ "$pl_a" != 0.0.0.0 ] && pl_ipv4 "$pl_a"; then printf '%s\n' "$pl_a"; return 0; fi
    if printf '%s\n' "$pl_ips" | awk '{ for (i = 3; i < NF; i++) if ($i == "inet" && index($(i + 1), "172.16.52.1/") == 1) f = 1 } END { exit !f }'; then
        echo 172.16.52.1; return 0
    fi
    [ "$1" = quiet ] || echo "Starchorus: note: no br-lan address; the page listens on 127.0.0.1 only (set bind to an address, or to all)" >&2
    echo 127.0.0.1
}
# pl_addr [quiet] -> the IPv4 address the page server binds to, per STARCHORUS_BIND (see BIND above): auto = pl_lanaddr,
# an explicit address, or all -> 0.0.0.0, the only way to every interface.
pl_addr() {
    case $STARCHORUS_BIND in
        all)  echo 0.0.0.0; return 0 ;;
        auto) pl_lanaddr "$1" ;;
        *)    printf '%s\n' "$STARCHORUS_BIND" ;;
    esac
}
# pl_show_addr ADDR -> the address a phone uses: the management address for a server on every interface
pl_show_addr() { if [ "$1" = 0.0.0.0 ]; then pl_lanaddr quiet; else printf '%s\n' "$1"; fi; }

# pl_url ADDR PORT -> the address to open in a browser
pl_url() { if [ "$1" = 0.0.0.0 ]; then echo "http://<device-ip>:$2/ (all interfaces)"; else echo "http://$1:$2/"; fi; }

# pl_srv_prog -> 0 iff a server program for the page exists (uhttpd, python3, or the bundled nc mini-server and an nc)
pl_srv_prog() {
    command -v uhttpd >/dev/null 2>&1 && return 0
    command -v python3 >/dev/null 2>&1 && return 0
    [ -x "$STARCHORUS_DIR/starchorus-serve.sh" ] && command -v nc >/dev/null 2>&1
}

# pl_port_busy PORT ADDR -> 0 iff a socket already listens on PORT where a server on ADDR would collide: on ADDR itself, on
# every address (0.0.0.0 or ::), or anywhere when ADDR is 0.0.0.0. Read-only, /proc/net/tcp and tcp6 (state 0A = LISTEN;
# the address is printed in host byte order, so both orders are compared). No /proc/net (a dev machine): never busy.
pl_port_busy() {
    [ -r "$PL_PROC/net/tcp" ] || return 1
    cat "$PL_PROC/net/tcp" "$PL_PROC/net/tcp6" 2>/dev/null | awk -v port="$1" -v addr="$2" '
        BEGIN { ph = sprintf("%04X", port); n = split(addr, o, ".")
                fw = sprintf("%02X%02X%02X%02X", o[1], o[2], o[3], o[4]); rv = sprintf("%02X%02X%02X%02X", o[4], o[3], o[2], o[1]) }
        $4 == "0A" { k = index($2, ":"); if (k == 0 || toupper(substr($2, k + 1)) != ph) next
                     a = toupper(substr($2, 1, k - 1))
                     if (addr == "0.0.0.0" || a ~ /^0+$/ || a == fw || a == rv) f = 1 }
        END { exit !f }'
}

# Best-effort static server for the visualiser. Prefer a real server (uhttpd/python3); else use the bundled nc
# mini-server. start-stop-daemon detaches it cleanly so the payload runner returns. Every server listens on PL_ADDR
# (pl_addr) only, at nice 19; the address and port served are recorded in page.addr and page.port.
# 0 = a server was started (whether it holds the port shows in pl_page_up), 1 = no server program, 2 = the port is taken
# or the server refused to start.
pl_serve() {
    pl_srv_prog || {
        echo "Starchorus: no web server for the page -> $STARCHORUS_DIR/starchorus.json (view from a connected computer, or 'opkg install -d mmc uhttpd')" >&2
        return 1
    }
    PL_ADDR=$(pl_addr)
    if pl_port_busy "$STARCHORUS_PORT" "$PL_ADDR"; then
        echo "Starchorus: port $STARCHORUS_PORT is in use on $PL_ADDR; no page server started" >&2
        return 2
    fi
    # shellcheck disable=SC2086   # PL_NICE is "nice -n 19" or empty: split on purpose
    if command -v uhttpd >/dev/null 2>&1; then
        # uhttpd daemonises itself (no -f), so it detaches cleanly and stop_servers sweeps it by port and our directory.
        $PL_NICE uhttpd -p "$PL_ADDR:$STARCHORUS_PORT" -h "$STARCHORUS_DIR" || { echo "Starchorus: uhttpd could not listen on $PL_ADDR:$STARCHORUS_PORT" >&2; return 2; }
        pl_srvn=""
    elif command -v python3 >/dev/null 2>&1; then
        $PL_NICE python3 -m http.server "$STARCHORUS_PORT" --bind "$PL_ADDR" --directory "$STARCHORUS_DIR" >/dev/null 2>&1 & echo $! > "$STARCHORUS_DIR/httpd.pid"
        pl_srvn=""
    else
        # the mini-server gets the resolved address (or all), so it binds the same one; STARCHORUS_DIR/PORT are exported
        pl_sb=$PL_ADDR; [ "$PL_ADDR" = 0.0.0.0 ] && pl_sb=all
        if command -v start-stop-daemon >/dev/null 2>&1; then
            STARCHORUS_BIND=$pl_sb $PL_NICE start-stop-daemon -S -b -x "$STARCHORUS_DIR/starchorus-serve.sh"
        else
            STARCHORUS_BIND=$pl_sb $PL_NICE setsid "$STARCHORUS_DIR/starchorus-serve.sh" </dev/null >/dev/null 2>&1 &
        fi
        pl_srvn=" (nc mini-server)"
    fi
    printf '%s\n' "$STARCHORUS_PORT" > "$STARCHORUS_DIR/page.port" 2>/dev/null
    printf '%s\n' "$PL_ADDR" > "$STARCHORUS_DIR/page.addr" 2>/dev/null
    echo "Starchorus (passive) -> $(pl_url "$PL_ADDR" "$STARCHORUS_PORT")$pl_srvn" >&2
}

# pl_col_launch -> the collector loop, detached (setsid, nice 19) so it survives the payload runner returning; PL_COLPID = its pid
pl_col_launch() {
    # shellcheck disable=SC2086   # PL_NICE split on purpose
    $PL_NICE setsid ./starchorus-collect.sh </dev/null >/dev/null 2>collect.log &
    PL_COLPID=$!
}

# Start per settings: if anything of ours runs (an identity-checked loop or our page server) it is stopped first, so
# re-running never stacks duplicate collectors/servers; otherwise nothing is stopped and nothing waits. Then the marker
# and the services that are switched on. Sets PL_SERVED (0 = no page wanted, 1 = a page server was started, 2 = no
# server program, 3 = it could not start). With both services off it stops nothing: it prints a note and returns 1.
pl_start() {
    PL_SERVED=0; PL_COLPID=""
    if [ "$STARCHORUS_COLLECTOR" != 1 ] && [ "$STARCHORUS_PAGE" != 1 ]; then
        echo "Starchorus: no service on (collector=off, page=off)" >&2
        return 1
    fi
    if [ -n "$(pl_loop_pid)" ] || pl_page_up; then pl_fast_stop all; fi
    date +%s > "$PL_MARK" 2>/dev/null
    [ "$STARCHORUS_COLLECTOR" = 1 ] && pl_col_launch
    if [ "$STARCHORUS_PAGE" = 1 ]; then
        pl_serve; case $? in 0) PL_SERVED=1 ;; 1) PL_SERVED=2 ;; *) PL_SERVED=3 ;; esac
    fi
    [ "$STARCHORUS_COLLECTOR" = 1 ] && [ "$STARCHORUS_PAGE" != 1 ] && echo "Starchorus: collecting, no page -> $STARCHORUS_DIR/starchorus.json" >&2
    return 0
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

# pl_skew -> the "# Version:" and "# Contract:" headers of the installed collector and Overview against this payload's own;
# a difference is reported once per launch (dialogue and LOG on the device, stderr elsewhere) and nothing else changes. The
# contract number is the interface the three scripts share (the collector's --status/--stop/pidfile protocol, the
# Overview's environment): it changes with that interface, so a payload updated on its own is caught at the same version
# too. An installed file with a version but no contract line is contract 1, every build before the line existed; a file
# with no version header at all is not judged. The remedy named is tools/install.sh, or, where this payload's own directory
# carries the files (Hak5's library layout, no tools/ on the device), the one file whose absence makes the next run copy them.
pl_ver() { sed -n 's/^# Version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$1" 2>/dev/null | head -n 1; }
pl_con() { sed -n 's/^# Contract:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -n 1; }
pl_skew() {
    pl_me=$(pl_ver "$0"); [ -n "$pl_me" ] || pl_me=$(pl_ver "$PL_HOME/payload.sh")
    [ -n "$pl_me" ] || return 0
    pl_mc=$(pl_con "$0"); [ -n "$pl_mc" ] || pl_mc=$(pl_con "$PL_HOME/payload.sh"); pl_mc=${pl_mc:-1}
    if [ -f "$PL_HOME/starchorus-collect.sh" ] && [ "$PL_HOME" != "$STARCHORUS_DIR" ]; then
        pl_fd="Delete starchorus-collect.sh\nin $STARCHORUS_DIR."; pl_fn="delete $STARCHORUS_DIR/starchorus-collect.sh"
    else pl_fd="Run tools/install.sh."; pl_fn="run tools/install.sh"; fi
    for pl_f in starchorus-collect.sh starchorus-display.sh; do
        pl_v=$(pl_ver "$STARCHORUS_DIR/$pl_f")
        [ -n "$pl_v" ] || continue
        pl_c=$(pl_con "$STARCHORUS_DIR/$pl_f"); pl_c=${pl_c:-1}
        if [ "$pl_v/$pl_c" = "$pl_me/$pl_mc" ]; then continue; fi
        if [ "$ONDEV" = 1 ]; then
            if [ "$pl_v" = "$pl_me" ]; then pl_sk="Installed files differ from\nthe payload."; pl_sl="Installed files differ from the payload."
            else pl_sk="Installed $pl_v, payload $pl_me."; pl_sl=$pl_sk; fi
            ui_log red "$pl_sl"
            ui_err "$pl_sk\n$pl_fd"
        else echo "Starchorus: note: installed $pl_f is $pl_v (contract $pl_c), this payload is $pl_me (contract $pl_mc); $pl_fn" >&2; fi
        return 0
    done
}

# ------------------------------------------------------------------ menu (device only)
PL_CUR=""      # the row the cursor goes to at the next draw (its exact text, or a "Name:" prefix for a setting)
PL_ARMED=0     # 1 right after a spinner or the Overview: the debounce applies to the next main-menu answer
PL_IGN=0       # the answers the debounce has ignored in a row (at most three: a picker that fails at once must end the payload)

# pl_menu_pick TITLE CURSOR ROW... -> R5: the rows are built afresh by the caller before every call; the default is the
# row whose text is CURSOR (or, for a CURSOR ending in ":", the row it begins), else row 1. 1 = B.
pl_menu_pick() {
    pl_t=$1; pl_cur=$2; shift 2
    pl_def=""
    for pl_o; do [ "$pl_o" = "$pl_cur" ] && pl_def=$pl_o; done
    if [ -z "$pl_def" ]; then
        case $pl_cur in *:) for pl_o; do case $pl_o in "$pl_cur"*) [ -n "$pl_def" ] || pl_def=$pl_o ;; esac; done ;; esac
    fi
    [ -n "$pl_def" ] || pl_def=$1
    ui_pick "$pl_t" "$@" "$pl_def"
}

pl_cs() { awk '{ printf "%d\n", $1 * 100 }' "$PL_PROC/uptime" 2>/dev/null; }   # uptime in hundredths of a second
pl_quick() {   # pl_quick T0 T1 -> 0 iff both are readable and less than 0.6 s apart
    case $1$2 in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$1" ] && [ -n "$2" ] && [ $(($2 - $1)) -lt 60 ]
}

pl_ov_ok() { [ -r "$STARCHORUS_DIR/starchorus-display.sh" ] && command -v jq >/dev/null 2>&1; }   # the Overview row can be shown

# pl_overview -> 2.4: the Overview as a child process at nice 19 (no exec: B there comes back here). It gets the epoch of
# the last Start (a capture older than that counts as no data), the page's address, and this payload's pid, so that it ends at
# its next key press after the payload has gone: it waits for a key with no time limit and checks the pid when a key has been
# taken (once per pass, so before it arms the next wait, and again when its list returns).
# Its output goes to /dev/null for that reason: the payload runner reads the payload's stdout until EOF, so a child that keeps
# it open hangs the runner (as a spinner left up does, see ui_spin_start), and an Overview left waiting behind a killed
# payload would hold it open for as long as nobody presses a key. Nothing is lost: LOG and the pickers speak to the UI
# service, not to stdout (ui_log discards LOG's own output for the same reason), and the display gets the answers itself: its
# waiter, a background child that holds none of the payload's pipes either, leaves each key in a file in a private temp directory.
pl_overview() {
    PL_CUR=Overview; PL_ARMED=1
    [ -r "$STARCHORUS_DIR/starchorus-display.sh" ] || return 0
    command -v jq >/dev/null 2>&1 || { ui_err "Overview needs jq."; return 0; }      # E11; the row stays hidden
    pl_pu=""; pl_page_up && pl_pu="$(pl_show_addr "$PL_UPADDR"):$PL_UPPORT"
    pl_since=; read -r pl_since 2>/dev/null < "$PL_MARK" || :
    # shellcheck disable=SC2086   # PL_NICE split on purpose
    STARCHORUS_SINCE=$pl_since STARCHORUS_PAGE_URL=$pl_pu STARCHORUS_PARENT_PID=$$ $PL_NICE sh "$STARCHORUS_DIR/starchorus-display.sh" >/dev/null 2>&1
    PL_ARMED=1
}

pl_lastlog() {   # L7: the last line of collect.log, without the collector's prefix, cut to 40 characters (nothing if empty)
    pl_ll=$(sed -n '$p' "$STARCHORUS_DIR/collect.log" 2>/dev/null)
    pl_ll=${pl_ll#\[starchorus\] }
    [ -z "$pl_ll" ] || printf '%s\n' "$pl_ll" | cut -c1-40
}

# pl_wait_up WANTPAGE -> polls every 0.5 s until the collector is up (and, with WANTPAGE=1, the page too), 5 s at most; a
# collector still starting (the process we launched is alive, no pidfile yet) gets 5 s more. 0 = up, 1 = not.
pl_wait_up() {
    pl_w=0
    while :; do
        if pl_col_up; then
            [ "$1" = 1 ] || return 0
            pl_page_up && return 0
        fi
        if [ "$pl_w" -ge 50 ]; then
            pl_col_up && return 0                     # the page did not come up in time: the caller says so
            [ "$pl_w" -lt 100 ] && pl_own "$PL_COLPID" starchorus-collect || return 1
        fi
        pl_nap; pl_w=$((pl_w + PL_NAP))
    done
}
pl_wait_page() {   # pl_wait_page -> up to 5 s for our page server; 0 = up
    pl_w=0
    while ! pl_page_up; do
        [ "$pl_w" -ge 50 ] && return 1
        pl_nap; pl_w=$((pl_w + PL_NAP))
    done
    return 0
}
# pl_wait_capture -> the first capture of this Start: a starchorus.json that is not empty and not older than the marker (an
# earlier run's file does not count). Polled every 0.5 s for up to STARCHORUS_FIRST_CAP tenths of a second (default 200 = 20 s),
# and over at once when the collector has gone, since nothing more will come. 0 = it exists, 1 = not. The Overview never
# refreshes by itself, so Start keeps its spinner up meanwhile instead of opening it on "Waiting for the first scan.".
pl_wait_capture() {
    pl_wc=${STARCHORUS_FIRST_CAP:-200}
    case $pl_wc in ''|*[!0-9]*|??????*) pl_wc=200 ;; esac                 # digits only, at most five
    pl_cj=$STARCHORUS_DIR/starchorus.json
    pl_w=0
    while :; do
        # shellcheck disable=SC3013   # -ot is not POSIX, but BusyBox ash and dash both have it
        [ -s "$pl_cj" ] && [ ! "$pl_cj" -ot "$PL_MARK" ] && return 0
        pl_col_up || return 1
        [ "$pl_w" -lt "$pl_wc" ] || return 1
        pl_nap; pl_w=$((pl_w + PL_NAP))
    done
}
# pl_web_up -> start the page server and wait for it: 0 = up, 1 = no server program (E3), 2 = it did not start (E4)
pl_web_up() {
    pl_serve >/dev/null 2>&1; pl_sr=$?
    [ "$pl_sr" = 0 ] || return "$pl_sr"
    pl_wait_page && return 0
    stop_servers
    return 2
}
pl_e3() { ui_err "No web server found.\nThe Overview still works."; }
pl_e4() { ui_err "Web page did not start.\nPort $STARCHORUS_PORT may be in use."; }
pl_l2() { pl_page_up && ui_log blue "Web page: $(pl_show_addr "$PL_UPADDR"):$PL_UPPORT"; return 0; }

# 2.6 Start (no question)
pl_start_flow() {
    PL_ARMED=1; PL_CUR=Start
    ui_spin_start Starting
    pl_start >/dev/null 2>&1
    pl_wp=0; [ "$PL_SERVED" = 1 ] && pl_wp=1
    if ! pl_wait_up "$pl_wp"; then
        ui_spin_stop "$pl_id"
        pl_own "$PL_COLPID" starchorus-collect && kill "$PL_COLPID" 2>/dev/null
        pl_fast_stop all; rm -f "$PL_MARK"
        ui_err "Could not start.\nSee the log."                                   # E2
        pl_ll=$(pl_lastlog); [ -z "$pl_ll" ] || ui_log red "$pl_ll"                # L7
        return 0
    fi
    # only when the Overview is to open: it needs numbers; without them it would show "Waiting for the first scan." and stay so
    [ "$STARCHORUS_DASHBOARD" = 1 ] && pl_ov_ok && pl_wait_capture
    ui_spin_stop "$pl_id"
    case $PL_SERVED in
        2) pl_e3 ;;
        1|3) pl_page_up || { stop_servers; pl_e4; } ;;
    esac
    pl_l2
    PL_CUR=Overview
    [ "$STARCHORUS_DASHBOARD" = 1 ] && pl_overview
    return 0
}

# 2.8 Stop (no question)
pl_stop_flow() {
    PL_ARMED=1
    ui_spin_start Stopping
    if pl_fast_stop all; then
        ui_spin_stop "$pl_id"; rm -f "$PL_MARK"
        ui_log green "Stopped."                                                    # L3
        PL_CUR=Start
    else
        ui_spin_stop "$pl_id"
        ui_err "Could not stop. Try again."                                        # E5
        PL_CUR=Stop
    fi
}

# 2.7 the QR code of the page's address
pl_qr_flow() {
    PL_CUR="Open on Phone"
    pl_page_up || return 0
    pl_qa=$PL_UPADDR
    if [ "$STARCHORUS_BIND" = auto ] && [ "$(pl_lanaddr quiet)" != "$pl_qa" ]; then   # the management address has changed
        PL_ARMED=1
        ui_spin_start Applying
        stop_servers; pl_web_up; pl_sr=$?
        ui_spin_stop "$pl_id"
        case $pl_sr in 0) ;; 1) pl_e3; return 0 ;; *) pl_e4; return 0 ;; esac
        pl_l2
        pl_page_up || return 0
        pl_qa=$PL_UPADDR
    fi
    pl_qa=$(pl_show_addr "$pl_qa")
    if [ "$pl_qa" = 127.0.0.1 ]; then ui_err "No network address.\nConnect USB-C or Wi-Fi."; return 0; fi   # E6
    pl_qu="http://$pl_qa:$PL_UPPORT/"
    ui_qr "$pl_qu" "Scan with a phone that is\non the Pager's Wi-Fi.\n$pl_qu"
}

# "Start Web Page" (RUNNING, Web Page ON, no page up, a server program exists)
pl_web_flow() {
    PL_CUR="Start Web Page"; PL_ARMED=1
    ui_spin_start Starting
    pl_web_up; pl_sr=$?
    ui_spin_stop "$pl_id"
    case $pl_sr in 0) ;; 1) pl_e3; return 0 ;; *) pl_e4; return 0 ;; esac
    pl_l2
    pl_qr_flow
}

# ---- Settings (2.5)
pl_envvar() {   # pl_envvar KEY -> the environment variable behind a settings key
    case $1 in window) echo STARCHORUS_MAX_AGE ;; interval) echo STARCHORUS_INTERVAL ;; port) echo STARCHORUS_PORT ;;
        vendor) echo STARCHORUS_VENDOR ;; survey) echo STARCHORUS_SURVEY ;; page) echo STARCHORUS_PAGE ;; esac
}
pl_lock() { pl_has "$PL_ENV" "$1" && printf ' (locked)'; return 0; }                # " (locked)" when the environment sets KEY
pl_sw() { if [ "$(pl_value "$1")" = on ]; then echo ON; else echo OFF; fi; }      # R1: an ON/OFF value flips with one press
pl_save() {     # pl_save KEY VALUE -> saved (0), or E9 and nothing changed (1)
    pl_set "$1" "$2" && return 0
    ui_err "Could not save the setting."                                            # E9
    return 1
}
pl_applykeys() { for pl_k in interval window vendor survey port; do printf '%s=%s ' "$pl_k" "$(pl_value "$pl_k")"; done; }

pl_set_page() {   # Web Page: while RUNNING the flip applies at once; while STOPPED it only saves
    if [ "$STARCHORUS_PAGE" = 1 ]; then
        pl_save page off || return 0
        if pl_page_up; then ui_spin_start Applying; stop_servers; ui_spin_stop "$pl_id"; fi
        return 0
    fi
    if ! pl_col_up; then pl_save page on; return 0; fi
    ui_spin_start Applying
    pl_web_up; pl_sr=$?
    ui_spin_stop "$pl_id"
    case $pl_sr in 0) ;; 1) pl_e3; return 0 ;; *) pl_e4; return 0 ;; esac   # nothing saved, the row stays OFF
    pl_save page on || { stop_servers; return 0; }
    pl_l2
}

pl_set_list() {   # pl_set_list KEY TITLE ROW... -> sub-list of presets; the cursor on the current value (row 1 if custom)
    pl_lk=$1; pl_lt=$2; shift 2
    pl_cv=$(pl_value "$pl_lk"); pl_cd=""
    for pl_o; do [ "$(pl_preset "$pl_lk" "$pl_o")" = "$pl_cv" ] && pl_cd=$pl_o; done
    pl_s=$(pl_menu_pick "$pl_lt" "$pl_cd" "$@") || return 0
    pl_n=$(pl_preset "$pl_lk" "$pl_s")
    [ -n "$pl_n" ] && [ "$pl_n" != "$pl_cv" ] || return 0
    pl_save "$pl_lk" "$pl_n"
}
pl_preset() {     # pl_preset KEY ROW -> the seconds behind a preset row
    case $1:$2 in
        interval:"10 s") echo 10 ;; interval:"30 s") echo 30 ;; interval:"1 min") echo 60 ;; interval:"2 min") echo 120 ;;
        window:"2 min") echo 120 ;; window:"10 min") echo 600 ;; window:"1 h") echo 3600 ;; window:"6 h") echo 21600 ;;
        window:"All (may be slow)") echo 0 ;;
    esac
}

pl_settings() {
    pl_snap=$(pl_applykeys)
    pl_scur="Web Page:"
    while :; do
        pl_c=$(pl_menu_pick Settings "$pl_scur" \
            "Web Page: $(pl_sw page)$(pl_lock page)" \
            "Refresh: $(pl_wlab "$STARCHORUS_INTERVAL")$(pl_lock interval)" \
            "Show Last: $(pl_wlab "$STARCHORUS_MAX_AGE")$(pl_lock window)" \
            "Vendor Names: $(pl_sw vendor)$(pl_lock vendor)" \
            "Channel Load: $(pl_sw survey)$(pl_lock survey)" \
            "Port: $STARCHORUS_PORT$(pl_lock port)" \
            "Reset to Defaults") || break
        case $pl_c in
            "Web Page: "*)     pl_scur="Web Page:"; pl_k=page ;;
            "Refresh: "*)      pl_scur="Refresh:"; pl_k=interval ;;
            "Show Last: "*)    pl_scur="Show Last:"; pl_k=window ;;
            "Vendor Names: "*) pl_scur="Vendor Names:"; pl_k=vendor ;;
            "Channel Load: "*) pl_scur="Channel Load:"; pl_k=survey ;;
            "Port: "*)         pl_scur="Port:"; pl_k=port ;;
            *)                 pl_scur="Reset to Defaults"; pl_k=reset ;;
        esac
        case $pl_c in
            *" (locked)") ui_prompt "Set by $(pl_envvar "$pl_k").\nUnset it to change it here."; continue ;;   # P1
        esac
        case $pl_k in
            page)     pl_set_page ;;
            interval) pl_set_list interval "$pl_c" "10 s" "30 s" "1 min" "2 min" ;;
            window)   pl_set_list window "$pl_c" "2 min" "10 min" "1 h" "6 h" "All (may be slow)" ;;
            vendor)   if [ "$STARCHORUS_VENDOR" = 1 ]; then pl_save vendor off
                      elif pl_save vendor on; then ui_log "Vendor names: device makers."; fi ;;            # L8a
            survey)   if [ "$STARCHORUS_SURVEY" = 1 ]; then pl_save survey off
                      elif pl_save survey on; then ui_log "Channel load: busy time per"; ui_log "channel, in Air quality."; fi ;;   # L8b, L8c
            port)     if pl_n=$(ui_num Port "$STARCHORUS_PORT"); then
                          if ! pl_valid port "$pl_n"; then ui_err "Use 1024 to 65535, not 1471."               # E7
                          elif [ "$pl_n" != "$STARCHORUS_PORT" ]; then pl_save port "$pl_n"; fi
                      fi ;;
            reset)    if ui_confirm "Reset all settings?"; then pl_reset; pl_scur="Web Page:"; fi ;;             # C1
        esac
    done
    pl_apply "$pl_snap"
}

# pl_apply SNAPSHOT -> leaving Settings: what changed (a change flipped back is no change) is applied while the collector
# runs, under one spinner and without a question. Collector keys: a fast stop of the collector alone and a new start
# (marker kept). The port: a restart of the page server alone; if the new port does not start, the old one is restored.
pl_apply() {
    PL_CUR=Settings
    [ "$(pl_applykeys)" = "$1" ] && return 0
    pl_col_up || return 0
    PL_ARMED=1
    pl_cch=0; pl_pch=0; pl_op=""
    for pl_kv in $1; do
        pl_k=${pl_kv%%=*}
        [ "$(pl_value "$pl_k")" = "${pl_kv#*=}" ] && continue
        if [ "$pl_k" = port ]; then pl_pch=1; pl_op=${pl_kv#*=}; else pl_cch=1; fi
    done
    ui_spin_start Applying
    if [ "$pl_cch" = 1 ]; then
        PL_COLPID=""
        if ! pl_fast_stop collector || { pl_col_launch; ! pl_wait_up 0; }; then
            ui_spin_stop "$pl_id"
            pl_fast_stop all; rm -f "$PL_MARK"
            ui_err "Could not restart.\nSee the log."                                 # E10
            PL_CUR=Start
            return 0
        fi
    fi
    if [ "$pl_pch" = 1 ] && pl_page_up; then
        stop_servers
        if ! pl_web_up; then
            pl_np=$STARCHORUS_PORT
            pl_set port "$pl_op" >/dev/null 2>&1 || STARCHORUS_PORT=$pl_op
            pl_web_up
            ui_spin_stop "$pl_id"
            ui_err "Port $pl_np is in use.\nKept $pl_op."                              # E8
            return 0
        fi
    fi
    ui_spin_stop "$pl_id"
    ui_log blue "Settings applied."                                                    # L5
}

# R6 at every draw: a dead loop with the marker present stopped by itself (L6); a page server without a collector is a
# leftover and is stopped (L9)
pl_reconcile() {
    pl_col_up && return 0
    if [ -f "$PL_MARK" ]; then
        rm -f "$PL_MARK"
        ui_log red "Collector had stopped."; ui_log red "See collect.log."               # L6
    fi
    if pl_page_up; then stop_servers; ui_log "Stopped a leftover web page."; fi         # L9
    return 0
}

pl_bye() {   # L4: B on RUNNING leaves the payload; everything keeps running, and the log says where the page is
    ui_log blue "Still running."; ui_log blue "Open Starchorus to stop it."
    pl_l2
}

pl_menu() {
    if [ "$STARCHORUS_COLLECTOR" != 1 ]; then ui_err "Collector disabled by\nSTARCHORUS_COLLECTOR=0."; exit 1; fi   # E12
    pl_clean_pids
    ui_log blue "Starchorus listens only."                                              # L1
    pl_skew
    if pl_col_up; then PL_CUR=Overview; else PL_CUR=Start; fi
    while :; do
        pl_reconcile
        if pl_col_up; then
            pl_run=1; pl_t="Starchorus: Running"
            set --
            pl_ov_ok && set -- Overview
            if [ "$STARCHORUS_PAGE" = 1 ]; then
                if pl_page_up; then set -- "$@" "Open on Phone"
                elif pl_srv_prog; then set -- "$@" "Start Web Page"; fi
            fi
            set -- "$@" Stop Settings
        else
            pl_run=0; pl_t="Starchorus: Stopped"
            set -- Start Settings
        fi
        pl_t0=$(pl_cs)
        pl_c=$(pl_menu_pick "$pl_t" "$PL_CUR" "$@"); pl_rc=$?
        if [ "$PL_ARMED" = 1 ] && pl_quick "$pl_t0" "$(pl_cs)"; then
            case $pl_rc:$pl_c in 0:Start|0:Stop|[!0]*) PL_IGN=$((PL_IGN + 1)); [ "$PL_IGN" -gt 3 ] || continue ;; esac   # a queued press: drawn again
        fi
        PL_ARMED=0; PL_IGN=0
        if [ "$pl_rc" != 0 ]; then
            [ "$pl_run" = 1 ] && pl_bye
            exit 0
        fi
        PL_CUR=$pl_c
        case $pl_c in
            Start)            pl_start_flow ;;
            Overview)         pl_overview ;;
            "Open on Phone")  pl_qr_flow ;;
            "Start Web Page") pl_web_flow ;;
            Stop)             pl_stop_flow ;;
            Settings)         pl_settings ;;
        esac
    done
}

pl_usage() { echo "usage: payload.sh [start | stop | status | get [KEY] | set KEY VALUE | reset]   keys: $PL_KEYS" >&2; }

# ------------------------------------------------------------------ dispatch
case "$1" in
    "")
        [ "$ONDEV" = 1 ] && pl_menu
        pl_clean_pids; pl_skew
        pl_start; exit $? ;;
    start)
        pl_clean_pids; pl_skew
        pl_start; exit $? ;;
    stop)
        pl_clean_pids
        pl_fast_stop all; rm -f "$PL_MARK"
        echo "Starchorus stopped" >&2
        exit 0 ;;
    status)
        pl_clean_pids; pl_skew
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
