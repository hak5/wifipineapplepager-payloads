#!/bin/bash
# Title: C5 Wardriver Pager Node
# Author: JustCallMeKoko
# Description: Adds Wi-Fi 6 GHz observations to a C5 Wardriver Core over ESP-NOW
# Version: 0.3.0
# Category: Reconnaissance

LAUNCH_DIR="$(cd "$(dirname "$0")" && pwd)"
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
IFACE=wlan1mon; STATS=/tmp/c5-pager-node.json; LOGFILE=/tmp/c5-pager-node.log
CORE_CONFIG=/root/.config/c5-wardriver/core_mac
RADIO_SET=0; OLD_HOP=""; OLD_CHANNEL=""
cleanup() {
  [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null
  if [ "$RADIO_SET" = 1 ]; then
    [ -n "$OLD_HOP" ] && uci set pineapd.wlan1mon.hop="$OLD_HOP" || uci -q delete pineapd.wlan1mon.hop
    [ -n "$OLD_CHANNEL" ] && uci set pineapd.wlan1mon.channel="$OLD_CHANNEL" || uci -q delete pineapd.wlan1mon.channel
    /etc/init.d/pineapd restart >/dev/null 2>&1
  fi
}
trap cleanup EXIT INT TERM
command -v python3 >/dev/null 2>&1 || { ERROR_DIALOG "Python 3 is required for this development preview."; exit 1; }
# Pager packages installed on MMC are not included in the stock interpreter path.
PYTHON_MMCLIB="/mmc/usr/lib/python$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
if [ -d "$PYTHON_MMCLIB" ]; then
  export PYTHONPATH="$PYTHON_MMCLIB:$PYTHON_MMCLIB/lib-dynload${PYTHONPATH:+:$PYTHONPATH}"
fi
python3 -c 'import argparse,json,select,socket,struct,subprocess' >/dev/null 2>&1 || {
  ERROR_DIALOG "Python 3 standard-library modules are unavailable. Install python3-light."; exit 1;
}
iw dev "$IFACE" info >/dev/null 2>&1 || { ERROR_DIALOG "wlan1mon is unavailable."; exit 1; }
valid_mac() { echo "$1" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; }
prepare_radio() {
  [ "$RADIO_SET" = 1 ] && return
  OLD_HOP=$(uci -q get pineapd.wlan1mon.hop); OLD_CHANNEL=$(uci -q get pineapd.wlan1mon.channel)
  uci set pineapd.wlan1mon.hop=0; uci set pineapd.wlan1mon.channel=6; RADIO_SET=1
  /etc/init.d/pineapd restart >/dev/null 2>&1; sleep 3
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
  CORE_MAC=$(python3 -c 'import sys; print(open(sys.argv[1]).read().strip())' "$CORE_CONFIG")
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
    prepare_radio
    LOG yellow "Searching for C5 Wardriver Cores..."
    CANDIDATES=()
    while IFS= read -r mac; do valid_mac "$mac" && CANDIDATES+=("$mac"); done < <(python3 "$DIR/c5_pager_node.py" --iface "$IFACE" --discover-seconds 6)
    [ "${#CANDIDATES[@]}" -gt 0 ] || { ERROR_DIALOG "No C5 Wardriver Core replied. Confirm Core mode and retry."; exit 1; }
    if [ "${#CANDIDATES[@]}" -eq 1 ]; then
      CORE_MAC="${CANDIDATES[0]}"
    else
      CORE_MAC=$(LIST_PICKER "Select C5 Core" "${CANDIDATES[@]}" "${CANDIDATES[0]}") || exit 0
    fi
    CONFIRMATION_DIALOG "Pair with $CORE_MAC?" || exit 0
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
prepare_radio
rm -f "$STATS"; : >"$LOGFILE"
start_worker() {
  printf "[%s] starting node worker\n" "$(date -Iseconds 2>/dev/null || date)" >>"$LOGFILE"
  python3 "$DIR/c5_pager_node.py" --iface "$IFACE" --core "$CORE_MAC" --stats "$STATS" >>"$LOGFILE" 2>&1 & PID=$!
}
start_worker
LOG cyan "C5 WARDRIVER 6 GHz NODE"
while true; do
  if ! kill -0 "$PID" 2>/dev/null; then
    wait "$PID" 2>/dev/null
    LOG red "Node worker stopped; restarting..."
    sleep 2
    start_worker
  fi
  status=$(python3 "$DIR/c5_pager_node.py" --render-stats "$STATS")
  if echo "$status" | grep -q "CORE: LINKED"; then
    LOG green "$status"
  else
    LOG yellow "$status"
  fi

  timeout 2 WAIT_FOR_BUTTON_PRESS A >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && break
  [ "$rc" -eq 124 ] || sleep 2
done
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""
if [ -s "$STATS" ]; then
  summary=$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print("Core: %s\n6 GHz seen: %d\nRecords sent: %d\nCore ACKs: %d"%(s.get("core") or "not found",s["seen"],s["sent"],s.get("acked",0)))' "$STATS")
  PROMPT "$summary"
else
  ERROR_DIALOG "Node stopped before producing status. See $LOGFILE"
fi
