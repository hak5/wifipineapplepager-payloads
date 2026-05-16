#!/bin/bash
# Title: Recon Reporter
# Author: sinX + Codex
# Description: Generate structured recon reports (CSV + JSON) for selected APs/clients
# Version: 1.1
# Category: recon/general
# Target: WiFi Pineapple Pager
# Requirements: None
# Net Mode: N/A

# ============================================
# CONFIGURATION
# ============================================
PAYLOAD_NAME="recon_reporter"
INTERACTIVE_CONFIG=true
SAVE_CONFIG=true

OUTPUT_DIR="/root/loot/recon_reports"
PER_TARGET_DIR=true
ENABLE_JSON=true
ENABLE_CSV=true
INCLUDE_ENV_DUMP=true
ENABLE_DIFF=true
ALERT_ON_CHANGES=true
IGNORE_DIFF_KEYS="ap_rssi,client_rssi,ap_packets,client_packets"
CLEANUP_DAYS=0

SAMPLE_COUNT=1
SAMPLE_INTERVAL=2

# ============================================
# HELPERS
# ============================================

json_escape() {
    # Escape JSON control characters without external deps
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' -e ':a;N;$!ba;s/\n/\\n/g'
}

csv_escape() {
    local val="$1"
    local esc
    esc=$(printf '%s' "$val" | sed 's/"/""/g')
    if printf '%s' "$val" | grep -q '[,\n"]'; then
        printf '"%s"' "$esc"
    else
        printf '%s' "$esc"
    fi
}

sanitize_id() {
    printf '%s' "$1" | tr ':' '-' | tr -cd '[:alnum:]_\-.'
}

now_ts() {
    date '+%Y%m%d-%H%M%S' 2>/dev/null || busybox date '+%Y%m%d-%H%M%S'
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

get_conf() {
    PAYLOAD_GET_CONFIG "$PAYLOAD_NAME" "$1" 2>/dev/null
}

set_conf() {
    PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" "$1" "$2" 2>/dev/null
}

key_ignored() {
    case ",$IGNORE_DIFF_KEYS," in
        *,"$1",*) return 0 ;;
        *) return 1 ;;
    esac
}

refresh_dynamic_fields() {
    AP_RSSI="${_RECON_SELECTED_AP_RSSI}"
    AP_PACKETS="${_RECON_SELECTED_AP_PACKETS}"
    AP_CLIENTS="${_RECON_SELECTED_AP_CLIENT_COUNT:-$_RECON_SELECTED_AP_CLIENTS}"
    AP_BEACONED_SSIDS="${_RECON_SELECTED_AP_BEACONED_SSIDS}"
    AP_PROBED_SSIDS="${_RECON_SELECTED_AP_PROBED_SSIDS}"
    AP_RESPONDED_SSIDS="${_RECON_SELECTED_AP_RESPONDED_SSIDS}"
    AP_BEACONED_SSID="${_RECON_SELECTED_AP_BEACONED_SSID}"
    AP_PROBED_SSID="${_RECON_SELECTED_AP_PROBED_SSID}"
    AP_RESPONDED_SSID="${_RECON_SELECTED_AP_RESPONDED_SSID}"

    CLIENT_RSSI="${_RECON_SELECTED_CLIENT_RSSI}"
    CLIENT_PACKETS="${_RECON_SELECTED_CLIENT_PACKETS}"
    CLIENT_BEACONED_SSIDS="${_RECON_SELECTED_CLIENT_BEACONED_SSIDS}"
    CLIENT_PROBED_SSIDS="${_RECON_SELECTED_CLIENT_PROBED_SSIDS}"
    CLIENT_RESPONDED_SSIDS="${_RECON_SELECTED_CLIENT_RESPONDED_SSIDS}"
    CLIENT_BEACONED_SSID="${_RECON_SELECTED_CLIENT_BEACONED_SSID}"
    CLIENT_PROBED_SSID="${_RECON_SELECTED_CLIENT_PROBED_SSID}"
    CLIENT_RESPONDED_SSID="${_RECON_SELECTED_CLIENT_RESPONDED_SSID}"
}

