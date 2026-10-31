#!/bin/bash
# Title: SharkJack Launcher
# Description: Run Hak5 Shark Jack library payloads on the Pager (compat layer + USB-Ethernet or wlan0cli WAN)
# Author: InfoSecREDD
# Version: 4.6
# Category: general

set -euo pipefail

PAYLOAD_HOME="${PAYLOAD_HOME:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
export PAYLOAD_HOME
PAYLOAD_WORKING_DIR="${PAYLOAD_WORKING_DIR:-$PAYLOAD_HOME}"
export PAYLOAD_WORKING_DIR
PAYLOAD_DIR="${PAYLOAD_DIR:-$PAYLOAD_HOME}"
export PAYLOAD_DIR
PAYLOAD_NAME="${PAYLOAD_NAME:-$(basename "$PAYLOAD_HOME")}"
export PAYLOAD_NAME
PAYLOAD_PATH="${PAYLOAD_PATH:-$PAYLOAD_HOME/payload.sh}"
export PAYLOAD_PATH
LOOT_ROOT="${LOOT_ROOT:-/root/loot}"
export LOOT_ROOT
PAGE_SIZE="${PAGE_SIZE:-4}"
export PAGE_SIZE
: "${SHARKJACK_MENU_PAUSE_MS:=0}"
export SHARKJACK_MENU_PAUSE_MS
: "${SHARKJACK_MENU_READY:=wait}"
export SHARKJACK_MENU_READY
: "${SHARKJACK_RAINBOW:=1}"
export SHARKJACK_RAINBOW
: "${SHARKJACK_RAINBOW_MS:=2.2}"
export SHARKJACK_RAINBOW_MS
: "${SHARKJACK_RAINBOW_NATIVE:=0}"
export SHARKJACK_RAINBOW_NATIVE

SHARKJACK_HOME="${SHARKJACK_HOME:-$PAYLOAD_HOME}"
export SHARKJACK_HOME
: "${SHARKJACK_HUB:=/root/sharkjack}"
export SHARKJACK_HUB
SHARKJACK_LIBRARY="${SHARKJACK_LIBRARY:-$SHARKJACK_HUB/library}"
export SHARKJACK_LIBRARY
LIBRARY="$SHARKJACK_LIBRARY"
export LIBRARY

: "${SHARKJACK_GITHUB_ARCHIVE_URL:=https://github.com/hak5/sharkjack-payloads/archive/refs/heads/master.tar.gz}"
export SHARKJACK_GITHUB_ARCHIVE_URL

: "${SHARKJACK_ETH_ALIAS:=eth0}"
: "${SHARKJACK_WAN_LINK:=usb}"
case "${SHARKJACK_WAN_LINK}" in
  wlan | wifi | wlan0cli) SHARKJACK_WAN_LINK=wlan ;;
  *) SHARKJACK_WAN_LINK=usb ;;
esac
export SHARKJACK_WAN_LINK
case "${SHARKJACK_WAN_LINK}" in
  wlan) : "${SHARKJACK_WAN_IF:=wlan0cli}" ;;
  *) : "${SHARKJACK_WAN_IF:=eth1}" ;;
esac
export SHARKJACK_WAN_IF
: "${SHARKJACK_LOOT:=$LOOT_ROOT}"
: "${SHARKJACK_QUIET:=0}"
: "${SHARKJACK_USB_ETH_ID:=0bda:8152}"
: "${SHARKJACK_SKIP_USB_CHECK:=0}"
: "${SHARKJACK_SWITCH:=}"
export SHARKJACK_SWITCH
: "${SHARKJACK_SWITCH_BUTTONS:=auto}"
export SHARKJACK_SWITCH_BUTTONS
: "${SHARKJACK_SWITCH_EXPECT:=}"
export SHARKJACK_SWITCH_EXPECT
: "${SHARKJACK_SERIAL_DEVICE:=}"
export SHARKJACK_SERIAL_DEVICE
: "${SHARKJACK_ALLOW_HALT:=0}"
export SHARKJACK_ALLOW_HALT
export SHARKJACK_ETH_ALIAS SHARKJACK_WAN_IF SHARKJACK_WAN_LINK SHARKJACK_LOOT SHARKJACK_QUIET SHARKJACK_USB_ETH_ID SHARKJACK_SKIP_USB_CHECK

: "${SHARKJACK_SKIP_NET_RESTORE:=0}"
export SHARKJACK_SKIP_NET_RESTORE
: "${SHARKJACK_UBUS_IF:=}"
export SHARKJACK_UBUS_IF

_sjwarn() {
  [ "$SHARKJACK_QUIET" = "1" ] && return
  LOG yellow "SharkJack: $*"
}

_sj_warn_iface_missing() {
  if [ "${SHARKJACK_WAN_LINK:-usb}" = "wlan" ]; then
    _sjwarn "iface ${SHARKJACK_WAN_IF} missing — check wlan0cli / Wi‑Fi"
  else
    _sjwarn "External Ethernet mod ${SHARKJACK_WAN_IF} missing — plug USB adapter"
  fi
}

_sj_normalize_ifconfig_out() {
  awk '
  {
    print
    if ($0 ~ /inet[[:space:]][0-9]/ && $0 !~ /inet addr:/) {
      ip = ""
      for (i = 1; i <= NF; i++) {
        if ($i == "inet") { ip = $(i+1); gsub(/\/.*/, "", ip); break }
      }
      if (ip != "") print "          inet addr:" ip "  Bcast:0.0.0.0  Mask:255.255.255.0"
    }
  }'
}

ifconfig() {
  local -a args=()
  local a
  for a in "$@"; do
    if [ "$a" = "$SHARKJACK_ETH_ALIAS" ]; then
      args+=("$SHARKJACK_WAN_IF")
    else
      args+=("$a")
    fi
  done
  local out
  if [ "$#" -eq 0 ]; then
    out=$(command ifconfig "${SHARKJACK_WAN_IF}" 2>/dev/null) || true
    if [ -z "$out" ]; then
      out=$(command ip -4 addr show dev "${SHARKJACK_WAN_IF}" 2>/dev/null; command ip link show dev "${SHARKJACK_WAN_IF}" 2>/dev/null) || true
    fi
    out=$(printf '%s\n' "$out" | _sj_normalize_ifconfig_out)
    if [ "$SHARKJACK_WAN_IF" != "$SHARKJACK_ETH_ALIAS" ]; then
      out=$(printf '%s\n' "$out" | sed "s/${SHARKJACK_WAN_IF}/${SHARKJACK_ETH_ALIAS}/g")
    fi
    printf '%s\n' "$out"
    return 0
  fi
  if out=$(command ifconfig "${args[@]}" 2>/dev/null); then
    out=$(printf '%s\n' "$out" | _sj_normalize_ifconfig_out)
    if [ "$SHARKJACK_WAN_IF" != "$SHARKJACK_ETH_ALIAS" ]; then
      out=$(printf '%s\n' "$out" | sed "s/${SHARKJACK_WAN_IF}/${SHARKJACK_ETH_ALIAS}/g")
    fi
    printf '%s\n' "$out"
    return 0
  fi
  if [ "${#args[@]}" -eq 1 ] && command ip link show "${args[0]}" >/dev/null 2>&1; then
    out=$(command ip -4 addr show dev "${args[0]}" 2>/dev/null; command ip link show dev "${args[0]}" 2>/dev/null) || true
    printf '%s\n' "$out" | _sj_normalize_ifconfig_out | sed "s/${SHARKJACK_WAN_IF}/${SHARKJACK_ETH_ALIAS}/g"
    return 0
  fi
  command ifconfig "${args[@]}" 2>/dev/null || return 1
}

