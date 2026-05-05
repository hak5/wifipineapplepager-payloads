# Title: SignalFence
# Description: RSSI-based proximity alert with multi-signal device fingerprinting.
#              AP mode     : exact BSSID match via beacons.
#              CLIENT mode : exact MAC match, any frame.
#              FINGERPRINT : 3-signal scoring engine survives MAC randomization.
#                            Signal 1 — Probe SSID set match       (3 pts)
#                            Signal 2 — 802.11 sequence continuity  (3 pts)
#                            Signal 3 — IE capability fingerprint   (2 pts)
#                            Fires alert when score >= CONFIDENCE_THRESHOLD.
#                            Sequence number tracking works against iOS 14+
#                            and modern Android even without probe SSID content.
# Author: 4c1d.burn
# Version: 1.0
# Category: reconnaissance
# Net Mode: TRANSPARENT
# Dependencies: airmon-ng, tcpdump, iw, md5sum (all pre-installed on Pager)
#
# LED State Descriptions:
#   Blue Solid       - Initializing / setting up monitor mode
#   Cyan Blink       - FINGERPRINT enrollment in progress
#   Yellow Blink     - Scanning / no target detected
#   Red Blink x3    - Alert: target entered threshold
#   Red Solid        - Target holding in range
#   Green Solid      - Graceful shutdown

# =====================================================================
# CONFIGURATION — edit before deploying
# =====================================================================

TARGET_MAC="AA:BB:CC:DD:EE:FF"   # Real MAC — used for enrollment in FINGERPRINT mode.
                                  # After enrollment MAC rotation no longer breaks tracking.

TARGET_TYPE="AUTO"                # "AUTO"        — recommended: detects mode from MAC automatically
                                  #   Locally administered MAC (bit 1 set) → FINGERPRINT mode
                                  #   Real hardware MAC, sends beacons     → AP mode
                                  #   Real hardware MAC, client device      → CLIENT mode
                                  # "AP"          — force AP/BSSID mode (beacons, exact match)
                                  # "CLIENT"       — force client MAC mode (exact match)
                                  # "FINGERPRINT"  — force 3-signal scoring, survives MAC rotation

TARGET_LABEL="target"            # Human-readable name shown in all log output

# RSSI threshold (dBm — less negative = closer)
# -30 centimeters away | -60 same room ~5m | -70 adjacent room ~15m | -80 building edge ~30m
RSSI_THRESHOLD="-70"             # Fire alert when seen RSSI >= this value
RSSI_HYSTERESIS="5"              # Re-arm only after RSSI drops this many dBm below threshold

# FINGERPRINT scoring
# Max possible score = 8 (SSID=3 + SEQ=3 + IE=2)
# AUTO mode sets CONFIDENCE_THRESHOLD=3 for randomizing devices (seq alone fires)
CONFIDENCE_THRESHOLD="4"         # Minimum score to count as target match
                                  # 3 = seq alone fires (aggressive, better for phones)
                                  # 4 = seq + partial second signal (balanced)
                                  # 5 = two full signals required (strict)
SEQ_DELTA_TOLERANCE="100"        # Max 802.11 seq gap to count as continuity
                                  # Raised from 20: phones go quiet for 20-30s between
                                  # probe bursts; 100 covers ~5 missed cycles safely
SEQ_SOFT_TOLERANCE="500"         # Wider window for keeping chain alive without scoring
                                  # If delta <= this, seq file is updated silently
                                  # so the tracker survives long silences

# Timing
SCAN_INTERVAL="3"                 # Seconds between scans (AP mode only)
CAPTURE_TIMEOUT="8"               # Seconds listening per FINGERPRINT cycle (raised from 5)
                                  # AP/CLIENT modes still use 5s
ENROLL_DURATION="30"             # Seconds capturing known-MAC frames for enrollment
ENROLL_MIN_SSIDS="2"             # Minimum unique SSIDs for usable SSID fingerprint
                                  # (lowered from 3 — iOS/modern Android probe less)
ALERT_COOLDOWN="30"               # Seconds before a repeat alert fires

# Interfaces
BASE_IFACE="wlan1"               # Physical base interface (used only if monitor setup needed)
MONITOR_IFACE="wlan1mon"         # Monitor interface — set explicitly if already exists
                                  # Pager manages wlan1mon automatically; leave as-is
                                  # Blank = auto-detect after airmon-ng/iw setup

# Alert outputs (1=enabled, 0=disabled)
ALERT_LED="1"
ALERT_BUZZER="1"
ALERT_LOG="1"
ALERT_WEBHOOK="0"
WEBHOOK_URL="http://example.com/signalfence/alert"

# Paths
LOG_FILE="/tmp/signalfence.log"
PID_FILE="/tmp/signalfence.pid"
SSID_FILE="/tmp/signalfence_ssids.txt"   # Enrolled probe SSID set
SEQ_FILE="/tmp/signalfence_seq.txt"      # Last known sequence number (live-updated)
IE_FILE="/tmp/signalfence_ie.txt"        # Enrolled IE capability hash

# =====================================================================
# HELPERS
# =====================================================================

led_set() {
    if [ -x /usr/bin/pineapple-led ]; then
        /usr/bin/pineapple-led "$1" "${2:-solid}" 2>/dev/null
    elif [ -x /usr/bin/led ]; then
        /usr/bin/led "$1" "${2:-solid}" 2>/dev/null
    fi
}

led_off() {
    if [ -x /usr/bin/pineapple-led ]; then
        /usr/bin/pineapple-led off 2>/dev/null
    elif [ -x /usr/bin/led ]; then
        /usr/bin/led off 2>/dev/null
    fi
}