prompt_yes_no() {
    local prompt="$1"
    local resp
    resp=$(CONFIRMATION_DIALOG "$prompt") || return 1
    if [ "$resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        return 0
    fi
    return 1
}

apply_persisted_config() {
    local v
    v=$(get_conf output_dir); [ -n "$v" ] && OUTPUT_DIR="$v"
    v=$(get_conf per_target_dir); [ -n "$v" ] && PER_TARGET_DIR="$v"
    v=$(get_conf enable_json); [ -n "$v" ] && ENABLE_JSON="$v"
    v=$(get_conf enable_csv); [ -n "$v" ] && ENABLE_CSV="$v"
    v=$(get_conf include_env_dump); [ -n "$v" ] && INCLUDE_ENV_DUMP="$v"
    v=$(get_conf enable_diff); [ -n "$v" ] && ENABLE_DIFF="$v"
    v=$(get_conf alert_on_changes); [ -n "$v" ] && ALERT_ON_CHANGES="$v"
    v=$(get_conf ignore_diff_keys); [ -n "$v" ] && IGNORE_DIFF_KEYS="$v"
    v=$(get_conf cleanup_days); [ -n "$v" ] && CLEANUP_DAYS="$v"
    v=$(get_conf sample_count); [ -n "$v" ] && SAMPLE_COUNT="$v"
    v=$(get_conf sample_interval); [ -n "$v" ] && SAMPLE_INTERVAL="$v"
}

run_interactive_config() {
    local resp
    if ! prompt_yes_no "Customize settings?"; then
        return 0
    fi

    resp=$(TEXT_PICKER "Output dir" "$OUTPUT_DIR") || return 1
    [ -n "$resp" ] && OUTPUT_DIR="$resp"

    if prompt_yes_no "Per-target folders?"; then
        PER_TARGET_DIR=true
    else
        PER_TARGET_DIR=false
    fi

    if prompt_yes_no "Write JSON reports?"; then
        ENABLE_JSON=true
    else
        ENABLE_JSON=false
    fi

    if prompt_yes_no "Write CSV summaries?"; then
        ENABLE_CSV=true
    else
        ENABLE_CSV=false
    fi

    if prompt_yes_no "Save env dump?"; then
        INCLUDE_ENV_DUMP=true
    else
        INCLUDE_ENV_DUMP=false
    fi

    if prompt_yes_no "Enable diff vs last?"; then
        ENABLE_DIFF=true
    else
        ENABLE_DIFF=false
    fi

    if [ "$ENABLE_DIFF" = true ]; then
        if prompt_yes_no "Alert on changes?"; then
            ALERT_ON_CHANGES=true
        else
            ALERT_ON_CHANGES=false
        fi

        if prompt_yes_no "Ignore RSSI/packet noise?"; then
            IGNORE_DIFF_KEYS="ap_rssi,client_rssi,ap_packets,client_packets"
        else
            IGNORE_DIFF_KEYS=""
        fi
    fi

    resp=$(NUMBER_PICKER "Samples (1=single)" "$SAMPLE_COUNT") || return 1
    [ -n "$resp" ] && SAMPLE_COUNT="$resp"

    resp=$(NUMBER_PICKER "Interval (sec)" "$SAMPLE_INTERVAL") || return 1
    [ -n "$resp" ] && SAMPLE_INTERVAL="$resp"

    resp=$(NUMBER_PICKER "Cleanup days (0=off)" "$CLEANUP_DAYS") || return 1
    [ -n "$resp" ] && CLEANUP_DAYS="$resp"

    if [ "$SAVE_CONFIG" = true ]; then
        set_conf output_dir "$OUTPUT_DIR"
        set_conf per_target_dir "$PER_TARGET_DIR"
        set_conf enable_json "$ENABLE_JSON"
        set_conf enable_csv "$ENABLE_CSV"
        set_conf include_env_dump "$INCLUDE_ENV_DUMP"
        set_conf enable_diff "$ENABLE_DIFF"
        set_conf alert_on_changes "$ALERT_ON_CHANGES"
        set_conf ignore_diff_keys "$IGNORE_DIFF_KEYS"
        set_conf cleanup_days "$CLEANUP_DAYS"
        set_conf sample_count "$SAMPLE_COUNT"
        set_conf sample_interval "$SAMPLE_INTERVAL"
    fi
}

# ============================================
# MAIN EXECUTION
# ============================================

LOG green "=== Recon Reporter ==="

apply_persisted_config
if [ "$INTERACTIVE_CONFIG" = true ]; then
    run_interactive_config || {
        LOG "Cancelled"
        exit 0
    }
fi

case "$SAMPLE_COUNT" in ''|*[!0-9]*) SAMPLE_COUNT=1 ;; esac
case "$SAMPLE_INTERVAL" in ''|*[!0-9]*) SAMPLE_INTERVAL=2 ;; esac
case "$CLEANUP_DAYS" in ''|*[!0-9]*) CLEANUP_DAYS=0 ;; esac
if [ "$SAMPLE_COUNT" -lt 1 ]; then
    SAMPLE_COUNT=1
