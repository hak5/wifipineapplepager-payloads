#!/bin/bash
# Title: DEFCON Sentry - Repeat-Offense Deauth Alert
# Description: Warns loudly only when the SAME attacker sustains a deauth/disassoc flood.
# Author: Henry Hu
# Version: 1.1
# Category: Alerts
# Source: https://github.com/ninedter/DEFCON-DEFENSE
#
# Fires on the deauth_flood_detected event. Alerts when one offender
# (keyed per KEY_MODE) crosses REPEAT_THRESHOLD events within WINDOW_SECONDS,
# then stays quiet for COOLDOWN_SECONDS. A flood touching any WATCH_MACS entry
# alerts immediately. Every event is logged to STATE_DIR/events.log.

# ---- CONFIG (tune these) ----
REPEAT_THRESHOLD=3                        # same-offense hits to warn
WINDOW_SECONDS=120                        # counting window
COOLDOWN_SECONDS=300                      # silence after a warning (per offender)
KEY_MODE="source_ap"                      # source | source_ap | source_client
WATCH_MACS=""                             # your MACs, comma-separated -> instant warn
RINGTONE_NAME="urgent"                    # saved Pager ringtone (RINGTONE --vibrate plays it + buzzes in sync)
LED_STATE="ATTACK"
# RINGTONE_VIBRATE_ONLY=1                  # uncomment for discreet vibrate-only, no sound
# STATE_DIR alone honors an inherited env value (used by the integration test);
# on device it's unset, so this resolves to the default path below.
STATE_DIR="${STATE_DIR:-/root/loot/defcon_sentry}"
# ------------------------------

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/pager_alert_lib.sh"
PCAP_LIB="$DIR/pcap_evidence_lib.sh"
if [ ! -f "$PCAP_LIB" ] && [ -f "$DIR/../../../lib/pcap_evidence_lib.sh" ]; then
  PCAP_LIB="$DIR/../../../lib/pcap_evidence_lib.sh"
fi
if [ -f "$PCAP_LIB" ]; then
  # shellcheck source=/dev/null
  . "$PCAP_LIB"
fi

sentry_process_event
