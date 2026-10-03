#!/bin/bash
# Title: RF-BUDDY
# Description: Passive 2.4/5 GHz interference finder: live channel meter, lock-on tracking, and survey log.
# Author: Henry Hu
# Version: 1.1
# Category: Reconnaissance
# Source: https://github.com/ninedter/DEFCON-DEFENSE
#
# Walk the office with this running. The overview ranks every channel; lock on
# to the worst one and follow the score toward the source. Recon keeps running;
# RF-BUDDY only locks it to one channel at a time and hands the channel back on
# every exit path. Nothing is ever transmitted.

# ---- CONFIG ----------------------------------------------------------------
OFFICE_SSID=""            # your office SSID; enables WEAK COVERAGE (blank = off)
DWELL_MS=250              # overview dwell per channel, milliseconds
RETRY_HIGH_PCT=25         # retry % at/above this on a quiet channel -> INTERFERENCE
AIRTIME_HIGH_PCT=50       # Wi-Fi airtime % at/above this -> CONGESTION
OVERLAP_MIN_DBM=-70       # neighbour AP louder than this -> CHANNEL OVERLAP
BT_DENSE_COUNT=30         # nearby BLE devices for BT DENSE
WEAK_SIGNAL_DBM=-70       # office AP quieter than this -> WEAK COVERAGE
LOG_MAX_MB=20             # per-session log cap
MIN_FREE_MB=64            # pause logging below this much free storage
TICK_FREQ_HZ=2000         # buzzer pitch for the lock-on tick, Hz
TICK_VOLUME=60            # buzzer loudness for the lock-on tick, 0-100
# ----------------------------------------------------------------------------

# The Pager starts payloads without an exported PATH; child processes (the UI
# binary and the tools it runs) need one.
export PATH="${PATH:-/usr/sbin:/usr/bin:/sbin:/bin}"

PAYLOAD_ROOT="/root/payloads"
# The Pager payload runner may execute payload.sh from a temporary directory,
# so prefer the stable installed payload path for the UI binary.
INSTALLED_DIR="${RF_BUDDY_INSTALL_DIR:-$PAYLOAD_ROOT/user/reconnaissance/RF-BUDDY}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MMC_DIR="/mmc/root/payloads/user/reconnaissance/RF-BUDDY"
if [ -f "$INSTALLED_DIR/payload.sh" ]; then
  DIR="$INSTALLED_DIR"
elif [ -f "$MMC_DIR/payload.sh" ]; then
  DIR="$MMC_DIR"
else
  DIR="$SOURCE_DIR"
fi
UI_BINARY="${RF_BUDDY_UI_BINARY:-$DIR/rf-buddy-ui}"
LOOT_ROOT="${RF_BUDDY_LOOT_DIR:-/root/loot/rf_buddy}"
RUN_DIR="${RF_BUDDY_RUN_DIR:-/tmp/rf_buddy}"
LOCK_DIR="${RF_BUDDY_LOCK_DIR:-/tmp/rf_buddy.lock}"
MON_IFACE="wlan1mon"
BT_IFACE="hci0"
BUZZER_DIR="${RF_BUDDY_BUZZER_DIR:-/sys/class/leds/buzzer}"
READY_FILE="$RUN_DIR/ready"

UI_PID=""
FROZEN_PIDS=""
WATCHDOG_PID=""
LOCKED=0
CLEANED=0

rf_lock_acquire() {
  local owner=""
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    LOCKED=1
    return 0
  fi
  [ -f "$LOCK_DIR/pid" ] && owner="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  [ -n "$owner" ] || return 1
  if printf '%s' "$owner" | grep -Eq '^[0-9]+$' && kill -0 "$owner" 2>/dev/null; then
    return 1
  fi
  rm -f "$LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || return 1
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  LOCKED=1
}

rf_lock_release() {
  [ "$LOCKED" = "1" ] || return 0
  rm -f "$LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
  LOCKED=0
}

# Hand the channel back to normal Recon hopping. The UI binary also does this
# on exit; repeating it here covers crashes and kills.
release_channel() {
  _pineap EXAMINE CANCEL >/dev/null 2>&1 || true
}