fi

# Selected AP variables (best-effort; varies by firmware)
AP_SSID="${_RECON_SELECTED_AP_SSID}"
AP_BSSID="${_RECON_SELECTED_AP_BSSID:-$_RECON_SELECTED_AP_MAC_ADDRESS}"
AP_CHANNEL="${_RECON_SELECTED_AP_CHANNEL}"
AP_ENCRYPTION="${_RECON_SELECTED_AP_ENCRYPTION_TYPE:-$_RECON_SELECTED_AP_ENCRYPTION}"
AP_RSSI="${_RECON_SELECTED_AP_RSSI}"
AP_FREQUENCY="${_RECON_SELECTED_AP_FREQ:-$_RECON_SELECTED_AP_FREQUENCY}"
AP_PACKETS="${_RECON_SELECTED_AP_PACKETS}"
AP_CLIENTS="${_RECON_SELECTED_AP_CLIENT_COUNT:-$_RECON_SELECTED_AP_CLIENTS}"
AP_OUI="${_RECON_SELECTED_AP_OUI}"
AP_HIDDEN="${_RECON_SELECTED_AP_HIDDEN}"
AP_BEACONED_SSIDS="${_RECON_SELECTED_AP_BEACONED_SSIDS}"
AP_PROBED_SSIDS="${_RECON_SELECTED_AP_PROBED_SSIDS}"
AP_RESPONDED_SSIDS="${_RECON_SELECTED_AP_RESPONDED_SSIDS}"
AP_BEACONED_SSID="${_RECON_SELECTED_AP_BEACONED_SSID}"
AP_PROBED_SSID="${_RECON_SELECTED_AP_PROBED_SSID}"
AP_RESPONDED_SSID="${_RECON_SELECTED_AP_RESPONDED_SSID}"
AP_FIRST_SEEN="${_RECON_SELECTED_AP_TIMESTAMP}"

