#!/bin/bash
# Title: C5 Wardriver Pager Node
# Author: JustCallMeKoko
# Description: Adds Wi-Fi 6 GHz observations to a C5 Wardriver Core over ESP-NOW
# Version: 0.5.0
# Category: Reconnaissance

LAUNCH_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/mmc/usr/sbin:/mmc/usr/bin:/mmc/sbin:/mmc/bin:$PATH"
if [ -f "$LAUNCH_DIR/c5_pager_node.py" ]; then
  DIR="$LAUNCH_DIR"
elif [ -f /root/payloads/user/reconnaissance/c5_wardriver_node/c5_pager_node.py ]; then
  DIR=/root/payloads/user/reconnaissance/c5_wardriver_node
elif [ -f /mmc/root/payloads/user/reconnaissance/c5_wardriver_node/c5_pager_node.py ]; then
  DIR=/mmc/root/payloads/user/reconnaissance/c5_wardriver_node
else
  ERROR_DIALOG "C5 Wardriver node worker is missing."
  exit 1
fi
IFACE=wlan1mon; STATS=/tmp/c5-pager-node.json; STATUS=/tmp/c5-pager-node.status; LOGFILE=/tmp/c5-pager-node.log
GUI_LOG=/tmp/c5-pager-node-gui.log; SETUP_LOG=/tmp/c5-pager-node-gui-setup.log
LOCK=/tmp/c5-pager-node.lock
CORE_CONFIG=/root/.config/c5-wardriver/core_mac
RADIO_SET=0; DISPLAY_SET=0; OLD_HOPRATE=""; OLD_CHANNEL=""
PID=""; GUI_PID=""
if ! mkdir "$LOCK" 2>/dev/null; then
  LOCK_PID=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null && \
     tr '\0' ' ' <"/proc/$LOCK_PID/cmdline" 2>/dev/null | grep -q 'c5_wardriver_node/payload.sh'; then
    ERROR_DIALOG "C5 Wardriver Node is already running."
    exit 1
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || { ERROR_DIALOG "Could not recover the C5 node lock."; exit 1; }
fi
printf "%s\n" "$$" >"$LOCK/pid"
stop_pid() {
  local pid="$1" count=0
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$count" -lt 10 ]; do sleep 0.2; count=$((count+1)); done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
cleanup() {
  stop_pid "$GUI_PID"; GUI_PID=""
  stop_pid "$PID"; PID=""
  if [ "$RADIO_SET" = 1 ]; then
    case "$OLD_HOPRATE" in
      200) _pineap INTERFACE SET "$IFACE" HOP fast >/dev/null 2>&1 || true ;;
      1000) _pineap INTERFACE SET "$IFACE" HOP slow >/dev/null 2>&1 || true ;;
      0) _pineap INTERFACE SET "$IFACE" CHANNEL "$OLD_CHANNEL" >/dev/null 2>&1 || true ;;
    esac
    RADIO_SET=0
  fi
  if [ "$DISPLAY_SET" = 1 ]; then
    UI_RELEASE >/dev/null 2>&1 || true
    DISPLAY_SET=0
  fi
  rm -f "$LOCK/pid"
  rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' INT TERM
confirmed() {
  local response
  response=$(CONFIRMATION_DIALOG "$1") || return 1
  [ -n "${DUCKYSCRIPT_USER_CONFIRMED:-}" ] && [ "$response" = "$DUCKYSCRIPT_USER_CONFIRMED" ]
}
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
  if ! confirmed "C5 Wardriver Node needs Python 3.\n\nInstall python3-light to MMC now?\n\nRequires internet and persistent storage changes."; then
    return 2
  fi
  INSTALL_LOG=/tmp/c5-pager-node-python-install.$$.log
  LOG cyan "Updating package lists..."
  opkg update >"$INSTALL_LOG" 2>&1 || { ERROR_DIALOG "Package list update failed. Check internet access. See $INSTALL_LOG"; return 1; }
  LOG cyan "Installing or repairing python3-light on MMC..."
  opkg -d mmc --force-reinstall install python3-light >>"$INSTALL_LOG" 2>&1 || { ERROR_DIALOG "Python installation failed. See $INSTALL_LOG"; return 1; }
  configure_python || { ERROR_DIALOG "Python installed but is not executable. See $INSTALL_LOG"; return 1; }
}
install_gui() {
  : >"$SETUP_LOG"
  LOG cyan "Installing Pager GUI support..."
  opkg update >>"$SETUP_LOG" 2>&1 || return 1
  opkg -d mmc --force-reinstall install python3-ctypes >>"$SETUP_LOG" 2>&1 || return 1
  bash "$DIR/install_pagerctl.sh" >>"$SETUP_LOG" 2>&1 || return 1
  configure_python || return 1
  PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -B "$DIR/gui.py" --check >>"$SETUP_LOG" 2>&1
}
if ! configure_python; then
  install_python
  install_rc=$?
  [ "$install_rc" -eq 2 ] && exit 0
  [ "$install_rc" -eq 0 ] || exit 1
