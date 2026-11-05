#!/bin/bash
# Title: RF-Baseline Sentinel
# Description: Passive RF environment behavioral baseline & anomaly correlation engine
# Author: D-L3aN
# Version: 1.1
# Category: blue-team
# Net Mode: NAT
#
# This payload does NOT transmit. It passively observes.
# Ethical use: detecting surveillance, rogue infrastructure, and RF anomalies in YOUR environment.

# === CONFIGURATION ===
BASELINE_DIR="/root/loot/rf-baseline"
BASELINE_FILE="$BASELINE_DIR/baseline.db"
ANOMALY_LOG="$BASELINE_DIR/anomalies.log"
LEARNING_MODE="${LEARNING_MODE:-true}"   # Set to false after training period
Z_THRESHOLD=3.0                          # Standard deviations for anomaly
MIN_SAMPLES=100                          # Minimum scans before baseline is valid
SAMPLE_INTERVAL=60                       # Seconds between samples (60 = production)
CHECK_INTERVAL=120                       # Seconds between anomaly checks

# === FRAMEWORK FALLBACKS ===
# Use the Pager's LOG/ALERT/VIBRATE if present; otherwise provide safe stubs.
command -v LOG     >/dev/null 2>&1 || LOG()     { echo "[LOG] $*"; }
command -v ALERT   >/dev/null 2>&1 || ALERT()   { echo "[ALERT] $*"; }
command -v VIBRATE >/dev/null 2>&1 || VIBRATE() { :; }

# === INITIALIZATION ===
mkdir -p "$BASELINE_DIR"

sqlite3 "$BASELINE_FILE" <<EOF
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS scans (
    id INTEGER PRIMARY KEY,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    hour INTEGER,
    ap_count INTEGER,
    client_count INTEGER,
    avg_rssi REAL,
    channel_distribution TEXT,
    unique_bssids INTEGER
);
CREATE TABLE IF NOT EXISTS bssid_registry (
    bssid TEXT PRIMARY KEY,
    first_seen DATETIME,
    last_seen DATETIME,
    sighting_count INTEGER DEFAULT 1,
    channel INTEGER,
    ssid TEXT,
    avg_rssi REAL
);
EOF

# === PASSIVE SCAN FUNCTION ===
passive_scan() {
    local recon_db="/root/recon/recon.db"

    if [ ! -f "$recon_db" ]; then
        LOG "Recon database not found at $recon_db"
        return 1
    fi

    # Devices seen in the last 5 minutes (epoch-based)
    local cutoff=$(( $(date +%s) - 300 ))

    local device_count
    device_count=$(sqlite3 -cmd ".timeout 5000" "$recon_db" \
        "SELECT COUNT(DISTINCT mac) FROM wifi_device WHERE time > $cutoff;" 2>&1)

    local ap_count
    ap_count=$(sqlite3 -cmd ".timeout 5000" "$recon_db" \
        "SELECT COUNT(DISTINCT mac) FROM wifi_device WHERE time > $cutoff AND packets > 10;" 2>&1)

    local avg_rssi
    avg_rssi=$(sqlite3 -cmd ".timeout 5000" "$recon_db" \
        "SELECT ROUND(AVG(signal),1) FROM wifi_device WHERE time > $cutoff;" 2>&1)

    # Sanity checks
    [[ "$device_count" =~ ^[0-9]+$ ]] || { LOG "Device query err: $device_count"; device_count=0; }
    [[ "$ap_count"     =~ ^[0-9]+$ ]] || { LOG "AP query err: $ap_count";         ap_count=0; }
    [[ "$avg_rssi" =~ ^-?[0-9.]+$ ]]   || { LOG "RSSI query err: $avg_rssi";      avg_rssi=0; }

    local current_hour
    current_hour=$(date +%H)

    if ! sqlite3 "$BASELINE_FILE" \
        "INSERT INTO scans (hour, ap_count, client_count, avg_rssi) \
         VALUES ($current_hour, $ap_count, $device_count, $avg_rssi);" 2>/tmp/rfbs_ins_err; then
        LOG "Insert failed: $(cat /tmp/rfbs_ins_err)"
        return 1
    fi

    echo "$ap_count|$device_count|$avg_rssi"
}

