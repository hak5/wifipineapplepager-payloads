#!/bin/bash
# Title: Digital Tails (Persistent Devices Monitor)
# Author: Notorious Squirrel 
# Passive-only. Tracks devices that persist nearby across scans (possible "tail").
# Uses recon.db + Pager UI helpers (commands.sh). No deauth/association/injection.

set -u
export LC_ALL=C

DBG="/tmp/digital_tails.log"
: > "$DBG"

# ----------------------------
# Load Hak5 UI helpers FIRST
# ----------------------------
if [ -f /lib/hak5/commands.sh ]; then
  # shellcheck disable=SC1091
  . /lib/hak5/commands.sh 2>>"$DBG" || true
fi

# ----------------------------
# UI Output (auto-detect)
# ----------------------------
ui_title() { command -v TITLE >/dev/null 2>&1 && TITLE "$1" || echo "=== $1 ==="; }
ui_log()   { command -v LOG   >/dev/null 2>&1 && LOG "$1"   || echo "$1"; }
ui_clear() {
  if command -v CLEAR >/dev/null 2>&1; then
    CLEAR
  else
    # ANSI clear fallback
    printf '\033[2J\033[H'
  fi
}
tlog() { echo "$1" >>"$DBG"; }

# Optional alert helpers (safe fallbacks)
do_beep()    { command -v RINGTONE >/dev/null 2>&1 && RINGTONE alert 2>/dev/null || true; }
do_vibrate() { command -v VIBRATE  >/dev/null 2>&1 && VIBRATE 2>/dev/null || true; }

trap 'command -v led_off >/dev/null 2>&1 && led_off 2>/dev/null || true' EXIT

# ----------------------------
# Config (happy-medium for walking + driving)
# ----------------------------
SCAN_INTERVAL=5

# ~90 seconds memory
WINDOW_SCANS=18

# SLOW mode thresholds (walking / calmer)
WATCH_MIN=10
ALERT_MIN=12

# FAST mode thresholds (driving / noisy)
WATCH_MIN_FAST=11
ALERT_MIN_FAST=13

STRONG_RSSI=-55

# FOLLOW alert logic
FOLLOW_RSSI_MIN=-65
FOLLOW_LOC_MIN=3
FOLLOW_COOLDOWN=180    # seconds

# Display
MAX_SHOW=8

# DB sampling
SAMPLE_ROWS=2500

# Location fingerprinting
LOC_APS=10
LOC_JACCARD_NEW=0.60
LOC_MAX_PER_DEVICE=6

# Heuristic: "FAST" if seen-now is very high (driving / busy environment)
FAST_SEEN_THRESHOLD=800

DB="/mmc/root/recon/recon.db"
TABLE_CLIENT="wifi_device"   # where mac/signal are read from for tails

STATE_DIR="/tmp/digital_tails"
SEEN="$STATE_DIR/seen.psv"              # MAC|RSSI
STATE="$STATE_DIR/state.psv"            # MAC|BITS|RSSI|LOCS
META="$STATE_DIR/meta.psv"              # last_tail1|stable_scans|mode|loc_hash|loc_name|loc_seq
LOC_DB="$STATE_DIR/locations.psv"       # loc_hash|loc_seq|loc_name|last_ts
LAST_LOC_SET="$STATE_DIR/last_locset.txt"
FOLLOW_DB="$STATE_DIR/follow_alerts.psv" # MAC|last_ts|last_loc_seq
mkdir -p "$STATE_DIR"

# ----------------------------
# SQLite wrapper (busy_timeout avoids lock issues)
# ----------------------------
sql() {
  sqlite3 "$DB" 2>>"$DBG" <<EOF
PRAGMA busy_timeout=2500;
.mode tabs
.headers off
$1
EOF
}