route() {
  local -a rargs=()
  local ra
  for ra in "$@"; do
    if [ "$ra" = "$SHARKJACK_ETH_ALIAS" ]; then
      rargs+=("$SHARKJACK_WAN_IF")
    else
      rargs+=("$ra")
    fi
  done
  if [ "$#" -eq 0 ]; then
    ip route show dev "${SHARKJACK_ETH_ALIAS}" 2>/dev/null | while IFS= read -r line; do
      case "$line" in
        default\ via\ *)
          gw=$(printf '%s' "$line" | awk '{print $3}')
          dev=$(printf '%s' "$line" | awk '{print $5}')
          [ -z "$dev" ] && dev="$SHARKJACK_ETH_ALIAS"
          echo "default         ${gw}         0.0.0.0         UG    0 0          0 ${dev}"
          ;;
        *)
          echo "$line"
          ;;
      esac
    done
    return 0
  fi
  if command -v route >/dev/null 2>&1; then
    local z
    z=$(command route "${rargs[@]}" 2>/dev/null) || true
    if [ -n "$z" ]; then
      if [ "$SHARKJACK_WAN_IF" != "$SHARKJACK_ETH_ALIAS" ]; then
        z=$(printf '%s\n' "$z" | sed "s/${SHARKJACK_WAN_IF}/${SHARKJACK_ETH_ALIAS}/g")
      fi
      printf '%s\n' "$z"
      return 0
    fi
  fi
  ip route "${rargs[@]}" 2>/dev/null || true
}

ip() {
  local -a iargs=()
  local ia rc out
  for ia in "$@"; do
    if [ "$ia" = "$SHARKJACK_ETH_ALIAS" ]; then
      iargs+=("$SHARKJACK_WAN_IF")
    else
      iargs+=("$ia")
    fi
  done
  rc=0
  out=$(command ip "${iargs[@]}" 2>&1) || rc=$?
  if [ "$SHARKJACK_WAN_IF" != "$SHARKJACK_ETH_ALIAS" ]; then
    out=$(printf '%s\n' "$out" | sed "s/${SHARKJACK_WAN_IF}/${SHARKJACK_ETH_ALIAS}/g")
  fi
  printf '%s\n' "$out"
  return "$rc"
}

ping() {
  if ! command -v ping >/dev/null 2>&1; then
    _sjwarn "ping not installed"
    return 127
  fi
  local -a pargs=()
  local pa prev=
  for pa in "$@"; do
    if [ "$prev" = "-I" ] && [ "$pa" = "$SHARKJACK_ETH_ALIAS" ]; then
      pargs+=("$SHARKJACK_WAN_IF")
    elif [ "$pa" = "$SHARKJACK_ETH_ALIAS" ]; then
      pargs+=("$SHARKJACK_WAN_IF")
    else
      pargs+=("$pa")
    fi
    prev=$pa
  done
  command ping "${pargs[@]}"
}

arp() {
  if ! command -v arp >/dev/null 2>&1; then
    _sjwarn "arp not installed"
    return 127
  fi
  local -a aargs=()
  local aa prev=
  for aa in "$@"; do
    if [ "$prev" = "-i" ] && [ "$aa" = "$SHARKJACK_ETH_ALIAS" ]; then
      aargs+=("$SHARKJACK_WAN_IF")
    elif [ "$aa" = "$SHARKJACK_ETH_ALIAS" ]; then
      aargs+=("$SHARKJACK_WAN_IF")
    else
      aargs+=("$aa")
    fi
    prev=$aa
  done
  command arp "${aargs[@]}"
}

tcpdump() {
  if ! command -v tcpdump >/dev/null 2>&1; then
    _sjwarn "tcpdump not installed"
    return 127
  fi
  local -a pargs=()
  local pa prev=
  for pa in "$@"; do
    if [ "$prev" = "-i" ] && [ "$pa" = "$SHARKJACK_ETH_ALIAS" ]; then
      pargs+=("$SHARKJACK_WAN_IF")
    elif [ "$pa" = "$SHARKJACK_ETH_ALIAS" ]; then
      pargs+=("$SHARKJACK_WAN_IF")
    else
      pargs+=("$pa")
    fi
    prev=$pa
  done
  command tcpdump "${pargs[@]}"
}

arp-scan() {
  if ! command -v arp-scan >/dev/null 2>&1; then
    _sjwarn "arp-scan not installed"
    return 127
  fi
  local has_iface=0 pa
  for pa in "$@"; do
    case "$pa" in
      --interface|--interface=*) has_iface=1 ;;
      -I*) has_iface=1 ;;
    esac
  done
  local -a raw=("$@")
  if [ "$has_iface" -eq 0 ]; then
    raw=(--interface "$SHARKJACK_WAN_IF" "${raw[@]}")
  fi
  local -a pargs=()
  local prev=
  for pa in "${raw[@]}"; do
    case "$pa" in
      --interface="$SHARKJACK_ETH_ALIAS") pargs+=("--interface=$SHARKJACK_WAN_IF") ;;
      -I"$SHARKJACK_ETH_ALIAS") pargs+=("-I$SHARKJACK_WAN_IF") ;;
      *)
        if [ "$prev" = "-I" ] && [ "$pa" = "$SHARKJACK_ETH_ALIAS" ]; then
          pargs+=("$SHARKJACK_WAN_IF")
        elif [ "$pa" = "$SHARKJACK_ETH_ALIAS" ]; then
          pargs+=("$SHARKJACK_WAN_IF")
        else
          pargs+=("$pa")
        fi
        ;;
    esac
    prev=$pa
  done
  command arp-scan "${pargs[@]}"
}

netdiscover() {
  if ! command -v netdiscover >/dev/null 2>&1; then
    _sjwarn "netdiscover not installed"
    return 127
  fi
  local has_i=0 pa
  for pa in "$@"; do
    case "$pa" in
      -i|--interface) has_i=1 ;;
      -i*) has_i=1 ;;
    esac
  done
  local -a pargs=()
  local prev=
  for pa in "$@"; do
    if [ "$prev" = "-i" ] && [ "$pa" = "$SHARKJACK_ETH_ALIAS" ]; then
      pargs+=("$SHARKJACK_WAN_IF")
    elif [ "$pa" = "$SHARKJACK_ETH_ALIAS" ]; then
      pargs+=("$SHARKJACK_WAN_IF")
    else
      pargs+=("$pa")
    fi
    prev=$pa
  done
  if [ "$has_i" -eq 0 ]; then
    command netdiscover -i "$SHARKJACK_WAN_IF" "${pargs[@]}"
  else
    command netdiscover "${pargs[@]}"
  fi
}

traceroute() {
  if ! command -v traceroute >/dev/null 2>&1; then
    _sjwarn "traceroute not installed"
    return 127
  fi
  local -a pargs=()
  local pa prev=
  for pa in "$@"; do
    if [ "$prev" = "-i" ] && [ "$pa" = "$SHARKJACK_ETH_ALIAS" ]; then
      pargs+=("$SHARKJACK_WAN_IF")
    elif [ "$pa" = "$SHARKJACK_ETH_ALIAS" ]; then
      pargs+=("$SHARKJACK_WAN_IF")
    else
      pargs+=("$pa")
    fi
    prev=$pa
  done
  command traceroute "${pargs[@]}"
}

nmap() {
  if ! command -v nmap >/dev/null 2>&1; then
    _sjwarn "nmap not installed"
    return 127
  fi
  local -a pargs=()
  local pa prev=
  for pa in "$@"; do
    if [ "$prev" = "-e" ] && [ "$pa" = "$SHARKJACK_ETH_ALIAS" ]; then
      pargs+=("$SHARKJACK_WAN_IF")
    elif [ "$pa" = "$SHARKJACK_ETH_ALIAS" ]; then
      pargs+=("$SHARKJACK_WAN_IF")
    else
      pargs+=("$pa")
    fi
    prev=$pa
  done
  command nmap "${pargs[@]}"
}

