#!/bin/bash
# Title: Remote ID Radar
# Author: JustCallMeKoko
# Description: Passively detects and maps ASTM/OpenDroneID broadcasts over Wi-Fi and Bluetooth
# Version: 0.2.0
# Category: Reconnaissance
LAUNCH_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/mmc/usr/sbin:/mmc/usr/bin:/mmc/sbin:/mmc/bin:$PATH"
if [ -f "$LAUNCH_DIR/remote_id_monitor.py" ]; then DIR="$LAUNCH_DIR"; elif [ -f /root/payloads/user/reconnaissance/remote_id_monitor/remote_id_monitor.py ]; then DIR=/root/payloads/user/reconnaissance/remote_id_monitor; elif [ -f /mmc/root/payloads/user/reconnaissance/remote_id_monitor/remote_id_monitor.py ]; then DIR=/mmc/root/payloads/user/reconnaissance/remote_id_monitor; else ERROR_DIALOG "Remote ID Radar worker is missing."; exit 1; fi
WORKER="$DIR/remote_id_monitor.py"; GUI="$DIR/gui.py"; SPLASH="$DIR/splash.png"
STATE=/tmp/remote-id-radar.json; LOGFILE=/tmp/remote-id-radar.log; GUI_LOG=/tmp/remote-id-radar-gui.log; SETUP_LOG=/tmp/remote-id-radar-gui-setup.log
LOCK=/tmp/remote-id-radar.lock; SETTINGS=/root/.config/remote_id_radar/settings.json
PID=""; GUI_PID=""; DISPLAY_SET=0
if ! mkdir "$LOCK" 2>/dev/null; then
  LOCK_PID=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null && tr '\0' ' ' <"/proc/$LOCK_PID/cmdline" 2>/dev/null | grep -q 'remote_id_monitor/payload.sh'; then ERROR_DIALOG "Remote ID Radar is already running."; exit 1; fi
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || { ERROR_DIALOG "Could not recover the monitor lock."; exit 1; }
fi
printf '%s\n' "$$" >"$LOCK/pid"
stop_pid() { local pid="$1" count=0; [ -n "$pid" ] || return 0; kill "$pid" 2>/dev/null || true; while kill -0 "$pid" 2>/dev/null && [ "$count" -lt 75 ]; do sleep 0.2; count=$((count+1)); done; kill -9 "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
cleanup() { stop_pid "$GUI_PID"; GUI_PID=""; stop_pid "$PID"; PID=""; if [ "$DISPLAY_SET" = 1 ]; then UI_RELEASE >/dev/null 2>&1 || true; DISPLAY_SET=0; fi; rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT; trap 'exit 0' INT TERM
confirmed() { local response; response=$(CONFIRMATION_DIALOG "$1") || return 1; [ -n "${DUCKYSCRIPT_USER_CONFIRMED:-}" ] && [ "$response" = "$DUCKYSCRIPT_USER_CONFIRMED" ]; }
bound_log() { local file="$1" temp; [ -f "$file" ] || return 0; [ "$(wc -c <"$file")" -le 65536 ] && return 0; temp="$file.tail.$$"; tail -c 65536 "$file" >"$temp" && mv "$temp" "$file"; }
configure_python() {
  PYTHON_BIN=""
  for candidate in /usr/bin/python3 /mmc/usr/bin/python3; do
    [ -x "$candidate" ] || continue
    if [ "$candidate" = /mmc/usr/bin/python3 ]; then export LD_LIBRARY_PATH="/mmc/usr/lib:/mmc/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"; fi
    PYTHON_VERSION=$("$candidate" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null) || continue; PYTHON_BIN="$candidate"; break
  done
  [ -n "$PYTHON_BIN" ] || return 1; PYTHON_MMCLIB="/mmc/usr/lib/python$PYTHON_VERSION"; [ ! -d "$PYTHON_MMCLIB" ] || export PYTHONPATH="$PYTHON_MMCLIB:$PYTHON_MMCLIB/lib-dynload${PYTHONPATH:+:$PYTHONPATH}"
}
install_python() {
  confirmed "Remote ID Radar needs Python 3.

Install python3-light to MMC now?

Requires internet and persistent storage changes." || return 2
  INSTALL_LOG=/tmp/remote-id-radar-python-install.$$.log; : >"$INSTALL_LOG"; LOG cyan "Updating package lists..."
  opkg update >>"$INSTALL_LOG" 2>&1 || { bound_log "$INSTALL_LOG"; ERROR_DIALOG "Package update failed. See $INSTALL_LOG"; return 1; }
  LOG cyan "Installing python3-light on MMC..."; opkg -d mmc --force-reinstall install python3-light >>"$INSTALL_LOG" 2>&1 || { bound_log "$INSTALL_LOG"; ERROR_DIALOG "Python installation failed. See $INSTALL_LOG"; return 1; }
  bound_log "$INSTALL_LOG"; configure_python
}
install_gui() {
  : >"$SETUP_LOG"; LOG cyan "Installing Pager GUI support..."
  if ! PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -B -c 'import ctypes' >>"$SETUP_LOG" 2>&1; then
    # A partially unreachable feed makes opkg update return nonzero even when
    # the package feed we need is healthy. Let the package install decide.
    opkg update >>"$SETUP_LOG" 2>&1 || true
    opkg -d mmc --force-reinstall install python3-ctypes >>"$SETUP_LOG" 2>&1 || { bound_log "$SETUP_LOG"; return 1; }
    configure_python || return 1
    PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -B -c 'import ctypes' >>"$SETUP_LOG" 2>&1 || { bound_log "$SETUP_LOG"; return 1; }
  fi
  bash "$DIR/install_pagerctl.sh" >>"$SETUP_LOG" 2>&1 || { bound_log "$SETUP_LOG"; return 1; }
  configure_python || return 1; PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -B "$GUI" --check >>"$SETUP_LOG" 2>&1; rc=$?; bound_log "$SETUP_LOG"; return "$rc"
}
if ! configure_python; then install_python; rc=$?; [ "$rc" -eq 2 ] && exit 0; [ "$rc" -eq 0 ] || exit 1; fi
command -v tcpdump >/dev/null 2>&1 || { ERROR_DIALOG "The stock tcpdump package is required."; exit 1; }
iw dev wlan1mon info >/dev/null 2>&1 || { ERROR_DIALOG "wlan1mon is unavailable."; exit 1; }
STARTUP_LOG=/tmp/remote-id-radar-startup.$$.log
if ! PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -B "$WORKER" --self-check >"$STARTUP_LOG" 2>&1; then
  bound_log "$STARTUP_LOG"
  if grep -Eq "ImportError|ModuleNotFoundError|No module named|cannot open shared object file" "$STARTUP_LOG"; then
    install_python; rc=$?; [ "$rc" -eq 2 ] && exit 0; [ "$rc" -eq 0 ] || exit 1
    PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -B "$WORKER" --self-check >>"$STARTUP_LOG" 2>&1 || { bound_log "$STARTUP_LOG"; ERROR_DIALOG "Python is incomplete. See $STARTUP_LOG"; exit 1; }
  elif grep -Eq "SyntaxError|IndentationError" "$STARTUP_LOG"; then ERROR_DIALOG "Remote ID Radar is damaged. Reinstall it. See $STARTUP_LOG"; exit 1
  else ERROR_DIALOG "Remote ID Radar could not start. See $STARTUP_LOG"; exit 1; fi
fi
rm -f "$STARTUP_LOG"; : >"$SETUP_LOG"
if ! PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -B "$GUI" --check >>"$SETUP_LOG" 2>&1; then
  bound_log "$SETUP_LOG"; confirmed "The live map needs pinned pagerctl and python3-ctypes.

Download and install them to MMC?

Requires internet and persistent storage changes." || exit 0
  install_gui || { ERROR_DIALOG "GUI setup failed. See $SETUP_LOG"; exit 1; }
fi
[ -f "$SPLASH" ] && PROMPT_IMAGE "$SPLASH"
while true; do
  censor_state=OFF; [ "$("$PYTHON_BIN" "$WORKER" --get-censor --settings "$SETTINGS")" = 1 ] && censor_state=ON
  action=$(LIST_PICKER "REMOTE ID RADAR" "Start live map" "Censor mode: $censor_state" "Exit" "Start live map") || exit 0
  case "$action" in
    "Start live map") break ;;
    "Censor mode: "*)
      [ "$censor_state" = ON ] && next=off || next=on
      "$PYTHON_BIN" "$WORKER" --set-censor "$next" --settings "$SETTINGS" || { ERROR_DIALOG "Could not save censor mode."; exit 1; }
      ;;
    "Exit") exit 0 ;;
  esac