# ----------------------------
# Helpers: detect AP table for location fingerprinting
# ----------------------------
table_exists() {
  local t="$1"
  sqlite3 "$DB" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$t' LIMIT 1;" 2>/dev/null | grep -q '^1$'
}
table_has_col() {
  local t="$1" c="$2"
  sqlite3 "$DB" "PRAGMA table_info($t);" 2>/dev/null | awk -F'|' '{print $2}' | grep -qx "$c"
}
detect_ap_source() {
  # candidates seen across Pineapple schemas
  for t in ssid access_point scan hostap_basic; do
    if table_exists "$t"; then
      if (table_has_col "$t" "bssid" || table_has_col "$t" "mac" || table_has_col "$t" "bssid_mac"); then
        if (table_has_col "$t" "signal" || table_has_col "$t" "rssi" || table_has_col "$t" "power"); then
          echo "$t"; return 0
        fi
      fi
    fi
  done
  echo ""
  return 1
}
ap_query_for_table() {
  local t="$1"
  local bcol="" rcol=""

  if table_has_col "$t" "bssid"; then bcol="bssid"
  elif table_has_col "$t" "mac"; then bcol="mac"
  elif table_has_col "$t" "bssid_mac"; then bcol="bssid_mac"
  else bcol="bssid"
  fi

  if table_has_col "$t" "signal"; then rcol="signal"
  elif table_has_col "$t" "rssi"; then rcol="rssi"
  elif table_has_col "$t" "power"; then rcol="power"
  else rcol="signal"
  fi

  cat <<EOF
WITH recent AS (
  SELECT $bcol AS b, $rcol AS s
  FROM $t
  ORDER BY rowid DESC
  LIMIT 2000
)
SELECT UPPER(b), MAX(s) AS rssi
FROM recent
WHERE b IS NOT NULL AND b != '' AND s IS NOT NULL
GROUP BY UPPER(b)
ORDER BY rssi DESC
LIMIT $LOC_APS;
EOF
}

# ----------------------------
# Parse seen -> MAC|RSSI (handles 12-hex and colon formats)
# ----------------------------
parse_seen() {
  : > "$SEEN"
  sql "SELECT mac, signal FROM $TABLE_CLIENT ORDER BY rowid DESC LIMIT $SAMPLE_ROWS;" \
  | awk -F'\t' '
      function is_hex12(s){ return (s ~ /^[0-9A-Fa-f]{12}$/) }
      function is_colon(s){ return (s ~ /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/) }
      function hex12_to_colon(h){
        h=toupper(h)
        return substr(h,1,2) ":" substr(h,3,2) ":" substr(h,5,2) ":" \
               substr(h,7,2) ":" substr(h,9,2) ":" substr(h,11,2)
      }
      NF>=2 {
        mac=$1; rssi=$2
        gsub(/[^0-9A-Fa-f:]/,"",mac)
        if (is_hex12(mac)) mac=hex12_to_colon(mac)
        if (!is_colon(mac)) next
        mac=toupper(mac)
        if (mac=="00:00:00:00:00:00") next
        if (rssi !~ /^-?[0-9]+$/) next
        print mac "|" rssi
      }
    ' | sort -u > "$SEEN"

  [ -s "$SEEN" ]
}

# ----------------------------
# Update state: MAC|BITS|RSSI|LOCS
# LOCS is comma-separated location hashes (distinct), capped
# ----------------------------
update_state() {
  [ -f "$STATE" ] || : > "$STATE"
  local cur_loc="$1"

  awk -F'|' -v W="$WINDOW_SCANS" -v CURLOC="$cur_loc" -v LMAX="$LOC_MAX_PER_DEVICE" '
    BEGIN{OFS="|"}
    function norm_bits(b){
      gsub(/[^01]/,"",b)
      if (length(b) > W) b = substr(b, length(b)-W+1)
      while (length(b) < W) b = "0" b
      return b
    }
    function loc_add(list, loc,   a,n,i,seen,out){
      if (loc=="") return list
      if (list=="") return loc
      n=split(list,a,",")
      seen=0
      for(i=1;i<=n;i++) if (a[i]==loc) seen=1
      if (!seen) list=list "," loc

      # cap to last LMAX entries
      n=split(list,a,",")
      if (n<=LMAX) return list
      out=""
      for(i=n-LMAX+1;i<=n;i++){
        if(out=="") out=a[i]; else out=out "," a[i]
      }
      return out
    }

    FNR==NR { seen[$1]=$2; next }
    {
      mac=$1; bits=$2; last=$3; locs=$4
      bits=norm_bits(bits)
      bits=substr(bits,2)

      if (mac in seen) {
        bits=bits "1"
        last=seen[mac]
        locs=loc_add(locs, CURLOC)
      } else {
        bits=bits "0"
      }

      print mac,bits,last,locs
      had[mac]=1
    }
    END{
      for (m in seen) if (!(m in had)) {
        bits=""
        for (i=1;i<=W-1;i++) bits=bits "0"
        bits=bits "1"
        print m,bits,seen[m],CURLOC
      }
    }
  ' "$SEEN" "$STATE" > "$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"
}