lldpd() {
  if ! command -v lldpd >/dev/null 2>&1; then
    _sjwarn "lldpd not installed"
    return 127
  fi
  local -a pargs=()
  local pa prev=
  for pa in "$@"; do
    if [ "$prev" = "-I" ] && [ "$pa" = "$SHARKJACK_ETH_ALIAS" ]; then
      pargs+=("$SHARKJACK_WAN_IF")
    elif [ "$pa" = "$SHARKJACK_ETH_ALIAS" ]; then
      pargs+=("$SHARKJACK_WAN_IF")
    else
      pargs+=("$pa")
    fi
    prev=$pa
  done
  command lldpd "${pargs[@]}"
}

SERIAL_WRITE() {
  local line="$*"
  LOG "$line"
  if [ -n "${SHARKJACK_SERIAL_DEVICE:-}" ] && [ -w "${SHARKJACK_SERIAL_DEVICE}" ] 2>/dev/null; then
    printf '%s\r\n' "$line" >>"${SHARKJACK_SERIAL_DEVICE}" 2>/dev/null || true
  fi
}

LED() {
  if [ "$#" -eq 0 ]; then
    return
  fi
  case "$1" in
    SETUP)     command LED M SOLID 2>/dev/null || command LED MAGENTA 2>/dev/null || true ;;
    ATTACK)    command LED Y SINGLE 2>/dev/null || command LED Y SOLID 2>/dev/null || command LED YELLOW 2>/dev/null || true ;;
    FAIL)      command LED R SLOW 2>/dev/null || command LED R SOLID 2>/dev/null || command LED RED 2>/dev/null || true ;;
    FAIL1)     command LED R SLOW 2>/dev/null || command LED R SOLID 2>/dev/null || true ;;
    FAIL2)     command LED R FAST 2>/dev/null || command LED R SOLID 2>/dev/null || true ;;
    FAIL3)     command LED R VERYFAST 2>/dev/null || command LED R SOLID 2>/dev/null || true ;;
    STAGE1)    command LED Y SINGLE 2>/dev/null || command LED Y SOLID 2>/dev/null || true ;;
    STAGE2)    command LED Y DOUBLE 2>/dev/null || command LED Y SOLID 2>/dev/null || true ;;
    STAGE3)    command LED Y TRIPLE 2>/dev/null || command LED Y SOLID 2>/dev/null || true ;;
    STAGE4)    command LED Y QUAD 2>/dev/null || command LED Y SOLID 2>/dev/null || true ;;
    STAGE5)    command LED Y QUIN 2>/dev/null || command LED Y SOLID 2>/dev/null || true ;;
    SPECIAL)   command LED C ISINGLE 2>/dev/null || command LED C SOLID 2>/dev/null || command LED CYAN 2>/dev/null || true ;;
    SPECIAL1)  command LED C ISINGLE 2>/dev/null || command LED C SOLID 2>/dev/null || true ;;
    SPECIAL2)  command LED C IDOUBLE 2>/dev/null || command LED C SOLID 2>/dev/null || true ;;
    SPECIAL3)  command LED C ITRIPLE 2>/dev/null || command LED C SOLID 2>/dev/null || true ;;
    SPECIAL4)  command LED C IQUAD 2>/dev/null || command LED C SOLID 2>/dev/null || true ;;
    SPECIAL5)  command LED C IQUIN 2>/dev/null || command LED C SOLID 2>/dev/null || true ;;
    CLEANUP)   command LED W FAST 2>/dev/null || command LED W SOLID 2>/dev/null || command LED WHITE 2>/dev/null || true ;;
    FINISH)    command LED FINISH 2>/dev/null || command LED G SUCCESS 2>/dev/null || command LED G SOLID 2>/dev/null || true ;;
    OFF)       command LED OFF 2>/dev/null || true ;;
    *)         command LED "$@" 2>/dev/null || true ;;
  esac
}

_sj_switch_state_file() {
  printf '%s/switch_state' "${SHARKJACK_HUB:-/root/sharkjack}"
}

_sj_switch_map_button() {
  case "${1:-}" in
    UP) echo switch1 ;;
    LEFT) echo switch2 ;;
    RIGHT | DOWN) echo switch3 ;;
    OK) echo switch3 ;;
    *) echo switch3 ;;
  esac
}

_sj_switch_short_label() {
  case "${1:-}" in
    switch1) printf '%s' "off" ;;
    switch2) printf '%s' "arm" ;;
    switch3) printf '%s' "atk" ;;
    *) printf '%s' "?" ;;
  esac
}

_sj_switch_btn_hint() {
  case "${1:-}" in
    switch1) printf '%s' "UP" ;;
    switch2) printf '%s' "LEFT" ;;
    switch3) printf '%s' "RIGHT/DN" ;;
    *) printf '%s' "?" ;;
  esac
}

_sj_switch_read_file() {
  local sf="$1"
  local sv
  [ ! -f "$sf" ] && return 1
  sv=$(head -1 "$sf" 2>/dev/null | tr -d '\r\n' | tr -d ' ')
  case "$sv" in
    switch1 | switch2 | switch3) printf '%s' "$sv"; return 0 ;;
  esac
  return 1
}

_sj_switch_prompt_and_save() {
  local f="$1"
  mkdir -p "$(dirname -- "$f")" 2>/dev/null || true

  local cur expect cur_disp expect_l
  cur=""
  if v=$(_sj_switch_read_file "$f"); then
    cur="$v"
  fi

  expect="${SHARKJACK_SWITCH_EXPECT:-}"
  case "$expect" in
    switch1 | switch2 | switch3) ;;
    *) expect="" ;;
  esac

  if [ -n "$cur" ]; then
    cur_disp="$cur ($(_sj_switch_short_label "$cur"))"
  else
    cur_disp="none (unset)"
  fi
  expect_l=$(_sj_switch_short_label "$expect")

  LOG magenta "── SWITCH ──"
  LOG blue "  Now: $cur_disp"
  if [ -n "$expect" ]; then
    LOG green "  Payload: need $expect ($expect_l)"
    LOG green "  Press: $(_sj_switch_btn_hint "$expect")"
    if [ -n "$cur" ] && [ "$cur" != "$expect" ]; then
      LOG yellow "  Mismatch — use key above"
    elif [ "$cur" = "$expect" ]; then
      LOG cyan "  Matches payload"
    fi
  else
    LOG cyan "  Payload: (set expect below)"
    LOG cyan "  export SHARKJACK_SWITCH_EXPECT=switch3"
  fi
  LOG ""
  LOG cyan "  UP=1 off  LEFT=2 arm"
  LOG cyan "  RIGHT/DN/OK=3 atk"
  LOG yellow "  Waiting key…"
  VIBRATE 25 10 25 2>/dev/null || true
  local b
  if command -v WAIT_FOR_INPUT >/dev/null 2>&1; then
    b=$(WAIT_FOR_INPUT 2>/dev/null || true)
  else
    b=""
  fi
  [ -z "$b" ] && b="DOWN"
  local r
  r=$(_sj_switch_map_button "$b")
  printf '%s\n' "$r" >"$f"
  sync 2>/dev/null || true
  export SHARKJACK_SWITCH="$r"
  LOG green "  Got: $b -> $r ($(_sj_switch_short_label "$r"))"
  SERIAL_WRITE "[*] SWITCH=$r key=$b expect=${expect:-any} was=${cur:-none}"
}

