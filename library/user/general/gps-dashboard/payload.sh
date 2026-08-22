#!/bin/bash
# Title: GPS Dashboard
# Description: Live-updating GPS status display: connection/fix state, satellites, position, speed/heading, UTC time.
# Author: KJ4M
# Version: 1.0
# Category: general

# Total cycle period per refresh ~= sampling time (bounded by
# SAMPLE_TIMEOUT_SECS, though in practice sample_gpsd finishes well before
# that - see its comment) + BUTTON_WAIT_SECS (the exit-check window used by
# wait_for_exit). Empirically ~1-2s sampling + BUTTON_WAIT_SECS, i.e. a few
# seconds total - measured live against the device, see task report.
BUTTON_WAIT_SECS=2
SAMPLE_TIMEOUT_SECS=3
SAMPLE_LINES=8

GNSS_NAMES=(GPS SBAS Galileo BeiDou IMES QZSS GLONASS)

# Maps a true-north heading in degrees to an 8-point compass letter.
compass_point() {
    local deg="${1%.*}"
    local dirs=(N NE E SE S SW W NW)
    local idx=$(( ((deg % 360 + 360) % 360 + 22) / 45 % 8 ))
    echo "${dirs[$idx]}"
}

# Extracts the fix mode (1=no fix, 2=2D, 3=3D) from the latest TPV report
# in a raw gpspipe -w JSON sample. Defaults to 1 if no TPV report is present.
tpv_mode() {
    local raw="$1"
    local mode
    mode="$(echo "$raw" | grep '"class":"TPV"' | tail -n 1 | jq -r '.mode // 1' 2>/dev/null)"
    echo "${mode:-1}"
}

# Picks a LOG color for a raw sample: red = no data at all, yellow = data
# but no 3D+ fix, green = mode >= 2 (2D or 3D fix).
block_color() {
    local raw="$1"
    if [ -z "$raw" ]; then
        echo "red"
        return
    fi
    local mode
    mode="$(tpv_mode "$raw")"
    if [ "$mode" -ge 2 ] 2>/dev/null; then
        echo "green"
    else
        echo "yellow"
    fi
}

# Groups the satellites in a SKY report by gnssid and formats a one-line
# per-constellation used/seen breakdown, e.g. "Sats: GPS 5/8 used  GLONASS 2/3 used".
format_constellation() {
    local sky="$1"
    if [ -z "$sky" ]; then
        echo "Sats: none"
        return
    fi
    local groups=""
    while read -r gnssid used seen; do
        [ -z "$gnssid" ] && continue
        # gnssid is used as a bash array subscript below, which evaluates it
        # in arithmetic context - a non-numeric value (e.g. from an NMEA-fed
        # source like mobile2gps, which doesn't always carry gnssid) would
        # silently coerce to 0 and get mislabeled "GPS". Guard against that.
        local name
        case "$gnssid" in
            ''|*[!0-9]*) name="GNSS?" ;;
            *) name="${GNSS_NAMES[$gnssid]:-GNSS$gnssid}" ;;
        esac
        groups+="${groups:+  }${name} ${used}/${seen} used"
    done < <(echo "$sky" | jq -r '
        .satellites // [] | group_by(.gnssid) |
        map({gnssid: .[0].gnssid, seen: length, used: (map(select(.used == true)) | length)}) |
        .[] | "\(.gnssid) \(.used) \(.seen)"
    ' 2>/dev/null)
    [ -z "$groups" ] && groups="none"
    echo "Sats: $groups"
}