# ----------------------------
# Bars for signal
# ----------------------------
bars() {
  local r="$1" b=1
  if   [ "$r" -ge -35 ]; then b=10
  elif [ "$r" -ge -40 ]; then b=9
  elif [ "$r" -ge -45 ]; then b=8
  elif [ "$r" -ge -50 ]; then b=7
  elif [ "$r" -ge -55 ]; then b=6
  elif [ "$r" -ge -60 ]; then b=5
  elif [ "$r" -ge -65 ]; then b=4
  elif [ "$r" -ge -70 ]; then b=3
  elif [ "$r" -ge -80 ]; then b=2
  else b=1
  fi
  printf "%s" "$(printf '#%.0s' $(seq 1 "$b"))"
}

# ----------------------------
# Auto-mode: SLOW vs FAST
# ----------------------------
detect_mode() {
  local seen_now
  seen_now="$(wc -l < "$SEEN" 2>/dev/null || echo 0)"
  [ "$seen_now" -ge "$FAST_SEEN_THRESHOLD" ] && echo "FAST" || echo "SLOW"
}

# ----------------------------
# Location fingerprinting (AP BSSID pool + Jaccard)
# ----------------------------
ensure_loc_db() { [ -f "$LOC_DB" ] || : > "$LOC_DB"; }

jaccard_similarity() {
  local a="$1" b="$2"
  if [ ! -s "$a" ] || [ ! -s "$b" ]; then echo "0.00"; return; fi
  local inter uni
  inter="$(comm -12 <(sort "$a") <(sort "$b") | wc -l 2>/dev/null || echo 0)"
  uni="$(cat "$a" "$b" 2>/dev/null | sort -u | wc -l 2>/dev/null || echo 1)"
  [ "$uni" -le 0 ] && uni=1
  awk -v i="$inter" -v u="$uni" 'BEGIN{printf "%.2f", (u==0?0:i/u)}'
}

loc_hash_from_set() {
  local h
  h="$(cat 2>/dev/null | tr -d '\r' | sed '/^$/d' | sort -u | tr '\n' ' ' | md5sum 2>/dev/null | awk '{print substr($1,1,8)}')"
  [ -n "$h" ] && echo "$h" || echo "00000000"
}

lookup_loc_name() { local h="$1"; awk -F'|' -v H="$h" '$1==H {print $3; exit}' "$LOC_DB" 2>/dev/null; }
lookup_loc_seq()  { local h="$1"; awk -F'|' -v H="$h" '$1==H {print $2; exit}' "$LOC_DB" 2>/dev/null; }

next_loc_seq() {
  local m
  m="$(awk -F'|' 'BEGIN{m=0} $2+0>m{m=$2+0} END{print m}' "$LOC_DB" 2>/dev/null)"
  echo $((m+1))
}

touch_loc_db() {
  local h="$1" seq="$2" name="$3"
  local ts
  ts="$(date +%s 2>/dev/null || echo 0)"
  if awk -F'|' -v H="$h" '$1==H{f=1} END{exit(f?0:1)}' "$LOC_DB" 2>/dev/null; then
    awk -F'|' -v H="$h" -v TS="$ts" 'BEGIN{OFS="|"} {if($1==H){$4=TS} print}' "$LOC_DB" > "$LOC_DB.tmp" && mv -f "$LOC_DB.tmp" "$LOC_DB"
  else
    printf "%s|%s|%s|%s\n" "$h" "$seq" "$name" "$ts" >> "$LOC_DB"
  fi
}

