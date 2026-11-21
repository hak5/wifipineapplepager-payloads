#!/bin/bash
# Title: DEFCON Honeypot - Decoy AP Connect Alert
# Description: Warns when a client joins your intentional decoy AP; dedups reconnects.
# Author: Henry Hu
# Version: 1.0
# Category: Alerts
# Source: https://github.com/ninedter/DEFCON-DEFENSE
#
# Fires on the pineapple_client_connected event. Warns on the FIRST sighting of
# each client MAC (that connection IS the signal), then stays quiet for
# COOLDOWN_SECONDS so reassociations don't spam. Randomized MACs are flagged.
# Every connect is logged to STATE_DIR/honeypot.csv.

# ---- CONFIG (tune these) ----
COOLDOWN_SECONDS=600                      # per-client quiet time after a warning
RINGTONE_NAME="communicator"              # distinct tone from deauth alerts (RINGTONE --vibrate)
LED_STATE="SPECIAL"
# RINGTONE_VIBRATE_ONLY=1                  # uncomment for discreet vibrate-only, no sound
# STATE_DIR alone honors an inherited env value (for parity with defcon_sentry
# and test overrides); on device it's unset, resolving to the default below.
STATE_DIR="${STATE_DIR:-/root/loot/defcon_sentry}"
# ------------------------------

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/pager_alert_lib.sh"

honeypot_process_event
