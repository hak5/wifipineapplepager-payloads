#!/bin/bash
# Title: The Nosey Neighbor
# Description: Passive recon payload — discovers APs, collects probed SSIDs,
#              identifies vendors, geo-tags with GPS, builds an intel report.
#              100% passive — no deauth, no mimic, no attacks.
# Author: curtthecoder - github.com/curthayman
# Version: 2.0

# ============================================================================
# CONFIGURATION
# ============================================================================
LOOT_BASE="/root/loot/nosey-neighbor"
MON_IFACE=""   # Auto-detected — leave empty
SCAN_IFACE=""  # Auto-detected — leave empty
RECON_DURATION=30
SSID_COLLECT_DURATION=45
PROBE_SNIFF_DURATION=30
ENABLE_GPS=true
ENABLE_VENDOR_LOOKUP=true # Why would you want to turn this off, but to each his/her/them own!
ENABLE_PCAP_SNAPSHOT=true # Same as the Vendor Lookup, why?
PCAP_DURATION=20
MAX_VENDOR_LOOKUPS=25
STOP_PROBE_COLLECT=false    # false = leave probe collection running after scan (default), I personally prefer this option because I keep "Collect Probes" on
                            # true  = stop probe collection when payload finishes

# --- v2.0: Advanced Intelligence ---
ENABLE_HISTORY=true               # Track runs over time (multi-run diff + returning device detection)
ENABLE_HIDDEN_CORRELATE=true      # Attempt to de-cloak hidden SSIDs via probe + OUI correlation
ENABLE_EXFIL=false                # Auto-send report via webhook when WiFi is available
EXFIL_WEBHOOK=""                  # Discord webhook URL (leave empty to skip)
EXFIL_NTFY_TOPIC=""               # ntfy.sh topic name for summary push (leave empty to skip)
EXFIL_SUMMARY_ONLY=false          # true = push summary stats only, false = attach full report file

# --- BLE Axon Detection (inspired by FuzzFinder - OSINTI4L and NyanBOX) ---
ENABLE_BLE_AXON_SCAN=true         # Scan for Axon body camera BLE advertisements before main recon
BLE_AXON_ATTEMPTS=3               # Number of scan attempts (each is 5s)

# ============================================================================
# SETUP
# ============================================================================
DATE_DIR=$(date +"%Y-%m-%d_%H%M%S")
TIMESTAMP=$(date +"%H%M%S")
LOOT_DIR="${LOOT_BASE}/${DATE_DIR}"
mkdir -p "$LOOT_DIR"

REPORT_FILE="$LOOT_DIR/report_${TIMESTAMP}.txt"
SSID_FILE="$LOOT_DIR/probed_ssids_${TIMESTAMP}.txt"
VENDOR_FILE="$LOOT_DIR/vendors_${TIMESTAMP}.txt"
PCAP_FILE="$LOOT_DIR/snapshot_${TIMESTAMP}.pcap"
GPS_FILE="$LOOT_DIR/gps_${TIMESTAMP}.txt"

# --- v2.0 persistent state files (live in LOOT_BASE across sessions) ---
LAST_AP_LIST="$LOOT_BASE/last_ap_list.txt"
LAST_CLIENT_LIST="$LOOT_BASE/last_client_list.txt"
LAST_RUN_INFO="$LOOT_BASE/last_run_info.txt"
KNOWN_CLIENTS_DB="$LOOT_BASE/known_clients.db"
MAC_PROBE_MAP="/tmp/nosey_mac_probe_${TIMESTAMP}.txt"
: > "$MAC_PROBE_MAP"

# ============================================================================
# BANNER
# ============================================================================
LED Y SOLID
VIBRATE 200 100 200

LOG "green" "========================================"
LOG "green" "  THE NOSEY NEIGHBOR!"
LOG "green" "  Passive Wireless Recon Toolkit"
LOG "green" "        by curtthecoder"
LOG "green" "========================================"
LOG ""
LOG "green" "  No attacks — just listening."
LOG ""

SCAN_START=$(date +%s)

EST_SECONDS=$((25 + 15 + SSID_COLLECT_DURATION + PCAP_DURATION + 30 + 20))
EST_MINUTES=$(( (EST_SECONDS + 59) / 60 ))

LOG "yellow" "[*] Estimated scan time: ~${EST_MINUTES} minutes"
LOG ""

# ============================================================================
# VERSION CHECK
# ============================================================================
CURRENT_VERSION="2.0"
VERSION_CHECK_URL="https://raw.githubusercontent.com/hak5/wifipineapplepager-payloads/master/library/user/reconnaissance/nosey-neighbor/VERSION"
ENABLE_UPDATE_CHECK=true

if [ "$ENABLE_UPDATE_CHECK" = true ]; then
    LOG "yellow" "[*] Checking for updates..."

    HTTP_RESPONSE=$(timeout 3 curl -s -w "\n%{http_code}" "$VERSION_CHECK_URL" 2>/dev/null)
    HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -1)
    LATEST_VERSION=$(echo "$HTTP_RESPONSE" | head -1 | tr -d '[:space:]')

    if [ "$HTTP_CODE" = "200" ] && [ -n "$LATEST_VERSION" ]; then
        if [ "$LATEST_VERSION" != "$CURRENT_VERSION" ]; then
            LOG ""
            LOG "green" "========================================================"
            LOG "green" "  UPDATE AVAILABLE!"
            LOG "green" "  Current: v${CURRENT_VERSION} -> Latest: v${LATEST_VERSION}"
            LOG "green" "  Update at: github.com/hak5/wifipineapplepager-payloads"
            LOG "========================================================"
            LOG ""
            sleep 3
        else
            LOG "    [OK] Running latest version (v${CURRENT_VERSION})"
        fi
    else
        LOG "    [OK] Running current version (v${CURRENT_VERSION})"
    fi
fi
LOG ""

# ============================================================================
# PRE-SCAN MENU  (firmware 1.0.8+)
# Interactive config before the scan kicks off. Toggle features, set duration.
# ============================================================================
__menu_active=true
while [ "$__menu_active" = "true" ]; do

    __lbl_ble="BLE Axon Scan: $([ "$ENABLE_BLE_AXON_SCAN" = "true" ] && echo ON || echo OFF)"
    __lbl_hist="History/Diff: $([ "$ENABLE_HISTORY" = "true" ] && echo ON || echo OFF)"
    __lbl_hidden="Hidden SSID: $([ "$ENABLE_HIDDEN_CORRELATE" = "true" ] && echo ON || echo OFF)"
    __lbl_exfil="Auto-Exfil: $([ "$ENABLE_EXFIL" = "true" ] && echo ON || echo OFF)"
    __lbl_dur="Recon: ${RECON_DURATION}s"

    __sel=$(LIST_PICKER "Nosey Neighbor v${CURRENT_VERSION}" \
        "Start Scan" \
        "$__lbl_dur" \
        "$__lbl_ble" \
        "$__lbl_hist" \
        "$__lbl_hidden" \
        "$__lbl_exfil" \
        "About" \
        "Exit" \
        "Start Scan")

    case "$__sel" in
        "Start Scan")
            __menu_active=false
            ;;

        "$__lbl_dur")
            __dur=$(LIST_PICKER "Recon Duration" \
                "Quick (15s)" \
                "Standard (30s)" \
                "Deep (60s)" \
                "Marathon (120s)" \
                "<- Back" \
                "Standard (30s)")
            case "$__dur" in
                "Quick (15s)")     RECON_DURATION=15  ;;
                "Standard (30s)")  RECON_DURATION=30  ;;
                "Deep (60s)")      RECON_DURATION=60  ;;
                "Marathon (120s)") RECON_DURATION=120 ;;
            esac
            unset __dur
            ;;

        "$__lbl_ble")
            [ "$ENABLE_BLE_AXON_SCAN" = "true" ] && ENABLE_BLE_AXON_SCAN=false || ENABLE_BLE_AXON_SCAN=true
            ;;

        "$__lbl_hist")
            [ "$ENABLE_HISTORY" = "true" ] && ENABLE_HISTORY=false || ENABLE_HISTORY=true
            ;;

        "$__lbl_hidden")
            [ "$ENABLE_HIDDEN_CORRELATE" = "true" ] && ENABLE_HIDDEN_CORRELATE=false || ENABLE_HIDDEN_CORRELATE=true
            ;;

        "$__lbl_exfil")
            [ "$ENABLE_EXFIL" = "true" ] && ENABLE_EXFIL=false || ENABLE_EXFIL=true
            ;;

        "About")
            LIST_PICKER "About" \
                "Nosey Neighbor v${CURRENT_VERSION}" \
                "Passive WiFi recon" \
                "by curtthecoder" \
                "github.com/curthayman" \
                "<- Back" \
                "<- Back"
            ;;

        "Exit")
            exit 0
            ;;

        *)
            # B button pressed — loop back to main menu
            ;;
    esac
done
unset __menu_active __sel __lbl_ble __lbl_hist __lbl_hidden __lbl_exfil __lbl_dur

printf "═══════════════════════════════════════════════════════════════\n" > "$REPORT_FILE"
printf "  THE NOSEY NEIGHBOR — Recon Report\n" >> "$REPORT_FILE"
printf "  Date: %s\n" "$(date)" >> "$REPORT_FILE"
printf "═══════════════════════════════════════════════════════════════\n\n" >> "$REPORT_FILE"

# ============================================================================
# PHASE 0.5: BLE AXON DEVICE SCAN
# Scans for Axon body camera BLE advertisements using known Axon OUI prefixes.
# Runs before main recon so the user is alerted immediately if one is nearby.
# Inspired by FuzzFinder (OSINTI4L) / NyanBOX (nyandevices.com)
# ============================================================================
AXON_DETECTED=false
AXON_SCAN_RESULT=""

if [ "$ENABLE_BLE_AXON_SCAN" = "true" ]; then
    LED R SOLID
    LOG "yellow" "[*] Scanning for Axon BLE devices..."

    _axon_attempt=0
    while [ "$_axon_attempt" -lt "$BLE_AXON_ATTEMPTS" ]; do
        _axon_attempt=$(( _axon_attempt + 1 ))
        BLE_RAW=$(timeout 5s hcitool lescan 2>/dev/null | grep -iE '00:25:DF|00:58:28|00:C0:D4|84:70:03')
        if [ -n "$BLE_RAW" ]; then
            AXON_DETECTED=true
            AXON_SCAN_RESULT="$BLE_RAW"
            break
        fi
        if [ "$_axon_attempt" -lt "$BLE_AXON_ATTEMPTS" ]; then
            LOG "green" "    No Axon devices detected. Re-scanning... (${_axon_attempt}/${BLE_AXON_ATTEMPTS})"
            sleep 1
        fi
    done

    if [ "$AXON_DETECTED" = "true" ]; then
        VIBRATE 500 100 500 100 500
        LOG "red" "  [!!!] AXON BODY CAMERA DETECTED!"
        LOG "red" "  $AXON_SCAN_RESULT"
        LOG ""
        __axon_resp=$(CONFIRMATION_DIALOG "Axon detected. Continue scan?") || exit 1
        [ "$__axon_resp" = "$DUCKYSCRIPT_USER_CONFIRMED" ] || exit 0
        unset __axon_resp
    else
        LOG "green" "    [OK] No Axon devices detected."
        LOG ""
    fi
fi

# ============================================================================
# PHASE 1: GPS LOCATION TAG
# ============================================================================
if [ "$ENABLE_GPS" = "true" ]; then
    LED B SOLID

    GPS_DATA=$(GPS_GET 2>/dev/null)

    # GPS_GET can return junk when no device is attached — validate coordinates
    GPS_VALID=false
    if [ -n "$GPS_DATA" ]; then
        if echo "$GPS_DATA" | grep -qE '[1-9][0-9]*\.[0-9]'; then
            STRIPPED=$(echo "$GPS_DATA" | tr -d '0., \t\n\r-')
            if [ -n "$STRIPPED" ]; then
                GPS_VALID=true
            fi
        fi
    fi

    if [ "$GPS_VALID" = "true" ]; then
        echo "$GPS_DATA" > "$GPS_FILE"
        printf "[GPS] Location acquired\n" >> "$REPORT_FILE"
        printf "%s\n\n" "$GPS_DATA" >> "$REPORT_FILE"
        LED G SOLID
        VIBRATE 100
        LOG "Nosey Neighbor: GPS fix acquired"
    else
        printf "[GPS] No fix available — skipping geo-tag\n" >> "$REPORT_FILE"
        printf "[GPS] (raw GPS_GET output: '%s')\n\n" "$GPS_DATA" >> "$REPORT_FILE"
        LED Y SOLID
        LOG "yellow" "[*] No GPS fix — skipping geo-tag"
    fi
else
    printf "[GPS] Disabled by configuration\n\n" >> "$REPORT_FILE"
fi

# ============================================================================
# PHASE 2: BATTERY & SYSTEM STATUS
# ============================================================================
LED B SOLID
BATTERY_LVL=$(BATTERY_PERCENT 2>/dev/null)
CHARGING=$(BATTERY_CHARGING 2>/dev/null)
DISK_FREE=$(df -h / 2>/dev/null | awk 'NR==2 {print $4}')
[ -z "$DISK_FREE" ] && DISK_FREE=$(USB_FREE 2>/dev/null)
UPTIME_STR=$(uptime 2>/dev/null)

printf "── SYSTEM STATUS ──────────────────────────────────────────────\n" >> "$REPORT_FILE"
printf "  Battery:  %s%%\n" "${BATTERY_LVL:-unknown}" >> "$REPORT_FILE"
printf "  Charging: %s\n" "${CHARGING:-unknown}" >> "$REPORT_FILE"
printf "  Storage:  %s free\n" "${DISK_FREE:-unknown}" >> "$REPORT_FILE"
printf "  Uptime:   %s\n\n" "${UPTIME_STR:-unknown}" >> "$REPORT_FILE"

# ============================================================================
# HISTORY LOAD  (v2.0 — read last session for multi-run diff)
# ============================================================================
LAST_RUN_DATE=""
LAST_AP_TOTAL=0
if [ "$ENABLE_HISTORY" = "true" ] && [ -f "$LAST_RUN_INFO" ]; then
    LAST_RUN_DATE=$(head -1 "$LAST_RUN_INFO" 2>/dev/null | tr -d '\n\r')
    LAST_AP_TOTAL=$(sed -n '2p' "$LAST_RUN_INFO" 2>/dev/null | tr -d ' \n\r')
    [ -z "$LAST_AP_TOTAL" ] && LAST_AP_TOTAL=0
fi

# ============================================================================
# PHASE 3: WIRELESS RECON SCAN
# ============================================================================
LED C SOLID
LOG "Nosey Neighbor: Starting recon scan"

AP_DB="/tmp/nosey_aps_${TIMESTAMP}.txt"
CLIENT_DB="/tmp/nosey_clients_${TIMESTAMP}.txt"
RAW_SCAN="/tmp/nosey_iwinfo_${TIMESTAMP}.txt"
DEBUG_LOG="$LOOT_DIR/debug_${TIMESTAMP}.txt"

: > "$AP_DB"
: > "$CLIENT_DB"
: > "$DEBUG_LOG"

printf "[DEBUG] === SYSTEM INFO ===\n" >> "$DEBUG_LOG"
printf "[DEBUG] Date: %s\n" "$(date)" >> "$DEBUG_LOG"
printf "[DEBUG] Kernel: %s\n" "$(uname -a 2>/dev/null)" >> "$DEBUG_LOG"
printf "\n" >> "$DEBUG_LOG"

printf "[DEBUG] === ALL INTERFACES (ip link) ===\n" >> "$DEBUG_LOG"
ip link show 2>/dev/null >> "$DEBUG_LOG"
printf "\n" >> "$DEBUG_LOG"