buzz() {
    [ -x /usr/bin/pineapple-buzzer ] && /usr/bin/pineapple-buzzer 2>/dev/null
}

log_msg() {
    TS=$(date '+%Y-%m-%d %H:%M:%S')
    LINE="[$TS] $1"
    echo "$LINE"
    [ "$ALERT_LOG" = "1" ] && echo "$LINE" >> "$LOG_FILE"
    # Also push to the Pager's on-screen log display
    LOG "$1" 2>/dev/null || true
}

now_epoch() {
    TS=$(date +%s 2>/dev/null)
    echo "$TS" | grep -qE '^[0-9]+$' && echo "$TS" || echo "0"
}

# =====================================================================
# AUTO MODE — detect AP / CLIENT / FINGERPRINT from MAC address
# =====================================================================
# The locally administered (LA) bit is bit 1 of the first octet.
# When set, the MAC is software-generated (randomized). When clear,
# it is a globally administered hardware MAC burned into the chipset.
#
# Detection logic:
#   LA bit set  → device is randomizing → FINGERPRINT mode
#   LA bit clear, sends beacons → it's an AP → AP mode
#   LA bit clear, no beacons    → it's a client → CLIENT mode

auto_detect_mode() {
    log_msg "AUTO mode: detecting target type from MAC..."

    # Extract first octet and test the LA bit (bit 1 = value 2)
    FIRST_OCTET=$(echo "$TARGET_MAC" | cut -d: -f1)
    OCTET_VAL=$(printf '%d' "0x${FIRST_OCTET}" 2>/dev/null || echo "0")
    LA_BIT=$((OCTET_VAL & 2))

    if [ "$LA_BIT" = "2" ]; then
        TARGET_TYPE="FINGERPRINT"
        # Lower threshold to 3 so seq number alone fires — critical for modern phones
        # that probe infrequently and won't reliably give SSID or IE signals.
        CONFIDENCE_THRESHOLD="3"
        log_msg "AUTO → FINGERPRINT (randomized MAC) | threshold lowered to 3 (seq alone fires)"
        LOG "AUTO: Randomized MAC → FINGERPRINT, threshold=3" 2>/dev/null || true
        return 0
    fi

    # Real hardware MAC — check if it's an AP by listening for beacons
    log_msg "AUTO: Real hardware MAC detected. Checking for beacons..."
    DETECT_SPIN=$(START_SPINNER "AUTO: Detecting AP or client..." 2>/dev/null)
    BEACON_CHECK=$(timeout 5 tcpdump         -i "$MONITOR_IFACE" -c 1 -e         "ether src $TARGET_MAC and type mgt subtype beacon" 2>/dev/null)
    STOP_SPINNER $DETECT_SPIN 2>/dev/null || true

    if [ -n "$BEACON_CHECK" ]; then
        TARGET_TYPE="AP"
        log_msg "AUTO → AP (beacon frames detected from this MAC)"
        LOG "AUTO: AP detected → AP mode" 2>/dev/null || true
    else
        TARGET_TYPE="CLIENT"
        log_msg "AUTO → CLIENT (no beacons — treating as client device)"
        LOG "AUTO: No beacons → CLIENT mode" 2>/dev/null || true
    fi
}

# =====================================================================
# PREFLIGHT — interactive dependency checker + installer
# =====================================================================
# Maps each binary to its opkg package name.
# Prompts the user to install each missing dep individually.
# If stdin is not a TTY (running headlessly from Pager UI),
# falls back to AUTO_INSTALL_DEPS config flag.

AUTO_INSTALL_DEPS="0"   # Set to "1" to install missing deps without prompting
                         # Useful when running from the Pager UI (no terminal)

pkg_for() {
    case "$1" in
        tcpdump)   echo "tcpdump" ;;
        airmon-ng) echo "aircrack-ng" ;;
        iw)        echo "iw" ;;
        md5sum)    echo "coreutils-md5sum" ;;
        curl)      echo "curl" ;;
        *)         echo "$1" ;;
    esac
}

try_install() {
    BIN="$1"
    PKG=$(pkg_for "$BIN")
    log_msg "Attempting: opkg update && opkg install $PKG"

    # Need network — check briefly
    if ! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        log_msg "ERROR: No network connectivity. Connect the Pager to the internet"
        log_msg "       (client mode or USB tethering) and retry."
        return 1
    fi

    opkg update >/dev/null 2>&1
    if opkg install "$PKG" 2>&1 | tee -a "$LOG_FILE" | grep -q "Installed\|up to date"; then
        log_msg "OK: $PKG installed successfully."
        return 0
    else
        log_msg "ERROR: opkg install $PKG failed. Try manually:"
        log_msg "  opkg update && opkg install $PKG"
        return 1
    fi
}

prompt_install() {
    BIN="$1"
    PKG=$(pkg_for "$BIN")

    # Non-interactive (headless Pager UI run): respect AUTO_INSTALL_DEPS
    if [ ! -t 0 ]; then
        if [ "$AUTO_INSTALL_DEPS" = "1" ]; then
            log_msg "Non-interactive mode: AUTO_INSTALL_DEPS=1 — installing $PKG..."
            try_install "$BIN"
            return $?
        else
            log_msg "Non-interactive mode: AUTO_INSTALL_DEPS=0 — skipping install of $PKG."
            log_msg "Set AUTO_INSTALL_DEPS=1 in config or install manually:"
            log_msg "  opkg update && opkg install $PKG"
            return 1
        fi
    fi

    # Interactive (SSH session): ask the user
    printf "\n[SignalFence] '%s' is missing (package: %s)\n" "$BIN" "$PKG"
    printf "[SignalFence] Install it now via opkg? [y/N]: "
    read -r ANSWER </dev/tty
    case "$ANSWER" in
        y|Y|yes|YES)
            try_install "$BIN"
            return $?
            ;;
        *)
            log_msg "Skipped install of $PKG."
            return 1
            ;;
    esac
}