# Turns one raw gpspipe -w JSON sample into the full multi-line display block.
format_block() {
    local raw="$1"

    if [ -z "$raw" ]; then
        echo "gpsd: DOWN"
        return
    fi

    local devices_json tpv_json sky_json
    devices_json="$(echo "$raw" | grep '"class":"DEVICES"' | tail -n 1)"
    tpv_json="$(echo "$raw" | grep '"class":"TPV"' | tail -n 1)"
    sky_json="$(echo "$raw" | grep '"class":"SKY"' | tail -n 1)"

    local dev_count
    dev_count="$(echo "$devices_json" | jq -r '.devices // [] | length' 2>/dev/null)"
    dev_count="${dev_count:-0}"

    if [ "$dev_count" -eq 0 ] 2>/dev/null; then
        echo "gpsd: UP, no GPS device attached"
        return
    fi

    local mode
    mode="$(tpv_mode "$raw")"

    local fixword="NO FIX"
    [ "$mode" = "2" ] && fixword="2D"
    [ "$mode" = "3" ] && fixword="3D"

    local time_str time_disp="--"
    time_str="$(echo "$tpv_json" | jq -r '.time // empty' 2>/dev/null)"
    if [ -n "$time_str" ]; then
        local date_part clock_part
        date_part="${time_str%%T*}"
        clock_part="${time_str#*T}"
        clock_part="${clock_part%%.*}"
        time_disp="${date_part} ${clock_part} UTC"
    fi

    echo "[$time_disp] FIX: $fixword"

    # Placeholders shared by both the mode<2 (no fix at all) and mode>=2
    # (fix reported but this particular TPV lacks lat/lon/speed/track)
    # cases, so the two branches can't drift out of sync with each other.
    # The mode<2 case is the only one that legitimately means "no fix" -
    # mode>=2 with missing fields just means the latest TPV hasn't caught
    # up yet, so it gets a neutral "pending" wording instead of implying
    # there's no fix when the header above already said otherwise.
    local lat_lon_line="Lat/Lon: -- (no fix)"
    local speed_line="Speed: --  Heading: --"

    if [ "$mode" -ge 2 ] 2>/dev/null; then
        local lat lon speed_ms track
        lat="$(echo "$tpv_json" | jq -r '.lat // empty' 2>/dev/null)"
        lon="$(echo "$tpv_json" | jq -r '.lon // empty' 2>/dev/null)"
        speed_ms="$(echo "$tpv_json" | jq -r '.speed // empty' 2>/dev/null)"
        track="$(echo "$tpv_json" | jq -r '.track // empty' 2>/dev/null)"

        if [ -n "$lat" ] && [ -n "$lon" ]; then
            lat_lon_line="Lat/Lon: $lat, $lon"
        else
            lat_lon_line="Lat/Lon: -- (pending)"
        fi

        if [ -n "$speed_ms" ] && [ -n "$track" ]; then
            local speed_kmh point track_int
            speed_kmh="$(awk -v s="$speed_ms" 'BEGIN { printf "%.1f", s * 3.6 }')"
            point="$(compass_point "$track")"
            track_int="${track%.*}"
            speed_line="Speed: ${speed_kmh} km/h  Heading: ${track_int}° (${point})"
        fi
    fi

    echo "$lat_lon_line"
    echo "$speed_line"

    format_constellation "$sky_json"
}

# Pulls one JSON sample from gpsd. Bounded independently of the button-wait
# below so a slow/silent gpsd can't stall the refresh cadence. SAMPLE_LINES
# is tuned to capture gpsd's initial VERSION/DEVICES/WATCH burst (arrives
# near-instantly) plus at least one full TPV+SKY pair - measured live at
# ~1-2s typically, well under SAMPLE_TIMEOUT_SECS, which exists as a safety
# bound for a slow/stalled connection rather than as the expected runtime.
sample_gpsd() {
    timeout "$SAMPLE_TIMEOUT_SECS" gpspipe -w -n "$SAMPLE_LINES" 2>/dev/null
}

# Blocks until the exit button is pressed or the button-wait window elapses.
# Returns 0 if B was pressed (caller should exit), 1 if the caller should
# refresh and loop again. Distinguishes three outcomes of the `timeout`
# call: rc 0 means WAIT_FOR_BUTTON_PRESS returned before the window elapsed
# (B was pressed); rc 124 is GNU coreutils' timeout exit status for "killed
# the child after the window elapsed" (confirmed live on this device) and
# means a normal timeout, not an error; any other rc means
# WAIT_FOR_BUTTON_PRESS itself failed (missing/broken binary, unexpected
# error) - that case has no external pacing at all, so this floors the loop
# with its own sleep of BUTTON_WAIT_SECS to guarantee it can never spin
# faster than the intended refresh cadence even in a total binary-failure
# scenario. Its own function, not inlined, so tests can override it without
# needing the real WAIT_FOR_BUTTON_PRESS binary or a live Pager session.
#
# NOTE: a B press that lands during the sampling phase (while
# WAIT_FOR_BUTTON_PRESS isn't yet running) may register late or be missed,
# depending on whether the Pager's eventbus queues button events - this
# needs confirming on a real hands-on-device pass with physical buttons.
wait_for_exit() {
    timeout "$BUTTON_WAIT_SECS" WAIT_FOR_BUTTON_PRESS B >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    elif [ "$rc" -eq 124 ]; then
        return 1
    fi
    sleep "$BUTTON_WAIT_SECS"
    return 1
}

main() {
    local raw block seq
    seq=0
    while true; do
        raw="$(sample_gpsd)"
        seq=$((seq + 1))
        # SEQ is a plain incrementing counter, not a redraw - the payload
        # console renders LOG as a scrolling feed with no way to update a
        # previous entry in place (confirmed live: an attempt to prefix
        # later messages with ANSI cursor-up/clear-to-end escape codes just
        # showed up as literal garbage text, e.g. "[5A", instead of being
        # interpreted). SEQ is the platform-safe way to show the payload is
        # still alive and updating rather than frozen.
        block="SEQ ${seq}
$(format_block "$raw")"

        LOG "$(block_color "$raw")" "$block"

        if wait_for_exit; then
            break
        fi
    done
    exit 0
}

# Only run main when this file is executed directly, not when it's sourced -
# lets tests source it for the function definitions without triggering the
# real loop (which would clobber any test shim of the same name - see the
# design note above).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main
fi
