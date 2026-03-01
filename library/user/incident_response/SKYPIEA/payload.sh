#!/bin/bash

# =========================================================================
#                                
#  _______  __   ___ _________  ________  _________  ________       __
# |  _____||  | /  /|___   ___||   __   ||___   ___||  ______|     /  \
# | |_____ |  |/  /     | |    |  |__|  |    | |    | |_____      / /\ \
# |_____  ||     \      | |    |   _____|    | |    |  _____|    /  __  \
#  _____| ||  |\  \  ___| |___ |  |       ___| |___ | |______   /  |  |  \
# |_______||__| \__\|_________||__|      |_________||________| /___|  |___\
#
#  Title:       SKYPIEA
#  Description: Wireless Incident Response & Threat Snapshot
#  Author:      FBG0x00
#  Version:     1.0
#  Category:    incident_response
#
#  Install to:  /mmc/root/payloads/user/incident_response/SKYPIEA/
#
#  Description:
#    SkYPIEA is a incident response payload for the WiFi
#    Pineapple Pager. When a security event is suspected,
#    SKYPIEA captures a complete wireless threat snapshot:
#    nearby APs, active clients, channel activity, rogue AP
#    indicators, and a full environment fingerprint — all
#    packaged into a timestamped loot bundle reviewable via
#    SSH or the Virtual Pager.
#
#    Nothing is transmitted. Nothing is modified.
#    SKYPIEA only listens and documents.
#
# ============================================================


# ----------------------------------------------
#                 CONFIGURATION
# ----------------------------------------------

PAYLOAD_NAME="SKYPIEA"
LOOT_BASE="/mmc/root/loot/SKYPIEA"
CAPTURE_DURATION=60        # Seconds to passively capture per phase
CHANNEL_HOP_INTERVAL=5     # Seconds per channel during sweep


# ----------------------------------------------
#   SETUP — Create timestamped loot directory
# ----------------------------------------------

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOOT_DIR="${LOOT_BASE}/${TIMESTAMP}"
mkdir -p "${LOOT_DIR}" || {
    ERROR_DIALOG "Failed to create loot directory. Check storage."
    exit 1
}

REPORT_FILE="${LOOT_DIR}/incident_report.txt"
AP_FILE="${LOOT_DIR}/access_points.txt"
CLIENT_FILE="${LOOT_DIR}/clients.txt"
CHANNEL_FILE="${LOOT_DIR}/channel_activity.txt"
ENV_FILE="${LOOT_DIR}/environment.txt"


# ----------------------------------------------
#                    HELPERS
# ----------------------------------------------

section() {
    {
        echo ""
        echo "--------------------------------------------"
        echo "  ${1}"
        echo "--------------------------------------------"
    } >> "${REPORT_FILE}"
}

field() {
    printf "  %-22s %s\n" "${1}:" "${2}" >> "${REPORT_FILE}"
}

raw() {
    echo "${1}" >> "${REPORT_FILE}"
}


# ----------------------------------------------
#            STEP 1 — CONFIRM INTENT
# ----------------------------------------------

LOG "SKYPIEA — Wireless Incident Response"
LOG "Preparing threat snapshot..."

CONFIRMATION_DIALOG "Start wireless incident response snapshot?" || {
    LOG "Cancelled by user."
    exit 0
}


# ----------------------------------------------
#           STEP 2 — DETECT INTERFACES
# ----------------------------------------------

LOG "Detecting wireless interfaces..."

MON_IFACE=$(iw dev 2>/dev/null | awk '/Interface/{iface=$2} /type monitor/{print iface; exit}')
MGMT_IFACE=$(iw dev 2>/dev/null | awk '/Interface/{iface=$2} /type managed/{print iface; exit}')

if [ -z "${MON_IFACE}" ]; then
    ERROR_DIALOG "No monitor interface found. Enable monitor mode first."
    exit 1
fi

LOG green "Monitor: ${MON_IFACE}"
[ -n "${MGMT_IFACE}" ] && LOG "Managed: ${MGMT_IFACE}"


# ----------------------------------------------
#         STEP 3 — WRITE REPORT HEADER
# ----------------------------------------------