check_deps() {
    FAILED=""

    log_msg "--- Dependency check ---"

    # Core binaries
    for BIN in tcpdump iw; do
        if command -v "$BIN" >/dev/null 2>&1; then
            log_msg "  [OK] $BIN"
        else
            log_msg "  [MISSING] $BIN"
            prompt_install "$BIN" || FAILED="$FAILED $BIN"
        fi
    done

    # airmon-ng — has iw fallback so only warn, don't hard-fail
    if command -v airmon-ng >/dev/null 2>&1; then
        log_msg "  [OK] airmon-ng"
        USE_IW_FALLBACK="0"
    else
        log_msg "  [MISSING] airmon-ng — will use iw fallback for monitor mode"
        USE_IW_FALLBACK="1"
        # Still offer install
        if ! prompt_install "airmon-ng"; then
            log_msg "  Continuing with iw fallback (no airmon-ng needed)."
        else
            USE_IW_FALLBACK="0"
        fi
    fi

    # md5sum (BusyBox applet)
    if echo "test" | md5sum >/dev/null 2>&1; then
        log_msg "  [OK] md5sum"
    else
        log_msg "  [MISSING] md5sum"
        prompt_install "md5sum" || FAILED="$FAILED md5sum"
    fi

    # curl — optional, only for webhook
    if [ "$ALERT_WEBHOOK" = "1" ]; then
        if command -v curl >/dev/null 2>&1; then
            log_msg "  [OK] curl"
        else
            log_msg "  [MISSING] curl (needed for webhook)"
            if ! prompt_install "curl"; then
                log_msg "  WARNING: ALERT_WEBHOOK disabled for this run."
                ALERT_WEBHOOK="0"
            fi
        fi
    fi

    if [ -n "$FAILED" ]; then
        log_msg "ERROR: Required tools still missing after install attempt:$FAILED"
        log_msg "Cannot continue. Fix manually via SSH:"
        log_msg "  opkg update"
        for T in $FAILED; do
            log_msg "  opkg install $(pkg_for $T)"
        done
        return 1
    fi

    # Interface validation:
    # If MONITOR_IFACE is already set and already in monitor mode — skip setup entirely.
    # This is the normal Pager state: wlan1mon is managed by the firmware automatically.
    if [ -n "$MONITOR_IFACE" ] && iw dev "$MONITOR_IFACE" info >/dev/null 2>&1; then
        MODE=$(iw dev "$MONITOR_IFACE" info 2>/dev/null | grep "type" | awk '{print $2}')
        if [ "$MODE" = "monitor" ]; then
            log_msg "  [OK] $MONITOR_IFACE already in monitor mode — skipping interface setup."
            SKIP_MONITOR_SETUP="1"
            log_msg "--- Preflight OK ---"
            return 0
        fi
    fi

    # MONITOR_IFACE not ready — will need to set up from BASE_IFACE
    SKIP_MONITOR_SETUP="0"
    if ! iw dev "$BASE_IFACE" info >/dev/null 2>&1; then
        log_msg "ERROR: Interface '$BASE_IFACE' not found and MONITOR_IFACE not in monitor mode."
        log_msg "Available interfaces:"
        iw dev 2>/dev/null | grep "Interface" | awk '{print "  " $2}'
        log_msg "Set MONITOR_IFACE= to an existing monitor interface (e.g. wlan1mon)"
        log_msg "or set BASE_IFACE= to a managed interface to be put into monitor mode."
        return 1
    fi

    log_msg "--- Preflight OK ---"
    return 0
}

# =====================================================================
# INTERFACE MANAGEMENT
# =====================================================================
# setup_monitor is skipped entirely when monitor interface already exists.
# SKIP_MONITOR_SETUP is set by check_deps above.

SKIP_MONITOR_SETUP="0"
USE_IW_FALLBACK="0"

setup_monitor() {
    # If monitor interface already exists and is ready — nothing to do
    if [ "$SKIP_MONITOR_SETUP" = "1" ]; then
        log_msg "Monitor interface $MONITOR_IFACE ready (pre-existing)."
        return 0
    fi

    log_msg "Starting monitor mode on $BASE_IFACE..."

    if [ "$USE_IW_FALLBACK" = "0" ]; then
        # Preferred: airmon-ng handles killing interfering processes too
        airmon-ng check kill >/dev/null 2>&1
        airmon-ng start "$BASE_IFACE" >/dev/null 2>&1
        sleep 2
    else
        # iw fallback: bring iface down, set monitor, bring up
        log_msg "Using iw fallback for monitor mode (airmon-ng not available)."
        ip link set "$BASE_IFACE" down 2>/dev/null || \
            ifconfig "$BASE_IFACE" down 2>/dev/null
        iw dev "$BASE_IFACE" set type monitor 2>/dev/null
        ip link set "$BASE_IFACE" up 2>/dev/null || \
            ifconfig "$BASE_IFACE" up 2>/dev/null
        sleep 2
        # In iw fallback the interface keeps its original name
        MONITOR_IFACE="$BASE_IFACE"
    fi

    if [ -z "$MONITOR_IFACE" ]; then
        MONITOR_IFACE=$(iw dev 2>/dev/null | \
            grep -B1 "type monitor" | \
            grep "Interface" | \
            awk '{print $2}' | head -1)
    fi

    if [ -z "$MONITOR_IFACE" ] || ! iw dev "$MONITOR_IFACE" info >/dev/null 2>&1; then
        log_msg "ERROR: Could not establish monitor mode on $BASE_IFACE."
        log_msg "Try setting MONITOR_IFACE manually in config."
        return 1
    fi

    log_msg "Monitor interface: $MONITOR_IFACE"
    return 0
}