SWITCH() {
  local f
  f=$(_sj_switch_state_file)
  local s
  if [ -n "${SHARKJACK_SWITCH:-}" ]; then
    case "$SHARKJACK_SWITCH" in
      switch1 | switch2 | switch3) printf '%s\n' "$SHARKJACK_SWITCH"; return 0 ;;
      *) printf '%s\n' "switch3"; return 0 ;;
    esac
  fi
  case "${SHARKJACK_SWITCH_BUTTONS:-auto}" in
    always)
      if command -v WAIT_FOR_INPUT >/dev/null 2>&1; then
        _sj_switch_prompt_and_save "$f"
        s=$(head -1 "$f" 2>/dev/null | tr -d '\r\n')
        case "$s" in switch1 | switch2 | switch3) printf '%s\n' "$s"; return 0 ;; esac
      fi
      printf '%s\n' "switch3"
      return 0
      ;;
    never)
      if [ -f "$f" ]; then
        s=$(head -1 "$f" 2>/dev/null | tr -d '\r\n' | tr -d ' ')
        case "$s" in switch1 | switch2 | switch3) printf '%s\n' "$s"; return 0 ;; esac
      fi
      printf '%s\n' "switch3"
      return 0
      ;;
    auto | *)
      if [ -f "$f" ]; then
        s=$(head -1 "$f" 2>/dev/null | tr -d '\r\n' | tr -d ' ')
        case "$s" in switch1 | switch2 | switch3) printf '%s\n' "$s"; return 0 ;; esac
      fi
      if command -v WAIT_FOR_INPUT >/dev/null 2>&1; then
        _sj_switch_prompt_and_save "$f"
        s=$(head -1 "$f" 2>/dev/null | tr -d '\r\n')
        case "$s" in switch1 | switch2 | switch3) printf '%s\n' "$s"; return 0 ;; esac
      fi
      printf '%s\n' "switch3"
      return 0
      ;;
  esac
}

sj_switch_mode_menu() {
  local f
  f=$(_sj_switch_state_file)
  unset SHARKJACK_SWITCH
  _sj_switch_prompt_and_save "$f"
  PROMPT "Switch saved" || true
  return
}

_sj_battery_state() {
  local s f
  for f in /sys/class/power_supply/*/status; do
    [ -f "$f" ] || continue
    s=$(tr '[:upper:]' '[:lower:]' <"$f" 2>/dev/null | tr -d ' \r')
    case "$s" in
      charging) echo "charging"; return 0 ;;
      discharging | notcharging) echo "discharging"; return 0 ;;
      full | not_charging) echo "full"; return 0 ;;
    esac
  done
  echo "full"
}

BATTERY() {
  _sj_battery_state
}

BATTERY_PERCENT() {
  local p f
  for f in /sys/class/power_supply/*/capacity; do
    [ -f "$f" ] || continue
    p=$(tr -d ' \r\n' <"$f" 2>/dev/null)
    if [ -n "$p" ] && [ "$p" -eq "$p" ] 2>/dev/null && [ "$p" -ge 0 ] && [ "$p" -le 100 ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  printf '%s\n' "100"
}

BATTERY_CHARGING() {
  case "$(BATTERY)" in
    charging) printf '%s\n' "1" ;;
    *) printf '%s\n' "0" ;;
  esac
}

GET_WAN_IP() {
  command ip -4 -o addr show dev "${SHARKJACK_WAN_IF}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

WAN_IP() {
  GET_WAN_IP "$@"
}

NETMODE() {
  local m="${1:-}"
  case "$m" in
    DHCP_CLIENT)
      if ! command ip link show "$SHARKJACK_WAN_IF" >/dev/null 2>&1; then
        _sj_warn_iface_missing
        return 1
      fi
      command ip link set "$SHARKJACK_WAN_IF" up 2>/dev/null || true
      killall udhcpc 2>/dev/null || true
      udhcpc -i "$SHARKJACK_WAN_IF" -b -q -p "/var/run/udhcpc.${SHARKJACK_WAN_IF}.pid" 2>/dev/null \
        || udhcpc -i "$SHARKJACK_WAN_IF" -q 2>/dev/null \
        || udhcpc -i "$SHARKJACK_WAN_IF" -n -q -T 3 -t 8 2>/dev/null \
        || { _sjwarn "udhcpc failed on $SHARKJACK_WAN_IF"; return 1; }
      sleep 2
      ;;
    TRANSPARENT)
      if command ip link show "$SHARKJACK_WAN_IF" >/dev/null 2>&1; then
        command ip link set "$SHARKJACK_WAN_IF" promisc on 2>/dev/null || true
        command ip link set "$SHARKJACK_WAN_IF" up 2>/dev/null || true
        _sjwarn "TRANSPARENT: promisc on $SHARKJACK_WAN_IF — sniff/bridge may still need br-lan/tcpdump"
      else
        _sjwarn "TRANSPARENT: $SHARKJACK_WAN_IF missing"
        return 1
      fi
      ;;
    DHCP_SERVER)
      if ! command ip link show "$SHARKJACK_WAN_IF" >/dev/null 2>&1; then
        _sjwarn "DHCP_SERVER: $SHARKJACK_WAN_IF missing"
        return 1
      fi
      command ip link set "$SHARKJACK_WAN_IF" up 2>/dev/null || true
      command ip addr replace 172.16.24.1/24 dev "$SHARKJACK_WAN_IF" 2>/dev/null || command ip addr add 172.16.24.1/24 dev "$SHARKJACK_WAN_IF" 2>/dev/null || true
      if command -v dnsmasq >/dev/null 2>&1; then
        killall dnsmasq 2>/dev/null || true
        dnsmasq --interface="$SHARKJACK_WAN_IF" \
          --dhcp-range=172.16.24.10,172.16.24.250,255.255.255.0,12h \
          --port=0 -K -R -n -x /tmp/dnsmasq-sharkjack.pid 2>/dev/null &
        sleep 1
        _sjwarn "DHCP_SERVER: dnsmasq 172.16.24.0/24 on $SHARKJACK_WAN_IF — avoid subnet clashes"
      else
        _sjwarn "DHCP_SERVER: install dnsmasq (opkg install dnsmasq) or configure manually"
        return 1
      fi
      ;;
    "")
      _sjwarn "NETMODE: missing argument (DHCP_CLIENT | TRANSPARENT | DHCP_SERVER)"
      return 1
      ;;
    *)
      _sjwarn "NETMODE $m — unknown; use DHCP_CLIENT / TRANSPARENT / DHCP_SERVER"
      return 1
      ;;
  esac
}

C2CONNECT() {
  local cc=""
  if command -v cc-client >/dev/null 2>&1; then
    cc=$(command -v cc-client)
  elif [ -x /usr/bin/cc-client ]; then
    cc=/usr/bin/cc-client
  elif [ -x /usr/local/bin/cc-client ]; then
    cc=/usr/local/bin/cc-client
  fi
  if [ -n "$cc" ]; then
    SERIAL_WRITE "[*] Starting cc-client"
    "$cc" >/tmp/cc-client.log 2>&1 &
    return 0
  fi
  _sjwarn "C2CONNECT: cc-client not installed — copy from Hak5 or use manual C2"
  return 1
}

C2DISCONNECT() {
  killall cc-client 2>/dev/null && SERIAL_WRITE "[*] cc-client stopped" && return 0
  killall -9 cc-client 2>/dev/null && return 0
  return 0
}