printf "[DEBUG] === ALL INTERFACES (ifconfig) ===\n" >> "$DEBUG_LOG"
ifconfig -a 2>/dev/null >> "$DEBUG_LOG"
printf "\n" >> "$DEBUG_LOG"

printf "[DEBUG] === WIRELESS INFO (iwinfo) ===\n" >> "$DEBUG_LOG"
iwinfo 2>/dev/null >> "$DEBUG_LOG"
printf "\n" >> "$DEBUG_LOG"

printf "[DEBUG] === WIRELESS DEVS (iw dev) ===\n" >> "$DEBUG_LOG"
iw dev 2>/dev/null >> "$DEBUG_LOG"
printf "\n" >> "$DEBUG_LOG"

printf "[DEBUG] === PHY LIST (iw phy) ===\n" >> "$DEBUG_LOG"
iw phy 2>/dev/null | head -30 >> "$DEBUG_LOG"
printf "\n" >> "$DEBUG_LOG"

printf "[DEBUG] === /sys/class/net contents ===\n" >> "$DEBUG_LOG"
ls -la /sys/class/net/ 2>/dev/null >> "$DEBUG_LOG"
printf "\n" >> "$DEBUG_LOG"

# Auto-detect monitor interface
if [ -z "$MON_IFACE" ]; then
    printf "[DEBUG] Auto-detecting monitor interface...\n" >> "$DEBUG_LOG"

    MON_IFACE=$(iw dev 2>/dev/null | awk '/Interface/{iface=$2} /type monitor/{print iface}' | head -1)
    printf "[DEBUG] iw dev monitor search: '%s'\n" "$MON_IFACE" >> "$DEBUG_LOG"

    if [ -z "$MON_IFACE" ]; then
        for IFACE in $(ls /sys/class/net/ 2>/dev/null); do
            MODE=$(iwinfo "$IFACE" info 2>/dev/null | grep -i "Mode:" | awk '{print $NF}')
            printf "[DEBUG] iwinfo %s mode: '%s'\n" "$IFACE" "$MODE" >> "$DEBUG_LOG"
            if echo "$MODE" | grep -qi "monitor"; then
                MON_IFACE="$IFACE"
                break
            fi
        done
    fi

    if [ -z "$MON_IFACE" ]; then
        for IFACE in wlan0mon wlan1mon mon0 mon1 phy0-mon0 phy1-mon0; do
            if [ -d "/sys/class/net/$IFACE" ]; then
                MON_IFACE="$IFACE"
                printf "[DEBUG] Found monitor iface by name: %s\n" "$MON_IFACE" >> "$DEBUG_LOG"
                break
            fi
        done
    fi

    if [ -z "$MON_IFACE" ]; then
        printf "[DEBUG] No monitor interface found, trying airmon-ng...\n" >> "$DEBUG_LOG"
        airmon-ng start wlan0 2>>"$DEBUG_LOG" >/dev/null
        airmon-ng start wlan1 2>>"$DEBUG_LOG" >/dev/null
        for IFACE in wlan0mon wlan1mon mon0; do
            if [ -d "/sys/class/net/$IFACE" ]; then
                MON_IFACE="$IFACE"
                printf "[DEBUG] Created monitor iface: %s\n" "$MON_IFACE" >> "$DEBUG_LOG"
                break
            fi
        done
    fi

    if [ -z "$MON_IFACE" ]; then
        printf "[DEBUG] WARNING: No monitor interface found or created!\n" >> "$DEBUG_LOG"
        MON_IFACE=$(ls /sys/class/net/ 2>/dev/null | grep -E '^wlan|^phy' | head -1)
        printf "[DEBUG] Last resort iface: '%s'\n" "$MON_IFACE" >> "$DEBUG_LOG"
    fi
fi

printf "[DEBUG] === FINAL MON_IFACE: '%s' ===\n" "$MON_IFACE" >> "$DEBUG_LOG"

# Auto-detect managed interface for active scanning
if [ -z "$SCAN_IFACE" ]; then
    for IFACE in $(ls /sys/class/net/ 2>/dev/null); do
        MODE=$(iwinfo "$IFACE" info 2>/dev/null | grep -i "Mode:")
        if echo "$MODE" | grep -qi "Master\|Client\|managed"; then
            SCAN_IFACE="$IFACE"
            printf "[DEBUG] Found managed iface: %s (%s)\n" "$IFACE" "$MODE" >> "$DEBUG_LOG"
            break
        fi
    done
fi

printf "[DEBUG] === FINAL SCAN_IFACE: '%s' ===\n" "$SCAN_IFACE" >> "$DEBUG_LOG"

[ -n "$MON_IFACE" ] && ip link set "$MON_IFACE" up 2>/dev/null
[ -n "$SCAN_IFACE" ] && ip link set "$SCAN_IFACE" up 2>/dev/null
for IFACE in $(ls /sys/class/net/ 2>/dev/null | grep -E '^wlan|^phy'); do
    ip link set "$IFACE" up 2>/dev/null
done
sleep 1

PINEAPPLE_SET_BANDS "both"
PINEAPPLE_RECON_NEW "$RECON_DURATION"

# Primary scan: tcpdump beacon sniff on monitor interface with channel hopping
if [ -n "$MON_IFACE" ] && [ -d "/sys/class/net/$MON_IFACE" ]; then
    printf "[DEBUG] Starting tcpdump beacon sniff on %s\n" "$MON_IFACE" >> "$DEBUG_LOG"

    (
        CHANNELS="1 2 3 4 5 6 7 8 9 10 11 36 40 44 48 52 56 60 64 100 104 108 112 116 120 124 128 132 136 140 144 149 153 157 161 165"
        while true; do
            for CH in $CHANNELS; do
                iw dev "$MON_IFACE" set channel "$CH" 2>/dev/null || \
                    iwconfig "$MON_IFACE" channel "$CH" 2>/dev/null
                sleep 0.4
            done
        done
    ) &
    CHANHOP_PID=$!
    sleep 1

    BEACON_RAW="/tmp/nosey_beacon_raw_${TIMESTAMP}.txt"
    timeout 25 tcpdump -i "$MON_IFACE" -e -l type mgt subtype beacon 2>/dev/null > "$BEACON_RAW"
    TCPDUMP_EXIT=$?

    kill "$CHANHOP_PID" 2>/dev/null
    wait "$CHANHOP_PID" 2>/dev/null

    printf "[DEBUG] tcpdump beacon exit code: %s\n" "$TCPDUMP_EXIT" >> "$DEBUG_LOG"
    printf "[DEBUG] tcpdump beacon raw lines: %s\n" "$(wc -l < "$BEACON_RAW" 2>/dev/null)" >> "$DEBUG_LOG"
    printf "[DEBUG] First 10 beacon lines:\n" >> "$DEBUG_LOG"
    head -10 "$BEACON_RAW" >> "$DEBUG_LOG" 2>/dev/null
    printf "\n" >> "$DEBUG_LOG"

    if [ -s "$BEACON_RAW" ]; then
        # Parse beacons into BSSID/SSID/CH/Signal/Enc, dedup by BSSID keeping strongest signal
        # Pager tcpdump -e format: BSSID:MAC as single token, signal as -NNdBm, channel in "CH: N"
        # BusyBox awk: no capture groups in match(), use index()+substr()
        # Never output empty tab fields — BusyBox ash read collapses consecutive tabs
        awk '{
            bssid = ""; ssid = ""; signal = ""; chan = ""; enc = ""

            for (i=1; i<=NF; i++) {
                if ($i ~ /^BSSID:[0-9a-fA-F]{2}:/) {
                    bssid = $i
                    sub(/^BSSID:/, "", bssid)
                    sub(/[^0-9a-fA-F:].*/, "", bssid)
                    break
                }
            }

            if (bssid == "" || bssid ~ /^ff:/) next
            if (bssid == "00:13:37:ad:a2:b8" || bssid == "02:13:37:ad:a2:b8") next
            if (bssid == "06:13:37:ad:a2:b8" || bssid == "00:13:37:ac:ff:34") next

            for (i=1; i<=NF; i++) {
                if ($i ~ /^-[0-9]+dBm$/) {
                    signal = $i
                    sub(/dBm$/, "", signal)
                    break
                }
            }

            s = $0
            idx = index(s, "Beacon (")
            if (idx == 0) idx = index(s, "beacon (")
            if (idx > 0) {
                s = substr(s, idx + 8)
                idx2 = index(s, ")")
                if (idx2 > 1) {
                    ssid = substr(s, 1, idx2 - 1)
                }
            }

            s = $0
            idx = index(s, "CH: ")
            if (idx > 0) {
                s = substr(s, idx + 4)
                sub(/[^0-9].*/, "", s)
                if (s != "") chan = s
            }

            # Fallback: derive channel from radiotap frequency for 5GHz APs lacking DS Parameter Set
            if (chan == "") {
                for (i=1; i<=NF; i++) {
                    if ($i ~ /^[0-9][0-9][0-9][0-9]$/ && $(i+1) == "MHz") {
                        freq = $i + 0
                        if (freq >= 2412 && freq <= 2484) {
                            if (freq == 2484) chan = 14
                            else chan = int((freq - 2407) / 5)
                        } else if (freq >= 5000 && freq <= 5900) {
                            chan = int((freq - 5000) / 5)
                        }
                        if (chan != "" && chan > 0) break
                        chan = ""
                    }
                }
            }

            if (index($0, "PRIVACY") > 0) enc = "Encrypted"

            if (ssid == "") ssid = "(hidden)"
            if (chan == "") chan = "-"
            if (signal == "") signal = "-"
            if (enc == "") enc = "Open"

            key = tolower(bssid)
            if (!(key in best_sig)) {
                best_sig[key] = signal
                best_ssid[key] = ssid
                best_chan[key] = chan
                best_enc[key] = enc
                best_bssid[key] = bssid
                order[++count] = key
            } else {
                if (best_ssid[key] == "(hidden)" && ssid != "(hidden)") {
                    best_ssid[key] = ssid
                }
                if (best_chan[key] == "-" && chan != "-") {
                    best_chan[key] = chan
                }
                if (signal != "-" && (best_sig[key] == "-" || signal + 0 > best_sig[key] + 0)) {
                    best_sig[key] = signal
                }
            }
        }
        END {
            for (i = 1; i <= count; i++) {
                k = order[i]
                printf "%s\t%s\t%s\t%s\t%s\n", best_bssid[k], best_ssid[k], best_chan[k], best_sig[k], best_enc[k]
            }
        }' "$BEACON_RAW" > "$AP_DB"

        printf "[DEBUG] Beacon sniff parsed AP count: %s\n" "$(wc -l < "$AP_DB")" >> "$DEBUG_LOG"
        printf "[DEBUG] First 5 beacon-parsed APs:\n" >> "$DEBUG_LOG"
        head -5 "$AP_DB" >> "$DEBUG_LOG" 2>/dev/null
        printf "\n" >> "$DEBUG_LOG"
    else
        printf "[DEBUG] tcpdump produced no output on %s\n" "$MON_IFACE" >> "$DEBUG_LOG"
    fi
    rm -f "$BEACON_RAW"
else
    printf "[DEBUG] No monitor interface available for tcpdump!\n" >> "$DEBUG_LOG"
fi

