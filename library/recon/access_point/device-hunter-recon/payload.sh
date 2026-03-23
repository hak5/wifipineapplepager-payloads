#!/bin/bash
# Title: Recon Device Hunter 
# Description: Auto-hunt a selected AP from Recon and display SSID
# Author: RocketGod + Notorious Squirrel (sidekick)

INPUT=/dev/input/event0
DB_CANDIDATES=(
  "/mmc/root/recon/recon.db"
  "/root/recon/recon.db"
  "/mmc/root/recon.db"
  "/root/recon.db"
)

# =========================
# CLEANUP
# =========================
cleanup() {
  pkill -9 -f "_pineap MONITOR" 2>/dev/null
  rm -f /tmp/hunter_signal 2>/dev/null
  _pineap EXAMINE CANCEL 2>/dev/null
  led_off 2>/dev/null
  sleep 0.1
}
trap cleanup EXIT INT TERM

pkill -9 -f "_pineap MONITOR" 2>/dev/null
rm -f /tmp/hunter_signal 2>/dev/null
_pineap EXAMINE CANCEL 2>/dev/null
sleep 0.3

# =========================
# LED CONTROL (safe)
# =========================
led_pattern() {
  . /lib/hak5/commands.sh 2>/dev/null || return 0
  HAK5_API_POST "system/led" "$1" >/dev/null 2>&1 || true
}
led_off() {
  led_pattern '{"color":"custom","raw_pattern":[{"onms":100,"offms":0,"next":false,"rgb":{"1":[false,false,false],"2":[false,false,false],"3":[false,false,false],"4":[false,false,false]}}]}'
}
led_signal_1() {
  led_pattern '{"color":"custom","raw_pattern":[{"onms":5000,"offms":0,"next":false,"rgb":{"1":[false,false,true],"2":[false,false,false],"3":[false,false,false],"4":[false,false,false]}}]}'
}
led_signal_2() {
  led_pattern '{"color":"custom","raw_pattern":[{"onms":5000,"offms":0,"next":false,"rgb":{"1":[false,true,true],"2":[false,true,true],"3":[false,false,false],"4":[false,false,false]}}]}'
}
led_signal_3() {
  led_pattern '{"color":"custom","raw_pattern":[{"onms":5000,"offms":0,"next":false,"rgb":{"1":[true,true,false],"2":[true,true,false],"3":[true,true,false],"4":[false,false,false]}}]}'
}
led_signal_4() {
  led_pattern '{"color":"custom","raw_pattern":[{"onms":5000,"offms":0,"next":false,"rgb":{"1":[true,false,false],"2":[true,false,false],"3":[true,false,false],"4":[true,false,false]}}]}'
}

# =========================
# SOUNDS (safe)
# =========================
click_weak()   { RINGTONE "W:d=32,o=4,b=200:c" & }
click_med()    { RINGTONE "M:d=32,o=5,b=200:c" & }
click_strong() { RINGTONE "S:d=32,o=6,b=200:c" & }
click_hot()    { RINGTONE "H:d=32,o=7,b=200:c" & }
play_start()   { RINGTONE "getkey" & }

# =========================
# BUTTON CHECK (A)
# =========================
check_for_A() {
  local data
  data=$(timeout 0.02 dd if=$INPUT bs=16 count=1 2>/dev/null | hexdump -e '16/1 "%02x "' 2>/dev/null)
  [ -z "$data" ] && return 1
  local type value keycode
  type=$(echo "$data" | cut -d' ' -f9-10)
  value=$(echo "$data" | cut -d' ' -f13)
  keycode=$(echo "$data" | cut -d' ' -f11-12)
  if [ "$type" = "01 00" ] && [ "$value" = "01" ]; then
    if [ "$keycode" = "31 01" ] || [ "$keycode" = "30 01" ]; then
      return 0
    fi
  fi
  return 1
}