C2EXFIL() {
  if [ "$1" = "STRING" ] && [ -n "${2:-}" ]; then
    local f="$2"
    local lab="${3:-loot}"
    if [ ! -f "$f" ]; then
      _sjwarn "C2EXFIL: missing file $f"
      return 1
    fi
    SERIAL_WRITE "[*] C2EXFIL $lab ($f)"
    LOG green "C2EXFIL → $lab ($(wc -c <"$f" 2>/dev/null | tr -d ' ') bytes)"
    local q="${SHARKJACK_LOOT:-/root/loot}/c2-exfil"
    mkdir -p "$q" 2>/dev/null || true
    if [ -d "$q" ] && [ -w "$q" ]; then
      cp -f "$f" "$q/${lab}-$(date +%s).txt" 2>/dev/null || true
    fi
    return 0
  fi
  if [ "$#" -ge 2 ] && [ -f "${1:-}" ] && [ -n "${2:-}" ]; then
    local f="$1" lab="$2"
    SERIAL_WRITE "[*] C2EXFIL $lab ($f)"
    LOG green "C2EXFIL → $lab ($(wc -c <"$f" 2>/dev/null | tr -d ' ') bytes)"
    local q="${SHARKJACK_LOOT:-/root/loot}/c2-exfil"
    mkdir -p "$q" 2>/dev/null || true
    if [ -d "$q" ] && [ -w "$q" ]; then
      cp -f "$f" "$q/${lab}-$(date +%s).txt" 2>/dev/null || true
    fi
    return 0
  fi
  _sjwarn "C2EXFIL: $* (expected STRING <file> <label> or <file> <label>)"
  return 1
}

UPDATE_PAYLOADS() {
  SERIAL_WRITE "[*] UPDATE_PAYLOADS: downloading repository…"
  if _sj_github_library_sync 1; then
    SERIAL_WRITE "[*] Successfully synchronized payloads repository."
    return 0
  fi
  SERIAL_WRITE "[!] UPDATE_PAYLOADS failed — check network and tools (wget/curl, tar)."
  return 1
}

LIST() {
  LIST_PAYLOADS "$@"
}

LIST_PAYLOADS() {
  local lib="${LIBRARY:-$SHARKJACK_LIBRARY}"
  local d n rel
  echo "Payloads"
  echo "========"
  echo ""
  if [ ! -d "$lib" ]; then
    echo "(library missing: $lib)"
    return 1
  fi
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    n=$(basename "$d")
    echo "$n"
    echo "---------"
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      echo "    $(basename "$(dirname "$rel")")"
    done < <(find "$d" -name payload.sh -type f 2>/dev/null | sort)
    echo ""
  done < <(find "$lib" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
}

ACTIVATE() {
  ACTIVATE_PAYLOAD "$@"
}

ACTIVATE_PAYLOAD() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    echo "usage: ACTIVATE <category/name|path/to/payload.sh>" >&2
    return 1
  fi
  local abs=""
  if [ -f "$target" ]; then
    abs=$(CDPATH= cd -- "$(dirname "$target")" && pwd)/$(basename "$target")
  elif [ -f "$LIBRARY/$target/payload.sh" ]; then
    abs="$LIBRARY/$target/payload.sh"
  elif [ -f "$LIBRARY/$target" ]; then
    abs="$LIBRARY/$target"
  else
    echo "ACTIVATE: not found: $target" >&2
    return 1
  fi
  mkdir -p "${SHARKJACK_HUB:-/root/sharkjack}" 2>/dev/null || true
  printf '%s\n' "$abs" >"${SHARKJACK_HUB:-/root/sharkjack}/activated_payload"
  sync 2>/dev/null || true
  SERIAL_WRITE "[*] Activated: $abs"
  return 0
}

GET_ACTIVATED_PAYLOAD() {
  local ap="${SHARKJACK_HUB:-/root/sharkjack}/activated_payload"
  [ -f "$ap" ] || return 1
  head -1 "$ap" 2>/dev/null | tr -d '\r'
}

DEACTIVATE_PAYLOAD() {
  rm -f "${SHARKJACK_HUB:-/root/sharkjack}/activated_payload" 2>/dev/null || true
  SERIAL_WRITE "[*] Cleared activated payload"
  return 0
}

ENSURE_LOOT() {
  mkdir -p "${SHARKJACK_LOOT:-$LOOT_ROOT}" 2>/dev/null || return 1
  return 0
}

SERIAL_READ() {
  local n="${1:-256}"
  [ -n "${SHARKJACK_SERIAL_DEVICE:-}" ] && [ -r "${SHARKJACK_SERIAL_DEVICE}" ] 2>/dev/null || return 0
  if command -v timeout >/dev/null 2>&1; then
    timeout 0.3 dd if="${SHARKJACK_SERIAL_DEVICE}" bs=1 count="$n" status=none 2>/dev/null || true
  else
    dd if="${SHARKJACK_SERIAL_DEVICE}" bs=1 count=1 status=none 2>/dev/null || true
  fi
}

halt() {
  if [ "${SHARKJACK_ALLOW_HALT:-0}" = "1" ]; then
    command halt "$@"
    exit $?
  fi
  SERIAL_WRITE "[*] halt (simulated — return to menu)"
  LOG cyan "  halt — simulated"
  exit 120
}

poweroff() {
  if [ "${SHARKJACK_ALLOW_HALT:-0}" = "1" ]; then
    command poweroff "$@"
    exit $?
  fi
  SERIAL_WRITE "[*] poweroff (simulated — return to menu)"
  LOG cyan "  poweroff — simulated"
  exit 120
}

reboot() {
  if [ "${SHARKJACK_ALLOW_HALT:-0}" = "1" ]; then
    command reboot "$@"
    exit $?
  fi
  SERIAL_WRITE "[*] reboot (simulated — return to menu)"
  LOG cyan "  reboot — simulated"
  exit 120
}

_sj_github_library_sync() {
  local force="${1:-0}"
  local tmp url inner base dl spin
  url="${SHARKJACK_GITHUB_ARCHIVE_URL:?}"
  local cnt=0
  if [ -d "$LIBRARY" ]; then
    cnt=$(find "$LIBRARY" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
    cnt=$((cnt + 0))
  fi
  if [ "$cnt" -gt 0 ] && [ "$force" != "1" ]; then
    return 2
  fi

  tmp=$(mktemp -d) || return 1

  if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi

  spin=""
  spin=$(START_SPINNER "Downloading…" 2>/dev/null) || true

  set +e
  dl=1
  if command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$tmp/sj.tar.gz"
    dl=$?
  else
    curl -fsSL "$url" -o "$tmp/sj.tar.gz"
    dl=$?
  fi
  [ -n "$spin" ] && STOP_SPINNER "$spin" 2>/dev/null || true
  set -e

  if [ "$dl" -ne 0 ] || [ ! -s "$tmp/sj.tar.gz" ]; then
    rm -rf "$tmp"
    return 1
  fi

  if ! tar -xzf "$tmp/sj.tar.gz" -C "$tmp" 2>/dev/null; then
    rm -rf "$tmp"
    return 1
  fi

  base=$(find "$tmp" -maxdepth 1 -type d -name 'sharkjack-payloads-*' 2>/dev/null | head -1)
  inner="${base}/payloads/library"
  if [ -z "$base" ] || [ ! -d "$inner" ]; then
    rm -rf "$tmp"
    return 1
  fi

  rm -rf "$LIBRARY"
  mkdir -p "$LIBRARY" || {
    rm -rf "$tmp"
    return 1
  }

  if ! cp -a "$inner/." "$LIBRARY/"; then
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"

  find "$LIBRARY" -name payload.sh -type f -exec chmod +x {} \; 2>/dev/null || true
  return 0
}


sj_trunc() { printf '%s' "$1" | cut -c1-18; }

sj_wan_device_banner() {
  local line
  if [ "${SHARKJACK_WAN_LINK:-usb}" = "wlan" ]; then
    line="${SHARKJACK_ETH_ALIAS:-eth0}→${SHARKJACK_WAN_IF:-wlan0cli} · Wi‑Fi"
  else
    line="${SHARKJACK_ETH_ALIAS:-eth0}→${SHARKJACK_WAN_IF:-eth1} · USB"
  fi
  LOG blue "  $(sj_trunc "$line")"
}

sj_net_restore() {
  [ "${SHARKJACK_SKIP_NET_RESTORE:-0}" = "1" ] && return 0
  local dev="${SHARKJACK_WAN_IF_AT_START:-${SHARKJACK_WAN_IF:-eth1}}"
  local ubus_if="${SHARKJACK_UBUS_IF:-$dev}"
  export SHARKJACK_WAN_IF="$dev"
  if command -v ubus >/dev/null 2>&1; then
    ubus call network.interface."$ubus_if" down 2>/dev/null || true
    ubus call network.interface."$ubus_if" up 2>/dev/null || true
  fi
  if command -v ifdown >/dev/null 2>&1 && command -v ifup >/dev/null 2>&1; then
    ifdown "$dev" 2>/dev/null || true
    ifup "$dev" 2>/dev/null || true
  fi
  return 0
}

sj_menu_pause() {
  [ "${SHARKJACK_MENU_PAUSE_MS:-0}" = "0" ] && return 0
  sleep "${SHARKJACK_MENU_PAUSE_MS:-0}" 2>/dev/null || true
}

sj_before_picker() {
  local mode="${SHARKJACK_MENU_READY:-}"
  [ -z "$mode" ] && mode=wait
  case "$mode" in
    off | 0 | false) return 0 ;;
    sleep | timer) sj_menu_pause ;;
    prompt)
      PROMPT "OK" 2>/dev/null || sj_menu_pause ;;
    wait | button | any | *)
      if command -v WAIT_FOR_INPUT >/dev/null 2>&1; then
        LOG yellow "  Any button → input"
        WAIT_FOR_INPUT >/dev/null 2>&1 || true
      else
        sj_menu_pause
      fi
      ;;
  esac
}