# Fallback: iwinfo scan
if [ ! -s "$AP_DB" ] && [ -n "$SCAN_IFACE" ]; then
    printf "[DEBUG] Beacon sniff empty, trying iwinfo scan on %s\n" "$SCAN_IFACE" >> "$DEBUG_LOG"

    iwinfo "$SCAN_IFACE" scan 2>>"$DEBUG_LOG" > "$RAW_SCAN"
    printf "[DEBUG] iwinfo scan exit code: %s, lines: %s\n" "$?" "$(wc -l < "$RAW_SCAN")" >> "$DEBUG_LOG"

    if [ ! -s "$RAW_SCAN" ]; then
        for IFACE in $(ls /sys/class/net/ 2>/dev/null | grep -E '^wlan|^phy'); do
            [ "$IFACE" = "$SCAN_IFACE" ] && continue
            ip link set "$IFACE" up 2>/dev/null
            sleep 1
            iwinfo "$IFACE" scan 2>/dev/null > "$RAW_SCAN"
            if [ -s "$RAW_SCAN" ]; then
                printf "[DEBUG] iwinfo scan succeeded on %s\n" "$IFACE" >> "$DEBUG_LOG"
                break
            fi
        done
    fi

    if [ -s "$RAW_SCAN" ]; then
        head -20 "$RAW_SCAN" >> "$DEBUG_LOG" 2>/dev/null
        printf "\n" >> "$DEBUG_LOG"

        awk '
        function emit() {
            if (bssid == "") return
            if (bssid == "00:13:37:AD:A2:B8" || bssid == "00:13:37:ad:a2:b8") return
            if (bssid == "02:13:37:AD:A2:B8" || bssid == "06:13:37:AD:A2:B8") return
            if (bssid == "00:13:37:AC:FF:34" || bssid == "00:13:37:ac:ff:34") return
            if (ssid == "") ssid = "(hidden)"
            if (chan == "") chan = "-"
            if (signal == "") signal = "-"
            if (enc == "") enc = "-"
            printf "%s\t%s\t%s\t%s\t%s\n", bssid, ssid, chan, signal, enc
        }
        /Address:/ {
            emit()
            bssid = $NF; ssid = ""; chan = ""; signal = ""; enc = ""
        }
        /ESSID:/ {
            s = $0
            sub(/.*ESSID: *"/, "", s)
            sub(/".*/, "", s)
            ssid = s
        }
        /Channel:/ {
            s = $0
            sub(/.*Channel: */, "", s)
            sub(/[^0-9].*/, "", s)
            if (s != "") chan = s
        }
        /Signal:/ {
            s = $0
            sub(/.*Signal: */, "", s)
            sub(/ .*/, "", s)
            if (s != "") signal = s
        }
        /Encryption:/ {
            s = $0
            sub(/.*Encryption: */, "", s)
            enc = s
        }
        END { emit() }
        ' "$RAW_SCAN" > "$AP_DB"

        printf "[DEBUG] iwinfo parsed AP count: %s\n" "$(wc -l < "$AP_DB")" >> "$DEBUG_LOG"
    fi
fi

# Fallback: iw scan
if [ ! -s "$AP_DB" ]; then
    printf "[DEBUG] Trying iw dev scan on all interfaces...\n" >> "$DEBUG_LOG"
    IW_SCAN="/tmp/nosey_iw_scan_${TIMESTAMP}.txt"

    for IFACE in $(ls /sys/class/net/ 2>/dev/null | grep -E '^wlan'); do
        ip link set "$IFACE" up 2>/dev/null
        sleep 1
        iw dev "$IFACE" scan 2>>"$DEBUG_LOG" > "$IW_SCAN"
        if [ -s "$IW_SCAN" ]; then
            printf "[DEBUG] iw scan succeeded on %s\n" "$IFACE" >> "$DEBUG_LOG"

            awk '
            function emit() {
                if (bssid == "") return
                if (ssid == "") ssid = "(hidden)"
                if (chan == "") chan = "-"
                if (signal == "") signal = "-"
                if (enc == "") enc = "-"
                printf "%s\t%s\t%s\t%s\t%s\n", bssid, ssid, chan, signal, enc
            }
            /^BSS / {
                emit()
                s = $2; sub(/\(.*/, "", s)
                bssid = s; ssid = ""; chan = ""; signal = ""; enc = ""
            }
            /SSID:/ { s = $0; sub(/.*SSID: */, "", s); if (s != "") ssid = s }
            /primary channel:/ || /DS Parameter set: channel/ {
                s = $0; sub(/.*: */, "", s); sub(/[^0-9].*/, "", s)
                if (s != "") chan = s
            }
            /signal:/ { s = $0; sub(/.*signal: */, "", s); sub(/ .*/, "", s); if (s != "") signal = s }
            /WPA:|RSN:|WEP/ { s = $0; sub(/.*\* /, "", s); if (enc == "") enc = s; else enc = enc " / " s }
            END { emit() }
            ' "$IW_SCAN" > "$AP_DB"

            printf "[DEBUG] iw scan parsed AP count: %s\n" "$(wc -l < "$AP_DB")" >> "$DEBUG_LOG"
            break
        fi
    done
    rm -f "$IW_SCAN"
fi

sleep 5

printf "[DEBUG] First 5 parsed AP lines:\n" >> "$DEBUG_LOG"
head -5 "$AP_DB" >> "$DEBUG_LOG" 2>/dev/null
printf "\n[DEBUG] Final AP_DB line count: %s\n" "$(wc -l < "$AP_DB" 2>/dev/null)" >> "$DEBUG_LOG"

# Sniff for client MACs on the monitor interface
CLIENT_RAW="/tmp/nosey_client_raw_${TIMESTAMP}.txt"
tcpdump -i "$MON_IFACE" -e -c 500 2>/dev/null > "$CLIENT_RAW"

grep -oE '(SA:|DA:|BSSID:)?([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' "$CLIENT_RAW" | \
    sed 's/^SA://;s/^DA://;s/^BSSID://' | \
    grep -v -i -E '^ff:ff:ff|^33:33:|^01:00:5e|^01:80:c2|^00:00:00' | \
    sort -u | while read -r CMAC; do
        [ -z "$CMAC" ] && continue
        case "$(echo "$CMAC" | tr 'A-F' 'a-f')" in
            00:13:37:ad:a2:b8|02:13:37:ad:a2:b8|06:13:37:ad:a2:b8) continue ;;
            00:13:37:ac:ff:34) continue ;;
        esac
        grep -qi "$CMAC" "$AP_DB" 2>/dev/null && continue

        ASSOC_BSSID="-"
        ASSOC_SSID="-"
        CLIENT_RSSI="-"

        CLIENT_LINES=$(grep -i "$CMAC" "$CLIENT_RAW")

        FOUND_BSSID=$(echo "$CLIENT_LINES" | \
            grep -oE '(BSSID:)?([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | \
            sed 's/^BSSID://' | \
            grep -v -i "$CMAC" | \
            grep -v -i -E '^ff:ff:ff|^33:33:|^01:00:5e' | \
            head -1)

        if [ -n "$FOUND_BSSID" ]; then
            AP_MATCH=$(grep -i "$FOUND_BSSID" "$AP_DB" 2>/dev/null | head -1)
            if [ -n "$AP_MATCH" ]; then
                ASSOC_BSSID="$FOUND_BSSID"
                ASSOC_SSID=$(echo "$AP_MATCH" | cut -f2)
                [ -z "$ASSOC_SSID" ] && ASSOC_SSID="-"
            fi
        fi

        CLIENT_RSSI=$(echo "$CLIENT_LINES" | \
            grep -oE '\-[0-9]+dBm' | \
            sed 's/dBm//' | \
            sort -n -r | head -1)
        [ -z "$CLIENT_RSSI" ] && CLIENT_RSSI="-"

        printf "%s\t%s\t%s\t%s\n" "$CMAC" "$ASSOC_BSSID" "$ASSOC_SSID" "$CLIENT_RSSI" >> "$CLIENT_DB"
    done

rm -f "$CLIENT_RAW"

VIBRATE 150 50 150

AP_COUNT=0
CLIENT_COUNT=0
[ -s "$AP_DB" ] && AP_COUNT=$(wc -l < "$AP_DB" | tr -d ' ')
[ -s "$CLIENT_DB" ] && CLIENT_COUNT=$(wc -l < "$CLIENT_DB" | tr -d ' ')

printf "[DEBUG] Final counts: %s APs, %s clients\n" "$AP_COUNT" "$CLIENT_COUNT" >> "$DEBUG_LOG"

printf "── WIRELESS LANDSCAPE ─────────────────────────────────────────\n" >> "$REPORT_FILE"
printf "  Access Points Found:  %s\n" "$AP_COUNT" >> "$REPORT_FILE"
printf "  Clients Found:        %s\n\n" "$CLIENT_COUNT" >> "$REPORT_FILE"

if [ "$AP_COUNT" -gt 0 ]; then
    printf "  ┌─ ACCESS POINTS ──────────────────────────────────────────\n" >> "$REPORT_FILE"
    printf "  │ %-18s %-28s %-4s %-5s %s\n" "BSSID" "SSID" "CH" "RSSI" "ENC" >> "$REPORT_FILE"
    printf "  │ %-18s %-28s %-4s %-5s %s\n" "──────────────────" "────────────────────────────" "──" "────" "───" >> "$REPORT_FILE"

    while IFS=$'\t' read -r BSSID SSID CHAN RSSI ENC; do
        [ -z "$BSSID" ] && continue
        SSID_DISPLAY="${SSID:-(hidden)}"
        printf "  │ %-18s %-28s %-4s %-5s %s\n" "$BSSID" "$SSID_DISPLAY" "$CHAN" "$RSSI" "$ENC" >> "$REPORT_FILE"
    done < "$AP_DB"

    printf "  └──────────────────────────────────────────────────────────\n\n" >> "$REPORT_FILE"

    printf "  ┌─ NETWORK SUMMARY ─────────────────────────────────────────\n" >> "$REPORT_FILE"
    printf "  │\n" >> "$REPORT_FILE"
    printf "  │  Modern routers broadcast multiple virtual networks (VAPs)\n" >> "$REPORT_FILE"
    printf "  │  across 2.4 GHz and 5 GHz bands. A single physical router\n" >> "$REPORT_FILE"
    printf "  │  can appear as 4-8 separate BSSIDs in a scan.\n" >> "$REPORT_FILE"
    printf "  │\n" >> "$REPORT_FILE"

    if [ -f "$AP_DB" ]; then
        awk -F'\t' '
        {
            bssid = $1; ssid = $2; chan = $3; rssi = $4; enc = $5

            band = "?"
            if (chan ~ /^[0-9]+$/) {
                ch = chan + 0
                if (ch >= 1 && ch <= 14) band = "2.4"
                else if (ch >= 36) band = "5"
            }

            if (ssid == "(hidden)") {
                hidden_count++
                oui = substr(bssid, 1, 13)
                hidden_oui[oui] = 1
                next
            }

            lssid = ssid
            gsub(/[A-Z]/, "\\&", lssid)
            is_isp = 0
            if (ssid == "xfinitywifi" || ssid == "Xfinity Mobile") is_isp = 1
            if (ssid == "CableWiFi" || ssid == "optimumwifi") is_isp = 1
            if (ssid ~ /^ATT-WiFi/ || ssid ~ /^Spectrum/) is_isp = 1

            key = ssid
            if (!(key in ssid_count)) {
                ssid_count[key] = 0
                ssid_best_rssi[key] = ""
                ssid_has_24[key] = 0
                ssid_has_5[key] = 0
                ssid_enc[key] = enc
                ssid_isp[key] = is_isp
                order[++idx] = key
            }
            ssid_count[key]++

            if (band == "2.4") ssid_has_24[key] = 1
            if (band == "5") ssid_has_5[key] = 1

            if (rssi != "-" && rssi ~ /^-[0-9]+$/) {
                if (ssid_best_rssi[key] == "" || rssi + 0 > ssid_best_rssi[key] + 0) {
                    ssid_best_rssi[key] = rssi
                }
            }

            oui = substr(bssid, 1, 13)
            seen_oui[oui] = 1
        }
        END {
            isp_count = 0
            private_count = 0
            for (i = 1; i <= idx; i++) {
                k = order[i]
                if (ssid_isp[k]) isp_count++
                else private_count++
            }

            phys = 0
            for (o in seen_oui) phys++
            for (o in hidden_oui) {
                if (!(o in seen_oui)) phys++
            }

            printf "  │  Total BSSIDs:           %d\n", NR
            printf "  │  Unique Named Networks:   %d\n", idx
            printf "  │  Hidden Networks:         %d\n", hidden_count
            printf "  │  ISP Hotspots:            %d\n", isp_count
            printf "  │  Private Networks:        %d\n", private_count
            printf "  │  Est. Physical Devices:   ~%d\n", phys
            printf "  │\n"

            if (private_count > 0) {
                printf "  │  PRIVATE NETWORKS\n"
                printf "  │  %-24s %6s  %-11s  %s\n", "SSID", "APs", "BANDS", "CLOSEST"
                printf "  │  %-24s %6s  %-11s  %s\n", "------------------------", "------", "-----------", "-------"
                for (i = 1; i <= idx; i++) {
                    k = order[i]
                    if (ssid_isp[k]) continue

                    bands = ""
                    if (ssid_has_24[k] && ssid_has_5[k]) bands = "2.4 + 5 GHz"
                    else if (ssid_has_24[k]) bands = "2.4 GHz"
                    else if (ssid_has_5[k]) bands = "5 GHz"
                    else bands = "Unknown"

                    r = ssid_best_rssi[k]
                    if (r == "") r = "-"

                    printf "  │  %-24s %4d    %-11s  %s dBm\n", k, ssid_count[k], bands, r
                }
                printf "  │\n"
            }

            if (isp_count > 0) {
                printf "  │  ISP HOTSPOTS (public networks from subscriber routers)\n"
                printf "  │  %-24s %6s  %-11s  %s\n", "SSID", "APs", "BANDS", "CLOSEST"
                printf "  │  %-24s %6s  %-11s  %s\n", "------------------------", "------", "-----------", "-------"
                for (i = 1; i <= idx; i++) {
                    k = order[i]
                    if (!ssid_isp[k]) continue

                    bands = ""
                    if (ssid_has_24[k] && ssid_has_5[k]) bands = "2.4 + 5 GHz"
                    else if (ssid_has_24[k]) bands = "2.4 GHz"
                    else if (ssid_has_5[k]) bands = "5 GHz"
                    else bands = "Unknown"

                    r = ssid_best_rssi[k]
                    if (r == "") r = "-"

                    printf "  │  %-24s %4d    %-11s  %s dBm\n", k, ssid_count[k], bands, r
                }
                printf "  │\n"
            }
        }' "$AP_DB" >> "$REPORT_FILE"
    fi

    printf "  └──────────────────────────────────────────────────────────\n\n" >> "$REPORT_FILE"

    printf "  ┌─ CHANNEL HEATMAP ────────────────────────────────────────\n" >> "$REPORT_FILE"
    if [ -f "$AP_DB" ]; then
        awk -F'\t' '{print $3}' "$AP_DB" | sort | uniq -c | sort -rn | while read -r COUNT CH; do
            [ -z "$CH" ] && continue
            BAR=""
            i=0
            while [ "$i" -lt "$COUNT" ]; do
                BAR="${BAR}█"
                i=$((i + 1))
            done
            printf "  │  CH %-3s [%2d] %s\n" "$CH" "$COUNT" "$BAR" >> "$REPORT_FILE"
        done
    fi
    printf "  └──────────────────────────────────────────────────────────\n\n" >> "$REPORT_FILE"

    printf "  ┌─ CHANNEL QUICK REFERENCE ────────────────────────────────\n" >> "$REPORT_FILE"
    printf "  │\n" >> "$REPORT_FILE"
    printf "  │  2.4 GHz Band (shorter range, more congested)\n" >> "$REPORT_FILE"
    printf "  │    CH 1-11      2412-2462 MHz    Standard WiFi channels\n" >> "$REPORT_FILE"
    printf "  │    CH 1, 6, 11  are non-overlapping (most common)\n" >> "$REPORT_FILE"
    printf "  │\n" >> "$REPORT_FILE"
    printf "  │  5 GHz Band (faster speeds, shorter range)\n" >> "$REPORT_FILE"
    printf "  │    U-NII-1      CH 36-48         5180-5240 MHz  Indoor\n" >> "$REPORT_FILE"
    printf "  │    U-NII-2      CH 52-64         5260-5320 MHz  DFS *\n" >> "$REPORT_FILE"
    printf "  │    U-NII-2C     CH 100-144       5500-5720 MHz  DFS *\n" >> "$REPORT_FILE"
    printf "  │    U-NII-3      CH 149-165       5745-5825 MHz  Outdoor\n" >> "$REPORT_FILE"
    printf "  │\n" >> "$REPORT_FILE"
    printf "  │  * DFS = Dynamic Frequency Selection (shared with radar).\n" >> "$REPORT_FILE"
    printf "  │    APs must detect radar and vacate. Fewer devices use\n" >> "$REPORT_FILE"
    printf "  │    DFS channels, so they tend to be less congested.\n" >> "$REPORT_FILE"
    printf "  │\n" >> "$REPORT_FILE"
    printf "  └──────────────────────────────────────────────────────────\n\n" >> "$REPORT_FILE"

    printf "  ┌─ RSSI QUICK REFERENCE ──────────────────────────────────\n" >> "$REPORT_FILE"
    printf "  │\n" >> "$REPORT_FILE"
    printf "  │  RSSI (Received Signal Strength Indicator) is measured\n" >> "$REPORT_FILE"
    printf "  │  in dBm. Values are negative — closer to 0 = stronger.\n" >> "$REPORT_FILE"
    printf "  │\n" >> "$REPORT_FILE"
    printf "  │    -30 to -40   Excellent    Right next to you\n" >> "$REPORT_FILE"
    printf "  │    -41 to -55   Very Good    Same room\n" >> "$REPORT_FILE"
    printf "  │    -56 to -67   Good         A few rooms away\n" >> "$REPORT_FILE"
    printf "  │    -68 to -75   Fair         Usable but weakening\n" >> "$REPORT_FILE"
    printf "  │    -76 to -85   Weak         Edge of range\n" >> "$REPORT_FILE"
    printf "  │    -86 to -95   Very Weak    Barely detectable\n" >> "$REPORT_FILE"
    printf "  │\n" >> "$REPORT_FILE"
    printf "  │  Applies to both AP and client signal readings.\n" >> "$REPORT_FILE"
    printf "  │  Walls, floors, and interference weaken signals.\n" >> "$REPORT_FILE"
    printf "  │\n" >> "$REPORT_FILE"
    printf "  └──────────────────────────────────────────────────────────\n\n" >> "$REPORT_FILE"

    printf "  ┌─ ENCRYPTION BREAKDOWN ───────────────────────────────────\n" >> "$REPORT_FILE"
    if [ -f "$AP_DB" ]; then
        awk -F'\t' '{print $5}' "$AP_DB" | sort | uniq -c | sort -rn | while read -r COUNT TYPE; do
            [ -z "$TYPE" ] && continue
            printf "  │  %-20s %d networks\n" "$TYPE" "$COUNT" >> "$REPORT_FILE"
        done
    fi
    printf "  └──────────────────────────────────────────────────────────\n\n" >> "$REPORT_FILE"
fi

LED G SOLID
LOG "Nosey Neighbor: Recon complete — $AP_COUNT APs, $CLIENT_COUNT clients"

# ============================================================================
# PHASE 3.5: INFRASTRUCTURE CLUSTERING  (v2.0)
# Group BSSIDs by OUI to reveal the physical hardware behind the BSSID flood.
# ============================================================================
if [ "$AP_COUNT" -gt 0 ] && [ -f "$AP_DB" ]; then
    CLUSTER_OUT=$(awk -F'\t' '
    {
        bssid = tolower($1); ssid = $2; chan = $3; rssi = $4
        oui = substr(bssid, 1, 8)

        if (!(oui in oui_count)) oui_order[++oui_idx] = oui
        oui_count[oui]++

        if (ssid != "(hidden)" && !(oui in oui_label)) oui_label[oui] = ssid

        if (!seen_ssid[oui, ssid]++) {
            oui_ssids[oui] = (oui_ssids[oui] == "") ? ssid : oui_ssids[oui] "|" ssid
        }

        if (chan ~ /^[0-9]+$/) {
            ch = chan + 0
            if (ch >= 1 && ch <= 14) oui_has24[oui] = 1
            else if (ch >= 36)       oui_has5[oui]  = 1
        }

        if (rssi ~ /^-[0-9]+$/) {
            r = rssi + 0
            if (!(oui in oui_rssi) || r > oui_rssi[oui]) oui_rssi[oui] = r
        }
    }
    END {
        found = 0
        for (i = 1; i <= oui_idx; i++) {
            if (oui_count[oui_order[i]] >= 2) { found++; break }
        }
        if (!found) exit

        printf "  ┌─ INFRASTRUCTURE CLUSTERS ────────────────────────────────\n"
        printf "  │\n"
        printf "  │  Every WiFi radio has a MAC address, and the first 3 bytes\n"
        printf "  │  (the OUI) identify the manufacturer. Routers, mesh nodes,\n"
        printf "  │  and gateways broadcast multiple SSIDs — each with its own\n"
        printf "  │  BSSID — but all sharing the same OUI. This section groups\n"
        printf "  │  those BSSIDs together so you can see the actual number of\n"
        printf "  │  physical devices rather than a flood of apparent networks.\n"
        printf "  │\n"
        printf "  │  The ↳ lines are additional SSIDs on the same hardware:\n"
        printf "  │    - Guest networks (e.g. MyNet_Guest alongside MyNetwork)\n"
        printf "  │    - ISP public hotspots (xfinitywifi on a subscriber router)\n"
        printf "  │    - Hidden VAPs (unnamed virtual access points)\n"
        printf "  │    - Band-specific SSIDs (same name, 2.4 vs 5 GHz radio)\n"
        printf "  │\n"
        printf "  │  APs = total BSSIDs seen from this hardware. CLOSEST is the\n"
        printf "  │  strongest signal across all its BSSIDs — i.e. how far away\n"
        printf "  │  the physical device is.\n"
        printf "  │\n"
        printf "  │  %-8s  %-24s  %4s  %-13s  %s\n", "OUI", "PRIMARY SSID", "APs", "BANDS", "CLOSEST"
        printf "  │  %-8s  %-24s  %4s  %-13s  %s\n", "────────", "────────────────────────", "────", "─────────────", "───────"

        for (i = 1; i <= oui_idx; i++) {
            oui = oui_order[i]
            if (oui_count[oui] < 2) continue

            label = (oui in oui_label) ? oui_label[oui] : "(all hidden)"
            if (length(label) > 24) label = substr(label, 1, 21) "..."

            bands = ""
            if      (oui_has24[oui] && oui_has5[oui]) bands = "2.4 + 5 GHz"
            else if (oui_has24[oui])                   bands = "2.4 GHz"
            else if (oui_has5[oui])                    bands = "5 GHz"
            else                                        bands = "unknown"

            rssi_str = (oui in oui_rssi) ? (oui_rssi[oui] " dBm") : "-"
            printf "  │  %-8s  %-24s  %4d  %-13s  %s\n", oui, label, oui_count[oui], bands, rssi_str

            n = split(oui_ssids[oui], slist, "|")
            for (j = 1; j <= n; j++) {
                if (slist[j] != label) printf "  │           ↳ %s\n", slist[j]
            }
        }
        printf "  └──────────────────────────────────────────────────────────\n\n"
    }' "$AP_DB")
    [ -n "$CLUSTER_OUT" ] && printf "%s\n" "$CLUSTER_OUT" >> "$REPORT_FILE"
fi

# ============================================================================
# PHASE 3.6: MULTI-RUN DIFF  (v2.0)
# Compare this session against the last saved session.
# ============================================================================
if [ "$ENABLE_HISTORY" = "true" ] && [ -f "$LAST_AP_LIST" ] && [ -n "$LAST_RUN_DATE" ] && [ -f "$AP_DB" ]; then
    printf "  ┌─ CHANGES SINCE LAST RUN ─────────────────────────────────\n" >> "$REPORT_FILE"
    printf "  │\n" >> "$REPORT_FILE"
    printf "  │  Each run saves a snapshot of visible APs and clients.\n" >> "$REPORT_FILE"
    printf "  │  This section diffs the current scan against that snapshot.\n" >> "$REPORT_FILE"
    printf "  │\n" >> "$REPORT_FILE"
    printf "  │  NEW APs  — BSSIDs visible now that weren't in the last run.\n" >> "$REPORT_FILE"
    printf "  │             Could be a device that arrived, or one that was\n" >> "$REPORT_FILE"
    printf "  │             just out of range / on a missed channel last time.\n" >> "$REPORT_FILE"
    printf "  │\n" >> "$REPORT_FILE"
    printf "  │  GONE APs — BSSIDs from the last run no longer visible now.\n" >> "$REPORT_FILE"
    printf "  │             Common causes:\n" >> "$REPORT_FILE"
    printf "  │               - Mobile hotspot or car that drove away\n" >> "$REPORT_FILE"
    printf "  │               - Weak edge-of-range AP that flickered out\n" >> "$REPORT_FILE"
    printf "  │               - Channel-hop timing miss on a specific BSSID\n" >> "$REPORT_FILE"
    printf "  │             If a BSSID keeps bouncing NEW/GONE across runs,\n" >> "$REPORT_FILE"
    printf "  │             it is at the edge of your detection range.\n" >> "$REPORT_FILE"
    printf "  │             If it stays gone, someone left or powered down.\n" >> "$REPORT_FILE"
    printf "  │\n" >> "$REPORT_FILE"
    printf "  │  Last run: %s\n" "$LAST_RUN_DATE" >> "$REPORT_FILE"
    printf "  │\n" >> "$REPORT_FILE"

    CURR_AP_SNAP="/tmp/nosey_curr_snap_${TIMESTAMP}.txt"
    awk -F'\t' '{printf "%s\t%s\n", tolower($1), $2}' "$AP_DB" | sort > "$CURR_AP_SNAP"

    NEW_APS_FILE="/tmp/nosey_new_aps_${TIMESTAMP}.txt"
    GONE_APS_FILE="/tmp/nosey_gone_aps_${TIMESTAMP}.txt"

    awk -F'\t' 'NR==FNR{seen[$1]=1; next} !($1 in seen){print}' \
        "$LAST_AP_LIST" "$CURR_AP_SNAP" > "$NEW_APS_FILE"
    awk -F'\t' 'NR==FNR{seen[$1]=1; next} !($1 in seen){print}' \
        "$CURR_AP_SNAP" "$LAST_AP_LIST" > "$GONE_APS_FILE"

    NEW_AP_DIFF=$(wc -l < "$NEW_APS_FILE" | tr -d ' ')
    GONE_AP_DIFF=$(wc -l < "$GONE_APS_FILE" | tr -d ' ')
    [ -z "$NEW_AP_DIFF" ] && NEW_AP_DIFF=0
    [ -z "$GONE_AP_DIFF" ] && GONE_AP_DIFF=0

    NEW_CLI_DIFF=0
    if [ -f "$LAST_CLIENT_LIST" ] && [ -f "$CLIENT_DB" ]; then
        CURR_CLI_SNAP="/tmp/nosey_curr_cli_${TIMESTAMP}.txt"
        awk -F'\t' '{print tolower($1)}' "$CLIENT_DB" | sort > "$CURR_CLI_SNAP"
        NEW_CLI_DIFF=$(awk 'NR==FNR{seen[$1]=1; next} !($1 in seen){print}' \
            "$LAST_CLIENT_LIST" "$CURR_CLI_SNAP" | wc -l | tr -d ' ')
        [ -z "$NEW_CLI_DIFF" ] && NEW_CLI_DIFF=0
        rm -f "$CURR_CLI_SNAP"
    fi

    if [ "$NEW_AP_DIFF" -gt 0 ]; then
        printf "  │  NEW APs (+%s):\n" "$NEW_AP_DIFF" >> "$REPORT_FILE"
        while IFS=$'\t' read -r DBSSID DSSID; do
            [ -z "$DBSSID" ] && continue
            DSSID="${DSSID:-(hidden)}"
            printf "  │    + %-18s %s\n" "$DBSSID" "$DSSID" >> "$REPORT_FILE"
        done < "$NEW_APS_FILE"
        printf "  │\n" >> "$REPORT_FILE"
    fi

    if [ "$GONE_AP_DIFF" -gt 0 ]; then
        printf "  │  GONE APs (-%s):\n" "$GONE_AP_DIFF" >> "$REPORT_FILE"
        while IFS=$'\t' read -r DBSSID DSSID; do
            [ -z "$DBSSID" ] && continue
            DSSID="${DSSID:-(hidden)}"
            printf "  │    - %-18s %s\n" "$DBSSID" "$DSSID" >> "$REPORT_FILE"
        done < "$GONE_APS_FILE"
        printf "  │\n" >> "$REPORT_FILE"
    fi

    [ "$NEW_CLI_DIFF" -gt 0 ] && printf "  │  NEW Clients: +%s\n  │\n" "$NEW_CLI_DIFF" >> "$REPORT_FILE"

    if [ "$NEW_AP_DIFF" -eq 0 ] && [ "$GONE_AP_DIFF" -eq 0 ] && [ "$NEW_CLI_DIFF" -eq 0 ]; then
        printf "  │  No changes detected since last run.\n" >> "$REPORT_FILE"
    fi

    printf "  └──────────────────────────────────────────────────────────\n\n" >> "$REPORT_FILE"

    rm -f "$CURR_AP_SNAP" "$NEW_APS_FILE" "$GONE_APS_FILE"
fi

# ============================================================================
# PHASE 4: PROBED SSID COLLECTION
# ============================================================================
LED M SOLID
LOG "Nosey Neighbor: Collecting probed SSIDs"

# Snapshot pool before collection so we can diff for new-this-session SSIDs
POOL_BEFORE_FILE="/tmp/nosey_pool_before_${TIMESTAMP}.txt"
POOL_BEFORE_RAW=$(PINEAPPLE_SSID_POOL_LIST 2>/dev/null)
echo "$POOL_BEFORE_RAW" | grep -v -i -E 'oui|[Uu]nknown|^$|^-|^=|^#|[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:' | \
    awk '{gsub(/[^[:print:]]/, ""); if (length > 0) print}' | \
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk 'length > 0' | \
    awk '!seen[tolower($0)]++' > "$POOL_BEFORE_FILE"
POOL_BEFORE_COUNT=$(wc -l < "$POOL_BEFORE_FILE" | tr -d ' ')
printf "[DEBUG] Pool snapshot before collection: %s SSIDs\n" "$POOL_BEFORE_COUNT" >> "$DEBUG_LOG"

PINEAPPLE_SSID_POOL_COLLECT_START

(
    CHANNELS="1 2 3 4 5 6 7 8 9 10 11 36 40 44 48 149 153 157 161 165"
    while true; do
        for CH in $CHANNELS; do
            iw dev "$MON_IFACE" set channel "$CH" 2>/dev/null || \
                iwconfig "$MON_IFACE" channel "$CH" 2>/dev/null
            sleep 0.4
        done
    done
) &
PROBE_CHANHOP_PID=$!

PROBE_SIGNAL_RAW="/tmp/nosey_probe_signal_${TIMESTAMP}.txt"
timeout "$SSID_COLLECT_DURATION" tcpdump -i "$MON_IFACE" -e type mgt subtype probe-req 2>/dev/null > "$PROBE_SIGNAL_RAW" &
PROBE_SIG_PID=$!

sleep "$SSID_COLLECT_DURATION"

if [ "$STOP_PROBE_COLLECT" = "true" ]; then
    PINEAPPLE_SSID_POOL_COLLECT_STOP
fi
kill "$PROBE_SIG_PID" 2>/dev/null
wait "$PROBE_SIG_PID" 2>/dev/null
kill "$PROBE_CHANHOP_PID" 2>/dev/null
wait "$PROBE_CHANHOP_PID" 2>/dev/null

sleep 2

POOL_RAW=$(PINEAPPLE_SSID_POOL_LIST 2>/dev/null)

printf "[DEBUG] Raw PINEAPPLE_SSID_POOL_LIST output:\n%s\n" "$POOL_RAW" >> "$DEBUG_LOG"

POOL_LIST=$(echo "$POOL_RAW" | grep -v -i -E 'oui|[Uu]nknown|^$|^-|^=|^#|[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
POOL_LIST=$(echo "$POOL_LIST" | awk 'length > 0')

printf "[DEBUG] Filtered pool list:\n%s\n" "$POOL_LIST" >> "$DEBUG_LOG"

# Build SSID-to-signal mapping from tcpdump probe captures
SIGNAL_MAP="/tmp/nosey_signal_map_${TIMESTAMP}.txt"
: > "$SIGNAL_MAP"

if [ -s "$PROBE_SIGNAL_RAW" ]; then
    printf "[DEBUG] First 5 probe signal lines:\n" >> "$DEBUG_LOG"
    head -5 "$PROBE_SIGNAL_RAW" >> "$DEBUG_LOG"
    printf "\n" >> "$DEBUG_LOG"

    awk '{
        signal = ""
        ssid = ""
        for (i=1; i<=NF; i++) {
            if ($i ~ /^-[0-9]+dBm$/) {
                sub(/dBm/, "", $i)
                signal = $i
            }
            if ($i ~ /^-[0-9]+dB$/) {
                sub(/dB/, "", $i)
                signal = $i
            }
        }
        if (match($0, /[Pp]robe [Rr]equest \([^)]+\)/)) {
            s = $0
            sub(/.*[Pp]robe [Rr]equest \(/, "", s)
            sub(/\).*/, "", s)
            ssid = s
        }
        if (ssid != "" && signal != "" && ssid !~ /^Broadcast$|^wildcard/) {
            print ssid "\t" signal
        }
    }' "$PROBE_SIGNAL_RAW" | \
    awk -F'\t' '{
        key = tolower($1)
        if (!(key in best) || $2 > best[key]) {
            best[key] = $2
            name[key] = $1
        }
    }
    END {
        for (k in best) print name[k] "\t" best[k]
    }' > "$SIGNAL_MAP"

    printf "[DEBUG] Signal map entries: %s\n" "$(wc -l < "$SIGNAL_MAP")" >> "$DEBUG_LOG"
fi

# Build MAC → probed-SSID map for hidden SSID correlation (v2.0)
if [ -s "$PROBE_SIGNAL_RAW" ]; then
    awk '{
        src_mac = ""
        ssid = ""

        for (i = 1; i <= NF; i++) {
            f = $i
            if (index(f, "SA:") == 1 && length(f) == 20) {
                src_mac = tolower(substr(f, 4))
                break
            }
        }
        if (src_mac == "") {
            for (i = 2; i <= NF; i++) {
                if ($i == ">") {
                    cand = $(i-1)
                    if (cand ~ /^[0-9a-fA-F]{2}:/) {
                        src_mac = tolower(cand)
                        break
                    }
                }
            }
        }

        s = $0
        idx = index(s, "Probe Request (")
        if (idx == 0) idx = index(s, "probe request (")
        if (idx > 0) {
            s = substr(s, idx + 15)
            idx2 = index(s, ")")
            if (idx2 > 1) ssid = substr(s, 1, idx2 - 1)
        }

        if (src_mac != "" && ssid != "" && ssid != "Broadcast" && ssid !~ /wildcard/ && length(ssid) > 0) {
            key = src_mac "\t" ssid
            if (!seen[key]++) print key
        }
    }' "$PROBE_SIGNAL_RAW" >> "$MAC_PROBE_MAP"
    printf "[DEBUG] MAC probe map entries: %s\n" "$(wc -l < "$MAC_PROBE_MAP")" >> "$DEBUG_LOG"