{
    echo " ______________________________________________ "
    echo "|                                              |"
    echo "|         SKYPIEA  INCIDENT  REPORT            |"
    echo "|      WiFi Pineapple Pager  —  by FBG0x00     |"
    echo "|______________________________________________|"
    echo ""
    echo "  Timestamp   : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Session ID  : ${TIMESTAMP}"
    echo "  Mon Iface   : ${MON_IFACE}"
    echo "  Mgmt Iface  : ${MGMT_IFACE:-N/A}"
    echo ""
} > "${REPORT_FILE}"


# ----------------------------------------------
#        STEP 4 — ENVIRONMENT FINGERPRINT
# ----------------------------------------------

section "ENVIRONMENT FINGERPRINT"

LOG "Capturing environment..."
__spinnerid=$(START_SPINNER "Environment scan")

{
    echo "  -- System --"
    uname -a 2>/dev/null
    echo ""
    echo "  -- Uptime & Load --"
    uptime 2>/dev/null
    echo ""
    echo "  -- Memory (MB) --"
    free -m 2>/dev/null
    echo ""
    echo "  -- Storage --"
    df -h /root 2>/dev/null
    df -h /mmc 2>/dev/null
    echo ""
    echo "  -- Network Interfaces --"
    ip addr 2>/dev/null
    echo ""
    echo "  -- Routing Table --"
    ip route 2>/dev/null
    echo ""
    echo "  -- Wireless Interfaces --"
    iw dev 2>/dev/null
    echo ""
    echo "  -- ARP Cache --"
    arp -a 2>/dev/null || ip neigh 2>/dev/null
    echo ""
} | tee "${ENV_FILE}" >> "${REPORT_FILE}"

STOP_SPINNER "${__spinnerid}"
LOG green "Environment captured."


# ------------------------------------------------
#         STEP 5 — CHANNEL ACTIVITY SWEEP
#  Hop channels, measure frame density per channel
# ------------------------------------------------

section "CHANNEL ACTIVITY SWEEP"

LOG "Sweeping channels..."
__spinnerid=$(START_SPINNER "Channel sweep")

raw "  Channel  | Frames Observed"
raw "  ---------|----------------"

> "${CHANNEL_FILE}"

# Common 2.4GHz + 5GHz channels
CHANNELS="1 6 11 2 3 4 5 7 8 9 10 36 40 44 48 52 56 60 64 100 104 108 112 116 149 153 157 161 165"

for ch in $CHANNELS; do
    iw dev "${MON_IFACE}" set channel "${ch}" 2>/dev/null || continue
    sleep "${CHANNEL_HOP_INTERVAL}"

    # Sample frame count on this channel
    frame_count=$(timeout "${CHANNEL_HOP_INTERVAL}" tcpdump -i "${MON_IFACE}" \
        --snapshot-lenght=32 -c 100 2>/dev/null | wc -l)

    line=$(printf "  CH %-5s  | %s frames" "${ch}" "${frame_count}")
    echo "${line}" >> "${CHANNEL_FILE}"
    raw "${line}"
done

STOP_SPINNER "${__spinnerid}"
LOG green "Channel sweep complete."

# Find the busiest channel
BUSIEST_CH=$(awk '/CH/ {split($4,a," "); if(a[1]+0 > max){max=a[1]+0; ch=$2}} END{print ch}' \
    "${CHANNEL_FILE}" 2>/dev/null)

if [ -n "${BUSIEST_CH}" ]; then
    raw ""
    raw "  Most active channel: ${BUSIEST_CH}"
    LOG "  Busiest channel: ${BUSIEST_CH}"
fi


# -----------------------------------------------------
#             STEP 6 — ACCESS POINT SURVEY
#  Discover APs with BSSID, SSID, channel, encryption
# -----------------------------------------------------

section "ACCESS POINT SURVEY"

LOG "Scanning for access points..."
__spinnerid=$(START_SPINNER "AP scan")

iw dev "${MON_IFACE}" scan 2>/dev/null > "${AP_FILE}"

STOP_SPINNER "${__spinnerid}"

AP_COUNT=0
OPEN_AP_COUNT=0
HIDDEN_COUNT=0