get_location() {
  ensure_loc_db
  local aptable tmp_set cur_hash last_sim is_new seq name

  aptable="$(detect_ap_source || true)"
  tmp_set="$STATE_DIR/cur_locset.txt"
  : > "$tmp_set"

  if [ -n "$aptable" ]; then
    sql "$(ap_query_for_table "$aptable")" \
      | awk -F'\t' 'NF>=1{print toupper($1)}' \
      | sed '/^$/d' > "$tmp_set"
  fi

  if [ ! -s "$tmp_set" ]; then
    echo "00000000|0|UNKNOWN|0.00"
    return
  fi

  cur_hash="$(loc_hash_from_set < "$tmp_set")"

  if [ -s "$LAST_LOC_SET" ]; then
    last_sim="$(jaccard_similarity "$LAST_LOC_SET" "$tmp_set")"
  else
    last_sim="0.00"
  fi

  is_new="$(awk -v s="$last_sim" -v t="$LOC_JACCARD_NEW" 'BEGIN{print (s<t)?"1":"0"}')"

  if [ "$is_new" = "1" ]; then
    seq="$(next_loc_seq)"
    name="LOC-$seq"
    touch_loc_db "$cur_hash" "$seq" "$name"
  else
    name="$(lookup_loc_name "$cur_hash")"
    seq="$(lookup_loc_seq "$cur_hash")"
    if [ -z "$name" ] || [ -z "$seq" ]; then
      seq="$(next_loc_seq)"
      name="LOC-$seq"
      touch_loc_db "$cur_hash" "$seq" "$name"
    else
      touch_loc_db "$cur_hash" "$seq" "$name"
    fi
  fi

  cp -f "$tmp_set" "$LAST_LOC_SET"
  echo "$cur_hash|$seq|$name|$last_sim"
}

# ----------------------------
# Tail selection, stability, and confidence
# ----------------------------
get_tail1() {
  awk -F'|' -v W="$WINDOW_SCANS" '
    function count1(s,   i,c){ c=0; for(i=1;i<=length(s);i++) if(substr(s,i,1)=="1") c++; return c }
    BEGIN{bestC=-1; bestR=-999; bestM=""}
    { mac=$1; bits=$2; rssi=$3
      gsub(/[^01]/,"",bits)
      c=count1(bits)
      if (rssi=="") rssi=-99
      if (c>bestC || (c==bestC && rssi>bestR)) { bestC=c; bestR=rssi; bestM=mac } }
    END{ if(bestM!="") print bestM "|" bestC "|" bestR; }
  ' "$STATE"
}

update_meta_stability() {
  local tail1="$1" mode="$2" loc_hash="$3" loc_name="$4" loc_seq="$5"
  local last stable oldmode oldhash oldname oldseq
  last=""; stable="0"; oldmode=""; oldhash=""; oldname=""; oldseq="0"
  if [ -f "$META" ]; then
    IFS='|' read -r last stable oldmode oldhash oldname oldseq < "$META" 2>/dev/null || true
  fi
  if [ -n "$tail1" ] && [ "$tail1" = "$last" ]; then stable=$((stable+1)); else stable=1; fi
  printf "%s|%s|%s|%s|%s|%s\n" "$tail1" "$stable" "$mode" "$loc_hash" "$loc_name" "$loc_seq" > "$META"
  echo "$stable"
}

locs_count() {
  local s="$1"
  [ -z "$s" ] && { echo 0; return; }
  echo "$s" | awk -F',' '{print NF}'
}

confidence_label() {
  local seen_count="$1" rssi="$2" stable="$3" watch_th="$4" alert_th="$5" lc="$6"
  local score=0

  if [ "$seen_count" -ge "$alert_th" ]; then score=$((score+2))
  elif [ "$seen_count" -ge "$watch_th" ]; then score=$((score+1))
  fi

  if [ "$rssi" -ge "$STRONG_RSSI" ]; then score=$((score+2))
  elif [ "$rssi" -ge -65 ]; then score=$((score+1))
  fi

  if [ "$stable" -ge 12 ]; then score=$((score+2))
  elif [ "$stable" -ge 6 ]; then score=$((score+1))
  fi

  if [ "$lc" -ge 3 ]; then score=$((score+2))
  elif [ "$lc" -ge 2 ]; then score=$((score+1))
  fi

  if [ "$score" -ge 6 ]; then echo "HIGH"
  elif [ "$score" -ge 4 ]; then echo "MED"
  else echo "LOW"
  fi
}