fi

PROBED_COUNT=0
: > "$SSID_FILE"

if [ -n "$POOL_LIST" ]; then
    echo "$POOL_LIST" >> "$SSID_FILE"
    printf "[DEBUG] PineAP pool collected SSIDs after filtering\n" >> "$DEBUG_LOG"
else
    printf "[DEBUG] PineAP pool empty, extracting from tcpdump probes\n" >> "$DEBUG_LOG"
    if [ -s "$SIGNAL_MAP" ]; then
        awk -F'\t' '{print $1}' "$SIGNAL_MAP" >> "$SSID_FILE"
    fi
fi

if [ -s "$SSID_FILE" ]; then
    grep -v -i -E 'oui|[Uu]nknown|^$|^[[:space:]]*$|[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:' "$SSID_FILE" | \
        awk '{gsub(/[^[:print:]]/, ""); if (length > 0) print}' | \
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
        awk 'length > 0' | \
        sort -f -u | awk '!seen[tolower($0)]++' > "${SSID_FILE}.clean"
    mv "${SSID_FILE}.clean" "$SSID_FILE"
    PROBED_COUNT=$(wc -l < "$SSID_FILE" | tr -d ' ')
else
    PROBED_COUNT=0
fi
POOL_LIST=$(cat "$SSID_FILE" 2>/dev/null)