if [ -s "${AP_FILE}" ]; then
    AP_COUNT=$(grep -c "^BSS" "${AP_FILE}" 2>/dev/null || echo 0)
    raw ""
    raw "  APs discovered: ${AP_COUNT}"
    raw ""
    raw "  BSSID               Ch    Signal        Enc    SSID"
    raw "  ---------------------------------------------------"

    # Parse iw scan output into clean table
    awk '
    /^BSS /       { bss=$2; signal="?"; ssid="(hidden)"; enc="Open"; channel="?" }
    /signal:/     { signal=$2" dBm" }
    /SSID:/       {
        rest = substr($0, index($0, $2))
        if (length(rest) > 0) ssid = rest
        else ssid = "(hidden)"
    }
    /DS Parameter/ { channel=$NF }
    /primary channel:/ { channel=$NF }
    /\* primary channel:/ { channel=$NF }
    /RSN:/        { enc="WPA2" }
    /WPA:/        { if(enc!="WPA2") enc="WPA" }
    /capability:/ {
        if(/Privacy/) { if(enc=="Open") enc="WEP" }
        printf "  %-20s%-6s%-14s%-7s%s\n", bss, channel, signal, enc, ssid
    }
    ' "${AP_FILE}" >> "${REPORT_FILE}" 2>/dev/null

    # Count open and hidden APs for threat scoring
    OPEN_AP_COUNT=$(awk '
    /^BSS /  { bss=$2; enc="Open"; ssid="visible" }
    /SSID:/  { rest=substr($0,index($0,$2)); if(length(rest)<1) ssid="hidden" }
    /RSN:/   { enc="WPA2" }
    /WPA:/   { if(enc!="WPA2") enc="WPA" }
    /capability:/ {
        if(/Privacy/) if(enc=="Open") enc="WEP"
        if(enc=="Open") count++
    }
    END { print count+0 }
    ' "${AP_FILE}" 2>/dev/null)

    HIDDEN_COUNT=$(grep -c "SSID: $" "${AP_FILE}" 2>/dev/null || echo 0)

    # Rogue AP indicators section
    section "ROGUE AP INDICATORS"
    raw "  Flagging: Open networks and hidden SSIDs"
    raw ""

    awk '
    /^BSS /  { bss=$2; ssid="(hidden)"; enc="Open"; channel="?" }
    /SSID:/  { rest=substr($0,index($0,$2)); if(length(rest)>0) ssid=rest }
    /DS Parameter/ { channel=$NF }
    /RSN:/   { enc="WPA2" }
    /WPA:/   { if(enc!="WPA2") enc="WPA" }
    /capability:/ {
        if(/Privacy/) if(enc=="Open") enc="WEP"
        if(enc=="Open" || ssid=="(hidden)")
            printf "  [!] %-20s CH:%-5s Enc:%-6s SSID:%s\n", bss, channel, enc, ssid
    }
    ' "${AP_FILE}" >> "${REPORT_FILE}" 2>/dev/null

    raw ""

else
    raw "  No AP data captured. Ensure monitor mode is active."
    LOG yellow "No APs found — check monitor interface."
fi

LOG green "AP survey complete. Found ${AP_COUNT} APs."


# -----------------------------------------------
#           STEP 7 — CLIENT DISCOVERY
#  Capture probe requests and association frames
# -----------------------------------------------

section "CLIENT DISCOVERY"

LOG "Capturing client activity..."
__spinnerid=$(START_SPINNER "Client capture")

# Return to most active channel for client capture
if [ -n "${BUSIEST_CH}" ]; then
    iw dev "${MON_IFACE}" set channel "${BUSIEST_CH}" 2>/dev/null
fi

# Capture probe requests, associations, reassociations
timeout "${CAPTURE_DURATION}" tcpdump \
    -i "${MON_IFACE}" -e -n \
    'type mgt and (subtype probe-req or subtype assoc-req or subtype reassoc-req)' \
    2>/dev/null > "${CLIENT_FILE}"

STOP_SPINNER "${__spinnerid}"

# Extract unique client MACs
UNIQUE_MACS=$(grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' "${CLIENT_FILE}" 2>/dev/null \
    | sort -u)
UNIQUE_CLIENTS=$(echo "${UNIQUE_MACS}" | grep -c . 2>/dev/null || echo 0)

raw ""
raw "  Client MACs observed: ${UNIQUE_CLIENTS}"
raw ""

if [ -n "${UNIQUE_MACS}" ]; then
    raw "  MAC Address         | Seen"
    raw "  --------------------------------------"
    echo "${UNIQUE_MACS}" | while read -r mac; do
        count=$(grep -c "${mac}" "${CLIENT_FILE}" 2>/dev/null || echo 0)
        printf "  %-20s| %s frames\n" "${mac}" "${count}" >> "${REPORT_FILE}"
    done
fi

LOG green "Client discovery complete. Saw ${UNIQUE_CLIENTS} unique clients."


# ----------------------------------------------
#        STEP 8 — THREAT ASSESSMENT
#  Score findings and produce threat level
# ----------------------------------------------

section "THREAT ASSESSMENT"

# Score threat level based on indicators
THREAT_SCORE=0
[ "${OPEN_AP_COUNT:-0}" -gt 0 ]  && THREAT_SCORE=$((THREAT_SCORE + OPEN_AP_COUNT * 2))
[ "${HIDDEN_COUNT:-0}" -gt 0 ]   && THREAT_SCORE=$((THREAT_SCORE + HIDDEN_COUNT))
[ "${UNIQUE_CLIENTS:-0}" -gt 15 ] && THREAT_SCORE=$((THREAT_SCORE + 3))
[ "${AP_COUNT:-0}" -gt 20 ]       && THREAT_SCORE=$((THREAT_SCORE + 2))

if [ "${THREAT_SCORE}" -ge 10 ]; then
    THREAT_LEVEL="HIGH"
    THREAT_SUMMARY="Multiple threat indicators present. Immediate review recommended."
elif [ "${THREAT_SCORE}" -ge 4 ]; then
    THREAT_LEVEL="MEDIUM"
    THREAT_SUMMARY="Some indicators of concern. Review flagged APs."
else
    THREAT_LEVEL="LOW"
    THREAT_SUMMARY="No significant threats detected at time of capture."
fi

field "Threat Level"      "${THREAT_LEVEL}  (score: ${THREAT_SCORE})"
field "APs Discovered"    "${AP_COUNT:-0}"
field "Flagged APs"       "${OPEN_AP_COUNT:-0} open / ${HIDDEN_COUNT:-0} hidden"
field "Active Clients"    "${UNIQUE_CLIENTS:-0}"
field "Busiest Channel"   "${BUSIEST_CH:-unknown}"
field "Capture Duration"  "${CAPTURE_DURATION}s"
field "Session ID"        "${TIMESTAMP}"
field "Loot Directory"    "${LOOT_DIR}"
raw ""
raw "  Summary: ${THREAT_SUMMARY}"
raw ""
raw "  Files:"
raw "    incident_report.txt   — Full human-readable report"
raw "    access_points.txt     — Raw iw scan output"
raw "    clients.txt           — Raw client frame capture"
raw "    channel_activity.txt  — Channel sweep results"
raw "    environment.txt       — System/network state"


# ----------------------------------------------
#    STEP 9 — DISPLAY RESULTS ON PAGER SCREEN
# ----------------------------------------------

LOG ""
LOG "------------------------------"
LOG "       SKYPIEA COMPLETE"
LOG "------------------------------"

case "${THREAT_LEVEL}" in
    HIGH)
        LOG red    "  Threat  : HIGH ⚠"
        LOG red    "  Flagged : ${OPEN_AP_COUNT} open APs"
        ;;
    MEDIUM)
        LOG yellow "  Threat  : MEDIUM"
        LOG yellow "  Flagged : ${OPEN_AP_COUNT} open APs"
        ;;
    LOW)
        LOG green  "  Threat  : LOW"
        LOG green  "  Flagged : ${OPEN_AP_COUNT} open APs"
        ;;
esac

LOG "  APs     : ${AP_COUNT:-0}"
LOG "  Clients : ${UNIQUE_CLIENTS:-0}"
LOG "  Channel : ${BUSIEST_CH:-?} (busiest)"
LOG ""
LOG green "Loot saved: ${TIMESTAMP}"
LOG green "Review via SSH or Virtual Pager."


# ----------------------------------------------
#                      DONE
# ----------------------------------------------

exit 0