# ----------------------------
# FOLLOW ALERT: cooldown + per-location suppression
# ----------------------------
ensure_follow_db() { [ -f "$FOLLOW_DB" ] || : > "$FOLLOW_DB"; }

follow_last_for() {
  local mac="$1"
  awk -F'|' -v M="$mac" '$1==M {print $2 "|" $3; exit}' "$FOLLOW_DB" 2>/dev/null
}

follow_update_for() {
  local mac="$1" ts="$2" locseq="$3"
  ensure_follow_db
  if awk -F'|' -v M="$mac" '$1==M{f=1} END{exit(f?0:1)}' "$FOLLOW_DB" 2>/dev/null; then
    awk -F'|' -v M="$mac" -v TS="$ts" -v L="$locseq" 'BEGIN{OFS="|"} {if($1==M){$2=TS;$3=L} print}' "$FOLLOW_DB" > "$FOLLOW_DB.tmp" && mv -f "$FOLLOW_DB.tmp" "$FOLLOW_DB"
  else
    printf "%s|%s|%s\n" "$mac" "$ts" "$locseq" >> "$FOLLOW_DB"
  fi
}

maybe_follow_alert() {
  # args: mac seen_count rssi locs_count loc_seq watch_th
  local mac="$1" sc="$2" rssi="$3" lc="$4" locseq="$5" watch_th="$6"

  # must meet follow conditions
  [ "$lc" -lt "$FOLLOW_LOC_MIN" ] && return 1
  [ "$sc" -lt "$watch_th" ] && return 1
  [ "$rssi" -lt "$FOLLOW_RSSI_MIN" ] && return 1

  ensure_follow_db
  local now lastline lastts lastloc
  now="$(date +%s 2>/dev/null || echo 0)"
  lastline="$(follow_last_for "$mac" || true)"
  lastts="$(echo "$lastline" | awk -F'|' '{print $1+0}')"
  lastloc="$(echo "$lastline" | awk -F'|' '{print $2+0}')"

  # suppress repeats in same location
  [ "$lastloc" -eq "$locseq" ] && [ "$lastts" -gt 0 ] && return 1

  # cooldown
  [ "$lastts" -gt 0 ] && [ $((now - lastts)) -lt "$FOLLOW_COOLDOWN" ] && return 1

  follow_update_for "$mac" "$now" "$locseq"
  return 0
}

