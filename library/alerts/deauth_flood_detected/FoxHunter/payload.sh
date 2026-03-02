#!/bin/bash

# ============================================================
#
#  FoxHunter — Deauth Flood Alert Payload
#
#  Title:       FoxHunter
#  Description: Passive Deauth Flood Detection - Pager Version
#  Author:      0x00
#  Version:     1.0
#  Category:    Alert
#
#  Install to:  /root/payloads/alerts/deauth_flood_detected/foxhunter/
#
#  This is an alert payload for the WiFi Pineapple Pager.
#  It is automatically triggered by the Pagers PineAP recon
#  engine whenever a deauthentication flood is detected.
#
#  The Pager provides the following environment variables:
#
#    $_ALERT                                — Alert name
#    $_ALERT_DENIAL_MESSAGE                 — Human-readable description
#    $_ALERT_DENIAL_SOURCE_MAC_ADDRESS      — Attacking device MAC
#    $_ALERT_DENIAL_DESTINATION_MAC_ADDRESS — Target MAC
#    $_ALERT_DENIAL_AP_MAC_ADDRESS          — Targeted access point MAC
#    $_ALERT_DENIAL_CLIENT_MAC_ADDRESS      — Targeted client MAC
#
# ============================================================


# ──────────────────────────────────────────────
#                 CONFIGURATION
# ──────────────────────────────────────────────

# Log all deauth flood events to loot directory
ENABLE_LOGGING=true
LOG_FILE="/root/loot/foxhunter_events.log"


# ──────────────────────────────────────────────
#                     SETUP
# ──────────────────────────────────────────────

# Create loot directory if it doesnt exist
if [ "$ENABLE_LOGGING" = true ]; then
    mkdir -p /root/loot
fi


# ──────────────────────────────────────────────
#              COLLECT EVENT DATA
#  All data comes from PineAP environment vars.
#  Provide safe fallbacks if any are missing.
# ──────────────────────────────────────────────

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

SOURCE_MAC="${_ALERT_DENIAL_SOURCE_MAC_ADDRESS:-Unknown}"
DEST_MAC="${_ALERT_DENIAL_DESTINATION_MAC_ADDRESS:-Unknown}"
AP_MAC="${_ALERT_DENIAL_AP_MAC_ADDRESS:-Unknown}"
CLIENT_MAC="${_ALERT_DENIAL_CLIENT_MAC_ADDRESS:-Unknown}"
EVENT_MSG="${_ALERT_DENIAL_MESSAGE:-Deauth flood detected}"


# ──────────────────────────────────────────────
#              BUILD ALERT MESSAGE
#  ALERT displays full-screen on the Pager and
#  interrupts whatever screen the user is on.
#  Keep lines short to fit the display.
# ──────────────────────────────────────────────

ALERT_LINE_1="⚠ DEAUTH FLOOD DETECTED"
ALERT_LINE_2="Src: ${SOURCE_MAC}"
ALERT_LINE_3="AP:  ${AP_MAC}"
ALERT_LINE_4="Cli: ${CLIENT_MAC}"

ALERT "${ALERT_LINE_1}" "${ALERT_LINE_2}" "${ALERT_LINE_3}" "${ALERT_LINE_4}"


# ──────────────────────────────────────────────
#                     VIBRATE
#  Three short pulses — urgent, hard to miss.
#  Uses RTTTL format: short notes = short pulses.
# ──────────────────────────────────────────────

VIBRATE "foxhunter:d=16,o=5,b=200:8c5,p,8c5,p,8c5"


# ──────────────────────────────────────────────
#              LOG EVENT TO LOOT FILE
#  Saved to /root/loot/ so it survives reboots
#  and can be reviewed later via SSH or Virtual Pager.
# ──────────────────────────────────────────────

if [ "$ENABLE_LOGGING" = true ]; then
    {
        echo "──────────────────────────────────────────"
        echo "  FoxHunter Event — ${TIMESTAMP}"
        echo "──────────────────────────────────────────"
        echo "  Message : ${EVENT_MSG}"
        echo "  Source  : ${SOURCE_MAC}"
        echo "  Target  : ${DEST_MAC}"
        echo "  AP      : ${AP_MAC}"
        echo "  Client  : ${CLIENT_MAC}"
        echo ""
    } >> "$LOG_FILE"
fi


# ──────────────────────────────────────────────
#                      DONE
#  Alert payloads should exit cleanly and fast.
#  The Pager handles dismissal automatically.
# ──────────────────────────────────────────────

exit 0
