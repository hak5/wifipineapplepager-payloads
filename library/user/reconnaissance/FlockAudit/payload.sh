#!/bin/bash
# Title: Flock Security Camera Audit
# Author: bad-antics
# Description: Detects Flock Safety LPR cameras by scanning airspace in monitor
#              mode for their management WiFi APs (OUI + SSID pattern) and probe
#              requests from devices that have previously connected to them.
#              Optionally connects to a discovered camera AP and does a deep probe
#              (HTTP banner, vendor API, default creds, RTSP) from inside.
#              No internet connection or shared subnet required.
#              GPS-tagged findings exported to KML.
#              For authorized security assessments only.
# Version: 4.0
# Category: recon
# Net Mode: Client

LOOT_DIR="/root/loot/FlockAudit"
mkdir -p "$LOOT_DIR"
SESSION_TS=$(date +%Y%m%d_%H%M%S)
REPORT="$LOOT_DIR/flock_${SESSION_TS}.txt"
KML="$LOOT_DIR/flock_${SESSION_TS}.kml"
IFACE="wlan0"

COUNT_FILE="/tmp/flock_count_$$"
SEEN_FILE="/tmp/flock_seen_$$"
SCAN_DIR="/tmp/flock_scan_$$"
echo 0 > "$COUNT_FILE"
> "$SEEN_FILE"
mkdir -p "$SCAN_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────────
bump()     { echo $(( $(cat "$COUNT_FILE") + 1 )) > "$COUNT_FILE"; }
count()    { cat "$COUNT_FILE"; }
is_seen()  { grep -qxF "$1" "$SEEN_FILE" 2>/dev/null; }
mark_seen(){ echo "$1" >> "$SEEN_FILE"; }

oui_label() {
    echo "$FLOCK_OUIS" | grep -i "^$1" | head -1 | cut -d: -f4-
}

alert_camera() {
    # $1=label  $2=identifier  $3=detail
    VIBRATE
    LED red blink
    sleep 1
    LED green solid
    N=$(count)
    LOG green "Camera #$N: $1 — $2"
    ALERT "CAMERA #${N} FOUND

$1
$2

$3"
}

set_monitor() {
    ip link set "$IFACE" down 2>/dev/null
    iwconfig "$IFACE" mode monitor 2>/dev/null
    ip link set "$IFACE" up 2>/dev/null
    sleep 1
    if ! iwconfig "$IFACE" 2>/dev/null | grep -q "Mode:Monitor"; then
        airmon-ng start "$IFACE" 2>/dev/null
        MON="${IFACE}mon"
        [ ! -d "/sys/class/net/$MON" ] && MON="$IFACE"
    else
        MON="$IFACE"
    fi
}

set_managed() {
    ip link set "$MON" down 2>/dev/null
    iwconfig "$MON" mode managed 2>/dev/null
    ip link set "$MON" up 2>/dev/null
    [ "$MON" != "$IFACE" ] && airmon-ng stop "$MON" 2>/dev/null
    sleep 1
}

cleanup() {
    set_managed 2>/dev/null
    rm -f "$COUNT_FILE" "$SEEN_FILE"
    rm -rf "$SCAN_DIR"
}

# ── KML ───────────────────────────────────────────────────────────────────────
kml_init() {
    cat > "$KML" << 'KMLINIT'
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
<Document>
<name>Flock Camera Audit</name>
<Style id="cam">
  <IconStyle><color>ff0000ff</color>
    <Icon><href>http://maps.google.com/mapfiles/kml/shapes/camera.png</href></Icon>
  </IconStyle>
</Style>
KMLINIT
}

kml_placemark() {
    # $1=name  $2=desc  $3=lat  $4=lon
    [ -z "$3" ] || [ -z "$4" ] && return
    cat >> "$KML" << KMLP
<Placemark>
  <name>$1</name>
  <description>$2</description>
  <styleUrl>#cam</styleUrl>
  <Point><coordinates>$4,$3,0</coordinates></Point>
</Placemark>
KMLP
}

kml_close() { printf "</Document>\n</kml>\n" >> "$KML"; }