# ----------------------------
# Render (static dashboard)
# ----------------------------
render() {
  local mode="$1" watch_th="$2" alert_th="$3" loc_name="$4" loc_seq="$5" loc_sim="$6"

  local seen_now
  seen_now="$(wc -l < "$SEEN" 2>/dev/null || echo 0)"

  local line t1mac t1c t1r t1locs t1lc stable conf status follow_now
  line="$(get_tail1 || true)"
  t1mac="$(echo "$line" | awk -F'|' '{print $1}')"
  t1c="$(echo "$line" | awk -F'|' '{print $2+0}')"
  t1r="$(echo "$line" | awk -F'|' '{print $3+0}')"
  [ -z "$t1c" ] && t1c=0
  [ -z "$t1r" ] && t1r=-99

  t1locs="$(awk -F'|' -v M="$t1mac" '$1==M{print $4; exit}' "$STATE" 2>/dev/null)"
  t1lc="$(locs_count "$t1locs")"

  stable="$(update_meta_stability "$t1mac" "$mode" "x" "$loc_name" "$loc_seq")"
  conf="$(confidence_label "$t1c" "$t1r" "$stable" "$watch_th" "$alert_th" "$t1lc")"

  status="SCANNING"
  if [ "$t1c" -ge "$watch_th" ]; then status="WATCH"; fi
  if [ "$t1c" -ge "$alert_th" ] && [ "$t1r" -ge "$STRONG_RSSI" ]; then status="ALERT"; fi

  follow_now=0
  if [ -n "${t1mac:-}" ]; then
    if maybe_follow_alert "$t1mac" "$t1c" "$t1r" "$t1lc" "$loc_seq" "$watch_th"; then
      follow_now=1
      do_beep
      do_vibrate
      tlog "[FOLLOW] mac=$t1mac seen=$t1c rssi=$t1r locs=$t1lc loc=$loc_name(#$loc_seq)"
    fi
  fi

  ui_clear
  ui_title "DIGITAL TAILS"

  if [ "$follow_now" -eq 1 ]; then
    ui_log "***** FOLLOW ALERT *****"
    ui_log "Tail across $t1lc locations + persistent"
  fi

  ui_log "STATUS: $status   MODE: $mode   CONF: $conf"
  ui_log "LOC: $loc_name (#$loc_seq)  sim:$loc_sim"
  ui_log "SEEN: $seen_now   INT:${SCAN_INTERVAL}s  WIN:${WINDOW_SCANS}"
  ui_log "WATCH>=${watch_th}/${WINDOW_SCANS}  ALERT>=${alert_th}+RSSI>=${STRONG_RSSI}  Stable:${stable}"
  ui_log "FOLLOW: locs>=${FOLLOW_LOC_MIN} + rssi>=${FOLLOW_RSSI_MIN} + persistent (cooldown ${FOLLOW_COOLDOWN}s)"
  ui_log "KEY: !! strong+persistent   ! persistent   F=follow-qualified"
  ui_log "-------------------------"

  awk -F'|' -v W="$WINDOW_SCANS" '
    function count1(s,   i,c){ c=0; for(i=1;i<=length(s);i++) if(substr(s,i,1)=="1") c++; return c }
    BEGIN{OFS="\t"}
    {
      mac=$1; bits=$2; rssi=$3; locs=$4
      gsub(/[^01]/,"",bits)
      c=count1(bits)
      if (rssi=="") rssi=-99
      lc=0
      if (locs!="") { n=split(locs,a,","); lc=n } else lc=0
      print c, rssi, lc, mac
    }
  ' "$STATE" | sort -k1,1nr -k2,2nr | head -n "$MAX_SHOW" \
    | while IFS=$'\t' read -r c rssi lc mac; do
        short="$(echo "$mac" | awk -F: '{print $(NF-3)":"$(NF-2)":"$(NF-1)":"$NF}')"

        flag="  "
        if [ "$c" -ge "$alert_th" ] && [ "$rssi" -ge "$STRONG_RSSI" ]; then flag="!!"
        elif [ "$c" -ge "$watch_th" ]; then flag="! "
        fi

        mark=" "
        if [ "$lc" -ge "$FOLLOW_LOC_MIN" ] && [ "$rssi" -ge "$FOLLOW_RSSI_MIN" ] && [ "$c" -ge "$watch_th" ]; then
          mark="F"
        fi

        ui_log "$flag$mark $short  seen:$c/$WINDOW_SCANS  rssi:$rssi  locs:$lc  $(bars "$rssi")"
      done
}

# ----------------------------
# Start
# ----------------------------
ui_title "DIGITAL TAILS"
ui_log "Starting..."
ui_log "DB: $DB"
ui_log "Debug: $DBG"
tlog "[BOOT] started"

ensure_follow_db
ensure_loc_db

while true; do
  # Location first
  loc_line="$(get_location)"
  loc_hash="$(echo "$loc_line" | awk -F'|' '{print $1}')"
  loc_seq="$(echo "$loc_line" | awk -F'|' '{print $2+0}')"
  loc_name="$(echo "$loc_line" | awk -F'|' '{print $3}')"
  loc_sim="$(echo "$loc_line" | awk -F'|' '{print $4}')"

  if parse_seen; then
    update_state "$loc_hash"

    mode="$(detect_mode)"
    if [ "$mode" = "FAST" ]; then
      watch_th="$WATCH_MIN_FAST"
      alert_th="$ALERT_MIN_FAST"
    else
      watch_th="$WATCH_MIN"
      alert_th="$ALERT_MIN"
    fi

    render "$mode" "$watch_th" "$alert_th" "$loc_name" "$loc_seq" "$loc_sim"
  else
    ui_clear
    ui_title "DIGITAL TAILS"
    ui_log "No devices parsed from DB."
    ui_log "Is Recon running?"
    ui_log "Debug: $DBG"
  fi

  sleep "$SCAN_INTERVAL"
done
