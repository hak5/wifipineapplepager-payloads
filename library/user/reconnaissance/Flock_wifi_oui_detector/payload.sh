#!/bin/bash
#
# Title: Flock Detector
# Version: 3.0.2
# Author: Liminal
# Category: Reconnaissance
# Description:
#   Passive WiFi reconnaissance payload for detecting configured
#   MAC/OUI signatures, ingested natively through the Pineapple
#   Recon engine's own database instead of a second independent
#   tcpdump capture on the same radio.
#
#   CHANGES FROM v2.x:
#     - No longer opens its own tcpdump/FIFO capture. Instead it
#       polls Recon's recon.db (SQLite) on an interval and scores
#       whatever rows have changed since the last poll.
#     - Association/Reassociation frame-subtype scoring has been
#       REMOVED. Recon's `ssid` table only preserves two row
#       types: type=8 ("AP frame" -- beacon and probe-response
#       are not distinguished from each other) and type=4
#       ("client probe request"). There is no native record of
#       association/reassociation/deauth frames in this table,
#       so ASSOCIATION_BONUS from v2.x has no equivalent here.
#     - BEACON_BONUS and PROBE_RESPONSE_BONUS have been merged
#       into a single AP_FRAME_BONUS, for the same reason.
#     - Adds a NativePackets column to both CSV outputs, sourced
#       from Recon's own wifi_device.packets counter -- informational
#       only, not fed into scoring.
#
#   This trades a small amount of frame-type granularity for a
#   much simpler, more robust ingestion path: Recon's own capture
#   and parsing is already battle-tested, so this payload no longer
#   has to scrape tcpdump text with sed/grep to reconstruct it.
#
#   v3.0.1: fixed a MAC-format mismatch in the polling query.
#   recon.db stores mac/bssid as raw 12-char hex with no colons
#   (confirmed on-device); the query now reconstructs standard
#   colon-separated form via a CTE so mac_prefix()/is_self_mac()/
#   is_valid_mac() -- all written assuming colon format -- work
#   as originally designed. Without this fix no signature could
#   ever match, regardless of what Recon captured.
#
#   v3.0.2: row_type_name() now treats any ssid.type value other
#   than 4 (client probe request) as infrastructure/AP evidence,
#   rather than allowlisting only {4,8}. Third-party documentation
#   of this schema references a distinct type=5 for probe-response
#   that was never independently confirmed on this firmware; under
#   the old allowlist those rows would have silently fallen into a
#   zero-bonus, non-repeat-eligible bucket.
#
# LED State Descriptions
# LED Green 1s, success tone - Initialization complete, polling started
# LED OFF                    - Idle / polling in background, no active alert
# LED Red, warning tone      - Confirmed detection (score >= ALERT_THRESHOLD)
#
# Signature file format:
#
#   MAC_PREFIX|SCORE|DESCRIPTION
#
# Example:
#
#   74:4C:A1|50|Lite-On WCBN3510A suspected Flock module
#   70:C9:4E|80|Known Flock Falcon
#
# Required companion file:
#
#   flock_signatures.conf
#

#############################################
# 1. GENERAL CONFIGURATION
#############################################

VERSION="3.0.2"

DEBUG=0

# Only used to pass to PINEAPPLE_SET_BANDS -- Recon itself manages
# the radio, this payload no longer opens the interface directly.

INTERFACE="wlan1mon"

PAYLOAD_DIR="/root/payloads/user/reconnaissance/flock_detector"

SIG_FILE="$PAYLOAD_DIR/flock_signatures.conf"

LOOT_DIR="/root/loot/flock_detector"

LOGFILE="$LOOT_DIR/detections_$(date '+%Y-%m-%d').csv"

STATE_FILE="$LOOT_DIR/device_state.csv"


#############################################
# 2. RECON DATABASE CONFIGURATION
#############################################

# Candidates are tried in order; the first that exists is used.
# On units with an SD card, /root/recon may be a bind mount of
# /mmc/root/recon -- both are tried defensively.

RECON_DB_CANDIDATES="/mmc/root/recon/recon.db"

# How often to poll recon.db for new/updated rows.

POLL_INTERVAL_SECONDS=3

# If the newest row in wifi_device is older than this many seconds
# at startup, Recon is probably not actively hopping/capturing.
# This is advisory only -- it does not block the payload, since
# an operator may start a Recon scan after this payload launches.

RECON_STALE_THRESHOLD=90

# Bands that the Pager Recon engine should scan.
#
# Expected values depend on firmware support:
#   2
#   5
#   6
#
# This payload will use PINEAPPLE_SET_BANDS
# only when that command is available.

RECON_BANDS="2 5"

USE_PINEAPPLE_SET_BANDS=0


#############################################
# 3. DETECTION CONFIGURATION
#############################################

ALERT_THRESHOLD=50

# Seconds before the same MAC may produce
# another audible/visual alert.

ALERT_COOLDOWN=120

# Score bonuses applied later by the scoring engine.

SSID_FLOCK_BONUS=30

# Replaces v2.x BEACON_BONUS + PROBE_RESPONSE_BONUS: Recon's
# ssid table does not distinguish beacons from probe responses,
# both surface as type=8. Both were 10 previously, so this
# preserves the same effective score for that evidence.

AP_FRAME_BONUS=10

PROBE_REQUEST_BONUS=0

RSSI_NEAR_THRESHOLD=-65

RSSI_NEAR_BONUS=5

RSSI_STRONG_THRESHOLD=-50

RSSI_STRONG_BONUS=15


#############################################
# 4. GPS CONFIGURATION
#############################################

GPS_ENABLED=1

GPS_DEVICE="/dev/ttyUSB0"

GPS_BAUD=9600

GPS_SOCKET="/var/run/gpsd.sock"

GPS_CACHE="/tmp/flock_detector_gps.json"

# 1:
#   When GPS_DEVICE exists, restart gpsd using
#   the serial device and socket configuration.
#
# 0:
#   Leave the Pager's existing gpsd process alone
#   and connect gpspipe to it.

RESTART_GPSD=1


#############################################
# 5. RUNTIME FILES
#############################################

RUNTIME_DIR="/tmp/flock_detector"

RECON_DB_SNAPSHOT="$RUNTIME_DIR/recon_snapshot.db"

ALERT_STATE_DIR="$RUNTIME_DIR/alerts"

GPS_PID_FILE="$RUNTIME_DIR/gpspipe.pid"

POLL_ERROR_LOG="$LOOT_DIR/recon_poll_$(date '+%Y-%m-%d_%H-%M-%S').log"


#############################################
# 6. RUNTIME PROCESS VARIABLES
#############################################

GPS_PID=""

CLEANED_UP=0

SHUTDOWN_REQUESTED=0

LAST_POLL_EPOCH=0

NEXT_POLL_EPOCH=0


#############################################
# 7. PAGER SELF-IDENTITIES
#############################################

# These are ignored so that the Pager does not
# detect its own wireless management traffic,
# replace with your own.

SELF_MACS="
00:13:37:00:00:00
00:13:37:00:00:01
"


#############################################
# 8. BASIC HELPERS
#############################################

debug_log()
{
    [ "$DEBUG" -eq 1 ] || return 0

    LOG gray "DEBUG: $*"
}


