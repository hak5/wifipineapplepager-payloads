#!/bin/bash
# Title: Flock You - Wardrive Mode v9.19
# Description: Continuous BLE scanner for Flock Safety surveillance devices,
#              tuned for driving past cameras.
#              Detection fires on THREE signals:
#                MANUF  XUNTONG manufacturer ID 0x09C8 in the advertising data
#                OUI    MAC prefix in oui_list.txt (Lite-On + verified Flock)
#                NAME   BLE name substring (FS Ext Battery/Penguin/Pigvision/Flock)
#              Field-proven: OUI is the signal that actually catches Falcon
#              cameras (a 1477-device drive saw zero 0x09C8), so all three
#              signals matter.
#
#              v9.19 fixes three field-observed defects in v9.18:
#                1. "Set scan parameters failed: I/O error" flooding the log.
#                   Killing `lescan` leaves LE scanning enabled in the
#                   controller, so the next cycle could not set scan params.
#                   Now scanning is explicitly disabled between cycles with
#                   HCI LE Set Scan Enable=0 - fast, no adapter bounce, so the
#                   high duty cycle is kept.
#                2. Alerts lagging ~30 minutes behind the sighting. The
#                   per-device dedup ran a grep against a growing seen-file
#                   (O(n^2)): measured 79s PER CYCLE at 1477 devices, and
#                   worsening. Bulk diagnostic dedup is now a single awk pass
#                   (measured 0ms at the same volume).
#                3. Detection timestamps were computed once per cycle, so a
#                   logged time could be many minutes stale. The timestamp is
#                   now taken at the moment of detection.
#               Flock hits are also processed BEFORE the bulk diagnostic write,
#               so the buzz/LED fire immediately rather than behind 1400+ rows.
#
#              Each detection is GPS-tagged from gpsd (NO_GPS when no fix).
# Author: colonelpanichacks
# Contributors: Claude (Anthropic), Grok (xAI), Brandon Starkweather
# Data Sources: colonelpanichacks/flock-you, deflock.me, GainSec,
#               Ryan O'Horo (FCC research), Will Greenberg (BLE research)
# Version: 9.19
# Category: Reconnaissance

# --- paths --------------------------------------------------------------
SCRIPT_DIR="$(dirname "$0")"
OUI_LIST="${SCRIPT_DIR}/oui_list.txt"
[ -f "$OUI_LIST" ] || OUI_LIST="/root/payloads/user/reconnaissance/Flock_Detect/oui_list.txt"

LOOT_DIR="/root/loot/flock_you"
mkdir -p "$LOOT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOOT_DIR}/flock_hcitool_${TIMESTAMP}.txt"
CSV_FILE="${LOOT_DIR}/flock_gps_${TIMESTAMP}.csv"
ALLADV_FILE="${LOOT_DIR}/flock_alladv_${TIMESTAMP}.csv"

# Per-instance temp files. The Pager UI launches payloads from a COPY at
# /tmp/payload-<id>.sh, so a payload left running from an earlier session is
# easy to miss; if a second instance starts, shared /tmp paths let the two
# corrupt each other's capture and dedup state. $$ keeps every run isolated.
TMPTAG="$$"
RAW_FILE="/tmp/flock_raw_${TMPTAG}.txt"
SCAN_FILE="/tmp/flock_scan_${TMPTAG}.txt"
ADV_FILE="/tmp/flock_adv_${TMPTAG}.txt"
HIT_FILE="/tmp/flock_hit_${TMPTAG}.txt"
SEEN_FILE="/tmp/flock_seen_${TMPTAG}.txt"       # detected (Flock) MACs - small
ALLSEEN_FILE="/tmp/flock_allseen_${TMPTAG}.txt" # every MAC (diagnostic) - large
NEWSEEN_FILE="/tmp/flock_newseen_${TMPTAG}.txt" # new MACs (awk cannot append to a file it read)
# No EXIT/TERM trap here, deliberately. Two ways it backfires on this
# platform: background subshells (the `hcidump ... &` jobs) inherit an EXIT
# trap and would delete the live dedup state every cycle, and a TERM trap
# makes the payload SURVIVE being killed (bash resumes the loop after a
# trapped signal), leaving immortal instances fighting over the adapter.
# Per-instance filenames already prevent collisions; /tmp is tmpfs and clears
# on reboot. Just remove our own leftovers at startup.
rm -f /tmp/flock_*_"${TMPTAG}".txt
: > "$SEEN_FILE"; : > "$ALLSEEN_FILE"; : > "$NEWSEEN_FILE"

# --- GPS fix reader -----------------------------------------------------
get_gps_fix() {
    local json mode lat lon
    json="$(timeout 3 gpspipe -w -n 30 2>/dev/null | grep '"class":"TPV"' | grep '"lat":' | tail -n 1)"
    [ -z "$json" ] && return 1
    mode="$(echo "$json" | jq -r '.mode // 0' 2>/dev/null)"
    case "$mode" in 2|3) ;; *) return 1 ;; esac
    lat="$(echo "$json" | jq -r '.lat // empty' 2>/dev/null)"
    lon="$(echo "$json" | jq -r '.lon // empty' 2>/dev/null)"
    [ -n "$lat" ] && [ -n "$lon" ] || return 1
    echo "${lat},${lon}"
}