fi
STARTUP_LOG=/tmp/c5-pager-node-startup.$$.log
if ! PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -B "$DIR/c5_pager_node.py" --self-check >"$STARTUP_LOG" 2>&1; then
  if grep -Eq "ImportError|ModuleNotFoundError|No module named|cannot open shared object file" "$STARTUP_LOG"; then
    install_python
    install_rc=$?
    [ "$install_rc" -eq 2 ] && exit 0
    [ "$install_rc" -eq 0 ] || exit 1
    if ! PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -B "$DIR/c5_pager_node.py" --self-check >"$STARTUP_LOG" 2>&1; then
      ERROR_DIALOG "Python is still incomplete. See $STARTUP_LOG"
      exit 1
    fi
  elif grep -Eq "SyntaxError|IndentationError" "$STARTUP_LOG"; then
    ERROR_DIALOG "C5 node worker is damaged. Reinstall the payload. See $STARTUP_LOG"
    exit 1
  else
    ERROR_DIALOG "C5 node could not start. See $STARTUP_LOG"
    exit 1
  fi
fi
rm -f "$STARTUP_LOG"
iw dev "$IFACE" info >/dev/null 2>&1 || { ERROR_DIALOG "wlan1mon is unavailable."; exit 1; }
: >"$SETUP_LOG"
if ! PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -B "$DIR/gui.py" --check >>"$SETUP_LOG" 2>&1; then
  if ! confirmed "JCMK live dashboard needs pagerctl and python3-ctypes.\n\nDownload the pinned GUI runtime and install python3-ctypes to MMC?\n\nRequires internet and persistent storage changes."; then
    LOG yellow "GUI setup cancelled"
    exit 0
  fi
  install_gui || { ERROR_DIALOG "GUI setup failed. See $SETUP_LOG"; exit 1; }
fi
valid_mac() { echo "$1" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; }
prepare_radio() {
  [ "$RADIO_SET" = 1 ] && return
  RADIO_STATE=$(_pineap INTERFACE LIST format=json | "$PYTHON_BIN" "$DIR/c5_pager_node.py" --interface-state "$IFACE") || return 1
  read -r OLD_HOPRATE OLD_CHANNEL <<<"$RADIO_STATE"
  if [ "$OLD_HOPRATE" = 0 ] && [ "${OLD_CHANNEL:-0}" -le 0 ]; then
    OLD_CHANNEL=$(iw dev "$IFACE" info 2>/dev/null | awk '$1=="channel" {print $2; exit}')
    [ -n "$OLD_CHANNEL" ] || return 1
  fi
  _pineap INTERFACE SET "$IFACE" CHANNEL 6 >/dev/null 2>&1 || return 1
  RADIO_SET=1
}
save_core() {
  PAYLOAD_SET_CONFIG c5_wardriver_node core_mac "$CORE_MAC" >/dev/null 2>&1 || {
    ERROR_DIALOG "Core paired, but persistent payload settings could not be saved."; exit 1;
  }
  mkdir -p "$(dirname "$CORE_CONFIG")"
  printf '%s\n' "$CORE_MAC" >"$CORE_CONFIG.tmp" && mv "$CORE_CONFIG.tmp" "$CORE_CONFIG" || {
    ERROR_DIALOG "Core paired, but the compatibility config could not be saved."; exit 1;
  }
}
CORE_MAC=$(PAYLOAD_GET_CONFIG c5_wardriver_node core_mac 2>/dev/null || true)
if ! valid_mac "$CORE_MAC" && [ -s "$CORE_CONFIG" ]; then
  CORE_MAC=$("$PYTHON_BIN" -c 'import sys; print(open(sys.argv[1]).read().strip())' "$CORE_CONFIG")