normalize_mac()
{
    printf '%s\n' "$1" |
        tr '[:lower:]' '[:upper:]'
}


mac_prefix()
{
    normalize_mac "$1" |
        cut -c1-8
}


is_self_mac()
{
    local candidate

    candidate="$(normalize_mac "$1")"

    printf '%s\n' "$SELF_MACS" |
        grep -Fqx "$candidate"
}


is_positive_integer()
{
    case "$1" in
        ''|*[!0-9]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}


#############################################
# 9. RUNTIME INITIALIZATION
#############################################

initialize_runtime()
{
    mkdir -p "$LOOT_DIR" "$RUNTIME_DIR" "$ALERT_STATE_DIR"

    rm -f "$RECON_DB_SNAPSHOT"
    rm -f "$GPS_CACHE"
    rm -f "$GPS_PID_FILE"

    if [ ! -f "$LOGFILE" ]; then
        printf '%s\n' \
            'Timestamp,FrameType,MAC,BSSID,SSID,RSSI,Frequency,Channel,Score,Latitude,Longitude,Description,NativePackets' \
            > "$LOGFILE"
    fi

    if [ ! -f "$STATE_FILE" ]; then
        printf '%s\n' \
            'MAC,FirstSeen,LastSeen,PacketCount,BestRSSI,LastSSID,Description' \
            > "$STATE_FILE"
    fi

    return 0
}


#############################################
# 10. GPSD INITIALIZATION
#############################################

initialize_gpsd()
{
    [ "$GPS_ENABLED" -eq 1 ] || {
        LOG gray "GPS disabled"
        return 0
    }

    if [ "$RESTART_GPSD" -eq 1 ] &&
       [ -e "$GPS_DEVICE" ]; then

        LOG cyan "SYNCING GPSD..."

        killall gpsd 2>/dev/null

        if ! stty -F "$GPS_DEVICE" "$GPS_BAUD" 2>/dev/null; then
            LOG yellow "Unable to set GPS baud"
        fi

        gpsd "$GPS_DEVICE" -F "$GPS_SOCKET" 2>/dev/null

        sleep 2
    fi

    if ! pidof gpsd >/dev/null 2>&1; then
        LOG yellow "gpsd is not running"
        return 1
    fi

    return 0
}


#############################################
# 11. GPS CACHE PROCESS
#############################################

start_gps_cache()
{
    [ "$GPS_ENABLED" -eq 1 ] || return 0

    if ! command -v gpspipe >/dev/null 2>&1; then
        LOG yellow "gpspipe is unavailable"
        return 1
    fi

    if ! pidof gpsd >/dev/null 2>&1; then
        LOG yellow "GPS cache not started"
        return 1
    fi

    LOG cyan "Starting GPS cache"

    gpspipe -w > "$GPS_CACHE" 2>/dev/null &

    GPS_PID=$!

    printf '%s\n' "$GPS_PID" > "$GPS_PID_FILE"

    debug_log "gpspipe PID=$GPS_PID"

    return 0
}


#############################################
# 12. GPS FIX RETRIEVAL
#############################################

get_gps_fix()
{
    local tpv
    local latitude
    local longitude

    latitude="0.000000"
    longitude="0.000000"

    if [ -s "$GPS_CACHE" ]; then
        tpv="$(
            grep '"class":"TPV"' "$GPS_CACHE" 2>/dev/null |
                tail -n 1
        )"

        latitude="$(
            printf '%s\n' "$tpv" |
                sed -n \
                    's/.*"lat":\([-0-9.]*\).*/\1/p'
        )"

        longitude="$(
            printf '%s\n' "$tpv" |
                sed -n \
                    's/.*"lon":\([-0-9.]*\).*/\1/p'
        )"
    fi

    [ -n "$latitude" ] || latitude="0.000000"
    [ -n "$longitude" ] || longitude="0.000000"

    printf '%s,%s\n' "$latitude" "$longitude"
}


#############################################
# 13. OWNED-PROCESS TERMINATION
#############################################