# ── OUI database ──────────────────────────────────────────────────────────────
FLOCK_OUIS="B8:27:EB:Raspberry Pi (Flock early)
DC:A6:32:Raspberry Pi (Flock early)
E4:5F:01:Raspberry Pi
00:04:4B:NVIDIA Jetson
48:B0:2D:NVIDIA Jetson
00:1A:22:Hikvision
44:19:B6:Hikvision
54:C4:15:Hikvision
BC:AD:28:Hikvision
C4:2F:90:Hikvision
C0:56:E3:Hikvision
28:57:BE:Dahua
3C:EF:8C:Dahua
BC:32:B2:Dahua
70:6D:15:Hanwha/Wisenet
00:09:18:Hanwha/Wisenet
C0:3F:D5:Bosch/Azena LPR
00:04:F3:Vivotek
00:02:D1:Mobotix
00:40:8C:Axis
AC:CC:8E:Axis
AC:1A:58:Axis
B8:A4:4F:Genetec
00:1E:64:March Networks"

# ── SSID patterns ─────────────────────────────────────────────────────────────
FLOCK_SSID_PAT="Flock_|FlockSafety|FLOCK-|flock-cam|LPR-|PlateReader|CommunityAlert|SafetyCam|ALPRCam"

# ── Deep-probe ports (only used when connected to camera's own AP) ─────────────
CAMERA_PORTS="80,443,554,1883,8080,8443,8000,8883,37777,34567"

# ── Default credentials ───────────────────────────────────────────────────────
DEFAULT_CREDS="admin:admin
admin:12345
admin:password
admin:123456
admin:
root:root
root:12345
admin:Admin12345
888888:888888
666666:666666"

# ─────────────────────────────────────────────────────────────────────────────
PROMPT "FLOCK CAMERA AUDIT v4

Detects Flock Safety LPR
cameras via RF only — no
network connection needed.

Phases:
1. Beacon scan (OUI+SSID)
2. Probe request sniff
3. GPS tag + KML export
4. Optional: connect to
   camera AP + deep probe

Press OK to configure."

SCAN_SECS=$(NUMBER_PICKER "Airspace scan secs:" 30)
[ -z "$SCAN_SECS" ] && SCAN_SECS=30

