#!/bin/bash
# Title: C5 Wardriver Pager Node
# Author: JustCallMeKoko
# Description: Adds Wi-Fi 6 GHz observations to a C5 Wardriver Core over ESP-NOW
# Version: 0.4.0
# Category: Reconnaissance

LAUNCH_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/mmc/usr/bin:$PATH"
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
CORE_CONFIG=/root/.config/c5-wardriver/core_mac
RADIO_SET=0; OLD_HOPRATE=""; OLD_CHANNEL=""; PID=""
cleanup() {
  if [ -n "$PID" ]; then kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""; fi
  if [ "$RADIO_SET" = 1 ]; then
    case "$OLD_HOPRATE" in
      200) _pineap INTERFACE SET "$IFACE" HOP fast >/dev/null 2>&1 ;;
      1000) _pineap INTERFACE SET "$IFACE" HOP slow >/dev/null 2>&1 ;;
      0) _pineap INTERFACE SET "$IFACE" CHANNEL "$OLD_CHANNEL" >/dev/null 2>&1 ;;
    esac
    RADIO_SET=0
  fi
}
trap cleanup EXIT
trap 'exit 0' INT TERM
confirm() {
  local response
  response=$(CONFIRMATION_DIALOG "$1") || return 1
  [ "$response" = "$DUCKYSCRIPT_USER_CONFIRMED" ]
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
  if ! confirm "C5 Wardriver Node needs Python 3.\n\nInstall python3-light to MMC now?\n\nRequires internet and persistent storage changes."; then
    return 2
  fi
  INSTALL_LOG=/tmp/c5-pager-node-python-install.$$.log
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
valid_mac() { echo "$1" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; }
prepare_radio() {
  [ "$RADIO_SET" = 1 ] && return 0
  RADIO_STATE=$(_pineap INTERFACE LIST format=json | "$PYTHON_BIN" "$DIR/c5_pager_node.py" --interface-state "$IFACE") || {
    ERROR_DIALOG "Could not read the current $IFACE channel state."; return 1;
  }
  read -r OLD_HOPRATE OLD_CHANNEL <<<"$RADIO_STATE"
  _pineap INTERFACE SET "$IFACE" CHANNEL 6 >/dev/null 2>&1 || {
    ERROR_DIALOG "Could not lock $IFACE to channel 6."; return 1;
  }
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
    prepare_radio || exit 1
    LOG yellow "Searching for C5 Wardriver Cores..."
    CANDIDATES=()
    while IFS= read -r mac; do valid_mac "$mac" && CANDIDATES+=("$mac"); done < <("$PYTHON_BIN" "$DIR/c5_pager_node.py" --iface "$IFACE" --discover-seconds 6)
    [ "${#CANDIDATES[@]}" -gt 0 ] || { ERROR_DIALOG "No C5 Wardriver Core replied. Confirm Core mode and retry."; exit 1; }
    if [ "${#CANDIDATES[@]}" -eq 1 ]; then
      CORE_MAC="${CANDIDATES[0]}"
    else
      CORE_MAC=$(LIST_PICKER "Select C5 Core" "${CANDIDATES[@]}" "${CANDIDATES[0]}") || exit 0
    fi
    confirm "Pair with $CORE_MAC?" || exit 0
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
prepare_radio || exit 1
rm -f "$STATS" "$STATUS"; : >"$LOGFILE"
start_worker() {
  printf "[%s] starting node worker\n" "$(date -Iseconds 2>/dev/null || date)" >>"$LOGFILE"
  "$PYTHON_BIN" "$DIR/c5_pager_node.py" --iface "$IFACE" --core "$CORE_MAC" --stats "$STATS" --status "$STATUS" >>"$LOGFILE" 2>&1 & PID=$!
}
start_worker
LOG cyan "C5 WARDRIVER 6 GHz NODE"
LAST_STATUS=""; LAST_LOG_TIME=0
while true; do
  if ! kill -0 "$PID" 2>/dev/null; then
    wait "$PID" 2>/dev/null
    LOG red "Node worker stopped; restarting..."
    sleep 2
    start_worker
  fi
  if [ -s "$STATUS" ]; then
    status=$(cat "$STATUS"); now=$(date +%s)
    if { [ "$status" != "$LAST_STATUS" ] && [ $((now-LAST_LOG_TIME)) -ge 10 ]; } || [ $((now-LAST_LOG_TIME)) -ge 30 ]; then
      if echo "$status" | grep -q "CORE: LINKED"; then LOG green "$status"; else LOG yellow "$status"; fi
      LAST_STATUS="$status"; LAST_LOG_TIME=$now
    fi
  fi

  timeout 2 WAIT_FOR_BUTTON_PRESS A >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && break
  [ "$rc" -eq 124 ] || sleep 2
done
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""
if [ -s "$STATS" ]; then
  summary=$("$PYTHON_BIN" -c 'import json,sys; s=json.load(open(sys.argv[1])); print("Core: %s\n6 GHz seen: %d\nRecords sent: %d\nCore ACKs: %d"%(s.get("core") or "not found",s["seen"],s["sent"],s.get("acked",0)))' "$STATS")
  PROMPT "$summary"
else
  ERROR_DIALOG "Node stopped before producing status. See $LOGFILE"
fi
