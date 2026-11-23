#!/bin/bash
# Title: PagerTAK Deauth Alert
# Description: Pushes a deauth/disassoc flood detection to TAK as a map marker and GeoChat alert
# Author: SECT0101
# Version: 1.0
# Category: Alerts
#
# Companion to the PagerTAK user payload (library/user/general/PagerTAK).
# It uses PagerTAK's saved server settings and certificates, so set up
# PagerTAK first.
#
#   - PagerTAK running   -> the alert is queued to PagerTAK's live connection
#   - PagerTAK not running -> opens a short one-shot connection and sends it
#
# The marker is placed at the Pager's position (the attacker is in radio range
# of the Pager, not at an exact spot). Repeat floods from the same source MAC
# update the same marker instead of creating new ones.
#
# Pager-provided variables used:
#   $_ALERT_DENIAL_MESSAGE, $_ALERT_DENIAL_SOURCE_MAC_ADDRESS,
#   $_ALERT_DENIAL_AP_MAC_ADDRESS, $_ALERT_DENIAL_CLIENT_MAC_ADDRESS

# Options
SEND_MARKER=1                   # 1 = drop a map marker at the Pager's position
SEND_CHAT=1                     # 1 = also post a GeoChat message to All Chat Rooms
LOCAL_ALERT=1                   # 1 = also show ALERT on the Pager screen
DEDUPE_SECONDS=300              # suppress repeats from the same source MAC for this long
MARKER_TYPE="a-s-G"             # CoT type: a-s-G suspect ground, a-h-G hostile, a-u-G unknown
MARKER_STALE_MIN=30             # minutes the marker stays on the map
PAGERTAK_DIR="/root/payloads/user/general/PagerTAK"   # also checks /mmc/root/payloads/... automatically

#############################################################################

shopt -u patsub_replacement 2>/dev/null
[ -d "$PAGERTAK_DIR/certs" ] || [ ! -d /mmc/root/payloads/user/general/PagerTAK/certs ] || PAGERTAK_DIR=/mmc/root/payloads/user/general/PagerTAK
trap '' PIPE

CFG_NS="pagertak"
RUN="/tmp/pagertak"
STATE="/tmp/pagertak_alerts"
mkdir -p "$STATE"

cfg_get() {
    local v; v=$(PAYLOAD_GET_CONFIG "$CFG_NS" "$1" 2>/dev/null)
    if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}