# Selected client variables (best-effort; varies by firmware)
CLIENT_MAC="${_RECON_SELECTED_CLIENT_MAC_ADDRESS:-$_RECON_SELECTED_CLIENT_MAC}"
CLIENT_RSSI="${_RECON_SELECTED_CLIENT_RSSI}"
CLIENT_FREQUENCY="${_RECON_SELECTED_CLIENT_FREQ:-$_RECON_SELECTED_CLIENT_FREQUENCY}"
CLIENT_PACKETS="${_RECON_SELECTED_CLIENT_PACKETS}"
CLIENT_OUI="${_RECON_SELECTED_CLIENT_OUI}"
CLIENT_ASSOC_BSSID="${_RECON_SELECTED_CLIENT_BSSID}"
CLIENT_BEACONED_SSIDS="${_RECON_SELECTED_CLIENT_BEACONED_SSIDS}"
CLIENT_PROBED_SSIDS="${_RECON_SELECTED_CLIENT_PROBED_SSIDS}"
CLIENT_RESPONDED_SSIDS="${_RECON_SELECTED_CLIENT_RESPONDED_SSIDS}"
CLIENT_BEACONED_SSID="${_RECON_SELECTED_CLIENT_BEACONED_SSID}"
CLIENT_PROBED_SSID="${_RECON_SELECTED_CLIENT_PROBED_SSID}"
CLIENT_RESPONDED_SSID="${_RECON_SELECTED_CLIENT_RESPONDED_SSID}"
CLIENT_FIRST_SEEN="${_RECON_SELECTED_CLIENT_TIMESTAMP}"

HAS_AP=false
HAS_CLIENT=false

if [ -n "$AP_BSSID" ] || [ -n "$AP_SSID" ]; then
    HAS_AP=true
fi

if [ -n "$CLIENT_MAC" ]; then
    HAS_CLIENT=true
fi

if [ "$HAS_AP" = false ] && [ "$HAS_CLIENT" = false ]; then
    ERROR_DIALOG "No recon target context found. Run from Recon on a selected AP or client."
    exit 1
fi

BASE_ID="unknown"

if [ "$HAS_CLIENT" = true ]; then
    BASE_ID=$(sanitize_id "$CLIENT_MAC")
elif [ -n "$AP_BSSID" ]; then
    BASE_ID=$(sanitize_id "$AP_BSSID")
fi

mkdir -p "$OUTPUT_DIR" || {
    ERROR_DIALOG "Failed to create output dir: $OUTPUT_DIR"
    exit 1
}

TARGET_DIR="$OUTPUT_DIR"
if [ "$PER_TARGET_DIR" = true ]; then
    TARGET_DIR="$OUTPUT_DIR/$BASE_ID"
    mkdir -p "$TARGET_DIR" || {
        ERROR_DIALOG "Failed to create target dir: $TARGET_DIR"
        exit 1
    }
fi

LAST_FILE="$TARGET_DIR/last_fields.env"

LOG blue "Target: $BASE_ID"
if [ "$SAMPLE_COUNT" -gt 1 ]; then
    LOG yellow "Sampling: $SAMPLE_COUNT x ${SAMPLE_INTERVAL}s"
fi

SAMPLE_INDEX=1
while [ "$SAMPLE_INDEX" -le "$SAMPLE_COUNT" ]; do
    TS=$(now_ts)
    JSON_FILE="$TARGET_DIR/${TS}_${BASE_ID}.json"
    ENV_FILE="$TARGET_DIR/${TS}_${BASE_ID}.env"
    CHANGE_FILE="$TARGET_DIR/${TS}_${BASE_ID}.changes.txt"

    if [ "$SAMPLE_COUNT" -gt 1 ]; then
        LOG blue "Sample $SAMPLE_INDEX/$SAMPLE_COUNT"
    fi
    refresh_dynamic_fields

