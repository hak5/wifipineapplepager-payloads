#!/bin/bash
# Title: Remote ID Radar
# Author: JustCallMeKoko
# Description: Passively detects and tracks ASTM/OpenDroneID broadcasts over Wi-Fi and Bluetooth
# Version: 0.1.5
# Category: Reconnaissance

LAUNCH_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/mmc/usr/bin:$PATH"
if [ -f "$LAUNCH_DIR/remote_id_monitor.py" ]; then
  DIR="$LAUNCH_DIR"
elif [ -f /root/payloads/user/reconnaissance/remote_id_monitor/remote_id_monitor.py ]; then
  DIR=/root/payloads/user/reconnaissance/remote_id_monitor
elif [ -f /mmc/root/payloads/user/reconnaissance/remote_id_monitor/remote_id_monitor.py ]; then
  DIR=/mmc/root/payloads/user/reconnaissance/remote_id_monitor
else
  ERROR_DIALOG "Remote ID Radar worker is missing."
  exit 1
fi

WORKER="$DIR/remote_id_monitor.py"
SPLASH="$DIR/splash.png"
STATE=/tmp/remote-id-radar.json
LOGFILE=/tmp/remote-id-radar.log
PID=""
LOCKDIR=/tmp/remote-id-radar.lock
LOCKED=0
SETTINGS=/root/.config/remote_id_radar/settings.json

cleanup() {
  if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null
    wait "$PID" 2>/dev/null
    PID=""
  fi
  if [ "$LOCKED" = 1 ] && [ -d "$LOCKDIR" ]; then
    owner=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    [ "$owner" = "$$" ] && rm -rf "$LOCKDIR"
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

configure_python() {
  PYTHON_BIN=""
  for candidate in /usr/bin/python3 /mmc/usr/bin/python3; do
    [ -x "$candidate" ] || continue
    if [ "$candidate" = /mmc/usr/bin/python3 ]; then
      export LD_LIBRARY_PATH="/mmc/usr/lib:/mmc/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    PYTHON_VERSION=$("$candidate" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null) || continue
    PYTHON_BIN="$candidate"
    break
  done
  [ -n "$PYTHON_BIN" ] || return 1
  PYTHON_MMCLIB="/mmc/usr/lib/python$PYTHON_VERSION"
  if [ -d "$PYTHON_MMCLIB" ]; then
    export PYTHONPATH="$PYTHON_MMCLIB:$PYTHON_MMCLIB/lib-dynload${PYTHONPATH:+:$PYTHONPATH}"
  fi
}
install_python() {
  if ! CONFIRMATION_DIALOG "Remote ID Radar needs Python 3.\n\nInstall python3-light to MMC now?\n\nRequires internet and persistent storage changes."; then
    return 2
  fi
  INSTALL_LOG=/tmp/remote-id-radar-python-install.$$.log
  LOG cyan "Updating package lists..."
  opkg update >"$INSTALL_LOG" 2>&1 || { ERROR_DIALOG "Package list update failed. Check internet access. See $INSTALL_LOG"; return 1; }
  LOG cyan "Installing or repairing python3-light on MMC..."
  opkg -d mmc --force-reinstall install python3-light >>"$INSTALL_LOG" 2>&1 || { ERROR_DIALOG "Python installation failed. See $INSTALL_LOG"; return 1; }
  configure_python || { ERROR_DIALOG "Python installed but is not executable. See $INSTALL_LOG"; return 1; }
}
if ! configure_python; then
  install_python
  install_rc=$?
  [ "$install_rc" -eq 2 ] && exit 0
  [ "$install_rc" -eq 0 ] || exit 1
fi
command -v tcpdump >/dev/null 2>&1 || { ERROR_DIALOG "The stock tcpdump package is required."; exit 1; }
iw dev wlan1mon info >/dev/null 2>&1 || { ERROR_DIALOG "wlan1mon is unavailable."; exit 1; }
STARTUP_LOG=/tmp/remote-id-radar-startup.$$.log
if ! PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -B "$WORKER" --self-check >"$STARTUP_LOG" 2>&1; then
  if grep -Eq "ImportError|ModuleNotFoundError|No module named|cannot open shared object file" "$STARTUP_LOG"; then
    install_python
    install_rc=$?
    [ "$install_rc" -eq 2 ] && exit 0
    [ "$install_rc" -eq 0 ] || exit 1
    if ! PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -B "$WORKER" --self-check >"$STARTUP_LOG" 2>&1; then
      ERROR_DIALOG "Python is still incomplete. See $STARTUP_LOG"
      exit 1
    fi
  elif grep -Eq "SyntaxError|IndentationError" "$STARTUP_LOG"; then
    ERROR_DIALOG "Remote ID Radar worker is damaged. Reinstall the payload. See $STARTUP_LOG"
    exit 1
  else
    ERROR_DIALOG "Remote ID Radar could not start. See $STARTUP_LOG"
    exit 1
  fi
fi
rm -f "$STARTUP_LOG"

if ! mkdir "$LOCKDIR" 2>/dev/null; then
  owner=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    ERROR_DIALOG "Remote ID Radar is already running."
    exit 1
  fi
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" || { ERROR_DIALOG "Could not acquire the monitor lock."; exit 1; }
fi
printf '%s\n' "$$" >"$LOCKDIR/pid"
LOCKED=1

show_devices() {
  [ -s "$STATE" ] || { PROMPT "No Remote ID session data is available."; return; }
  CENSOR_FLAG=""
  [ "$("$PYTHON_BIN" "$WORKER" --get-censor --settings "$SETTINGS")" = 1 ] && CENSOR_FLAG=--censor
  mapfile -t devices < <("$PYTHON_BIN" "$WORKER" --list-state "$STATE" $CENSOR_FLAG)
  [ "${#devices[@]}" -gt 0 ] || devices=("No Remote ID devices")
  if [ "${devices[0]}" = "No Remote ID devices" ]; then
    PROMPT "No Remote ID devices were detected."
    return
  fi
  selected=$(LIST_PICKER "Remote ID devices" "${devices[@]}" "${devices[0]}") || return
  index=$(printf '%s' "$selected" | sed -n 's/^\([0-9][0-9]*\)\..*/\1/p')
  [ -n "$index" ] || return
  detail=$("$PYTHON_BIN" "$WORKER" --detail-state "$STATE" --index "$((index - 1))" $CENSOR_FLAG)
  PROMPT "$detail"
}

run_monitor() {
  timestamp=$(date +%Y%m%d_%H%M%S)
  if [ -d /mmc/root/loot ] && [ -w /mmc/root/loot ]; then
    loot_dir=/mmc/root/loot/remote_id_monitor
  else
    loot_dir=/root/loot/remote_id_monitor
  fi
  mkdir -p "$loot_dir"
  events="$loot_dir/remote_id_${timestamp}.jsonl"
  csv="$loot_dir/remote_id_${timestamp}.csv"
  gpx="$loot_dir/remote_id_${timestamp}.gpx"
  rm -f "$STATE"
  : >"$LOGFILE"
  "$PYTHON_BIN" "$WORKER" --run --interface wlan1mon --wifi-channel 6 --state "$STATE" --events "$events" --csv "$csv" --gpx "$gpx" >>"$LOGFILE" 2>&1 &
  PID=$!
  CENSOR_FLAG=""
  [ "$("$PYTHON_BIN" "$WORKER" --get-censor --settings "$SETTINGS")" = 1 ] && CENSOR_FLAG=--censor

  LOG cyan "REMOTE ID RADAR"
  LOG "Passive Wi-Fi + Bluetooth monitor"
  LOG "Press A to stop"
  last_render=""
  last_event=0
  last_heartbeat=0
  while kill -0 "$PID" 2>/dev/null; do
    if [ -s "$STATE" ]; then
      render=$("$PYTHON_BIN" "$WORKER" --render-state "$STATE" $CENSOR_FLAG 2>/dev/null || true)
      event=$("$PYTHON_BIN" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("event_seq",0))' "$STATE" 2>/dev/null || echo 0)
      now=$(date +%s)
      if [ "$event" -gt "$last_event" ] 2>/dev/null; then
        VIBRATE 200 >/dev/null 2>&1 || true
        LOG green "NEW REMOTE ID DEVICE"
        last_event="$event"
      fi
      if [ "$render" != "$last_render" ] || [ $((now - last_heartbeat)) -ge 10 ]; then
        if echo "$render" | grep -q '^WARN '; then
          LOG red "$render"
        elif echo "$render" | grep -q '^ACTIVE [1-9]'; then
          LOG green "$render"
        else
          LOG cyan "$render"
        fi
        last_render="$render"
        last_heartbeat="$now"
      fi
    fi
    timeout 2 WAIT_FOR_BUTTON_PRESS A >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] && break
    [ "$rc" -eq 124 ] || sleep 1
  done

  if kill -0 "$PID" 2>/dev/null; then kill "$PID" 2>/dev/null; fi
  wait "$PID" 2>/dev/null
  PID=""

  if [ ! -s "$STATE" ]; then
    ERROR_DIALOG "Monitor stopped before producing status. See $LOGFILE"
    return
  fi
  summary=$("$PYTHON_BIN" "$WORKER" --render-state "$STATE" $CENSOR_FLAG)
  PROMPT "$summary\n\nLoot: $loot_dir"
  show_devices
}