# === BASELINE LEARNING ===
learn_baseline() {
    LOG "RF-Baseline Sentinel: Learning mode active"

    local sample_count
    sample_count=$(sqlite3 "$BASELINE_FILE" "SELECT COUNT(*) FROM scans;")

    if [ "$sample_count" -lt "$MIN_SAMPLES" ]; then
        LOG "Collecting baseline samples... ($sample_count/$MIN_SAMPLES)"

        while [ "$sample_count" -lt "$MIN_SAMPLES" ]; do
            passive_scan > /dev/null
            sample_count=$(sqlite3 "$BASELINE_FILE" "SELECT COUNT(*) FROM scans;")
            LOG "Sample collected: $sample_count/$MIN_SAMPLES"
            sleep "$SAMPLE_INTERVAL"
        done

        LOG "Baseline established with $sample_count samples."
    else
        LOG "Baseline already has $sample_count samples (>= $MIN_SAMPLES). Skipping learning."
    fi
}

# === ANOMALY DETECTION ===
detect_anomalies() {
    local current_hour
    current_hour=$(date +%H)

    local current
    current=$(passive_scan)
    [ -z "$current" ] && { LOG "passive_scan returned empty; skipping anomaly check."; return 1; }

    local current_ap current_clients current_rssi
    current_ap=$(echo "$current" | cut -d'|' -f1)
    current_clients=$(echo "$current" | cut -d'|' -f2)
    current_rssi=$(echo "$current" | cut -d'|' -f3)

    # Pull historical stats for this hour of day
    local avg_ap variance_ap
    read -r avg_ap variance_ap < <(sqlite3 -separator ' ' "$BASELINE_FILE" "
        SELECT
            COALESCE(AVG(ap_count),0),
            COALESCE(AVG((ap_count - (SELECT AVG(ap_count) FROM scans WHERE hour = $current_hour)) *
                         (ap_count - (SELECT AVG(ap_count) FROM scans WHERE hour = $current_hour))),0)
        FROM scans WHERE hour = $current_hour;")

    # Need enough samples for this hour to trust stats
    local hour_samples
    hour_samples=$(sqlite3 "$BASELINE_FILE" "SELECT COUNT(*) FROM scans WHERE hour = $current_hour;")
    if [ "$hour_samples" -lt 5 ]; then
        LOG "Only $hour_samples samples for hour $current_hour; deferring anomaly decision."
        return 0
    fi

    # Compute z-score with awk (no bc dependency)
    local z_score
    z_score=$(awk -v c="$current_ap" -v a="$avg_ap" -v v="$variance_ap" 'BEGIN{
        if (v <= 0) { print 0; exit }
        s = sqrt(v);
        if (s == 0) { print 0; exit }
        printf "%.2f", (c - a) / s
    }')

    local z_abs
    z_abs=$(awk -v z="$z_score" 'BEGIN{ z<0 ? print -z : print z }')

    if awk -v z="$z_abs" -v t="$Z_THRESHOLD" 'BEGIN{ exit !(z > t) }'; then
        local direction="increase"
        awk -v z="$z_score" 'BEGIN{ exit !(z < 0) }' && direction="decrease"

        local alert_msg="RF Anomaly: AP count $direction (current: $current_ap, baseline: ${avg_ap%.*}, z-score: $z_score)"
        echo "$(date '+%Y-%m-%d %H:%M:%S') | $alert_msg" >> "$ANOMALY_LOG"
        LOG "$alert_msg"
        ALERT "$alert_msg"
        VIBRATE 200
    else
        LOG "Nominal: AP=$current_ap (avg=${avg_ap%.*}, z=$z_score), devices=$current_clients, rssi=$current_rssi"
    fi
}

# === MAIN LOOP ===
main() {
    LOG "RF-Baseline Sentinel starting..."

    if [ "$LEARNING_MODE" = "true" ]; then
        learn_baseline
    fi

    LOG "Entering continuous monitoring mode..."

    while true; do
        detect_anomalies
        sleep "$CHECK_INTERVAL"
    done
}

main