# Diff against pre-scan snapshot to find new-this-session SSIDs
NEW_SSID_FILE="/tmp/nosey_new_ssids_${TIMESTAMP}.txt"
: > "$NEW_SSID_FILE"

if [ -s "$SSID_FILE" ] && [ -s "$POOL_BEFORE_FILE" ]; then
    while IFS= read -r SSID_LINE; do
        [ -z "$SSID_LINE" ] && continue
        if ! grep -qiFx "$SSID_LINE" "$POOL_BEFORE_FILE"; then
            echo "$SSID_LINE" >> "$NEW_SSID_FILE"
        fi
    done < "$SSID_FILE"
elif [ -s "$SSID_FILE" ]; then
    cp "$SSID_FILE" "$NEW_SSID_FILE"
fi

NEW_SSID_COUNT=$(wc -l < "$NEW_SSID_FILE" 2>/dev/null | tr -d ' ')
[ -z "$NEW_SSID_COUNT" ] && NEW_SSID_COUNT=0

printf "[DEBUG] New SSIDs this session: %s (total pool: %s)\n" "$NEW_SSID_COUNT" "$PROBED_COUNT" >> "$DEBUG_LOG"

# Restructure probed SSID file: new this session first, then previously collected
SSID_STRUCTURED="${SSID_FILE}.structured"
: > "$SSID_STRUCTURED"
if [ "$NEW_SSID_COUNT" -gt 0 ]; then
    printf "# NEW THIS SESSION (%s)\n" "$NEW_SSID_COUNT" >> "$SSID_STRUCTURED"
    cat "$NEW_SSID_FILE" >> "$SSID_STRUCTURED"
    printf "\n" >> "$SSID_STRUCTURED"
fi
if [ -s "$POOL_BEFORE_FILE" ]; then
    PREV_SSID_COUNT=$(wc -l < "$POOL_BEFORE_FILE" | tr -d ' ')
    if [ "$PREV_SSID_COUNT" -gt 0 ]; then
        printf "# PREVIOUSLY COLLECTED (%s)\n" "$PREV_SSID_COUNT" >> "$SSID_STRUCTURED"
        cat "$POOL_BEFORE_FILE" >> "$SSID_STRUCTURED"
    fi
fi
[ -s "$SSID_STRUCTURED" ] && mv "$SSID_STRUCTURED" "$SSID_FILE" || rm -f "$SSID_STRUCTURED"

printf "── PROBED SSIDs (What devices are looking for) ────────────────\n" >> "$REPORT_FILE"
printf "  NEW this session:      %s\n" "$NEW_SSID_COUNT" >> "$REPORT_FILE"
printf "  Total in SSID pool:    %s\n\n" "$PROBED_COUNT" >> "$REPORT_FILE"

if [ "$PROBED_COUNT" -gt 0 ]; then
    printf "  These are NOT necessarily networks nearby. These are networks\n" >> "$REPORT_FILE"
    printf "  that nearby DEVICES are actively seeking via probe requests.\n" >> "$REPORT_FILE"
    printf "  When a device has WiFi enabled, it broadcasts the names of\n" >> "$REPORT_FILE"
    printf "  every saved network asking \"are you here?\" — even networks\n" >> "$REPORT_FILE"
    printf "  from home, work, hotels, coffee shops, etc.\n" >> "$REPORT_FILE"
    printf "  This reveals where people have been and what they connect to. Just being Nosey!\n\n" >> "$REPORT_FILE"
    printf "  Signal strength indicates how close the requesting device is.\n\n" >> "$REPORT_FILE"
fi

