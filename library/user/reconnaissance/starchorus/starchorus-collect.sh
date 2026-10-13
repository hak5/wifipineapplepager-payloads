#!/bin/sh
#
# Title:        Starchorus passive collector
# Description:  STRICTLY PASSIVE, observation-only Wi-Fi recon collector. Listens for
#               beacons / probe requests / probe responses that are already being
#               broadcast and writes a JSON view of nearby access points and client
#               stations to starchorus.json for a visualisation front end.
#               It NEVER transmits an attack frame: no deauth/disassoc, no rogue/evil AP,
#               no injection, no association/connection, no channel jamming, no active
#               features of the device's AP service. It only RECEIVES what the air already carries.
# Author:       Starchorus
# Version:      0.1.0
# Category:     reconnaissance
# SPDX-License-Identifier: GPL-3.0-or-later
# Notes:        Monitor-mode capture (tcpdump / airodump-ng) and reading the already-passive
#               device's recon SQLite store are RX-only. `iw scan` transmits probe requests and
#               is therefore treated as ACTIVE: it is DISABLED by default and only runs if you
#               explicitly opt in with STARCHORUS_ALLOW_ACTIVE=1.
#
# ---------------------------------------------------------------------------------------------
# PASSIVITY CONTRACT (read this):
#   Allowed here      : monitor-mode RX (airodump-ng with NO injection, tcpdump, tshark),
#                       reading an existing recon SQLite DB read-only, channel *tuning*
#                       (receiver retuning is not a transmission).
#   Never done here   : aireplay/mdk (deauth), hostapd/airbase (rogue AP), hcxdumptool active,
#                       besside/wifite, associating to any BSS, AP-service impersonation / beacon
#                       responses / SSID pool broadcast. This script contains none of those.
# ---------------------------------------------------------------------------------------------
#
# USAGE:
#   ./starchorus-collect.sh            # run forever, rewrite the JSON every INTERVAL seconds
#   ./starchorus-collect.sh --once     # do a single scan/parse cycle, then exit  (good for crond)
#   ./starchorus-collect.sh --stop     # stop a previously started background instance (loop+airodump)
#   ./starchorus-collect.sh --status   # report whether a loop / airodump is running
#   ./starchorus-collect.sh --selftest # run offline self-tests with embedded sample data (no HW)
#   ./starchorus-collect.sh --help     # short help
#
# CONFIG (override via environment, e.g. `STARCHORUS_IFACE=wlan1mon ./starchorus-collect.sh`):
#   STARCHORUS_INTERVAL       Seconds between JSON rewrites.                 (default 5)
#   STARCHORUS_OUTDIR         Directory for starchorus.json.                      (default /tmp/starchorus)
#   STARCHORUS_IFACE          Monitor interface to use, or "auto" to detect. (default auto)
#   STARCHORUS_SOURCE         auto|capture|recondb|iwscan  data source.      (default auto)
#   STARCHORUS_RECON_DB       Path to recon SQLite DB, or "auto" to find it. (default auto)
#   STARCHORUS_ALLOW_ACTIVE   1 = allow the ACTIVE `iw scan` fallback.       (default 0 = never)
#   STARCHORUS_CREATE_MON     1 = allow creating a monitor VIF if none.      (default 1)
#   STARCHORUS_MAX_AGE        recon.db only: show only devices seen in the
#                        last N seconds (live-presence view). 0 = off,
#                        show the full accumulated history.             (default 0)
#   STARCHORUS_CAPDIR         Where capture files / DB work copy are written.(default $OUTDIR/cap)
#   STARCHORUS_PIDDIR         Where pidfiles live.                           (default $OUTDIR)
#   STARCHORUS_VENDOR         1 = add the optional "vendor" / "randomized" fields via a LOCAL,
#                        passive MAC-prefix (OUI) file lookup; 0 = never (no post-pass:
#                        the plain emitter JSON is published).          (default 1)
#   STARCHORUS_OUI_FILE       auto | path. auto tries, in order: /lib/hak5/oui.txt,
#                        /usr/share/nmap/nmap-mac-prefixes, /usr/share/macchanger/OUI.list,
#                        skipping any candidate whose format is not parsable. nmap / IEEE
#                        oui.txt / macchanger / Wireshark-manuf files work (also from a USB
#                        stick). Missing/unusable file => no "vendor" field ("randomized"
#                        is still derived from the MAC itself), one log line.  (default auto)
#   Everything that depends on device behaviour that is not verified yet is a FLAG, default OFF:
#   STARCHORUS_HOPINFO        1 = top-level "channels": [{"freq", "last_heard"}] from the recon.db `time`
#                        column (the front-end never calls an AP "gone" without it).  (default 0)
#   STARCHORUS_SURVEY         1 = add "busy_pct" / "noise" to channels[] from `iw dev IF survey dump`
#                        (read-only netlink dump; IF = STARCHORUS_SURVEY_IFACE or the monitor VIF). (default 0)
#   STARCHORUS_OWN            1 = center."own_bssids" (this device's interface MACs from
#                        /sys/class/net/*/address) and center."own_ssids" (ONLY from the file in
#                        STARCHORUS_OWN_SSID_FILE, one SSID per line -- never from the AP service's SSID pool). (default 0)
#   STARCHORUS_HOMING_BSSID   one access point to home in on: adds a top-level "homing": {"bssid","dbm","peak","t"} taken from that AP's row
#                        in the same document (a station / unknown / own BSSID is refused). Also read from the first line of
#                        $STARCHORUS_OUTDIR/homing.target (the device writes it). Coarse: one reading per cycle.  (default: none)
#   STARCHORUS_APCLI_RO       1 = apcli_ro() may run its three read-only AP-service CLI commands; nothing calls it
#                        in this release (spec §14.6). The refusal rules are self-tested.  (default 0)
#
# OPTIONAL JSON FIELDS (all additive; a field is simply ABSENT when unknown, never null):
#   AP     : "vendor" (string, from the OUI file, every source), "rate" (int, Mbit/s: airodump Speed,
#            or the highest legacy rate in a tcpdump beacon, <= 54: without -v tcpdump prints only the
#            Supported Rates IE), "last_seen" (int, Unix seconds, recon.db MAX(time), running schema
#            only; airodump's local-time text is deliberately NOT converted: DST-ambiguous). tcpdump
#            also fills "channel"/"freq"/"band" from "CH: n" (or the radiotap MHz prefix) and
#            "security" = "Secured"/"Open" from the PRIVACY bit.
#   client : "vendor", "randomized": true (locally-administered / private MAC, no lookup
#            done), "last_seen" (recon.db only). Same for associated and unassociated clients.
#   AP, recon.db only (never a station): "akm" (["psk","sae",...]), "cipher" ({"group", "pairwise": []}),
#            "auth" (["open","sae",...]) decoded from libwifi's encryption_info (layout pinned above
#            build_from_recondb); "security" says OWE for OWE, "WPA2-Enterprise"/"WPA3-Enterprise" for
#            802.1X AKMs, "WPA2 (TKIP)"/"WPA (TKIP)" for TKIP-only; "responded_ssids" (int >= 2: how many
#            different SSIDs this BSSID answered probes with).
#   center : "max_age" (int, the STARCHORUS_MAX_AGE window; 0 = the whole record) and "interval" (int, seconds
#            between rewrites), always; "own_bssids"/"own_ssids" with STARCHORUS_OWN=1.
#   NOT filled: "packets" (the meaning of wifi_device.packets is an open device question), "first_seen"
#            (the `time` column may be an upsert time), "width" (MHz), "phy" (a/b/g/n/ac/ax), "caps": no
#            passive source on the device carries them (recon.db has no such columns, tcpdump without -v
#            prints no HT/VHT/HE IEs, airodump CSV has no width column). OPTIONAL in the front-end contract.
#
# The exact monitor interface name, recon DB path, and available tools DIFFER per device.
# This script detects and degrades; see the "NOTES / DEVICE FACTS" section at the bottom.

# --------------------------------------------------------------------------- configuration
INTERVAL=${STARCHORUS_INTERVAL:-5}
OUTDIR=${STARCHORUS_OUTDIR:-/tmp/starchorus}
IFACE=${STARCHORUS_IFACE:-auto}
SOURCE=${STARCHORUS_SOURCE:-auto}
RECON_DB=${STARCHORUS_RECON_DB:-auto}
ALLOW_ACTIVE=${STARCHORUS_ALLOW_ACTIVE:-0}
CREATE_MON=${STARCHORUS_CREATE_MON:-1}
MAX_AGE=${STARCHORUS_MAX_AGE:-0}
CAPDIR=${STARCHORUS_CAPDIR:-$OUTDIR/cap}
PIDDIR=${STARCHORUS_PIDDIR:-$OUTDIR}
VENDOR=${STARCHORUS_VENDOR:-1}
OUI_FILE=${STARCHORUS_OUI_FILE:-auto}
# Device-dependent behaviour nobody has verified yet: flags, default OFF (docs/device-notes.md).
HOPINFO=${STARCHORUS_HOPINFO:-0}                  # 1 = top-level channels[] {freq,last_heard} from recon.db `time` (semantics unverified)
SURVEY=${STARCHORUS_SURVEY:-0}                    # 1 = add busy_pct/noise to channels[] from `iw dev IF survey dump` (read-only)
OWN=${STARCHORUS_OWN:-0}                          # 1 = center.own_bssids[] (interface MACs from sysfs) and center.own_ssids[] (a file, see below)
OWN_SSID_FILE=${STARCHORUS_OWN_SSID_FILE:-}       # one SSID per line; the ONLY source of own_ssids (never the AP service's SSID pool)
APCLI_RO=${STARCHORUS_APCLI_RO:-0}              # 1 = apcli_ro() may run its three read-only AP-service CLI commands (spec §14.6); nothing calls it
# The homing target: ONE access point the operator chose (this variable, or the first line of $OUTDIR/homing.target that the
# device writes). It only adds a top-level "homing" reading taken from the AP's row in the SAME document; a station, a BSSID
# not in this document's aps[] and one of our own transmitters are refused (no field, no error). Nothing is transmitted or looked up.
HOMING_BSSID=${STARCHORUS_HOMING_BSSID:-}         # "aa:bb:cc:dd:ee:ff" or empty (then $OUTDIR/homing.target, if it exists)
HOMING_PEAK=""; HOMING_POLLS=0               # peak hold across cycles (a new maximum resets, 12 quiet cycles decay it)

OUTFILE=$OUTDIR/starchorus.json
CAPPREFIX=$CAPDIR/starchorus
AIRODUMP_PIDFILE=$PIDDIR/starchorus-airodump.pid
LOOP_PIDFILE=$PIDDIR/starchorus-loop.pid
CENTER_LABEL="This device"

# Runtime state (filled in by setup)
MONIF=""            # the monitor interface we ended up using
CREATED_MON=0       # 1 if we created it and must tear it down on exit
CAP_METHOD=""       # airodump | tcpdump  (only meaningful when SOURCE resolves to capture)
RESOLVED=none
OUI_PATH=""         # resolved OUI file ("" = none found -> no vendor field)
OUI_CACHE=""        # $CAPDIR/oui-cache.txt once the vendor lookup is active ("" = no cache)
OUI_HDR=""          # header line the cache must carry for OUI_PATH (set by setup_vendor)
VENDOR_NEWF=""      # this instance's temp file of new cache lines (removed by cleanup)
CACHE_LOCKED=0      # lock depth: >0 while this instance holds $OUI_CACHE.lock (released by cleanup)
VENDOR_STATE=""     # last logged vendor-setup state: setup_vendor logs only when it changes
STARTED_AIRODUMP=0  # 1 if THIS instance started airodump (only then does cleanup stop it)
LOCK_BUDGET=100     # cache_lock: wait at most this long (0.1-s units) for a live holder
LOCK_BUSY_UNTIL=0   # epoch until which cache writes are skipped after a lock give-up (backoff)
LOCK_BUSY_LOGGED=0  # a lock give-up is logged once per episode, not every cycle

# --------------------------------------------------------------------------- small helpers
log() { printf '[starchorus] %s\n' "$*" >&2; }   # printf: dash/bash-as-sh echo would eat \t \b \n in paths
have() { command -v "$1" >/dev/null 2>&1; }

# Remove control bytes that would produce invalid JSON, keeping TAB(011) and LF(012).
# Strips NUL..BS, VT..US (incl CR) and DEL. `"` `\` `\t` are escaped later in awk.
clean_ctrl() { tr -d '\000-\010\013-\037\177'; }
RECON_TAB=$(printf '\t')   # recon.db column separator: the one control byte clean_ctrl keeps besides LF

# Is a PID alive?  kill -0 is POSIX and works under busybox, but it also FAILS (EPERM) for a live
# process of another user (a mixed-user dev box; the device runs everything as root), so a failed
# kill is double-checked against /proc (Linux) and `ps -p` (BSD/macOS; busybox rejects -p -> 1).
# A zombie counts as alive here (kill -0 succeeds until it is reaped); holder_alive() below is
# the stricter test used for the cache lock.
pid_alive() {
    [ -n "$1" ] || return 1
    case "$1" in *[!0-9]*) return 1 ;; esac
    kill -0 "$1" 2>/dev/null && return 0
    [ -d "/proc/$1" ] && return 0
    ps -p "$1" >/dev/null 2>&1
}

SELF_BASE=$(basename "$0" 2>/dev/null); [ -n "$SELF_BASE" ] || SELF_BASE=starchorus-collect.sh

# Is $1 the pid of a LIVE process that runs THIS script (a daemon loop or a `--once`)? Used for the
# cache lock: a lock directory survives kill -9 / power loss and -- on a persistent OUTDIR -- even
# a reboot, after which its pid may belong to a long-lived FOREIGN process (init, crond, the AP-service daemon)
# or, after a pid wrap, to anything. Judged by pid alone such a holder would be "live" forever and
# every cycle would pay the whole lock budget. So the command line must name the script:
# /proc/<pid>/cmdline on Linux (empty for a zombie / kernel thread -> not a holder), else
# `ps -p PID -o args=` (BSD/macOS; busybox has no -p -> falls through to `ps w`). Only when NO
# command line can be read at all is the holder assumed live (never break a live lock blindly).
holder_alive() {
    pid_alive "$1" || return 1
    if [ -d "/proc/$1" ]; then
        hc=$(tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null)
    else
        hc=$(ps -p "$1" -o args= 2>/dev/null)
        [ -n "$hc" ] || hc=$(ps w 2>/dev/null | awk -v p="$1" '$1==p')
        [ -n "$hc" ] || return 0
    fi
    case "$hc" in *"$SELF_BASE"*) return 0 ;; esac
    return 1
}

# Working directory of a live pid, read from /proc/PID/cwd (readlink; BusyBox has readlink). Falls
# back to "unknown directory" where /proc is absent (e.g. a macOS development machine).
loop_cwd() {
    _lc=$(readlink "/proc/$1/cwd" 2>/dev/null)
    if [ -n "$_lc" ]; then printf '%s\n' "$_lc"; else printf 'unknown directory\n'; fi
}

# 0 iff pid $1 descends from this shell ($$), following PPid in /proc/PID/status a few levels up. A
# forked subshell (a pipeline member, a command substitution) keeps the script's command line on
# BusyBox, so it looks like a collector loop in `ps w`; it is part of this run, never another loop.
# Without /proc (a macOS development machine) nothing counts as a descendant.
is_own_child() {
    _ic=$1; _id=0
    while [ "$_id" -lt 4 ]; do
        _ic=$(awk '/^PPid:/ { print $2; exit }' "/proc/$_ic/status" 2>/dev/null)
        [ -n "$_ic" ] && [ "$_ic" != 0 ] || return 1
        [ "$_ic" = "$$" ] && return 0
        _id=$((_id + 1))
    done
    return 1
}

# Kill every running collector DAEMON LOOP, with or without a pidfile (the backstop for the pidfile
# logic): command lines naming this script but NO "--" flag, so --stop/--once/--status/--selftest
# runs, including THIS one, never match; our own PID is skipped.
#
# One collector runs per device: a start or a stop stops every collector loop, not only this OUTDIR's,
# so the two never share the monitor interface / radio. That is deliberate but must be honest, so each
# loop this kills that is NOT the one named by this OUTDIR's pidfile is logged with its pid and working
# directory. $1 is the context ("stop" from --stop, "replace" at daemon start-up); $2, when given, is
# the pid of this OUTDIR's own loop (already reported by stop_pidfile), which is killed but not logged.
kill_loops() {
    _kl_ctx=${1:-stop}
    _kl_own=${2:-}
    # shellcheck disable=SC2009  # busybox pgrep/pkill -f are unreliable here; ps+grep is the portable way
    ps w 2>/dev/null | grep "$SELF_BASE" | grep -v grep | grep -v -- '--' | awk '{print $1}' | \
    while read -r p; do
        [ -n "$p" ] || continue
        [ "$p" = "$$" ] && continue
        is_own_child "$p" && continue   # this run's own subshells, e.g. the one running this loop
        if [ "$p" != "$_kl_own" ]; then   # the one named by this OUTDIR's pidfile is already accounted for
            _kl_dir=$(loop_cwd "$p")
            if [ "$_kl_ctx" = replace ]; then
                log "replaced collector loop pid $p in $_kl_dir: one collector per device"
            else
                log "also stopped collector loop pid $p in $_kl_dir (one collector per device)"
            fi
        fi
        kill "$p" 2>/dev/null
    done
}

# --------------------------------------------------------------------------- --stop / --status
stop_pidfile() {   # $1 = pidfile, $2 = label: kill the live pid it names (sets stopped=1), drop the file
    [ -f "$1" ] || return 0
    sp=$(cat "$1" 2>/dev/null)
    if pid_alive "$sp"; then
        kill "$sp" 2>/dev/null && log "stopped $2 pid $sp" && stopped=1
    fi
    rm -f "$1"
}
stop_instances() {
    stopped=0
    own_loop=$(cat "$LOOP_PIDFILE" 2>/dev/null)   # read before stop_pidfile removes the file: not re-reported by kill_loops
    stop_pidfile "$LOOP_PIDFILE" "collector loop"
    # backstop: any collector loop without a live pidfile (e.g. its pidfile was overwritten by a re-run)
    # shellcheck disable=SC2009  # see kill_loops(): ps+grep is the portable count here
    before=$(ps w 2>/dev/null | grep "$SELF_BASE" | grep -v grep | grep -v -- '--' | grep -vc "^ *$$ ")
    kill_loops stop "$own_loop"
    [ "${before:-0}" -gt 0 ] 2>/dev/null && stopped=1
    stop_pidfile "$AIRODUMP_PIDFILE" airodump
    [ "$stopped" = "1" ] || log "nothing running for this OUTDIR ($OUTDIR)"
}

status_pidfile() {   # $1 = label, $2 = pidfile
    if [ -f "$2" ] && pid_alive "$(cat "$2" 2>/dev/null)"; then
        log "$1 RUNNING (pid $(cat "$2"))"
    else
        log "$1 not running"
    fi
}
status_instances() {
    status_pidfile loop "$LOOP_PIDFILE"
    status_pidfile airodump "$AIRODUMP_PIDFILE"
    [ -f "$OUTFILE" ] && log "last JSON: $OUTFILE ($(wc -c < "$OUTFILE" 2>/dev/null) bytes)"
}

# --------------------------------------------------------------------------- interface setup
# Return the mgmt interface so we never touch the 2.4GHz management radio (phy0).
# On the device the mgmt AP interface is wlan0mgmt (often part of br-lan) and carries one of the
# two management addresses the awk below knows. We match the
# fixed names first, then fall back to whichever iface carries a known mgmt IP.
mgmt_iface() {
    if have iw; then
        iw dev 2>/dev/null | awk '
            /^[[:space:]]*Interface/ { ifc=$2 }
            ifc ~ /^wlan0(mgmt|cli|open|wpa|ent)?$/ { print ifc; exit }'
    fi
    if have ip; then
        ip -o addr show 2>/dev/null | awk '/172\.16\.52\.1|172\.16\.42\.1/{print $2; exit}'
    fi
}

# List interfaces that are ALREADY in monitor mode (the device's recon engine or a prior
# run may have created one). We prefer reusing these read-only rather than fighting them.
# On the device the tri-band recon radio (radio1) surfaces as wlan1mon; the 2.4GHz radio can
# surface wlan0mon; a staged USB adapter surfaces as wlan2mon. setup_monitor_iface() prefers
# wlan1mon among these.
existing_monitors() {
    if have iw; then
        iw dev 2>/dev/null | awk '
            /^[[:space:]]*Interface/ { ifc=$2 }
            /type monitor/           { print ifc }'
    fi
}

# Pick a base (managed) interface that is NOT the mgmt radio, to host a monitor VIF.
# Prefer the recon radio (wlan1*) over the 2.4GHz mgmt/client radio (wlan0*).
candidate_base_iface() {
    mg=$(mgmt_iface)
    if have iw; then
        iw dev 2>/dev/null | awk -v mg="$mg" '
            /^[[:space:]]*Interface/ { ifc=$2 }
            /type managed/ && ifc != mg {
                if (ifc ~ /^wlan1/) { print ifc; hit=1; exit }
                if (!n++) alt=ifc }
            END { if (!hit && n) print alt }'
    fi
}

# Create a monitor VIF on the recon adapter WITHOUT disturbing the mgmt link.
# We deliberately avoid `airmon-ng start` as a first resort because its check-kill can
# tear down processes on the mgmt radio; we add a VIF with `iw` instead.
create_monitor() {
    base=$1
    [ -z "$base" ] && return 1
    newif="${base}mon"
    if have iw; then
        phy=$(iw dev "$base" info 2>/dev/null | awk '/wiphy/{print "phy"$2; exit}')
        if [ -n "$phy" ]; then
            if iw phy "$phy" interface add "$newif" type monitor >/dev/null 2>&1; then
                have ip && ip link set "$newif" up 2>/dev/null
                have ifconfig && ifconfig "$newif" up 2>/dev/null
                printf '%s\n' "$newif"; return 0
            fi
        fi
    fi
    # Last resort: airmon-ng (may rename to <base>mon). Only if iw path failed.
    if have airmon-ng; then
        out=$(airmon-ng start "$base" 2>/dev/null)
        m=$(printf '%s\n' "$out" | awk 'tolower($0) ~ /monitor mode.*enabled|vif enabled/ {for(i=1;i<=NF;i++) if($i ~ /mon$/){print $i}}' | tail -1)
        [ -z "$m" ] && m="${base}mon"
        printf '%s\n' "$m"; return 0
    fi
    return 1
}

# Decide which monitor interface to capture on. Sets MONIF and CREATED_MON.
setup_monitor_iface() {
    if [ "$IFACE" != "auto" ]; then
        MONIF=$IFACE; CREATED_MON=0
        log "using user-specified interface: $MONIF"
        return 0
    fi
    mons=$(existing_monitors)
    if [ -n "$mons" ]; then
        # Prefer the device's tri-band recon monitor (wlan1mon) if present, so we read the same
        # radio the recon engine uses; otherwise take the first non-2.4 mon, else first.
        existing=$(printf '%s\n' "$mons" | grep -x 'wlan1mon' | head -1)
        [ -z "$existing" ] && existing=$(printf '%s\n' "$mons" | grep -v -x 'wlan0mon' | head -1)
        [ -z "$existing" ] && existing=$(printf '%s\n' "$mons" | head -1)
        MONIF=$existing; CREATED_MON=0
        log "reusing existing monitor interface: $MONIF (not created by us)"
        return 0
    fi
    if [ "$CREATE_MON" = "1" ]; then
        base=$(candidate_base_iface)
        if [ -n "$base" ]; then
            m=$(create_monitor "$base")
            if [ -n "$m" ]; then
                MONIF=$m; CREATED_MON=1
                log "created monitor interface $MONIF on base $base"
                return 0
            fi
        fi
        log "could not create a monitor interface (no non-mgmt adapter found?)"
    fi
    return 1
}

