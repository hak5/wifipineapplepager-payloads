#!/bin/sh
# Title: GS Drone Detector
# Author: GhostStrats
# Description: Passive Wi-Fi SSID candidate tracker with RSSI bar and Pager alert requests
# Version: Community submission rebuild 1.2 (cancelable scan)
# Category: Reconnaissance
# Target: Hak5 WiFi Pineapple Pager
# Dependencies: iw, awk; tcpdump and timeout for monitor-mode captures
# This is a reconstructed implementation, NOT a byte-for-byte copy of the author's GitHub script.
# Names are not aircraft identification; RSSI cannot measure distance.

WINDOW=${GS_SCAN_WINDOW:-1}
IFACE=${GS_WIFI_IFACE:-}
SOUND=${GS_SOUND:-1}
VIBE=${GS_VIBRATE:-1}
REPEAT=${GS_CLOSE_REPEAT:-25}
MAX=${GS_MAX_ROUNDS:-0}
DEMO=${GS_DEMO:-0}
# Non-blocking status: no persistent modal spinner. B stops the scan.
TRACK_MISSES=${GS_TRACK_MISSES:-12}
# Update tracked signal readout no more than once per N seconds.
TRACK_INTERVAL=${GS_TRACK_INTERVAL:-10}
case "$WINDOW" in ''|*[!0-9]*) WINDOW=1;; esac
[ "$WINDOW" -ge 1 ] 2>/dev/null || WINDOW=1
[ "$WINDOW" -le 10 ] || WINDOW=10
case "$MAX" in ''|*[!0-9]*) MAX=0;; esac
case "$REPEAT" in ''|*[!0-9]*) REPEAT=25;; esac
[ "$REPEAT" -ge 10 ] || REPEAT=10
case "$TRACK_MISSES" in ''|*[!0-9]*) TRACK_MISSES=12;; esac
[ "$TRACK_MISSES" -ge 3 ] 2>/dev/null || TRACK_MISSES=3
case "$TRACK_INTERVAL" in ''|*[!0-9]*) TRACK_INTERVAL=10;; esac
[ "$TRACK_INTERVAL" -ge 3 ] || TRACK_INTERVAL=3
TMP="${TMPDIR:-/tmp}/gs_drone_$$"
WORKER_PID=''
cleanup() {
    # Clean only this payload instance. Never kill other scanners or Pager services.
    if [ -n "$WORKER_PID" ]; then
        kill "$WORKER_PID" 2>/dev/null || :
        wait "$WORKER_PID" 2>/dev/null || :
        WORKER_PID=''
    fi
    rm -f "$TMP".*
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
log() { color=$1; shift; if command -v LOG >/dev/null 2>&1; then LOG "$color" "$*"; else printf '%s\n' "$*"; fi; }
alert_user() {
    if [ "$SOUND" = 1 ] && command -v RINGTONE >/dev/null 2>&1; then RINGTONE 'alert' >/dev/null 2>&1 || :; fi
    if [ "$VIBE" = 1 ] && command -v VIBRATE >/dev/null 2>&1; then VIBRATE >/dev/null 2>&1 || :; fi
}
choose_radio() {
    [ "$DEMO" = 1 ] && { BACKEND=demo; IFACE=demo; return 0; }
    command -v iw >/dev/null 2>&1 || return 1
    iw dev > "$TMP.iw" 2>/dev/null || return 1
    awk '$1=="Interface"{a=$2} $1=="type" && a!=""{print a"|"$2}' "$TMP.iw" > "$TMP.devs"
    if [ -n "$IFACE" ]; then
        case "$(awk -F'|' -v n="$IFACE" '$1==n{print $2;exit}' "$TMP.devs")" in
            monitor) BACKEND=monitor;; managed) BACKEND=managed;; *) return 1;; esac
    else
        IFACE=''
        if command -v tcpdump >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
            for n in wlan1mon wlan0mon wlan2mon; do
                if grep -Fqx "$n|monitor" "$TMP.devs"; then IFACE=$n; BACKEND=monitor; break; fi
            done
            [ -n "$IFACE" ] || IFACE=$(awk -F'|' '$2=="monitor"{print $1;exit}' "$TMP.devs")
            [ -z "$IFACE" ] || BACKEND=monitor
        fi
        if [ -z "$IFACE" ]; then
            for n in wlan1 wlan2 wlan0cli; do
                if grep -Fqx "$n|managed" "$TMP.devs"; then IFACE=$n; BACKEND=managed; break; fi
            done
        fi
    fi
    [ -n "$IFACE" ] || return 1
    if [ "$BACKEND" = monitor ]; then
        command -v tcpdump >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 || return 1
    fi
}
read_sample() {
    : > "$TMP.results"
    if [ "$BACKEND" = demo ]; then
        case $((ROUND % 7)) in 0) printf 'DJI-DEMO|-86\n' ;; 1) printf 'DJI-DEMO|-73\n';; 2) printf 'DJI-DEMO|-56\n';; 3) printf 'DJI-DEMO|-39\n';; 4) printf 'DJI-DEMO|-52\n';; 5) printf 'DJI-DEMO|-68\n';; esac > "$TMP.results"
        sleep "$WINDOW"
    elif [ "$BACKEND" = monitor ]; then
        timeout "${WINDOW}s" tcpdump -l -e -s 512 -n -i "$IFACE" 'type mgt subtype beacon or type mgt subtype probe-resp' > "$TMP.capture" 2>/dev/null || :
        awk '
        /Beacon \(/ || /Probe Response \(/ {
            s=$0; sub(/^.*(Beacon|Probe Response) \(/,"",s); sub(/\).*$/, "", s)
            if(s=="" || s=="<hidden>") next
            r="?"
            if(match($0, /-[0-9]+dBm/)) {r=substr($0,RSTART,RLENGTH); sub(/dBm/,"",r)}
            print s "|" r
        }' "$TMP.capture" > "$TMP.results"
    else
        # Bound scans, so cancel does not leave a long-lived iw process.
        if command -v timeout >/dev/null 2>&1; then
            timeout 8s iw dev "$IFACE" scan passive > "$TMP.capture" 2>/dev/null || :
        else
            iw dev "$IFACE" scan passive > "$TMP.capture" 2>/dev/null || :
        fi
        awk '
        /^BSS / {if(s!="") print s "|" r; s="";r="?"}
        /^[[:space:]]*signal:/ {r=int($2)}
        /^[[:space:]]*SSID:/ {s=$0;sub(/^[[:space:]]*SSID:[[:space:]]*/,"",s)}
        END{if(s!="") print s "|" r}
        ' "$TMP.capture" > "$TMP.results"
    fi
    awk -F'|' 'BEGIN{IGNORECASE=1} {
        a=toupper($1)
        if(a ~ /(DJI|AUTEL|PARROT|DRONE|FPV|SKYDIO|TELLO|MAVIC|PHANTOM|INSPIRE)/) print $0
    }' "$TMP.results" > "$TMP.matches"
}
make_bar() {
    # RSSI is an approximation of strength, never distance.
    r=$1
    case "$r" in -[0-9]*|[0-9]*) :;; *) r=-100;; esac
    [ "$r" -gt -30 ] && r=-30
    [ "$r" -lt -100 ] && r=-100
    blocks=$(((r+100)/7)); [ "$blocks" -gt 10 ] && blocks=10
    i=0; BAR='['
    while [ "$i" -lt 10 ]; do
        if [ "$i" -lt "$blocks" ]; then BAR="${BAR}#"; else BAR="${BAR}-"; fi
        i=$((i+1))
    done
    BAR="${BAR}]"
    if [ "$r" -ge -45 ]; then LABEL='MAY BE CLOSE'; COLOR=red
    elif [ "$r" -ge -60 ]; then LABEL='POSSIBLY NEAR'; COLOR=yellow
    elif [ "$r" -ge -75 ]; then LABEL=MODERATE; COLOR=blue
    else LABEL='WEAK SIGNAL'; COLOR=blue; fi
}
choose_radio || { log red 'No compatible Wi-Fi interface or required scanning tools found'; exit 1; }
log green 'GS Drone Detector | passive Wi-Fi candidate tracking'
log blue "Radio: $IFACE ($BACKEND); scan window: ${WINDOW}s"
log yellow 'SSID matches are not verified drones. RSSI is not distance.'
log blue 'Scanning... press [B] to stop'