if [ "$NEW_SSID_COUNT" -gt 0 ]; then
    printf "  ┌─ NEW THIS SESSION ─────────────────────────────────────────\n" >> "$REPORT_FILE"

    IDX=1
    while IFS= read -r PROBED_SSID; do
        [ -z "$PROBED_SSID" ] && continue

        SIG=$(awk -F'\t' -v ssid="$PROBED_SSID" 'tolower($1) == tolower(ssid) {print $2}' "$SIGNAL_MAP" 2>/dev/null)

        if [ -n "$SIG" ]; then
            SIG_NUM=${SIG#-}
            if [ "$SIG_NUM" -le 40 ] 2>/dev/null; then
                DIST="~1-3m (right here)"
            elif [ "$SIG_NUM" -le 55 ] 2>/dev/null; then
                DIST="~3-8m (very close)"
            elif [ "$SIG_NUM" -le 67 ] 2>/dev/null; then
                DIST="~8-15m (nearby)"
            elif [ "$SIG_NUM" -le 75 ] 2>/dev/null; then
                DIST="~15-30m (in range)"
            elif [ "$SIG_NUM" -le 85 ] 2>/dev/null; then
                DIST="~30-50m (moderate)"
            else
                DIST="~50m+ (far)"
            fi
            printf "  │ %3d. %-35s [%sdBm] %s\n" "$IDX" "$PROBED_SSID" "$SIG" "$DIST" >> "$REPORT_FILE"
        else
            printf "  │ %3d. %s\n" "$IDX" "$PROBED_SSID" >> "$REPORT_FILE"
        fi

        IDX=$((IDX + 1))
    done < "$NEW_SSID_FILE"

    printf "  └──────────────────────────────────────────────────────────\n\n" >> "$REPORT_FILE"
elif [ "$PROBED_COUNT" -gt 0 ]; then
    printf "  No NEW SSIDs captured this session.\n"  >> "$REPORT_FILE"
    printf "  (All %s SSIDs below are from previous sessions)\n\n" "$PROBED_COUNT" >> "$REPORT_FILE"
fi

if [ -s "$POOL_BEFORE_FILE" ]; then
    PREV_COUNT=$(wc -l < "$POOL_BEFORE_FILE" | tr -d ' ')
    if [ "$PREV_COUNT" -gt 0 ]; then
        printf "  ┌─ PREVIOUSLY COLLECTED (%s SSIDs from earlier sessions) ──\n" "$PREV_COUNT" >> "$REPORT_FILE"

        IDX=1
        while IFS= read -r PREV_SSID; do
            [ -z "$PREV_SSID" ] && continue
            printf "  │ %3d. %s\n" "$IDX" "$PREV_SSID" >> "$REPORT_FILE"
            IDX=$((IDX + 1))
        done < "$POOL_BEFORE_FILE"

        printf "  └──────────────────────────────────────────────────────────\n\n" >> "$REPORT_FILE"
    fi
fi

rm -f "$PROBE_SIGNAL_RAW" "$SIGNAL_MAP"

VIBRATE 150 50 150
LOG "Nosey Neighbor: Collected $NEW_SSID_COUNT new SSIDs ($PROBED_COUNT total in pool)"

# ============================================================================
# PHASE 4.5: HIDDEN SSID CORRELATION  (v2.0)
# Two methods:
#   OUI match  — hidden BSSID shares OUI with a named BSSID in this scan
#   Client probe — a client associated to the hidden AP is probing for X
# ============================================================================
if [ "$ENABLE_HIDDEN_CORRELATE" = "true" ] && [ -f "$AP_DB" ]; then
    HIDDEN_AP_COUNT=$(awk -F'\t' '$2 == "(hidden)"' "$AP_DB" | wc -l | tr -d ' ')

    if [ "$HIDDEN_AP_COUNT" -gt 0 ]; then
        CORR_RESULTS="/tmp/nosey_corr_${TIMESTAMP}.txt"
        : > "$CORR_RESULTS"

        # Method 1: OUI-based correlation
        awk -F'\t' '
        {
            bssid = tolower($1); ssid = $2
            oui = substr(bssid, 1, 8)
            if (ssid != "(hidden)") {
                if (!(oui in oui_name)) oui_name[oui] = ssid
            } else {
                hidden_list[bssid] = oui
            }
        }
        END {
            for (hb in hidden_list) {
                oui = hidden_list[hb]
                if (oui in oui_name)
                    printf "%s\t%s\tMED\tOUI match\n", hb, oui_name[oui]
            }
        }' "$AP_DB" >> "$CORR_RESULTS"

        # Method 2: Client-probe correlation
        if [ -s "$MAC_PROBE_MAP" ] && [ -s "$CLIENT_DB" ]; then
            while IFS=$'\t' read -r CMAC CBSSID CSSID CRSSI; do
                [ -z "$CMAC" ] && continue
                [ -z "$CBSSID" ] && continue
                [ "$CBSSID" = "-" ] && continue
                IS_HIDDEN=$(awk -F'\t' -v b="$CBSSID" \
                    'tolower($1)==tolower(b) && $2=="(hidden)"{print "yes"; exit}' "$AP_DB")
                if [ "$IS_HIDDEN" = "yes" ]; then
                    CPROBE=$(awk -F'\t' -v mac="$(echo "$CMAC" | tr 'A-F' 'a-f')" \
                        'tolower($1)==mac{print $2; exit}' "$MAC_PROBE_MAP")
                    if [ -n "$CPROBE" ]; then
                        printf "%s\t%s\tHIGH\tclient probe\n" \
                            "$(echo "$CBSSID" | tr 'A-F' 'a-f')" "$CPROBE" >> "$CORR_RESULTS"
                    fi
                fi
            done < "$CLIENT_DB"
        fi

        # Dedup by BSSID — prefer HIGH over MED
        if [ -s "$CORR_RESULTS" ]; then
            awk -F'\t' '
            {
                bssid = $1; conf = $3
                if (conf == "HIGH") {
                    high_line[bssid] = $0
                } else if (!(bssid in high_line) && !(bssid in med_line)) {
                    med_line[bssid] = $0
                }
            }
            END {
                for (b in high_line) print high_line[b]
                for (b in med_line)  print med_line[b]
            }' "$CORR_RESULTS" > "${CORR_RESULTS}.dedup"
            mv "${CORR_RESULTS}.dedup" "$CORR_RESULTS"
            CORR_COUNT=$(wc -l < "$CORR_RESULTS" | tr -d ' ')
        else
            CORR_COUNT=0
        fi

        if [ "$CORR_COUNT" -gt 0 ]; then
            printf "  ┌─ HIDDEN SSID CORRELATION ─────────────────────────────────\n" >> "$REPORT_FILE"
            printf "  │\n" >> "$REPORT_FILE"
            printf "  │  Some routers broadcast with a hidden SSID — the network\n" >> "$REPORT_FILE"
            printf "  │  name is intentionally blank, so it won't show up in a\n" >> "$REPORT_FILE"
            printf "  │  normal WiFi scan. The owner thinks this adds security,\n" >> "$REPORT_FILE"
            printf "  │  but the BSSID (the radio's MAC address) is still visible\n" >> "$REPORT_FILE"
            printf "  │  in every beacon frame it broadcasts — so we can still\n" >> "$REPORT_FILE"
            printf "  │  see it. We just don't know the name.\n" >> "$REPORT_FILE"
            printf "  │\n" >> "$REPORT_FILE"
            printf "  │  This section attempts to figure out the hidden SSID name\n" >> "$REPORT_FILE"
            printf "  │  using two methods:\n" >> "$REPORT_FILE"
            printf "  │\n" >> "$REPORT_FILE"
            printf "  │  OUI match (MED) — The hidden BSSID shares its first 3\n" >> "$REPORT_FILE"
            printf "  │    MAC bytes (the OUI / manufacturer ID) with a named\n" >> "$REPORT_FILE"
            printf "  │    BSSID in this scan. Same hardware = likely same network.\n" >> "$REPORT_FILE"
            printf "  │    Example: a router broadcasting 'HomeNet' on one BSSID\n" >> "$REPORT_FILE"
            printf "  │    and hiding another BSSID — both share the same OUI.\n" >> "$REPORT_FILE"
            printf "  │\n" >> "$REPORT_FILE"
            printf "  │  Client probe (HIGH) — A device is actively connected to\n" >> "$REPORT_FILE"
            printf "  │    the hidden AP AND is sending probe requests for a named\n" >> "$REPORT_FILE"
            printf "  │    SSID. If a client is on the network, it knows the name.\n" >> "$REPORT_FILE"
            printf "  │\n" >> "$REPORT_FILE"
            printf "  │  CONF = confidence level. HIGH means a connected device\n" >> "$REPORT_FILE"
            printf "  │  confirmed the name. MED means it is a logical inference.\n" >> "$REPORT_FILE"
            printf "  │  These are educated guesses, not guarantees.\n" >> "$REPORT_FILE"
            printf "  │\n" >> "$REPORT_FILE"
            printf "  │  %-18s  %-24s  %-6s  %s\n" "HIDDEN BSSID" "PROBABLE SSID" "CONF" "METHOD" >> "$REPORT_FILE"
            printf "  │  %-18s  %-24s  %-6s  %s\n" "──────────────────" "────────────────────────" "──────" "──────────────" >> "$REPORT_FILE"
            while IFS=$'\t' read -r HBSSID PROBABLE CONF METHOD; do
                [ -z "$HBSSID" ] && continue
                PROBABLE_D=$(echo "$PROBABLE" | cut -c1-24)
                printf "  │  %-18s  %-24s  %-6s  %s\n" "$HBSSID" "$PROBABLE_D" "$CONF" "$METHOD" >> "$REPORT_FILE"
            done < "$CORR_RESULTS"
            printf "  └──────────────────────────────────────────────────────────\n\n" >> "$REPORT_FILE"
        fi

        rm -f "$CORR_RESULTS"
    fi
fi
rm -f "$MAC_PROBE_MAP"

# ============================================================================
# PHASE 5: VENDOR IDENTIFICATION
# ============================================================================
if [ "$ENABLE_VENDOR_LOOKUP" = "true" ]; then
    LED Y SOLID
    LOG "Nosey Neighbor: Running vendor lookups"

    printf "── DEVICE VENDOR IDENTIFICATION ───────────────────────────────\n" >> "$REPORT_FILE"
    printf "  %-18s  %s\n" "MAC ADDRESS" "VENDOR" >> "$REPORT_FILE"
    printf "  %-18s  %s\n" "──────────────────" "──────────────────────────────────" >> "$REPORT_FILE"

    ALL_MACS_FILE="/tmp/nosey_all_macs_${TIMESTAMP}.txt"
    : > "$ALL_MACS_FILE"

    [ -f "$AP_DB" ] && awk -F'\t' '{print $1}' "$AP_DB" >> "$ALL_MACS_FILE"
    [ -f "$CLIENT_DB" ] && awk -F'\t' '{print $1}' "$CLIENT_DB" >> "$ALL_MACS_FILE"

    UNIQUE_MACS=$(sort -u "$ALL_MACS_FILE" | head -n "$MAX_VENDOR_LOOKUPS")
    LOOKUP_COUNT=0
    VENDOR_TOTAL=0

    printf "[DEBUG] whoismac test with 08:B4:B1:2C:4A:F7:\n" >> "$DEBUG_LOG"
    whoismac -m "08:B4:B1:2C:4A:F7" >> "$DEBUG_LOG" 2>&1
    printf "\n" >> "$DEBUG_LOG"

    echo "$UNIQUE_MACS" | while read -r MAC_ADDR; do
        [ -z "$MAC_ADDR" ] && continue
        LOOKUP_COUNT=$((LOOKUP_COUNT + 1))

        VENDOR_TMP="/tmp/nosey_vendor_tmp"
        whoismac -m "$MAC_ADDR" > "$VENDOR_TMP" 2>&1
        printf "[DEBUG] whoismac -m %s returned:\n" "$MAC_ADDR" >> "$DEBUG_LOG"
        cat "$VENDOR_TMP" >> "$DEBUG_LOG"
        printf "\n" >> "$DEBUG_LOG"

        VENDOR=$(tail -n 1 "$VENDOR_TMP" | tr -d '\r\n')
        if [ -z "$VENDOR" ] || echo "$VENDOR" | grep -qi "oui\|unknown\|version\|^$"; then
            VENDOR=$(grep -v -i -E 'oui|unknown|version|^$|whoismac' "$VENDOR_TMP" | head -1 | tr -d '\r\n')
        fi
        [ -z "$VENDOR" ] && VENDOR="Unknown"
        rm -f "$VENDOR_TMP"

        # Strip "VENDOR: " prefix and "(UAA/LAA), unicast/multicast" suffix
        VENDOR=$(echo "$VENDOR" | sed 's/^VENDOR: *//;s/ *(UAA[^)]*) *,.*//;s/ *(LAA[^)]*) *,.*//;s/ *([Uu]nicast.*//')

        printf "  %-18s  %s\n" "$MAC_ADDR" "$VENDOR" >> "$REPORT_FILE"
        printf "%s\t%s\n" "$MAC_ADDR" "$VENDOR" >> "$VENDOR_FILE"

        sleep 0.5
    done

    printf "\n" >> "$REPORT_FILE"

    LOG "Nosey Neighbor: Vendor lookups complete"
fi

# ============================================================================
# CLIENT TABLE
# ============================================================================
if [ "$CLIENT_COUNT" -gt 0 ]; then
    printf "  ┌─ CLIENTS ──────────────────────────────────────────────────────────────────────\n" >> "$REPORT_FILE"
    printf "  │ %-18s %-18s %-20s %-5s  %s\n" "CLIENT MAC" "AP BSSID" "SSID" "RSSI" "VENDOR" >> "$REPORT_FILE"
    printf "  │ %-18s %-18s %-20s %-5s  %s\n" "──────────────────" "──────────────────" "────────────────────" "─────" "──────────────────────────" >> "$REPORT_FILE"

    while IFS=$'\t' read -r CMAC CBSSID CSSID CRSSI; do
        [ -z "$CMAC" ] && continue

        CVENDOR="-"
        if [ -f "$VENDOR_FILE" ]; then
            CVENDOR=$(awk -F'\t' -v mac="$CMAC" 'tolower($1) == tolower(mac) {print $2; exit}' "$VENDOR_FILE")
        fi

        if [ -z "$CVENDOR" ] || [ "$CVENDOR" = "-" ] || [ "$CVENDOR" = "Unknown" ]; then
            CVENDOR_TMP="/tmp/nosey_cvendor_tmp"
            whoismac -m "$CMAC" > "$CVENDOR_TMP" 2>/dev/null
            CVENDOR=$(grep -v -i -E 'oui|unknown|version|^$|whoismac' "$CVENDOR_TMP" | head -1 | tr -d '\r\n')
            [ -z "$CVENDOR" ] && CVENDOR=$(tail -n 1 "$CVENDOR_TMP" | tr -d '\r\n')
            rm -f "$CVENDOR_TMP"
            CVENDOR=$(echo "$CVENDOR" | sed 's/^VENDOR: *//;s/ *(UAA[^)]*) *,.*//;s/ *(LAA[^)]*) *,.*//;s/ *([Uu]nicast.*//')
        fi
        [ -z "$CVENDOR" ] && CVENDOR="-"

        if [ ${#CVENDOR} -gt 28 ]; then
            CVENDOR=$(echo "$CVENDOR" | cut -c1-25)
            CVENDOR="${CVENDOR}..."
        fi

        printf "  │ %-18s %-18s %-20s %-5s  %s\n" "$CMAC" "${CBSSID:--}" "${CSSID:--}" "$CRSSI" "$CVENDOR" >> "$REPORT_FILE"
    done < "$CLIENT_DB"

    printf "  └────────────────────────────────────────────────────────────────────────────────\n\n" >> "$REPORT_FILE"
fi

# ============================================================================
# PHASE 5.5: RETURNING DEVICE DETECTION  (v2.0)
# Cross-reference current clients against known_clients.db
# ============================================================================
if [ "$ENABLE_HISTORY" = "true" ] && [ -f "$CLIENT_DB" ] && [ "$CLIENT_COUNT" -gt 0 ]; then
    NOW_DATE=$(date "+%Y-%m-%d %H:%M")
    RET_FILE="/tmp/nosey_ret_${TIMESTAMP}.txt"
    NEW_FILE="/tmp/nosey_newdev_${TIMESTAMP}.txt"
    UPDATED_DB="/tmp/nosey_known_new_${TIMESTAMP}.txt"
    : > "$RET_FILE"
    : > "$NEW_FILE"
    [ -f "$KNOWN_CLIENTS_DB" ] && cp "$KNOWN_CLIENTS_DB" "$UPDATED_DB" || : > "$UPDATED_DB"

    while IFS=$'\t' read -r CMAC CBSSID CSSID CRSSI; do
        [ -z "$CMAC" ] && continue
        CMAC_LC=$(echo "$CMAC" | tr 'A-F' 'a-f')
        CSSID="${CSSID:--}"

        CVENDOR="-"
        if [ -f "$VENDOR_FILE" ]; then
            CVENDOR=$(awk -F'\t' -v mac="$CMAC_LC" \
                'tolower($1)==mac{print $2; exit}' "$VENDOR_FILE" 2>/dev/null)
        fi
        [ -z "$CVENDOR" ] && CVENDOR="-"

        DB_LINE=$(awk -F'\t' -v mac="$CMAC_LC" 'tolower($1)==mac{print; exit}' "$UPDATED_DB" 2>/dev/null)

        if [ -n "$DB_LINE" ]; then
            FIRST_SEEN=$(printf "%s" "$DB_LINE" | cut -f2)
            VISIT_COUNT=$(printf "%s" "$DB_LINE" | cut -f4)
            VISIT_COUNT=$((VISIT_COUNT + 1))
            awk -F'\t' -v mac="$CMAC_LC" 'tolower($1)!=mac' "$UPDATED_DB" > "${UPDATED_DB}.tmp"
            mv "${UPDATED_DB}.tmp" "$UPDATED_DB"
            printf "%s\t%s\t%s\t%s\n" "$CMAC_LC" "$FIRST_SEEN" "$NOW_DATE" "$VISIT_COUNT" >> "$UPDATED_DB"
            printf "%s\t%s\t%s\t%s\t%s\n" "$CMAC" "$CVENDOR" "$FIRST_SEEN" "$CSSID" "$VISIT_COUNT" >> "$RET_FILE"
        else
            printf "%s\t%s\t%s\t1\n" "$CMAC_LC" "$NOW_DATE" "$NOW_DATE" >> "$UPDATED_DB"
            printf "%s\t%s\t%s\n" "$CMAC" "$CVENDOR" "$CSSID" >> "$NEW_FILE"
        fi
    done < "$CLIENT_DB"

    mv "$UPDATED_DB" "$KNOWN_CLIENTS_DB"

    RET_COUNT=$(wc -l < "$RET_FILE" | tr -d ' ')
    NEW_DEV_COUNT=$(wc -l < "$NEW_FILE" | tr -d ' ')
    [ -z "$RET_COUNT" ] && RET_COUNT=0
    [ -z "$NEW_DEV_COUNT" ] && NEW_DEV_COUNT=0

    if [ "$RET_COUNT" -gt 0 ] || [ "$NEW_DEV_COUNT" -gt 0 ]; then
        printf "  ┌─ DEVICE HISTORY ─────────────────────────────────────────\n" >> "$REPORT_FILE"

        if [ "$RET_COUNT" -gt 0 ]; then
            printf "  │  RETURNING DEVICES (%s seen in previous sessions):\n" "$RET_COUNT" >> "$REPORT_FILE"
            printf "  │  %-18s  %-22s  %-14s  %s\n" "MAC" "VENDOR" "FIRST SEEN" "VISITS" >> "$REPORT_FILE"
            printf "  │  %-18s  %-22s  %-14s  %s\n" "──────────────────" "──────────────────────" "──────────────" "──────" >> "$REPORT_FILE"
            while IFS=$'\t' read -r RMAC RVENDOR RFIRST RSSID RVISITS; do
                [ -z "$RMAC" ] && continue
                [ ${#RVENDOR} -gt 22 ] && RVENDOR="$(echo "$RVENDOR" | cut -c1-19)..."
                printf "  │  %-18s  %-22s  %-14s  %s visits\n" "$RMAC" "${RVENDOR:--}" "$RFIRST" "${RVISITS:--}" >> "$REPORT_FILE"
            done < "$RET_FILE"
            printf "  │\n" >> "$REPORT_FILE"
        fi

        if [ "$NEW_DEV_COUNT" -gt 0 ]; then
            printf "  │  FIRST-TIME DEVICES (%s):\n" "$NEW_DEV_COUNT" >> "$REPORT_FILE"
            while IFS=$'\t' read -r NMAC NVENDOR NSSID; do
                [ -z "$NMAC" ] && continue
                [ ${#NVENDOR} -gt 22 ] && NVENDOR="$(echo "$NVENDOR" | cut -c1-19)..."
                printf "  │  %-18s  %-22s  %s\n" "$NMAC" "${NVENDOR:--}" "${NSSID:--}" >> "$REPORT_FILE"
            done < "$NEW_FILE"
        fi

        printf "  └──────────────────────────────────────────────────────────\n\n" >> "$REPORT_FILE"
    fi

    rm -f "$RET_FILE" "$NEW_FILE"
fi

# ============================================================================
# PHASE 6: TRAFFIC SNAPSHOT
# ============================================================================
if [ "$ENABLE_PCAP_SNAPSHOT" = "true" ]; then
    LED R SOLID
    LOG "Nosey Neighbor: Starting packet capture on ${MON_IFACE}"

    WIFI_PCAP_START "$PCAP_FILE" "$MON_IFACE" 2>/dev/null
    sleep 2

    if [ ! -f "$PCAP_FILE" ]; then
        printf "[DEBUG] WIFI_PCAP_START failed, using tcpdump -w fallback\n" >> "$DEBUG_LOG"
        tcpdump -i "$MON_IFACE" -w "$PCAP_FILE" 2>/dev/null &
        TCPDUMP_PCAP_PID=$!
        sleep "$PCAP_DURATION"
        kill "$TCPDUMP_PCAP_PID" 2>/dev/null
        wait "$TCPDUMP_PCAP_PID" 2>/dev/null
    else
        sleep "$((PCAP_DURATION - 2))"
        WIFI_PCAP_STOP 2>/dev/null
    fi

    if [ -f "$PCAP_FILE" ] && [ -s "$PCAP_FILE" ]; then
        PCAP_SIZE=$(du -h "$PCAP_FILE" 2>/dev/null | cut -f1)
        PKT_COUNT=$(tcpdump -r "$PCAP_FILE" 2>/dev/null | wc -l | tr -d ' ')

        printf "── TRAFFIC SNAPSHOT ───────────────────────────────────────────\n" >> "$REPORT_FILE"
        printf "  PCAP File:    %s\n" "$PCAP_FILE" >> "$REPORT_FILE"
        printf "  File Size:    %s\n" "$PCAP_SIZE" >> "$REPORT_FILE"
        printf "  Packets:      %s\n" "$PKT_COUNT" >> "$REPORT_FILE"
        printf "  Duration:     %ss\n\n" "$PCAP_DURATION" >> "$REPORT_FILE"

        printf "  ┌─ FRAME TYPE BREAKDOWN ───────────────────────────────────\n" >> "$REPORT_FILE"
        tcpdump -r "$PCAP_FILE" 2>/dev/null | awk '{
            type = "Other"
            if (/[Bb]eacon/)                    type = "Beacon"
            else if (/[Pp]robe [Rr]equest/)     type = "Probe Request"
            else if (/[Pp]robe [Rr]esponse/)    type = "Probe Response"
            else if (/[Dd]eauthentication/)     type = "Deauthentication"
            else if (/[Dd]isassociation/)       type = "Disassociation"
            else if (/[Aa]uthentication/)       type = "Authentication"
            else if (/[Aa]ssoc [Rr]equest/)     type = "Assoc Request"
            else if (/[Aa]ssoc [Rr]esponse/)    type = "Assoc Response"
            else if (/[Rr]eassoc/)              type = "Reassociation"
            else if (/[Aa]ction/)               type = "Action"
            else if (/[Aa][Cc][Kk]/)            type = "Acknowledgment"
            else if (/[Cc]lear-[Tt]o-[Ss]end/)  type = "Clear-to-Send"
            else if (/[Rr]equest-[Tt]o-[Ss]end/) type = "Request-to-Send"
            else if (/[Dd]ata/)                 type = "Data"
            else if (/[Nn]ull/)                 type = "Null Data"
            else if (/QoS/)                     type = "QoS Data"
            print type
        }' | sort | uniq -c | sort -rn | head -15 | while read -r CNT FTYPE; do
            printf "  │  %-30s %s frames\n" "$FTYPE" "$CNT" >> "$REPORT_FILE"
        done
        printf "  └──────────────────────────────────────────────────────────\n\n" >> "$REPORT_FILE"

        # --- Active Session Detection ---
        # Count Block Ack / RTS pairs between MACs. High count = sustained data session.
        # Streaming device OUIs (Roku, Fire TV, Apple TV, Chromecast, Samsung TV) flagged.
        # Uses SUBSEP for pair keys (BusyBox awk safe). MACs extracted via length/position
        # checks (no regex quantifiers). Writes directly to report to avoid IFS/tab issues.
        printf "  ┌─ ACTIVE SESSIONS ────────────────────────────────────────\n" >> "$REPORT_FILE"
        printf "  │  Pairs with sustained Block Ack / RTS activity — indicates\n" >> "$REPORT_FILE"
        printf "  │  active data sessions. Known streaming devices flagged.\n" >> "$REPORT_FILE"
        printf "  │  Note: MACs starting with 0a/0b/02/06 use randomization —\n" >> "$REPORT_FILE"
        printf "  │  vendor lookup will not resolve for those addresses.\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        PCAP_TMP="/tmp/nosey_pcap_tmp_${TIMESTAMP}.txt"
        tcpdump -r "$PCAP_FILE" -e 2>/dev/null > "$PCAP_TMP"
        awk -v report="$REPORT_FILE" -v threshold=15 '
        NR==FNR {
            tab = index($0, "\t")
            if (tab > 0) {
                bssid = substr($0, 1, tab - 1)
                rest = substr($0, tab + 1)
                tab2 = index(rest, "\t")
                ssid = (tab2 > 0) ? substr(rest, 1, tab2 - 1) : rest
                ap[tolower(bssid)] = ssid
            }
            next
        }
        BEGIN {
            soui["00:09:bf"]="Roku";  soui["08:05:81"]="Roku";  soui["b0:a7:37"]="Roku"
            soui["d4:e2:2f"]="Roku";  soui["ac:3a:7a"]="Roku";  soui["d8:31:34"]="Roku"
            soui["dc:3a:5e"]="Roku";  soui["cc:6d:a0"]="Roku";  soui["50:0e:bf"]="Roku"
            soui["40:b4:cd"]="Fire TV"; soui["74:75:48"]="Fire TV"; soui["84:d6:d0"]="Fire TV"
            soui["a0:02:dc"]="Fire TV"; soui["f0:27:2d"]="Fire TV"; soui["fc:65:de"]="Fire TV"
            soui["44:65:0d"]="Fire TV"; soui["68:54:fd"]="Fire TV"
            soui["7c:61:93"]="Apple TV"; soui["a8:60:b6"]="Apple TV"; soui["98:01:a7"]="Apple TV"
            soui["04:54:53"]="Apple TV"; soui["78:4f:43"]="Apple TV"; soui["3c:d0:f8"]="Apple TV"
            soui["f0:d1:a9"]="Apple TV"
            soui["6c:ad:f8"]="Chromecast"; soui["54:60:09"]="Chromecast"; soui["f4:f5:d8"]="Chromecast"
            soui["1c:f2:9a"]="Chromecast"; soui["48:d6:d5"]="Chromecast"; soui["e4:f0:42"]="Chromecast"
            soui["00:12:47"]="Samsung TV"; soui["8c:77:12"]="Samsung TV"; soui["14:c2:13"]="Samsung TV"
            soui["78:ab:bb"]="Samsung TV"; soui["f4:7b:5e"]="Samsung TV"
            soui["08:b4:b1"]="Google/Nest"; soui["d4:f5:47"]="Google/Nest"; soui["18:b4:30"]="Google/Nest"
            soui["64:16:66"]="Google/Nest"; soui["f4:f5:d8"]="Google/Nest"
            soui["34:f1:50"]="Google/Nest"; soui["08:97:98"]="Google/Nest"
            soui["e0:37:17"]="Vantiva (Cable Box)"
        }
        tolower($0) ~ /block ack|request-to-send/ {
            mac1 = ""; mac2 = ""
            for (i = 1; i <= NF; i++) {
                f = $i
                if (substr(f,1,3) == "RA:" || substr(f,1,3) == "TA:") f = substr(f,4)
                gsub(/[,);>]/, "", f)
                if (length(f) == 17 && substr(f,3,1) == ":" && substr(f,6,1) == ":" && \
                    substr(f,9,1) == ":" && substr(f,12,1) == ":" && substr(f,15,1) == ":") {
                    f = tolower(f)
                    if (mac1 == "") mac1 = f
                    else if (mac2 == "" && f != mac1) { mac2 = f; break }
                }
            }
            if (mac1 != "" && mac2 != "") {
                pair = (mac1 < mac2) ? mac1 SUBSEP mac2 : mac2 SUBSEP mac1
                cnt[pair]++
            }
        }
        END {
            found = 0
            for (pair in cnt) {
                if (cnt[pair] < threshold) continue
                split(pair, macs, SUBSEP)
                m1 = macs[1]; m2 = macs[2]
                oui1 = substr(m1,1,8); oui2 = substr(m2,1,8)
                dev = (oui1 in soui) ? soui[oui1] : (oui2 in soui) ? soui[oui2] : ""
                tag = (dev != "") ? "  [" dev "]" : ""
                ssid1 = (m1 in ap) ? " (" ap[m1] ")" : ""
                ssid2 = (m2 in ap) ? " (" ap[m2] ")" : ""
                printf "  │  %s%s  <->  %s%s%s\n", m1, ssid1, m2, ssid2, tag >> report
                printf "  │  %d frames — active data session\n  │\n", cnt[pair] >> report
                found++
            }
            if (found == 0) printf "  │  No sustained sessions detected in capture window.\n" >> report
        }' "$AP_DB" "$PCAP_TMP"
        rm -f "$PCAP_TMP"
        printf "  └──────────────────────────────────────────────────────────\n\n" >> "$REPORT_FILE"

        printf "  ┌─ WIRESHARK FILTER QUICK REFERENCE ───────────────────────\n" >> "$REPORT_FILE"
        printf "  │  Load your .pcap in Wireshark, paste a filter into the\n" >> "$REPORT_FILE"
        printf "  │  display filter bar, and press Enter to drill down.\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  File: %s\n" "$PCAP_FILE" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  -- MANAGEMENT FRAMES --\n" >> "$REPORT_FILE"
        printf "  │  All beacon frames:\n" >> "$REPORT_FILE"
        printf "  │    wlan.fc.type_subtype == 0x08\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  All probe requests + responses (requests may be sparse due to channel hop timing):\n" >> "$REPORT_FILE"
        printf "  │    wlan.fc.type_subtype == 0x04 || wlan.fc.type_subtype == 0x05\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  Probe requests from one specific device:\n" >> "$REPORT_FILE"
        printf "  │    wlan.fc.type_subtype == 0x04 && wlan.sa == \"aa:bb:cc:dd:ee:ff\"\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  Probe requests for a specific SSID:\n" >> "$REPORT_FILE"
        printf "  │    wlan.ssid == \"TargetNetworkName\"\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  Hidden SSID beacons (zero-length SSID field):\n" >> "$REPORT_FILE"
        printf "  │    wlan.fc.type_subtype == 0x08 && wlan.ssid == \"\"\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  Deauthentication frames (disconnection events):\n" >> "$REPORT_FILE"
        printf "  │    wlan.fc.type_subtype == 0x0c\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  Disassociation frames:\n" >> "$REPORT_FILE"
        printf "  │    wlan.fc.type_subtype == 0x0a\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  All management frames:\n" >> "$REPORT_FILE"
        printf "  │    wlan.fc.type == 0\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  -- FOCUS ON A SPECIFIC AP --\n" >> "$REPORT_FILE"
        printf "  │  All traffic involving one BSSID:\n" >> "$REPORT_FILE"
        printf "  │    wlan.bssid == \"aa:bb:cc:dd:ee:ff\"\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  Only data frames (actual traffic, not management):\n" >> "$REPORT_FILE"
        printf "  │    wlan.fc.type == 2 && wlan.bssid == \"aa:bb:cc:dd:ee:ff\"\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  -- DATA & CONTENT --\n" >> "$REPORT_FILE"
        printf "  │  All data frames (look for unencrypted content):\n" >> "$REPORT_FILE"
        printf "  │    wlan.fc.type == 2\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  Unencrypted (no WPA/WEP flag set) data frames:\n" >> "$REPORT_FILE"
        printf "  │    wlan.fc.type == 2 && !wlan.fc.protected\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  Traffic to/from a specific device (any role):\n" >> "$REPORT_FILE"
        printf "  │    wlan.addr == xx:xx:xx:xx:xx:xx\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  QoS data frames (active client data traffic):\n" >> "$REPORT_FILE"
        printf "  │    wlan.fc.type_subtype == 0x28\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  -- SIGNAL & CHANNEL --\n" >> "$REPORT_FILE"
        printf "  │  Filter by signal strength (e.g. stronger than -70 dBm):\n" >> "$REPORT_FILE"
        printf "  │    radiotap.dbm_antsignal > -70\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  Filter to a specific 2.4GHz channel (e.g. ch 6 = 2437 MHz):\n" >> "$REPORT_FILE"
        printf "  │    radiotap.channel.freq == 2437\n" >> "$REPORT_FILE"
        printf "  │\n" >> "$REPORT_FILE"
        printf "  │  Filter to a specific 5GHz channel (e.g. ch 36 = 5180 MHz):\n" >> "$REPORT_FILE"
        printf "  │    radiotap.channel.freq == 5180\n" >> "$REPORT_FILE"
        printf "  └──────────────────────────────────────────────────────────\n\n" >> "$REPORT_FILE"

        LOG "Nosey Neighbor: Captured $PKT_COUNT packets ($PCAP_SIZE)"
    else
        printf "── TRAFFIC SNAPSHOT ───────────────────────────────────────────\n" >> "$REPORT_FILE"
        printf "  Capture failed — no pcap file generated.\n\n" >> "$REPORT_FILE"
        printf "[DEBUG] PCAP file missing or empty after both methods\n" >> "$DEBUG_LOG"
        LOG "Nosey Neighbor: PCAP capture failed"
    fi
fi

# ============================================================================
# PHASE 7: SECURITY FINDINGS
# ============================================================================
printf "── SECURITY FINDINGS ──────────────────────────────────────────\n" >> "$REPORT_FILE"

OPEN_COUNT=0
if [ -f "$AP_DB" ]; then
    OPEN_NETS=$(awk -F'\t' '$5 ~ /[Oo]pen|[Nn]one|^$/' "$AP_DB")
    if [ -n "$OPEN_NETS" ]; then
        OPEN_COUNT=$(echo "$OPEN_NETS" | wc -l | tr -d ' ')
        printf "  [!] OPEN NETWORKS DETECTED: %d\n" "$OPEN_COUNT" >> "$REPORT_FILE"
        echo "$OPEN_NETS" | while IFS=$'\t' read -r BSSID SSID CHAN RSSI ENC; do
            printf "      -> %-28s (%s) CH:%s RSSI:%s\n" "${SSID:-(hidden)}" "$BSSID" "$CHAN" "$RSSI" >> "$REPORT_FILE"
        done
        printf "\n" >> "$REPORT_FILE"
    fi
fi

WEP_COUNT=0
if [ -f "$AP_DB" ]; then
    WEP_NETS=$(awk -F'\t' '$5 ~ /[Ww][Ee][Pp]/' "$AP_DB")
    if [ -n "$WEP_NETS" ]; then
        WEP_COUNT=$(echo "$WEP_NETS" | wc -l | tr -d ' ')
        printf "  [!] WEP NETWORKS DETECTED: %d (trivially crackable)\n" "$WEP_COUNT" >> "$REPORT_FILE"
        echo "$WEP_NETS" | while IFS=$'\t' read -r BSSID SSID CHAN RSSI ENC; do
            printf "      -> %-28s (%s) CH:%s\n" "${SSID:-(hidden)}" "$BSSID" "$CHAN" >> "$REPORT_FILE"
        done
        printf "\n" >> "$REPORT_FILE"
    fi
fi

if [ "$ENABLE_BLE_AXON_SCAN" = "true" ]; then
    if [ "$AXON_DETECTED" = "true" ]; then
        printf "  [!!!] AXON BODY CAMERA DETECTED (Bluetooth LE)\n" >> "$REPORT_FILE"
        printf "        Known Axon OUI detected in BLE advertisement scan.\n" >> "$REPORT_FILE"
        echo "$AXON_SCAN_RESULT" | while IFS= read -r _axon_line; do
            [ -n "$_axon_line" ] && printf "        %s\n" "$_axon_line" >> "$REPORT_FILE"
        done
        printf "\n" >> "$REPORT_FILE"
    else
        printf "  [OK] No Axon BLE devices detected.\n\n" >> "$REPORT_FILE"
    fi
fi

if [ "$OPEN_COUNT" -eq 0 ] && [ "$WEP_COUNT" -eq 0 ]; then
    printf "  No open or WEP networks found. Good neighborhood.\n\n" >> "$REPORT_FILE"
fi

# ============================================================================
# PHASE 8: INTELLIGENCE SUMMARY
# ============================================================================
printf "── INTELLIGENCE SUMMARY ──────────────────────────────────────\n" >> "$REPORT_FILE"
printf "\n" >> "$REPORT_FILE"

if [ -f "$AP_DB" ] && [ "$AP_COUNT" -gt 0 ]; then
    awk -F'\t' \
        -v ap_count="$AP_COUNT" \
        -v client_count="$CLIENT_COUNT" \
        -v probed_count="$PROBED_COUNT" \
        -v new_ssids="$NEW_SSID_COUNT" \
        -v open_count="$OPEN_COUNT" \
        -v wep_count="$WEP_COUNT" '
    BEGIN { best_rssi = -999; isp_count = 0; biz_keyword_count = 0; guest_ssid_count = 0 }
    {
        bssid=$1; ssid=$2; chan=$3; rssi=$4; enc=$5

        if (chan ~ /^[0-9]+$/) {
            ch = chan + 0
            if (ch >= 1 && ch <= 14) band24++
            else if (ch >= 36) band5++
        }

        if (ssid != "(hidden)" && ssid != "") {
            if (!(ssid in ssid_count)) order[++idx] = ssid
            ssid_count[ssid]++
        } else {
            hidden_count++
        }

        if (rssi ~ /^-[0-9]+$/) {
            r = rssi + 0
            if (r > best_rssi) { best_rssi = r; best_ssid_rssi = ssid }
            if (r >= -35) very_close++
        }

        # ISP-broadcast hotspots (strong residential signal)
        if (ssid ~ /xfinitywifi|CableWiFi|optimumwifi|ATT.WiFi|Spectrum.WiFi|CoxWiFi/) isp_count++

        # Commercial keyword detection in SSID
        ls = tolower(ssid)
        if (ls ~ /cafe|coffee|shop|store|hotel|motel|lobby|restaurant|diner|bakery|pizza|burger|grill|gym|fitness|church|school|library|hospital|clinic|office|salon|spa|laundry|market/) {
            biz_keyword_count++
        }

        # Guest/public/visitor SSID patterns
        if (ls ~ /guest|visitor|public|customer/) guest_ssid_count++

        # Car/phone hotspot detection
        if (ssid ~ /^BUICK|^CHEVY|^FORD[0-9_]|^GMC[0-9_]|^RAM[0-9]|^DODGE|^HONDA[0-9_]|^TOYOTA[0-9_]|^NISSAN[0-9_]|^HYUNDAI|^KIA[0-9]|^SUBARU|^MAZDA[0-9_]|^JEEP[0-9_]|^CHRYSLER|^TESLA/) {
            car_ssids[ssid] = 1
        }
        if (ssid ~ /^iPhone|^Android AP|^Galaxy.*Hotspot|^Pixel [0-9]/) {
            phone_ssids[ssid] = 1
        }
    }
    END {
        # Density label (AP count only)
        if      (ap_count >= 50) d_adj = "very high-density"
        else if (ap_count >= 25) d_adj = "high-density"
        else if (ap_count >= 15) d_adj = "medium-density"
        else if (ap_count >= 6)  d_adj = "low-density"
        else                     d_adj = "sparse"

        # Enterprise multi-SSID list (non-ISP, 3+ BSSIDs)
        biz_count = 0; biz_out = ""
        for (i = 1; i <= idx; i++) {
            s = order[i]
            is_isp = (s ~ /xfinitywifi|CableWiFi|optimumwifi|ATT.WiFi|Spectrum.WiFi|CoxWiFi/)
            if (ssid_count[s] >= 3 && !is_isp) {
                biz_count++
                biz_out = biz_out "    - \"" s "\" (" ssid_count[s] " BSSIDs)\n"
            }
        }

        # Client/AP and ISP ratios
        cap_ratio  = (ap_count > 0) ? client_count / ap_count : 0
        isp_ratio  = (ap_count > 0) ? isp_count    / ap_count : 0

        # --- Scoring ---
        comm_score = 0; res_score = 0

        # Commercial signals
        if      (biz_count >= 3)         comm_score += 2
        else if (biz_count >= 1)         comm_score += 1

        if      (biz_keyword_count >= 2) comm_score += 2
        else if (biz_keyword_count >= 1) comm_score += 1

        if      (guest_ssid_count >= 2)  comm_score += 2
        else if (guest_ssid_count >= 1)  comm_score += 1

        # High client/AP ratio = busy venue
        if      (cap_ratio >= 1.0) comm_score += 3
        else if (cap_ratio >= 0.5) comm_score += 2
        else if (cap_ratio >= 0.3) comm_score += 1

        # Residential signals
        # Many ISP hotspot BSSIDs = lots of Comcast/ATT subscribers = dense housing
        if      (isp_count >= 8) res_score += 3
        else if (isp_count >= 4) res_score += 2
        else if (isp_count >= 1) res_score += 1

        # Low client/AP ratio = people at home, not a busy venue
        if      (cap_ratio < 0.1) res_score += 2
        else if (cap_ratio < 0.2) res_score += 1

        # High ISP fraction of total APs = residential street
        if (isp_ratio >= 0.3) res_score += 1

        # --- Classify ---
        if (comm_score >= res_score + 3) {
            d_loc = "commercial or business area"
        } else if (res_score >= comm_score + 2) {
            if (d_adj == "very high-density" || d_adj == "high-density")
                d_loc = "residential area (apartment complex or urban housing)"
            else
                d_loc = "residential neighborhood"
        } else {
            d_loc = "mixed residential/commercial area"
        }

        printf "  AREA OVERVIEW\n"
        printf "  %d APs and %d clients indicate a %s %s.\n", ap_count, client_count, d_adj, d_loc
        if (band24 > 0 && band5 > 0)
            printf "  Dual-band environment: %d x 2.4 GHz, %d x 5 GHz BSSIDs.\n", band24, band5
        if (hidden_count > 0)
            printf "  %d hidden SSID(s) detected.\n", hidden_count
        if (isp_count > 0)
            printf "  %d ISP-broadcast hotspot BSSID(s) detected (Xfinity/AT&T/Spectrum/etc).\n", isp_count
        printf "\n"

        if (biz_count > 0) {
            printf "  DOMINANT INFRASTRUCTURE\n"
            printf "%s", biz_out
            if (biz_count == 1)
                printf "  Single enterprise deployment broadcasting multiple SSIDs per band.\n"
            else
                printf "  Multiple enterprise networks -- likely a commercial building or shared site.\n"
            printf "\n"
        }

        printf "  PROXIMITY\n"
        if (best_rssi > -999) {
            if      (best_rssi >= -35) plabel = "within a few meters"
            else if (best_rssi >= -55) plabel = "very close (same room)"
            else if (best_rssi >= -67) plabel = "nearby (~15m)"
            else if (best_rssi >= -75) plabel = "moderate range (~30m)"
            else                       plabel = "at range limit"
            printf "  Strongest AP: \"%s\" at %d dBm (%s).\n", best_ssid_rssi, best_rssi, plabel
        }
        if (very_close > 0)
            printf "  %d AP(s) at >-35 dBm -- within arm reach.\n", very_close
        printf "\n"

        car_n = 0; for (k in car_ssids) car_n++
        phone_n = 0; for (k in phone_ssids) phone_n++
        if (car_n + phone_n > 0) {
            printf "  NOTABLE DETECTIONS\n"
            for (k in car_ssids)  printf "  * Vehicle hotspot: \"%s\"\n", k
            for (k in phone_ssids) printf "  * Phone hotspot: \"%s\"\n", k
            printf "\n"
        }

        printf "  ACTIVITY LEVEL\n"
        if      (client_count >= 30) activity = "heavy foot traffic"
        else if (client_count >= 15) activity = "moderate activity"
        else if (client_count >= 5)  activity = "light activity"
        else                         activity = "minimal wireless clients"
        printf "  %d active clients -- %s.\n\n", client_count, activity

        if (probed_count > 0) {
            printf "  DEVICE HISTORY\n"
            printf "  %d probed SSIDs reveal nearby devices have previously\n", probed_count
            printf "  connected to home networks, workplaces, hotels, and hotspots.\n"
            if (new_ssids > 0)
                printf "  %d new SSID(s) captured this session.\n", new_ssids
            printf "\n"
        }

        printf "  SECURITY POSTURE\n"
        if (open_count == 0 && wep_count == 0) {
            printf "  All visible networks use modern encryption. Clean area.\n"
        } else {
            if (open_count > 0) {
                printf "  [!] %d open network(s) -- unencrypted traffic visible.\n", open_count
                if (isp_count > 0)
                    printf "      (Note: ISP hotspots like xfinitywifi are open by design -- not a local threat.)\n"
            }
            if (wep_count > 0) printf "  [!] %d WEP network(s) -- trivially crackable encryption.\n", wep_count
        }
        printf "\n"
    }' "$AP_DB" >> "$REPORT_FILE"
fi

# Vendor-based device profile
if [ "$ENABLE_VENDOR_LOOKUP" = "true" ] && [ -f "$VENDOR_FILE" ] && [ -s "$VENDOR_FILE" ]; then
    VENDOR_SUMMARY=$(awk -F'\t' '
    {
        v = tolower($2)
        if (v ~ /apple/) apple++
        if (v ~ /samsung/) samsung++
        if (v ~ /google/) google++
        if (v ~ /intel/) intel++
        if (v ~ /amazon|ring|ecobee|resideo|honeywell|nest|wyze|arlo/) iot++
        if (v ~ /vizio|sony|lg electronic|tcl|hisense/) av++
        if (v ~ /ubiquiti|ruckus|aruba|cisco/) infra++
        if (v ~ /dragino|particle|espressif|silicon lab|nordic semi/) devboard++
        if (v ~ /commscope|arris/) isp_hw++
    }
    END {
        if (apple)    printf "    Apple:              %d device(s)\n", apple
        if (samsung)  printf "    Samsung:            %d device(s)\n", samsung
        if (google)   printf "    Google:             %d device(s)\n", google
        if (intel)    printf "    Intel (PC/laptop):  %d device(s)\n", intel
        if (av)       printf "    Smart TV / AV:      %d device(s)\n", av
        if (iot)      printf "    Smart home / IoT:   %d device(s)\n", iot
        if (devboard) printf "    IoT dev boards:     %d device(s)\n", devboard
        if (isp_hw)   printf "    ISP hardware:       %d device(s)\n", isp_hw
        if (infra)    printf "    Network infra:      %d device(s)\n", infra
    }' "$VENDOR_FILE" 2>/dev/null)

    if [ -n "$VENDOR_SUMMARY" ]; then
        printf "  DEVICE PROFILE (by vendor category)\n" >> "$REPORT_FILE"
        printf "%s\n\n" "$VENDOR_SUMMARY" >> "$REPORT_FILE"
    fi
fi

printf "──────────────────────────────────────────────────────────────\n\n" >> "$REPORT_FILE"

# ============================================================================
# REPORT SUMMARY
# ============================================================================
SCAN_END=$(date +%s)
ELAPSED_SECONDS=$((SCAN_END - SCAN_START))
ELAPSED_MIN=$((ELAPSED_SECONDS / 60))
ELAPSED_SEC=$((ELAPSED_SECONDS % 60))
if [ "$ELAPSED_MIN" -gt 0 ]; then
    ELAPSED_DISPLAY="${ELAPSED_MIN}m ${ELAPSED_SEC}s"
else
    ELAPSED_DISPLAY="${ELAPSED_SEC}s"
fi

printf "═══════════════════════════════════════════════════════════════\n" >> "$REPORT_FILE"
printf "  SUMMARY\n" >> "$REPORT_FILE"
printf "═══════════════════════════════════════════════════════════════\n" >> "$REPORT_FILE"
printf "  Access Points:     %s\n" "$AP_COUNT" >> "$REPORT_FILE"
printf "  Clients:           %s\n" "$CLIENT_COUNT" >> "$REPORT_FILE"
printf "  Probed SSIDs:      %s new / %s total\n" "$NEW_SSID_COUNT" "$PROBED_COUNT" >> "$REPORT_FILE"
printf "  Open Networks:     %s\n" "$OPEN_COUNT" >> "$REPORT_FILE"
printf "  WEP Networks:      %s\n" "$WEP_COUNT" >> "$REPORT_FILE"
printf "  Scan Duration:     %s\n" "$ELAPSED_DISPLAY" >> "$REPORT_FILE"
printf "  Report:            %s\n" "$REPORT_FILE" >> "$REPORT_FILE"
printf "═══════════════════════════════════════════════════════════════\n" >> "$REPORT_FILE"

# ============================================================================
# PHASE 9: HISTORY SAVE  (v2.0)
# Persist this session's data for the next run's multi-run diff.
# ============================================================================
if [ "$ENABLE_HISTORY" = "true" ]; then
    if [ -f "$AP_DB" ] && [ "$AP_COUNT" -gt 0 ]; then
        awk -F'\t' '{printf "%s\t%s\n", tolower($1), $2}' "$AP_DB" | sort > "$LAST_AP_LIST"
    fi
    if [ -f "$CLIENT_DB" ] && [ "$CLIENT_COUNT" -gt 0 ]; then
        awk -F'\t' '{print tolower($1)}' "$CLIENT_DB" | sort > "$LAST_CLIENT_LIST"
    fi
    printf "%s\n%s\n" "$(date)" "$AP_COUNT" > "$LAST_RUN_INFO"
fi

# ============================================================================
# PHASE 10: AUTO-EXFIL  (v2.0)
# When WiFi is up, deliver the report to a webhook/push service.
# ============================================================================
if [ "$ENABLE_EXFIL" = "true" ] && [ -f "$REPORT_FILE" ]; then
    # wlan0cli is the Pager's WiFi client interface (connected to external network).
    # wlan0 is in AP mode and always has 172.16.42.1 — never use it as a connectivity check.
    WIFI_IP=$(ip addr show wlan0cli 2>/dev/null | awk '/inet /{gsub(/\/.*/, "", $2); print $2; exit}')

    printf "[DEBUG] EXFIL: wlan0cli IP='%s'\n" "$WIFI_IP" >> "$DEBUG_LOG"
    printf "[DEBUG] EXFIL: EXFIL_WEBHOOK='%s'\n" "${EXFIL_WEBHOOK:+(set)}" >> "$DEBUG_LOG"
    printf "[DEBUG] EXFIL: REPORT_FILE exists=%s size=%s\n" "$([ -f "$REPORT_FILE" ] && echo yes || echo no)" "$(wc -c < "$REPORT_FILE" 2>/dev/null)" >> "$DEBUG_LOG"

    if [ -n "$WIFI_IP" ]; then
        LOG "yellow" "[*] WiFi active ($WIFI_IP) — attempting exfil..."
        EXFIL_OK=false

        # Discord / generic webhook
        if [ -n "$EXFIL_WEBHOOK" ]; then
            if [ "$EXFIL_SUMMARY_ONLY" = "true" ]; then
                STAT_LINE="Nosey Neighbor | ${AP_COUNT} APs | ${CLIENT_COUNT} clients | ${NEW_SSID_COUNT} new SSIDs | ${ELAPSED_DISPLAY}"
                [ "$OPEN_COUNT" -gt 0 ] && STAT_LINE="${STAT_LINE} | [!] ${OPEN_COUNT} open"
                CURL_OUT=$(curl -s -w "\nHTTP:%{http_code}" \
                    -H "Content-Type: application/json" \
                    -d "{\"content\":\"${STAT_LINE}\"}" \
                    "$EXFIL_WEBHOOK" 2>&1)
            else
                STAT_LINE="Nosey Neighbor complete — ${AP_COUNT} APs, ${CLIENT_COUNT} clients, ${ELAPSED_DISPLAY}"
                CURL_OUT=$(curl -s -w "\nHTTP:%{http_code}" \
                    -F "file=@${REPORT_FILE};filename=nosey_neighbor_$(date +%Y%m%d_%H%M).txt" \
                    -F "payload_json={\"content\":\"${STAT_LINE}\"}" \
                    "$EXFIL_WEBHOOK" 2>&1)
            fi
            CURL_CODE=$(echo "$CURL_OUT" | awk -F: '/^HTTP:/{print $2}')
            printf "[DEBUG] EXFIL: Discord curl output: %s\n" "$CURL_OUT" >> "$DEBUG_LOG"
            if [ "$CURL_CODE" = "200" ] || [ "$CURL_CODE" = "204" ]; then
                LOG "green" "[+] Report delivered to webhook (HTTP $CURL_CODE)"
                EXFIL_OK=true
            else
                LOG "yellow" "[!] Webhook delivery failed (HTTP $CURL_CODE)"
            fi
        else
            printf "[DEBUG] EXFIL: EXFIL_WEBHOOK is empty — skipping Discord\n" >> "$DEBUG_LOG"
        fi

        # ntfy.sh summary push
        if [ -n "$EXFIL_NTFY_TOPIC" ]; then
            NTFY_MSG="Nosey Neighbor: ${AP_COUNT} APs | ${CLIENT_COUNT} clients | ${NEW_SSID_COUNT} new probed SSIDs | Scan: ${ELAPSED_DISPLAY}"
            [ "$OPEN_COUNT" -gt 0 ] && NTFY_MSG="${NTFY_MSG} | [!] ${OPEN_COUNT} OPEN"
            CURL_OUT=$(curl -s -w "\nHTTP:%{http_code}" \
                -d "$NTFY_MSG" \
                "https://ntfy.sh/$EXFIL_NTFY_TOPIC" 2>&1)
            CURL_CODE=$(echo "$CURL_OUT" | awk -F: '/^HTTP:/{print $2}')
            printf "[DEBUG] EXFIL: ntfy curl output: %s\n" "$CURL_OUT" >> "$DEBUG_LOG"
            if [ "$CURL_CODE" = "200" ]; then
                LOG "green" "[+] Summary pushed to ntfy.sh/${EXFIL_NTFY_TOPIC}"
                EXFIL_OK=true
            fi
        fi

        if [ "$EXFIL_OK" = "false" ]; then
            LOG "yellow" "[!] Exfil enabled but no method configured or succeeded"
        fi
    else
        LOG "yellow" "[*] No WiFi — skipping exfil"
        printf "[DEBUG] EXFIL: wlan0cli has no IP — skipping\n" >> "$DEBUG_LOG"
    fi
fi

# ============================================================================
# CLEANUP & COMPLETION
# ============================================================================
rm -f "$AP_DB" "$CLIENT_DB" "$RAW_SCAN" "/tmp/nosey_all_macs_${TIMESTAMP}.txt" "$POOL_BEFORE_FILE" "$NEW_SSID_FILE" \
    "$MAC_PROBE_MAP" "/tmp/nosey_curr_snap_${TIMESTAMP}.txt" \
    "/tmp/nosey_new_aps_${TIMESTAMP}.txt" "/tmp/nosey_gone_aps_${TIMESTAMP}.txt" \
    "/tmp/nosey_curr_cli_${TIMESTAMP}.txt"

LED FINISH
VIBRATE 300 100 300 100 300
RINGTONE "success"

SUMMARY_MSG="NOSEY NEIGHBOR COMPLETE\n\n"
SUMMARY_MSG="${SUMMARY_MSG}APs Found: ${AP_COUNT}\n"
SUMMARY_MSG="${SUMMARY_MSG}Clients: ${CLIENT_COUNT}\n"
SUMMARY_MSG="${SUMMARY_MSG}Probed SSIDs: ${NEW_SSID_COUNT} new / ${PROBED_COUNT} total\n"
SUMMARY_MSG="${SUMMARY_MSG}Scan Time: ${ELAPSED_DISPLAY}\n"
[ "$OPEN_COUNT" -gt 0 ] && SUMMARY_MSG="${SUMMARY_MSG}\n[!] ${OPEN_COUNT} OPEN networks!\n"
[ "$WEP_COUNT" -gt 0 ] && SUMMARY_MSG="${SUMMARY_MSG}[!] ${WEP_COUNT} WEP networks!\n"
SUMMARY_MSG="${SUMMARY_MSG}\nLoot saved to:\n${LOOT_DIR}"

ALERT "$SUMMARY_MSG"
LOG "green" "Scan complete in ${ELAPSED_DISPLAY}"

exit 0