teardown_monitor() {
    # If we didn't set up monitor mode, don't tear it down — the Pager manages it
    if [ "$SKIP_MONITOR_SETUP" = "1" ]; then
        log_msg "Monitor interface left intact (managed by Pager firmware)."
        return 0
    fi
    if [ "$USE_IW_FALLBACK" = "0" ]; then
        [ -n "$MONITOR_IFACE" ] && airmon-ng stop "$MONITOR_IFACE" >/dev/null 2>&1
    else
        ip link set "$BASE_IFACE" down 2>/dev/null || \
            ifconfig "$BASE_IFACE" down 2>/dev/null
        iw dev "$BASE_IFACE" set type managed 2>/dev/null
        ip link set "$BASE_IFACE" up 2>/dev/null || \
            ifconfig "$BASE_IFACE" up 2>/dev/null
    fi
}

# =====================================================================
# RSSI HELPERS
# =====================================================================

parse_rssi() {
    # Average all dBm values in tcpdump radiotap output
    SIGNALS=$(echo "$1" | grep -oE '\-[0-9]+dBm' | sed 's/dBm//')
    [ -z "$SIGNALS" ] && echo "" && return
    echo "$SIGNALS" | awk '{s+=$1; n++} END {if(n>0) printf "%d", s/n; else print ""}'
}

get_ap_rssi() {
    RAW=$(timeout "$CAPTURE_TIMEOUT" tcpdump \
        -i "$MONITOR_IFACE" -c 5 -v -e \
        "ether src $TARGET_MAC and type mgt subtype beacon" 2>/dev/null)
    parse_rssi "$RAW"
}

get_client_rssi() {
    RAW=$(timeout "$CAPTURE_TIMEOUT" tcpdump \
        -i "$MONITOR_IFACE" -c 5 -v -e \
        "ether src $TARGET_MAC" 2>/dev/null)
    parse_rssi "$RAW"
}

# =====================================================================
# FINGERPRINT ENGINE — PER-FRAME SCORING
# =====================================================================
#
# Three signals, each contributes to a confidence score:
#
#   Signal 1 — SSID set match (3 pts)
#     Device probes for an SSID in the enrolled Preferred Network List.
#     Works: older Android, Windows, devices with randomization off.
#     Fails: iOS 14+, Android 12+ (wildcard-only probes or none at all).
#
#   Signal 2 — 802.11 sequence number continuity (3 pts)
#     The 12-bit 802.11 seq counter increments per-frame on the hardware
#     and does NOT reset on MAC rotation. If the observed seq number is
#     within SEQ_DELTA_TOLERANCE of the last confirmed seq, same device.
#     Works: ALL devices including iOS 14+ — fires on data/ack frames too,
#     not just probe requests. This is the key signal for modern phones.
#     The last confirmed seq is updated on every confident match, keeping
#     the chain alive across rotations indefinitely.
#     Handles 12-bit wraparound (0–4095).
#
#   Signal 3 — IE capability fingerprint (2 pts)
#     The set of 802.11 Information Elements in probe requests — supported
#     rates, HT/VHT capabilities, vendor-specific OUI list — is determined
#     by the WiFi chipset/driver, not the OS or MAC address. Hashed and
#     compared against the enrolled hash.
#     Works: any device that sends probe requests.
#     Fails: devices sending no probes (iOS 14+ in passive mode).
#
# Score >= CONFIDENCE_THRESHOLD = target match confirmed.
# Score >= SEQ score alone (3) = seq tracker updated (keeps chain alive).

# Score a single frame. Uses globals set by the parser.
# Sets FRAME_SCORE. Updates SEQ_FILE on seq match.
score_frame() {
    FRAME_SCORE=0
    SEQ_MATCHED=0

    # ---- Signal 1: SSID set match (3 pts) ----
    if [ -n "$F_SSID" ] && [ -n "$ENROLLED_SSIDS" ]; then
        if echo "$ENROLLED_SSIDS" | grep -qF "$F_SSID"; then
            FRAME_SCORE=$((FRAME_SCORE + 3))
            SEQ_MATCHED=1
            log_msg "  [+3] SSID match: '$F_SSID'"
        fi
    fi

    # ---- Signal 2: Sequence number continuity (3 pts) ----
    if [ -n "$F_SEQ" ]; then
        LAST_SEQ=$(cat "$SEQ_FILE" 2>/dev/null)
        if [ -n "$LAST_SEQ" ] && [ "$LAST_SEQ" != "0" ]; then
            # Compute delta with 12-bit wraparound handling (counter is 0-4095)
            DELTA=$((F_SEQ - LAST_SEQ))
            if [ "$DELTA" -lt "0" ]; then
                DELTA=$((DELTA + 4096))
            fi

            if [ "$DELTA" -le "$SEQ_DELTA_TOLERANCE" ] && [ "$DELTA" -gt "0" ]; then
                # Hard match — within tight tolerance, full score
                FRAME_SCORE=$((FRAME_SCORE + 3))
                SEQ_MATCHED=1
                log_msg "  [+3] Seq continuity: last=$LAST_SEQ now=$F_SEQ delta=$DELTA"
                echo "$F_SEQ" > "$SEQ_FILE"

            elif [ "$DELTA" -le "$SEQ_SOFT_TOLERANCE" ] && [ "$DELTA" -gt "0" ]; then
                # Soft match — phone was quiet for several cycles, gap too large for
                # full score but still plausibly the same device. Update tracker
                # silently to keep the chain alive. No score contribution.
                log_msg "  [~0] Seq soft update: last=$LAST_SEQ now=$F_SEQ delta=$DELTA (chain kept)"
                echo "$F_SEQ" > "$SEQ_FILE"
            fi
        fi

        # First-seen after enrollment — bootstrap the tracker
        if [ -z "$LAST_SEQ" ] || [ "$LAST_SEQ" = "0" ]; then
            if [ "$SEQ_MATCHED" = "1" ]; then
                echo "$F_SEQ" > "$SEQ_FILE"
            fi
        fi
    fi

    # ---- Signal 3: IE capability fingerprint (2 pts) ----
    if [ -n "$F_RATES" ] || [ -n "$F_VENDORS" ]; then
        ENROLLED_IE=$(cat "$IE_FILE" 2>/dev/null)
        if [ -n "$ENROLLED_IE" ]; then
            CURRENT_IE=$(echo "${F_RATES}|${F_VENDORS}" | md5sum | cut -d' ' -f1)
            if [ "$CURRENT_IE" = "$ENROLLED_IE" ]; then
                FRAME_SCORE=$((FRAME_SCORE + 2))
                log_msg "  [+2] IE fingerprint match: $CURRENT_IE"
            fi
        fi
    fi
}