# --------------------------------------------------------------------------- recon DB locate
find_recon_db() {
    if [ "$RECON_DB" != "auto" ]; then
        [ -r "$RECON_DB" ] && { printf '%s\n' "$RECON_DB"; return 0; }
        return 1
    fi
    # Common locations first (cheap), then a bounded search. On the device the persistent
    # recon store is /root/recon/recon.db (== /mmc/root/recon/recon.db, same eMMC; confirmed
    # in the AP-service binary as "<reconpath>/recon.db"). Other firmware layouts use
    # /tmp/recon.db or /root/recon.db; we probe both families.
    for c in /root/recon/recon.db /mmc/root/recon/recon.db \
             /tmp/recon.db /root/recon.db /mmc/root/recon.db \
             /etc/pineapple/recon.db; do
        [ -r "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    # Bounded find: only the paths the device is likely to use, quiet, first hit wins.
    # (No /sd -- the device has internal eMMC only.)
    for root in /root /mmc /tmp /etc; do
        [ -d "$root" ] || continue
        f=$(find "$root" -maxdepth 4 -name 'recon.db' 2>/dev/null | head -1)
        [ -n "$f" ] && [ -r "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

# --------------------------------------------------------------------------- source decision
# Resolve SOURCE=auto to a concrete method, honouring the passivity contract and the
# single-recon-radio contention rule:
#   * a monitor iface we did NOT create may belong to the channel-hopping recon engine; a 2nd
#     capture on that PHY would fight it, so the engine's recon DB is preferred (zero contention);
#   * a monitor VIF of our OWN gets our own passive capture (self-contained).
# On the device this resolves to `recondb`: wlan1mon belongs to the Recon engine (CREATED_MON=0)
# and sqlite3 is pre-installed; airodump-ng is not, so the capture fallback there is tcpdump.
# Force a source with STARCHORUS_SOURCE=recondb|capture if auto guesses wrong.
# Sets the global RESOLVED (and, via setup_monitor_iface, MONIF/CREATED_MON): call it directly,
# never as `X=$(resolve_source)` -- a command substitution's subshell would discard those globals.
resolve_source() {
    # A forced source is honoured; capture still needs an interface.
    if [ "$SOURCE" != "auto" ]; then
        RESOLVED=$SOURCE
        [ "$RESOLVED" = "capture" ] && setup_monitor_iface
        return 0
    fi
    setup_monitor_iface
    dbpath=$(find_recon_db)
    if [ -n "$MONIF" ] && [ "$CREATED_MON" = "1" ] && { have airodump-ng || have tcpdump; }; then
        RESOLVED=capture; return 0
    fi
    if [ -n "$dbpath" ] && have sqlite3; then
        RESOLVED=recondb; return 0
    fi
    if [ -n "$MONIF" ] && { have airodump-ng || have tcpdump; }; then
        log "WARNING: capturing on pre-existing monitor $MONIF; if the device's recon engine"
        log "         owns this radio, channel-hop contention is possible (still RX-only)."
        RESOLVED=capture; return 0
    fi
    if [ "$ALLOW_ACTIVE" = "1" ] && have iw; then
        RESOLVED=iwscan; return 0
    fi
    RESOLVED=none
}

# --------------------------------------------------------------------------- capture: start
# airodump-ng is inherently passive: it RECEIVES beacons/probes/data headers and channel-hops
# to tune the receiver. It does NOT inject. We pass NO active/injection flags.
start_airodump() {
    [ -n "$MONIF" ] || return 1
    mkdir -p "$CAPDIR"
    rm -f "$CAPDIR"/starchorus-*.csv 2>/dev/null
    have ip && ip link set "$MONIF" up 2>/dev/null
    # --write-interval rewrites the CSV on a cadence; --output-format csv keeps it parseable.
    # --background 1 avoids curses; stdout/err are discarded.
    airodump-ng --write-interval 2 --output-format csv --background 1 \
        -w "$CAPPREFIX" "$MONIF" >/dev/null 2>&1 &
    echo $! > "$AIRODUMP_PIDFILE"
    CAP_METHOD="airodump"; STARTED_AIRODUMP=1
    log "started passive airodump-ng (pid $(cat "$AIRODUMP_PIDFILE")) on $MONIF"
    return 0
}

# --------------------------------------------------------------------------- teardown
# cleanup() only tidies up: a trap handler that merely returns does NOT terminate the shell (after a
# caught SIGTERM the interrupted `sleep` returns and the loop would resume as an orphan whose pidfile
# is gone), so the INT/TERM traps run cleanup AND exit; the EXIT trap runs cleanup alone. It clears
# the traps first so it never re-enters itself.
# INSTANCE-SCOPED: the EXIT trap fires for every `--once` too, and a crond `--once` regularly overlaps
# the daemon's cycle (DB copy + queries take a second or more on the device's MIPS CPU). So cleanup touches
# ONLY what THIS process created: its own pid-stamped temp files, the loop pidfile only if it names
# this pid, the airodump only if this instance started it -- never the daemon's half-written cycle
# (-> source=none for an interval) or its pidfile (-> --status "not running").
cleanup() {
    trap - INT TERM EXIT
    if [ "$STARTED_AIRODUMP" = "1" ] && [ -f "$AIRODUMP_PIDFILE" ]; then
        p=$(cat "$AIRODUMP_PIDFILE" 2>/dev/null)
        pid_alive "$p" && kill "$p" 2>/dev/null
        rm -f "$AIRODUMP_PIDFILE"
    fi
    [ "$(cat "$LOOP_PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$LOOP_PIDFILE"
    rm -f "$OUTFILE.tmp.$$" "$OUTFILE.tmp.$$.v" 2>/dev/null        # a cycle cut short by the signal
    [ -n "$VENDOR_NEWF" ] && rm -f "$VENDOR_NEWF" 2>/dev/null
    [ "${CACHE_LOCKED:-0}" -gt 0 ] 2>/dev/null && CACHE_LOCKED=1  # release fully, whatever the depth
    cache_unlock
    if [ "$CREATED_MON" = "1" ] && [ -n "$MONIF" ]; then
        # only the VIF we created; never the mgmt radio or a VIF we reused
        if have iw; then iw dev "$MONIF" del 2>/dev/null; fi
        log "removed monitor interface $MONIF"
    fi
}

# ============================================================================ AWK LIBRARIES
# Shared awk helpers, prepended to every JSON-emitting awk program so the emission stays identical
# across sources. POSIX/busybox-awk safe: no gensub, no asorti, no length(array), no {n} interval regex.
AWK_JSON_HELPERS='
    function jesc(s,   i,c,o,n){ o=""; n=length(s)
        for(i=1;i<=n;i++){ c=substr(s,i,1)
            if(c=="\\") o=o "\\\\"
            else if(c=="\"") o=o "\\\""
            else if(c=="\t") o=o "\\t"
            else o=o c }
        return o }
    function numval(v){ if(v ~ /^-?[0-9]+$/) return v; return "null" }
    function macfmt(s,   t,i,o){ t=s; gsub(/[^0-9A-Fa-f]/,"",t)
        if(length(t)==12){ o=""; for(i=1;i<=12;i+=2){ o=o (i>1?":":"") tolower(substr(t,i,2)) } return o }
        return s }
    function ismac(s){ return (length(s)==17 && s ~ /^[0-9A-Fa-f:]+$/) }
    function band_from_freq(f){
        if(f>=2400 && f<2500) return "2.4GHz"
        if(f>=4900 && f<5925) return "5GHz"
        if(f>=5925)           return "6GHz"
        return "" }
    function band_norm(b){
        if(b ~ /6/) return "6GHz"; if(b ~ /5/) return "5GHz"
        if(b ~ /2/) return "2.4GHz"; return "" }
    function band_from_ch(ch){ if(ch>=1 && ch<=14) return "2.4GHz"; if(ch>0) return "5GHz"; return "" }
    function ch_from_freq(f){
        if(f>=2412 && f<=2472) return int((f-2407)/5)
        if(f==2484) return 14
        if(f>=5000 && f<5925) return int((f-5000)/5)
        if(f==5935) return 2                          # 6GHz channel 2: the one odd centre (5935 MHz)
        if(f>=5950) return int((f-5950)/5)
        return "" }
    function freq_from_ch(ch){
        if(ch>=1 && ch<=13) return 2407+ch*5
        if(ch==14) return 2484
        if(ch>=15) return 5000+ch*5
        return "" }
    function freq_from_ch6(ch){                       # 6GHz: 5950 + 5*ch, except channel 2 = 5935 MHz
        if(ch==2) return 5935
        if(ch>=1) return 5950+ch*5
        return "" }
    # document pieces shared by every emitter (ts, center and src are set by each emitter via -v)
    function doc_head(){ printf "{\n  \"generated\": %s,\n  \"center\": {\"label\": \"%s\"},\n  \"source\": \"%s\",\n", ts, jesc(center), src }
    function ap_json(pbss,pssid,pch,pband,pfreq,prssi,psec,pextra,pcli){
        return sprintf("    {\"bssid\": \"%s\", \"ssid\": \"%s\", \"channel\": %s, \"band\": \"%s\", \"freq\": %s, \"rssi\": %s, \"security\": \"%s\"%s, \"clients\": [%s]}", pbss, pssid, pch, pband, pfreq, prssi, psec, pextra, pcli) }
    function cl_json(cmac,crssi,cextra){ return sprintf("    {\"mac\": \"%s\", \"rssi\": %s%s}", cmac, crssi, cextra) }
'

# ============================================================================ VENDOR LOOKUP
# PASSIVE, LOCAL, file-only: the first 3 MAC bytes (OUI-24) are looked up in an OUI text file
# that is already on the device (the firmware ships /lib/hak5/oui.txt; nmap and macchanger ship their
# own). Nothing is fetched, nothing is sent. Implemented as ONE awk post-pass over the finished
# emitter JSON (all sources get it for free, the emitters stay untouched):
#   * loads the persistent prefix cache $CAPDIR/oui-cache.txt  (PREFIX<TAB>vendor; an empty
#     vendor is a NEGATIVE entry = "not in the file", so it is never scanned for again),
#   * collects the prefixes of every "mac"/"bssid" value that is NOT yet cached,
#   * scans the OUI file ONCE for exactly those prefixes (stops early when all are found),
#   * appends the new hits + negatives to the cache, then rewrites the JSON lines, inserting
#     `, "vendor": "..."` right after the MAC value (jesc-escaped) or `, "randomized": true`
#     for locally-administered client MACs (U/L bit set: 2nd hex digit 2/6/A/E). Those are
#     never looked up: IEEE assigns no such OUIs and phones rotate them per network, which
#     would otherwise flood the negative cache and force a full file scan nearly every cycle.
#     An AP with a locally-administered BSSID (virtual/guest BSS) gets neither field.
# The cache header "# oui=<path> size=<bytes> mtime=<secs>" ties it to one file; a different,
# resized or rewritten file (or a cache > 20000 lines) restarts it, and a long-running daemon
# re-checks that every 120 cycles. Negative entries are written ONLY after a complete, error-free
# scan of the file (an unreadable/unplugged file must never poison the cache); the loader trusts
# only well-formed lines (6 upper hex, ONE tab, no further tab; control bytes stripped); each
# instance collects its new lines in its own temp file and merges them under a pid-stamped mkdir
# lock (a live holder is waited for, a dead one is broken), so a daemon loop and a crond `--once`
# do not tear or duplicate lines -- and should a lock ever be lost anyway, the strict loader still
# ignores a torn line and the merge drops duplicates. Any failure in this pass leaves the plain
# emitter JSON untouched -- vendor is optional by contract.
# Accepted file formats (one tolerant parser): nmap `AABBCC Vendor`, macchanger `AA BB CC VENDOR`,
# `AA:BB:CC - Vendor`, IEEE oui.txt `AA-BB-CC   (hex)<TAB>Vendor` / `AABBCC (base 16)<TAB>Vendor`,
# Wireshark manuf `AA:BB:CC<TAB>Short<TAB>Long Name`. `#` comments, CRLF, and MA-M/MA-S blocks
# (7/9 hex or /28, /36) are skipped; the first line for a prefix wins.
# A candidate is usable only if it is a regular file AND at least one of its first 300 lines
# parses as a prefix line (`AABBCC<ws>`, `AA:BB:CC`, `AA-BB-CC`, `AA BB CC`). Without this probe a
# file in an unknown format would silently turn every prefix into a negative cache entry and
# "vendor" would never appear, although a known-good file (nmap) sits right next to it.
file_usable() { [ -f "$1" ] && [ -r "$1" ] && [ -s "$1" ]; }   # a readable, non-empty regular file
oui_format_ok() {
    file_usable "$1" || return 1
    head -n 300 "$1" 2>/dev/null | grep -q -E \
        '^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][[:space:]]|^[0-9A-Fa-f][0-9A-Fa-f][ :-][0-9A-Fa-f][0-9A-Fa-f][ :-][0-9A-Fa-f][0-9A-Fa-f][[:space:]]'
}

# Modification time in Unix seconds ("" if unknown): busybox `date -r FILE` (the device), then
# GNU/busybox stat, then BSD/macOS stat. Used in the cache header so a rewritten OUI file of the
# SAME byte size (firmware update) still restarts the cache.
file_mtime() {
    m=$(date -r "$1" +%s 2>/dev/null)
    case "$m" in *[!0-9]*|"") m=$(stat -c %Y "$1" 2>/dev/null) ;; esac
    case "$m" in *[!0-9]*|"") m=$(stat -f %m "$1" 2>/dev/null) ;; esac
    case "$m" in *[!0-9]*|"") m="" ;; esac
    printf '%s' "$m"
}

# Prints the file to use and returns 0; 1 = none; 2 = the explicit STARCHORUS_OUI_FILE exists but is
# not parsable (setup_vendor logs that). Directories and empty files are never accepted.
# Paths are returned with printf, never echo: a POSIX echo (dash, bash as /bin/sh) interprets
# `\t` `\b` `\n` `\c` ... in a stick path like /mnt/b\ts and the mangled path opens nothing.
find_oui_file() {
    if [ "$OUI_FILE" != "auto" ]; then
        oui_format_ok "$OUI_FILE" && { printf '%s\n' "$OUI_FILE"; return 0; }
        file_usable "$OUI_FILE" && return 2
        return 1
    fi
    for c in /lib/hak5/oui.txt /usr/share/nmap/nmap-mac-prefixes /usr/share/macchanger/OUI.list; do
        oui_format_ok "$c" && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

# Called at startup (after CAPDIR exists) and again every 120 cycles by the daemon loop, so a
# replaced OUI file (firmware update, swapped USB stick) is picked up without a restart. Sets
# OUI_PATH / OUI_CACHE; logs only when the outcome changed. With STARCHORUS_VENDOR=0 the post-pass is
# never run (plain emitter JSON).
setup_vendor() {
    OUI_PATH=""; OUI_CACHE=""
    if [ "$VENDOR" != "1" ]; then
        [ "$VENDOR_STATE" = "off" ] || log "vendor lookup disabled (STARCHORUS_VENDOR=$VENDOR)"
        VENDOR_STATE="off"; return 0
    fi
    OUI_PATH=$(find_oui_file); fr=$?
    if [ -z "$OUI_PATH" ]; then
        if [ "$fr" = "2" ]; then
            st="bad:$OUI_FILE"
            [ "$VENDOR_STATE" = "$st" ] || log "warning: no usable OUI format in STARCHORUS_OUI_FILE=$OUI_FILE (expected nmap / IEEE / macchanger / manuf lines); JSON will carry no \"vendor\" field"
        else
            st="none"
            [ "$VENDOR_STATE" = "$st" ] || log "no OUI database found (STARCHORUS_OUI_FILE=$OUI_FILE); JSON will carry no \"vendor\" field"
        fi
        VENDOR_STATE=$st; return 0
    fi
    sz=$({ wc -c < "$OUI_PATH"; } 2>/dev/null | tr -d ' ')   # braces: the shell's own "cannot open" too
    mt=$(file_mtime "$OUI_PATH")
    hdr="# oui=$OUI_PATH size=${sz:-0} mtime=${mt:-0}"
    vc="$CAPDIR/oui-cache.txt"
    nl=0; [ -f "$vc" ] && nl=$(wc -l < "$vc" | tr -d ' ')
    if [ "$(head -n 1 "$vc" 2>/dev/null)" != "$hdr" ] || [ "${nl:-0}" -gt 20000 ] 2>/dev/null; then
        # (re)start the cache for this file -- under the lock, so a `--once` that is merging lines
        # gathered from the OLD file right now cannot slip them under the NEW header (cache_append
        # also re-checks the header against OUI_HDR once it holds the lock).
        OUI_CACHE=$vc; cache_lock
        { printf '%s\n' "$hdr" > "$vc"; } 2>/dev/null
        cache_unlock; OUI_CACHE=""
    fi
    OUI_HDR=$hdr
    if [ -w "$vc" ]; then
        OUI_CACHE=$vc
        cache_repair          # a crash mid-append may have left an unterminated last line
    fi
    st="$hdr|${OUI_CACHE:-nocache}"
    if [ "$VENDOR_STATE" != "$st" ]; then
        [ -n "$OUI_CACHE" ] || log "warning: cannot write $vc; vendor cache off (OUI file scanned every cycle)"
        log "vendor lookup: $OUI_PATH${OUI_CACHE:+ (cache $OUI_CACHE)}"
    fi
    VENDOR_STATE=$st
}

# awk body of the post-pass. Needs AWK_JSON_HELPERS (jesc) prepended. Environment: SC_CACHE (file or ""),
# SC_OUI (file or ""), SC_NEWF (append target for new cache lines, or ""), SC_TERM (see BEGIN).
# shellcheck disable=SC2016  # awk program text: $0 is awk's field, deliberately not expanded
AWK_VENDOR='
    function vtrim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
    function vstrip(s,   i,n,c,o){ o=""; n=length(s)      # drop control bytes (CTRL: 1-31, 127)
        for(i=1;i<=n;i++){ c=substr(s,i,1); if(index(CTRL,c)==0) o=o c }
        return o }
    function cload(l,   p,v){
        # STRICT: exactly 6 upper hex + ONE tab + a vendor without further tab. A torn, fused or
        # foreign line is ignored, so its prefix is simply looked up again. Control bytes in the
        # vendor part (bit rot, an editor that left a CR) are stripped -- served from the cache they
        # would otherwise make EVERY cycle emit invalid JSON. (The regex gate keeps the per-line
        # cost near zero for the usual plain-ASCII cache.)
        if(substr(l,1,1)=="#") return
        if(index(l,"\t")!=7) return
        p=substr(l,1,6); if(p !~ /^[0-9A-F]+$/) return
        v=substr(l,8); if(index(v,"\t")>0) return
        if(v ~ /[^ -~]/) v=vstrip(v)
        if(!(p in V)) V[p]=v }
    function vend(rest,   n,a,i,v){
        rest=vtrim(rest)
        if(substr(rest,1,5)=="(hex)")     rest=substr(rest,6)
        if(substr(rest,1,9)=="(base 16)") rest=substr(rest,10)
        rest=vtrim(rest)
        if(substr(rest,1,1)=="-") rest=substr(rest,2)
        rest=vtrim(rest)
        if(index(rest,"\t")>0){ n=split(rest,a,"\t"); v=""
            for(i=1;i<=n;i++){ if(vtrim(a[i])!="") v=vtrim(a[i]) }
            rest=v }
        return vstrip(rest) }
    function pfx(mac){ return toupper(substr(mac,1,2) substr(mac,4,2) substr(mac,7,2)) }
    function laa(mac){ return (substr(mac,2,1) ~ /[26AEae]/) }
    function ismac17(m){ return (m ~ /^[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]$/) }
    function collect(line,key,   pos,rest,mac,p,kl){ rest=line; kl=length(key)
        while((pos=index(rest,key))>0){ mac=substr(rest,pos+kl,17)
            if(ismac17(mac) && !laa(mac)){ p=pfx(mac); if(!(p in V)) want[p]=1 }
            rest=substr(rest,pos+kl+17) } }
    function enrich(line,key,iscl,   out,pos,rest,mac,p,ins,kl){ out=""; rest=line; kl=length(key)
        while((pos=index(rest,key))>0){ mac=substr(rest,pos+kl,17); ins=""
            if(ismac17(mac) && substr(rest,pos+kl+17,1)=="\""){
                if(laa(mac)){ if(iscl) ins=", \"randomized\": true" }
                else { p=pfx(mac); if((p in V) && V[p]!="") ins=", \"vendor\": \"" jesc(V[p]) "\"" } }
            out=out substr(rest,1,pos+kl+17) ins
            rest=substr(rest,pos+kl+18) }
        return out rest }
    BEGIN{ cache=ENVIRON["SC_CACHE"]; oui=ENVIRON["SC_OUI"]; newf=ENVIRON["SC_NEWF"]
        KM="\"mac\": \""; KB="\"bssid\": \""; n=0
        CTRL=sprintf("%c",127); for(i=1;i<=31;i++) CTRL=CTRL sprintf("%c",i)
        CR=sprintf("%c",13)
        if(cache!=""){
            # Lines are committed one behind: the LAST line is trusted only if the shell saw the
            # cache end with a newline (SC_TERM=1). A line cut off by a crash looks well-formed to
            # cload() and must not be served when cache_repair could not drop it (unwritable dir).
            have=0
            while((getline l < cache)>0){ if(have) cload(prev); prev=l; have=1 }
            if(have && ENVIRON["SC_TERM"]=="1") cload(prev)
            close(cache) } }
    { L[++n]=$0; collect($0,KM); collect($0,KB) }
    END{
        nw=0; for(p in want) nw++
        r=0
        if(nw>0 && oui!=""){
            while((r=(getline line < oui))>0){
                if(substr(line,length(line),1)==CR) line=substr(line,1,length(line)-1)
                if(!match(line,/^[0-9A-Fa-f]+/)) continue
                if(RLENGTH==6){ p=substr(line,1,6); rest=substr(line,7) }
                else if(RLENGTH==2 && line ~ /^[0-9A-Fa-f][0-9A-Fa-f][ :-][0-9A-Fa-f][0-9A-Fa-f][ :-][0-9A-Fa-f][0-9A-Fa-f]/){
                    p=substr(line,1,2) substr(line,4,2) substr(line,7,2); rest=substr(line,9) }
                else continue
                if(rest!="" && rest !~ /^[ \t]/) continue
                p=toupper(p)
                if(!(p in want)) continue
                delete want[p]; V[p]=vend(rest)
                if(newf!="") printf "%s\t%s\n", p, V[p] >> newf
                nw--; if(nw<=0) break }
            close(oui)
            # r<0: the file could not be opened/read (unplugged stick, permissions, i/o error) --
            # then nothing is known about the remaining prefixes, so NO negative entries; they are
            # simply tried again next cycle. Negatives only after a complete scan (r==0; r>0 means
            # every prefix was found and `want` is empty anyway).
            if(newf!=""){
                if(r>=0){ for(p in want){ printf "%s\t\n", p >> newf } }
                close(newf) } }
        for(i=1;i<=n;i++){ l=L[i]
            if(index(l,KM)>0) l=enrich(l,KM,1)
            if(index(l,KB)>0) l=enrich(l,KB,0)
            print l } }
'

# ---- cache write serialisation. Two instances can run at once (daemon loop + `--once` from crond,
# or two --once): every cache WRITE happens under a mkdir lock (atomic on every POSIX filesystem,
# busybox included). The holder writes its pid into $lock/pid, and staleness is judged by that
# pid, NOT by how long we have been waiting (a slow live holder -- a cache merge takes seconds on
# the device's MIPS CPU under load -- must never lose its lock):
#   * holder alive          -> a LIVE PROCESS RUNNING THIS SCRIPT (holder_alive; a reused pid of a
#                              foreign process, a zombie, are no holders): wait (0.2 s ticks; 1 s
#                              where sleep has no fractions), up to LOCK_BUDGET (10 s; a merge
#                              takes < 2 s even on the device), then give up THIS write (return 2;
#                              the lines are gathered again next cycle) -- never break a live lock.
#   * holder dead           -> break at once (killed inside the critical section).
#   * no pid (yet)          -> the holder is between mkdir and the pid write, or died right there,
#                              or the pid is our own from a previous incarnation of this pid
#                              (pid reuse; also a subshell sibling under --selftest): 3 s grace,
#                              then break.
#   * ours, still held      -> re-entrant: depth +1, return 0 at once (cache_unlock counts down).
#   * unbreakable           -> the lock's directory is not writable (ro remount after an FS error /
#                              power loss on the eMMC OUTDIR): it can be neither taken nor broken,
#                              so give up at once (return 2), not after the budget.
# A give-up (return 2) is logged ONCE per episode and starts a 60-s backoff during which every
# cache write is skipped without waiting (vendor is still served; the OUI file is scanned instead).
# Breaking = rename the lock dir away (atomic: of two waiters only one succeeds, the other just
# goes on spinning), verify the moved dir still names the dead pid (a fresh, live lock grabbed in
# between is put back), then delete it. A release race (holder rmdir'ed between our mkdir and the
# `-d` test) gets a second mkdir before we conclude that the directory cannot hold a lock at all
# (plain file in the way -- removed, it is never ours -- or unwritable dir: return 1, the caller
# goes on without a lock, a single instance needs none). Return 0 = locked.
lock_take() {   # one mkdir attempt on $lk; on success the lock is ours (pid file written)
    mkdir "$lk" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$lk/pid" 2>/dev/null
    CACHE_LOCKED=1; LOCK_BUSY_LOGGED=0
}
lock_give_up() {   # $1 = reason. Log once, start the backoff, return 2 (= skip this write).
    [ "$LOCK_BUSY_LOGGED" = "1" ] || log "vendor cache lock: $1; cache writes skipped for 60 s (vendor still served, OUI file scanned each cycle)"
    LOCK_BUSY_LOGGED=1
    lnow=$(date +%s 2>/dev/null)
    case "$lnow" in ""|*[!0-9]*) LOCK_BUSY_UNTIL=0 ;; *) LOCK_BUSY_UNTIL=$((lnow+60)) ;; esac
    return 2
}
cache_lock() {
    [ -n "$OUI_CACHE" ] || return 1
    lk="$OUI_CACHE.lock"; lw=0; lnp=0
    if [ "${CACHE_LOCKED:-0}" -gt 0 ] 2>/dev/null && [ "$(cat "$lk/pid" 2>/dev/null)" = "$$" ]; then
        CACHE_LOCKED=$((CACHE_LOCKED+1)); return 0      # re-entrant: we hold it already
    fi
    if [ "${LOCK_BUSY_UNTIL:-0}" -gt 0 ] 2>/dev/null; then
        lnow=$(date +%s 2>/dev/null)
        if [ -n "$lnow" ] && [ "$lnow" -lt "$LOCK_BUSY_UNTIL" ] 2>/dev/null; then return 2; fi
        LOCK_BUSY_UNTIL=0                                # backoff over: try again
    fi
    while :; do
        lock_take && return 0
        if [ ! -d "$lk" ]; then
            [ -f "$lk" ] && rm -f "$lk" 2>/dev/null
            lock_take && return 0
            [ -d "$lk" ] || return 1
        fi
        # A lock is in place. If its directory cannot be written (ro mount: access() says so even
        # for root) we can neither take nor break it -- not worth a single tick.
        [ -w "${lk%/*}" ] || { lock_give_up "lock directory ${lk%/*} not writable"; return 2; }
        hp=$(cat "$lk/pid" 2>/dev/null)
        if [ -n "$hp" ] && [ "$hp" != "$$" ] && holder_alive "$hp"; then
            lnp=0                                          # live holder: wait
        elif [ -n "$hp" ] && [ "$hp" != "$$" ]; then
            cache_break "$lk" "$hp"; lb=$?                 # dead / foreign holder: break, retry at once
            [ "$lb" = "0" ] && continue
            [ "$lb" = "3" ] && { lock_give_up "stale lock of pid $hp cannot be broken"; return 2; }
        elif [ "$lnp" -ge 30 ]; then
            cache_break "$lk" "$hp"; lb=$?                 # no pid / own stale pid for 3 s: break
            [ "$lb" = "0" ] && continue
            [ "$lb" = "3" ] && { lock_give_up "pid-less lock cannot be broken"; return 2; }
        fi
        [ "$lw" -lt "$LOCK_BUDGET" ] || { lock_give_up "held by live pid ${hp:-?} for over $((LOCK_BUDGET/10)) s"; return 2; }
        if sleep 0.2 2>/dev/null; then lstep=2; else sleep 1; lstep=10; fi
        lw=$((lw+lstep)); lnp=$((lnp+lstep))
    done
}
# Break the lock at $1 whose holder ($2 = pid we saw, "" = none) we found dead. Returns 0 when the
# lock is gone (removed by us or by another waiter meanwhile), 1 when it is still in place, 3 when
# nothing can be created next to it (ro / full directory): unbreakable, do not spin on it.
cache_break() {
    [ -d "$1" ] || return 0
    stdir=$(mktemp -d "$1.stale.XXXXXX" 2>/dev/null) || return 3
    if mv "$1" "$stdir/" 2>/dev/null; then
        lgot=$(cat "$stdir/${1##*/}/pid" 2>/dev/null)
        if [ -n "$lgot" ] && [ "$lgot" != "$2" ] && [ "$lgot" != "$$" ] && holder_alive "$lgot" && [ ! -e "$1" ]; then
            # a live holder took a fresh lock between our check and the rename: give it back
            mv "$stdir/${1##*/}" "$1" 2>/dev/null
            rm -rf "$stdir" 2>/dev/null
            return 1
        fi
    fi
    rm -rf "$stdir" 2>/dev/null
    [ -d "$1" ] && return 1
    return 0
}
cache_unlock() {
    if [ "${CACHE_LOCKED:-0}" -gt 1 ] 2>/dev/null; then CACHE_LOCKED=$((CACHE_LOCKED-1)); return 0; fi   # nested
    if [ "$CACHE_LOCKED" = "1" ] && [ -n "$OUI_CACHE" ]; then
        lk="$OUI_CACHE.lock"; hp=$(cat "$lk/pid" 2>/dev/null)
        # only OUR lock (or one whose pid file never made it): a waiter may have broken ours
        # legitimately while this process was stopped, and holds it now
        if [ -z "$hp" ] || [ "$hp" = "$$" ]; then rm -f "$lk/pid" 2>/dev/null; rmdir "$lk" 2>/dev/null; fi
    fi
    CACHE_LOCKED=0
}

