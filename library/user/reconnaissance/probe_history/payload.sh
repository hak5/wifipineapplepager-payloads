#!/bin/bash
# Title: Probe History
# Description: Exports every probe request SSID from the native recon.db
#              into a loot text file (plus CSV) with timestamp, client MAC
#              and signal. If WiGLE wardrive logs exist, each probe is
#              geotagged with the GPS position the Pager had at that moment.
# Author: DerSeb90
# Version: 1.0
# Category: reconnaissance
# Requires: sqlite3 (opkg install sqlite3-cli if missing)

# =============================================================================
# CONFIG
# =============================================================================

RECON_DB=/root/recon/recon.db
WIGLE_DIR=/root/loot/wigle
LOOT_DIR=/root/loot/probe_history

# Include probes without SSID (wildcard / broadcast probes)?
INCLUDE_BROADCAST=false

# Max seconds between a probe and the nearest WiGLE GPS fix to still
# count as "same place". Driving at 50 km/h is ~14 m per second.
GPS_MATCH_WINDOW=60

# Seconds to add to WiGLE "FirstSeen" values to convert them to UTC.
# 0 if the Pager clock / WiGLE log is UTC (default on the Pager).
WIGLE_TIME_OFFSET=0

# =============================================================================
# PREFLIGHT
# =============================================================================

if ! command -v sqlite3 >/dev/null 2>&1; then
    ALERT "sqlite3 not found.\nRun: opkg install sqlite3-cli"
    exit 1
fi

if [ ! -f "$RECON_DB" ]; then
    ALERT "Recon database not found at\n$RECON_DB"
    exit 1
fi

SPINNER_ID=""
WORK_DB=/tmp/probe_history_$$.db
cleanup() {
    [ -n "$SPINNER_ID" ] && STOP_SPINNER "$SPINNER_ID" 2>/dev/null
    rm -f "$WORK_DB" "$WORK_DB-journal" /tmp/probe_history_$$.sql
}
trap cleanup EXIT INT TERM

mkdir -p "$LOOT_DIR"
STAMP=$(date +%Y%m%d_%H%M%S)
TXT="$LOOT_DIR/probes_$STAMP.txt"
CSV="$LOOT_DIR/probes_$STAMP.csv"

SPINNER_ID=$(START_SPINNER "Reading recon.db...")

# Consistent snapshot (includes pending WAL pages), fall back to plain copy.
if ! sqlite3 "$RECON_DB" ".backup '$WORK_DB'" 2>/dev/null; then
    cp "$RECON_DB" "$WORK_DB" || { ALERT "Could not copy recon.db"; exit 1; }
fi

# =============================================================================
# GPS TRACK FROM WIGLE LOGS
# =============================================================================
# The Pager's WiGLE CSVs (WigleWifi-1.6) contain a FirstSeen timestamp and the
# Pager's own GPS position for every logged AP. Together they form a track of
# where the Pager was at what time. Probes are matched to the nearest point.

sqlite3 "$WORK_DB" "DROP TABLE IF EXISTS ph_track;
CREATE TABLE ph_track (t INTEGER PRIMARY KEY, lat REAL, lon REAL, acc REAL);"