# Called after each frame's state variables are fully populated.
# Skips multicast/broadcast MACs, scores the frame, tracks best match.
# Uses globals: F_MAC, F_SIGNAL, F_SEQ, F_SSID, F_RATES, F_VENDORS
# Updates globals: BEST_SCORE, BEST_RSSI, BEST_MAC
process_current_frame() {
    [ -z "$F_MAC" ] && return

    # Skip multicast/broadcast source MACs (bit 0 of first octet set)
    FIRST_OCTET=$(echo "$F_MAC" | cut -d: -f1)
    ODD=$(printf '%d' "0x${FIRST_OCTET}" 2>/dev/null)
    MULTICAST=$((ODD & 1))
    [ "$MULTICAST" = "1" ] && return

    score_frame

    # Accumulate score across all frames from the same MAC in this capture window.
    # A phone sending 5 probe frames per cycle, each matching SSID (+3), accumulates
    # 15 pts total — far above threshold — giving much stickier tracking than
    # single-best-frame selection which would only ever see max 3 from SSID alone.
    # We track the best RSSI seen from any matching frame separately.
    if [ "$FRAME_SCORE" -gt "0" ]; then
        if [ "$F_MAC" = "$BEST_MAC" ]; then
            # Same MAC as current best — accumulate
            BEST_SCORE=$((BEST_SCORE + FRAME_SCORE))
            # Keep strongest RSSI reading
            if [ -n "$F_SIGNAL" ] && [ -n "$BEST_RSSI" ]; then
                if [ "$F_SIGNAL" -gt "$BEST_RSSI" ]; then
                    BEST_RSSI="$F_SIGNAL"
                fi
            fi
        elif [ "$FRAME_SCORE" -gt "$BEST_SCORE" ]; then
            # Different MAC with higher score — new best
            BEST_SCORE="$FRAME_SCORE"
            BEST_RSSI="$F_SIGNAL"
            BEST_MAC="$F_MAC"
        fi
    fi
}

# Capture all management frames and score each one against the fingerprint.
# Returns: "<rssi> <mac> <score>" of best matching frame, or empty.
get_fingerprint_match() {
    ENROLLED_SSIDS=$(cat "$SSID_FILE" 2>/dev/null)

    # Capture all management frames — broad net needed for seq number tracking.
    # Use longer timeout and more frames for FINGERPRINT mode since phones
    # can be silent for 10-30s between probe bursts.
    FP_TIMEOUT="$CAPTURE_TIMEOUT"
    RAW=$(timeout "$FP_TIMEOUT" tcpdump \
        -i "$MONITOR_IFACE" -c 300 -vv -e \
        "type mgt" 2>/dev/null)

    [ -z "$RAW" ] && echo "" && return

    BEST_SCORE=0
    BEST_RSSI=""
    BEST_MAC=""

    # Per-frame state (reset on each new frame boundary)
    F_SIGNAL=""
    F_MAC=""
    F_SEQ=""
    F_SSID=""
    F_RATES=""
    F_VENDORS=""

    while IFS= read -r LINE; do

        # New frame boundary: line starts with timestamp HH:MM:SS.NNNNNN
        if echo "$LINE" | grep -qE '^[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+'; then
            process_current_frame
            # Reset per-frame state
            F_SIGNAL=""
            F_MAC=""
            F_SEQ=""
            F_SSID=""
            F_RATES=""
            F_VENDORS=""

            # Extract signal from timestamp line (radiotap header)
            SIG=$(echo "$LINE" | grep -oE '\-[0-9]+dBm' | sed 's/dBm//' | head -1)
            [ -n "$SIG" ] && F_SIGNAL="$SIG"
            continue
        fi

        # Source MAC (SA:xx:xx:xx:xx:xx:xx)
        if echo "$LINE" | grep -q "SA:"; then
            M=$(echo "$LINE" | grep -oE 'SA:[0-9a-f:]{17}' | sed 's/SA://' | head -1)
            [ -n "$M" ] && F_MAC="$M"
        fi

        # Signal on non-timestamp lines (some drivers put it here)
        if [ -z "$F_SIGNAL" ]; then
            SIG=$(echo "$LINE" | grep -oE '\-[0-9]+dBm' | sed 's/dBm//' | head -1)
            [ -n "$SIG" ] && F_SIGNAL="$SIG"
        fi

        # 802.11 sequence number
        if echo "$LINE" | grep -qiE 'sequence:? [0-9]+'; then
            SQ=$(echo "$LINE" | grep -oiE 'sequence:? [0-9]+' | grep -oE '[0-9]+' | tail -1)
            [ -n "$SQ" ] && F_SEQ="$SQ"
        fi

        # Probe request SSID (skip empty/wildcard)
        if echo "$LINE" | grep -q "Probe Request"; then
            PS=$(echo "$LINE" | \
                grep -o 'Probe Request ([^)]*)' | \
                sed 's/Probe Request (//' | sed 's/)//')
            [ -n "$PS" ] && F_SSID="$PS"
        fi

        # Supported rates line — IE fingerprint component
        if echo "$LINE" | grep -qE '\[b?( [0-9]+\.[0-9]+\*?)+Mbit\]'; then
            F_RATES=$(echo "$LINE" | grep -oE '\[.*Mbit\]' | head -1)
        fi

        # Vendor OUI — IE fingerprint component (accumulate all vendors for this frame)
        if echo "$LINE" | grep -q "Vendor:"; then
            OUI=$(echo "$LINE" | grep -oE '\(0x[0-9a-f]+\)' | head -1)
            [ -n "$OUI" ] && F_VENDORS="${F_VENDORS}${OUI}"
        fi

    done <<PARSE_EOF
$RAW
PARSE_EOF

    # Process the last frame in the buffer
    process_current_frame

    if [ -n "$BEST_RSSI" ] && [ "$BEST_SCORE" -ge "$CONFIDENCE_THRESHOLD" ]; then
        echo "$BEST_RSSI $BEST_MAC $BEST_SCORE"
    else
        echo ""
    fi
}