# Clears LE scan state left behind when `hcitool lescan` is killed.
# Without this the next cycle fails with "Set scan parameters failed: I/O error".
stop_le_scan() { hcitool cmd 0x08 0x000C 00 00 >/dev/null 2>&1; }

# --- unified advert parser ----------------------------------------------
# Emits one line per unique MAC this cycle:
#   MAC|MANUF|RSSI|TAGS|LABEL|NAME
parse_adverts() {
    awk -v ouifile="$OUI_LIST" -v scanfile="$SCAN_FILE" '
      function hx(s,  n,i,c){ n=0; s=toupper(s);
        for(i=1;i<=length(s);i++){ c=substr(s,i,1); n=n*16+(index("0123456789ABCDEF",c)-1) } return n }
      BEGIN{
        while((getline l < ouifile) > 0){ n=split(l,a,"|"); if(n>=2){ k=toupper(a[1]); gsub(/ /,"",k); cat[k]=a[2]; lbl[k]=a[3] } }
        while((getline l < scanfile) > 0){ n=split(l,a," "); if(n>=2){ m=toupper(a[1]); nm=l; sub(/^[^ ]+ /,"",nm);
          if(nm!="(unknown)" && nm!="") name[m]=nm } }
      }
      /^[<>]/ { if(b!="") proc(b); b=$0; next }
      { s=$0; gsub(/^ +/,"",s); b=b" "s }
      END{
        if(b!="") proc(b)
        for(m in seenmac){
          tg=tags[m]
          if(m in name){ low=tolower(name[m]); if(low ~ /fs ext battery|penguin|flock|pigvision/) tg=(tg?tg"+":"")"NAME" }
          printf "%s|%s|%s|%s|%s|%s\n", m, (m in manf?manf[m]:"-"), rssi[m], tg, (m in lbl2?lbl2[m]:""), (m in name?name[m]:"")
        }
      }
      function proc(ev,  t,n2,mac,oui,dl,i,en,ln,ty,comp,r){
        if(ev !~ /^> 04 3E /) return
        n2=split(ev,t," ")
        if(t[5]!="02") return
        if(n2<16) return
        mac=toupper(t[14]":"t[13]":"t[12]":"t[11]":"t[10]":"t[9])
        oui=toupper(t[14]":"t[13]":"t[12])
        dl=hx(t[15]); r=hx(t[n2]); if(r>=128) r=r-256
        seenmac[mac]=1
        if(!(mac in rssi) || r>rssi[mac]) rssi[mac]=r
        i=16; en=16+dl; if(en>n2) en=n2
        while(i < en){
          ln=hx(t[i]); if(ln<=0) break
          ty=toupper(t[i+1])
          if(ty=="FF" && (i+3)<=n2){
            comp="0x" toupper(t[i+3] t[i+2]); manf[mac]=comp
            if(comp=="0x09C8" && index(tags[mac],"MANUF")==0) tags[mac]=(tags[mac]?tags[mac]"+":"")"MANUF:XUNTONG"
          }
          i += ln+1
        }
        if((oui in cat) && index(tags[mac],"OUI")==0){ tags[mac]=(tags[mac]?tags[mac]"+":"")"OUI:"cat[oui]; lbl2[mac]=lbl[oui] }
      }
    ' "$RAW_FILE" 2>/dev/null
}

# --- startup ------------------------------------------------------------
LOG yellow "Flock-You v9.19 (wardrive) started at $(date)"
LOG "Near-continuous scan + all-advert diagnostic log."
LOG "Signal key:"
LOG magenta "  MANUF  XUNTONG 0x09C8"
LOG yellow  "  OUI    MAC prefix match (catches Falcon)"
LOG cyan    "  NAME   BLE name match"
LOG "----------------------------------"
echo "v9.19 started at $(date)" > "$LOG_FILE"
echo "time,mac,name_or_label,signals,rssi,lat,lon" > "$CSV_FILE"
echo "time,mac,manuf_id,rssi,name" > "$ALLADV_FILE"

hciconfig hci0 down 2>>"$LOG_FILE"
hciconfig hci0 reset 2>>"$LOG_FILE"
hciconfig hci0 up 2>>"$LOG_FILE"
stop_le_scan

DETECTIONS=0
COUNTER=0
EMPTY_STREAK=0