fi
valid_mac "$CORE_MAC" || CORE_MAC=""
PROMPT_IMAGE "$DIR/splash.png"
if [ -n "$CORE_MAC" ]; then
  action=$(LIST_PICKER "Core: $CORE_MAC" "Start node" "Pair nearby Core" "Enter Core MAC" "Start node") || exit 0
else
  action=$(LIST_PICKER "Choose C5 Core" "Pair nearby Core" "Enter Core MAC" "Pair nearby Core") || exit 0
fi
case "$action" in
  "Pair nearby Core")
    prepare_radio || { ERROR_DIALOG "Could not take temporary control of $IFACE."; exit 1; }
    LOG yellow "Searching for C5 Wardriver Cores..."
    CANDIDATES=()
    while IFS= read -r mac; do valid_mac "$mac" && CANDIDATES+=("$mac"); done < <("$PYTHON_BIN" "$DIR/c5_pager_node.py" --iface "$IFACE" --discover-seconds 6)
    [ "${#CANDIDATES[@]}" -gt 0 ] || { ERROR_DIALOG "No C5 Wardriver Core replied. Confirm Core mode and retry."; exit 1; }
    if [ "${#CANDIDATES[@]}" -eq 1 ]; then
      CORE_MAC="${CANDIDATES[0]}"
    else
      CORE_MAC=$(LIST_PICKER "Select C5 Core" "${CANDIDATES[@]}" "${CANDIDATES[0]}") || exit 0
    fi
    confirmed "Pair with $CORE_MAC?" || exit 0
    save_core
    LOG green "Paired Core: $CORE_MAC"
    ;;
  "Enter Core MAC")
    CORE_MAC=$(MAC_PICKER "C5 Core MAC" "$CORE_MAC") || exit 0
    valid_mac "$CORE_MAC" || { ERROR_DIALOG "The entered C5 Core MAC is invalid."; exit 1; }
    save_core
    LOG green "Saved Core: $CORE_MAC"
    ;;
  "Start node") ;;
  *) exit 0 ;;
esac
valid_mac "$CORE_MAC" || { ERROR_DIALOG "A valid C5 Core is required."; exit 1; }
prepare_radio || { ERROR_DIALOG "Could not take temporary control of $IFACE."; exit 1; }
rm -f "$STATS" "$STATUS"; : >"$LOGFILE"
start_worker() {
  printf "[%s] starting node worker\n" "$(date -Iseconds 2>/dev/null || date)" >>"$LOGFILE"
  "$PYTHON_BIN" "$DIR/c5_pager_node.py" --iface "$IFACE" --core "$CORE_MAC" --stats "$STATS" --status "$STATUS" >>"$LOGFILE" 2>&1 & PID=$!
}
start_worker
UI_TAKEOVER >/dev/null 2>&1 || { ERROR_DIALOG "Could not take over the Pager display."; exit 1; }
DISPLAY_SET=1
PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -B "$DIR/gui.py" --stats "$STATS" --node-pid "$PID" 2>"$GUI_LOG" &
GUI_PID=$!
wait "$GUI_PID"; GUI_RC=$?; GUI_PID=""
cleanup
trap - EXIT
if [ "$GUI_RC" -ne 0 ]; then
  ERROR_DIALOG "JCMK dashboard stopped unexpectedly. See $GUI_LOG"
  exit "$GUI_RC"
fi
if [ -s "$STATS" ]; then
  summary=$("$PYTHON_BIN" -c 'import json,sys; s=json.load(open(sys.argv[1])); print("Core: %s\nDevices: %d\nRecords sent: %d\nCore ACKs: %d\nDuplicates suppressed: %d"%(s.get("core") or "not found",s.get("devices",0),s.get("sent",0),s.get("acked",0),s.get("deduped",0)))' "$STATS")
  PROMPT "$summary"
else
  ERROR_DIALOG "Node stopped before producing status. See $LOGFILE"
fi