# The cache must end with a newline. An unterminated last line (crash / power loss while
# appending) is DROPPED (the loader would otherwise trust a cut-off vendor name for good, and the
# next append would fuse two lines). cache_fix_unterminated expects the caller to hold the lock.
# An EMPTY (or missing) file counts as terminated: nothing can fuse with it, and cache_append
# re-creates the header in it (a header cut short by ENOSPC is dropped by the repair like any
# other line, leaving 0 bytes -- without this, every cycle until the 120-cycle re-check would scan
# the whole OUI file, take the lock and rewrite the empty cache for nothing).
file_terminated() { [ ! -s "$1" ] || [ "$(tail -c 1 "$1" 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; }
cache_terminated() { file_terminated "$OUI_CACHE"; }
cache_fix_unterminated() {
    cache_terminated && return 0
    sed '$d' "$OUI_CACHE" > "$OUI_CACHE.fix.$$" 2>/dev/null && mv -f "$OUI_CACHE.fix.$$" "$OUI_CACHE"
    rm -f "$OUI_CACHE.fix.$$" 2>/dev/null
}
cache_repair() {   # cheap lock-free check first; only a damaged cache takes the lock
    [ -n "$OUI_CACHE" ] && [ -s "$OUI_CACHE" ] || return 0
    cache_terminated && return 0
    cache_lock || return 0
    cache_fix_unterminated
    cache_unlock
}

# Append this instance's new lines ($1 = temp file of PREFIX<TAB>vendor lines). Only well-formed
# lines whose prefix is not in the cache yet are added (the other instance may have scanned the
# same prefixes meanwhile), so parallel instances never duplicate entries. The awk reads the
# cache completely (BEGIN) before its first line of output, and stdout is one small append.
cache_append() {
    cache_lock; lr=$?
    [ "$lr" = "2" ] && return 0      # lock given up (live holder past the budget / backoff): next cycle
    cache_fix_unterminated
    # A cache that is gone or empty (tmpfs cleaner, a header write cut short and then dropped by
    # the repair) gets its header back right here, under the lock; otherwise the header test below
    # would skip EVERY merge until the daemon's 120-cycle re-check runs setup_vendor again.
    [ -s "$OUI_CACHE" ] || { printf '%s\n' "$OUI_HDR" > "$OUI_CACHE"; } 2>/dev/null
    # Never append onto a cache whose last line is still unterminated (the fix above failed:
    # unwritable directory -- the lines would fuse), nor onto one that setup_vendor has meanwhile
    # restarted for another OUI file (our lines came from the old one).
    if ! cache_terminated || [ "$(head -n 1 "$OUI_CACHE" 2>/dev/null)" != "$OUI_HDR" ]; then
        cache_unlock; return 0
    fi
    nt=0; file_terminated "$1" && nt=1
    # The temp file's LAST line is merged only if the file ends with a newline (SC_TERM): a line
    # cut short by ENOSPC on /tmp or a killed awk would otherwise be persisted as a well-formed,
    # wrong vendor -- for good. Lines are therefore committed one behind.
    # shellcheck disable=SC2094  # awk finishes reading the cache in BEGIN before its first print
    clean_ctrl < "$1" | SC_CACHE="$OUI_CACHE" SC_TERM="$nt" awk '
        function wf(l){ return (index(l,"\t")==7 && substr(l,1,6) ~ /^[0-9A-F]+$/ && index(substr(l,8),"\t")==0) }
        function emit(l,   p){ if(!wf(l)) return; p=substr(l,1,6); if(p in seen) return; seen[p]=1; print l }
        BEGIN{ c=ENVIRON["SC_CACHE"]
            while((getline l < c)>0){ if(wf(l)) seen[substr(l,1,6)]=1 }
            close(c); have=0 }
        { if(have) emit(prev); prev=$0; have=1 }
        END{ if(have && ENVIRON["SC_TERM"]=="1") emit(prev) }' >> "$OUI_CACHE"
    cache_unlock
}

# Daemon start-up, right after kill_loops (no other loop is alive now): temp files a previous
# daemon left behind when it died hard (kill -9, power loss) are worthless -- sweep them, but ONLY
# those whose owner pid (embedded in the name: .new.<pid>.XXXXXX / .fix.<pid>) is not a live
# collector: a crond `--once` may be running right now, and kill_loops leaves it alone on purpose.
# The lock itself is swept when its pid is not a live collector either (holder_alive: dead, or a
# foreign process that inherited the number after a reboot on a persistent OUTDIR / a pid wrap);
# left in place, such a lock would cost every cycle the whole lock budget and the cache would
# never be written again. A pid-less lock is left to cache_lock's 3-s grace. (Not for --once.)
sweep_stale_cache_files() {
    for f in "$CAPDIR"/oui-cache.txt.new.* "$CAPDIR"/oui-cache.txt.fix.*; do
        [ -e "$f" ] || continue
        p=${f##*.new.}; p=${p##*.fix.}; p=${p%%.*}
        holder_alive "$p" || rm -f "$f" 2>/dev/null
    done
    rm -rf "$CAPDIR"/oui-cache.txt.lock.stale.* 2>/dev/null   # a lock breaker holds one for milliseconds
    lkd="$CAPDIR/oui-cache.txt.lock"
    if [ -d "$lkd" ]; then
        p=$(cat "$lkd/pid" 2>/dev/null)
        if [ -n "$p" ] && ! holder_alive "$p"; then
            log "removing stale vendor cache lock left by pid $p (not a live collector)"
            rm -rf "$lkd" 2>/dev/null
        fi
    fi
}

# stdin = emitter JSON, stdout = same JSON plus optional vendor/randomized. One awk process.
# Paths reach awk via ENVIRON, not -v: -v values get backslash-escape processing (a stick path
# like /mnt/b\s would be mangled and the file silently "missing"). The temp file is created HERE,
# per instance (mktemp): an awk `>>` that cannot open its target is FATAL and would throw the
# whole post-pass away -- if CAPDIR is not writable we merely skip the cache write.
# $1 = "defer": leave the gathered lines in VENDOR_NEWF for a later vendor_merge instead of
# merging them here -- run_cycle publishes the JSON FIRST and merges afterwards, so a contended
# cache lock (up to LOCK_BUDGET) delays the cache, never the visualisation.
add_vendor() {
    newf=""; VENDOR_NEWF=""; term=0
    if [ -n "$OUI_CACHE" ]; then
        # the temp name carries OUR pid: the daemon's start-up sweep removes only files of dead pids
        newf=$(mktemp "$OUI_CACHE.new.$$.XXXXXX" 2>/dev/null) || newf="$OUI_CACHE.new.$$.0"
        if printf '' > "$newf" 2>/dev/null; then VENDOR_NEWF=$newf; else newf=""; fi
        cache_repair
        cache_terminated && term=1      # tells the loader whether the cache's last line is whole
    fi
    SC_CACHE="$OUI_CACHE" SC_OUI="$OUI_PATH" SC_NEWF="$newf" SC_TERM="$term" awk "$AWK_JSON_HELPERS$AWK_VENDOR"
    arc=$?
    # Merge only after a clean pass: with rc != 0 (ENOSPC on /tmp, awk killed) the temp file may
    # hold a cut-off line -- and run_cycle discards that JSON anyway.
    if [ "$arc" != "0" ] || [ -z "$newf" ] || [ ! -s "$newf" ]; then
        [ -n "$newf" ] && rm -f "$newf" 2>/dev/null
        VENDOR_NEWF=""
    elif [ "$1" != "defer" ]; then
        vendor_merge
    fi
    return $arc
}
# Merge the lines a deferred add_vendor gathered (VENDOR_NEWF) into the cache and drop the temp
# file; with $1 = "discard" the lines are dropped unmerged (the pass's JSON was rejected).
vendor_merge() {
    if [ -n "$VENDOR_NEWF" ]; then
        [ "$1" = "discard" ] || cache_append "$VENDOR_NEWF"
        rm -f "$VENDOR_NEWF" 2>/dev/null
    fi
    VENDOR_NEWF=""
}

# --------------------------------------------------------------------------- JSON: airodump CSV
# airodump CSV has two comma-separated sections separated by a blank line:
#   AP section:      BSSID, First seen, Last seen, channel, Speed, Privacy, Cipher, Auth,
#                    Power(=RSSI dBm), #beacons, #IV, LAN IP, ID-length, ESSID, Key
#   Station section: Station MAC, First seen, Last seen, Power, #packets, BSSID, Probed ESSIDs
# Stations carry the associated AP BSSID (or "(not associated)"), giving us real client->AP
# links when the data frames were overheard. If none were, clients:[] is simply empty.
build_from_csv() {
    # shellcheck disable=SC2012  # need mtime order; busybox has no portable stat -c, ls -t is fine
    csv=$(ls -1t "$CAPDIR"/starchorus-*.csv 2>/dev/null | head -1)
    [ -s "$csv" ] || return 1
    clean_ctrl < "$csv" | awk -v ts="$1" -v center="$CENTER_LABEL" -v src="airodump-csv" \
      "$AWK_JSON_HELPERS"'
        function trim(s){ sub(/^[ ]+/,"",s); sub(/[ ]+$/,"",s); return s }
        BEGIN{ FS=","; mode=""; nap=0; nun=0 }
        /^[ ]*BSSID,/        { mode="ap";  next }
        /^[ ]*Station MAC,/  { mode="sta"; next }
        /^[ ]*$/             { next }
        mode=="ap" {
            bssid=trim($1)
            if(!ismac(bssid)) next
            chan=trim($4)+0
            spd=trim($5)        # airodump "Speed": max rate the AP advertises (-1 = unknown)
            priv=trim($6); ciph=trim($7); auth=trim($8)
            pow=trim($9)
            # ESSID is field 14; Key is the LAST field. Rejoin 14..NF-1 so ESSIDs that
            # themselves contain commas survive; drop the trailing Key column.
            essid=""
            hi = (NF>=15) ? NF-1 : NF
            for(i=14;i<=hi;i++){ essid = essid (i>14?",":"") $i }
            essid=trim(essid)
            sec=priv
            if(auth!="" && auth!="OPN") sec=sec "/" auth
            if(ciph!="") sec=sec "/" ciph
            if(sec=="" || sec=="OPN") sec="Open"
            f=freq_from_ch(chan); b=band_from_freq(f); if(b=="") b=band_from_ch(chan)
            ap_bssid[nap]=macfmt(bssid); ap_ssid[nap]=essid; ap_chan[nap]=chan   # aa:bb:.. like every source
            ap_band[nap]=b; ap_freq[nap]=f; ap_pow[nap]=pow; ap_sec[nap]=sec
            ap_rate[nap]=(spd ~ /^[0-9]+$/ && spd+0>0) ? spd+0 : ""
            ap_index[bssid]=nap   # for client association
            nap++
        }
        mode=="sta" {
            mac=trim($1)
            if(!ismac(mac)) next
            pow=trim($4)
            abss=trim($6)
            if(ismac(abss) && (abss in ap_index)){
                k=ap_index[abss]
                cli[k]=cli[k] (clic[k]?",":"") \
                    "{\"mac\": \"" jesc(macfmt(mac)) "\", \"rssi\": " numval(pow) "}"
                clic[k]++
            } else {
                un[nun]=macfmt(mac); unp[nun]=pow
                pl=""; pc=0; split("", ps)
                for(i=7;i<=NF && pc<8;i++){ v=trim($i); if(v=="" || (v in ps)) continue; ps[v]=1; pc++; pl=pl (pl!=""?", ":"") "\"" jesc(v) "\"" }
                unpr[nun]=pl; nun++
            }
        }
        END{
            doc_head(); printf "  \"aps\": [\n"
            for(i=0;i<nap;i++){
                extra=(ap_rate[i]!="") ? ", \"rate\": " ap_rate[i] : ""
                printf "%s%s\n", ap_json(jesc(ap_bssid[i]), jesc(ap_ssid[i]), numval(ap_chan[i]"" ), jesc(ap_band[i]),
                    (ap_freq[i]!="" && ap_freq[i]>0?ap_freq[i]:"null"), numval(ap_pow[i]), jesc(ap_sec[i]),
                    extra, (i in cli?cli[i]:"")), (i<nap-1?",":"")
            }
            printf "  ],\n  \"unassociated\": [\n"
            for(i=0;i<nun;i++)
                printf "%s%s\n", cl_json(jesc(un[i]), numval(unp[i]), (unpr[i]!="" ? ", \"probes\": [" unpr[i] "]" : "")), (i<nun-1?",":"")
            printf "  ]\n}\n"
        }'
    return 0
}

# --------------------------------------------------------------------------- JSON: tcpdump burst
# Passive fallback when airodump-ng is absent (the device default). Listens for one short burst
# per cycle and classifies MACs: beacon/probe-response source = AP; probe-request source =
# client. Client<->AP association is NOT derived here (left empty, which the schema allows),
# because reliably pairing data frames from tcpdump -e text is fragile.
build_from_tcpdump() {
    [ -n "$MONIF" ] || return 1
    have tcpdump || return 1
    have ip && ip link set "$MONIF" up 2>/dev/null
    burst=$INTERVAL
    [ "$burst" -lt 1 ] 2>/dev/null && burst=2
    tcpdump_burst "$burst" | parse_tcpdump_text "$1"
    return 0
}

# Grab one burst of management frames. `timeout` bounds it to one cycle. If timeout is missing
# we background tcpdump and kill it after $burst seconds. Split out so --selftest can feed text.
tcpdump_burst() {
    burst=$1
    filt='(type mgt subtype beacon) or (type mgt subtype probe-req) or (type mgt subtype probe-resp)'
    if have timeout; then
        timeout "$burst" tcpdump -i "$MONIF" -l -e -s 256 "$filt" 2>/dev/null
    else
        tf="$CAPDIR/tcpdump.$$"
        tcpdump -i "$MONIF" -l -e -s 256 "$filt" >"$tf" 2>/dev/null &
        tdpid=$!
        i=0
        while [ "$i" -lt "$burst" ]; do sleep 1; i=$((i+1)); done
        kill "$tdpid" 2>/dev/null
        cat "$tf" 2>/dev/null; rm -f "$tf"
    fi
}

# Parse tcpdump -e text (fed on stdin) into the JSON schema. Isolated for offline self-test.
parse_tcpdump_text() {
    clean_ctrl | awk -v ts="$1" -v center="$CENTER_LABEL" -v src="tcpdump" \
      "$AWK_JSON_HELPERS"'
        {
            line=$0
            # Split the line at the frame-type token. `head` = radiotap prefix (rate, MHz, dBm)
            # + addresses; `ssid` = the parenthesised SSID; `tail` = what tcpdump prints AFTER it:
            # "[rates Mbit]", ESS/IBSS, "CH: n", ", PRIVACY". AP attributes are searched in `tail`
            # ONLY and RSSI/SA in `head` ONLY. An SSID may itself contain ")" (valid, <= 32 bytes),
            # so the split is at the LAST ")" that is followed by one of those real fields (greedy
            # .*): tcpdump always prints them after the SSID, hence anything an SSID injects -- e.g.
            # "x) CH: 11, PRIVACY" -- stays inside `ssid`, verbatim, and never reaches `tail`.
            head=line; tail=""; ssid=""; tok=""
            if(match(line,/(Beacon|Probe Request|Probe Response) \(.*\)( \[| ESS| IBSS| CH:|, PRIVACY|$)/)){
                head=substr(line,1,RSTART-1); seg=substr(line,RSTART,RLENGTH); tail=substr(line,RSTART+RLENGTH)
                tok=seg; sub(/ \(.*$/,"",tok)
                sub(/^[^(]*\(/,"",seg)                  # seg = "SSID) <start of tail>" or "SSID)"
                i=length(seg); while(i>0 && substr(seg,i,1)!=")") i--
                tail=substr(seg,i+1) tail; ssid=substr(seg,1,i-1)
            } else if(match(line,/(Beacon|Probe Request|Probe Response)/)){
                head=substr(line,1,RSTART-1); tok=substr(line,RSTART,RLENGTH); tail=substr(line,RSTART+RLENGTH)
            }
            # RSSI (dBm), first match e.g. "-45dBm signal"
            rssi=""
            if(match(head,/-?[0-9]+dBm/)){ rssi=substr(head,RSTART,RLENGTH); sub(/dBm/,"",rssi) }
            # Source MAC (avoid {17} interval regex for old busybox awk; grab the run and clip 17)
            sa=""
            if(match(head,/SA:[0-9a-fA-F:][0-9a-fA-F:]*/)){ sa=substr(head,RSTART+3,17) }
            if(sa==""){ next }
            sa=macfmt(sa)
            isap = (tok=="Beacon" || tok=="Probe Response")
            isreq = (tok=="Probe Request")
            if(isap){
                ap_seen[sa]=1
                if(ssid!="") ap_ssid[sa]=ssid
                if(rssi!="" && (!(sa in ap_rssi) || rssi+0 > ap_rssi[sa]+0)) ap_rssi[sa]=rssi
                # DS Parameter Set channel "CH: n" (authoritative; LAST match -- the genuine field
                # is always printed last); radiotap "NNNN MHz" = the frequency the receiver was
                # tuned to (fallback, and 6GHz disambiguation).
                rest=tail; c=0
                while(match(rest,/ CH: [0-9]+/)){ c=substr(rest,RSTART+5,RLENGTH-5)+0; rest=substr(rest,RSTART+RLENGTH) }
                if(c>0) ap_ch[sa]=c
                if(match(head,/ [0-9][0-9][0-9][0-9] MHz/)){ f=substr(head,RSTART+1,4)+0; if(f>0) ap_fq[sa]=f }
                # Supported-Rates IE "[1.0* 2.0* ... 54.0 Mbit]" (last match): keep the highest (<= 54)
                rest=tail; seg=""
                while(match(rest,/\[[0-9. *]+ Mbit\]/)){ seg=substr(rest,RSTART+1,RLENGTH-2); rest=substr(rest,RSTART+RLENGTH) }
                if(seg!=""){ nr=split(seg,ra," ")
                    for(i=1;i<=nr;i++){ v=ra[i]; sub(/\*$/,"",v)
                        if(v ~ /^[0-9.]+$/ && int(v+0) > ap_rate[sa]+0) ap_rate[sa]=int(v+0) } }
                # Capability bits: PRIVACY (whole word in the genuine tail) => encrypted, else Open.
                if(tail ~ /(^|[ ,])PRIVACY([ ,]|$)/) ap_sec[sa]="Secured"
                else if(tail ~ / (ESS|IBSS)( |,|$)/ && ap_sec[sa]!="Secured") ap_sec[sa]="Open"
            } else if(isreq){
                cl_seen[sa]=1
                if(rssi!="" && (!(sa in cl_rssi) || rssi+0 > cl_rssi[sa]+0)) cl_rssi[sa]=rssi
                if(ssid!="" && !((sa SUBSEP ssid) in pseen) && pn[sa]<8){ pseen[sa SUBSEP ssid]=1; pn[sa]++; pr[sa]=pr[sa] (pr[sa]!=""?", ":"") "\"" jesc(ssid) "\"" }
            }
        }
        END{
            doc_head(); printf "  \"aps\": [\n"
            first=1
            for(m in ap_seen){
                r=(m in ap_rssi)?ap_rssi[m]:"null"
                s=(m in ap_ssid)?ap_ssid[m]:""
                c=(m in ap_ch)?ap_ch[m]:""; f=""
                if(c!=""){ f=((m in ap_fq) && ap_fq[m]>=5925) ? freq_from_ch6(c) : freq_from_ch(c) }
                else if(m in ap_fq){ f=ap_fq[m]; c=ch_from_freq(f) }
                b=(f!="")?band_from_freq(f):""
                extra=((m in ap_rate) && ap_rate[m]+0>0) ? ", \"rate\": " ap_rate[m] : ""
                printf "%s%s", (first?"":",\n"), ap_json(jesc(m), jesc(s), (c!=""?c:"null"), b, (f!=""?f:"null"), r,
                    ((m in ap_sec)?ap_sec[m]:""), extra, "")
                first=0
            }
            printf "\n  ],\n  \"unassociated\": [\n"
            first=1
            for(m in cl_seen){
                if(m in ap_seen) continue   # a device that also beacons is an AP, not a stray client
                r=(m in cl_rssi)?cl_rssi[m]:"null"
                printf "%s%s", (first?"":",\n"), cl_json(jesc(m), r, ((m in pr) ? ", \"probes\": [" pr[m] "]" : ""))
                first=0
            }
            printf "\n  ]\n}\n"
        }'
}

# --------------------------------------------------------------------------- JSON: recon DB
# SECONDARY passive source, and the PREFERRED one on the device: its recon radio wlan1mon belongs to
# the channel-hopping recon engine, so reading that engine's store is contention-free (and
# gives band via the freq column). The engine is RX-only; we open the DB READ-ONLY. One table `ssid`
# holds every observation; `type` is the 802.11 mgmt subtype: 8=beacon and 5=probe-response (APs),
# 4=probe-request (clients). Schema families, tried in this order:
#   * RUNNING firmware (OpenWrt 24.10.1, confirmed live): hash, wifi_device, scan, type, bssid,
#     ssid(BLOB), hidden, time, signal, freq, channel, encryption; client MACs join via
#     ssid.wifi_device -> wifi_device.hash(.mac).
#   * apmac/stamac schema (AP-service binary of the firmware image): UNIQUE(scan,type,apmac,stamac,ssid) with apmac/stamac/band and
#     no `bssid`/`channel`/`time` column; channel is derived from freq.
#   * legacy schema: table `aps` with a text privacy column, colon'd bssid and a channel.
# `encryption` is libwifi's encryption_info uint64 bitmask; awk's doubles lose bits above 2^53, so it
# is split IN SQL into small ints. The live DB is held by the AP-service daemon (journal_mode=MEMORY, so normally no
# -wal/-shm): it is COPIED before querying to avoid any lock contention.
# libwifi encryption_info layout, PINNED to libwifi (github.com/libwifi/libwifi) commit c38dbc8d7d7836759300a9512d80a3d2d3e41a4b
# (2026-01-23, "Bump version to 0.0.11"), file src/libwifi/core/misc/security.h. uint64 bit -> meaning:
#   1 WEP · 2 WPA · 3 WPA2 · 4 WPA3 (class bits; libwifi ALSO sets bit 4 for OWE)
#   5..17  group cipher   : 5 WEP40 · 6 TKIP · 7 reserved · 8 CCMP128 · 9 WEP104 · 10 BIP-CMAC128 · 11 not-allowed · 12 GCMP128 · 13 GCMP256 ·
#                           14 CCMP256 · 15 BIP-GMAC128 · 16 BIP-GMAC256 · 17 BIP-CMAC256
#   18..31 pairwise cipher: 18 group · 19 WEP40 · 20 TKIP · 21 reserved · 22 CCMP128 · 23 WEP104 · 24 BIP-CMAC128 · 25 not-allowed · 26 GCMP128 ·
#                           27 GCMP256 · 28 CCMP256 · 29 BIP-GMAC128 · 30 BIP-GMAC256 · 31 BIP-CMAC256
#   32..53 AKM            : 32 reserved · 33 1X · 34 PSK · 35 1X-FT · 36 PSK-FT · 37 1X-SHA256 · (38 unused) · 39 PSK-SHA256 · 40 TDLS · 41 SAE ·
#                           42 SAE-FT · 43 AP-PEER · 44 1X-SuiteB-SHA256 · 45 1X-SuiteB-SHA384 · 46 1X-FT-SHA384 · 47 FILS-SHA256 · 48 FILS-SHA384 ·
#                           49 FILS-SHA256-FT · 50 FILS-SHA384-FT · 51 OWE · 52 PSK-SHA384-FT · 53 PSK-SHA384
#   54..58 auth scheme    : 54 OPEN · 55 SHARED-KEY · 56 FAST-BSS · 57 SAE · 58 VENDOR
# (Bit 38 is genuinely skipped in that header: PSK_SHA256 is bit 39.) The four SQL splits ENC_GRP/ENC_PW/ENC_AKM/ENC_AUTH shift and mask
# these ranges; the awk name tables index them from 0 within each range.
recondb_query() {   # $1 = db path, $2 = sql: read-only, tab-separated, no header
    sqlite3 -readonly -noheader -separator "$RECON_TAB" "$1" "$2" 2>/dev/null
}
recondb_first() {   # $1 = db path, $2... = alternative queries (schema families): the first non-empty result
    rf_db=$1; shift
    for rf_q in "$@"; do
        rf_out=$(recondb_query "$rf_db" "$rf_q") && [ -n "$rf_out" ] && { printf '%s\n' "$rf_out"; return 0; }
    done
    return 1
}

build_from_recondb() {
    db=$(find_recon_db) || return 1
    have sqlite3 || return 1

    # Copy-before-query: never lock the live DB the Recon engine is writing to.
    mkdir -p "$CAPDIR" 2>/dev/null
    qdb="$CAPDIR/recon_copy.db"
    if cp "$db" "$qdb" 2>/dev/null; then
        [ -r "$db-wal" ] && cp "$db-wal" "$qdb-wal" 2>/dev/null
        [ -r "$db-shm" ] && cp "$db-shm" "$qdb-shm" 2>/dev/null
    else
        qdb="$db"   # fall back to reading the live DB read-only
    fi

    # Class bits -> small mask (WEP 2 / WPA 4 / WPA2 8 / WPA3 16; the SAE auth bit 57 counts as WPA3).
    # Text encryption values pass straight through.
    ENC="CASE WHEN typeof(encryption)='integer' THEN ((encryption & 30) | (CASE WHEN ((encryption>>57)&1)=1 THEN 16 ELSE 0 END)) ELSE encryption END"
    # The rest as four small non-negative ints (each < 2^22, exact in awk): group cipher bits 5..17, pairwise
    # 18..31, AKM 32..53, auth scheme 54..58 (table above). Text encryption values give '' and keep the class label.
    ENC_GRP="CASE WHEN typeof(encryption)='integer' THEN ((encryption>>5)&8191) ELSE '' END"
    ENC_PW="CASE WHEN typeof(encryption)='integer' THEN ((encryption>>18)&16383) ELSE '' END"
    ENC_AKM="CASE WHEN typeof(encryption)='integer' THEN ((encryption>>32)&4194303) ELSE '' END"
    ENC_AUTH="CASE WHEN typeof(encryption)='integer' THEN ((encryption>>54)&31) ELSE '' END"
    ENC5="($ENC_GRP), ($ENC_PW), ($ENC_AKM), ($ENC_AUTH)"
    # SSID as text with any tab/newline replaced by a space, so no SSID can break the TAB field split.
    SSD="replace(replace(CAST(ssid AS TEXT),char(9),' '),char(10),' ')"

    # Live-presence window (opt-in): with STARCHORUS_MAX_AGE>0 only observations from the last N seconds
    # count, so devices that have left drop off the map. `time` is Unix seconds; the cutoff comes from
    # the LOCAL clock (same UTC epoch as the recon engine's). AGE = predicate for single-table `ssid`
    # queries, AGE_S = the same for the wifi_device JOIN (where a bare `time` is ambiguous). Empty (no
    # filter) when the window is off or unusable.
    AGE=""; AGE_S=""
    if [ "$MAX_AGE" -gt 0 ] 2>/dev/null; then
        now=$(date +%s 2>/dev/null)
        if [ -n "$now" ] && [ "$now" -gt "$MAX_AGE" ] 2>/dev/null; then
            cut=$((now - MAX_AGE))
            AGE="AND time > $cut"
            AGE_S="AND s.time > $cut"
        fi
    fi

    # --- access points. 13 tab-separated cols: mac, ssid, freq, band, channel, signal, encryption,
    # hidden, last_seen ('' if unknown), then the four ENC5 splits. last_seen = MAX(time) per BSSID.
    # CAUTION (verified with sqlite3): the ssid/encryption/hidden/freq values are SQLite "bare columns"
    # and come from the MAX(signal) row ONLY while the query has exactly ONE aggregate. A second
    # MAX(time) in the same SELECT makes them arbitrary, so MAX(time) lives in a derived table joined on
    # bssid; the plain query (no `time` column) is the next fallback.
    # the legacy `aps` table differs across builds (signal vs rssi, encryption vs privacy); try each combo.
    APSSD="replace(replace(ssid,char(9),' '),char(10),' ')"
    rows=$(recondb_first "$qdb" \
        "SELECT s.bssid, $SSD, IFNULL(s.freq,''), '', IFNULL(s.channel,''), MAX(s.signal), ($ENC), IFNULL(s.hidden,0), IFNULL(t.last,''), $ENC5 FROM ssid s JOIN (SELECT bssid, MAX(time) AS last FROM ssid WHERE bssid IS NOT NULL AND bssid<>'' AND type IN (5,8) $AGE GROUP BY bssid) t ON t.bssid=s.bssid WHERE s.type IN (5,8) $AGE_S GROUP BY s.bssid" \
        "SELECT bssid, $SSD, IFNULL(freq,''), '', IFNULL(channel,''), MAX(signal), ($ENC), IFNULL(hidden,0), '', $ENC5 FROM ssid WHERE bssid IS NOT NULL AND bssid<>'' AND type IN (5,8) $AGE GROUP BY bssid" \
        "SELECT apmac, $SSD, IFNULL(freq,''), IFNULL(band,''), '', MAX(signal), ($ENC), IFNULL(hidden,0), '', $ENC5 FROM ssid WHERE apmac IS NOT NULL AND apmac<>'' AND type IN (5,8) $AGE GROUP BY apmac" \
        "SELECT bssid, $APSSD, '', '', IFNULL(channel,''), signal, encryption, 0, '', '', '', '', '' FROM aps" \
        "SELECT bssid, $APSSD, '', '', IFNULL(channel,''), signal, privacy, 0, '', '', '', '', '' FROM aps" \
        "SELECT bssid, $APSSD, '', '', IFNULL(channel,''), rssi, encryption, 0, '', '', '', '', '' FROM aps" \
        "SELECT bssid, $APSSD, '', '', IFNULL(channel,''), rssi, privacy, 0, '', '', '', '', '' FROM aps")
    [ -n "$rows" ] || return 1

    # --- unassociated stations: probe-request senders (type=4), best-effort. 3 cols: mac, signal,
    # last_seen ('' if unknown). Only the GROUP BY key is a bare column here, so two aggregates are safe.
    clirows=$(recondb_first "$qdb" \
        "SELECT w.mac, MAX(s.signal), IFNULL(MAX(s.time),'') FROM ssid s JOIN wifi_device w ON s.wifi_device=w.hash WHERE s.type=4 AND w.mac IS NOT NULL AND w.mac<>'' $AGE_S GROUP BY w.mac" \
        "SELECT w.mac, MAX(s.signal), '' FROM ssid s JOIN wifi_device w ON s.wifi_device=w.hash WHERE s.type=4 AND w.mac IS NOT NULL AND w.mac<>'' $AGE_S GROUP BY w.mac" \
        "SELECT stamac, MAX(signal), '' FROM ssid WHERE type=4 AND stamac IS NOT NULL AND stamac<>'' $AGE GROUP BY stamac")

    # --- probed SSIDs (optional "probes"): the network a station's probe request names -- received,
    # never sent. 2 cols: mac, ssid; one row per distinct pair, sorted (deterministic output).
    # Wildcard probes (empty SSID) skipped.
    prbrows=$(recondb_first "$qdb" \
        "SELECT w.mac, $SSD FROM ssid s JOIN wifi_device w ON s.wifi_device=w.hash WHERE s.type=4 AND w.mac IS NOT NULL AND w.mac<>'' AND s.ssid IS NOT NULL AND CAST(s.ssid AS TEXT)<>'' $AGE_S GROUP BY w.mac, 2 ORDER BY w.mac, 2" \
        "SELECT stamac, $SSD FROM ssid WHERE type=4 AND stamac IS NOT NULL AND stamac<>'' AND ssid IS NOT NULL AND CAST(ssid AS TEXT)<>'' $AGE GROUP BY stamac, 2 ORDER BY stamac, 2")

    # --- hop awareness (STARCHORUS_HOPINFO / STARCHORUS_SURVEY, default off): channels[] = per frequency the last
    # time anything was heard there (recon.db `time`; whether that is a first-seen or an upsert time is
    # an OPEN device question) and, with the survey flag, the driver's own busy percentage and noise
    # floor (`iw ... survey dump` is a read-only netlink dump). No channels[] => the front-end never
    # treats a BSSID's absence as "gone" or "stale".
    chj=""
    if [ "$HOPINFO" = "1" ] || [ "$SURVEY" = "1" ]; then
        chrows=""
        if [ "$HOPINFO" = "1" ]; then
            hop=$(recondb_query "$qdb" "SELECT freq, MAX(time) FROM ssid WHERE freq IS NOT NULL AND freq>0 AND time IS NOT NULL AND time>0 GROUP BY freq ORDER BY freq")
            [ -z "$hop" ] || chrows=$(printf '%s\n' "$hop" | awk -F"$RECON_TAB" '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {printf "H\t%s\t%s\n", $1, $2}')
        fi
        if [ "$SURVEY" = "1" ]; then
            sif=${STARCHORUS_SURVEY_IFACE:-$MONIF}
            if [ -n "$sif" ] && have iw; then
                sv=$(iw dev "$sif" survey dump 2>/dev/null | survey_rows)
                [ -z "$sv" ] || chrows=$(printf '%s\n%s' "$chrows" "$sv")
            fi
        fi
        chj=$(printf '%s\n' "$chrows" | channels_json)
    fi

    # --- multi-SSID responders: how many DIFFERENT SSIDs one BSSID answered probes with (type=5). A
    # count only, no SSID list; emitted as ap.responded_ssids when >= 2. Both column families.
    resprows=$(recondb_first "$qdb" \
        "SELECT bssid, COUNT(DISTINCT CAST(ssid AS TEXT)) FROM ssid WHERE type=5 AND bssid IS NOT NULL AND bssid<>'' AND ssid IS NOT NULL AND CAST(ssid AS TEXT)<>'' $AGE GROUP BY bssid HAVING COUNT(DISTINCT CAST(ssid AS TEXT))>1" \
        "SELECT apmac, COUNT(DISTINCT CAST(ssid AS TEXT)) FROM ssid WHERE type=5 AND apmac IS NOT NULL AND apmac<>'' AND ssid IS NOT NULL AND CAST(ssid AS TEXT)<>'' $AGE GROUP BY apmac HAVING COUNT(DISTINCT CAST(ssid AS TEXT))>1")

    printf '#STARCHORUS_APS#\n%s\n#STARCHORUS_CLIENTS#\n%s\n#STARCHORUS_PROBES#\n%s\n#STARCHORUS_RESP#\n%s\n' "$rows" "$clirows" "$prbrows" "$resprows" | clean_ctrl | \
      SC_CH="$chj" awk -v ts="$1" -v center="$CENTER_LABEL" -v src="recon-db" -v FSU="$RECON_TAB" \
      "$AWK_JSON_HELPERS"'
        # encryption -> security label. Numeric = the ENC class mask (WEP 2 / WPA 4 / WPA2 8 / WPA3 16).
        # Text = libwifi string ("WPA2", "WPA3", "OWE", ...) or legacy enum.
        function sec_of(e,   p,u){
            if(e ~ /^[0-9]+$/){
                e=e+0
                if(e==0) return "Open"
                p=""
                if(int(e/16)%2==1) p="WPA3"
                if(int(e/8)%2==1)  p=p (p?"/":"") "WPA2"
                if(int(e/4)%2==1)  p=p (p?"/":"") "WPA"
                if(int(e/2)%2==1)  p=p (p?"/":"") "WEP"
                return (p!="" ? p : "WPA2")
            }
            u=toupper(e)
            if(u=="" || u=="OPN" || u=="OPEN" || u=="[OPEN]" || u=="NONE") return "Open"
            if(u ~ /WPA3|SAE/){ return (u ~ /WPA2/) ? "WPA2/WPA3" : "WPA3" }
            if(u ~ /OWE/)  return "OWE"
            if(u ~ /WPA2/) return "WPA2"
            if(u ~ /WPA/)  return "WPA"
            if(u ~ /WEP/)  return "WEP"
            return e }
        # libwifi bit tables (see the comment above build_from_recondb); v = one of the small SQL-split ints, i = bit in that int.
        function bit(v,i){ return (v ~ /^[0-9]+$/) ? (int(v/P2[i])%2) : 0 }
        function names(v,tbl,n,   i,o){ o=""
            for(i=0;i<n;i++) if(bit(v,i) && tbl[i+1]!="-" && tbl[i+1]!="reserved") o=o (o!=""?", ":"") "\"" tbl[i+1] "\""
            return o }
        function first(v,tbl,n,   i){ for(i=0;i<n;i++) if(bit(v,i) && tbl[i+1]!="-" && tbl[i+1]!="reserved") return tbl[i+1]
            return "" }
        # security label from the class bits PLUS the AKM/cipher/auth detail. OWE first: libwifi sets the WPA3 class bit for OWE, so the
        # class alone calls an OWE network "WPA3". 802.1X AKMs -> "...-Enterprise". TKIP as the only pairwise cipher (or, without a
        # pairwise field, as the only group cipher) marks the label "(TKIP)". No AKM/auth field (text encryption) -> the class label.
        function sec_of2(e,grp,pw,akm,auth,   base,owe,sae,psk,ent,i,tk,aead){
            base=sec_of(e)
            if(akm !~ /^[0-9]+$/ && auth !~ /^[0-9]+$/) return base
            owe=bit(akm,19); sae=(bit(akm,9)||bit(akm,10)||bit(auth,3))
            psk=(bit(akm,2)||bit(akm,4)||bit(akm,7)||bit(akm,20)||bit(akm,21))
            ent=(bit(akm,1)||bit(akm,3)||bit(akm,5)); for(i=12;i<=18;i++) if(bit(akm,i)) ent=1
            if(owe && !psk && !sae && !ent) return "OWE"
            if(ent){ if(bit(akm,12)||bit(akm,13)||sae) return "WPA3-Enterprise"; if(base=="WPA") return "WPA-Enterprise"; return "WPA2-Enterprise" }
            if(pw ~ /^[0-9]+$/ && pw+0>0){ tk=bit(pw,2); aead=(bit(pw,4)||bit(pw,8)||bit(pw,9)||bit(pw,10)) }
            else { tk=bit(grp,1); aead=(bit(grp,3)||bit(grp,7)||bit(grp,8)||bit(grp,9)) }
            if(tk && !aead && base ~ /WPA/) return base " (TKIP)"
            return base }
        BEGIN{ FS=FSU; mode=""; nap=0; nun=0
            P2[0]=1; for(i=1;i<=31;i++) P2[i]=P2[i-1]*2
            split("reserved 1x psk 1x-ft psk-ft 1x-sha256 - psk-sha256 tdls sae sae-ft ap-peer 1x-suiteb-sha256 1x-suiteb-sha384 1x-ft-sha384 fils-sha256 fils-sha384 fils-sha256-ft fils-sha384-ft owe psk-sha384-ft psk-sha384", AKMN, " ")
            split("wep40 tkip reserved ccmp128 wep104 bip-cmac128 notallowed gcmp128 gcmp256 ccmp256 bip-gmac128 bip-gmac256 bip-cmac256", CGN, " ")
            split("group wep40 tkip reserved ccmp128 wep104 bip-cmac128 notallowed gcmp128 gcmp256 ccmp256 bip-gmac128 bip-gmac256 bip-cmac256", CPN, " ")
            split("open shared-key fast-bss sae vendor", AUTHN, " ") }
        /^#STARCHORUS_APS#$/     { mode="ap";  next }
        /^#STARCHORUS_CLIENTS#$/ { mode="cli"; next }
        /^#STARCHORUS_PROBES#$/  { mode="prb"; next }
        /^#STARCHORUS_RESP#$/    { mode="resp"; next }
        /^[ \t]*$/          { next }
        mode=="prb" {
            m=macfmt($1); ss=$2
            if($1=="" || ss=="" || (m SUBSEP ss) in pseen || pn[m]>=8) next
            pseen[m SUBSEP ss]=1; pn[m]++
            pr[m]=pr[m] (pr[m]!=""?", ":"") "\"" jesc(ss) "\""
            next
        }
        mode=="resp" { rm=macfmt($1); if(rm!="" && $2 ~ /^[0-9]+$/ && $2+0>1) rc[rm]=$2+0; next }
        mode=="ap" {
            mac=$1; ssid=$2; fr=$3; bnd=$4; ch=$5; sig=$6; enc=$7; hid=$8; last=$9; egrp=$10; epw=$11; eakm=$12; eauth=$13
            if(mac=="") next
            f=(fr ~ /^[0-9]+$/ && fr+0>0) ? fr+0 : ""
            if(f=="" && ch ~ /^[0-9]+$/ && ch+0>0) f=freq_from_ch(ch+0)
            b=(f!="")? band_from_freq(f) : ""
            if(b=="") b=band_norm(bnd)
            if(b=="" && ch ~ /^[0-9]+$/) b=band_from_ch(ch+0)
            c=(ch ~ /^[0-9]+$/ && ch+0>0) ? ch+0 : (f!="" ? ch_from_freq(f) : "")
            if(hid+0==1) ssid=""    # hidden network -> empty SSID (front-end convention)
            ap_mac[nap]=macfmt(mac); ap_ssid[nap]=ssid; ap_ch[nap]=c
            ap_band[nap]=b; ap_freq[nap]=f; ap_sig[nap]=sig; ap_sec[nap]=sec_of2(enc,egrp,epw,eakm,eauth)
            sx=""; t1=names(eakm,AKMN,22); t2=names(eauth,AUTHN,5); cg=first(egrp,CGN,13); t3=names(epw,CPN,14)
            if(t1!="") sx=sx ", \"akm\": [" t1 "]"
            if(cg!="" || t3!=""){ cj=""; if(cg!="") cj="\"group\": \"" cg "\""; if(t3!="") cj=cj (cj!=""?", ":"") "\"pairwise\": [" t3 "]"; sx=sx ", \"cipher\": {" cj "}" }
            if(t2!="") sx=sx ", \"auth\": [" t2 "]"
            ap_sx[nap]=sx
            ap_last[nap]=(last ~ /^[0-9]+$/ && last+0>0) ? last+0 : ""
            nap++
        }
        mode=="cli" {
            mac=$1; sig=$2; last=$3
            if(mac=="") next
            un_mac[nun]=macfmt(mac); un_sig[nun]=sig
            un_last[nun]=(last ~ /^[0-9]+$/ && last+0>0) ? last+0 : ""
            nun++
        }
        END{
            doc_head()
            if(ENVIRON["SC_CH"]!="") printf "  \"channels\": %s,\n", ENVIRON["SC_CH"]
            printf "  \"aps\": [\n"
            for(i=0;i<nap;i++){
                extra=(ap_last[i]!="") ? ", \"last_seen\": " ap_last[i] : ""
                extra=extra ap_sx[i]
                if(ap_mac[i] in rc) extra=extra ", \"responded_ssids\": " rc[ap_mac[i]]
                printf "%s%s\n", ap_json(jesc(ap_mac[i]), jesc(ap_ssid[i]), (ap_ch[i]!=""?numval(ap_ch[i]""):"null"), jesc(ap_band[i]),
                    (ap_freq[i]!="" && ap_freq[i]>0?ap_freq[i]:"null"), numval(ap_sig[i]), jesc(ap_sec[i]), extra, ""), (i<nap-1?",":"")
            }
            printf "  ],\n  \"unassociated\": [\n"
            for(i=0;i<nun;i++){
                extra=(un_last[i]!="") ? ", \"last_seen\": " un_last[i] : ""
                if(un_mac[i] in pr) extra=extra ", \"probes\": [" pr[un_mac[i]] "]"
                printf "%s%s\n", cl_json(jesc(un_mac[i]), numval(un_sig[i]), extra), (i<nun-1?",":"")
            }
            printf "  ]\n}\n"
        }'
    return 0
}

# --------------------------------------------------------------------------- JSON: iw scan (ACTIVE!)
# WARNING: `iw dev <iface> scan` TRANSMITS probe-request frames. That is ACTIVE, not passive,
# so it violates the strict passivity contract and is DISABLED unless STARCHORUS_ALLOW_ACTIVE=1.
# It also cannot enumerate client stations (APs only).
build_from_iwscan() {
    [ "$ALLOW_ACTIVE" = "1" ] || return 1
    have iw || return 1
    scanif=$IFACE; [ "$scanif" = "auto" ] && scanif=$(candidate_base_iface)
    [ -n "$scanif" ] || return 1
    log "ACTIVE iw scan on $scanif (transmits probe requests) -- opted in via STARCHORUS_ALLOW_ACTIVE=1"
    iw dev "$scanif" scan 2>/dev/null | clean_ctrl | awk -v ts="$1" -v center="$CENTER_LABEL" -v src="iw-scan-ACTIVE" \
      "$AWK_JSON_HELPERS"'
        function flush(   f,ch){
            if(bss==""){ return }
            f=freq+0; ch=ch_from_freq(f)
            band = band_from_freq(f)
            sec="Open"
            if(rsn && wpa) sec="WPA/WPA2"
            else if(rsn) sec="WPA2/WPA3"
            else if(wpa) sec="WPA"
            else if(wep) sec="WEP"
            out[n++]=ap_json(jesc(macfmt(bss)), jesc(ssid), (ch!=""?int(ch):"null"), band, (f>0?f:"null"),
                (haversig?sig:"null"), sec, "", "")
            bss=""; ssid=""; freq=0; sig=0; haversig=0; rsn=0; wpa=0; wep=0
        }
        BEGIN{ n=0 }
        /^BSS / { flush(); bss=substr($2,1,17); next }
        /freq:/ { for(i=1;i<=NF;i++) if($i=="freq:"){ freq=$(i+1) } }
        /signal:/ { for(i=1;i<=NF;i++) if($i=="signal:"){ sig=int($(i+1)); haversig=1 } }
        /SSID:/ { s=$0; sub(/^[^:]*SSID:[ ]?/,"",s); ssid=s }
        /RSN:/ { rsn=1 }
        /WPA:/ { wpa=1 }
        /Privacy/ { wep=1 }   # capability Privacy w/o RSN/WPA implies WEP
        END{
            flush()
            doc_head(); printf "  \"aps\": [\n"
            for(i=0;i<n;i++) printf "%s%s", out[i], (i<n-1?",\n":"\n")
            printf "  ],\n  \"unassociated\": [\n\n  ]\n}\n"
        }'
    return 0
}

# --------------------------------------------------------------------------- spec §14.6: the AP-service CLI allowlist
# The ONLY functions in which an AP-service CLI command may be written (tools/passivity-check.sh lists them in SEC6_FUNCS and greps every
# other line of the collector, both starchorus-display.sh, payload.sh and library/** for `_pineap`, PINEAPPLE_, WIGLE_, DEAUTH, SSID_POOL,
# GPS_GET). Three LITERAL command lines, no eval, no variable command name. Nothing calls apcli_ro yet: `recon_aps`/`recon_clients`
# wait for a per-command device verification, `monitor` is the read side of the homing meter. rc 0 = ran, 2 = refused, 3 = flag off.
apcli_ro() {
    [ "$APCLI_RO" = "1" ] || return 3
    case "$1" in
        recon_aps)     [ $# -eq 1 ] || return 2; _pineap RECON APS format=json ;;
        recon_clients) [ $# -eq 1 ] || return 2; _pineap RECON CLIENTS format=json ;;
        monitor)
            [ $# -eq 2 ] || return 2
            pb=$2
            printf '%s' "$pb" | grep -Eq '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' || return 2
            case $(printf '%s' "$pb" | cut -c2) in [13579bdf]) return 2 ;; esac       # group/multicast address (low bit of octet 1)
            [ -r "$OUTFILE" ] || return 2
            grep -q "\"bssid\": \"$pb\"" "$OUTFILE" || return 2                      # must be an AP of the current document ...
            ! grep -q "\"mac\": \"$pb\"" "$OUTFILE" || return 2                       # ... never a station
            ! grep -q "\"own_bssids\": \[[^]]*\"$pb\"" "$OUTFILE" || return 2         # ... and never one of our own transmitters
            ! own_bssids | grep -qx "$pb" || return 2
            _pineap MONITOR "$pb" any rate=200 timeout=120 ;;
        *) return 2 ;;
    esac
}
# selftest support: an executable `_pineap` stub in directory $1 that appends its argv to file $2 (one line per call).
apcli_stub() {
    mkdir -p "$1" && printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$2" > "$1/_pineap" && chmod +x "$1/_pineap"
}
# The allowlist selftest ($1 = workspace): stub first in PATH; allowed ids produce exactly the expected line, everything else exits
# non-zero WITHOUT reaching the stub; a monitor request needs an AP of the current document that is unicast, not a station, not ours.
apcli_selftest() {
    pt="$1"; plog="$pt/apcli.log"; : > "$plog"
    apcli_stub "$pt/bin" "$plog"
    p_path=$PATH; p_out=$OUTFILE; p_flag=$APCLI_RO; p_own=$OWN
    PATH="$pt/bin:$PATH"; OUTFILE="$pt/apcli-doc.json"; APCLI_RO=1; OWN=0
    printf '{\n  "aps": [\n    {"bssid": "aa:bb:cc:00:00:01", "ssid": "x"},\n    {"bssid": "aa:bb:cc:00:00:03", "ssid": "y"},\n    {"bssid": "03:bb:cc:00:00:05", "ssid": "z"}\n  ],\n  "center": {"label": "x", "own_bssids": ["aa:bb:cc:00:00:03"]},\n  "unassociated": [\n    {"mac": "aa:bb:cc:00:00:02", "rssi": -60}\n  ]\n}\n' > "$OUTFILE"
    apcli_ro recon_aps; apcli_ro recon_clients; apcli_ro monitor aa:bb:cc:00:00:01
    pl=$(cat "$plog")
    if [ "$pl" = "RECON APS format=json
RECON CLIENTS format=json
MONITOR aa:bb:cc:00:00:01 any rate=200 timeout=120" ]; then st_pass "apcli_ro: the three allowed ids run exactly their literal command lines"; else st_fail "apcli_ro allowed ids: [$pl]"; fi
    n0=$(wc -l < "$plog" | tr -d ' '); bad=""
    for rid in DEAUTH deauth "RECON STOP" "RECON NEW" SSID_POOL_ADD WIGLE_UPLOAD GPS_GET "" monitor aa:bb:cc:00:00:01; do
        apcli_ro "$rid" >/dev/null 2>&1 && bad="$bad [$rid]"
    done
    apcli_ro recon_aps extra >/dev/null 2>&1 && bad="$bad [recon_aps extra]"
    for pm in ff:ff:ff:ff:ff:ff 01:00:5e:00:00:01 03:bb:cc:00:00:05 aa:bb:cc:00:00:02 aa:bb:cc:00:00:03 aa:bb:cc:00:00:99 AA:BB:CC:00:00:01 "aa:bb:cc:00:00:01;reboot" 'aa:bb:cc:00:00:01 --x' ""; do
        apcli_ro monitor "$pm" >/dev/null 2>&1 && bad="$bad [monitor $pm]"
    done
    n1=$(wc -l < "$plog" | tr -d ' ')
    if [ -z "$bad" ] && [ "$n0" = "$n1" ]; then st_pass "apcli_ro: refuses DEAUTH/RECON STOP|NEW/SSID_POOL/WIGLE/GPS ids, broadcast, multicast, a station, our own BSSID, a non-AP, injection — no stub call"; else st_fail "apcli_ro refusals:$bad (stub calls $n0 -> $n1)"; fi
    APCLI_RO=0; apcli_ro recon_aps >/dev/null 2>&1; rc=$?
    n2=$(wc -l < "$plog" | tr -d ' ')
    if [ "$rc" = "3" ] && [ "$n2" = "$n1" ]; then st_pass "apcli_ro: flag off (STARCHORUS_APCLI_RO=0) -> rc 3, no call"; else st_fail "apcli_ro flag off (rc $rc, calls $n1 -> $n2)"; fi
    PATH=$p_path; OUTFILE=$p_out; APCLI_RO=$p_flag; OWN=$p_own
}

# --------------------------------------------------------------------------- survey rows, channels[], center extras
# `iw dev IF survey dump` text on stdin -> "S<TAB>freq<TAB>noise<TAB>active_ms<TAB>busy_ms" per channel (fields absent => '-').
survey_rows() {
    awk '
        function flush(){ if(f ~ /^[0-9]+$/) printf "S\t%s\t%s\t%s\t%s\n", f, (n==""?"-":n), (a==""?"-":a), (b==""?"-":b); f=""; n=""; a=""; b="" }
        /^[ \t]*frequency:/            { flush(); f=$2; next }
        /^[ \t]*noise:/                { n=$2; next }
        /^[ \t]*channel active time:/  { a=$4; next }
        /^[ \t]*channel busy time:/    { b=$4; next }
        END{ flush() }'
}
# "H<TAB>freq<TAB>last_heard" and "S<TAB>freq<TAB>noise<TAB>active<TAB>busy" rows on stdin -> one JSON array (sorted by freq), or nothing.
channels_json() {
    awk -F'\t' '
        $1=="H" && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { seen[$2]=1; last[$2]=$3 }
        $1=="S" && $2 ~ /^[0-9]+$/ { seen[$2]=1
            if($3 ~ /^-?[0-9]+$/) noise[$2]=$3
            if($4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ && $4+0>0){ p=int(100*$5/$4+0.5); if(p>100) p=100; busy[$2]=p } }
        END{ n=0; for(k in seen) key[n++]=k+0
            for(i=1;i<n;i++){ v=key[i]; j=i-1; while(j>=0 && key[j]>v){ key[j+1]=key[j]; j-- } key[j+1]=v }
            if(n==0) exit
            o="["
            for(i=0;i<n;i++){ k=key[i]; o=o (i?", ":"") "{\"freq\": " k
                if(k in last)  o=o ", \"last_heard\": " last[k]
                if(k in busy)  o=o ", \"busy_pct\": " busy[k]
                if(k in noise) o=o ", \"noise\": " noise[k]
                o=o "}" }
            print o "]" }'
}
# center.own_bssids: this device's interface MACs (sysfs; STARCHORUS_SYSFS_NET overrides the directory for tests), unicast, unique, sorted.
own_bssids() {
    d=${STARCHORUS_SYSFS_NET:-/sys/class/net}
    for f in "$d"/*/address; do [ -r "$f" ] && head -n 1 "$f" 2>/dev/null; done | tr 'A-F' 'a-f' | tr -d '\r' | \
        awk '$0 ~ /^[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f]){5}$/ && $0 != "00:00:00:00:00:00" && $0 != "ff:ff:ff:ff:ff:ff" && !seen[$0]++' | sort
}
# center.own_ssids: ONLY from the operator's file (one per line, <= 32 chars, <= 32 entries). Never read from the AP service's SSID pool.
own_ssids() {
    [ -n "$OWN_SSID_FILE" ] && [ -r "$OWN_SSID_FILE" ] || return 0
    clean_ctrl < "$OWN_SSID_FILE" 2>/dev/null | awk 'length($0)>0 && length($0)<=32 && !seen[$0]++ && n++<32'
}
# The text appended INSIDE the center object: max_age and interval (D1/D3, always), own_bssids/own_ssids (STARCHORUS_OWN=1 only).
center_extra() {
    ma=$MAX_AGE; case $ma in ''|*[!0-9]*) ma=0 ;; esac
    iv=$INTERVAL; case $iv in ''|*[!0-9]*) iv=5 ;; esac
    x=", \"max_age\": $ma, \"interval\": $iv"
    if [ "$OWN" = "1" ]; then
        ob=$(own_bssids | awk '{printf "%s\"%s\"", (NR>1?", ":""), $0}')
        [ -z "$ob" ] || x="$x, \"own_bssids\": [$ob]"
        os=$(own_ssids | awk "$AWK_JSON_HELPERS"'{printf "%s\"%s\"", (NR>1?", ":""), jesc($0)}')
        [ -z "$os" ] || x="$x, \"own_ssids\": [$os]"
    fi
    printf '%s' "$x"
}
# A post-pass wrote the document $1 into "$1.$2" with exit status $3. Keep its output only when the pass
# succeeded, the line count is unchanged and the last line is still "}": every post-pass only inserts fields
# into existing lines, so anything else (e.g. a pass that died half-way yet returned 0) is dropped and the
# document stays as it was (return 1).
post_keep() {
    if [ "$3" = "0" ] && [ -s "$1.$2" ] \
       && [ "$(wc -l < "$1" | tr -d ' ')" = "$(wc -l < "$1.$2" | tr -d ' ')" ] && [ "$(tail -n 1 "$1.$2")" = "}" ]; then
        mv -f "$1.$2" "$1"; return 0
    fi
    rm -f "$1.$2" 2>/dev/null; return 1
}
# stdin -> stdout: the JSON with center_extra() inserted into the one-line "center" object.
add_center() {
    SC_CX=$(center_extra) awk '
        !done && /^  "center": \{"label": "[^"]*"\},?$/ {
            p=match($0, /\},?$/); $0=substr($0,1,p-1) ENVIRON["SC_CX"] substr($0,p); done=1 }
        { print }'
}

# Homing: the validated target (lower-case MAC) or nothing. The environment wins over the file; both are read every cycle so the device can change it.
homing_target() {
    t=$HOMING_BSSID
    if [ -z "$t" ] && [ -r "$OUTDIR/homing.target" ]; then t=$(head -n 1 "$OUTDIR/homing.target" 2>/dev/null | tr -d '\r '); fi
    t=$(printf '%s' "$t" | tr 'A-F' 'a-f')
    case $t in
        [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) printf '%s' "$t" ;;
    esac
}
# stdin (the document) -> the target AP's rssi (an integer, e.g. -57) if its row is in aps[]; nothing otherwise (stations never match: they have "mac", not "bssid").
homing_dbm() {
    awk -v t="$1" 'index($0, "\"bssid\": \"" t "\"") && match($0, /"rssi": -?[0-9]+/) { v=substr($0, RSTART+8, RLENGTH-8); print v; exit }'
}
# stdin -> stdout: the document with a "homing" object appended to the generated line.
add_homing() {
    SC_HM="$1" awk '
        !done && /^  "generated": [0-9]+,$/ { sub(/,$/, ", " ENVIRON["SC_HM"] ","); done=1 }
        { print }'
}
# One cycle's homing step on the file $1 (the finished document): keeps the peak, inserts the field, drops the result if the shape changed.
apply_homing() {
    ht=$(homing_target); [ -n "$ht" ] || { HOMING_PEAK=""; HOMING_POLLS=0; return 0; }
    if own_bssids | grep -qx "$ht"; then return 0; fi
    hd=$(homing_dbm "$ht" < "$1"); [ -n "$hd" ] || return 0
    if [ -z "$HOMING_PEAK" ] || [ "$hd" -ge "$HOMING_PEAK" ] || [ "$HOMING_POLLS" -ge 12 ]; then HOMING_PEAK=$hd; HOMING_POLLS=0; else HOMING_POLLS=$((HOMING_POLLS + 1)); fi
    hg=$(sed -n 's/^  "generated": \([0-9][0-9]*\),$/\1/p' "$1" | head -n 1); [ -n "$hg" ] || hg=0
    add_homing "\"homing\": {\"bssid\": \"$ht\", \"dbm\": $hd, \"peak\": $HOMING_PEAK, \"t\": $hg}" < "$1" > "$1.h" 2>/dev/null
    post_keep "$1" h $?
}

# --------------------------------------------------------------------------- empty document
write_empty() {
    ts=$1; reason=$2
    printf '{\n  "generated": %s,\n  "center": {"label": "%s"%s},\n  "source": "none",\n  "note": "%s",\n  "aps": [],\n  "unassociated": []\n}\n' \
        "$ts" "$CENTER_LABEL" "$(center_extra)" "$reason"
}

# --------------------------------------------------------------------------- one cycle
run_cycle() {
    ts=$(date +%s 2>/dev/null); [ -n "$ts" ] || ts=0
    tmp="$OUTFILE.tmp.$$"
    ok=1
    case "$RESOLVED" in
        capture)
            if [ "$CAP_METHOD" = "airodump" ]; then
                build_from_csv "$ts" > "$tmp" 2>/dev/null || ok=0
            else
                build_from_tcpdump "$ts" > "$tmp" 2>/dev/null || ok=0
            fi
            ;;
        recondb) build_from_recondb "$ts" > "$tmp" 2>/dev/null || ok=0 ;;
        iwscan)  build_from_iwscan  "$ts" > "$tmp" 2>/dev/null || ok=0 ;;
        *)       ok=0 ;;
    esac
    # Post-passes on a good document, none of which can fail the cycle: the center extras (max_age,
    # interval, own_*), the homing reading of the ONE chosen AP, and the optional passive vendor /
    # randomized enrichment (skipped entirely with STARCHORUS_VENDOR=0; "defer": its new cache lines are
    # merged only AFTER the JSON is published, below).
    if [ "$ok" = "1" ] && [ -s "$tmp" ]; then
        add_center < "$tmp" > "$tmp.c" 2>/dev/null; post_keep "$tmp" c $?
        apply_homing "$tmp"
        if [ "$VENDOR" = "1" ]; then
            add_vendor defer < "$tmp" > "$tmp.v" 2>/dev/null; post_keep "$tmp" v $? || vendor_merge discard
        fi
    fi
    # Guard: never publish an empty/failed temp over a good file; publish an explicit
    # empty document instead so the front-end always has valid JSON.
    if [ "$ok" != "1" ] || [ ! -s "$tmp" ]; then
        write_empty "$ts" "no data this cycle (source=$RESOLVED)" > "$tmp"
    fi
    mv -f "$tmp" "$OUTFILE"    # atomic replace
    vendor_merge               # cache write AFTER publication: a lock wait costs the cache, not the view
}

# ============================================================================ SELF TEST
# Runs entirely offline with embedded sample data (airodump CSV, recon.db in every schema family,
# tcpdump -e text, OUI files): every emitter, the post-passes (center extras, homing, vendor with
# its cache and lock), run_cycle, a real overlapping --once and the apcli_ro allowlist.
json_ok() {
    # Validate JSON on stdin. Prefer jq, then python3, else a minimal brace-balance sanity check.
    if have jq; then jq -e . >/dev/null 2>&1
    elif have python3; then python3 -c 'import sys,json; json.load(sys.stdin)' >/dev/null 2>&1
    else
        awk '{n+=gsub(/{/,"{"); m+=gsub(/}/,"}")} END{exit (n>0 && n==m)?0:1}'
    fi
}

selftest() {
    # Verdict = the FAIL counter ST_FAILS (a deliberately unique name: a short global like `rc`
    # can be clobbered by any helper called later and silently turn a red run green).
    ST_FAILS=0; ST_PASS=0
    tdir=$(mktemp -d 2>/dev/null || echo /tmp/starchorus-selftest.$$)
    mkdir -p "$tdir"
    OUTDIR="$tdir"; CAPDIR="$tdir/cap"; mkdir -p "$CAPDIR"
    log "selftest workspace: $tdir"

    st_pass() { log "  PASS: $1"; ST_PASS=$((ST_PASS+1)); }
    st_fail() { log "  FAIL: $1"; ST_FAILS=$((ST_FAILS+1)); }
    check() {  # desc, haystack, needle (basic regex)
        if printf '%s' "$2" | grep -q -- "$3"; then st_pass "$1"; else st_fail "$1  (missing: $3)"; fi
    }
    checkf() {  # desc, haystack, FIXED-string needle (for needles containing \ or ")
        if printf '%s' "$2" | grep -qF -- "$3"; then st_pass "$1"; else st_fail "$1  (missing: $3)"; fi
    }
    checkno() {  # desc, haystack, needle that must be ABSENT
        if printf '%s' "$2" | grep -q -- "$3"; then st_fail "$1  (unexpected: $3)"; else st_pass "$1"; fi
    }
    jcheck() {  # name, document: "<name> valid JSON"
        if printf '%s' "$2" | json_ok; then st_pass "$1 valid JSON"; else st_fail "$1 JSON"; fi
    }

    # ---- 1) airodump CSV -------------------------------------------------------------------
    cat > "$CAPDIR/starchorus-01.csv" <<'CSV'
BSSID, First time seen, Last time seen, channel, Speed, Privacy, Cipher, Authentication, Power, # beacons, # IV, LAN IP, ID-length, ESSID, Key
AA:BB:CC:00:11:22, 2026-09-13 10:00:00, 2026-09-13 10:05:00, 6, 130, WPA2, CCMP, PSK, -42, 100, 0, 0.0.0.0, 8, HomeNet,
DD:EE:FF:33:44:55, 2026-09-13 10:00:00, 2026-09-13 10:05:00, 149, 866, OPN, , , -70, 50, 0, 0.0.0.0, 7, Caf, e Guest,

Station MAC, First time seen, Last time seen, Power, # packets, BSSID, Probed ESSIDs
11:22:33:44:55:66, 2026-09-13 10:00:00, 2026-09-13 10:05:00, -55, 20, AA:BB:CC:00:11:22,
99:88:77:66:55:44, 2026-09-13 10:00:00, 2026-09-13 10:05:00, -80, 5, (not associated), FreeWifi
CSV
    out=$(build_from_csv 1710000000 2>/dev/null)
    jcheck "airodump-csv" "$out"
    check "airodump: source label"        "$out" '"source": "airodump-csv"'
    check "airodump: WPA2 AP"             "$out" '"security": "WPA2/PSK/CCMP"'
    check "airodump: 5GHz band from ch149" "$out" '"band": "5GHz"'
    check "airodump: comma-in-ESSID kept"  "$out" 'Caf, e Guest'
    check "airodump: associated client"    "$out" '"mac": "11:22:33:44:55:66"'
    check "airodump: unassociated client"  "$out" '"mac": "99:88:77:66:55:44"'
    checkf "airodump: probed ESSID -> probes" "$out" '"rssi": -80, "probes": ["FreeWifi"]'
    check "airodump: rate from Speed (130)" "$out" '"security": "WPA2/PSK/CCMP", "rate": 130, "clients"'
    check "airodump: rate from Speed (866)" "$out" '"rate": 866'

    # ---- 2) recon.db, running `ssid` schema --------------------------------------------------
    if have sqlite3; then
        pdb="$tdir/recon_ssid.db"
        # 1<<57 = 144115188075855872 ; +16 (WPA3 bit) exercises the >2^53 SQL bit-extraction.
        sqlite3 "$pdb" >/dev/null 2>&1 <<'SQL'
CREATE TABLE ssid (scan INTEGER, type INTEGER, apmac TEXT, stamac TEXT, ssid BLOB,
                   encryption INTEGER, freq INTEGER, signal INTEGER, hidden INTEGER, band TEXT);
CREATE TABLE wifi_device (hash INTEGER, mac TEXT, packets INTEGER);
-- APs (type 8 beacon):  open, WPA2, WPA3-SAE(6GHz), hidden(2.4)
INSERT INTO ssid VALUES (1,8,'aabbcc001122','', 'OpenAir',      0,   2437, -40, 0, '2');
INSERT INTO ssid VALUES (1,8,'aabbcc334455','', 'SecureHome',   8,   5240, -55, 0, '5');
INSERT INTO ssid VALUES (1,8,'aabbcc667788','', 'Mesh6E', 144115188075855888, 5955, -66, 0, '6');
INSERT INTO ssid VALUES (1,8,'aabbccaabbcc','', '',             8,   2412, -60, 1, '2');
-- 6GHz channel 2 sits at 5935 MHz (not 5950+2*5); this schema has no channel column
INSERT INTO ssid VALUES (1,8,'aabbcc66aa02','', 'Mesh6E-Ch2',   8,   5935, -70, 0, '6');
-- duplicate/older observation of SecureHome, weaker signal, must be deduped by GROUP BY
INSERT INTO ssid VALUES (2,8,'aabbcc334455','', 'SecureHome',   8,   5240, -77, 0, '5');
-- probe-response (type 5) for an AP not seen via beacon
INSERT INTO ssid VALUES (1,5,'aabbccddeeff','', 'ProbeRespNet', 4,   2462, -50, 0, '2');
-- probe requests (type 4) -> unassociated clients
INSERT INTO ssid VALUES (1,4,'','1122aabbccdd','FreeWifi',      0,   0,    -72, 0, '');
INSERT INTO ssid VALUES (1,4,'','1122aabbccee','',              0,   0,    -83, 0, '');
SQL
        out=$(RECON_DB="$pdb" build_from_recondb 1710000000 2>/dev/null)
        jcheck "recon(ssid)" "$out"
        check "recon: source label"      "$out" '"source": "recon-db"'
        check "recon: open AP"           "$out" '"ssid": "OpenAir"'
        check "recon: Open security"     "$out" '"security": "Open"'
        check "recon: WPA2"              "$out" '"security": "WPA2"'
        check "recon: WPA3 via SAE bit"  "$out" '"security": "WPA3"'
        check "recon: 6GHz band"         "$out" '"band": "6GHz"'
        check "recon: bssid colonised"   "$out" '"bssid": "aa:bb:cc:00:11:22"'
        check "recon: probe-resp AP"     "$out" 'ProbeRespNet'
        check "recon: unassociated probe" "$out" '"mac": "11:22:aa:bb:cc:dd"'
        checkf "recon: probed SSID -> probes" "$out" '"probes": ["FreeWifi"]'
        checkf "recon: wildcard probe carries no probes" "$out" '"mac": "11:22:aa:bb:cc:ee", "rssi": -83}'
        check "recon: 6GHz channel 2 from freq 5935" "$(printf '%s\n' "$out" | grep 'aa:bb:cc:66:aa:02')" '"channel": 2, "band": "6GHz", "freq": 5935'
        # dedup: SecureHome must appear exactly once, and at the strong -55 (not -77)
        cnt=$(printf '%s\n' "$out" | grep -c 'SecureHome')
        if [ "$cnt" = "1" ]; then st_pass "recon dedup (SecureHome x1)"; else st_fail "recon dedup (x$cnt)"; fi
        check "recon: strong signal kept" "$out" '"rssi": -55'

        # ---- 2b) recon.db, RUNNING-firmware `ssid` schema (bssid + channel + wifi_device join).
        #      Uses the real encryption integers observed on-device (libwifi bitmask: bit3=WPA2,
        #      bit4=WPA3) to prove the SQL bit-extraction decodes real values correctly.
        rdb="$tdir/recon_real.db"
        sqlite3 "$rdb" >/dev/null 2>&1 <<'SQL'
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB,
                  hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT,
                  UNIQUE(hash) ON CONFLICT REPLACE);
CREATE TABLE wifi_device(hash INT PRIMARY KEY, scan INT, mac TEXT, time INT, signal INT, freq INT,
                  packets INT, UNIQUE(hash) ON CONFLICT REPLACE);
-- beacons (type 8): open(enc 0), WPA2, WPA3(SAE), WPA2/WPA3 transition, hidden, 6GHz
INSERT INTO ssid VALUES (1,0,1,8,'AABBCC001122','OpenGuest',        0,0,-50,5220,44, 0);
INSERT INTO ssid VALUES (2,0,1,8,'AABBCC334455','HomeNet-5G',   0,0,-55,5500,64, 17184063752);
INSERT INTO ssid VALUES (3,0,1,8,'AABBCC667788','SAE-Only',         0,0,-66,5955, 1, 6597073961232);
INSERT INTO ssid VALUES (4,0,1,8,'AABBCC99AABB','Transition',       0,0,-58,2437, 6, 2216207319320);
INSERT INTO ssid VALUES (5,0,1,8,'AABBCCCCDDEE','',                 1,0,-71,5785,157,17184063752);
-- older, weaker duplicate observation of the WPA2 net -> must dedupe to one, keep -55
INSERT INTO ssid VALUES (6,0,2,8,'AABBCC334455','HomeNet-5G',   0,0,-77,5500,64, 17184063752);
-- probe-response (type 5) AP not seen via beacon
INSERT INTO ssid VALUES (7,0,1,5,'AABBCCF00D01','ProbeRespOnly',    0,0,-52,2462,11, 17184063752);
-- probe-request stations (type 4) linked through wifi_device
INSERT INTO ssid VALUES (8,101,1,4,'FFFFFFFFFFFF','FreeWifi',       0,0,-72,0,0, 0);
INSERT INTO ssid VALUES (9,102,1,4,'FFFFFFFFFFFF','',               0,0,-83,0,0, 0);
INSERT INTO wifi_device VALUES (101,1,'1122AABBCCDD',0,-72,0,5);
INSERT INTO wifi_device VALUES (102,1,'1122AABBCCEE',0,-83,0,2);
SQL
        out=$(RECON_DB="$rdb" build_from_recondb 1710000000 2>/dev/null)
        jcheck "recon(real ssid)" "$out"
        check "real: open (enc 0)"        "$out" '"ssid": "OpenGuest"'
        check "real: WPA2 (bit3)"         "$out" '"security": "WPA2"'
        check "real: WPA3 (bit4/SAE)"     "$out" '"security": "WPA3"'
        check "real: WPA2/WPA3 transition" "$out" '"security": "WPA3/WPA2"'
        check "real: 6GHz from freq 5955"  "$out" '"band": "6GHz"'
        check "real: probe-resp AP"        "$out" 'ProbeRespOnly'
        checkf "real: probed SSID -> probes"  "$out" '"probes": ["FreeWifi"]'
        checkf "real: wildcard probe no probes" "$out" '"mac": "11:22:aa:bb:cc:ee", "rssi": -83}'
        check "real: bssid colonised"      "$out" '"bssid": "aa:bb:cc:00:11:22"'
        check "real: client via wifi_device join" "$out" '"mac": "11:22:aa:bb:cc:dd"'
        rcnt=$(printf '%s\n' "$out" | grep -c 'HomeNet-5G')
        if [ "$rcnt" = "1" ]; then st_pass "real dedup (HomeNet-5G x1)"; else st_fail "real dedup (x$rcnt)"; fi

        # ---- 2c) STARCHORUS_MAX_AGE live-presence window: only recent rows survive -----------------
        adb="$tdir/recon_age.db"; now=$(date +%s 2>/dev/null); [ -n "$now" ] || now=1789312406
        old=$((now - 100000))
        sqlite3 "$adb" >/dev/null 2>&1 <<SQL
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB,
                  hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT);
CREATE TABLE wifi_device(hash INT PRIMARY KEY, scan INT, mac TEXT, time INT, signal INT, freq INT, packets INT);
INSERT INTO ssid VALUES (1,0,1,8,'AAAAAAAA0001','RecentAP',0,$now,-50,2437,6,8);
INSERT INTO ssid VALUES (2,0,1,8,'BBBBBBBB0002','StaleAP', 0,$old,-60,2437,6,8);
INSERT INTO ssid VALUES (3,301,1,4,'FFFFFFFFFFFF','',0,$now,-70,0,0,0);
INSERT INTO ssid VALUES (4,302,1,4,'FFFFFFFFFFFF','',0,$old,-80,0,0,0);
INSERT INTO wifi_device VALUES (301,1,'AA11AA11AA11',$now,-70,0,1);
INSERT INTO wifi_device VALUES (302,1,'BB22BB22BB22',$old,-80,0,1);
SQL
        full=$(RECON_DB="$adb" MAX_AGE=0 build_from_recondb 1710000000 2>/dev/null)
        live=$(RECON_DB="$adb" MAX_AGE=300 build_from_recondb 1710000000 2>/dev/null)
        if printf '%s' "$full" | grep -q 'RecentAP' && printf '%s' "$full" | grep -q 'StaleAP'; then
            st_pass "MAX_AGE=0 keeps full history (RecentAP+StaleAP)"; else st_fail "MAX_AGE=0 history"; fi
        if printf '%s' "$live" | grep -q 'RecentAP' && ! printf '%s' "$live" | grep -q 'StaleAP'; then
            st_pass "MAX_AGE=300 drops stale AP, keeps recent"; else st_fail "MAX_AGE window (AP)"; fi
        if printf '%s' "$live" | grep -q 'aa:11:aa:11:aa:11' && ! printf '%s' "$live" | grep -q 'bb:22:bb:22:bb:22'; then
            st_pass "MAX_AGE=300 drops stale client (join uses s.time)"; else st_fail "MAX_AGE window (client)"; fi

        # ---- 2d) libwifi encryption_info in full (group/pairwise cipher, AKM, auth) and multi-SSID responders -------------------------
        #      Integers built from the pinned libwifi layout (bit 3 WPA2 class, 4 WPA3, 6 group TKIP, 8 group CCMP128, 20 pairwise TKIP, 22 pairwise
        #      CCMP128, 26 pairwise GCMP128, 33 AKM 1X, 34 PSK, 41 SAE, 44 1X-SuiteB-SHA256, 51 OWE, 54 auth OPEN, 57 auth SAE). All above 2^32,
        #      OWE/SAE above 2^41: they only survive because the bit extraction happens in SQL.
        sdb="$tdir/recon_sec.db"
        sqlite3 "$sdb" >/dev/null 2>&1 <<SQL
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB,
                  hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT);
INSERT INTO ssid VALUES (1,0,1,8,'A0A0A0000001','Sec-OWE',    0,0,-50,5220,44,20266198327361808);
INSERT INTO ssid VALUES (2,0,1,8,'A0A0A0000002','Sec-SAE',    0,0,-50,5220,44,144117387103306000);
INSERT INTO ssid VALUES (3,0,1,8,'A0A0A0000003','Sec-PSK',    0,0,-50,5220,44,18014415693545736);
INSERT INTO ssid VALUES (4,0,1,8,'A0A0A0000004','Sec-ENT2',   0,0,-50,5220,44,18014407103611144);
INSERT INTO ssid VALUES (5,0,1,8,'A0A0A0000005','Sec-ENT3',   0,0,-50,5220,44,18031990762635536);
INSERT INTO ssid VALUES (6,0,1,8,'A0A0A0000006','Sec-WPATKIP',0,0,-50,2437,6,17180917828);
INSERT INTO ssid VALUES (7,0,1,8,'A0A0A0000007','Sec-WPA2TKIP',0,0,-50,2437,6,17180917832);
INSERT INTO ssid VALUES (8,0,1,8,'A0A0A0000008','Sec-MIXED',  0,0,-50,2437,6,17185112392);
INSERT INTO ssid VALUES (9,0,1,8,'A0A0A0000009','Sec-TRANS',  0,0,-50,2437,6,18016614716801304);
-- multi-SSID responder: one BSSID answers probes for three different SSIDs (type 5), another for one
INSERT INTO ssid VALUES (10,0,1,5,'A0A0A0000010','ResponderA',0,0,-60,2437,6,8);
INSERT INTO ssid VALUES (11,0,1,5,'A0A0A0000010','ResponderB',0,0,-61,2437,6,8);
INSERT INTO ssid VALUES (12,0,1,5,'A0A0A0000010','ResponderC',0,0,-62,2437,6,8);
INSERT INTO ssid VALUES (13,0,1,5,'A0A0A0000011','SingleSsid',0,0,-63,2437,6,8);
SQL
        out=$(RECON_DB="$sdb" build_from_recondb 1710000000 2>/dev/null)
        jcheck "recon(security suite)" "$out"
        sl() { printf '%s\n' "$out" | grep -- "$1" | head -1; }
        checkf "sec: OWE is OWE, not WPA3 (libwifi sets the WPA3 class bit for OWE)" "$(sl 'a0:a0:a0:00:00:01')" '"security": "OWE", "akm": ["owe"]'
        checkf "sec: OWE auth scheme open"       "$(sl 'a0:a0:a0:00:00:01')" '"auth": ["open"]'
        checkf "sec: SAE (AKM bit 41 + auth SAE) is WPA3" "$(sl 'a0:a0:a0:00:00:02')" '"security": "WPA3", "akm": ["sae"]'
        checkf "sec: SAE auth scheme listed"     "$(sl 'a0:a0:a0:00:00:02')" '"auth": ["sae"]'
        checkf "sec: PSK is WPA2 with its ciphers" "$(sl 'a0:a0:a0:00:00:03')" '"security": "WPA2", "akm": ["psk"], "cipher": {"group": "ccmp128", "pairwise": ["ccmp128"]}, "auth": ["open"]'
        checkf "sec: 802.1X is WPA2-Enterprise"  "$(sl 'a0:a0:a0:00:00:04')" '"security": "WPA2-Enterprise", "akm": ["1x"]'
        checkf "sec: Suite-B 802.1X is WPA3-Enterprise" "$(sl 'a0:a0:a0:00:00:05')" '"security": "WPA3-Enterprise", "akm": ["1x-suiteb-sha256"]'
        checkf "sec: TKIP-only WPA is marked"    "$(sl 'a0:a0:a0:00:00:06')" '"security": "WPA (TKIP)"'
        checkf "sec: TKIP-only WPA2 is marked"   "$(sl 'a0:a0:a0:00:00:07')" '"security": "WPA2 (TKIP)"'
        checkf "sec: TKIP+CCMP mixed mode is not marked" "$(sl 'a0:a0:a0:00:00:08')" '"security": "WPA2", "akm": ["psk"], "cipher": {"group": "tkip", "pairwise": ["tkip", "ccmp128"]}'
        checkf "sec: WPA2+WPA3 transition keeps both AKMs" "$(sl 'a0:a0:a0:00:00:09')" '"security": "WPA3/WPA2", "akm": ["psk", "sae"]'
        checkf "resp: BSSID answering for 3 SSIDs -> responded_ssids 3" "$(sl 'a0:a0:a0:00:00:10')" '"responded_ssids": 3'
        checkno "resp: a single-SSID responder carries no count" "$(sl 'a0:a0:a0:00:00:11')" 'responded_ssids'
        checkno "packets: never on a station (no client field carries it)" "$out" '"packets"'
        # nothing in the additive fields may leak a client identity: only AP lines carry akm/cipher/auth/responded_ssids
        cl=$(printf '%s\n' "$out" | grep -c '"mac".*\("akm"\|"cipher"\|"auth"\|"responded_ssids"\)')
        if [ "$cl" = "0" ]; then st_pass "sec: akm/cipher/auth/responded_ssids only on AP lines"; else st_fail "sec: additive fields on a client line ($cl)"; fi

        # ---- 2e) channels[] (hop info + survey), center max_age/interval, own_bssids/own_ssids, run_cycle post-pass ----------------------
        hdb="$tdir/recon_hop.db"; hnow=1710000000
        sqlite3 "$hdb" >/dev/null 2>&1 <<SQL
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB,
                  hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT);
INSERT INTO ssid VALUES (1,0,1,8,'B0B0B0000001','HopA',0,$((hnow-5)),-50,2412,1,8);
INSERT INTO ssid VALUES (2,0,1,8,'B0B0B0000002','HopB',0,$((hnow-60)),-60,2412,1,8);
INSERT INTO ssid VALUES (3,0,1,8,'B0B0B0000003','HopC',0,$((hnow-30)),-60,5180,36,8);
SQL
        RECON_DB="$hdb"
        out=$(HOPINFO=0 SURVEY=0 build_from_recondb "$hnow" 2>/dev/null)
        checkno "hop: no channels[] by default (flag off)" "$out" '"channels"'
        out=$(HOPINFO=1 build_from_recondb "$hnow" 2>/dev/null)
        if printf '%s' "$out" | json_ok; then st_pass "hop: valid JSON with channels[]"; else st_fail "hop: JSON"; fi
        checkf "hop: last_heard per frequency = newest row" "$out" '"channels": [{"freq": 2412, "last_heard": 1709999995}, {"freq": 5180, "last_heard": 1709999970}],'
        RECON_DB=auto
        sv=$(printf 'Survey data from wlan1mon\n\tfrequency:\t\t\t2412 MHz [in use]\n\tnoise:\t\t\t\t-95 dBm\n\tchannel active time:\t\t1000 ms\n\tchannel busy time:\t\t250 ms\nSurvey data from wlan1mon\n\tfrequency:\t\t\t5180 MHz\n\tnoise:\t\t\t\t-101 dBm\n\tchannel active time:\t\t0 ms\n\tchannel busy time:\t\t0 ms\n' | survey_rows)
        chj=$( { printf 'H\t2412\t1709999995\n'; printf '%s\n' "$sv"; } | channels_json)
        checkf "survey: busy_pct = 100*busy/active, noise kept, a zero active time gives no percentage" "$chj" '[{"freq": 2412, "last_heard": 1709999995, "busy_pct": 25, "noise": -95}, {"freq": 5180, "noise": -101}]'
        mkdir -p "$tdir/sys/wlan0" "$tdir/sys/wlan1mon" "$tdir/sys/lo" "$tdir/sys/br0"
        printf '00:C0:CA:11:22:33\n' > "$tdir/sys/wlan0/address"; printf '00:c0:ca:11:22:33\n' > "$tdir/sys/wlan1mon/address"
        printf '00:00:00:00:00:00\n' > "$tdir/sys/lo/address"; printf 'not-a-mac\n' > "$tdir/sys/br0/address"
        printf 'MyOwnNet\n\nMyOwnNet\nSecond "quoted" net\n' > "$tdir/own_ssids.txt"
        cx=$(OWN=1 STARCHORUS_SYSFS_NET="$tdir/sys" OWN_SSID_FILE="$tdir/own_ssids.txt" MAX_AGE=120 INTERVAL=7 center_extra)
        checkf "own: max_age, interval, unique lower-case interface MACs, file SSIDs (dedup, escaped)" "$cx" ', "max_age": 120, "interval": 7, "own_bssids": ["00:c0:ca:11:22:33"], "own_ssids": ["MyOwnNet", "Second \"quoted\" net"]'
        cx=$(OWN=0 STARCHORUS_SYSFS_NET="$tdir/sys" MAX_AGE=0 INTERVAL=5 center_extra)
        if [ "$cx" = ', "max_age": 0, "interval": 5' ]; then st_pass "own: flag off -> only max_age and interval"; else st_fail "own flag off: [$cx]"; fi
        # run_cycle (recon source): the published document carries the extras, on the same line, and stays valid JSON
        RESOLVED=recondb; RECON_DB="$sdb"; OUTFILE="$tdir/cycle.json"; VENDOR=0; MAX_AGE=90; INTERVAL=9
        run_cycle >/dev/null 2>&1
        pub=$(cat "$OUTFILE" 2>/dev/null)
        if printf '%s' "$pub" | json_ok; then st_pass "run_cycle: center-extra post-pass keeps valid JSON"; else st_fail "run_cycle center post-pass JSON"; fi
        checkf "run_cycle: center carries max_age + interval" "$pub" '"center": {"label": "This device", "max_age": 90, "interval": 9},'
        # ---- 2f) homing: the reading of the ONE chosen AP, peak hold, refusals (station / unknown / own / garbage), file vs environment
        checkno "homing: no target -> no homing field" "$pub" '"homing"'
        OUTDIR_SAVE=$OUTDIR; OUTDIR=$tdir; rm -f "$tdir/homing.target"; MAX_AGE=0   # the fixture rows carry time 0: a 90 s window above would give the empty document
        hp=$(run_cycle >/dev/null 2>&1; cat "$OUTFILE" 2>/dev/null); pub=$hp; checkf "homing: the fixture cycle is a real document (a0:a0:a0:00:00:03 is there)" "$pub" '"bssid": "a0:a0:a0:00:00:03"'
        hcyc() { run_cycle >/dev/null 2>&1; cat "$OUTFILE" 2>/dev/null; }
        HOMING_BSSID="A0:A0:A0:00:00:03"; hp=$(hcyc)
        if printf '%s' "$hp" | json_ok; then st_pass "homing: valid JSON with the field"; else st_fail "homing: JSON"; fi
        checkf "homing: bssid lower-cased, dbm from the AP's own row, peak, t = generated" "$hp" '"homing": {"bssid": "a0:a0:a0:00:00:03", "dbm": -50, "peak": -50, "t": '
        if [ "$(printf '%s\n' "$hp" | grep -c '"homing"')" = 1 ] && [ "$(printf '%s\n' "$hp" | wc -l | tr -d ' ')" = "$(printf '%s\n' "$pub" | wc -l | tr -d ' ')" ]; then st_pass "homing: exactly one field, same line count as without"; else st_fail "homing: line count / count"; fi
        HOMING_BSSID="11:22:aa:bb:cc:dd"; hp=$(hcyc); checkno "homing: a station (a MAC with no aps[] row) is refused" "$hp" '"homing"'
        HOMING_BSSID="de:ad:be:ef:00:01"; hp=$(hcyc); checkno "homing: a BSSID that is not in this document is refused" "$hp" '"homing"'
        HOMING_BSSID="not-a-mac"; hp=$(hcyc); checkno "homing: garbage is refused" "$hp" '"homing"'
        HOMING_BSSID="a0:a0:a0:00:00:03"; OWN=1 STARCHORUS_SYSFS_NET="$tdir/sys"; printf 'A0:A0:A0:00:00:03\n' > "$tdir/sys/wlan0/address"
        hp=$(OWN=1 STARCHORUS_SYSFS_NET="$tdir/sys" hcyc); checkno "homing: one of our own transmitters is refused" "$hp" '"homing"'
        printf '00:C0:CA:11:22:33\n' > "$tdir/sys/wlan0/address"
        HOMING_BSSID=""; printf 'A0:A0:A0:00:00:04\r\nignored line\n' > "$tdir/homing.target"; hp=$(hcyc)
        checkf "homing: the file target works (first line, CRLF, upper case)" "$hp" '"homing": {"bssid": "a0:a0:a0:00:00:04"'
        HOMING_BSSID="a0:a0:a0:00:00:03"; hp=$(hcyc); checkf "homing: the environment wins over the file" "$hp" '"homing": {"bssid": "a0:a0:a0:00:00:03"'
        # peak hold (the state lives in this shell, so the cycles run here, not in a $(...) subshell): a weaker reading keeps it, 12 quiet cycles decay it
        hrun() { run_cycle >/dev/null 2>&1; hp=$(cat "$OUTFILE" 2>/dev/null); }
        HOMING_BSSID="a0:a0:a0:00:00:03"; HOMING_PEAK=-40; HOMING_POLLS=0
        hrun; checkf "homing: a weaker reading keeps the peak (-40 stays, dbm -50)" "$hp" '"dbm": -50, "peak": -40,'
        n=0; while [ "$n" -lt 12 ]; do hrun; n=$((n + 1)); done
        checkf "homing: 12 quiet cycles later the peak has decayed to the current reading" "$hp" '"dbm": -50, "peak": -50,'
        HOMING_BSSID=""; rm -f "$tdir/homing.target"; hrun; checkno "homing: target removed -> field gone" "$hp" '"homing"'
        if [ -z "$HOMING_PEAK" ]; then st_pass "homing: the peak is dropped with the target"; else st_fail "homing: peak kept ($HOMING_PEAK)"; fi
        OUTDIR=$OUTDIR_SAVE; HOMING_BSSID=${STARCHORUS_HOMING_BSSID:-}; HOMING_PEAK=""; HOMING_POLLS=0
        RESOLVED=none; RECON_DB=auto; OUTFILE=$OUTDIR/starchorus.json; VENDOR=${STARCHORUS_VENDOR:-1}; MAX_AGE=${STARCHORUS_MAX_AGE:-0}; INTERVAL=${STARCHORUS_INTERVAL:-5}
        apcli_selftest "$tdir"

        # ---- 3) recon.db, legacy `aps` schema ----------------------------------------------------
        mdb="$tdir/recon_legacy.db"
        sqlite3 "$mdb" >/dev/null 2>&1 <<'SQL'
CREATE TABLE aps (bssid TEXT, ssid TEXT, channel INTEGER, signal INTEGER, privacy TEXT);
INSERT INTO aps VALUES ('aa:bb:cc:aa:00:01','LegacyNet', 11, -48, 'WPA2');
INSERT INTO aps VALUES ('aa:bb:cc:aa:00:02','OldOpen',    1, -75, 'OPN');
SQL
        out=$(RECON_DB="$mdb" build_from_recondb 1710000000 2>/dev/null)
        jcheck "recon(legacy aps)" "$out"
        check "legacy: LegacyNet WPA2"    "$out" '"security": "WPA2"'
        check "legacy: channel->band 2.4" "$out" '"band": "2.4GHz"'
        check "legacy: OPN->Open"         "$out" '"security": "Open"'
    else
        log "  SKIP: recon.db tests (sqlite3 not installed here)"
    fi

    # ---- 4) tcpdump text -------------------------------------------------------------------
    # Real `tcpdump -e` shapes: with radiotap prefix (rate, MHz, dBm), rates IE "[... Mbit]",
    # capabilities ESS / ", PRIVACY", DS channel "CH: n"; an MCS/6GHz beacon without DS IE; a
    # legacy short line without radiotap; and an SSID that tries to inject "CH: 6 ... PRIVACY".
    line_of() { printf '%s\n' "$1" | grep -- "$2" | head -1; }   # first output line containing $2
    # (a plain file, not td=$(cat <<EOF): bash's $(...) parser trips over the unbalanced ")" below)
    cat > "$tdir/tcpdump.txt" <<'TXT'
10:00:00.000000 1.0 Mb/s 2437 MHz 11g -45dBm signal antenna 0 BSSID:aa:bb:cc:00:11:22 DA:ff:ff:ff:ff:ff:ff SA:aa:bb:cc:00:11:22 Beacon (HomeNet) [1.0* 2.0* 5.5* 11.0* 6.0 9.0 12.0 18.0 Mbit] ESS CH: 6, PRIVACY
10:00:00.100000 -78dBm signal antenna 0 BSSID:ff:ff:ff:ff:ff:ff DA:ff:ff:ff:ff:ff:ff SA:99:88:77:66:55:44 Probe Request (FreeWifi) [1.0* 2.0* 5.5* 11.0* Mbit]
10:00:00.200000 6.0 Mb/s 5745 MHz 11a -60dBm signal antenna 0 BSSID:de:ad:be:ef:00:01 DA:11:22:33:44:55:66 SA:de:ad:be:ef:00:01 Probe Response (OtherNet) [6.0* 9.0 12.0* 18.0 24.0* 36.0 48.0 54.0 Mbit] ESS CH: 149
10:00:00.300000 MCS 7 20 MHz lon GI 5955 MHz 11a -66dBm signal antenna 0 BSSID:a8:bb:cc:66:77:88 DA:ff:ff:ff:ff:ff:ff SA:a8:bb:cc:66:77:88 Beacon (Mesh6E) [6.0* 9.0 12.0* Mbit] ESS
10:00:00.400000 1.0 Mb/s 2462 MHz 11g -50dBm signal antenna 0 BSSID:a8:bb:cc:00:99:99 DA:ff:ff:ff:ff:ff:ff SA:a8:bb:cc:00:99:99 Beacon (CH: 6 [54.0 Mbit] PRIVACY) [1.0* 2.0* 5.5* 11.0* Mbit] ESS CH: 11
10:00:00.500000 -52dBm signal antenna 0 12500us BSSID:aa:bb:cc:00:11:22 DA:ff:ff:ff:ff:ff:ff SA:aa:bb:cc:00:11:22 Beacon (HomeNet) [1.0* 2.0*] CH: 6
10:00:00.600000 1.0 Mb/s 2437 MHz 11g -47dBm signal antenna 0 BSSID:a8:bb:cc:00:99:98 DA:ff:ff:ff:ff:ff:ff SA:a8:bb:cc:00:99:98 Beacon (x) CH: 11, PRIVACY) [1.0* 2.0* Mbit] ESS CH: 6
10:00:00.700000 1.0 Mb/s 2462 MHz 11g -49dBm signal antenna 0 BSSID:a8:bb:cc:00:99:97 DA:ff:ff:ff:ff:ff:ff SA:a8:bb:cc:00:99:97 Beacon (x CH: 6 [54.0 Mbit] PRIVACY, y) [1.0* 2.0* 5.5* 11.0* Mbit] ESS CH: 11
10:00:00.800000 MCS 7 20 MHz lon GI 5955 MHz 11a -64dBm signal antenna 0 BSSID:a8:bb:cc:66:77:89 DA:ff:ff:ff:ff:ff:ff SA:a8:bb:cc:66:77:89 Beacon (Mesh6E-DS) [6.0* 9.0 12.0* Mbit] ESS CH: 1
10:00:00.900000 1.0 Mb/s 2412 MHz 11g -58dBm signal antenna 0 BSSID:a8:bb:cc:66:77:8a DA:ff:ff:ff:ff:ff:ff SA:a8:bb:cc:66:77:8a Beacon (Ch1-24) [1.0* 2.0* Mbit] ESS CH: 1
10:00:01.000000 MCS 7 20 MHz lon GI 5935 MHz 11a -70dBm signal antenna 0 BSSID:a8:bb:cc:66:77:8b DA:ff:ff:ff:ff:ff:ff SA:a8:bb:cc:66:77:8b Beacon (Mesh6E-Ch2) [6.0* Mbit] ESS CH: 2
10:00:01.100000 MCS 7 20 MHz lon GI 5935 MHz 11a -71dBm signal antenna 0 BSSID:a8:bb:cc:66:77:8c DA:ff:ff:ff:ff:ff:ff SA:a8:bb:cc:66:77:8c Beacon (Mesh6E-Ch2-noDS) [6.0* Mbit] ESS
TXT
    out=$(parse_tcpdump_text 1710000000 < "$tdir/tcpdump.txt" 2>/dev/null)
    jcheck "tcpdump" "$out"
    check "tcpdump: source label"   "$out" '"source": "tcpdump"'
    check "tcpdump: beacon AP"      "$out" '"bssid": "aa:bb:cc:00:11:22"'
    check "tcpdump: probe-resp AP"  "$out" '"bssid": "de:ad:be:ef:00:01"'
    check "tcpdump: probe client"   "$out" '"mac": "99:88:77:66:55:44", "rssi": -78'
    checkf "tcpdump: probe SSID -> probes" "$out" '"rssi": -78, "probes": ["FreeWifi"]'
    hn=$(line_of "$out" 'aa:bb:cc:00:11:22')
    check "tcpdump: channel from DS 'CH: 6'"      "$hn" '"channel": 6, "band": "2.4GHz", "freq": 2437'
    check "tcpdump: PRIVACY -> security Secured"  "$hn" '"security": "Secured"'
    check "tcpdump: rate = highest legacy rate"   "$hn" '"rate": 18'
    check "tcpdump: strongest RSSI kept (-45)"    "$hn" '"rssi": -45'
    check "tcpdump: probe-resp ch149/Open/rate 54" "$(line_of "$out" 'de:ad:be:ef:00:01')" \
        '"channel": 149, "band": "5GHz", "freq": 5745, "rssi": -60, "security": "Open", "rate": 54'
    check "tcpdump: 6GHz from radiotap MHz (no CH:)" "$(line_of "$out" 'a8:bb:cc:66:77:88')" \
        '"channel": 1, "band": "6GHz", "freq": 5955, "rssi": -66, "security": "Open", "rate": 12'
    # the DS channel number alone is ambiguous ("CH: 1" is 2412 MHz on 2.4GHz, 5955 MHz on 6GHz):
    # only the radiotap MHz prefix decides; a mutant using freq_from_ch(c) alone turns this red
    check "tcpdump: 6GHz with DS 'CH: 1' -> freq 5955 (radiotap disambiguates)" "$(line_of "$out" 'a8:bb:cc:66:77:89')" \
        '"channel": 1, "band": "6GHz", "freq": 5955, "rssi": -64'
    check "tcpdump: 2.4GHz with DS 'CH: 1' -> freq 2412 (counter-check)" "$(line_of "$out" 'a8:bb:cc:66:77:8a')" \
        '"channel": 1, "band": "2.4GHz", "freq": 2412, "rssi": -58'
    check "tcpdump: 6GHz channel 2 = 5935 MHz (DS CH: 2)"      "$(line_of "$out" 'a8:bb:cc:66:77:8b')" '"channel": 2, "band": "6GHz", "freq": 5935'
    check "tcpdump: 6GHz channel 2 = 5935 MHz (radiotap only)" "$(line_of "$out" 'a8:bb:cc:66:77:8c')" '"channel": 2, "band": "6GHz", "freq": 5935'
    inj=$(line_of "$out" 'a8:bb:cc:00:99:99')
    check "tcpdump: injected SSID kept verbatim"  "$inj" '"ssid": "CH: 6 \[54.0 Mbit\] PRIVACY"'
    check "tcpdump: injection ignored (ch11/Open/11)" "$inj" '"channel": 11, "band": "2.4GHz", "freq": 2462, "rssi": -50, "security": "Open", "rate": 11'
    # an SSID containing ")" must not move its own remainder into the field area (ch 11 / Secured)
    pj=$(line_of "$out" 'a8:bb:cc:00:99:98')
    checkf "tcpdump: SSID with ')' kept verbatim"           "$pj" '"ssid": "x) CH: 11, PRIVACY"'
    check  "tcpdump: ')' injection ignored (ch6/Open/2)"     "$pj" '"channel": 6, "band": "2.4GHz", "freq": 2437, "rssi": -47, "security": "Open", "rate": 2'
    # " CH: 6" WITH its leading space and "PRIVACY," as a whole word inside the SSID
    sj=$(line_of "$out" 'a8:bb:cc:00:99:97')
    checkf "tcpdump: ' CH: 6 ... PRIVACY,' SSID kept verbatim" "$sj" '"ssid": "x CH: 6 [54.0 Mbit] PRIVACY, y"'
    check  "tcpdump: ' CH:' injection ignored (ch11/Open/11)" "$sj" '"channel": 11, "band": "2.4GHz", "freq": 2462, "rssi": -49, "security": "Open", "rate": 11'

    # ---- 5) none path + atomic write -------------------------------------------------------
    empty=$(write_empty 1710000000 "test reason")
    jcheck "none-doc" "$empty"
    check "none: source none"  "$empty" '"source": "none"'
    check "none: note present" "$empty" '"note": "test reason"'
    RESOLVED=none; OUTFILE="$tdir/starchorus.json"; run_cycle
    if [ -s "$OUTFILE" ] && json_ok < "$OUTFILE"; then st_pass "run_cycle wrote valid JSON atomically"; else st_fail "run_cycle output"; fi

    # ---- 6) vendor lookup (passive, local OUI file) + optional fields ---------------------
    vbase() { printf '%s\n' "$base" | add_vendor 2>/dev/null; }          # the post-pass over the emitter document
    vreset() { printf '%s\n' "$(head -n 1 "$OUI_CACHE")" > "$OUI_CACHE"; }   # the cache back to its header line
    # Test MACs: A8:BB:CC / A8:BB:CD / 10:22:33 / 98:76:54 have the U/L bit CLEAR (real OUIs);
    # 9A:... and AA:... have it SET (randomized client / virtual BSSID). Speed -1 = unknown rate.
    rm -f "$CAPDIR"/starchorus-*.csv 2>/dev/null
    cat > "$CAPDIR/starchorus-06.csv" <<'CSV'
BSSID, First time seen, Last time seen, channel, Speed, Privacy, Cipher, Authentication, Power, # beacons, # IV, LAN IP, ID-length, ESSID, Key
A8:BB:CC:00:11:22, 2026-09-13 10:00:00, 2026-09-13 10:05:00, 6, 130, WPA2, CCMP, PSK, -42, 100, 0, 0.0.0.0, 7, AcmeNet,
A8:BB:CD:00:11:23, 2026-09-13 10:00:00, 2026-09-13 10:05:00, 11, 54, WPA2, CCMP, PSK, -61, 10, 0, 0.0.0.0, 6, Quoted,
AA:BB:CC:33:44:55, 2026-09-13 10:00:00, 2026-09-13 10:05:00, 36, -1, OPN, , , -70, 50, 0, 0.0.0.0, 26, "mac": "00:11:22:33:44:55",

Station MAC, First time seen, Last time seen, Power, # packets, BSSID, Probed ESSIDs
10:22:33:44:55:66, 2026-09-13 10:00:00, 2026-09-13 10:05:00, -55, 20, A8:BB:CC:00:11:22,
9A:88:77:66:55:44, 2026-09-13 10:00:00, 2026-09-13 10:05:00, -80, 5, (not associated), FreeWifi
98:76:54:32:10:00, 2026-09-13 10:00:00, 2026-09-13 10:05:00, -85, 1, (not associated),
CSV
    base=$(build_from_csv 1710000000 2>/dev/null)     # plain emitter output (no post-pass)
    checkno "vendor: emitter omits rate for Speed -1" "$(line_of "$base" 'aa:bb:cc:33:44:55')" '"rate"'
    # 6a) nmap format (hit for AP + associated client; duplicate, MA-M/MA-S and comment lines)
    cat > "$tdir/oui-nmap.txt" <<'TXT'
# Nmap MAC prefixes (test file)
A8BBCC Acme Networks
A8BBCC Duplicate Must Lose
A8BBCD Acme "Quoted" \ Corp
102233 Client Corp
0055DA0 Skip MA-M
70B3D5001 Skip MA-S
TXT
    OUI_FILE="$tdir/oui-nmap.txt"; VENDOR=1; setup_vendor 2>/dev/null
    if [ "$OUI_PATH" = "$tdir/oui-nmap.txt" ] && [ -n "$OUI_CACHE" ] && [ -f "$OUI_CACHE" ]; then
        st_pass "vendor: explicit STARCHORUS_OUI_FILE found, cache created"; else st_fail "vendor: setup_vendor"; fi
    out=$(vbase)
    jcheck "vendor(nmap):" "$out"
    check   "vendor(nmap): AP vendor after bssid (first line wins)" "$out" '"bssid": "a8:bb:cc:00:11:22", "vendor": "Acme Networks", "ssid": "AcmeNet"'
    check   "vendor(nmap): associated client vendor"  "$out" '"mac": "10:22:33:44:55:66", "vendor": "Client Corp", "rssi": -55'
    checkf  "vendor(nmap): quote + backslash escaped" "$out" '"vendor": "Acme \"Quoted\" \\ Corp"'
    check   "vendor: rate survives beside vendor"     "$out" '"rate": 130'
    check   "vendor: randomized client flagged"       "$out" '"mac": "9a:88:77:66:55:44", "randomized": true, "rssi": -80'
    checkno "vendor: randomized client has no vendor" "$(line_of "$out" '9a:88:77:66:55:44')" '"vendor"'
    laa=$(line_of "$out" 'aa:bb:cc:33:44:55')
    checkno "vendor: LAA bssid gets no vendor"        "$laa" '"vendor"'
    checkno "vendor: LAA bssid gets no randomized"    "$laa" '"randomized"'
    checkf  "vendor: SSID injection inert"            "$laa" '"ssid": "\"mac\": \"00:11:22:33:44:55\""'
    checkno "vendor: unknown prefix -> no field"      "$(line_of "$out" '98:76:54:32:10:00')" '"vendor"'
    ccache=$(cat "$OUI_CACHE" 2>/dev/null)
    checkf  "vendor: cache header ties cache to file" "$ccache" "# oui=$tdir/oui-nmap.txt size="
    check   "vendor: cache positive entry"            "$ccache" "^A8BBCC${RECON_TAB}Acme Networks\$"
    check   "vendor: cache negative entry"            "$ccache" "^987654${RECON_TAB}\$"
    # 6b) cache reuse: OUI file gone, 2nd run must be served from the cache and not grow it
    n1=$(wc -l < "$OUI_CACHE" | tr -d ' ')
    OUI_PATH="$tdir/oui-gone.txt"
    out2=$(vbase)
    n2=$(wc -l < "$OUI_CACHE" | tr -d ' ')
    if [ "$out" = "$out2" ]; then st_pass "vendor: 2nd run served from cache (byte-identical)"; else st_fail "vendor: cache reuse output"; fi
    if [ "$n1" = "$n2" ] && [ "$n1" -gt 1 ]; then st_pass "vendor: cache unchanged on 2nd run ($n1 lines)"; else st_fail "vendor: cache grew/shrank ($n1 -> $n2)"; fi
    # 6c) macchanger "AA BB CC NAME" and "AA:BB:CC - Name"; a different file restarts the cache
    printf '%s\n' 'A8 BB CC ACME NETWORKS' '10 22 33 CLIENT CORP' 'A8:BB:CD - Dash Style' > "$tdir/oui-mc.txt"
    OUI_FILE="$tdir/oui-mc.txt"; setup_vendor 2>/dev/null
    n3=$(wc -l < "$OUI_CACHE" | tr -d ' ')
    if [ "$n3" = "1" ]; then st_pass "vendor: new file restarts cache (header only)"; else st_fail "vendor: cache restart ($n3 lines)"; fi
    out=$(vbase)
    check "vendor(macchanger): 'AA BB CC NAME'"      "$out" '"bssid": "a8:bb:cc:00:11:22", "vendor": "ACME NETWORKS"'
    check "vendor(macchanger): client"               "$out" '"mac": "10:22:33:44:55:66", "vendor": "CLIENT CORP"'
    check "vendor(dash): 'AA:BB:CC - Name'"          "$out" '"bssid": "a8:bb:cd:00:11:23", "vendor": "Dash Style"'
    # 6d) IEEE oui.txt ((hex) + (base 16) + address lines) and Wireshark manuf (tabs, CRLF, /28)
    { printf 'OUI/MA-L\t\t\t\t\t\tOrganization\ncompany_id\t\t\t\t\t\tOrganization\n\t\t\t\t\t\tAddress\n\n'
      printf 'A8-BB-CC   (hex)\t\tAcme Networks Ltd\nA8BBCC     (base 16)\t\tAcme Networks Ltd\n'
      printf '\t\t\t\t1 Acme Way\n\t\t\t\tAcmeville  CA  90000\n\t\t\t\tUS\n\n'
      printf '10:22:33\tCli\tClient Corp Long\r\n00:55:DA:00:00:00/28\tSkip\tLong Block\r\n'; } > "$tdir/oui-ieee.txt"
    OUI_FILE="$tdir/oui-ieee.txt"; setup_vendor 2>/dev/null
    out=$(vbase)
    jcheck "vendor(ieee):" "$out"
    check "vendor(ieee): '(hex)' line, first wins"   "$out" '"bssid": "a8:bb:cc:00:11:22", "vendor": "Acme Networks Ltd"'
    vcnt=$(printf '%s\n' "$out" | awk '{n+=gsub(/Acme Networks Ltd/,"&")} END{print n+0}')
    if [ "$vcnt" = "1" ]; then st_pass "vendor(ieee): vendor inserted exactly once"; else st_fail "vendor(ieee): inserted x$vcnt"; fi
    check "vendor(manuf): last tab field, CRLF ok"   "$out" '"mac": "10:22:33:44:55:66", "vendor": "Client Corp Long"'
    # 6e) missing OUI file: one log line, no vendor field, randomized still flagged, JSON valid
    VENDOR_STATE=""; OUI_FILE="$tdir/no-such-oui.txt"; setup_vendor 2>"$tdir/log6e"
    check "vendor: missing file logged"              "$(cat "$tdir/log6e")" 'no OUI database found'
    if [ -z "$OUI_PATH" ] && [ -z "$OUI_CACHE" ]; then st_pass "vendor: missing file -> no path, no cache"; else st_fail "vendor: missing file state"; fi
    out=$(vbase)
    jcheck "vendor(none):" "$out"
    checkno "vendor: missing file -> no vendor field" "$out" '"vendor"'
    check   "vendor: missing file -> randomized kept" "$out" '"randomized": true'
    # 6f) run_cycle integration (airodump path) and STARCHORUS_VENDOR=0 => emitter output identical
    OUI_FILE="$tdir/oui-nmap.txt"; VENDOR=1; setup_vendor 2>/dev/null
    RESOLVED=capture; CAP_METHOD=airodump; OUTFILE="$tdir/starchorus.json"; run_cycle
    if [ -s "$OUTFILE" ] && json_ok < "$OUTFILE" && grep -q '"vendor": "Acme Networks"' "$OUTFILE"; then
        st_pass "vendor: run_cycle publishes vendor (airodump path)"; else st_fail "vendor: run_cycle airodump"; fi
    VENDOR=0; setup_vendor 2>/dev/null; run_cycle
    # run_cycle always inserts max_age/interval into the one-line center object, so "identical" means identical apart from that line
    # (and `generated`); the center line itself must be the emitter's line with exactly center_extra() inside its closing brace.
    if ! grep -q '"vendor"' "$OUTFILE" && ! grep -q '"randomized"' "$OUTFILE" && \
       [ "$(grep -v -e '"generated"' -e '"center"' "$OUTFILE")" = "$(printf '%s\n' "$base" | grep -v -e '"generated"' -e '"center"')" ] && \
       [ "$(grep '"center"' "$OUTFILE")" = "$(printf '%s\n' "$base" | grep '"center"' | sed "s/}\(,\{0,1\}\)\$/$(center_extra | sed 's/[\/&]/\\&/g')}\1/")" ]; then
        st_pass "vendor: STARCHORUS_VENDOR=0 -> emitter output byte-identical (apart from the center extras)"; else st_fail "vendor: STARCHORUS_VENDOR=0 output differs"; fi
    VENDOR=1
    # 6g) recon.db path via run_cycle: vendor + last_seen, bare-column integrity, client fields
    if have sqlite3; then
        vdb="$tdir/recon_vendor.db"
        sqlite3 "$vdb" >/dev/null 2>&1 <<'SQL'
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB,
                  hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT);
CREATE TABLE wifi_device(hash INT PRIMARY KEY, scan INT, mac TEXT, time INT, signal INT, freq INT, packets INT);
-- same BSSID twice: ssid/encryption must come from the STRONGER (-55, older, WPA2, "OLD") row,
-- last_seen must be the NEWER time 2000 (SQLite bare-column trap, see build_from_recondb)
INSERT INTO ssid VALUES (1,0,1,8,'A8BBCC000001','HomeNet-OLD',0,1000,-55,2437,6,8);
INSERT INTO ssid VALUES (2,0,2,8,'A8BBCC000001','HomeNet-NEW',0,2000,-77,2437,6,24);
INSERT INTO ssid VALUES (3,0,1,8,'A8BBCD000002','NoTime',0,0,-60,5180,36,8);
INSERT INTO ssid VALUES (4,301,1,4,'FFFFFFFFFFFF','',0,1300,-70,0,0,0);
INSERT INTO ssid VALUES (5,301,2,4,'FFFFFFFFFFFF','',0,1100,-60,0,0,0);
INSERT INTO ssid VALUES (6,302,1,4,'FFFFFFFFFFFF','',0,1500,-90,0,0,0);
INSERT INTO wifi_device VALUES (301,1,'102233AABBCC',1300,-70,0,5);
INSERT INTO wifi_device VALUES (302,1,'9A8877665544',1500,-90,0,1);
SQL
        OUI_FILE="$tdir/oui-nmap.txt"; setup_vendor 2>/dev/null
        RESOLVED=recondb; RECON_DB="$vdb"; run_cycle; RECON_DB=auto
        rout=$(cat "$OUTFILE" 2>/dev/null)
        jcheck "recon+vendor:" "$rout"
        check   "recon: AP vendor via run_cycle"         "$rout" '"bssid": "a8:bb:cc:00:00:01", "vendor": "Acme Networks"'
        check   "recon: last_seen = MAX(time) per AP"    "$rout" '"rssi": -55, "security": "WPA2", "last_seen": 2000'
        check   "recon: bare columns from MAX(signal) row" "$rout" '"ssid": "HomeNet-OLD"'
        checkno "recon: time 0 -> no last_seen"          "$(line_of "$rout" 'NoTime')" '"last_seen"'
        check   "recon: client vendor + last_seen"       "$rout" '"mac": "10:22:33:aa:bb:cc", "vendor": "Client Corp", "rssi": -60, "last_seen": 1300'
        check   "recon: randomized client + last_seen"   "$rout" '"mac": "9a:88:77:66:55:44", "randomized": true, "rssi": -90, "last_seen": 1500'
    fi

    # ---- 6h) cache robustness: the failure paths ------------------------------------------
    # (1) OUI file unreadable/unplugged while a NEW prefix shows up: no negative entry may be
    #     written (it would hide that vendor for good); once the file is back, the vendor appears.
    printf '%s\n' '005056 VMware Inc' >> "$tdir/oui-nmap.txt"
    OUI_FILE="$tdir/oui-nmap.txt"; VENDOR=1; setup_vendor 2>/dev/null      # size changed -> fresh cache
    newcl=$(printf '%s\n' "$base" | sed 's/98:76:54:32:10:00/00:50:56:12:34:56/')
    OUI_PATH="$tdir/oui-gone.txt"
    out=$(printf '%s\n' "$newcl" | add_vendor 2>/dev/null); jrc=$?
    if [ "$jrc" = "0" ] && printf '%s' "$out" | json_ok; then st_pass "cache: unreadable OUI file -> post-pass rc 0, valid JSON"; else st_fail "cache: unreadable OUI file rc=$jrc"; fi
    checkno "cache: unreadable OUI file -> NO negative entry"  "$(cat "$OUI_CACHE")" "^005056${RECON_TAB}\$"
    checkno "cache: unreadable OUI file -> no vendor (yet)"    "$(line_of "$out" '00:50:56:12:34:56')" '"vendor"'
    OUI_PATH="$tdir/oui-nmap.txt"
    out=$(printf '%s\n' "$newcl" | add_vendor 2>/dev/null)
    check   "cache: file back -> vendor found (cache not poisoned)" "$out" '"mac": "00:50:56:12:34:56", "vendor": "VMware Inc"'
    check   "cache: file back -> positive entry cached"        "$(cat "$OUI_CACHE")" "^005056${RECON_TAB}VMware Inc\$"
    # (2) corrupt cache lines: an unterminated last line (crash mid-append) is dropped, a fused
    #     two-tab line and a lowercase prefix are ignored, and those prefixes are resolved again.
    vreset
    { printf 'A8BBCD\tFused\tLine\n'; printf 'a8bbcc\tlowercase\n'
      printf 'A8BBCC\tAcme Net'; } >> "$OUI_CACHE"        # last line cut off, no newline
    out=$(vbase)
    if printf '%s' "$out" | json_ok; then st_pass "cache: corrupt lines -> valid JSON"; else st_fail "cache: corrupt lines JSON"; fi
    checkno "cache: cut-off last line not trusted"          "$out" 'Acme Net"'
    checkno "cache: fused two-tab line not trusted"         "$out" 'Fused'
    checkno "cache: lowercase-prefix line not trusted"      "$out" 'lowercase'
    check   "cache: cut-off prefix resolved from the file"  "$out" '"bssid": "a8:bb:cc:00:11:22", "vendor": "Acme Networks"'
    checkf  "cache: fused-line prefix resolved from the file" "$out" '"vendor": "Acme \"Quoted\" \\ Corp"'
    cc=$(cat "$OUI_CACHE")
    checkno "cache: cut-off line removed from the cache"    "$cc" "Acme Net\$"
    check   "cache: repaired cache got the real entry"      "$cc" "^A8BBCC${RECON_TAB}Acme Networks\$"
    if cache_terminated; then st_pass "cache: cache ends with a newline again"; else st_fail "cache: cache still unterminated"; fi
    # (3) a file in an unknown format ("AABBCC=Vendor") and a directory are rejected up front,
    #     never silently turned into an all-negative cache
    printf '%s\n' 'A8BBCC=Acme Networks' '102233=Client Corp' > "$tdir/oui-weird.txt"
    if oui_format_ok "$tdir/oui-nmap.txt" && oui_format_ok "$tdir/oui-mc.txt" && oui_format_ok "$tdir/oui-ieee.txt" \
       && ! oui_format_ok "$tdir/oui-weird.txt" && ! oui_format_ok "$tdir"; then
        st_pass "cache: format probe accepts nmap/macchanger/ieee, rejects '=' format and a directory"
    else st_fail "cache: format probe"; fi
    VENDOR_STATE=""; OUI_FILE="$tdir/oui-weird.txt"; setup_vendor 2>"$tdir/log6h"
    check "cache: unusable explicit file is logged"    "$(cat "$tdir/log6h")" 'no usable OUI format'
    if [ -z "$OUI_PATH" ] && [ -z "$OUI_CACHE" ]; then st_pass "cache: unusable file -> no path, no cache"; else st_fail "cache: unusable file state ($OUI_PATH)"; fi
    out=$(vbase)
    checkno "cache: unusable file -> no vendor field"   "$out" '"vendor"'
    check   "cache: unusable file -> randomized kept"   "$out" '"randomized": true'
    VENDOR_STATE=""; OUI_FILE="$tdir"; setup_vendor 2>"$tdir/log6h2"
    check "cache: directory as STARCHORUS_OUI_FILE rejected" "$(cat "$tdir/log6h2")" 'no OUI database found'
    # (4) two instances at once on a COLD cache (daemon loop + `--once` from crond): every entry
    #     exactly once, no torn lines, both outputs complete, lock and temp files released
    OUI_FILE="$tdir/oui-nmap.txt"; setup_vendor 2>/dev/null
    vreset
    printf '%s\n' "$base" | add_vendor > "$tdir/par1" 2>/dev/null &
    printf '%s\n' "$base" | add_vendor > "$tdir/par2" 2>/dev/null &
    wait
    dups=$(grep -v '^#' "$OUI_CACHE" | sort | uniq -d | wc -l | tr -d ' ')
    badl=$(grep -v '^#' "$OUI_CACHE" | awk -F "$RECON_TAB" 'NF!=2{n++} END{print n+0}')
    nent=$(grep -vc '^#' "$OUI_CACHE")
    if [ "$dups" = "0" ] && [ "$badl" = "0" ] && [ "$nent" = "4" ]; then
        st_pass "cache: 2 parallel instances -> 4 entries, no duplicates, no torn lines"
    else st_fail "cache: parallel instances (dups=$dups torn=$badl entries=$nent)"; fi
    for pf in par1 par2; do
        if json_ok < "$tdir/$pf" && grep -q '"vendor": "Acme Networks"' "$tdir/$pf" && grep -q '"vendor": "Client Corp"' "$tdir/$pf"; then
            st_pass "cache: parallel instance $pf output complete"; else st_fail "cache: parallel instance $pf output"; fi
    done
    if [ ! -d "$OUI_CACHE.lock" ] && [ -z "$(ls "$OUI_CACHE".new.* 2>/dev/null)" ] \
       && [ -z "$(ls -d "$OUI_CACHE".lock.stale.* 2>/dev/null)" ]; then
        st_pass "cache: lock and temp files released"; else st_fail "cache: lock/temp file left behind"; fi
    # (5) a rewritten OUI file of the SAME byte size (firmware update) restarts the cache (mtime)
    printf '%s\n' 'A8BBCC Acme' > "$tdir/oui-same.txt"; touch -t 202001010000 "$tdir/oui-same.txt" 2>/dev/null
    m1=$(file_mtime "$tdir/oui-same.txt")
    OUI_FILE="$tdir/oui-same.txt"; setup_vendor 2>/dev/null
    out=$(vbase)
    check "cache: mtime baseline vendor"                "$out" '"vendor": "Acme"'
    printf '%s\n' 'A8BBCC Bcme' > "$tdir/oui-same.txt"       # same byte count, new content, newer mtime
    m2=$(file_mtime "$tdir/oui-same.txt")
    if [ -z "$m1" ] || [ -z "$m2" ] || [ "$m1" = "$m2" ]; then
        log "  SKIP: cache: same-size rewrite (mtime unavailable or unchanged here: '$m1' -> '$m2')"
    else
        setup_vendor 2>/dev/null
        out=$(vbase)
        check  "cache: same-size rewritten file restarts the cache (mtime)" "$out" '"vendor": "Bcme"'
        checkf "cache: header carries the mtime"        "$(head -n 1 "$OUI_CACHE")" "mtime=$m2"
    fi
    # (6) a backslash sequence in the OUI/CAPDIR path (stick paths are user input) must survive
    #     every hand-over verbatim: `\t` is an echo escape under dash / bash-as-sh (so paths travel
    #     via printf) AND an awk -v escape (so they travel via ENVIRON). `b\s` would test neither.
    bsd="$tdir/b\\ts"
    mkdir -p "$bsd" && cp "$tdir/oui-nmap.txt" "$bsd/oui.txt"
    save_cap=$CAPDIR; CAPDIR=$bsd; OUI_FILE="$bsd/oui.txt"; VENDOR_STATE=""; setup_vendor 2>"$tdir/log6h6"
    if [ "$OUI_PATH" = "$bsd/oui.txt" ] && [ "$OUI_CACHE" = "$bsd/oui-cache.txt" ]; then
        st_pass "cache: '\\t' in the path resolved verbatim (printf, not echo)"
    else st_fail "cache: '\\t' path mangled (OUI_PATH='$OUI_PATH')"; fi
    out=$(vbase)
    check  "cache: backslash in OUI path handled (ENVIRON, not -v)" "$out" '"vendor": "Acme Networks"'
    check  "cache: backslash in cache path handled"      "$(cat "$bsd/oui-cache.txt" 2>/dev/null)" "^A8BBCC${RECON_TAB}Acme Networks\$"
    checkf "log: backslash sequence printed verbatim"    "$(cat "$tdir/log6h6")" "vendor lookup: $bsd/oui.txt"
    CAPDIR=$save_cap
    # (7) CAPDIR turns read-only after start (full / ro eMMC): the post-pass must still deliver
    #     vendor + randomized (no cache write, no fatal awk). chmod does not stop root (the device
    #     runs everything as root), so the cache is ALSO pointed under a plain file (ENOTDIR for
    #     everyone): mktemp and printf fail there and must not take the awk down.
    OUI_FILE="$tdir/oui-nmap.txt"; setup_vendor 2>/dev/null
    vreset
    if [ "$(id -u 2>/dev/null)" != "0" ]; then
        chmod 555 "$CAPDIR" 2>/dev/null
        out=$(vbase); jrc=$?
        chmod 755 "$CAPDIR" 2>/dev/null
        if [ "$jrc" = "0" ] && printf '%s' "$out" | json_ok; then st_pass "cache: read-only CAPDIR -> post-pass rc 0, valid JSON"; else st_fail "cache: read-only CAPDIR rc=$jrc"; fi
        check "cache: read-only CAPDIR -> vendor still delivered"     "$out" '"vendor": "Acme Networks"'
        check "cache: read-only CAPDIR -> randomized still delivered" "$out" '"randomized": true'
    else
        log "  SKIP: cache: read-only CAPDIR via chmod (no effect for root; ENOTDIR variant below)"
    fi
    printf '' > "$tdir/afile"; save_oc=$OUI_CACHE; OUI_CACHE="$tdir/afile/oui-cache.txt"
    out=$(vbase); jrc=$?
    OUI_CACHE=$save_oc
    if [ "$jrc" = "0" ] && printf '%s' "$out" | json_ok; then st_pass "cache: unwritable cache path (ENOTDIR) -> post-pass rc 0, valid JSON"; else st_fail "cache: ENOTDIR cache path rc=$jrc"; fi
    check "cache: ENOTDIR cache path -> vendor still delivered"     "$out" '"vendor": "Acme Networks"'
    check "cache: ENOTDIR cache path -> randomized still delivered" "$out" '"randomized": true'
    # (8) the periodic re-check (daemon loop) logs only when something changed
    VENDOR_STATE=""; setup_vendor 2>"$tdir/log6i"; setup_vendor 2>>"$tdir/log6i"; setup_vendor 2>>"$tdir/log6i"
    nlog=$(grep -c 'vendor lookup:' "$tdir/log6i")
    if [ "$nlog" = "1" ]; then st_pass "cache: repeated setup_vendor logs once"; else st_fail "cache: repeated setup_vendor logged x$nlog"; fi
    # (9) control bytes: a foreign/rotten cache line (ESC sequence, CR from a CRLF editor) must not
    #     make every cycle emit invalid JSON; an OUI line with a control byte is cleaned on entry
    OUI_FILE="$tdir/oui-nmap.txt"; setup_vendor 2>/dev/null
    vreset
    printf 'A8BBCC\tAcme\033[0m Corp\n102233\tClient Corp\r\n' >> "$OUI_CACHE"
    out=$(vbase)
    if printf '%s' "$out" | json_ok; then st_pass "cache: control bytes in cache lines -> valid JSON"; else st_fail "cache: control bytes in cache lines -> invalid JSON"; fi
    check "cache: ESC stripped from cached vendor"       "$out" '"bssid": "a8:bb:cc:00:11:22", "vendor": "Acme\[0m Corp"'
    check "cache: CR stripped from cached vendor"        "$out" '"mac": "10:22:33:44:55:66", "vendor": "Client Corp", "rssi": -55'
    printf 'A8BBCC Bell\007 Labs\n' > "$tdir/oui-bel.txt"
    OUI_FILE="$tdir/oui-bel.txt"; setup_vendor 2>/dev/null
    out=$(vbase)
    if printf '%s' "$out" | json_ok; then st_pass "vendor: control byte in OUI line -> valid JSON"; else st_fail "vendor: control byte in OUI line -> invalid JSON"; fi
    check "vendor: control byte stripped on entry (BEL)" "$out" '"vendor": "Bell Labs"'
    check "vendor: cache entry written without the BEL"  "$(cat "$OUI_CACHE")" "^A8BBCC${RECON_TAB}Bell Labs\$"
    # (10) a temp file whose last line was cut short (ENOSPC on /tmp, killed awk) must not persist
    #      that line as a "well-formed" wrong vendor; the terminated lines before it are merged
    OUI_FILE="$tdir/oui-nmap.txt"; setup_vendor 2>/dev/null
    vreset
    printf '102233\tClient Corp\nA8BBCC\tAcme Net' > "$tdir/newf-cut"
    cache_append "$tdir/newf-cut"
    cc=$(cat "$OUI_CACHE")
    check   "cache: terminated temp line merged"         "$cc" "^102233${RECON_TAB}Client Corp\$"
    checkno "cache: cut-off temp line NOT merged"        "$cc" "^A8BBCC"
    if cache_terminated && [ ! -d "$OUI_CACHE.lock" ]; then st_pass "cache: cache whole and lock released after the merge"; else st_fail "cache: state after cut temp merge"; fi
    # (11) lock semantics: the holder's liveness decides, never the waiting time
    lk="$OUI_CACHE.lock"
    #   a) lock of a DEAD pid is broken at once
    sh -c 'exit 0' & dpid=$!; wait "$dpid" 2>/dev/null
    mkdir "$lk" && printf '%s\n' "$dpid" > "$lk/pid"
    t0=$(date +%s); cache_lock; lr=$?; t1=$(date +%s)
    if [ "$lr" = "0" ] && [ "$(cat "$lk/pid" 2>/dev/null)" = "$$" ] && [ $((t1-t0)) -le 1 ]; then
        st_pass "lock: dead holder broken at once, lock now ours"; else st_fail "lock: dead holder (rc=$lr, $((t1-t0)) s)"; fi
    cache_unlock
    if [ ! -d "$lk" ]; then st_pass "lock: unlock removed our lock"; else st_fail "lock: unlock left the lock behind"; fi
    #   b) lock without a pid (holder died between mkdir and pid write) is broken after ~3 s grace
    mkdir "$lk"
    t0=$(date +%s); cache_lock; lr=$?; t1=$(date +%s); el=$((t1-t0))
    if [ "$lr" = "0" ] && [ "$el" -ge 2 ] && [ "$el" -le 10 ]; then st_pass "lock: pid-less lock broken after the grace period ($el s)"; else st_fail "lock: pid-less lock (rc=$lr, $el s)"; fi
    cache_unlock
    #   c) lock of a LIVE collector pid is waited for (not broken while it lives), broken once dead.
    #      A holder is a live process whose command line names this script (holder_alive), so the
    #      stand-ins below run as `sh -c '...' "$SELF_BASE"` ("sleep N; exit 0": a lone command
    #      would be exec'ed by bash and the name lost).
    sh -c 'sleep 2; exit 0' "$SELF_BASE" & spid=$!
    mkdir "$lk" && printf '%s\n' "$spid" > "$lk/pid"
    t0=$(date +%s); cache_lock; lr=$?; t1=$(date +%s); el=$((t1-t0))
    wait "$spid" 2>/dev/null
    if [ "$lr" = "0" ] && [ "$el" -ge 1 ] && [ "$el" -le 10 ]; then st_pass "lock: live holder waited for ($el s), broken once dead"; else st_fail "lock: live holder (rc=$lr, $el s)"; fi
    cache_unlock
    #   d) ordering: a holder (own pid, 3 s critical section) appends its line BEFORE releasing;
    #      an add_vendor started meanwhile must merge AFTER it (a spin-count break would invert this)
    vreset
    sh -c 'mkdir "$1" && printf "%s\n" "$$" > "$1/pid"; sleep 3; printf "ZZZZZZ\tHolder\n" >> "$2"; rm -f "$1/pid"; rmdir "$1"' "$SELF_BASE" "$lk" "$OUI_CACHE" &
    hpid=$!
    sleep 1
    t0=$(date +%s)
    out=$(vbase)
    t1=$(date +%s); el=$((t1-t0))
    wait "$hpid" 2>/dev/null
    hl=$(grep -n 'Holder' "$OUI_CACHE" | head -1 | cut -d: -f1); al=$(grep -n '^A8BBCC' "$OUI_CACHE" | head -1 | cut -d: -f1)
    if [ -n "$hl" ] && [ -n "$al" ] && [ "$hl" -lt "$al" ] && [ "$el" -ge 1 ]; then
        st_pass "lock: waited for the live holder ($el s); holder's line precedes ours"
    else st_fail "lock: live holder overtaken (holder line ${hl:-none}, ours ${al:-none}, waited $el s)"; fi
    check "lock: output complete after waiting"          "$out" '"vendor": "Acme Networks"'
    if [ ! -d "$lk" ] && [ -z "$(ls -d "$lk".stale.* 2>/dev/null)" ]; then st_pass "lock: nothing left behind"; else st_fail "lock: leftovers"; fi
    #   e) pid reuse: the pid in a left-over lock (persistent OUTDIR across a reboot / kill -9, pid
    #      wrap) now belongs to a LIVE process that is NOT this collector -> no holder, broken at
    #      once (judged by pid alone it would block every cycle for the whole budget, for good)
    sleep 30 & fpid=$!
    mkdir "$lk" && printf '%s\n' "$fpid" > "$lk/pid"
    t0=$(date +%s); cache_lock; lr=$?; t1=$(date +%s)
    kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
    if [ "$lr" = "0" ] && [ "$(cat "$lk/pid" 2>/dev/null)" = "$$" ] && [ $((t1-t0)) -le 1 ]; then
        st_pass "lock: live FOREIGN pid (pid reuse) is no holder: broken at once"
    else st_fail "lock: foreign live pid (rc=$lr, $((t1-t0)) s)"; fi
    #   f) re-entrant: a nested cache_lock in the SAME process returns at once; the lock is released
    #      only by the matching (outer) cache_unlock
    t0=$(date +%s); cache_lock; lr=$?; t1=$(date +%s)
    if [ "$lr" = "0" ] && [ "$CACHE_LOCKED" = "2" ] && [ $((t1-t0)) -le 1 ]; then st_pass "lock: nested cache_lock re-enters at once (depth 2)"; else st_fail "lock: nested cache_lock (rc=$lr, depth $CACHE_LOCKED, $((t1-t0)) s)"; fi
    cache_unlock
    if [ -d "$lk" ] && [ "$(cat "$lk/pid" 2>/dev/null)" = "$$" ] && [ "$CACHE_LOCKED" = "1" ]; then st_pass "lock: inner unlock keeps the lock (depth 1)"; else st_fail "lock: inner unlock released the lock"; fi
    cache_unlock
    if [ ! -d "$lk" ] && [ "$CACHE_LOCKED" = "0" ]; then st_pass "lock: outer unlock releases it"; else st_fail "lock: outer unlock"; fi
    #   g) cache_unlock must never remove a lock that is not ours, even when this process believes
    #      it holds one (a waiter broke ours while we were stopped and holds it now)
    sh -c 'sleep 5; exit 0' "$SELF_BASE" & fh=$!
    mkdir "$lk" && printf '%s\n' "$fh" > "$lk/pid"
    CACHE_LOCKED=1; cache_unlock
    if [ -d "$lk" ] && [ "$(cat "$lk/pid" 2>/dev/null)" = "$fh" ]; then st_pass "lock: unlock leaves a foreign lock alone"; else st_fail "lock: unlock removed a foreign lock"; fi
    kill "$fh" 2>/dev/null; wait "$fh" 2>/dev/null; rm -rf "$lk"
    #   h) the merge re-checks the header under the lock: lines gathered from the OLD OUI file must
    #      not land under a header setup_vendor has meanwhile written for a NEW one
    vreset
    printf '102233\tClient Corp\n' > "$tdir/newf-hdr"
    save_hdr=$OUI_HDR; OUI_HDR="# oui=$tdir/some-other-file.txt size=1 mtime=1"
    cache_append "$tdir/newf-hdr"; OUI_HDR=$save_hdr
    checkno "lock: merge skipped when the cache was restarted for another file meanwhile" "$(cat "$OUI_CACHE")" '^102233'
    if [ ! -d "$lk" ]; then st_pass "lock: released after the skipped merge"; else st_fail "lock: left behind after the skipped merge"; fi
    #   i) cache_append itself repairs an unterminated cache before appending (no fused line)
    vreset; printf 'A8BBCC\tAcme Net' >> "$OUI_CACHE"
    cache_append "$tdir/newf-hdr"
    cc=$(cat "$OUI_CACHE")
    checkno "cache: merge drops the cut-off line first"      "$cc" 'Acme Net'
    check   "cache: merge appends after the repair"          "$cc" "^102233${RECON_TAB}Client Corp\$"
    if cache_terminated; then st_pass "cache: whole after repair + merge"; else st_fail "cache: unterminated after repair + merge"; fi
    #   j) budget + backoff: a live collector holding the lock longer than LOCK_BUDGET (shortened
    #      here) makes cache_lock give up (rc 2), log ONCE, and skip further lock attempts for 60 s
    #      without waiting; a later success re-arms the log
    sh -c 'sleep 6; exit 0' "$SELF_BASE" & lh=$!
    mkdir "$lk" && printf '%s\n' "$lh" > "$lk/pid"
    save_budget=$LOCK_BUDGET; LOCK_BUDGET=20; LOCK_BUSY_UNTIL=0; LOCK_BUSY_LOGGED=0
    t0=$(date +%s); cache_lock 2>"$tdir/log11j"; lr=$?; t1=$(date +%s); el=$((t1-t0))
    if [ "$lr" = "2" ] && [ "$el" -ge 1 ] && [ "$el" -le 5 ]; then st_pass "lock: live holder past the budget -> rc 2 after $el s"; else st_fail "lock: budget (rc=$lr, $el s)"; fi
    t0=$(date +%s); cache_lock 2>>"$tdir/log11j"; lr=$?; t1=$(date +%s)
    if [ "$lr" = "2" ] && [ $((t1-t0)) -le 1 ]; then st_pass "lock: backoff -> next attempt gives up at once"; else st_fail "lock: backoff (rc=$lr, $((t1-t0)) s)"; fi
    cache_repair 2>>"$tdir/log11j"; cache_append "$tdir/newf-hdr" 2>>"$tdir/log11j"
    nl=$(grep -c 'vendor cache lock' "$tdir/log11j")
    if [ "$nl" = "1" ]; then st_pass "lock: give-up logged exactly once per episode"; else st_fail "lock: give-up logged x$nl"; fi
    check "lock: log names the holder and the budget" "$(cat "$tdir/log11j")" "held by live pid $lh for over 2 s"
    LOCK_BUDGET=$save_budget; LOCK_BUSY_UNTIL=0
    kill "$lh" 2>/dev/null; wait "$lh" 2>/dev/null; rm -rf "$lk"
    cache_lock; lr=$?
    if [ "$lr" = "0" ] && [ "$LOCK_BUSY_LOGGED" = "0" ]; then st_pass "lock: taken again after the episode (log re-armed)"; else st_fail "lock: after episode (rc=$lr)"; fi
    cache_unlock
    #   k) UNBREAKABLE stale lock (dead pid) on a directory that cannot be written (ro remount):
    #      cache_lock / cache_repair must return at once, not spin through the budget
    if [ "$(id -u 2>/dev/null)" != "0" ]; then
        sh -c 'exit 0' & dpid=$!; wait "$dpid" 2>/dev/null
        mkdir "$lk" && printf '%s\n' "$dpid" > "$lk/pid"
        printf 'A8BBCC\tcut' >> "$OUI_CACHE"                   # also damaged: cache_repair wants the lock
        chmod 555 "$CAPDIR" 2>/dev/null
        LOCK_BUSY_UNTIL=0; LOCK_BUSY_LOGGED=0
        t0=$(date +%s); cache_lock 2>/dev/null; lr=$?; cache_repair 2>/dev/null; t1=$(date +%s)
        chmod 755 "$CAPDIR" 2>/dev/null
        if [ "$lr" = "2" ] && [ $((t1-t0)) -le 1 ]; then st_pass "lock: unbreakable lock on a read-only directory -> give up at once (rc 2, $((t1-t0)) s)"; else st_fail "lock: ro dir + stale lock (rc=$lr, $((t1-t0)) s)"; fi
        LOCK_BUSY_UNTIL=0; LOCK_BUSY_LOGGED=0; rm -rf "$lk"
        cache_repair
        if cache_terminated; then st_pass "cache: repaired once writable again"; else st_fail "cache: still damaged after ro episode"; fi
    else
        log "  SKIP: lock: read-only directory via chmod (no effect for root)"
    fi
    #   l) daemon start-up sweep: temp files and the lock of a pid that is no live collector go,
    #      those of a live collector (our own pid runs this script) stay
    sh -c 'exit 0' & dpid=$!; wait "$dpid" 2>/dev/null
    mkdir "$lk" && printf '%s\n' "$dpid" > "$lk/pid"
    : > "$OUI_CACHE.new.$dpid.abc"; : > "$OUI_CACHE.fix.$dpid"; : > "$OUI_CACHE.new.$$.abc"; mkdir "$lk.stale.xyz"
    sweep_stale_cache_files 2>"$tdir/log11l"
    if [ ! -d "$lk" ] && [ ! -e "$OUI_CACHE.new.$dpid.abc" ] && [ ! -e "$OUI_CACHE.fix.$dpid" ] && [ ! -d "$lk.stale.xyz" ] && [ -e "$OUI_CACHE.new.$$.abc" ]; then
        st_pass "sweep: dead pid's lock + temp files removed, live collector's kept"
    else st_fail "sweep: lock=$([ -d "$lk" ] && echo kept || echo gone) new.dead=$([ -e "$OUI_CACHE.new.$dpid.abc" ] && echo kept || echo gone) new.own=$([ -e "$OUI_CACHE.new.$$.abc" ] && echo kept || echo gone)"; fi
    check "sweep: stale lock removal is logged" "$(cat "$tdir/log11l")" "removing stale vendor cache lock left by pid $dpid"
    rm -f "$OUI_CACHE.new.$$.abc"
    mkdir "$lk" && printf '%s\n' "$$" > "$lk/pid"
    sweep_stale_cache_files 2>/dev/null
    if [ -d "$lk" ]; then st_pass "sweep: lock of a live collector kept"; else st_fail "sweep: removed a live collector's lock"; fi
    rm -rf "$lk"
    # (12) the loader must not trust a cut-off last cache line when cache_repair could not drop it
    #      (unwritable directory): the shell passes SC_TERM, the awk commits lines one behind
    vreset; printf 'A8BBCC\tAcme Net' >> "$OUI_CACHE"
    out=$(printf '%s\n' "$base" | SC_CACHE="$OUI_CACHE" SC_OUI="" SC_NEWF="" SC_TERM=0 awk "$AWK_JSON_HELPERS$AWK_VENDOR" 2>/dev/null)
    checkno "loader: cut-off last line ignored when unrepaired (SC_TERM=0)" "$out" 'Acme Net"'
    out=$(printf '%s\n' "$base" | SC_CACHE="$OUI_CACHE" SC_OUI="" SC_NEWF="" SC_TERM=1 awk "$AWK_JSON_HELPERS$AWK_VENDOR" 2>/dev/null)
    check   "loader: same line served when the cache is whole (SC_TERM=1)"  "$out" '"vendor": "Acme Net"'
    if [ "$(id -u 2>/dev/null)" != "0" ]; then
        chmod 555 "$CAPDIR" 2>/dev/null
        out=$(vbase); jrc=$?
        chmod 755 "$CAPDIR" 2>/dev/null
        checkno "loader: ro CAPDIR + cut-off line -> not served (rc $jrc)"   "$out" 'Acme Net"'
        check   "loader: ro CAPDIR + cut-off line -> resolved from the file" "$out" '"vendor": "Acme Networks"'
        if ! cache_terminated; then st_pass "cache: ro CAPDIR -> nothing appended onto the cut-off line"; else st_fail "cache: ro CAPDIR -> cache was written"; fi
    fi
    cache_repair
    if cache_terminated; then st_pass "cache: repaired once the directory is writable again"; else st_fail "cache: repair failed"; fi
    # (13) a post-pass that FAILS after gathering its lines (rc != 0 -- here: a closed stdout, the
    #      stand-in for ENOSPC on /tmp or a killed awk) must merge nothing: run_cycle discards that
    #      JSON, and its temp file may hold a cut-off line
    OUI_FILE="$tdir/oui-nmap.txt"; setup_vendor 2>/dev/null
    vreset
    printf '%s\n' "$base" | add_vendor >&- 2>/dev/null; jrc=$?
    if [ "$jrc" != "0" ]; then
        if [ "$(grep -vc '^#' "$OUI_CACHE")" = "0" ]; then st_pass "cache: failed post-pass (rc $jrc) merged nothing"; else st_fail "cache: failed post-pass (rc $jrc) merged lines"; fi
    else log "  SKIP: cache: failed post-pass (awk here returns 0 on a closed stdout)"; fi
    if [ -z "$(ls "$OUI_CACHE".new.* 2>/dev/null)" ]; then st_pass "cache: temp file removed after a failed pass"; else st_fail "cache: temp file left after a failed pass"; fi
    # (14) a cache that is EMPTY (a header cut short by ENOSPC and dropped by the repair), one whose
    #      header lacks its newline, or one that is GONE (tmpfs cleaner) must be rebuilt by the very
    #      next merge -- not first by the daemon's 120-cycle re-check (until then every cycle would
    #      scan the whole OUI file, take the lock and rewrite nothing)
    OUI_FILE="$tdir/oui-nmap.txt"; setup_vendor 2>/dev/null
    for cs in empty noeol gone; do
        case "$cs" in
            empty) : > "$OUI_CACHE" ;;
            noeol) printf '%s' "$OUI_HDR" > "$OUI_CACHE" ;;
            gone)  rm -f "$OUI_CACHE" ;;
        esac
        out=$(vbase)
        check  "cache($cs): vendor delivered"                     "$out" '"vendor": "Acme Networks"'
        checkf "cache($cs): header rewritten by the merge"        "$(head -n 1 "$OUI_CACHE" 2>/dev/null)" "$OUI_HDR"
        check  "cache($cs): entries appended under it"            "$(cat "$OUI_CACHE" 2>/dev/null)" "^A8BBCC${RECON_TAB}Acme Networks\$"
        nh=$(grep -c '^#' "$OUI_CACHE" 2>/dev/null)
        if [ "$nh" = "1" ] && cache_terminated; then st_pass "cache($cs): exactly one header, whole file"; else st_fail "cache($cs): headers x$nh"; fi
    done
    # (15) publication is decoupled from the merge: with the cache lock held by another live
    #      collector, run_cycle must publish the JSON (with vendor) BEFORE it waits for the lock
    OUI_FILE="$tdir/oui-nmap.txt"; setup_vendor 2>/dev/null
    vreset          # cold: there will be lines to merge
    RESOLVED=capture; CAP_METHOD=airodump; OUTFILE="$tdir/starchorus.json"; rm -f "$OUTFILE"
    sh -c 'sleep 8; exit 0' "$SELF_BASE" & lh=$!
    mkdir "$lk" && printf '%s\n' "$lh" > "$lk/pid"
    save_budget=$LOCK_BUDGET; LOCK_BUDGET=50; LOCK_BUSY_UNTIL=0; LOCK_BUSY_LOGGED=0
    t0=$(date +%s)
    run_cycle 2>/dev/null &
    cpid=$!
    pub=""; w=0
    while [ "$w" -lt 20 ]; do
        if grep -q '"vendor": "Acme Networks"' "$OUTFILE" 2>/dev/null && [ -d "$lk" ] && [ "$(cat "$lk/pid" 2>/dev/null)" = "$lh" ]; then pub=$(date +%s); break; fi
        sleep 0.2 2>/dev/null || sleep 1; w=$((w+1))
    done
    wait "$cpid" 2>/dev/null; t1=$(date +%s)
    if [ -n "$pub" ] && [ $((pub-t0)) -le 4 ]; then st_pass "run_cycle: JSON published while the cache lock was still held ($((pub-t0)) s)"; else st_fail "run_cycle: publication waited for the lock (published after ${pub:-never})"; fi
    if [ $((t1-t0)) -ge 4 ]; then st_pass "run_cycle: the merge itself waited for the lock ($((t1-t0)) s, budget 5)"; else st_fail "run_cycle: merge did not wait ($((t1-t0)) s)"; fi
    if [ "$(grep -vc '^#' "$OUI_CACHE")" = "0" ]; then st_pass "run_cycle: nothing merged under a foreign live lock"; else st_fail "run_cycle: merged under a foreign live lock"; fi
    if [ -z "$(ls "$OUI_CACHE".new.* 2>/dev/null)" ]; then st_pass "run_cycle: deferred temp file removed"; else st_fail "run_cycle: deferred temp file left"; fi
    LOCK_BUDGET=$save_budget; LOCK_BUSY_UNTIL=0; LOCK_BUSY_LOGGED=0
    kill "$lh" 2>/dev/null; wait "$lh" 2>/dev/null; rm -rf "$lk"
    run_cycle 2>/dev/null
    check "run_cycle: merged once the lock is free" "$(cat "$OUI_CACHE")" "^A8BBCC${RECON_TAB}Acme Networks\$"

    # ---- 6k) a crond `--once` finishing while the daemon's cycle is still emitting (on the device
    #          the DB copy + queries take a second or more, so the overlap is routine): its EXIT
    #          cleanup must touch only ITS OWN artefacts -- not the daemon's temp file (the daemon
    #          would then publish source=none for one interval), not the loop pidfile (--status
    #          "not running", --stop only via the ps backstop), not an airodump it did not start.
    #          A REAL second process is needed: a subshell shares $$ and could not tell them apart.
    if have sqlite3; then
        PIDDIR="$tdir"; LOOP_PIDFILE="$tdir/starchorus-loop.pid"; AIRODUMP_PIDFILE="$tdir/starchorus-airodump.pid"
        odb="$tdir/recon_once.db"
        sqlite3 "$odb" >/dev/null 2>&1 <<'SQL'
CREATE TABLE ssid(hash INT PRIMARY KEY, wifi_device INT, scan INT, type INT, bssid TEXT, ssid BLOB,
                  hidden INT, time INT, signal INT, freq INT, channel INT, encryption INT);
CREATE TABLE wifi_device(hash INT PRIMARY KEY, scan INT, mac TEXT, time INT, signal INT, freq INT, packets INT);
INSERT INTO ssid VALUES (1,0,1,8,'A8BBCC0000CE','OnceNet',0,0,-50,2437,6,8);
SQL
        printf '%s\n' "$base" > "$tdir/base.json"
        printf '%s\n' "$$" > "$LOOP_PIDFILE"                       # the "daemon" (this process) is registered
        sleep 30 & fake_ad=$!; printf '%s\n' "$fake_ad" > "$AIRODUMP_PIDFILE"   # an airodump the --once did not start
        rm -f "$tdir/go"
        # the daemon's cycle: its emitter holds $OUTFILE.tmp.<pid> open until the go-file appears
        ( build_from_csv() { w=0; while [ ! -e "$tdir/go" ] && [ "$w" -lt 150 ]; do sleep 0.2 2>/dev/null || sleep 1; w=$((w+1)); done; cat "$tdir/base.json"; }
          VENDOR=0; RESOLVED=capture; CAP_METHOD=airodump; OUTFILE="$tdir/starchorus.json"; run_cycle ) &
        dpid=$!
        sleep 1
        STARCHORUS_OUTDIR="$tdir" STARCHORUS_SOURCE=recondb STARCHORUS_RECON_DB="$odb" STARCHORUS_VENDOR=0 STARCHORUS_CREATE_MON=0 \
            sh "$0" --once >"$tdir/once.out" 2>"$tdir/once.log"; orc=$?
        : > "$tdir/go"
        wait "$dpid" 2>/dev/null
        if [ "$orc" = "0" ] && grep -q 'single cycle complete' "$tdir/once.log"; then st_pass "once: real --once process ran a recondb cycle in the same OUTDIR"; else st_fail "once: --once rc=$orc ($(tail -n 1 "$tdir/once.log" 2>/dev/null))"; fi
        oj=$(cat "$tdir/starchorus.json" 2>/dev/null)
        check   "once: daemon's overlapping cycle still published its data" "$oj" '"ssid": "AcmeNet"'
        checkno "once: daemon's cycle was not turned into source=none"      "$oj" '"source": "none"'
        if [ "$(cat "$LOOP_PIDFILE" 2>/dev/null)" = "$$" ]; then st_pass "once: loop pidfile of the daemon survives a --once"; else st_fail "once: loop pidfile after --once: $([ -f "$LOOP_PIDFILE" ] && cat "$LOOP_PIDFILE" || echo MISSING)"; fi
        if [ -f "$AIRODUMP_PIDFILE" ] && pid_alive "$fake_ad"; then st_pass "once: airodump it did not start is left running (pidfile kept)"; else st_fail "once: foreign airodump killed / pidfile removed"; fi
        kill "$fake_ad" 2>/dev/null; wait "$fake_ad" 2>/dev/null; rm -f "$AIRODUMP_PIDFILE" "$LOOP_PIDFILE"
        set -- "$tdir"/starchorus.json.tmp.*
        if [ ! -e "$1" ]; then st_pass "once: no temp file left by either instance"; else st_fail "once: temp files left: $*"; fi
    else
        log "  SKIP: once: overlap test needs sqlite3"
    fi

    # ---- 6l) kill_loops scope and honesty: one collector runs per device, so a start or a stop stops
    #          EVERY collector loop, not only this OUTDIR's. Each loop killed that is NOT this OUTDIR's
    #          own is logged with its pid and working directory; our own loop (named by the pidfile) is
    #          not double-reported; and a --once / --status run (a "--" on its command line) is never
    #          touched. The stand-in loops are real processes, but kill_loops sees them only through a
    #          stand-in `ps` that prints a fixed table in the BusyBox 1.36 `ps w` layout ("PID USER VSZ
    #          STAT COMMAND", COMMAND as "{starchorus-coll} /bin/sh ./starchorus-collect.sh" when the
    #          comm differs, or plain "sh /path/..."), with the recorded pids. So the real grep is checked
    #          against device-format lines, the real `ps` is never consulted (on the device it would list
    #          the operator's own collector), and a stand-in `readlink` answers /proc/PID/cwd from a map.
    #          Every wait is bounded (0.2 s polls, ~10 s); the stand-ins hold no inherited descriptor
    #          (a survivor would keep a caller's pipe open) and are killed by recorded pid at the end.
    klw="$tdir/klscope"; klbin="$klw/bin"; mkdir -p "$klbin" "$klw/d1" "$klw/d2" "$klw/own" "$klw/status"
    printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "$klw/d1/starchorus-collect.sh"
    for kd in d2 own status; do cp "$klw/d1/starchorus-collect.sh" "$klw/$kd/starchorus-collect.sh"; done
    chmod +x "$klw"/*/starchorus-collect.sh
    # shellcheck disable=SC2016   # script text for the stand-in, expanded when it runs
    printf '#!/bin/sh\n# stand-in BusyBox `ps w`: the prepared table\ncat "$KLTAB"\n' > "$klbin/ps"
    cat > "$klbin/readlink" <<'KLRL'
#!/bin/sh
# stand-in readlink: /proc/PID/cwd from $KLMAP (lines "PID DIR"); unmapped -> nothing, exit 1 (the fallback)
case $1 in
  /proc/*/cwd) klp=${1#/proc/}; klp=${klp%/cwd}
    awk -v k="$klp" '$1 == k { $1 = ""; sub(/^ /, ""); print; f = 1 } END { exit !f }' "$KLMAP" 2>/dev/null; exit $? ;;
esac
exit 1
KLRL
    chmod +x "$klbin/ps" "$klbin/readlink"
    # shellcheck disable=SC2086   # $2 is an optional flag (--status) or nothing
    # Detached (double fork): the stand-in is re-parented away from this shell, as another collector loop
    # would be, so kill_loops does not skip it as one of this run's own subshells (is_own_child).
    kl_spawn() {
        ( ( cd "$klw/$1" && exec sh "$klw/$1/starchorus-collect.sh" $2 ) </dev/null >/dev/null 2>&1 & echo $! > "$klw/spawn.pid" )
        klsp=$(cat "$klw/spawn.pid"); KLPIDS="$KLPIDS $klsp"
    }
    kl_wait() {   # kl_wait PID -> 0 once PID is gone, 1 after ~10 s (0.2 s polls)
        kli=0
        while kill -0 "$1" 2>/dev/null && [ "$kli" -lt 50 ]; do sleep 0.2 2>/dev/null || { sleep 1; kli=$((kli + 4)); }; kli=$((kli + 1)); done
        ! kill -0 "$1" 2>/dev/null
    }
    kl_cleanup() {   # kill every stand-in still alive by recorded pid; reap only the dead (never blocks)
        for klp in $KLPIDS; do kill -9 "$klp" 2>/dev/null; done
        for klp in $KLPIDS; do kl_wait "$klp" && wait "$klp" 2>/dev/null; done
    }
    KLPIDS=""
    exec 4>&2 2>/dev/null   # no job "Terminated" lines while stand-ins come and go
    kl_spawn d1; klf1=$klsp; kl_spawn d2; klf2=$klsp; kl_spawn own; klown=$klsp; kl_spawn status --status; klst=$klsp
    exec 2>&4 4>&-
    {   printf '  PID USER       VSZ STAT COMMAND\n'
        printf '%5s root      1508 S    {starchorus-coll} /bin/sh %s/d1/starchorus-collect.sh\n' "$klf1" "$klw"
        printf '%5s root      1508 S    sh %s/d2/starchorus-collect.sh\n' "$klf2" "$klw"
        printf '%5s root      1508 S    {starchorus-coll} /bin/sh ./starchorus-collect.sh\n' "$klown"
        printf '%5s root      1508 S    {starchorus-coll} /bin/sh ./starchorus-collect.sh --status\n' "$klst"
        printf '%5s root      1200 S    sleep 1\n' 1
        printf '%5s root      1200 S    grep starchorus-collect.sh\n' 2
    } > "$klw/ps.txt"
    printf '%s %s\n' "$klf1" "$klw/d1" > "$klw/proc.map"   # d1 mapped (its directory is reported); d2 unmapped (the fallback)
    export KLTAB="$klw/ps.txt" KLMAP="$klw/proc.map"
    klsave=$PATH; PATH="$klbin:$PATH"
    kill_loops stop "$klown" 2>"$klw/kl.log"           # the --stop path: own loop already reported by stop_pidfile
    PATH=$klsave
    exec 4>&2 2>/dev/null
    kl_wait "$klf1"; klr1=$?; kl_wait "$klf2"; klr2=$?; kl_wait "$klown"; klro=$?
    kill -0 "$klst" 2>/dev/null; klrs=$?
    for klp in "$klf1" "$klf2" "$klown"; do kill -0 "$klp" 2>/dev/null || wait "$klp" 2>/dev/null; done   # reap the dead only
    exec 2>&4 4>&-
    klbad=""
    [ "$klr1" = 0 ] || klbad="$klbad foreign1-alive-after-10s"
    [ "$klr2" = 0 ] || klbad="$klbad foreign2-alive-after-10s"
    [ "$klro" = 0 ] || klbad="$klbad own-alive-after-10s"
    [ "$klrs" = 0 ] || klbad="$klbad status-killed"
    grep -qF "also stopped collector loop pid $klf1 in $klw/d1 (one collector per device)" "$klw/kl.log" || klbad="$klbad no-foreign1-report"
    grep -qF "also stopped collector loop pid $klf2 in unknown directory (one collector per device)" "$klw/kl.log" || klbad="$klbad no-foreign2-fallback"
    grep -q "pid $klown " "$klw/kl.log" && klbad="$klbad own-double-reported"
    grep -q "pid $klst " "$klw/kl.log" && klbad="$klbad status-reported"
    grep -qE "pid (1|2) " "$klw/kl.log" && klbad="$klbad sleep-or-grep-line-matched"
    if [ -z "$klbad" ]; then st_pass "kill_loops --stop (BusyBox ps w lines): foreign loops stopped and reported with directory (d1 named, d2 -> unknown directory); own loop not double-reported; --status untouched"; else st_fail "kill_loops --stop scope/honesty:$klbad"; fi
    # start-up "replace" wording: each loop replaced is reported (one collector per device)
    exec 4>&2 2>/dev/null
    kl_spawn d1; klf3=$klsp
    exec 2>&4 4>&-
    { printf '  PID USER       VSZ STAT COMMAND\n'; printf '%5s root      1508 S    {starchorus-coll} /bin/sh %s/d1/starchorus-collect.sh\n' "$klf3" "$klw"; } > "$klw/ps.txt"
    printf '%s %s\n' "$klf3" "$klw/d1" > "$klw/proc.map"
    PATH="$klbin:$PATH"
    kill_loops replace 2>"$klw/kl2.log"
    PATH=$klsave
    exec 4>&2 2>/dev/null
    kl_wait "$klf3"; klr3=$?; kill -0 "$klf3" 2>/dev/null || wait "$klf3" 2>/dev/null
    exec 2>&4 4>&-
    klbad=""
    [ "$klr3" = 0 ] || klbad="$klbad foreign3-alive-after-10s"
    grep -qF "replaced collector loop pid $klf3 in $klw/d1: one collector per device" "$klw/kl2.log" || klbad="$klbad no-replace-report"
    if [ -z "$klbad" ]; then st_pass "kill_loops start-up: each replaced loop reported (one collector per device)"; else st_fail "kill_loops replace wording:$klbad"; fi
    # a subshell of THIS run looks like a loop in BusyBox `ps w` but is never one: skipped, not reported
    if [ -r "/proc/$$/status" ]; then
        exec 4>&2 2>/dev/null
        ( cd "$klw/d1" && exec sh "$klw/d1/starchorus-collect.sh" ) </dev/null >/dev/null 2>&1 & klch=$!
        exec 2>&4 4>&-
        { printf '  PID USER       VSZ STAT COMMAND\n'; printf '%5s root      1508 S    {starchorus-coll} /bin/sh %s/d1/starchorus-collect.sh\n' "$klch" "$klw"; } > "$klw/ps.txt"
        : > "$klw/proc.map"
        PATH="$klbin:$PATH"
        kill_loops replace 2>"$klw/kl3.log"
        PATH=$klsave
        sleep 1
        if kill -0 "$klch" 2>/dev/null && ! grep -q "pid $klch " "$klw/kl3.log"; then
            st_pass "kill_loops: this run's own subshell is skipped and not reported"
        else st_fail "kill_loops: own subshell killed or reported"; fi
        exec 4>&2 2>/dev/null; kill -9 "$klch" 2>/dev/null; wait "$klch" 2>/dev/null; exec 2>&4 4>&-
    else
        log "  SKIP: kill_loops own-subshell case needs /proc"
    fi
    exec 4>&2 2>/dev/null
    kl_cleanup
    exec 2>&4 4>&-
    klleft=""; for klp in $KLPIDS; do kill -0 "$klp" 2>/dev/null && klleft="$klleft $klp"; done
    if [ -z "$klleft" ]; then st_pass "kill_loops: no stand-in loop left running"; else st_fail "kill_loops: stand-ins still alive after kill -9:$klleft"; fi
    unset KLTAB KLMAP

    # ---- 6j) run_cycle must not publish a post-pass result that is structurally wrong even when
    #          the pass returned 0 (an awk write error not reflected in its exit code). The mutants
    #          replace add_vendor for the rest of the run (POSIX sh cannot copy a function back),
    #          so this block stays LAST.
    OUI_FILE="$tdir/oui-nmap.txt"; VENDOR=1; setup_vendor 2>/dev/null
    RESOLVED=capture; CAP_METHOD=airodump; OUTFILE="$tdir/starchorus.json"
    add_vendor() { printf '{"partial": true\n'; return 0; }          # fewer lines, no closing brace
    run_cycle
    if json_ok < "$OUTFILE" && grep -q '"ssid": "AcmeNet"' "$OUTFILE" && ! grep -q partial "$OUTFILE"; then
        st_pass "run_cycle: truncated post-pass output (rc 0) discarded, emitter JSON published"
    else st_fail "run_cycle: truncated post-pass output published"; fi
    add_vendor() { sed '$d'; printf '"junk": 1\n'; return 0; }       # same line count, last line not "}"
    run_cycle
    if json_ok < "$OUTFILE" && grep -q '"ssid": "AcmeNet"' "$OUTFILE" && ! grep -q junk "$OUTFILE"; then
        st_pass "run_cycle: post-pass output without closing brace (rc 0) discarded"
    else st_fail "run_cycle: broken post-pass tail published"; fi

    rm -rf "$tdir" 2>/dev/null
    if [ "$ST_FAILS" = "0" ]; then log "SELFTEST: ALL PASS ($ST_PASS checks)"; else log "SELFTEST: $ST_FAILS FAILURES, $ST_PASS passed (see above)"; fi
    [ "$ST_FAILS" = "0" ]
}

usage() {
    # the USAGE/CONFIG block of the header, selected by its first and last line (not by line numbers)
    sed -n '/^# USAGE:$/,/one log line\.  (default auto)$/p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
}

# --------------------------------------------------------------------------- main
case "$1" in
    --stop)      mkdir -p "$OUTDIR" 2>/dev/null; stop_instances;   exit 0 ;;
    --status)    status_instances; exit 0 ;;
    --selftest)  selftest; exit $? ;;
    --help|-h)   usage; exit 0 ;;
esac

mkdir -p "$OUTDIR" "$CAPDIR" "$PIDDIR" 2>/dev/null

# Locate the local OUI file + cache once (logs once if none; never fatal).
setup_vendor

resolve_source
log "resolved data source: $RESOLVED  (interface: ${MONIF:-n/a}, created_mon=$CREATED_MON)"

if [ "$RESOLVED" = "none" ]; then
    ts=$(date +%s 2>/dev/null); [ -n "$ts" ] || ts=0
    write_empty "$ts" "no passive data source available (need tcpdump/airodump-ng + monitor iface, or a readable recon.db)" > "$OUTFILE"
    log "no usable passive source; wrote an empty document to $OUTFILE"
    log "hint: set STARCHORUS_IFACE=<monitor-if>, or STARCHORUS_RECON_DB=<path>, or (ACTIVE) STARCHORUS_ALLOW_ACTIVE=1."
    exit 1
fi

# If we resolved to our own airodump capture, start it once and let it keep the CSV fresh.
if [ "$RESOLVED" = "capture" ] && have airodump-ng; then
    start_airodump || log "airodump start failed; will fall back to tcpdump bursts"
fi
[ "$RESOLVED" = "capture" ] && [ "$CAP_METHOD" = "" ] && CAP_METHOD="tcpdump"

# Signals clean up AND exit (a returning handler would otherwise resume the loop); EXIT only cleans.
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap cleanup EXIT

if [ "$1" = "--once" ]; then
    # For a single cycle with airodump, give it a moment to populate the CSV.
    [ "$CAP_METHOD" = "airodump" ] && sleep "$INTERVAL"
    run_cycle
    log "single cycle complete -> $OUTFILE"
    exit 0
fi

# Daemon loop. Idempotent start: stop ANY collector loop already running for this script first
# (pidfile-tracked or orphaned) so repeated starts -- e.g. re-running the payload -- never stack
# duplicate loops fighting over one starchorus.json. kill_loops() skips our own PID and reports every
# other collector loop it replaces (one collector per device).
kill_loops replace
sweep_stale_cache_files
echo $$ > "$LOOP_PIDFILE"
log "collecting every ${INTERVAL}s -> $OUTFILE (Ctrl-C or --stop to end; loop pid $$)"
cyc=0
while :; do
    run_cycle
    # Every 120 cycles (10 min at the default interval) re-check the OUI file: a replaced /
    # rewritten file (firmware update, swapped USB stick) restarts the cache. Cheap: a few stats.
    cyc=$((cyc+1)); if [ "$cyc" -ge 120 ]; then cyc=0; setup_vendor; fi
    # A plain foreground sleep: under busybox ash a caught INT/TERM is handled after the current
    # sleep returns, so --stop takes effect within at most one INTERVAL (verified on the device).
    # Backgrounding the sleep and `wait`-ing on it does NOT deliver the trap sooner under ash and
    # left the process running.
    sleep "$INTERVAL"
done

# =============================================================================================
# NOTES / DEVICE FACTS (read-only checks on the device, OpenWrt 24.10.1 with BusyBox 1.36.1, and on
# the AP-service binary and UCI configs of its unpacked firmware image).
#   1. INTERFACES (confirmed live via `iw dev`): radio0 = 2.4GHz (mgmt `wlan0mgmt`, client
#      `wlan0cli`, and a 2.4 monitor `wlan0mon`); `wlan1mon` is the recon engine's
#      channel-hopping monitor; a staged USB adapter is `wlan2mon`. Override STARCHORUS_IFACE=<name>.
#      Auto-mode prefers wlan1mon, then any non-wlan0mon monitor, then the first; it never
#      touches the mgmt radio and only creates/removes a VIF it made itself (none, on the device).
#   2. SINGLE RECON RADIO: wlan1mon is owned by the Recon engine, which channel-hops. Do NOT run
#      a 2nd airodump on that PHY. Auto-mode therefore prefers reading recon.db (zero
#      contention). Force with STARCHORUS_SOURCE=recondb (read engine) or =capture (own tcpdump).
#   3. RECON DB: `/root/recon/recon.db` (== /mmc/root/recon/recon.db); schema families, copy and
#      read-only access: see build_from_recondb. `encryption` values CONFIRMED against real nets on
#      the device: 0=Open (e.g. "OpenGuest"); bit3(=8)=WPA2 (majority); bit4(=16)=WPA3; bit3+bit4
#      => WPA2/WPA3 transition; bit2(=4)=WPA; large 64-bit ints (AKM/cipher bits high up).
#   4. TOOLS (present on the device): sqlite3, tcpdump, iw, iwinfo, jq, curl, wget,
#      nc, crond, and coreutils `timeout` are pre-installed. airodump-ng and python3 are NOT.
#      awk/grep are busybox (no `grep -P`, no gawk-only awk functions). So on the device the
#      recon.db path works out of the box; the capture fallback is tcpdump (not airodump).
#   5. OUTPUT DIR: defaults to /tmp/starchorus (volatile). For persistence use the loot convention on
#      the internal eMMC: STARCHORUS_OUTDIR=/root/loot/starchorus (== /mmc/root/loot/starchorus). There is NO
#      SD card and NO /sd on the device. Serve index.html from there.
#   6. iw scan is ACTIVE (transmits probes) and lists APs only -- left OFF unless you set
#      STARCHORUS_ALLOW_ACTIVE=1 on purpose.
#   7. CLIENT<->AP LINKS: only airodump CSV yields real associations (from overheard data
#      frames). recondb lists probe-req senders as `unassociated`; tcpdump/recondb/iwscan leave
#      per-AP clients:[] empty -- that is expected and schema-valid.
#   8. MANAGEMENT: SSH as root@<device> (tools/install.sh has the default address); mgmt_iface()
#      knows the management addresses.
#   9. MAC VENDOR (OUI) FILES, all already on the device, read-only, nothing fetched:
#      /lib/hak5/oui.txt (the firmware's own, used by the device UI; FORMAT NOT YET VERIFIED ON DEVICE --
#      run `head -5 /lib/hak5/oui.txt; wc -lc /lib/hak5/oui.txt` and note it here),
#      /usr/share/nmap/nmap-mac-prefixes (`AABBCC Vendor`, upstream also has 7/9-hex MA-M/MA-S
#      lines which are skipped), /usr/share/macchanger/OUI.list (`AA BB CC VENDOR`, dated).
#      Override with STARCHORUS_OUI_FILE=<path> (e.g. a newer file on a USB stick). Parser, cache and
#      lock: see VENDOR LOOKUP. Expect the first cycle with many new prefixes to take a few seconds
#      on the MIPS CPU (one full file scan), later cycles to be near-free.
#      NOT covered by --selftest (timing races, documented rather than faked): a live holder
#      grabbing a fresh lock in the microseconds between a breaker's check and its rename
#      (cache_break gives it back), and setup_vendor's restart racing an in-flight merge (the
#      header re-check under the lock is tested; the restart-under-lock itself is not).
# =============================================================================================