# --------------------------------------------
# JSON OUTPUT
# --------------------------------------------
if [ "$ENABLE_JSON" = true ]; then
    {
        echo "{"
        echo "  \"timestamp\": \"$(json_escape "$TS")\","
        echo "  \"payload\": \"recon_reporter\","
        echo "  \"sample_index\": \"$(json_escape "$SAMPLE_INDEX")\","

        if [ "$HAS_AP" = true ]; then
            echo "  \"ap\": {"
            echo "    \"ssid\": \"$(json_escape "$AP_SSID")\","
            echo "    \"bssid\": \"$(json_escape "$AP_BSSID")\","
            echo "    \"channel\": \"$(json_escape "$AP_CHANNEL")\","
            echo "    \"encryption\": \"$(json_escape "$AP_ENCRYPTION")\","
            echo "    \"rssi\": \"$(json_escape "$AP_RSSI")\","
            echo "    \"frequency\": \"$(json_escape "$AP_FREQUENCY")\","
            echo "    \"packets\": \"$(json_escape "$AP_PACKETS")\","
            echo "    \"clients\": \"$(json_escape "$AP_CLIENTS")\","
            echo "    \"oui\": \"$(json_escape "$AP_OUI")\","
            echo "    \"hidden\": \"$(json_escape "$AP_HIDDEN")\","
            echo "    \"beaconed_ssids\": \"$(json_escape "$AP_BEACONED_SSIDS")\","
            echo "    \"probed_ssids\": \"$(json_escape "$AP_PROBED_SSIDS")\","
            echo "    \"responded_ssids\": \"$(json_escape "$AP_RESPONDED_SSIDS")\","
            echo "    \"beaconed_ssid\": \"$(json_escape "$AP_BEACONED_SSID")\","
            echo "    \"probed_ssid\": \"$(json_escape "$AP_PROBED_SSID")\","
            echo "    \"responded_ssid\": \"$(json_escape "$AP_RESPONDED_SSID")\","
            echo "    \"first_seen\": \"$(json_escape "$AP_FIRST_SEEN")\""
            echo "  },"
        else
            echo "  \"ap\": null,"
        fi

        if [ "$HAS_CLIENT" = true ]; then
            echo "  \"client\": {"
            echo "    \"mac\": \"$(json_escape "$CLIENT_MAC")\","
            echo "    \"rssi\": \"$(json_escape "$CLIENT_RSSI")\","
            echo "    \"frequency\": \"$(json_escape "$CLIENT_FREQUENCY")\","
            echo "    \"packets\": \"$(json_escape "$CLIENT_PACKETS")\","
            echo "    \"oui\": \"$(json_escape "$CLIENT_OUI")\","
            echo "    \"associated_bssid\": \"$(json_escape "$CLIENT_ASSOC_BSSID")\","
            echo "    \"beaconed_ssids\": \"$(json_escape "$CLIENT_BEACONED_SSIDS")\","
            echo "    \"probed_ssids\": \"$(json_escape "$CLIENT_PROBED_SSIDS")\","
            echo "    \"responded_ssids\": \"$(json_escape "$CLIENT_RESPONDED_SSIDS")\","
            echo "    \"beaconed_ssid\": \"$(json_escape "$CLIENT_BEACONED_SSID")\","
            echo "    \"probed_ssid\": \"$(json_escape "$CLIENT_PROBED_SSID")\","
            echo "    \"responded_ssid\": \"$(json_escape "$CLIENT_RESPONDED_SSID")\","
            echo "    \"first_seen\": \"$(json_escape "$CLIENT_FIRST_SEEN")\""
            echo "  }"
        else
            echo "  \"client\": null"
        fi

        echo "}"
    } > "$JSON_FILE"
    if has_cmd ln; then
        ln -sf "$JSON_FILE" "$TARGET_DIR/last.json" 2>/dev/null
    fi
fi