[ -f "$SPLASH" ] && PROMPT_IMAGE "$SPLASH"
while true; do
  censor_state=OFF
  [ "$("$PYTHON_BIN" "$WORKER" --get-censor --settings "$SETTINGS")" = 1 ] && censor_state=ON
  action=$(LIST_PICKER "REMOTE ID RADAR" "Start live monitor" "View last detections" "Censor mode: $censor_state" "About" "Exit" "Start live monitor") || exit 0
  case "$action" in
    "Start live monitor") run_monitor ;;
    "View last detections") show_devices ;;
    "Censor mode: "*)
      if [ "$censor_state" = ON ]; then
        if "$PYTHON_BIN" "$WORKER" --set-censor off --settings "$SETTINGS" &&
           [ "$("$PYTHON_BIN" "$WORKER" --get-censor --settings "$SETTINGS")" = 0 ]; then
          PROMPT "Censor mode disabled."
        else
          ERROR_DIALOG "Could not save the censor setting."
        fi
      else
        if "$PYTHON_BIN" "$WORKER" --set-censor on --settings "$SETTINGS" &&
           [ "$("$PYTHON_BIN" "$WORKER" --get-censor --settings "$SETTINGS")" = 1 ]; then
          PROMPT "Censor mode enabled."
        else
          ERROR_DIALOG "Could not save the censor setting."
        fi
      fi
      ;;
    "About") PROMPT "Remote ID Radar v0.1.5\n\nPassive ASTM/OpenDroneID monitor for Wi-Fi Beacon, Wi-Fi NAN, and Bluetooth broadcasts. Wi-Fi uses Remote ID channel 6 and restores the prior channel when stopped.\n\nCensor mode masks on-screen identifiers and persists across payload restarts. Loot retains complete records.\n\nLogs JSONL, CSV, and GPX under the MMC loot directory when available." ;;
    "Exit") exit 0 ;;
  esac
done
