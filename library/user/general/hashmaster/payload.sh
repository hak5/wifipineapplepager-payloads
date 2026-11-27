#!/bin/bash
# Title: HashMaster 22000
# Description: Report captured handshakes using the HashMaster database
# Author:  spencershepard
# Version:  2.0
# Category: general

REPORT_PAYLOAD_VERSION="2.0"
DB_FILE="/root/hashmaster.db"

# Resolve script dir and source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HSMANAGER="${SCRIPT_DIR}/hashmaster.sh"
if [[ -f "$HSMANAGER" ]]; then
    source "$HSMANAGER"
else
    echo "ERROR: Cannot find hashmaster.sh at $HSMANAGER" >&2
    exit 1
fi

# Fallback LOG for headless usage if not defined by environment
if ! command -v LOG >/dev/null 2>&1; then
    LOG() {
        if [[ $# -eq 2 ]]; then
            shift
        fi
        echo -e "$*"
    }
fi
if ! command -v ERROR_DIALOG >/dev/null 2>&1; then
    ERROR_DIALOG() { echo "[ERROR] $*" >&2; }
fi

# Install alert payload if not present (optional)
if install_alert_payload; then
    LOG green "Alert payload is installed (alerts will be enabled)"
else
    LOG yellow "Alert payload not installed (alerts will not be enabled)"
fi

LOG "Scanning $HANDSHAKE_DIR"

# Header
debug_log "========================================"
debug_log "HashMaster DB Report v${REPORT_PAYLOAD_VERSION}"
debug_log "HashMaster Library v${HASHMASTER_LIB_VERSION}"

# Init DB (creates if missing; preserves existing)
if ! init_handshake_database "$DB_FILE"; then
    ERROR_DIALOG "Failed to initialize handshake tracking database at $DB_FILE"
    exit 1
fi

# Use same lock as alerts to avoid concurrent writes during reporting
LOCK_FILE="/tmp/hashmaster_alert.lock"
LOCK_FD=200
acquire_lock() {
    exec 200>"$LOCK_FILE"
    local timeout=15
    local waited=0
    while ! flock -n 200; do
        if [[ $waited -ge $timeout ]]; then
            ERROR_DIALOG "Could not acquire DB lock after ${timeout}s"
            exit 1
        fi
        sleep 1
        ((waited++))
    done
}
release_lock() { flock -u 200 2>/dev/null; }
trap release_lock EXIT
acquire_lock

# Helpers
safe_sql() { echo "${1//\'/\'\'}"; }

# Top-level DB stats
db_total_networks=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM handshakes;" 2>/dev/null || echo 0)
db_crackable_networks=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM handshakes WHERE crackable=1;" 2>/dev/null || echo 0)
db_total_captures=$(sqlite3 "$DB_FILE" "SELECT IFNULL(SUM(total_captures),0) FROM handshakes;" 2>/dev/null || echo 0)

# Quality breakdown
readarray -t quality_rows < <(sqlite3 "$DB_FILE" "SELECT IFNULL(best_quality,'UNKNOWN') AS q, COUNT(*) FROM handshakes GROUP BY best_quality ORDER BY q;" 2>/dev/null)

# Print overview
LOG "======================================"
LOG cyan "[DATABASE SNAPSHOT]"
LOG "======================================"
LOG ""
LOG blue "[COLLECTION]"
LOG "   Networks Tracked: $db_total_networks"
LOG "   Crackable Networks: $db_crackable_networks"
LOG "   Total Captures (lifetime): $db_total_captures"
LOG ""
LOG blue "[QUALITY BREAKDOWN]"
if [[ ${#quality_rows[@]} -eq 0 ]]; then
    LOG "   No records yet"
else
    for row in "${quality_rows[@]}"; do
        q="${row%%|*}"; c="${row##*|}"
        case "$q" in
            EAPOL_M2M3_BEST) LOG yellow "   $q: $c" ;;
            *) LOG "   $q: $c" ;;
        esac
    done
fi
LOG ""

# Recent networks (last 10 by last_seen)
readarray -t recent_rows < <(sqlite3 "$DB_FILE" "SELECT IFNULL(ssid_printable,'UNKNOWN_SSID'), bssid, IFNULL(best_quality,'UNKNOWN'), crackable, last_seen, total_captures FROM handshakes ORDER BY last_seen DESC LIMIT 10;" 2>/dev/null)
if [[ ${#recent_rows[@]} -gt 0 ]]; then
    LOG blue "[RECENT CAPTURES]"
    for row in "${recent_rows[@]}"; do
        IFS='|' read -r ssid bssid q crack last_seen captures <<<"$row"
        ts="unknown"; [[ -n "$last_seen" ]] && ts=$(date -d "@$last_seen" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "$last_seen" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$last_seen")
        icon="[X]"; [[ "$q" == "EAPOL_M2M3_BEST" ]] && icon="[***]"; [[ "$crack" == "1" ]] && [[ "$q" != "EAPOL_M2M3_BEST" ]] && icon="[OK]"
        LOG "   $icon $ssid ($bssid) | Quality: $q | Captures: $captures | Crackable: $([[ "$crack" == "1" ]] && echo Yes || echo No) | Last: $ts"
    done
    LOG ""
fi

# Detailed per-SSID breakdown from DB only
# Aggregate by ssid_hex to de-duplicate across BSSIDs while using printable for display
readarray -t ssid_rows < <(sqlite3 "$DB_FILE" "SELECT ssid_hex, IFNULL(ssid_printable,'UNKNOWN_SSID') AS name,
    COUNT(*) AS bssid_count,
    IFNULL(SUM(total_captures),0) AS captures,
    SUM(CASE WHEN crackable=1 THEN 1 ELSE 0 END) AS crackable_bssid,
    SUM(CASE WHEN best_quality='EAPOL_M2M3_BEST' THEN 1 ELSE 0 END) AS best_bssid
  FROM handshakes
  GROUP BY ssid_hex
  ORDER BY captures DESC, name ASC;" 2>/dev/null)

if [[ ${#ssid_rows[@]} -gt 0 ]]; then
    LOG cyan "[DETAILED SSID BREAKDOWN]"
    LOG ""
    for row in "${ssid_rows[@]}"; do
        IFS='|' read -r ssid_hex ssid_name bssid_count captures crackable_bssid best_bssid <<<"$row"
        # Determine status
        status_icon="[X]"; status_text="NOT CRACKABLE"; status_color="red"
        if [[ ${best_bssid:-0} -gt 0 ]]; then
            status_icon="[***]"; status_text="EXCELLENT"; status_color="green"
        elif [[ ${crackable_bssid:-0} -gt 0 ]]; then
            status_icon="[OK]"; status_text="READY"; status_color="yellow"
        fi
        LOG "$status_color" "$status_icon $ssid_name [$status_text]"
        LOG "   |-- Total Captures (DB): ${captures:-0}"
        LOG "   |-- Crackable BSSIDs: ${crackable_bssid:-0}"
        LOG "   +-- Access Point(s) [${bssid_count:-0}]:"

        # List BSSIDs under this SSID
        ssid_hex_sql=$(safe_sql "$ssid_hex")
        readarray -t bssid_rows < <(sqlite3 "$DB_FILE" "SELECT bssid, IFNULL(best_quality,'UNKNOWN'), crackable, total_captures, first_seen FROM handshakes WHERE ssid_hex='$ssid_hex_sql' ORDER BY total_captures DESC;" 2>/dev/null)
        for brow in "${bssid_rows[@]}"; do
            IFS='|' read -r bssid q crack total first_seen <<<"$brow"
            icon="[X]"; [[ "$q" == "EAPOL_M2M3_BEST" ]] && icon="[***]"; [[ "$crack" == "1" ]] && [[ "$q" != "EAPOL_M2M3_BEST" ]] && icon="[OK]"
            fdate="unknown"; [[ -n "$first_seen" ]] && fdate=$(date -d "@$first_seen" "+%Y-%m-%d" 2>/dev/null || date -r "$first_seen" "+%Y-%m-%d" 2>/dev/null || echo "$first_seen")
            LOG "       |-- $icon $bssid: ${total:-0} captures, quality $q [first: $fdate]"
        done
        LOG ""
    done
fi

LOG "======================================"
LOG "Database snapshot complete:  $db_total_networks networks tracked, $db_total_captures lifetime captures"
debug_log "DB report completed successfully."
exit 0