# Freeze the stock Pager UI so it stops drawing over our framebuffer and
# reading the buttons. No hak5 API command works while it is frozen, so
# nothing may call hak5 API commands between freeze and resume.
stock_ui_freeze() {
  local pids
  pids="$(pidof pineapple 2>/dev/null)"
  [ -n "$pids" ] || return 0
  # Remember the pids first: even a partially applied STOP must be resumed.
  FROZEN_PIDS="$pids"
  # shellcheck disable=SC2086
  kill -STOP $pids 2>/dev/null || return 1
}

# Idempotent: continue what we froze, and restart the stock UI if it is gone.
stock_ui_resume() {
  if [ -n "$FROZEN_PIDS" ]; then
    # shellcheck disable=SC2086
    kill -CONT $FROZEN_PIDS 2>/dev/null || true
    FROZEN_PIDS=""
  fi
  local initd="${RF_BUDDY_PINEAPPLE_INITD:-/etc/init.d/pineapplepager}"
  if [ -z "$(pidof pineapple 2>/dev/null)" ] && [ -x "$initd" ]; then
    # Cleanup runs with INT/TERM/HUP ignored; do not hand that to the UI.
    ( trap - INT TERM HUP; "$initd" start >/dev/null 2>&1 ) || true
  fi
}

# Body of the freeze watchdog. It runs in its own process (see
# rf_watchdog_start) and must stand alone: it only uses its arguments, never the
# parent's state, and never calls hak5 API commands. When the payload is gone
# (e.g. SIGKILLed) it undoes everything the payload did.
rf_watchdog_body() {
  trap '' HUP INT TERM
  local ppid="$1" uipid="$2" frozen="$3" initd="$4" buzdir="$5" lockdir="$6"
  local rundir="$7"
  local i=0 owner=""
  # First statement: publish our own pid ($$ is this bash). setsid may fork,
  # so the launcher's $! can name a short-lived parent instead of us.
  echo $$ > "$rundir/watchdog.pid"
  while kill -0 "$ppid" 2>/dev/null; do sleep 1; done
  # A normal exit marks itself clean before killing us; never act on it.
  [ -e "$rundir/clean-exit" ] && return 0
  if [ -n "$uipid" ] && kill -0 "$uipid" 2>/dev/null; then
    kill "$uipid" 2>/dev/null || true
    while kill -0 "$uipid" 2>/dev/null && [ "$i" -lt 30 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    kill -0 "$uipid" 2>/dev/null && kill -KILL "$uipid" 2>/dev/null
  fi
  # shellcheck disable=SC2086
  [ -n "$frozen" ] && kill -CONT $frozen 2>/dev/null
  if [ -z "$(pidof pineapple 2>/dev/null)" ] && [ -x "$initd" ]; then
    ( trap - INT TERM HUP; "$initd" start >/dev/null 2>&1 )
  fi
  [ -w "$buzdir/brightness" ] && echo 0 > "$buzdir/brightness" 2>/dev/null
  _pineap EXAMINE CANCEL >/dev/null 2>&1
  [ -f "$lockdir/pid" ] && owner="$(cat "$lockdir/pid" 2>/dev/null)"
  if [ "$owner" = "$ppid" ]; then
    rm -f "$lockdir/pid" 2>/dev/null
    rmdir "$lockdir" 2>/dev/null
  fi
  return 0
}

# Start the detached watchdog right after a successful freeze.
rf_watchdog_start() {
  local initd="${RF_BUDDY_PINEAPPLE_INITD:-/etc/init.d/pineapplepager}"
  local script
  script="$(declare -f rf_watchdog_body); rf_watchdog_body \"\$@\""
  if command -v setsid >/dev/null 2>&1; then
    setsid bash -c "$script" rf-buddy-watchdog "$$" "$UI_PID" "$FROZEN_PIDS" \
      "$initd" "$BUZZER_DIR" "$LOCK_DIR" "$RUN_DIR" </dev/null >/dev/null 2>&1 &
  else
    bash -c "$script" rf-buddy-watchdog "$$" "$UI_PID" "$FROZEN_PIDS" \
      "$initd" "$BUZZER_DIR" "$LOCK_DIR" "$RUN_DIR" </dev/null >/dev/null 2>&1 &
  fi
  WATCHDOG_PID=$!
  disown "$WATCHDOG_PID" 2>/dev/null || true
}

# Stop our UI: TERM, then KILL after 3 s.
stop_ui() {
  local i=0
  [ -n "$UI_PID" ] || return 0
  if kill -0 "$UI_PID" 2>/dev/null; then
    kill "$UI_PID" 2>/dev/null || true
    while kill -0 "$UI_PID" 2>/dev/null && [ "$i" -lt 60 ]; do
      sleep 0.05
      i=$((i + 1))
    done
    kill -0 "$UI_PID" 2>/dev/null && kill -KILL "$UI_PID" 2>/dev/null
  fi
  wait "$UI_PID" 2>/dev/null || true
  UI_PID=""
  return 0
}

rf_buddy_cleanup() {
  trap '' INT TERM HUP
  [ "$CLEANED" = "1" ] && return 0
  CLEANED=1
  stop_ui
  # Hand the stock UI back first; nothing below needs the UI to stay frozen.
  stock_ui_resume
  # The UI is back; the watchdog must not fire a second time.
  # Mark the exit clean first so a watchdog that survives the kill stands down.
  touch "$RUN_DIR/clean-exit" 2>/dev/null || true
  local wpid=""
  [ -f "$RUN_DIR/watchdog.pid" ] && wpid="$(cat "$RUN_DIR/watchdog.pid" 2>/dev/null)"
  [ -n "$wpid" ] || wpid="$WATCHDOG_PID"
  [ -n "$wpid" ] && kill -KILL "$wpid" 2>/dev/null
  WATCHDOG_PID=""
  # Backstop: a SIGKILLed UI must never leave the buzzer sounding.
  [ -w "$BUZZER_DIR/brightness" ] && echo 0 > "$BUZZER_DIR/brightness" 2>/dev/null || true
  release_channel
  rm -f "$READY_FILE" "$RUN_DIR/watchdog.pid"
  rf_lock_release
}

rf_buddy_main() {
  local rc=0
  mkdir -p "$RUN_DIR" "$LOOT_ROOT"
  if [ ! -x "$UI_BINARY" ]; then
    ERROR_DIALOG "RF-BUDDY is incomplete:\nmissing rf-buddy-ui"
    return 1
  fi
  if ! rf_lock_acquire; then
    ERROR_DIALOG "RF-BUDDY is already running."
    return 0
  fi
  rm -f "$RUN_DIR/clean-exit" "$RUN_DIR/watchdog.pid"
  trap rf_buddy_cleanup EXIT
  trap 'rf_buddy_cleanup; exit 130' INT
  trap 'rf_buddy_cleanup; exit 143' TERM
  trap 'rf_buddy_cleanup; exit 129' HUP

  LOG "RF-BUDDY: Recon stays on; locked to one channel at a time."
  rm -f "$READY_FILE"

  "$UI_BINARY" \
    --framebuffer /dev/fb0 \
    --input-device /dev/input/event0 \
    --ready-file "$READY_FILE" \
    --iface "$MON_IFACE" \
    --bt-iface "$BT_IFACE" \
    --loot-dir "$LOOT_ROOT" \
    --tick-freq-hz "$TICK_FREQ_HZ" \
    --tick-volume "$TICK_VOLUME" \
    --office-ssid "$OFFICE_SSID" \
    --dwell-ms "$DWELL_MS" \
    --log-max-mb "$LOG_MAX_MB" \
    --min-free-mb "$MIN_FREE_MB" \
    --retry-high-pct "$RETRY_HIGH_PCT" \
    --airtime-high-pct "$AIRTIME_HIGH_PCT" \
    --overlap-min-dbm "$OVERLAP_MIN_DBM" \
    --bt-dense-count "$BT_DENSE_COUNT" \
    --weak-signal-dbm "$WEAK_SIGNAL_DBM" &
  UI_PID=$!
  # LOG above was the last hak5 API call. Wait for the UI's first frame, then
  # freeze the stock UI; it is resumed in cleanup.
  local i=0
  while [ ! -f "$READY_FILE" ] && kill -0 "$UI_PID" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  if [ -f "$READY_FILE" ]; then
    stock_ui_freeze || true
    [ -n "$FROZEN_PIDS" ] && rf_watchdog_start
  fi
  wait "$UI_PID"
  rc=$?
  UI_PID=""
  rf_buddy_cleanup
  return "$rc"
}

if [ "${RF_BUDDY_SOURCE_ONLY:-0}" != "1" ]; then
  rf_buddy_main
  exit $?
fi