wigle_files=0
for f in "$WIGLE_DIR"/*.csv; do
    [ -f "$f" ] || continue
    # Line 1 is the WigleWifi pre-header, line 2 holds the column names.
    head -n 1 "$f" | grep -q '^WigleWifi' || continue
    sqlite3 "$WORK_DB" >/dev/null 2>&1 <<SQL
DROP TABLE IF EXISTS ph_raw;
.import --csv --skip 1 '$f' ph_raw
INSERT OR REPLACE INTO ph_track (t, lat, lon, acc)
SELECT CAST(strftime('%s', FirstSeen) AS INTEGER) + $WIGLE_TIME_OFFSET,
       avg(CAST(CurrentLatitude  AS REAL)),
       avg(CAST(CurrentLongitude AS REAL)),
       min(CAST(AccuracyMeters   AS REAL))
FROM ph_raw
WHERE strftime('%s', FirstSeen) IS NOT NULL
  AND CAST(CurrentLatitude  AS REAL) != 0
  AND CAST(CurrentLongitude AS REAL) != 0
GROUP BY 1;
DROP TABLE ph_raw;
SQL
    wigle_files=$((wigle_files + 1))
done
track_points=$(sqlite3 "$WORK_DB" "SELECT count(*) FROM ph_track;")
: "${track_points:=0}"

# Some firmware builds may store coordinates directly in the ssid table.
ssid_cols=$(sqlite3 "$WORK_DB" "PRAGMA table_info(ssid);" | awk -F'|' '{print $2}')
native_lat=""; native_lon=""
for c in lat latitude gps_lat; do echo "$ssid_cols" | grep -qx "$c" && native_lat="s.$c" && break; done
for c in lon lng longitude gps_lon; do echo "$ssid_cols" | grep -qx "$c" && native_lon="s.$c" && break; done
if [ -n "$native_lat" ] && [ -n "$native_lon" ]; then
    native_pos="CASE WHEN CAST($native_lat AS REAL) != 0 THEN CAST($native_lat AS REAL) END AS nlat,
                CASE WHEN CAST($native_lon AS REAL) != 0 THEN CAST($native_lon AS REAL) END AS nlon"
else
    native_pos="NULL AS nlat, NULL AS nlon"
fi

# =============================================================================
# QUERY
# =============================================================================
# ssid.type is the 802.11 management subtype: 4 = probe request.

if [ "$INCLUDE_BROADCAST" = true ]; then
    ssid_filter=""
else
    ssid_filter="AND length(CAST(s.ssid AS TEXT)) > 0"
fi

STOP_SPINNER "$SPINNER_ID"
SPINNER_ID=$(START_SPINNER "Matching GPS...")

sqlite3 "$WORK_DB" >/dev/null <<SQL
DROP TABLE IF EXISTS ph_out;
CREATE TABLE ph_out AS
WITH p AS (
    SELECT s.time AS ts,
           upper(substr(w.mac,1,2)||':'||substr(w.mac,3,2)||':'||substr(w.mac,5,2)||':'||
                 substr(w.mac,7,2)||':'||substr(w.mac,9,2)||':'||substr(w.mac,11,2)) AS mac,
           COALESCE(NULLIF(CAST(s.ssid AS TEXT), ''), '[broadcast]') AS ssid,
           s.signal AS signal,
           CASE WHEN s.freq >= 5925 THEN '6'
                WHEN s.freq >= 5000 THEN '5'
                ELSE '2.4' END AS band,
           $native_pos
    FROM ssid s
    JOIN wifi_device w ON s.wifi_device = w.hash
    WHERE s.type = 4 $ssid_filter
),
m AS (
    SELECT p.*,
           (SELECT t FROM ph_track WHERE t <= p.ts ORDER BY t DESC LIMIT 1) AS tb,
           (SELECT t FROM ph_track WHERE t >= p.ts ORDER BY t ASC  LIMIT 1) AS ta
    FROM p
),
n AS (
    SELECT m.*,
           CASE WHEN tb IS NULL THEN ta
                WHEN ta IS NULL THEN tb
                WHEN (ts - tb) <= (ta - ts) THEN tb
                ELSE ta END AS tn
    FROM m
)
SELECT datetime(n.ts, 'unixepoch', 'localtime') AS seen,
       n.mac, n.ssid, n.signal, n.band,
       CASE WHEN n.nlat IS NOT NULL THEN n.nlat
            WHEN abs(n.tn - n.ts) <= $GPS_MATCH_WINDOW THEN tr.lat END AS lat,
       CASE WHEN n.nlat IS NOT NULL THEN n.nlon
            WHEN abs(n.tn - n.ts) <= $GPS_MATCH_WINDOW THEN tr.lon END AS lon,
       CASE WHEN n.nlat IS NOT NULL THEN NULL
            WHEN abs(n.tn - n.ts) <= $GPS_MATCH_WINDOW THEN tr.acc END AS acc,
       CASE WHEN n.nlat IS NOT NULL THEN 0
            WHEN abs(n.tn - n.ts) <= $GPS_MATCH_WINDOW THEN abs(n.tn - n.ts) END AS gps_delta_s
FROM n
LEFT JOIN ph_track tr ON tr.t = n.tn
ORDER BY n.ts;
SQL

total=$(sqlite3 "$WORK_DB" "SELECT count(*) FROM ph_out;")
located=$(sqlite3 "$WORK_DB" "SELECT count(*) FROM ph_out WHERE lat IS NOT NULL;")
unique_ssids=$(sqlite3 "$WORK_DB" "SELECT count(DISTINCT ssid) FROM ph_out;")
: "${total:=0}" "${located:=0}" "${unique_ssids:=0}"

# =============================================================================
# OUTPUT
# =============================================================================

{
    echo "=== Probe History ==="
    echo "Generated  : $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "Probes     : $total ($unique_ssids unique SSIDs)"
    echo "Geotagged  : $located (WiGLE logs: $wigle_files, track points: $track_points, window: ${GPS_MATCH_WINDOW}s)"
    echo ""
    echo "Time                 Client MAC         Sig  Band  SSID                              Location"
    echo "---------------------------------------------------------------------------------------------------------"
    sqlite3 "$WORK_DB" "SELECT printf('%-20s %-18s %-4s %-5s %-33s %s',
            seen, mac, signal, band, '\"' || ssid || '\"',
            CASE WHEN lat IS NULL THEN '-'
                 ELSE printf('%.6f,%.6f', lat, lon)
                      || CASE WHEN acc IS NOT NULL THEN printf(' +-%dm', CAST(acc AS INTEGER)) ELSE '' END
                      || CASE WHEN gps_delta_s > 0 THEN printf(' (dt %ds)', gps_delta_s) ELSE '' END
            END)
        FROM ph_out;"
    echo ""
    echo "=== Top SSIDs (distinct clients) ==="
    sqlite3 "$WORK_DB" "SELECT printf('%4d  %s', count(DISTINCT mac), ssid)
        FROM ph_out GROUP BY ssid ORDER BY count(DISTINCT mac) DESC, ssid LIMIT 25;"
} > "$TXT"

sqlite3 -csv -header "$WORK_DB" \
    "SELECT seen AS time, mac, ssid, signal, band, lat, lon, acc AS accuracy_m, gps_delta_s FROM ph_out;" > "$CSV"

STOP_SPINNER "$SPINNER_ID"
SPINNER_ID=""

LOG "Probes: $total ($unique_ssids SSIDs)"
LOG "Geotagged: $located"
LOG "TXT: $TXT"
LOG "CSV: $CSV"
VIBRATE "alert" 2>/dev/null
ALERT "Probe History\n\n$total probes\n$unique_ssids unique SSIDs\n$located geotagged\n\n$LOOT_DIR"

exit 0