while true; do
    : > "$RAW_FILE"; : > "$SCAN_FILE"
    timeout 11 hcidump --raw > "$RAW_FILE" 2>>"$LOG_FILE" &
    DUMP_PID=$!
    timeout 11 hcitool lescan --duplicates > "$SCAN_FILE" 2>>"$LOG_FILE" &
    SCAN_PID=$!
    sleep 8
    kill $SCAN_PID 2>/dev/null; kill $DUMP_PID 2>/dev/null
    wait $SCAN_PID 2>/dev/null; wait $DUMP_PID 2>/dev/null
    stop_le_scan            # <- clears scan state; prevents I/O-error flood

    if [ ! -s "$RAW_FILE" ]; then
        EMPTY_STREAK=$((EMPTY_STREAK + 1))
        if [ "$EMPTY_STREAK" -ge 2 ]; then
            hciconfig hci0 down 2>>"$LOG_FILE"; hciconfig hci0 reset 2>>"$LOG_FILE"; hciconfig hci0 up 2>>"$LOG_FILE"
            stop_le_scan
            EMPTY_STREAK=0
        fi
        continue
    fi
    EMPTY_STREAK=0

    CYCLE_GPS="$(get_gps_fix)"
    if [ -n "$CYCLE_GPS" ]; then GPS_TAG="$CYCLE_GPS"; CSV_LAT="${CYCLE_GPS%,*}"; CSV_LON="${CYCLE_GPS#*,}";
    else GPS_TAG="NO_GPS"; CSV_LAT=""; CSV_LON=""; fi

    parse_adverts > "$ADV_FILE"

    # ---- FLOCK HITS FIRST (few rows) so the alert is immediate ----------
    awk -F'|' '$4 != ""' "$ADV_FILE" > "$HIT_FILE"
    while IFS='|' read -r MAC MANUF RSSI TAGS LABEL NAME; do
        [ -z "$MAC" ] && continue
        grep -qx "$MAC" "$SEEN_FILE" 2>/dev/null && continue
        echo "$MAC" >> "$SEEN_FILE"

        CURRENT_TIME=$(date '+%H:%M:%S')     # per-detection, not per-cycle
        DESC="${LABEL:-${NAME:-$TAGS}}"
        ENTRY="DECT: $CURRENT_TIME | $MAC | $TAGS | $DESC | RSSI:$RSSI | $GPS_TAG"
        case "$TAGS" in
            *MANUF*) LOG magenta "$ENTRY" ;;
            *OUI*)   LOG yellow  "$ENTRY" ;;
            *NAME*)  LOG cyan    "$ENTRY" ;;
            *)       LOG "$ENTRY" ;;
        esac
        echo "$ENTRY" >> "$LOG_FILE"
        echo "${CURRENT_TIME},${MAC},\"${DESC}\",\"${TAGS}\",${RSSI},${CSV_LAT},${CSV_LON}" >> "$CSV_FILE"

        DETECTIONS=$((DETECTIONS + 1)); COUNTER=$((COUNTER + 1))
        if [ $((COUNTER % 10)) -eq 0 ]; then
            LOG " "; LOG magenta "MANUF XUNTONG"; LOG yellow "OUI match"; LOG cyan "NAME match"; LOG " "
        fi

        # Alert: buzz + LED, immediately.
        if [ -f /sys/class/gpio/vibrator/value ]; then
            echo 1 > /sys/class/gpio/vibrator/value 2>/dev/null; sleep 0.15
            echo 0 > /sys/class/gpio/vibrator/value 2>/dev/null
        fi
        if [ -d /sys/class/leds/buzzer ]; then
            echo 1 > /sys/class/leds/buzzer/brightness 2>/dev/null; sleep 0.2
            echo 0 > /sys/class/leds/buzzer/brightness 2>/dev/null
        fi
        if [ -d /sys/class/leds/a-button-led ]; then
            echo 1 > /sys/class/leds/a-button-led/brightness 2>/dev/null; sleep 0.2
            echo 0 > /sys/class/leds/a-button-led/brightness 2>/dev/null
        fi
    done < "$HIT_FILE"

    # ---- BULK DIAGNOSTIC (many rows) - single awk pass, O(n) ------------
    # Appends new MACs to ALLSEEN_FILE and their rows to ALLADV_FILE.
    # getline (not NR==FNR) so an empty/missing seen-file behaves correctly.
    DIAG_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
    # NOTE: awk cannot reliably append to a file it also read with getline
    # (the write is lost), so new MACs go to a temp file and are concatenated
    # afterwards. Errors are NOT suppressed - a silent awk failure here once
    # cost a whole test run.
    awk -F'|' -v seenfile="$ALLSEEN_FILE" -v newout="$NEWSEEN_FILE" -v ts="$DIAG_TIME" '
      BEGIN{ while((getline l < seenfile) > 0) seen[l]=1 }
      {
        if($1 != "" && !($1 in seen)){
          seen[$1]=1
          print $1 > newout
          printf "%s,%s,%s,%s,\"%s\"\n", ts, $1, $2, $3, $6
        }
      }
    ' "$ADV_FILE" >> "$ALLADV_FILE" 2>>"$LOG_FILE"
    [ -s "$NEWSEEN_FILE" ] && cat "$NEWSEEN_FILE" >> "$ALLSEEN_FILE"
    : > "$NEWSEEN_FILE"
done
exit 0