WATCH_RESP=$(CONFIRMATION_DIALOG "Enable watch mode?

YES = keep scanning in
      a loop (for driving
      a route)
NO  = single pass")
WATCH_MODE="no"
[ "$WATCH_RESP" = "$DUCKYSCRIPT_USER_CONFIRMED" ] && WATCH_MODE="yes"

PROBE_RESP=$(CONFIRMATION_DIALOG "Deep probe mode?

YES = auto-connect to
      found camera APs
      and probe them
NO  = RF detection only")
DEEP_PROBE="no"
[ "$PROBE_RESP" = "$DUCKYSCRIPT_USER_CONFIRMED" ] && DEEP_PROBE="yes"

resp=$(CONFIRMATION_DIALOG "START AUDIT?

Scan: ${SCAN_SECS}s per pass
Watch: $(echo $WATCH_MODE | tr a-z A-Z)
Deep: $(echo $DEEP_PROBE | tr a-z A-Z)

Press OK to begin.")
[ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ] && exit 0

# ── Init report + KML ─────────────────────────────────────────────────────────
{
    echo "========================================"
    echo "  FLOCK SAFETY CAMERA AUDIT"
    echo "  Session: $SESSION_TS"
    GPS_INIT=$(GPS_GET 2>/dev/null | head -1)
    [ -n "$GPS_INIT" ] && echo "  Start GPS: $GPS_INIT"
    echo "========================================"
    echo ""
} > "$REPORT"

kml_init

# ─────────────────────────────────────────────────────────────────────────────
# DEEP PROBE FUNCTION — called after connecting to a camera's AP
# $1 = camera IP (gateway, usually 192.168.x.1 or 10.x.x.1)
# $2 = SSID
# ─────────────────────────────────────────────────────────────────────────────
deep_probe() {
    CAM_IP="$1"
    CAM_SSID="$2"

    LOG "Deep probe on $CAM_IP ($CAM_SSID)..."

    {
        echo "[DEEP PROBE: $CAM_SSID / $CAM_IP]"
    } >> "$REPORT"

    # Port scan
    SPINNER_ID=$(START_SPINNER "Port scan $CAM_IP...")
    nmap -sV -p "$CAMERA_PORTS" --open --version-intensity 2 -T4 \
        "$CAM_IP" 2>/dev/null \
        | grep -E "/tcp|/udp" >> "$REPORT"
    STOP_SPINNER "$SPINNER_ID"

    # HTTP banner + title
    for PORT in 80 8080 8000 443 8443; do
        PROTO="http"
        [ "$PORT" = "443" ] || [ "$PORT" = "8443" ] && PROTO="https"
        HEADERS=$(curl -sk --max-time 4 -o /dev/null -D - \
            "${PROTO}://${CAM_IP}:${PORT}/" 2>/dev/null \
            | grep -iE "^Server:|^X-Application:|^WWW-Authenticate:" \
            | tr -d '\r' | head -3)
        TITLE=$(curl -sk --max-time 4 "${PROTO}://${CAM_IP}:${PORT}/" 2>/dev/null \
            | grep -oiE "<title>[^<]{1,80}</title>" \
            | sed 's/<[Tt][Ii][Tt][Ll][Ee]>//;s|</[Tt][Ii][Tt][Ll][Ee]>||' \
            | head -1)
        if [ -n "$HEADERS" ] || [ -n "$TITLE" ]; then
            {
                printf "  HTTP %s:%s\n" "$PROTO" "$PORT"
                [ -n "$TITLE"   ] && printf "    Title: %s\n" "$TITLE"
                [ -n "$HEADERS" ] && echo "$HEADERS" | sed 's/^/    /'
            } >> "$REPORT"
        fi
    done

    # Hikvision ISAPI
    HIK=$(curl -sk --max-time 4 "http://${CAM_IP}/ISAPI/System/deviceInfo" 2>/dev/null \
        | grep -oE "<(deviceName|model|serialNumber|firmwareVersion)>[^<]+" \
        | sed 's/<[^>]*>//' | head -6)
    [ -n "$HIK" ] && { echo "  Hikvision ISAPI:"; echo "$HIK" | sed 's/^/    /'; } >> "$REPORT"

    # Dahua CGI
    DAH=$(curl -sk --max-time 4 \
        "http://${CAM_IP}/cgi-bin/magicBox.cgi?action=getDeviceType" 2>/dev/null)
    DAH_SN=$(curl -sk --max-time 4 \
        "http://${CAM_IP}/cgi-bin/magicBox.cgi?action=getSerialNo" 2>/dev/null)
    [ -n "$DAH" ] && { echo "  Dahua CGI: $DAH  SN:$DAH_SN"; } >> "$REPORT"

    # Axis VAPIX
    AXIS=$(curl -sk --max-time 4 \
        "http://${CAM_IP}/axis-cgi/param.cgi?action=list&group=Properties.System" \
        2>/dev/null | grep -iE "ProductName|SerialNumber" | head -3)
    [ -n "$AXIS" ] && { echo "  Axis VAPIX:"; echo "$AXIS" | sed 's/^/    /'; } >> "$REPORT"

    # RTSP
    RTSP_RAW=$(printf "DESCRIBE rtsp://%s/ RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: LibVLC\r\n\r\n" \
        "$CAM_IP" | timeout 4 nc -w 3 "$CAM_IP" 554 2>/dev/null | head -3)
    if [ -n "$RTSP_RAW" ]; then
        RTSP_CODE=$(echo "$RTSP_RAW" | head -1 | awk '{print $2}')
        printf "  RTSP:554 code=%s\n" "$RTSP_CODE" >> "$REPORT"
        [ "$RTSP_CODE" = "200" ] && { LOG green "RTSP OPEN (no auth)"; VIBRATE; }
    fi

    # Default credential check
    echo "$DEFAULT_CREDS" | while IFS=: read DUSER DPASS; do
        for CPORT in 80 8080; do
            STATUS=$(curl -sk --max-time 3 -o /dev/null -w "%{http_code}" \
                -u "${DUSER}:${DPASS}" "http://${CAM_IP}:${CPORT}/" 2>/dev/null)
            if [ "$STATUS" = "200" ] || [ "$STATUS" = "302" ]; then
                CRED_LINE="${DUSER}:${DPASS} (port $CPORT)"
                {
                    echo "  *** DEFAULT CREDS WORK: $CRED_LINE ***"
                } >> "$REPORT"
                LOG red "DEFAULT CREDS: $CRED_LINE on $CAM_IP"
                VIBRATE
                ALERT "DEFAULT CREDS!

$CAM_SSID
$CAM_IP
$CRED_LINE"
                break 2
            fi
        done
    done

    echo "" >> "$REPORT"
    LOG "Deep probe complete: $CAM_IP"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN SCAN FUNCTION
# ─────────────────────────────────────────────────────────────────────────────
run_scan() {

    # ── Monitor mode ──────────────────────────────────────────────────────────
    LOG "Setting monitor mode..."
    set_monitor
    LOG "Monitor: $MON"

    # ── Airspace scan ─────────────────────────────────────────────────────────
    rm -f "$SCAN_DIR"/flock*.csv
    SPINNER_ID=$(START_SPINNER "Scanning airspace (${SCAN_SECS}s)...")

    timeout "$SCAN_SECS" airodump-ng "$MON" \
        --output-format csv \
        -w "$SCAN_DIR/flock" \
        --write-interval 2 2>/dev/null

    STOP_SPINNER "$SPINNER_ID"

    set_managed

    # ── Parse CSV: APs + probe requests ───────────────────────────────────────
    AP_CSV=$(ls "$SCAN_DIR"/flock*.csv 2>/dev/null | head -1)
    [ -f "$AP_CSV" ] || return

    IN_CLIENTS=0
    while IFS=',' read -r F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12 F13 F14 F15; do
        LINE_CLEAN=$(echo "$F1" | tr -d ' \r')

        echo "$F1" | grep -q "Station MAC" && { IN_CLIENTS=1; continue; }
        [ -z "$LINE_CLEAN" ] && continue

        if [ "$IN_CLIENTS" = "0" ]; then
            # ── AP beacon row ─────────────────────────────────────────────────
            BSSID=$(echo "$F1"  | tr -d ' \r' | tr '[:lower:]' '[:upper:]')
            CH=$(echo "$F4"     | tr -d ' \r')
            SIG=$(echo "$F9"    | tr -d ' \r')
            ESSID=$(echo "$F14" | tr -d ' \r"')

            echo "$BSSID" | grep -qE "^[0-9A-F]{2}:" || continue

            OUI=$(echo "$BSSID" | cut -d':' -f1-3)
            OUI_LBL=$(oui_label "$OUI")
            SSID_HIT=$(echo "$ESSID" | grep -iE "$FLOCK_SSID_PAT")

            [ -z "$OUI_LBL" ] && [ -z "$SSID_HIT" ] && continue
            is_seen "$BSSID" && continue
            mark_seen "$BSSID"
            bump

            # GPS tag
            GPS_NOW=$(GPS_GET 2>/dev/null | head -1)
            GPS_LAT=$(echo "$GPS_NOW" | grep -oE "[-]?[0-9]+\.[0-9]+" | head -1)
            GPS_LON=$(echo "$GPS_NOW" | grep -oE "[-]?[0-9]+\.[0-9]+" | sed -n '2p')

            {
                echo "[BEACON $(count)]"
                echo "  BSSID:   $BSSID"
                echo "  SSID:    ${ESSID:-(hidden)}"
                echo "  Channel: $CH"
                echo "  Signal:  $SIG dBm"
                [ -n "$OUI_LBL"  ] && echo "  Vendor:  $OUI_LBL"
                [ -n "$SSID_HIT" ] && echo "  Match:   Flock SSID pattern"
                [ -n "$GPS_NOW"  ] && echo "  GPS:     $GPS_NOW"
                echo ""
            } >> "$REPORT"

            kml_placemark \
                "${ESSID:-$BSSID}" \
                "${OUI_LBL:-Flock SSID} | ch${CH} ${SIG}dBm" \
                "$GPS_LAT" "$GPS_LON"

            alert_camera "${OUI_LBL:-Flock SSID}" "${ESSID:-$BSSID}" "ch${CH}  ${SIG}dBm"

            # Deep probe — connect to this camera's AP
            if [ "$DEEP_PROBE" = "yes" ] && [ -n "$ESSID" ]; then
                LOG "Connecting to $ESSID for deep probe..."
                # Connect managed mode
                iwconfig "$IFACE" mode managed 2>/dev/null
                iwconfig "$IFACE" essid "$ESSID" 2>/dev/null
                sleep 3
                # Get IP via DHCP
                udhcpc -i "$IFACE" -q -t 5 2>/dev/null
                sleep 2
                # Find gateway (camera's IP)
                GW=$(ip route show dev "$IFACE" 2>/dev/null \
                    | grep "default via" | awk '{print $3}' | head -1)
                if [ -z "$GW" ]; then
                    # Try ARP table for first host
                    GW=$(arp -n 2>/dev/null | awk '/wlan/{print $1}' | head -1)
                fi
                if [ -n "$GW" ]; then
                    deep_probe "$GW" "$ESSID"
                else
                    LOG red "Connected to $ESSID but couldn't find camera IP"
                    echo "  [DEEP PROBE: could not determine camera IP]" >> "$REPORT"
                fi
                # Disconnect — go back to scan
                iwconfig "$IFACE" essid off 2>/dev/null
                ip addr flush dev "$IFACE" 2>/dev/null
                sleep 1
            fi

        else
            # ── Client/probe request row ──────────────────────────────────────
            CLIENT_MAC=$(echo "$F1" | tr -d ' \r' | tr '[:lower:]' '[:upper:]')
            PROBED=$(echo "$F6"     | tr -d ' \r"')

            echo "$CLIENT_MAC" | grep -qE "^[0-9A-F]{2}:" || continue
            [ -z "$PROBED" ] && continue

            PROBE_HIT=$(echo "$PROBED" | grep -iE "$FLOCK_SSID_PAT")
            [ -z "$PROBE_HIT" ] && continue

            is_seen "probe_$CLIENT_MAC" && continue
            mark_seen "probe_$CLIENT_MAC"

            GPS_NOW=$(GPS_GET 2>/dev/null | head -1)

            {
                echo "[PROBE REQUEST]"
                echo "  Client MAC: $CLIENT_MAC"
                echo "  Probing for: $PROBED"
                echo "  Note: This device was previously connected to a Flock camera"
                [ -n "$GPS_NOW" ] && echo "  GPS: $GPS_NOW"
                echo ""
            } >> "$REPORT"
            LOG "Probe: $CLIENT_MAC seeking $PROBED"
            VIBRATE
        fi

    done < "$AP_CSV"

} # end run_scan()

# ─────────────────────────────────────────────────────────────────────────────
# EXECUTE
# ─────────────────────────────────────────────────────────────────────────────
run_scan

if [ "$WATCH_MODE" = "yes" ]; then
    LOG "Watch mode active. Looping..."
    PASS=1
    while true; do
        PASS=$(( PASS + 1 ))
        LOG "Pass #$PASS — cameras so far: $(count)"
        run_scan
        sleep 5
    done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL=$(count)
kml_close

{
    echo "========================================"
    echo "  SUMMARY"
    echo "  Total unique cameras: $TOTAL"
    echo "  Beacons:       $(grep -c "^\[BEACON"  "$REPORT" 2>/dev/null || echo 0)"
    echo "  Probe requests:$(grep -c "^\[PROBE"   "$REPORT" 2>/dev/null || echo 0)"
    echo "  Deep probes:   $(grep -c "^\[DEEP"    "$REPORT" 2>/dev/null || echo 0)"
    echo "  Report:        $REPORT"
    echo "  KML:           $KML"
    echo "========================================"
} >> "$REPORT"

PINEAPPLE_LOOT_ARCHIVE 2>/dev/null
cleanup

LED blue solid
[ "$TOTAL" -gt 0 ] && { VIBRATE; LED green solid; }

PROMPT "FLOCK AUDIT COMPLETE

Cameras: $TOTAL found

Beacons:       $(grep -c "^\[BEACON" "$REPORT" 2>/dev/null || echo 0)
Probe requests:$(grep -c "^\[PROBE"  "$REPORT" 2>/dev/null || echo 0)

Report: $REPORT
KML:    $KML

Press OK to exit."