# --------------------------------------------
# CSV OUTPUT
# --------------------------------------------
if [ "$ENABLE_CSV" = true ]; then
    AP_CSV="$OUTPUT_DIR/ap_summary.csv"
    CLIENT_CSV="$OUTPUT_DIR/client_summary.csv"

    if [ ! -f "$AP_CSV" ]; then
        echo "timestamp,ssid,bssid,channel,encryption,rssi,frequency,packets,clients,oui,hidden,beaconed_ssids,probed_ssids,responded_ssids,beaconed_ssid,probed_ssid,responded_ssid,first_seen" > "$AP_CSV"
    fi

    if [ ! -f "$CLIENT_CSV" ]; then
        echo "timestamp,client_mac,rssi,frequency,packets,oui,associated_bssid,beaconed_ssids,probed_ssids,responded_ssids,beaconed_ssid,probed_ssid,responded_ssid,first_seen" > "$CLIENT_CSV"
    fi

    if [ "$HAS_AP" = true ]; then
        echo "$(csv_escape "$TS"),$(csv_escape "$AP_SSID"),$(csv_escape "$AP_BSSID"),$(csv_escape "$AP_CHANNEL"),$(csv_escape "$AP_ENCRYPTION"),$(csv_escape "$AP_RSSI"),$(csv_escape "$AP_FREQUENCY"),$(csv_escape "$AP_PACKETS"),$(csv_escape "$AP_CLIENTS"),$(csv_escape "$AP_OUI"),$(csv_escape "$AP_HIDDEN"),$(csv_escape "$AP_BEACONED_SSIDS"),$(csv_escape "$AP_PROBED_SSIDS"),$(csv_escape "$AP_RESPONDED_SSIDS"),$(csv_escape "$AP_BEACONED_SSID"),$(csv_escape "$AP_PROBED_SSID"),$(csv_escape "$AP_RESPONDED_SSID"),$(csv_escape "$AP_FIRST_SEEN")" >> "$AP_CSV"
    fi

    if [ "$HAS_CLIENT" = true ]; then
        echo "$(csv_escape "$TS"),$(csv_escape "$CLIENT_MAC"),$(csv_escape "$CLIENT_RSSI"),$(csv_escape "$CLIENT_FREQUENCY"),$(csv_escape "$CLIENT_PACKETS"),$(csv_escape "$CLIENT_OUI"),$(csv_escape "$CLIENT_ASSOC_BSSID"),$(csv_escape "$CLIENT_BEACONED_SSIDS"),$(csv_escape "$CLIENT_PROBED_SSIDS"),$(csv_escape "$CLIENT_RESPONDED_SSIDS"),$(csv_escape "$CLIENT_BEACONED_SSID"),$(csv_escape "$CLIENT_PROBED_SSID"),$(csv_escape "$CLIENT_RESPONDED_SSID"),$(csv_escape "$CLIENT_FIRST_SEEN")" >> "$CLIENT_CSV"
    fi
fi

# --------------------------------------------
# ENV DUMP (DEBUG)
# --------------------------------------------
if [ "$INCLUDE_ENV_DUMP" = true ]; then
    env | grep '^_RECON_' > "$ENV_FILE"
fi

# --------------------------------------------
# DIFF (PREVIOUS RUN)
# --------------------------------------------
CHANGE_COUNT=0
CHANGE_SUMMARY=""