sj_ui_title() {
  LOG magenta "$(printf '%s\n' "──────────────────" "  $1" "──────────────────")"
}

sj_splash_mode_hint() {
  [ "$SHARKJACK_QUIET" = "1" ] && return
  if [ "${SHARKJACK_WAN_LINK:-usb}" = "wlan" ]; then
    LOG cyan "Wi‑Fi  download · wlan0cli run"
    if command -v ip >/dev/null 2>&1 && command ip link show "${SHARKJACK_WAN_IF:-wlan0cli}" >/dev/null 2>&1; then
      LOG green "  Wi‑Fi WAN (${SHARKJACK_WAN_IF:-wlan0cli})"
    else
      LOG yellow "  Bring up ${SHARKJACK_WAN_IF:-wlan0cli} (wlan0cli)"
    fi
    return 0
  fi
  LOG cyan "Wi‑Fi  download · Ext Eth run"
  if [ "${SHARKJACK_SKIP_USB_CHECK:-0}" = "1" ]; then
    LOG yellow "USB check disabled"
  elif [ -n "${SHARKJACK_USB_ETH_ID:-}" ] && command -v lsusb >/dev/null 2>&1 \
    && lsusb 2>/dev/null | grep -qi "$SHARKJACK_USB_ETH_ID" \
    && command -v ip >/dev/null 2>&1 \
    && command ip link show "${SHARKJACK_WAN_IF:-eth1}" >/dev/null 2>&1; then
    LOG green "USB adapter ready"
  fi
}

sj_led_rainbow_boot() {
  [ "${SHARKJACK_RAINBOW:-1}" = "0" ] && return 0
  command -v LED >/dev/null 2>&1 || return 0
  if [ "${SHARKJACK_RAINBOW_NATIVE:-0}" = "1" ] \
    && { command LED RAINBOW 2>/dev/null || command LED RAINBOW SLOW 2>/dev/null; }; then
    sleep "${SHARKJACK_RAINBOW_MS:-2.2}"
    command LED OFF 2>/dev/null || true
    return 0
  fi
  local step="${SHARKJACK_RAINBOW_STEP_MS:-0.15}"
  local n
  for n in R Y G C B M; do
    command LED "${n}" SOLID 2>/dev/null || command LED "${n}" 2>/dev/null || true
    sleep "$step"
  done
  command LED OFF 2>/dev/null || true
}

banner() {
  local f='·'
  LOG magenta "┌──────────────────┐"
  LOG magenta "│·\___)\___${f}${f}${f}Shark│"
  LOG magenta "│ /--v__°<${f}${f}${f}${f}Pager│"
  LOG magenta "│${f}${f}${f}${f}${f}${f}\"${f}${f}${f}${f}${f}${f}${f}${f}${f}${f}${f}│"
  LOG magenta "│${f}${f}by${f}InfoSecREDD${f}${f}│"
  LOG magenta "└──────────────────┘"
}

splash() {
  sj_led_rainbow_boot
  LED M SOLID 2>/dev/null || true
  VIBRATE 60 30 60 2>/dev/null || true
  banner
  LOG ""
  LOG blue "$(printf '%s\n' "  SharkPager" "  Payload library")"
  LOG cyan "  -> $(sj_trunc "${SHARKJACK_HUB:-/root/sharkjack}")"
  sj_wan_device_banner
  LOG ""
  sj_splash_mode_hint
  local pc
  pc=$(count_payloads)
  if [ "$pc" -eq 0 ]; then
    LOG yellow "  No library yet — menu 5"
  else
    LOG green "  $pc payload(s) ready"
  fi
  if [ -f "${SHARKJACK_HUB:-/root/sharkjack}/activated_payload" ]; then
    LOG cyan "  Active: $(sj_trunc "$(head -1 "${SHARKJACK_HUB:-/root/sharkjack}/activated_payload" 2>/dev/null)")"
  fi
  LOG ""
  RINGTONE desk 2>/dev/null || RINGTONE success 2>/dev/null || true
  sj_menu_pause
}

sj_ensure_payload_layout() {
  local hub="${SHARKJACK_HUB:-/root/sharkjack}"

  mkdir -p "$PAYLOAD_HOME" 2>/dev/null || true
  mkdir -p "$SHARKJACK_HOME" 2>/dev/null || true
  mkdir -p "$LOOT_ROOT" 2>/dev/null || true
  mkdir -p "$hub" 2>/dev/null || true
  mkdir -p "$(dirname -- "$LIBRARY")" 2>/dev/null || true

  if ! mkdir -p "$LIBRARY" 2>/dev/null; then
    SHARKJACK_LIBRARY="$hub/library"
    LIBRARY="$SHARKJACK_LIBRARY"
    export SHARKJACK_LIBRARY LIBRARY
    mkdir -p "$hub" 2>/dev/null || true
    mkdir -p "$LIBRARY" 2>/dev/null || true
  fi
  if [ ! -d "$LIBRARY" ]; then
    SHARKJACK_LIBRARY="$hub/library"
    LIBRARY="$SHARKJACK_LIBRARY"
    export SHARKJACK_LIBRARY LIBRARY
    mkdir -p "$LIBRARY" 2>/dev/null || true
  fi
  if [ ! -d "$LIBRARY" ]; then
    SHARKJACK_LIBRARY="/tmp/sharkjack-library"
    LIBRARY="$SHARKJACK_LIBRARY"
    export SHARKJACK_LIBRARY LIBRARY
    mkdir -p "$LIBRARY" 2>/dev/null || true
  fi

  if [ ! -d "$LIBRARY" ]; then
    ALERT "Cannot create library directory

Tried: $SHARKJACK_HUB/library and /tmp/sharkjack-library
PAYLOAD_HOME=$PAYLOAD_HOME (payload dir may be read-only — library uses /root/sharkjack by default)"
    exit 1
  fi

  if [ ! -w "$LIBRARY" ]; then
    chmod 775 "$LIBRARY" 2>/dev/null || chmod 755 "$LIBRARY" 2>/dev/null || true
  fi
  if [ ! -w "$LIBRARY" ]; then
    ALERT "Library directory not writable

$LIBRARY"
    exit 1
  fi

  touch "$hub/.sharkjack_launcher_ready" 2>/dev/null || true
  touch "$PAYLOAD_HOME/.sharkjack_launcher_ready" 2>/dev/null || true
  sj_ensure_root_hub_links
}