# =====================================================================
# FINGERPRINT ENROLLMENT
# =====================================================================

enroll_fingerprint() {
    log_msg "======================================================="
    log_msg "FINGERPRINT ENROLLMENT — v1.0 (3-signal)"
    log_msg "Known real MAC: $TARGET_MAC"
    log_msg "Capturing for ${ENROLL_DURATION}s..."
    log_msg "On the target device: toggle WiFi off then on to force probing."
    log_msg "MAC randomization MUST be disabled during enrollment."
    log_msg "  Android: Settings > WiFi > [network gear] > Privacy > Use device MAC"
    log_msg "  iOS: Settings > WiFi > [network i] > Private Wi-Fi Address > OFF"
    log_msg "======================================================="

    led_set cyan blink

    # Capture all management frames from known MAC — we need mgt for seq + IE + SSID
    RAW=$(timeout "$ENROLL_DURATION" tcpdump \
        -i "$MONITOR_IFACE" -c 200 -vv -e \
        "ether src $TARGET_MAC" 2>/dev/null)

    if [ -z "$RAW" ]; then
        log_msg "ERROR: No frames captured from $TARGET_MAC during enrollment."
        log_msg "Check: device is nearby, MAC randomization is disabled, MAC is correct."
        return 1
    fi

    # ---- Enroll Signal 1: SSID set ----
    SSID_LIST=$(echo "$RAW" | \
        grep "Probe Request" | \
        grep -o 'Probe Request ([^)]*)' | \
        sed 's/Probe Request (//' | sed 's/)//' | \
        grep -v '^$' | sort -u)
    SSID_COUNT=$(echo "$SSID_LIST" | grep -c . 2>/dev/null || echo "0")

    if [ "$SSID_COUNT" -lt "$ENROLL_MIN_SSIDS" ]; then
        log_msg "WARNING: Only $SSID_COUNT probe SSIDs captured (min: $ENROLL_MIN_SSIDS)."
        log_msg "SSID signal will be weak. Seq+IE signals will compensate."
        log_msg "Increase ENROLL_DURATION or prompt more WiFi scanning activity."
    fi
    echo "$SSID_LIST" > "$SSID_FILE"
    log_msg "Signal 1 (SSID set): $SSID_COUNT unique SSIDs enrolled."
    echo "$SSID_LIST" | while IFS= read -r S; do
        [ -n "$S" ] && log_msg "  + $S"
    done

    # ---- Enroll Signal 2: Sequence number ----
    LAST_SEQ=$(echo "$RAW" | \
        grep -oiE 'sequence:? [0-9]+' | \
        grep -oE '[0-9]+' | \
        tail -1)
    if [ -n "$LAST_SEQ" ]; then
        echo "$LAST_SEQ" > "$SEQ_FILE"
        log_msg "Signal 2 (seq number): last seen seq=$LAST_SEQ enrolled."
    else
        echo "0" > "$SEQ_FILE"
        log_msg "WARNING: No sequence numbers found in enrollment capture."
        log_msg "Seq signal unavailable until first confident match updates the tracker."
    fi

    # ---- Enroll Signal 3: IE capability fingerprint ----
    RATES=$(echo "$RAW" | grep -oE '\[.*Mbit\]' | head -1)
    VENDORS=$(echo "$RAW" | grep "Vendor:" | \
        grep -oE '\(0x[0-9a-f]+\)' | sort -u | tr -d '\n')

    if [ -n "$RATES" ] || [ -n "$VENDORS" ]; then
        IE_HASH=$(echo "${RATES}|${VENDORS}" | md5sum | cut -d' ' -f1)
        echo "$IE_HASH" > "$IE_FILE"
        log_msg "Signal 3 (IE fingerprint): hash=$IE_HASH enrolled."
        log_msg "  Rates   : $RATES"
        log_msg "  Vendors : $VENDORS"
    else
        echo "" > "$IE_FILE"
        log_msg "WARNING: No IE data captured. IE signal disabled."
        log_msg "Ensure target is sending probe requests during enrollment."
    fi

    FP_HASH=$(cat "$SSID_FILE" "$SEQ_FILE" "$IE_FILE" 2>/dev/null | md5sum | cut -d' ' -f1)
    log_msg "======================================================="
    log_msg "Enrollment complete. Combined fingerprint hash: $FP_HASH"
    log_msg "MAC randomization can now be re-enabled on target device."
    log_msg "======================================================="

    return 0
}