if [ "$ENABLE_DIFF" = true ]; then
    TMP_CUR="$TARGET_DIR/.current_fields.tmp"
    {
        echo "ap_ssid=$AP_SSID"
        echo "ap_bssid=$AP_BSSID"
        echo "ap_channel=$AP_CHANNEL"
        echo "ap_encryption=$AP_ENCRYPTION"
        echo "ap_rssi=$AP_RSSI"
        echo "ap_frequency=$AP_FREQUENCY"
        echo "ap_packets=$AP_PACKETS"
        echo "ap_clients=$AP_CLIENTS"
        echo "ap_oui=$AP_OUI"
        echo "ap_hidden=$AP_HIDDEN"
        echo "ap_beaconed_ssids=$AP_BEACONED_SSIDS"
        echo "ap_probed_ssids=$AP_PROBED_SSIDS"
        echo "ap_responded_ssids=$AP_RESPONDED_SSIDS"
        echo "ap_beaconed_ssid=$AP_BEACONED_SSID"
        echo "ap_probed_ssid=$AP_PROBED_SSID"
        echo "ap_responded_ssid=$AP_RESPONDED_SSID"
        echo "ap_first_seen=$AP_FIRST_SEEN"
        echo "client_mac=$CLIENT_MAC"
        echo "client_rssi=$CLIENT_RSSI"
        echo "client_frequency=$CLIENT_FREQUENCY"
        echo "client_packets=$CLIENT_PACKETS"
        echo "client_oui=$CLIENT_OUI"
        echo "client_associated_bssid=$CLIENT_ASSOC_BSSID"
        echo "client_beaconed_ssids=$CLIENT_BEACONED_SSIDS"
        echo "client_probed_ssids=$CLIENT_PROBED_SSIDS"
        echo "client_responded_ssids=$CLIENT_RESPONDED_SSIDS"
        echo "client_beaconed_ssid=$CLIENT_BEACONED_SSID"
        echo "client_probed_ssid=$CLIENT_PROBED_SSID"
        echo "client_responded_ssid=$CLIENT_RESPONDED_SSID"
        echo "client_first_seen=$CLIENT_FIRST_SEEN"
    } > "$TMP_CUR"

    if [ -f "$LAST_FILE" ]; then
        while IFS='=' read -r key curval; do
            if key_ignored "$key"; then
                continue
            fi
            prevval=$(grep -m1 "^${key}=" "$LAST_FILE" | cut -d= -f2-)
            if [ "$curval" != "$prevval" ]; then
                CHANGE_COUNT=$((CHANGE_COUNT + 1))
                CHANGE_SUMMARY="${CHANGE_SUMMARY}${key}: '${prevval}' -> '${curval}'\n"
            fi
        done < "$TMP_CUR"
    fi

    mv "$TMP_CUR" "$LAST_FILE"

    if [ "$CHANGE_COUNT" -gt 0 ]; then
        printf '%b' "$CHANGE_SUMMARY" > "$CHANGE_FILE"
    fi
fi

# --------------------------------------------
# CLEANUP
# --------------------------------------------
if [ "$CLEANUP_DAYS" -gt 0 ] 2>/dev/null; then
    if has_cmd find; then
        find "$OUTPUT_DIR" -type f -mtime +"$CLEANUP_DAYS" \( -name "*.json" -o -name "*.env" -o -name "*.changes.txt" \) 2>/dev/null | xargs rm -f 2>/dev/null
    fi
fi

# --------------------------------------------
# UI SUMMARY
# --------------------------------------------
if [ "$HAS_AP" = true ]; then
    LOG blue "AP: ${AP_SSID:-<hidden>} (${AP_BSSID})"
    LOG "Ch ${AP_CHANNEL} | ${AP_ENCRYPTION} | RSSI ${AP_RSSI}"
fi

if [ "$HAS_CLIENT" = true ]; then
    LOG blue "Client: ${CLIENT_MAC}"
    LOG "RSSI ${CLIENT_RSSI} | Assoc ${CLIENT_ASSOC_BSSID}"
fi

LOG green "Report saved to: $OUTPUT_DIR"
if [ "$ENABLE_JSON" = true ]; then
    LOG "JSON: $(basename "$JSON_FILE")"
fi
if [ "$INCLUDE_ENV_DUMP" = true ]; then
    LOG "ENV: $(basename "$ENV_FILE")"
fi
if [ "$ENABLE_DIFF" = true ]; then
    if [ "$CHANGE_COUNT" -gt 0 ]; then
        LOG yellow "Changes detected: $CHANGE_COUNT"
        if [ "$ALERT_ON_CHANGES" = true ]; then
            ALERT "Recon changes detected: $CHANGE_COUNT\nSaved: $(basename "$CHANGE_FILE")"
        fi
    else
        LOG green "No changes detected"
    fi
fi

    if [ "$SAMPLE_INDEX" -lt "$SAMPLE_COUNT" ]; then
        sleep "$SAMPLE_INTERVAL"
    fi
    SAMPLE_INDEX=$((SAMPLE_INDEX + 1))
done

exit 0