sj_ensure_root_hub_links() {
  local hub="${SHARKJACK_HUB:-/root/sharkjack}"
  mkdir -p "$hub" 2>/dev/null || return 0
  if [ "$LIBRARY" != "$hub/library" ]; then
    ln -sfn "$LIBRARY" "$hub/library" 2>/dev/null || true
  fi
  ln -sfn "$LOOT_ROOT" "$hub/loot" 2>/dev/null || true
  ln -sfn "$PAYLOAD_HOME" "$hub/launcher" 2>/dev/null || true
}

require_usb_ethernet_mod() {
  [ "${SHARKJACK_SKIP_USB_CHECK:-0}" = "1" ] && return 0
  if [ "${SHARKJACK_WAN_LINK:-usb}" = "wlan" ]; then
    local dev="${SHARKJACK_WAN_IF:-wlan0cli}"
    if ! command -v ip >/dev/null 2>&1 || ! command ip link show "$dev" >/dev/null 2>&1; then
      LOG red "  Wi‑Fi WAN iface missing: $dev"
      LOG yellow "  Bring up wlan0cli (Pager internal WAN) or set SHARKJACK_WAN_IF"
      LED FAIL 2>/dev/null || true
      return 1
    fi
    return 0
  fi
  if [ -z "${SHARKJACK_USB_ETH_ID:-}" ]; then
    LOG red "  External Ethernet mod required"
    LOG yellow "  SHARKJACK_USB_ETH_ID (e.g. 0bda:8152)"
    LED FAIL 2>/dev/null || true
    return 1
  fi
  if ! command -v lsusb >/dev/null 2>&1; then
    LOG red "  lsusb missing"
    LOG yellow "  opkg install usbutils"
    LED FAIL 2>/dev/null || true
    return 1
  fi
  if ! lsusb 2>/dev/null | grep -qi "$SHARKJACK_USB_ETH_ID"; then
    LOG red "  USB adapter not plugged in"
    LOG yellow "  Expect lsusb: $SHARKJACK_USB_ETH_ID"
    LED FAIL 2>/dev/null || true
    return 1
  fi
  local dev="${SHARKJACK_WAN_IF:-eth1}"
  if ! command -v ip >/dev/null 2>&1 || ! command ip link show "$dev" >/dev/null 2>&1; then
    LOG red "  Eth mod iface missing: $dev"
    LOG yellow "  Plug USB Ethernet, wait for driver"
    LED FAIL 2>/dev/null || true
    return 1
  fi
  return 0
}

compat_help_text() {
  sj_ui_title "HELP"
  LOG cyan "$(printf '%s\n' \
    "  LED SERIAL SERIAL_READ" \
    "  SWITCH BATTERY % CHARGING" \
    "  GET_WAN_IP NETMODE C2 / C2EXFIL" \
    "  UPDATE LIST ACTIVATE DEACTIVATE" \
    "  ENSURE_LOOT  halt→menu (sim)" \
    "  ip/ifconfig/route  tcpdump arp-scan nmap lldpd netdiscover traceroute")"
  LOG ""
  if [ "${SHARKJACK_WAN_LINK:-usb}" = "wlan" ]; then
    LOG blue "$(printf '%s\n' \
      "  Lib  $(sj_trunc "${SHARKJACK_HUB:-/root/sharkjack}")" \
      "  eth0→${SHARKJACK_WAN_IF:-wlan0cli}  Wi‑Fi WAN (wlan0cli)" \
      "  SHARKJACK_WAN_LINK=wlan · hub/.eth_mod_if")"
  else
    LOG blue "$(printf '%s\n' \
      "  Lib  $(sj_trunc "${SHARKJACK_HUB:-/root/sharkjack}")" \
      "  eth0→${SHARKJACK_WAN_IF:-eth1}  USB Eth mod" \
      "  SHARKJACK_WAN_LINK=usb · hub/.eth_mod_if")"
  fi
  LOG ""
  LOG yellow "$(printf '%s\n' \
    "  Menu 0–7 · Browse · Activate" \
    "  SWITCH  keys + switch_state" \
    "  SHARKJACK_SWITCH_EXPECT 1|2|3")"
  LOG ""
}

list_categories() {
  find "$LIBRARY" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | while IFS= read -r d; do
    basename "$d"
  done
}

count_payloads() {
  find "$LIBRARY" -name payload.sh -type f 2>/dev/null | wc -l | tr -d ' '
}

sj_load_eth_mod_if() {
  local hub="${SHARKJACK_HUB:-/root/sharkjack}" f w
  f="$hub/.eth_mod_if"
  [ -f "$f" ] || f="$hub/.wan_if"
  [ -f "$f" ] || return 0
  w=$(head -1 "$f" 2>/dev/null | tr -d '\r\n' | tr -d ' ')
  [ -z "$w" ] && return 0
  export SHARKJACK_WAN_IF="$w"
}

sj_deactivate_menu() {
  local ap cur
  ap="${SHARKJACK_HUB:-/root/sharkjack}/activated_payload"
  sj_ui_title "DEACTIVATE"
  if [ ! -f "$ap" ]; then
    LOG yellow "  No activated payload"
    sj_menu_pause
    return
  fi
  cur=$(head -1 "$ap" 2>/dev/null | tr -d '\r')
  LOG blue "  $(sj_trunc "$cur")"
  LOG yellow "  Clear activation?"
  sj_before_picker
  local r
  r=$(CONFIRMATION_DIALOG "Clear activation?") || true
  if [ "$r" = "1" ]; then
    DEACTIVATE_PAYLOAD
    LOG green "  Cleared"
    PROMPT "OK" || true
  fi
}

main_menu() {
  local n c
  while true; do
    n=$(count_payloads)
    LED C SOLID 2>/dev/null || true
    sj_ui_title "MENU"
    sj_wan_device_banner
    LOG cyan "$(printf '%s\n' "  Library · $n payload(s)" "")"
    LOG green "$(printf '%d  %s\n' \
      1 "- Browse · run" \
      2 "- Quick run" \
      3 "- Set active payload" \
      4 "- Clear activation" \
      5 "- Download library" \
      6 "- Switch mode" \
      7 "- Help")"
    LOG ""
    LOG blue "  0 - Exit"
    LOG yellow "  1–7  select · cancel redraw"
    VIBRATE 35 20 35 2>/dev/null || true
    sj_before_picker
    c=$(NUMBER_PICKER "0–7" 0) || true
    [ -z "$c" ] && continue
    case "$c" in
      0) exit 0 ;;
      1) browse_categories run ;;
      2) quick_run ;;
      3) browse_categories activate ;;
      4) sj_deactivate_menu ;;
      5) download_github_library ;;
      6) sj_switch_mode_menu ;;
      7) help_compat ;;
      *) LOG red "  Invalid choice" ;;
    esac
  done
}

help_compat() {
  compat_help_text
  sj_menu_pause
  PROMPT "Continue" || true
  return
}