# =========================
# HELPERS
# =========================
looks_like_mac() {
  echo "$1" | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

get_ssid_for_mac() {
  local mac="$1"

  # Try Recon API first
  local json ssid
  json=$(_pineap RECON APS limit=50 format=json 2>/dev/null)

  # Find the first ssid following the matching mac
  ssid=$(echo "$json" | grep -i "\"mac\":\"$mac\"" -A3 | grep '"ssid"' | head -n1 | sed 's/.*"ssid":"//;s/".*//')

  if [ -n "$ssid" ]; then
    echo "$ssid"
    return 0
  fi

  # Fallback: try recon.db if present (best-effort; schema may differ)
  if command -v sqlite3 >/dev/null 2>&1 && [ -f "/mmc/root/recon/recon.db" ]; then
    ssid=$(sqlite3 /mmc/root/recon/recon.db "
      SELECT ssid FROM access_points
      WHERE lower(mac)=lower('$mac')
      LIMIT 1;
    " 2>/dev/null | head -n1)
    [ -n "$ssid" ] && { echo "$ssid"; return 0; }
  fi

  echo "[Hidden SSID]"
  return 0
}

# =========================
# GET TARGET MAC
#   1) Try Recon DB (auto-detect schema)
#   2) Fall back to _pineap RECON APS json
# =========================
get_target_from_db() {
  command -v sqlite3 >/dev/null 2>&1 || return 1

  local db=""
  for f in "${DB_CANDIDATES[@]}"; do
    if [ -f "$f" ]; then
      db="$f"
      break
    fi
  done
  [ -z "$db" ] && return 1

  local tables
  tables=$(sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type='table';" 2>/dev/null) || return 1
  [ -z "$tables" ] && return 1

  local t c ts

  for t in access_points aps ap ap_table accesspoint wifi_access_points; do
    echo "$tables" | grep -qx "$t" || continue

    local cols
    cols=$(sqlite3 "$db" "PRAGMA table_info($t);" 2>/dev/null | awk -F'|' '{print $2}') || continue

    for c in mac bssid ap_mac ap_bssid; do
      echo "$cols" | grep -qx "$c" || continue

      for ts in last_seen lastseen seen updated_at ts; do
        echo "$cols" | grep -qx "$ts" || continue

        local mac
        mac=$(sqlite3 "$db" "SELECT $c FROM $t ORDER BY $ts DESC LIMIT 1;" 2>/dev/null | head -n1)
        if looks_like_mac "$mac"; then
          echo "$mac"
          return 0
        fi
      done

      local mac2
      mac2=$(sqlite3 "$db" "SELECT $c FROM $t LIMIT 1;" 2>/dev/null | head -n1)
      if looks_like_mac "$mac2"; then
        echo "$mac2"
        return 0
      fi
    done
  done

  for t in $tables; do
    local cols
    cols=$(sqlite3 "$db" "PRAGMA table_info($t);" 2>/dev/null | awk -F'|' '{print $2}') || continue

    for c in mac bssid; do
      echo "$cols" | grep -qx "$c" || continue
      local mac3
      mac3=$(sqlite3 "$db" "SELECT $c FROM $t LIMIT 1;" 2>/dev/null | head -n1)
      if looks_like_mac "$mac3"; then
        echo "$mac3"
        return 0
      fi
    done
  done

  return 1
}

get_target_from_recon_api() {
  local json mac
  json=$(_pineap RECON APS limit=1 format=json 2>/dev/null) || return 1
  mac=$(echo "$json" | grep -o '"mac":"[^"]*"' | head -n1 | sed 's/"mac":"//;s/"//')
  looks_like_mac "$mac" && { echo "$mac"; return 0; }
  return 1
}

# =========================
# TRACKING
# =========================
make_bar() {
  local sig=$1
  local strength=$(( (sig + 90) / 3 ))
  [ $strength -lt 1 ] && strength=1
  [ $strength -gt 20 ] && strength=20
  printf '%0*d' $strength 0 | tr '0' '#'
  printf '%0*d' $((20 - strength)) 0 | tr '0' '-'
}

track_target() {
  local mac="$1"
  local ssid=""

  # If this payload was launched from a selected AP in Recon on the Pager,
  # prefer the SSID that Recon reported for that AP to avoid mismatches.
  if [ "$mac" = "$_RECON_SELECTED_AP_MAC_ADDRESS" ] || [ "$mac" = "$_RECON_SELECTED_AP_BSSID" ]; then
    if [ -n "$_RECON_SELECTED_AP_SSID" ]; then
      ssid="$_RECON_SELECTED_AP_SSID"
    fi
  fi

  # Fallback: derive SSID from Recon API / recon.db
  [ -z "$ssid" ] && ssid=$(get_ssid_for_mac "$mac")

  LOG ""
  LOG "HUNTING:"
  LOG "$ssid"
  LOG "$mac"
  LOG "A = Stop"
  LOG ""

  pkill -9 -f "_pineap MONITOR" 2>/dev/null
  sleep 0.2
  rm -f /tmp/hunter_signal 2>/dev/null

  _pineap MONITOR "$mac" any rate=200 timeout=3600 > /tmp/hunter_signal 2>&1 &
  local monitor_pid=$!

  sleep 0.5
  if ! kill -0 "$monitor_pid" 2>/dev/null; then
    LOG "Monitor failed to start!"
    exit 1
  fi

  local click_counter=0

  while kill -0 "$monitor_pid" 2>/dev/null; do
    if check_for_A; then
      kill -9 "$monitor_pid" 2>/dev/null
      wait "$monitor_pid" 2>/dev/null
      LOG "Stopped."
      return 0
    fi

    local sig
    sig=$(tail -1 /tmp/hunter_signal 2>/dev/null)

    if [ -n "$sig" ] && [[ "$sig" =~ ^-[0-9]+$ ]]; then
      local bar
      bar=$(make_bar "$sig")

      local level=1
      [ "$sig" -ge -75 ] && level=2
      [ "$sig" -ge -55 ] && level=3
      [ "$sig" -ge -35 ] && level=4

      case $level in
        1) led_signal_1 ;;
        2) led_signal_2 ;;
        3) led_signal_3 ;;
        4) led_signal_4; VIBRATE 20 ;;
      esac

      click_counter=$((click_counter + 1))
      local click_rate=$((5 - level))
      [ $click_rate -lt 1 ] && click_rate=1

      if [ $((click_counter % click_rate)) -eq 0 ]; then
        case $level in
          1) click_weak ;;
          2) click_med ;;
          3) click_strong ;;
          4) click_hot ;;
        esac
      fi

      LOG "${sig}dBm [${bar}]"
    fi

    sleep 0.1
  done
}

# =========================
# MAIN
# =========================
LOG "DEVICE HUNTER"
LOG "AUTO-HUNT + SSID"
LOG ""

play_start

TARGET_MAC=""

# Prefer the AP the user actually selected in Recon (Pager env vars),
# then fall back to auto-detection from DB / Recon API.
if looks_like_mac "$_RECON_SELECTED_AP_MAC_ADDRESS"; then
  TARGET_MAC="$_RECON_SELECTED_AP_MAC_ADDRESS"
elif looks_like_mac "$_RECON_SELECTED_AP_BSSID"; then
  TARGET_MAC="$_RECON_SELECTED_AP_BSSID"
else
  TARGET_MAC="$(get_target_from_db 2>/dev/null)" || true
  if ! looks_like_mac "$TARGET_MAC"; then
    TARGET_MAC="$(get_target_from_recon_api 2>/dev/null)" || true
  fi
fi

if ! looks_like_mac "$TARGET_MAC"; then
  LOG "No AP found in Recon."
  LOG "Start Recon scan, then run this payload from an AP."
  exit 1
fi

LOG "Target locked:"
LOG "$TARGET_MAC"

track_target "$TARGET_MAC"
LOG "Done!"
 