# =====================================================================
# ALERTING
# =====================================================================

fire_alert() {
    RSSI="$1"
    DETECTED_MAC="$2"
    SCORE="$3"

    if [ "$TARGET_TYPE" = "FINGERPRINT" ] && \
       [ -n "$DETECTED_MAC" ] && [ "$DETECTED_MAC" != "$TARGET_MAC" ]; then
        log_msg "ALERT *** $TARGET_LABEL fingerprint match | MAC=${DETECTED_MAC} | RSSI=${RSSI}dBm | score=${SCORE}/8 ***"
    else
        log_msg "ALERT *** $TARGET_LABEL ($TARGET_MAC) IN RANGE | RSSI=${RSSI}dBm | threshold=${RSSI_THRESHOLD}dBm ***"
    fi

    # On-screen full-screen alert
    if [ "$TARGET_TYPE" = "FINGERPRINT" ] && [ -n "$DETECTED_MAC" ] && [ "$DETECTED_MAC" != "$TARGET_MAC" ]; then
        ALERT "SignalFence\n${TARGET_LABEL} IN RANGE\nMAC: ${DETECTED_MAC}\nRSSI: ${RSSI}dBm  Score: ${SCORE}/8" 2>/dev/null || true
    else
        ALERT "SignalFence\n${TARGET_LABEL} IN RANGE\nRSSI: ${RSSI}dBm" 2>/dev/null || true
    fi
    VIBRATE 500 2>/dev/null || true

    if [ "$ALERT_LED" = "1" ]; then
        i=0
        while [ $i -lt 3 ]; do
            led_set red solid; usleep 300000
            led_off;           usleep 200000
            i=$((i + 1))
        done
        led_set red solid
    fi

    [ "$ALERT_BUZZER" = "1" ] && buzz

    if [ "$ALERT_WEBHOOK" = "1" ] && [ -n "$WEBHOOK_URL" ]; then
        TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        JSON="{\"target\":\"$TARGET_MAC\",\"label\":\"$TARGET_LABEL\",\"type\":\"$TARGET_TYPE\",\"detected_mac\":\"${DETECTED_MAC:-$TARGET_MAC}\",\"rssi\":$RSSI,\"score\":${SCORE:-0},\"threshold\":$RSSI_THRESHOLD,\"confidence_threshold\":$CONFIDENCE_THRESHOLD,\"ts\":\"$TS\"}"
        curl -s -m 5 -X POST \
            -H "Content-Type: application/json" \
            -d "$JSON" "$WEBHOOK_URL" >/dev/null 2>&1 &
    fi
}

# =====================================================================
# CLEANUP
# =====================================================================

cleanup() {
    log_msg "SignalFence shutting down."
    led_set green solid
    teardown_monitor
    sleep 1
    led_off
    rm -f "$PID_FILE"
}

trap cleanup EXIT INT TERM

# =====================================================================
# MAIN
# =====================================================================

echo $$ > "$PID_FILE"
led_set blue solid

# ── Splash screen — shown once on startup ─────────────────────────────
PROMPT "SignalFence v1.0

RSSI proximity alert with multi-signal
device fingerprinting. Tracks APs,
clients, and MAC-randomizing phones.

Signals: Probe SSID | Seq# | IE caps
Modes: AUTO / AP / CLIENT / FINGERPRINT

Author : 4c1d.burn
IG     : @4c1d.burn
GitHub : github.com/4cidburnn" 2>/dev/null || true

# ── Step 1: Let user enter TARGET_MAC on device screen ────────────────
# If TARGET_MAC is still the placeholder, prompt on-screen via MAC_PICKER.
# This means you NEVER need to hardcode the MAC in the config file.
if [ "$TARGET_MAC" = "AA:BB:CC:DD:EE:FF" ] || [ "$TARGET_MAC" = "aa:bb:cc:dd:ee:ff" ]; then
    TARGET_MAC=$(MAC_PICKER "SignalFence: Target MAC" "aa:bb:cc:dd:ee:ff" 2>/dev/null)
    # MAC_PICKER returns empty if user cancels
    if [ -z "$TARGET_MAC" ]; then
        LOG "Cancelled by user." 2>/dev/null || true
        exit 0
    fi
fi

# Validate MAC
TARGET_MAC_CLEAN=$(echo "$TARGET_MAC" | tr 'A-Z' 'a-z' | \
    grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}')
if [ -z "$TARGET_MAC_CLEAN" ]; then
    ERROR_DIALOG "Invalid MAC: $TARGET_MAC" 2>/dev/null || true
    log_msg "ERROR: TARGET_MAC '$TARGET_MAC' is not a valid MAC address."
    exit 1
fi
TARGET_MAC="$TARGET_MAC_CLEAN"

case "$TARGET_TYPE" in
    AUTO|AP|CLIENT|FINGERPRINT) ;;
    *)
        ERROR_DIALOG "Bad TARGET_TYPE: $TARGET_TYPE" 2>/dev/null || true
        log_msg "ERROR: TARGET_TYPE must be AUTO, AP, CLIENT, or FINGERPRINT."
        exit 1
        ;;
esac