stop_owned_process()
{
    local pid="$1"
    local name="$2"

    [ -n "$pid" ] || return 0

    case "$pid" in
        *[!0-9]*)
            debug_log "Invalid $name PID: $pid"
            return 1
            ;;
    esac

    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    debug_log "Stopping $name PID=$pid"

    kill "$pid" 2>/dev/null

    local attempts=0

    while kill -0 "$pid" 2>/dev/null &&
          [ "$attempts" -lt 10 ]; do

        sleep 0.1

        attempts=$((attempts + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        debug_log "$name did not stop cleanly"

        kill -9 "$pid" 2>/dev/null
    fi
}


#############################################
# 14. CLEANUP
#############################################

cleanup()
{
    local exit_status=$?

    [ "$CLEANED_UP" -eq 0 ] || return "$exit_status"

    CLEANED_UP=1

    SHUTDOWN_REQUESTED=1

    LOG yellow "Stopping Flock Detector"

    stop_owned_process "$GPS_PID" "gpspipe"

    if declare -F persist_device_state >/dev/null 2>&1; then
        persist_device_state >/dev/null 2>&1
    fi

    rm -f "$GPS_PID_FILE"
    rm -f "$GPS_CACHE"
    rm -f "$RECON_DB_SNAPSHOT"

    if [ -d "$ALERT_STATE_DIR" ]; then
        rm -f "$ALERT_STATE_DIR"/* 2>/dev/null
    fi

    LED OFF 2>/dev/null

    LOG gray "Flock Detector stopped"

    return "$exit_status"
}


#############################################
# 15. SIGNAL HANDLING
#############################################

request_shutdown()
{
    SHUTDOWN_REQUESTED=1
}

trap 'request_shutdown; exit 130' INT

trap 'request_shutdown; exit 143' TERM

trap 'request_shutdown; exit 129' HUP

trap cleanup EXIT


#############################################
# 16. SIGNATURE CACHE
#############################################

declare -A SIG_SCORES

declare -A SIG_DESCRIPTIONS

SIG_CACHE_READY=0

SIG_VALID_COUNT=0

SIG_INVALID_COUNT=0

SIG_DUPLICATE_COUNT=0


#############################################
# 17. STRING HANDLING
#############################################

trim_whitespace()
{
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"

    value="${value%"${value##*[![:space:]]}"}"

    printf '%s\n' "$value"
}


strip_carriage_return()
{
    printf '%s\n' "$1" |
        tr -d '\r'
}


#############################################
# 18. SIGNATURE FIELD VALIDATION
#############################################

is_valid_mac_prefix()
{
    local prefix="$1"

    printf '%s\n' "$prefix" |
        grep -Eq \
            '^[[:xdigit:]]{2}:[[:xdigit:]]{2}:[[:xdigit:]]{2}$'
}


is_valid_signature_score()
{
    local score="$1"

    is_positive_integer "$score" || return 1

    [ "$score" -ge 0 ] &&
        [ "$score" -le 100 ]
}


#############################################
# 19. CLEAR SIGNATURE CACHE
#############################################

clear_signature_cache()
{
    unset SIG_SCORES
    unset SIG_DESCRIPTIONS

    declare -gA SIG_SCORES
    declare -gA SIG_DESCRIPTIONS

    SIG_CACHE_READY=0

    SIG_VALID_COUNT=0

    SIG_INVALID_COUNT=0

    SIG_DUPLICATE_COUNT=0
}


#############################################
# 20. ADD SIGNATURE TO CACHE
#############################################

cache_signature()
{
    local prefix="$1"
    local score="$2"
    local description="$3"

    local existing_score

    if [ "${SIG_SCORES[$prefix]+exists}" = "exists" ]; then

        SIG_DUPLICATE_COUNT=$((SIG_DUPLICATE_COUNT + 1))

        existing_score="${SIG_SCORES[$prefix]}"

        if [ "$score" -gt "$existing_score" ]; then

            debug_log \
                "Duplicate $prefix: replacing score $existing_score with $score"

            SIG_SCORES["$prefix"]="$score"

            SIG_DESCRIPTIONS["$prefix"]="$description"

        else

            debug_log \
                "Duplicate $prefix ignored; cached score $existing_score is equal or higher"

        fi

        return 0
    fi

    SIG_SCORES["$prefix"]="$score"

    SIG_DESCRIPTIONS["$prefix"]="$description"

    SIG_VALID_COUNT=$((SIG_VALID_COUNT + 1))

    return 0
}


#############################################
# 21. LOAD SIGNATURE FILE
#############################################

load_signature_cache()
{
    local line_number=0

    local raw_prefix
    local raw_score
    local raw_description
    local extra_field

    local prefix
    local score
    local description

    clear_signature_cache

    if [ ! -f "$SIG_FILE" ]; then

        LOG red "Signature file not found"

        LOG yellow "$SIG_FILE"

        return 1
    fi

    if [ ! -r "$SIG_FILE" ]; then

        LOG red "Signature file is not readable"

        LOG yellow "$SIG_FILE"

        return 1
    fi

    LOG cyan "Loading signatures"

    while IFS='|' read -r \
        raw_prefix \
        raw_score \
        raw_description \
        extra_field ||
        [ -n "$raw_prefix$raw_score$raw_description$extra_field" ]; do

        line_number=$((line_number + 1))

        raw_prefix="$(strip_carriage_return "$raw_prefix")"

        raw_score="$(strip_carriage_return "$raw_score")"

        raw_description="$(
            strip_carriage_return "$raw_description"
        )"

        extra_field="$(strip_carriage_return "$extra_field")"

        prefix="$(trim_whitespace "$raw_prefix")"

        score="$(trim_whitespace "$raw_score")"

        description="$(trim_whitespace "$raw_description")"

        extra_field="$(trim_whitespace "$extra_field")"

        case "$prefix" in
            ''|\#*)
                continue
                ;;
        esac

        if [ -n "$extra_field" ]; then

            SIG_INVALID_COUNT=$((SIG_INVALID_COUNT + 1))

            LOG yellow \
                "Invalid signature line $line_number: too many fields"

            continue
        fi

        prefix="$(normalize_mac "$prefix")"

        if ! is_valid_mac_prefix "$prefix"; then

            SIG_INVALID_COUNT=$((SIG_INVALID_COUNT + 1))

            LOG yellow \
                "Invalid MAC prefix on line $line_number"

            continue
        fi

        if ! is_valid_signature_score "$score"; then

            SIG_INVALID_COUNT=$((SIG_INVALID_COUNT + 1))

            LOG yellow \
                "Invalid score on line $line_number"

            continue
        fi

        if [ -z "$description" ]; then

            SIG_INVALID_COUNT=$((SIG_INVALID_COUNT + 1))

            LOG yellow \
                "Missing description on line $line_number"

            continue
        fi

        cache_signature \
            "$prefix" \
            "$score" \
            "$description"

    done < "$SIG_FILE"

    if [ "$SIG_VALID_COUNT" -eq 0 ]; then

        LOG red "No valid signatures loaded"

        return 1
    fi

    SIG_CACHE_READY=1

    LOG green "Signatures loaded: $SIG_VALID_COUNT"

    if [ "$SIG_DUPLICATE_COUNT" -gt 0 ]; then

        LOG yellow \
            "Duplicate rows: $SIG_DUPLICATE_COUNT"

    fi

    if [ "$SIG_INVALID_COUNT" -gt 0 ]; then

        LOG yellow \
            "Invalid rows skipped: $SIG_INVALID_COUNT"

    fi

    return 0
}


#############################################
# 22. LOOK UP A MAC SIGNATURE
#############################################

lookup_signature()
{
    local mac="$1"

    local prefix
    local score
    local description

    prefix="$(mac_prefix "$mac")"

    score=0

    description=""

    if [ "$SIG_CACHE_READY" -eq 1 ] &&
       [ "${SIG_SCORES[$prefix]+exists}" = "exists" ]; then

        score="${SIG_SCORES[$prefix]}"

        description="${SIG_DESCRIPTIONS[$prefix]}"
    fi

    printf '%s|%s\n' \
        "$score" \
        "$description"
}


#############################################
# 23. COMPLETE MAC VALIDATION
#############################################

is_valid_mac()
{
    local mac="$1"

    printf '%s\n' "$mac" |
        grep -Eq \
            '^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$'
}


#############################################
# 24. UNSAFE DEVICE ADDRESS CHECK
#############################################

is_usable_device_mac()
{
    local mac="$1"

    is_valid_mac "$mac" || return 1

    case "$mac" in
        FF:FF:FF:FF:FF:FF)
            return 1
            ;;

        00:00:00:00:00:00)
            return 1
            ;;
    esac

    return 0
}


#############################################
# 25. SCORING AND TRACKING DEFAULTS
#############################################

: "${MAX_SCORE:=100}"

: "${REPEAT_SEEN_THRESHOLD:=3}"

: "${REPEAT_SEEN_BONUS:=15}"

: "${STATE_FLUSH_INTERVAL:=15}"


#############################################
# 26. IN-MEMORY DEVICE STATE
#############################################

declare -A DEVICE_FIRST_SEEN

declare -A DEVICE_LAST_SEEN

declare -A DEVICE_PACKET_COUNT

declare -A DEVICE_BEST_RSSI

declare -A DEVICE_LAST_SSID

declare -A DEVICE_DESCRIPTION


LAST_STATE_FLUSH=0

CURRENT_OBSERVATION_COUNT=0

CURRENT_BEST_RSSI=-99


#############################################
# 27. FRAME SCORE BONUS
#############################################

# Replaces v2.x frame_score_bonus(). Recon's ssid table only
# survives two row types -- see header comment for why
# association/reassociation bonuses have no equivalent here.

row_type_bonus()
{
    local row_type="$1"

    case "$row_type" in
        AP_FRAME)
            printf '%s\n' "$AP_FRAME_BONUS"
            ;;

        PROBE_REQUEST)
            printf '%s\n' "$PROBE_REQUEST_BONUS"
            ;;

        *)
            printf '%s\n' "0"
            ;;
    esac
}


#############################################
# 28. INFRASTRUCTURE-ROW CHECK
#############################################

is_infrastructure_row()
{
    [ "$1" = "AP_FRAME" ]
}


#############################################
# 29. SSID SIGNATURE BONUS
#############################################

ssid_contains_flock()
{
    local ssid="$1"

    [ -n "$ssid" ] || return 1

    printf '%s\n' "$ssid" |
        grep -Fqi "FLOCK"
}


ssid_score_bonus()
{
    local ssid="$1"

    if ssid_contains_flock "$ssid"; then
        printf '%s\n' "$SSID_FLOCK_BONUS"
    else
        printf '%s\n' "0"
    fi
}


#############################################
# 30. RSSI SCORE BONUS
#############################################

rssi_score_bonus()
{
    local rssi="$1"

    case "$rssi" in
        ''|'-'|*[!0-9-]*)
            printf '%s\n' "0"
            return 0
            ;;
    esac

    if [ "$rssi" -ge "$RSSI_STRONG_THRESHOLD" ]; then

        printf '%s\n' "$RSSI_STRONG_BONUS"

    elif [ "$rssi" -ge "$RSSI_NEAR_THRESHOLD" ]; then

        printf '%s\n' "$RSSI_NEAR_BONUS"

    else

        printf '%s\n' "0"
    fi
}


#############################################
# 31. REPEAT-OBSERVATION BONUS
#############################################

# NOTE: this is now counted in poll cycles, not raw captured
# frames. At the default 5s POLL_INTERVAL_SECONDS,
# REPEAT_SEEN_THRESHOLD=3 means "still present after ~15s of
# polling", which is a reasonable sustained-sighting signal.
# If you change POLL_INTERVAL_SECONDS significantly, revisit
# this threshold.

repeat_score_bonus()
{
    local row_type="$1"
    local observation_count="$2"

    if ! is_infrastructure_row "$row_type"; then
        printf '%s\n' "0"
        return 0
    fi

    if [ "$observation_count" -ge "$REPEAT_SEEN_THRESHOLD" ]; then
        printf '%s\n' "$REPEAT_SEEN_BONUS"
    else
        printf '%s\n' "0"
    fi
}


#############################################
# 32. RECORD AN OBSERVATION
#############################################

record_observation()
{
    local mac="$1"
    local rssi="$2"
    local ssid="$3"
    local description="$4"

    local now
    local count
    local best_rssi

    now="$(date '+%Y-%m-%d %H:%M:%S')"

    if [ "${DEVICE_FIRST_SEEN[$mac]+exists}" != "exists" ]; then

        DEVICE_FIRST_SEEN["$mac"]="$now"

        DEVICE_PACKET_COUNT["$mac"]=0

        DEVICE_BEST_RSSI["$mac"]="$rssi"
    fi

    DEVICE_LAST_SEEN["$mac"]="$now"

    count="${DEVICE_PACKET_COUNT[$mac]:-0}"

    count=$((count + 1))

    DEVICE_PACKET_COUNT["$mac"]="$count"

    best_rssi="${DEVICE_BEST_RSSI[$mac]:--99}"

    if [ "$rssi" -gt "$best_rssi" ]; then
        best_rssi="$rssi"
    fi

    DEVICE_BEST_RSSI["$mac"]="$best_rssi"

    if [ -n "$ssid" ]; then
        DEVICE_LAST_SSID["$mac"]="$ssid"
    elif [ "${DEVICE_LAST_SSID[$mac]+exists}" != "exists" ]; then
        DEVICE_LAST_SSID["$mac"]=""
    fi

    if [ -n "$description" ]; then
        DEVICE_DESCRIPTION["$mac"]="$description"
    elif [ "${DEVICE_DESCRIPTION[$mac]+exists}" != "exists" ]; then
        DEVICE_DESCRIPTION["$mac"]=""
    fi

    CURRENT_OBSERVATION_COUNT="$count"

    CURRENT_BEST_RSSI="$best_rssi"
}


#############################################
# 33. STATE FIELD SANITIZATION
#############################################

sanitize_state_field()
{
    local value="$1"

    printf '%s\n' "$value" |
        tr '\r\n,' '   '
}


#############################################
# 34. SAVE DEVICE STATE
#############################################

persist_device_state()
{
    local temporary_file

    local mac
    local first_seen
    local last_seen
    local packet_count
    local best_rssi
    local last_ssid
    local description

    temporary_file="${STATE_FILE}.tmp.$$"

    printf '%s\n' \
        'MAC,FirstSeen,LastSeen,PacketCount,BestRSSI,LastSSID,Description' \
        > "$temporary_file" ||
        return 1

    for mac in "${!DEVICE_FIRST_SEEN[@]}"; do

        first_seen="$(
            sanitize_state_field \
                "${DEVICE_FIRST_SEEN[$mac]}"
        )"

        last_seen="$(
            sanitize_state_field \
                "${DEVICE_LAST_SEEN[$mac]}"
        )"

        packet_count="${DEVICE_PACKET_COUNT[$mac]:-0}"

        best_rssi="${DEVICE_BEST_RSSI[$mac]:--99}"

        last_ssid="$(
            sanitize_state_field \
                "${DEVICE_LAST_SSID[$mac]}"
        )"

        description="$(
            sanitize_state_field \
                "${DEVICE_DESCRIPTION[$mac]}"
        )"

        printf '%s,%s,%s,%s,%s,%s,%s\n' \
            "$mac" \
            "$first_seen" \
            "$last_seen" \
            "$packet_count" \
            "$best_rssi" \
            "$last_ssid" \
            "$description" \
            >> "$temporary_file"

    done

    if mv "$temporary_file" "$STATE_FILE"; then

        LAST_STATE_FLUSH="$(date +%s)"

        debug_log "Device state saved"

        return 0
    fi

    rm -f "$temporary_file"

    return 1
}


#############################################
# 35. PERIODIC STATE SAVE
#############################################

maybe_persist_device_state()
{
    local now

    now="$(date +%s)"

    if [ "$LAST_STATE_FLUSH" -eq 0 ] ||
       [ $((now - LAST_STATE_FLUSH)) -ge "$STATE_FLUSH_INTERVAL" ]; then

        persist_device_state
    fi
}


#############################################
# 36. RESTORE DEVICE STATE
#############################################

load_device_state()
{
    local line_number=0

    local mac
    local first_seen
    local last_seen
    local packet_count
    local best_rssi
    local last_ssid
    local description

    [ -f "$STATE_FILE" ] || return 0

    while IFS=',' read -r \
        mac \
        first_seen \
        last_seen \
        packet_count \
        best_rssi \
        last_ssid \
        description; do

        line_number=$((line_number + 1))

        if [ "$line_number" -eq 1 ]; then
            continue
        fi

        mac="$(normalize_mac "$mac")"

        is_usable_device_mac "$mac" || continue

        is_positive_integer "$packet_count" ||
            packet_count=0

        case "$best_rssi" in
            ''|'-'|*[!0-9-]*)
                best_rssi=-99
                ;;
        esac

        DEVICE_FIRST_SEEN["$mac"]="$first_seen"

        DEVICE_LAST_SEEN["$mac"]="$last_seen"

        DEVICE_PACKET_COUNT["$mac"]="$packet_count"

        DEVICE_BEST_RSSI["$mac"]="$best_rssi"

        DEVICE_LAST_SSID["$mac"]="$last_ssid"

        DEVICE_DESCRIPTION["$mac"]="$description"

    done < "$STATE_FILE"

    LAST_STATE_FLUSH="$(date +%s)"

    debug_log \
        "Restored ${#DEVICE_FIRST_SEEN[@]} tracked devices"
}


#############################################
# 37. SCORE REASON BUILDER
#############################################

append_score_reason()
{
    local current="$1"
    local addition="$2"

    if [ -z "$addition" ]; then
        printf '%s\n' "$current"
    elif [ -z "$current" ]; then
        printf '%s\n' "$addition"
    else
        printf '%s; %s\n' \
            "$current" \
            "$addition"
    fi
}


#############################################
# 38. PACKET SCORING ENTRY POINT
#############################################

process_packet()
{
    local row_type="$1"
    local device_mac="$2"
    local bssid="$3"
    local ssid="$4"
    local rssi="$5"
    local frequency="$6"
    local channel="$7"
    local native_packets="$8"

    local signature
    local base_score
    local description

    local frame_bonus
    local ssid_bonus
    local rssi_bonus
    local repeat_bonus

    local final_score
    local score_reasons

    is_usable_device_mac "$device_mac" || return 0

    signature="$(lookup_signature "$device_mac")"

    base_score="${signature%%|*}"

    description="${signature#*|}"

    case "$base_score" in
        ''|*[!0-9]*)
            base_score=0
            ;;
    esac

    ssid_bonus="$(ssid_score_bonus "$ssid")"

    if [ "$base_score" -eq 0 ] &&
       [ "$ssid_bonus" -eq 0 ]; then

        return 0
    fi

    record_observation \
        "$device_mac" \
        "$rssi" \
        "$ssid" \
        "$description"

    frame_bonus="$(row_type_bonus "$row_type")"

    rssi_bonus="$(rssi_score_bonus "$rssi")"

    repeat_bonus="$(
        repeat_score_bonus \
            "$row_type" \
            "$CURRENT_OBSERVATION_COUNT"
    )"

    final_score=$(( \
        base_score + \
        frame_bonus + \
        ssid_bonus + \
        rssi_bonus + \
        repeat_bonus \
    ))

    if [ "$final_score" -gt "$MAX_SCORE" ]; then
        final_score="$MAX_SCORE"
    fi

    score_reasons=""

    if [ "$base_score" -gt 0 ]; then

        score_reasons="$(
            append_score_reason \
                "$score_reasons" \
                "OUI +$base_score"
        )"
    fi

    if [ "$frame_bonus" -gt 0 ]; then

        score_reasons="$(
            append_score_reason \
                "$score_reasons" \
                "$row_type +$frame_bonus"
        )"
    fi

    if [ "$ssid_bonus" -gt 0 ]; then

        score_reasons="$(
            append_score_reason \
                "$score_reasons" \
                "SSID +$ssid_bonus"
        )"
    fi

    if [ "$rssi_bonus" -gt 0 ]; then

        score_reasons="$(
            append_score_reason \
                "$score_reasons" \
                "RSSI +$rssi_bonus"
        )"
    fi

    if [ "$repeat_bonus" -gt 0 ]; then

        score_reasons="$(
            append_score_reason \
                "$score_reasons" \
                "repeat +$repeat_bonus"
        )"
    fi

    debug_log \
        "Candidate $device_mac score=$final_score count=$CURRENT_OBSERVATION_COUNT"

    maybe_persist_device_state

    handle_scored_packet \
        "$row_type" \
        "$device_mac" \
        "$bssid" \
        "$ssid" \
        "$rssi" \
        "$frequency" \
        "$channel" \
        "$final_score" \
        "$description" \
        "$score_reasons" \
        "$CURRENT_OBSERVATION_COUNT" \
        "$CURRENT_BEST_RSSI" \
        "$native_packets"
}


#############################################
# 39. EVENT AND ALERT DEFAULTS
#############################################

: "${ENABLE_CANDIDATE_LOG:=1}"

: "${CANDIDATE_LOG_INTERVAL:=60}"

: "${DETECTION_LOG_INTERVAL:=30}"

: "${ALERT_LED_DURATION:=1}"

: "${SYNC_ON_DETECTION:=1}"


CANDIDATE_LOG="$LOOT_DIR/candidates_$(date '+%Y-%m-%d').csv"


#############################################
# 40. PER-DEVICE EVENT TIMERS
#############################################

declare -A DEVICE_LAST_ALERT_EPOCH

declare -A DEVICE_LAST_DETECTION_LOG_EPOCH

declare -A DEVICE_LAST_CANDIDATE_LOG_EPOCH


#############################################
# 41. CANDIDATE LOG INITIALIZATION
#############################################

initialize_candidate_log()
{
    [ "$ENABLE_CANDIDATE_LOG" -eq 1 ] || return 0

    if [ ! -f "$CANDIDATE_LOG" ]; then

        printf '%s\n' \
            'Timestamp,FrameType,MAC,BSSID,SSID,RSSI,Frequency,Channel,Score,Threshold,Observations,BestRSSI,Latitude,Longitude,Description,Reasons,NativePackets' \
            > "$CANDIDATE_LOG"
    fi
}


#############################################
# 42. CSV FIELD ESCAPING
#############################################

csv_escape()
{
    local value="$1"

    printf '%s' "$value" |
        tr '\r\n' '  ' |
        sed 's/"/""/g'
}


#############################################
# 43. GENERIC INTERVAL CHECK
#############################################

interval_is_due()
{
    local last_epoch="$1"
    local interval="$2"
    local current_epoch="$3"

    case "$last_epoch" in
        ''|*[!0-9]*)
            last_epoch=0
            ;;
    esac

    case "$interval" in
        ''|*[!0-9]*)
            interval=0
            ;;
    esac

    case "$current_epoch" in
        ''|*[!0-9]*)
            current_epoch="$(date +%s)"
            ;;
    esac

    [ $((current_epoch - last_epoch)) -ge "$interval" ]
}


#############################################
# 44. PER-DEVICE ALERT CHECK
#############################################

device_alert_is_due()
{
    local mac="$1"
    local current_epoch="$2"

    local last_epoch

    last_epoch="${DEVICE_LAST_ALERT_EPOCH[$mac]:-0}"

    interval_is_due \
        "$last_epoch" \
        "$ALERT_COOLDOWN" \
        "$current_epoch"
}


mark_device_alerted()
{
    local mac="$1"
    local current_epoch="$2"

    DEVICE_LAST_ALERT_EPOCH["$mac"]="$current_epoch"
}


#############################################
# 45. DETECTION-LOG INTERVAL CHECK
#############################################

detection_log_is_due()
{
    local mac="$1"
    local current_epoch="$2"

    local last_epoch

    last_epoch="${DEVICE_LAST_DETECTION_LOG_EPOCH[$mac]:-0}"

    interval_is_due \
        "$last_epoch" \
        "$DETECTION_LOG_INTERVAL" \
        "$current_epoch"
}


mark_detection_logged()
{
    local mac="$1"
    local current_epoch="$2"

    DEVICE_LAST_DETECTION_LOG_EPOCH["$mac"]="$current_epoch"
}


#############################################
# 46. CANDIDATE-LOG INTERVAL CHECK
#############################################

candidate_log_is_due()
{
    local mac="$1"
    local current_epoch="$2"

    local last_epoch

    last_epoch="${DEVICE_LAST_CANDIDATE_LOG_EPOCH[$mac]:-0}"

    interval_is_due \
        "$last_epoch" \
        "$CANDIDATE_LOG_INTERVAL" \
        "$current_epoch"
}


mark_candidate_logged()
{
    local mac="$1"
    local current_epoch="$2"

    DEVICE_LAST_CANDIDATE_LOG_EPOCH["$mac"]="$current_epoch"
}


#############################################
# 47. SCORE CLASSIFICATION
#############################################

classify_score()
{
    local score="$1"

    if [ "$score" -ge 95 ]; then

        printf '%s\n' "HIGH CONFIDENCE"

    elif [ "$score" -ge "$ALERT_THRESHOLD" ]; then

        printf '%s\n' "LIKELY"

    else

        printf '%s\n' "CANDIDATE"

    fi
}


#############################################
# 48. GPS VALUE SPLITTING
#############################################

split_gps_fix()
{
    local fix="$1"

    EVENT_LATITUDE="${fix%%,*}"

    EVENT_LONGITUDE="${fix#*,}"

    [ -n "$EVENT_LATITUDE" ] ||
        EVENT_LATITUDE="0.000000"

    [ -n "$EVENT_LONGITUDE" ] ||
        EVENT_LONGITUDE="0.000000"
}


#############################################
# 49. WRITE CANDIDATE EVENT
#############################################

write_candidate_event()
{
    local timestamp="$1"
    local frame_type="$2"
    local mac="$3"
    local bssid="$4"
    local ssid="$5"
    local rssi="$6"
    local frequency="$7"
    local channel="$8"
    local score="$9"

    shift 9

    local description="$1"
    local score_reasons="$2"
    local observation_count="$3"
    local best_rssi="$4"
    local latitude="$5"
    local longitude="$6"
    local native_packets="$7"

    local escaped_timestamp
    local escaped_frame_type
    local escaped_mac
    local escaped_bssid
    local escaped_ssid
    local escaped_description
    local escaped_reasons

    [ "$ENABLE_CANDIDATE_LOG" -eq 1 ] || return 0

    escaped_timestamp="$(csv_escape "$timestamp")"

    escaped_frame_type="$(csv_escape "$frame_type")"

    escaped_mac="$(csv_escape "$mac")"

    escaped_bssid="$(csv_escape "$bssid")"

    escaped_ssid="$(csv_escape "$ssid")"

    escaped_description="$(csv_escape "$description")"

    escaped_reasons="$(csv_escape "$score_reasons")"

    printf \
        '"%s","%s","%s","%s","%s",%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s","%s",%s\n' \
        "$escaped_timestamp" \
        "$escaped_frame_type" \
        "$escaped_mac" \
        "$escaped_bssid" \
        "$escaped_ssid" \
        "$rssi" \
        "$frequency" \
        "$channel" \
        "$score" \
        "$ALERT_THRESHOLD" \
        "$observation_count" \
        "$best_rssi" \
        "$latitude" \
        "$longitude" \
        "$escaped_description" \
        "$escaped_reasons" \
        "$native_packets" \
        >> "$CANDIDATE_LOG"
}


#############################################
# 50. WRITE CONFIRMED DETECTION
#############################################

write_detection_event()
{
    local timestamp="$1"
    local frame_type="$2"
    local mac="$3"
    local bssid="$4"
    local ssid="$5"
    local rssi="$6"
    local frequency="$7"
    local channel="$8"
    local score="$9"

    shift 9

    local latitude="$1"
    local longitude="$2"
    local description="$3"
    local score_reasons="$4"
    local native_packets="$5"

    local escaped_timestamp
    local escaped_frame_type
    local escaped_mac
    local escaped_bssid
    local escaped_ssid
    local escaped_description

    escaped_timestamp="$(csv_escape "$timestamp")"

    escaped_frame_type="$(csv_escape "$frame_type")"

    escaped_mac="$(csv_escape "$mac")"

    escaped_bssid="$(csv_escape "$bssid")"

    escaped_ssid="$(csv_escape "$ssid")"

    escaped_description="$(
        csv_escape "$description; $score_reasons"
    )"

    printf \
        '"%s","%s","%s","%s","%s",%s,%s,%s,%s,%s,%s,"%s",%s\n' \
        "$escaped_timestamp" \
        "$escaped_frame_type" \
        "$escaped_mac" \
        "$escaped_bssid" \
        "$escaped_ssid" \
        "$rssi" \
        "$frequency" \
        "$channel" \
        "$score" \
        "$latitude" \
        "$longitude" \
        "$escaped_description" \
        "$native_packets" \
        >> "$LOGFILE"

    if [ "$SYNC_ON_DETECTION" -eq 1 ]; then
        sync
    fi
}


#############################################
# 51. SHORT DISPLAY TEXT
#############################################

shorten_display_text()
{
    local value="$1"
    local maximum="${2:-36}"

    if [ "${#value}" -le "$maximum" ]; then

        printf '%s\n' "$value"

    else

        printf '%s...\n' \
            "${value:0:$((maximum - 3))}"

    fi
}


#############################################
# 52. PAGER OPERATOR ALERT
#############################################

notify_operator()
{
    local classification="$1"
    local frame_type="$2"
    local mac="$3"
    local ssid="$4"
    local rssi="$5"
    local channel="$6"
    local score="$7"
    local latitude="$8"
    local longitude="$9"

    shift 9

    local description="$1"
    local observation_count="$2"
    local best_rssi="$3"
    local native_packets="$4"

    local display_ssid
    local display_description

    display_ssid="$(
        shorten_display_text \
            "${ssid:-Hidden/unknown}" \
            28
    )"

    display_description="$(
        shorten_display_text \
            "$description" \
            38
    )"

    LOG red "============================"

    LOG red "FLOCK $classification"

    LOG white "MAC: $mac"

    LOG cyan "Frame: $frame_type"

    LOG cyan "SSID: $display_ssid"

    LOG yellow "RSSI: ${rssi} dBm"

    LOG yellow "Best: ${best_rssi} dBm"

    LOG yellow "Channel: $channel"

    LOG yellow "Score: $score"

    LOG white "Seen: $observation_count polls"

    LOG white "Native pkts: $native_packets"

    LOG green "GPS: $latitude,$longitude"

    LOG white "$display_description"

    LOG red "============================"

    LED R 255

    RINGTONE warning

    ALERT "FLOCK $classification
MAC: $mac
RSSI: ${rssi}dBm
CH: $channel
SCORE: $score
GPS: $latitude,$longitude"

    sleep "$ALERT_LED_DURATION"

    LED OFF
}


#############################################
# 53. SCORED-PACKET HANDLER
#############################################

handle_scored_packet()
{
    local frame_type="$1"
    local mac="$2"
    local bssid="$3"
    local ssid="$4"
    local rssi="$5"
    local frequency="$6"
    local channel="$7"
    local score="$8"
    local description="$9"

    shift 9

    local score_reasons="$1"
    local observation_count="$2"
    local best_rssi="$3"
    local native_packets="$4"

    local current_epoch
    local timestamp
    local classification

    local candidate_due=0
    local detection_due=0
    local alert_due=0

    local gps_fix

    current_epoch="$(date +%s)"

    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    classification="$(classify_score "$score")"

    if [ "$score" -lt "$ALERT_THRESHOLD" ]; then

        if [ "$ENABLE_CANDIDATE_LOG" -eq 1 ] &&
           candidate_log_is_due \
               "$mac" \
               "$current_epoch"; then

            candidate_due=1
        fi

        if [ "$candidate_due" -eq 0 ]; then
            return 0
        fi

        gps_fix="$(get_gps_fix)"

        split_gps_fix "$gps_fix"

        write_candidate_event \
            "$timestamp" \
            "$frame_type" \
            "$mac" \
            "$bssid" \
            "$ssid" \
            "$rssi" \
            "$frequency" \
            "$channel" \
            "$score" \
            "$description" \
            "$score_reasons" \
            "$observation_count" \
            "$best_rssi" \
            "$EVENT_LATITUDE" \
            "$EVENT_LONGITUDE" \
            "$native_packets"

        mark_candidate_logged \
            "$mac" \
            "$current_epoch"

        debug_log \
            "Candidate logged: $mac score=$score"

        return 0
    fi

    if detection_log_is_due \
        "$mac" \
        "$current_epoch"; then

        detection_due=1
    fi

    if device_alert_is_due \
        "$mac" \
        "$current_epoch"; then

        alert_due=1
    fi

    if [ "$detection_due" -eq 0 ] &&
       [ "$alert_due" -eq 0 ]; then

        return 0
    fi

    gps_fix="$(get_gps_fix)"

    split_gps_fix "$gps_fix"

    if [ "$detection_due" -eq 1 ]; then

        write_detection_event \
            "$timestamp" \
            "$frame_type" \
            "$mac" \
            "$bssid" \
            "$ssid" \
            "$rssi" \
            "$frequency" \
            "$channel" \
            "$score" \
            "$EVENT_LATITUDE" \
            "$EVENT_LONGITUDE" \
            "$description" \
            "$score_reasons" \
            "$native_packets"

        mark_detection_logged \
            "$mac" \
            "$current_epoch"

        debug_log \
            "Detection logged: $mac score=$score"
    fi

    if [ "$alert_due" -eq 1 ]; then

        notify_operator \
            "$classification" \
            "$frame_type" \
            "$mac" \
            "$ssid" \
            "$rssi" \
            "$channel" \
            "$score" \
            "$EVENT_LATITUDE" \
            "$EVENT_LONGITUDE" \
            "$description" \
            "$observation_count" \
            "$best_rssi" \
            "$native_packets"

        mark_device_alerted \
            "$mac" \
            "$current_epoch"
    fi
}


#############################################
# 54. COMMAND VALIDATION
#############################################

require_command()
{
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then

        LOG red "Missing command: $command_name"

        return 1
    fi

    return 0
}


validate_environment()
{
    local failed=0

    require_command sqlite3 || failed=1

    require_command cp || failed=1

    require_command date || failed=1

    require_command grep || failed=1

    require_command sed || failed=1

    require_command awk || failed=1

    if [ "$GPS_ENABLED" -eq 1 ]; then

        if ! command -v gpspipe >/dev/null 2>&1; then

            LOG yellow "gpspipe unavailable"

            LOG yellow "GPS logging disabled"

            GPS_ENABLED=0
        fi
    fi

    if [ "$failed" -ne 0 ]; then

        LOG red "Environment validation failed"

        return 1
    fi

    return 0
}


#############################################
# 55. RECON DATABASE DISCOVERY
#############################################

resolve_recon_db()
{
    local candidate

    for candidate in $RECON_DB_CANDIDATES; do

        if [ -f "$candidate" ]; then

            printf '%s\n' "$candidate"

            return 0
        fi

    done

    return 1
}


#############################################
# 56. RECON ACTIVITY CHECK
#############################################

# Advisory only -- never blocks startup. Recon may be started
# by the operator after this payload launches, and each poll
# cycle re-resolves the database independently.

verify_recon_active()
{
    local db
    local latest_time
    local now
    local age

    db="$(resolve_recon_db)" || {

        LOG red "recon.db not found yet"

        LOG yellow "Start a Recon scan on the Pager"

        return 0
    }

    LOG green "recon.db located"

    LOG gray "$db"

    latest_time="$(
        sqlite3 "$db" \
            "SELECT COALESCE(MAX(time),0) FROM wifi_device;" \
            2>/dev/null
    )"

    case "$latest_time" in
        ''|*[!0-9]*)
            latest_time=0
            ;;
    esac

    now="$(date +%s)"

    age=$((now - latest_time))

    if [ "$latest_time" -eq 0 ] ||
       [ "$age" -gt "$RECON_STALE_THRESHOLD" ]; then

        LOG yellow "Recon data looks stale or empty"

        if command -v PINEAPPLE_HOPPING_START >/dev/null 2>&1; then

            LOG yellow "Attempting PINEAPPLE_HOPPING_START"

            PINEAPPLE_HOPPING_START >/dev/null 2>&1
        fi

        LOG yellow "Start a Recon scan if detections don't appear"

    else

        LOG green "Recon active (${age}s ago)"

    fi

    return 0
}


#############################################
# 57. RECON BAND CONFIGURATION
#############################################

configure_recon_bands()
{
    local result_file
    local result
    local status

    if [ "$USE_PINEAPPLE_SET_BANDS" -ne 1 ]; then

        LOG gray "Using existing Recon bands"

        return 0
    fi

    if ! command -v PINEAPPLE_SET_BANDS >/dev/null 2>&1; then

        LOG yellow "PINEAPPLE_SET_BANDS unavailable"

        LOG yellow "Keeping current channel plan"

        return 0
    fi

    result_file="$RUNTIME_DIR/set_bands.log"

    rm -f "$result_file"

    LOG cyan "Setting Recon bands"

    LOG yellow "$RECON_BANDS"

    # RECON_BANDS intentionally expands into separate arguments.
    # Do not quote $RECON_BANDS here.

    PINEAPPLE_SET_BANDS \
        $INTERFACE \
        $RECON_BANDS \
        > "$result_file" \
        2>&1

    status=$?

    result="$(
        tail -n 3 "$result_file" 2>/dev/null
    )"

    if [ "$status" -ne 0 ]; then

        LOG yellow "Band configuration failed"

        debug_log "$result"

        LOG yellow "Keeping current Recon behavior"

        return 0
    fi

    LOG green "Recon bands configured"

    debug_log "$result"

    return 0
}


#############################################
# 58. ROW TYPE MAPPING
#############################################

# ssid.type integer values, as observed in Recon's schema:
#   4 -> client-originated row (probe request) -- the only
#        value confirmed to represent client, not AP, traffic
#   anything else -> treated as AP-originated evidence
#        (beacon, probe-response, or any other infrastructure
#        row type this schema may use) rather than allowlisting
#        a fixed set of integers and silently zero-scoring
#        anything outside it

row_type_name()
{
    case "$1" in
        4)
            printf '%s\n' "PROBE_REQUEST"
            ;;
        *)
            printf '%s\n' "AP_FRAME"
            ;;
    esac
}


#############################################
# 59. SINGLE-ROW PROCESSOR
#############################################

process_recon_row()
{
    local mac="$1"
    local bssid="$2"
    local ssid="$3"
    local rssi="$4"
    local frequency="$5"
    local channel="$6"
    local type_int="$7"
    local native_packets="$8"

    local row_type

    mac="$(normalize_mac "$mac")"

    bssid="$(normalize_mac "$bssid")"

    is_usable_device_mac "$mac" || return 0

    if is_self_mac "$mac"; then
        return 0
    fi

    row_type="$(row_type_name "$type_int")"

    case "$rssi" in
        ''|*[!0-9-]*)
            rssi="-99"
            ;;
    esac

    case "$frequency" in
        ''|*[!0-9]*)
            frequency="0"
            ;;
    esac

    case "$channel" in
        ''|*[!0-9]*)
            channel="0"
            ;;
    esac

    case "$native_packets" in
        ''|*[!0-9]*)
            native_packets="0"
            ;;
    esac

    if [ "$DEBUG" -eq 1 ]; then
        debug_log \
            "ROW type=$row_type mac=$mac ssid=$ssid rssi=$rssi freq=$frequency ch=$channel pkts=$native_packets"
    fi

    process_packet \
        "$row_type" \
        "$mac" \
        "$bssid" \
        "$ssid" \
        "$rssi" \
        "$frequency" \
        "$channel" \
        "$native_packets"
}


#############################################
# 60. POLL RECON DATABASE
#############################################

poll_recon_db()
{
    local source
    local query
    local row_count=0
    local max_time_seen="$LAST_POLL_EPOCH"

    local row_mac row_ssid row_signal row_freq row_channel
    local row_hidden row_type row_time row_packets row_bssid

    source="$(resolve_recon_db)" || {

        debug_log "recon.db not found this cycle"

        NEXT_POLL_EPOCH="$LAST_POLL_EPOCH"

        return 1
    }

    if ! cp -f "$source" "$RECON_DB_SNAPSHOT" 2>/dev/null; then

        debug_log "Unable to snapshot recon.db"

        NEXT_POLL_EPOCH="$LAST_POLL_EPOCH"

        return 1
    fi

    # recon.db stores mac/bssid as raw 12-character hex with no
    # colons (e.g. B87BD4D7A0B1, not B8:7B:D4:D7:A0:B1). Every
    # downstream consumer in this payload -- mac_prefix(),
    # is_self_mac(), is_valid_mac(), the signature file format --
    # expects standard colon-separated form, so colons are
    # reconstructed here via a CTE rather than touching every
    # caller. Rows with a malformed (non-12-char) mac are dropped
    # at the source instead of producing garbled output.

    query="WITH rows AS (
        SELECT
            w.mac AS raw_mac,
            COALESCE(NULLIF(s.bssid,''), w.mac) AS raw_bssid,
            replace(replace(COALESCE(CAST(s.ssid AS TEXT),''),char(10),' '),char(13),' ') AS ssid_text,
            COALESCE(s.signal,-99) AS signal,
            COALESCE(s.freq,0) AS freq,
            COALESCE(s.channel,0) AS channel,
            COALESCE(s.hidden,0) AS hidden,
            COALESCE(s.type,0) AS type,
            COALESCE(s.time,0) AS time,
            COALESCE(w.packets,0) AS packets
        FROM ssid s
        JOIN wifi_device w ON s.wifi_device = w.hash
        WHERE COALESCE(s.time,0) > $LAST_POLL_EPOCH
    )
    SELECT
        upper(substr(raw_mac,1,2)||':'||substr(raw_mac,3,2)||':'||substr(raw_mac,5,2)||':'||substr(raw_mac,7,2)||':'||substr(raw_mac,9,2)||':'||substr(raw_mac,11,2)),
        ssid_text,
        signal,
        freq,
        channel,
        hidden,
        type,
        time,
        packets,
        upper(substr(raw_bssid,1,2)||':'||substr(raw_bssid,3,2)||':'||substr(raw_bssid,5,2)||':'||substr(raw_bssid,7,2)||':'||substr(raw_bssid,9,2)||':'||substr(raw_bssid,11,2))
    FROM rows
    WHERE length(raw_mac) = 12 AND length(raw_bssid) = 12
    ORDER BY time ASC;"

    while IFS=$'\x1f' read -r \
        row_mac row_ssid row_signal row_freq row_channel \
        row_hidden row_type row_time row_packets row_bssid; do

        [ -n "$row_mac" ] || continue

        row_count=$((row_count + 1))

        case "$row_time" in
            ''|*[!0-9]*)
                row_time=0
                ;;
        esac

        if [ "$row_time" -gt "$max_time_seen" ]; then
            max_time_seen="$row_time"
        fi

        process_recon_row \
            "$row_mac" \
            "$row_bssid" \
            "$row_ssid" \
            "$row_signal" \
            "$row_freq" \
            "$row_channel" \
            "$row_type" \
            "$row_packets"

    done < <(
        sqlite3 -separator $'\x1f' "$RECON_DB_SNAPSHOT" "$query" \
            2>>"$POLL_ERROR_LOG"
    )

    NEXT_POLL_EPOCH="$max_time_seen"

    debug_log "Poll cycle: $row_count row(s) since epoch $LAST_POLL_EPOCH"

    return 0
}


#############################################
# 61. POLL LOOP
#############################################

run_poll_loop()
{
    while [ "$SHUTDOWN_REQUESTED" -eq 0 ]; do

        poll_recon_db

        LAST_POLL_EPOCH="$NEXT_POLL_EPOCH"

        sleep "$POLL_INTERVAL_SECONDS"

    done

    return 0
}


#############################################
# 62. STARTUP DISPLAY
#############################################

display_startup()
{
    LOG cyan "============================"

    LOG cyan "FLOCK DETECTOR v$VERSION"

    LOG cyan "============================"

    LOG white "Poll interval:"

    LOG yellow "${POLL_INTERVAL_SECONDS}s"

    LOG white "Threshold:"

    LOG yellow "$ALERT_THRESHOLD"

    LOG white "Signature file:"

    LOG gray "$SIG_FILE"
}


#############################################
# 63. PROGRAM INITIALIZATION
#############################################

initialize_payload()
{
    display_startup

    if ! validate_environment; then
        return 1
    fi

    if ! initialize_runtime; then
        return 1
    fi

    initialize_candidate_log

    verify_recon_active

    if ! load_signature_cache; then
        return 1
    fi

    load_device_state

    configure_recon_bands

    if [ "$GPS_ENABLED" -eq 1 ]; then

        if initialize_gpsd; then

            start_gps_cache ||
                LOG yellow "GPS cache unavailable"

        else

            LOG yellow "Continuing without GPS fix"
        fi
    fi

    LAST_POLL_EPOCH="$(date +%s)"

    LOG green "Initialization complete"

    return 0
}


#############################################
# 64. MAIN
#############################################

main()
{
    if ! initialize_payload; then

        LOG red "Payload initialization failed"

        return 1
    fi

    RINGTONE success

    LED G 255

    sleep 1

    LED OFF

    LOG green "Polling Recon database"

    run_poll_loop

    return $?
}


main "$@"

exit $?