xml_esc() {
    local s=$1
    s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; s=${s//\"/&quot;}; s=${s//\'/&apos;}; s=${s//$'\n'/ }
    printf '%s' "$s"
}
iso_time() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%S.000Z'; }
valid_coord() { [[ $1 =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && [[ ! $1 =~ ^-?0+(\.0+)?$ ]]; }

SRC=${_ALERT_DENIAL_SOURCE_MAC_ADDRESS:-unknown}
AP=${_ALERT_DENIAL_AP_MAC_ADDRESS:-unknown}
CLIENT=${_ALERT_DENIAL_CLIENT_MAC_ADDRESS:-unknown}
MSG=${_ALERT_DENIAL_MESSAGE:-deauth/disassoc flood detected}

# ---- dedupe ---------------------------------------------------------------
KEY=$(printf '%s' "$SRC" | tr -cd '0-9A-Fa-f' | tr 'a-f' 'A-F'); [ -z "$KEY" ] && KEY="UNKNOWN"
SHORT="DEAUTH ${SRC: -8}"            # last 3 octets keep the marker name short on the Pager map
NOW=$(date +%s)
if [ -f "$STATE/$KEY" ] && [ $((NOW - $(cat "$STATE/$KEY"))) -lt "$DEDUPE_SECONDS" ]; then
    exit 0
fi
echo "$NOW" > "$STATE/$KEY"

[ "$LOCAL_ALERT" = 1 ] && ALERT "DEAUTH FLOOD
$MSG
-> sending to TAK" >/dev/null 2>&1 &

# ---- config from PagerTAK ---------------------------------------------------
HOST=$(cfg_get host ""); PROTO=$(cfg_get proto tls); PORT=$(cfg_get port 8089)
CALLSIGN=$(cfg_get callsign PAGER-1); UID_=$(cfg_get uid "")
CLIENT_PEM=$(cfg_get client_pem client.pem); CA_PEM=$(cfg_get ca_pem ca.pem)
MANUAL=$(cfg_get manual_pos "")
if [ -z "$HOST" ] || [ -z "$UID_" ]; then
    LOG red "PagerTAK not configured - run PagerTAK once first"
    exit 1
fi

# ---- position: live GPS > PagerTAK's last fix > manual ---------------------
read -r LAT LON HAE _ <<< "$(timeout 5 GPS_GET 2>/dev/null)"
if ! valid_coord "$LAT" || ! valid_coord "$LON"; then
    LAT=""; LON=""; HAE=0
    [ -f "$RUN/lastfix" ] && read -r LAT LON HAE _ < "$RUN/lastfix"
    if ! valid_coord "$LAT" && [ -n "$MANUAL" ]; then
        LAT=${MANUAL%%,*}; LON=${MANUAL##*,}; LAT=${LAT// /}; LON=${LON// /}; HAE=0
    fi
fi
if ! valid_coord "$LAT" || ! valid_coord "$LON"; then
    LAT=0; LON=0; HAE=0; NOPOS=" (no GPS position)"
fi
[[ $HAE =~ ^-?[0-9.]+$ ]] || HAE=0

T=$(iso_time "$NOW"); STALE=$(iso_time $((NOW + MARKER_STALE_MIN * 60)))
CS=$(xml_esc "$CALLSIGN")
REMARKS=$(xml_esc "Deauth/disassoc flood detected by $CALLSIGN at $(date '+%Y-%m-%d %H:%M:%S').
Source: $SRC  AP/BSSID: $AP  Client: $CLIENT.
$MSG${NOPOS:-}")

EVENTS=()
if [ "$SEND_MARKER" = 1 ] && [ -z "${NOPOS:-}" ]; then
    EVENTS+=("<event version=\"2.0\" uid=\"PagerTAK-deauth-$KEY\" type=\"$MARKER_TYPE\" how=\"m-g\" time=\"$T\" start=\"$T\" stale=\"$STALE\"><point lat=\"$LAT\" lon=\"$LON\" hae=\"$HAE\" ce=\"100\" le=\"9999999.0\"/><detail><contact callsign=\"$SHORT\"/><link uid=\"$UID_\" type=\"a-f-G-U-C\" parent_callsign=\"$CS\" relation=\"p-p\"/><color argb=\"-65536\"/><remarks>$REMARKS</remarks><archive/></detail></event>")
fi
if [ "$SEND_CHAT" = 1 ]; then
    MID=$(cat /proc/sys/kernel/random/uuid)
    CHAT=$(xml_esc "ALERT: deauth flood near $CALLSIGN - src $SRC, AP $AP${NOPOS:-}")
    EVENTS+=("<event version=\"2.0\" uid=\"GeoChat.$UID_.All Chat Rooms.$MID\" type=\"b-t-f\" how=\"h-g-i-g-o\" time=\"$T\" start=\"$T\" stale=\"$(iso_time $((NOW + 86400)))\"><point lat=\"$LAT\" lon=\"$LON\" hae=\"$HAE\" ce=\"9999999.0\" le=\"9999999.0\"/><detail><__chat parent=\"RootContactGroup\" groupOwner=\"false\" messageId=\"$MID\" chatroom=\"All Chat Rooms\" id=\"All Chat Rooms\" senderCallsign=\"$CS\"><chatgrp uid0=\"$UID_\" uid1=\"All Chat Rooms\" id=\"All Chat Rooms\"/></__chat><link uid=\"$UID_\" type=\"a-f-G-U-C\" relation=\"p-p\"/><remarks source=\"BAO.F.ATAK.$UID_\" to=\"All Chat Rooms\" time=\"$T\">$CHAT</remarks></detail></event>")
fi
[ ${#EVENTS[@]} -eq 0 ] && exit 0

mkdir -p /root/loot/PagerTAK
echo "$(date '+%Y-%m-%d %H:%M:%S') DEAUTH src=$SRC ap=$AP client=$CLIENT pos=$LAT,$LON" >> "/root/loot/PagerTAK/alerts.log"

# ---- deliver ---------------------------------------------------------------
# 1) PagerTAK is running: hand off to its live connection
if [ -d "$RUN/outbox" ] && [ ! -f "$RUN/stop" ] && kill -0 "$(cat "$RUN/engine.pid" 2>/dev/null)" 2>/dev/null; then
    for ev in "${EVENTS[@]}"; do
        f="$RUN/outbox/$(date +%s)-$$-$RANDOM"
        printf '%s\n' "$ev" > "$f.tmp" && mv "$f.tmp" "$f.cot"
    done
    # show it on PagerTAK's own map / contacts list too (the server will not echo it back)
    if [ "$SEND_MARKER" = 1 ] && [ -z "${NOPOS:-}" ] && [ -d "$RUN/tracks.d" ]; then
        printf '%s|%s|DEAUTH %s|%s||%s|marker\n' "$LAT" "$LON" "${SRC: -8}" "$MARKER_TYPE" "$NOW" > "$RUN/tracks.d/PagerTAK-deauth-$KEY"
    fi
    LOG yellow "Deauth alert queued to PagerTAK"
    exit 0
fi

# 2) One-shot connection. Send a position report first so the server knows who we are.
SA="<event version=\"2.0\" uid=\"$UID_\" type=\"a-f-G-U-C\" how=\"m-g\" time=\"$T\" start=\"$T\" stale=\"$(iso_time $((NOW + 120)))\"><point lat=\"$LAT\" lon=\"$LON\" hae=\"$HAE\" ce=\"9999999.0\" le=\"9999999.0\"/><detail><contact callsign=\"$CS\" endpoint=\"*:-1:stcp\"/><takv device=\"WiFi Pineapple Pager\" platform=\"PagerTAK\" os=\"OpenWrt\" version=\"1.0\"/></detail></event>"
PAYLOAD="$( [ -z "${NOPOS:-}" ] && printf '%s\n' "$SA"; printf '%s\n' "${EVENTS[@]}")"

case "$PROTO" in
    udp)
        printf '%s\n' "$PAYLOAD" > "/dev/udp/$HOST/$PORT" 2>/dev/null; rc=$? ;;
    tcp)
        timeout 10 bash -c 'exec 3<>"/dev/tcp/$1/$2" && printf "%s\n" "$3" >&3 && sleep 1' _ "$HOST" "$PORT" "$PAYLOAD" 2>/dev/null; rc=$? ;;
    tls)
        args=(-quiet -connect "$HOST:$PORT" -cert "$PAGERTAK_DIR/certs/$CLIENT_PEM" -key "$PAGERTAK_DIR/certs/$CLIENT_PEM")
        [[ $HOST =~ ^[0-9.]+$ ]] || args+=(-servername "$HOST")
        [ -f "$PAGERTAK_DIR/certs/$CA_PEM" ] && args+=(-CAfile "$PAGERTAK_DIR/certs/$CA_PEM" -verify_return_error)
        # keep stdin open briefly so the TLS session can finish sending
        if timeout 6 bash -c ': <>"/dev/tcp/$1/$2"' _ "$HOST" "$PORT" 2>/dev/null; then
            # -quiet keeps the session open after stdin ends; timeout closes it once sent
            { printf '%s\n' "$PAYLOAD"; sleep 3; } | timeout 8 openssl s_client "${args[@]}" >/dev/null 2>&1
            rc=$?; [ "$rc" = 124 ] && rc=0
        else
            rc=2
        fi ;;
    *) rc=1 ;;
esac

if [ "$rc" = 0 ]; then
    LOG yellow "Deauth alert sent to TAK"
else
    LOG red "Deauth alert: TAK send failed ($PROTO://$HOST:$PORT)"
    echo "$(date '+%Y-%m-%d %H:%M:%S') SEND FAILED rc=$rc" >> "/root/loot/PagerTAK/alerts.log"
fi
exit 0