download_github_library() {
  local resp cnt
  while true; do
    LED B SOLID 2>/dev/null || true
    sj_ui_title "DOWNLOAD"
    LOG blue "  hak5/sharkjack-payloads"
    LOG cyan "  Official Hak5 archive"
    LOG yellow "  Requires network (Wi‑Fi OK)"

    cnt=0
    if [ -d "$LIBRARY" ]; then
      cnt=$(find "$LIBRARY" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
      cnt=$((cnt + 0))
    fi
    if [ "$cnt" -gt 0 ]; then
      sj_before_picker
      resp=$(CONFIRMATION_DIALOG "Replace library folder?") || true
      [ "$resp" = "1" ] || continue
    fi

    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
      LOG red "  Install wget or curl (opkg)"
      PROMPT "OK" || true
      return
    fi

    if _sj_github_library_sync 1; then
      LOG green "  Installed  $(count_payloads) payload(s)"
      LOG cyan "  $(sj_trunc "$LIBRARY")"
      RINGTONE success 2>/dev/null || true
      PROMPT "Library ready" || true
      return
    fi
    LOG red "  Sync failed (network, URL, or tar)"
    PROMPT "OK" || true
    return
  done
}

browse_categories() {
  local mode="${1:-run}"
  local cats=()
  while IFS= read -r line; do
    [ -n "$line" ] && cats+=("$line")
  done < <(list_categories)

  if [ "${#cats[@]}" -eq 0 ]; then
    LOG red "  No categories in library"
    return
  fi

  local pick cat bp
  while true; do
    if [ "$mode" = "activate" ]; then
      sj_ui_title "ACTIVATE"
    else
      sj_ui_title "BROWSE"
    fi
    local i=0 buf=""
    for c in "${cats[@]}"; do
      i=$((i + 1))
      buf="${buf}$(printf '%d  %s\n' "$i" "$(sj_trunc "$c")")"
    done
    LOG green "$buf"
    LOG yellow "  1–$i  pick · 0  back"
    VIBRATE 30 15 30 2>/dev/null || true
    sj_before_picker
    pick=$(NUMBER_PICKER "0–$i" 0) || true
    [ -z "$pick" ] && continue
    [ "$pick" -eq 0 ] && return
    if [ "$pick" -lt 1 ] || [ "$pick" -gt "$i" ]; then
      LOG red "  Invalid choice"
      continue
    fi
    cat="${cats[$((pick - 1))]}"
    browse_payloads "$cat" "$mode"
    bp=$?
    [ "$bp" -eq 1 ] && continue
    return 0
  done
}

browse_payloads() {
  local cat="$1"
  local mode="${2:-run}"
  local base="$LIBRARY/$cat"
  local paths=()
  mapfile -t paths < <(find "$base" -name payload.sh -type f 2>/dev/null | sort)

  if [ "${#paths[@]}" -eq 0 ]; then
    LOG red "  No payload.sh in $(sj_trunc "$cat")"
    return 1
  fi

  local offset=0
  local total=${#paths[@]}
  while true; do
    local pages=$(( (total + PAGE_SIZE - 1) / PAGE_SIZE ))
    local cur=$(( offset / PAGE_SIZE + 1 ))
    sj_ui_title "$(sj_trunc "$cat")"
    LOG cyan "$(printf '%s\n' "  $cur / $pages  ·  $total payload(s)" "")"
    local j=0 k buf=""
    for ((k = 0; k < PAGE_SIZE; k++)); do
      local idx=$((offset + k))
      [ "$idx" -ge "$total" ] && break
      j=$((j + 1))
      local rel="${paths[$idx]#$LIBRARY/}"
      buf="${buf}$(printf '%d  %s\n' "$j" "$(sj_trunc "$(dirname "$rel")")")"
    done
    LOG blue "$buf"
    [ "$j" -eq 0 ] && break

    if [ "$mode" = "activate" ]; then
      LOG yellow "$(printf '%s\n' "  0  next · 9  main menu" "  1–$j  set active")"
    else
      LOG yellow "$(printf '%s\n' "  0  next · 9  main menu" "  1–$j  run")"
    fi
    VIBRATE 30 15 30 2>/dev/null || true
    sj_before_picker
    local a
    a=$(NUMBER_PICKER "0–9" 0) || true
    [ -z "$a" ] && continue
    if [ "$a" -eq 9 ]; then
      return 2
    fi
    if [ "$a" -eq 0 ]; then
      offset=$((offset + PAGE_SIZE))
      [ "$offset" -ge "$total" ] && offset=0
      continue
    fi
    if [ "$a" -ge 1 ] && [ "$a" -le "$j" ]; then
      local target_idx=$((offset + a - 1))
      local prc=0
      if [ "$mode" = "activate" ]; then
        if ACTIVATE_PAYLOAD "${paths[$target_idx]}"; then
          LOG green "  Active  $(sj_trunc "$(basename "$(dirname "${paths[$target_idx]}")")")"
          RINGTONE success 2>/dev/null || true
          PROMPT "Activated" || true
        else
          LOG red "  Activate failed"
          PROMPT "OK" || true
        fi
        return 2
      fi
      run_payload "${paths[$target_idx]}" || prc=$?
      VIBRATE 40 2>/dev/null || true
      [ "$prc" -eq 2 ] && continue
      [ "$prc" -eq 4 ] && return 2
      [ "$prc" -eq 1 ] && return 2
    fi
  done
  return 2
}

quick_run() {
  local p rc def ap
  def="${LIBRARY:-$SHARKJACK_LIBRARY}/recon/ipinfo/payload.sh"
  if ap=$(GET_ACTIVATED_PAYLOAD 2>/dev/null) && [ -n "$ap" ] && [ -f "$ap" ]; then
    def="$ap"
  fi
  while true; do
    sj_ui_title "QUICK RUN"
    LOG blue "  Full path to payload.sh"
    if [ "$def" != "${LIBRARY:-$SHARKJACK_LIBRARY}/recon/ipinfo/payload.sh" ]; then
      LOG cyan "  Default  $(sj_trunc "$def")"
    fi
    sj_before_picker
    p=$(TEXT_PICKER "payload.sh" "$def") || true
    [ -z "$p" ] && return
    if [ ! -f "$p" ]; then
      LOG red "  File not found"
      continue
    fi
    rc=0
    run_payload "$p" || rc=$?
    [ "$rc" -eq 2 ] && continue
    [ "$rc" -eq 4 ] && return
    break
  done
  return
}

run_payload() {
  local script="$1"
  if ! require_usb_ethernet_mod; then
    PROMPT "Plug Eth mod" || true
    return 2
  fi
  LOG green "  Run  $(sj_trunc "$(basename "$(dirname "$script")")")"
  LED Y SOLID 2>/dev/null || true
  set +e
  (
    set +e
    set +u
    set +o pipefail 2>/dev/null || true
    source "$script"
  )
  local rc=$?
  set -e
  if [ "$rc" -eq 120 ]; then
    LED FINISH 2>/dev/null || true
    LOG cyan "  halt/poweroff/reboot (simulated)"
    return 4
  fi
  if [ "$rc" -ne 0 ]; then
    LED R SOLID 2>/dev/null || true
    LOG red "  Exit code  $rc"
    PROMPT "Failed ($rc)" || true
    return 1
  fi
  LED FINISH 2>/dev/null || true
  LOG green "  Finished OK"
  PROMPT "Done ($rc)" || true
  return 0
}

sj_ensure_payload_layout
sj_load_eth_mod_if
SHARKJACK_WAN_IF_AT_START="${SHARKJACK_WAN_IF:-eth1}"
export SHARKJACK_WAN_IF_AT_START

trap sj_net_restore EXIT

splash
main_menu
exit 0