done
timestamp=$(date +%Y%m%d_%H%M%S); if [ -d /mmc/root/loot ] && [ -w /mmc/root/loot ]; then loot_dir=/mmc/root/loot/remote_id_monitor; else loot_dir=/root/loot/remote_id_monitor; fi; mkdir -p "$loot_dir"
events="$loot_dir/remote_id_${timestamp}.jsonl"; csv="$loot_dir/remote_id_${timestamp}.csv"; gpx="$loot_dir/remote_id_${timestamp}.gpx"
rm -f "$STATE"; : >"$LOGFILE"; : >"$GUI_LOG"
"$PYTHON_BIN" "$WORKER" --run --interface wlan1mon --wifi-channel 6 --state "$STATE" --events "$events" --csv "$csv" --gpx "$gpx" >>"$LOGFILE" 2>&1 & PID=$!
UI_TAKEOVER >/dev/null 2>&1 || { ERROR_DIALOG "Could not take over the Pager display."; exit 1; }; DISPLAY_SET=1
CENSOR_FLAG=""; [ "$censor_state" = ON ] && CENSOR_FLAG=--censor
PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -B "$GUI" --state "$STATE" --worker-pid "$PID" $CENSOR_FLAG 2>>"$GUI_LOG" & GUI_PID=$!
wait "$GUI_PID"; GUI_RC=$?; GUI_PID=""; cleanup; trap - EXIT; bound_log "$GUI_LOG"; bound_log "$LOGFILE"
if [ "$GUI_RC" -ne 0 ]; then ERROR_DIALOG "Remote ID dashboard stopped unexpectedly. See $GUI_LOG"; exit "$GUI_RC"; fi
exit 0