scan_loop() {
    ROUND=0; CURRENT=''; MISSES=0; LAST_CLOSE=0; OLD_RSSI=''; LAST_UPDATE=0
    RECENT_NAME=''; RECENT_TIME=0
    while :; do
        ROUND=$((ROUND+1)); read_sample
        LINE=$(awk -F'|' -v old="$CURRENT" '
          $2 ~ /^-[0-9]+$/ { score=$2+0; if($1==old) score+=15; if(best=="" || score>max){best=$0;max=score} }
          END{print best}' "$TMP.matches")
        if [ -n "$LINE" ]; then
            NAME=${LINE%|*}; RSSI=${LINE##*|}; MISSES=0
            NEW=0; RESUMED=0
            NOW=$(date +%s)
            if [ "$CURRENT" != "$NAME" ]; then
                OLD_RSSI=''; LAST_UPDATE=0
                if [ "$RECENT_NAME" = "$NAME" ] && [ $((NOW-RECENT_TIME)) -le 90 ]; then
                    RESUMED=1
                else
                    NEW=1
                fi
            fi
            CURRENT=$NAME; RECENT_NAME=$NAME; RECENT_TIME=$NOW
            if [ -n "$OLD_RSSI" ]; then RSSI=$(((RSSI+OLD_RSSI)/2)); fi
            OLD_RSSI=$RSSI
            make_bar "$RSSI"
            if [ "$NEW" = 1 ]; then
                log red "NEW CANDIDATE: $NAME"
                alert_user
                LAST_CLOSE=$NOW
            elif [ "$RESUMED" = 1 ]; then
                log blue "TRACK RESUMED: $NAME"
            elif [ "$RSSI" -ge -45 ] && [ $((NOW-LAST_CLOSE)) -ge "$REPEAT" ]; then
                log yellow 'Strong signal reminder (not a distance measurement)'
                alert_user
                LAST_CLOSE=$NOW
            fi
            if [ "$NEW" = 1 ] || [ "$RESUMED" = 1 ] || [ $((NOW-LAST_UPDATE)) -ge "$TRACK_INTERVAL" ]; then
                log "$COLOR" "$NAME  $BAR ${RSSI} dBm  $LABEL"
                LAST_UPDATE=$NOW
            fi
        else
            if [ -n "$CURRENT" ]; then
                MISSES=$((MISSES+1))
                if [ "$MISSES" -ge "$TRACK_MISSES" ]; then
                    log blue "TRACK LOST: $CURRENT"
                    RECENT_NAME=$CURRENT; RECENT_TIME=$(date +%s)
                    CURRENT=''; OLD_RSSI=''; MISSES=0; LAST_UPDATE=0
                fi
            fi
            # An empty observation doesn't add log lines or stop input handling.
        fi
        [ "$MAX" -gt 0 ] && [ "$ROUND" -ge "$MAX" ] && break
    done
}

# The continuous scanner runs in the background so WAIT_FOR_INPUT can
# receive B even if there are no candidates. Unlike START_SPINNER, this
# does not create a persistent modal overlay on the Pager.
if command -v WAIT_FOR_INPUT >/dev/null 2>&1; then
    PARENT_PID=$$
    (
        scan_loop
        # Only demo/explicit finite scans send completion to the parent.
        [ "$MAX" -gt 0 ] && kill -TERM "$PARENT_PID" 2>/dev/null || :
    ) &
    WORKER_PID=$!
    while kill -0 "$WORKER_PID" 2>/dev/null; do
        BUTTON=$(WAIT_FOR_INPUT) || break
        case "$BUTTON" in
            B|b|BACK|back)
                log yellow 'Stopping scan (B pressed)...'
                break;;
            *) : ;; # Ignore non-cancel buttons; keep listening.
        esac
    done
    cleanup
    log green 'GS Drone Detector stopped'
    exit 0
else
    log yellow 'Button input unavailable: Ctrl+C stops a terminal session.'
    scan_loop
    log green 'GS Drone Detector stopped'
fi