# ── Step 2: Preflight ─────────────────────────────────────────────────
INIT_SPIN=$(START_SPINNER "Preflight checks..." 2>/dev/null)
check_deps
DEPS_OK=$?
STOP_SPINNER $INIT_SPIN 2>/dev/null || true
if [ "$DEPS_OK" != "0" ]; then
    ERROR_DIALOG "Dependency check failed. See log." 2>/dev/null || true
    exit 1
fi

# ── Step 3: Monitor mode ──────────────────────────────────────────────
MON_SPIN=$(START_SPINNER "Starting monitor mode..." 2>/dev/null)
setup_monitor
MON_OK=$?
STOP_SPINNER $MON_SPIN 2>/dev/null || true
if [ "$MON_OK" != "0" ]; then
    ERROR_DIALOG "Monitor mode failed. See log." 2>/dev/null || true
    exit 1
fi

# ── Step 4: AUTO mode detection (must happen after monitor is up) ─────
if [ "$TARGET_TYPE" = "AUTO" ]; then
    auto_detect_mode
fi

log_msg "======================================================="
log_msg "SignalFence v1.0"
log_msg "Target  : $TARGET_LABEL ($TARGET_MAC) [$TARGET_TYPE]"
log_msg "RSSI    : alert >= ${RSSI_THRESHOLD}dBm | re-arm < $((RSSI_THRESHOLD - RSSI_HYSTERESIS))dBm"
if [ "$TARGET_TYPE" = "FINGERPRINT" ]; then
    log_msg "Score   : threshold=${CONFIDENCE_THRESHOLD}/8 (SSID=3 SEQ=3 IE=2)"
fi
log_msg "======================================================="

# ── Step 5: Enrollment (FINGERPRINT only) ────────────────────────────
if [ "$TARGET_TYPE" = "FINGERPRINT" ]; then
    ENROLL_SPIN=$(START_SPINNER "Enrolling ${TARGET_LABEL}... ${ENROLL_DURATION}s" 2>/dev/null)
    enroll_fingerprint
    ENROLL_OK=$?
    STOP_SPINNER $ENROLL_SPIN 2>/dev/null || true
    if [ "$ENROLL_OK" != "0" ]; then
        ERROR_DIALOG "Enrollment failed. Disable MAC randomization and retry." 2>/dev/null || true
        exit 1
    fi
fi

# ── Step 5: Main scan loop ───────────────────────────────────────────
log_msg "Scanning for ${TARGET_LABEL}..."
led_set yellow blink

LAST_ALERT=0
ARMED=1   # 1 = watching for entry | 0 = target in range, waiting for exit

while true; do

    RSSI=""
    DETECTED_MAC=""
    DETECTED_SCORE=""

    case "$TARGET_TYPE" in
        AP)
            RSSI=$(get_ap_rssi)
            ;;
        CLIENT)
            RSSI=$(get_client_rssi)
            ;;
        FINGERPRINT)
            RESULT=$(get_fingerprint_match)
            if [ -n "$RESULT" ]; then
                RSSI=$(echo "$RESULT"          | awk '{print $1}')
                DETECTED_MAC=$(echo "$RESULT"  | awk '{print $2}')
                DETECTED_SCORE=$(echo "$RESULT"| awk '{print $3}')
            fi
            ;;
    esac

    NOW=$(now_epoch)

    # --- Not visible ---
    if [ -z "$RSSI" ]; then
        if [ "$TARGET_TYPE" = "FINGERPRINT" ]; then
            log_msg "No match  (score < ${CONFIDENCE_THRESHOLD}/8)"
        else
            log_msg "No signal from ${TARGET_LABEL}"
        fi
        if [ "$ARMED" = "0" ]; then
            log_msg "Target lost — re-arming."
            ARMED=1
        fi
        led_set yellow blink
        [ "$TARGET_TYPE" = "AP" ] && sleep "$SCAN_INTERVAL"
        continue
    fi

    # --- Visible ---
    if [ "$TARGET_TYPE" = "FINGERPRINT" ]; then
        log_msg "SEEN  MAC=${DETECTED_MAC}  RSSI=${RSSI}dBm  score=${DETECTED_SCORE}/8"
    else
        log_msg "SEEN  ${TARGET_MAC}  RSSI=${RSSI}dBm  thresh=${RSSI_THRESHOLD}dBm"
    fi

    if [ "$RSSI" -ge "$RSSI_THRESHOLD" ]; then
        if [ "$ARMED" = "1" ]; then
            ELAPSED=$((NOW - LAST_ALERT))
            if [ "$LAST_ALERT" = "0" ] || [ "$ELAPSED" -ge "$ALERT_COOLDOWN" ]; then
                fire_alert "$RSSI" "$DETECTED_MAC" "$DETECTED_SCORE"
                LAST_ALERT="$NOW"
                ARMED=0
            else
                log_msg "IN RANGE — cooldown ${ELAPSED}s/${ALERT_COOLDOWN}s"
                led_set red solid
            fi
        else
            led_set red solid
            log_msg "IN RANGE — holding."
        fi
    else
        if [ "$ARMED" = "0" ]; then
            REARM_LEVEL=$((RSSI_THRESHOLD - RSSI_HYSTERESIS))
            if [ "$RSSI" -lt "$REARM_LEVEL" ]; then
                log_msg "Left range (${RSSI}dBm). Re-armed."
                ARMED=1
                led_set yellow blink
            else
                log_msg "Hysteresis band. Disarmed."
                led_set red solid
            fi
        else
            led_set yellow blink
        fi
    fi

    [ "$TARGET_TYPE" = "AP" ] && sleep "$SCAN_INTERVAL"

done
