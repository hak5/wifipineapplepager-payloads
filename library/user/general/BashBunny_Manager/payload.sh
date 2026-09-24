#!/bin/sh
# Title: BashBunny Manager
# Author: lab81 <hello@lab81.io>
# Description: Administer a docked BashBunny (arming mode) from the Pager - assign/swap/clear switch payloads, browse & upload the library, download/empty loot, backup/restore switch config, readiness & per-switch settings.
# Version: 1.0
# Dependencies: none for the mass-storage backend (pure POSIX sh). The serial-console
#   fallback (used when the udisk isn't the exported LUN, e.g. a microSD is inserted)
#   needs python3 at /mmc/usr/bin/python3. LED/RINGTONE/VIBRATE feedback is optional.
# Scope: administration of the operator's OWN BashBunny. No target-facing / offensive actions.

DIR="$(dirname "$0")"
BB="$DIR/bb.sh"; [ -f "$BB" ] || BB="/root/payloads/user/utility/bunnyarm/bb.sh"
command -v LOG >/dev/null 2>&1 || LOG() { shift 2>/dev/null; echo "$*"; }

# --- Pager paths -------------------------------------------------------------
bb_resolve_base() {
  [ -n "$BB_PAGER_BASE" ] && { printf '%s' "$BB_PAGER_BASE"; return; }
  for b in /mmc/root /root; do [ -d "$b" ] && { printf '%s' "$b"; return; }; done
  printf '%s' "/root"
}
bb_paths() {
  _b="$(bb_resolve_base)"
  printf 'LOOT=%s/loot/FromBashBunny STAGE=%s/BashBunny_Payloads BACKUP=%s/BashBunny_Backups\n' "$_b" "$_b" "$_b"
}
# stamp-free timestamp for backup dirs (busybox date)
bb_stamp() { date +%Y%m%d-%H%M%S 2>/dev/null || echo backup; }

# Allow tests to source helpers without launching the menu.
[ "${BB_SOURCE_ONLY:-0}" = "1" ] && return 0 2>/dev/null

eval "$(bb_paths)"
mkdir -p "$LOOT" "$STAGE" "$BACKUP" 2>/dev/null

# --- UI helpers (Pager primitives; degrade to LOG/echo off-device) -----------
TAB="$(printf '\t')"
OKTUNE="ok:d=16,o=6,b=180:c,e,g"
ERRTUNE="er:d=8,o=5,b=120:e,c"
have()   { command -v "$1" >/dev/null 2>&1; }
info()   { if have PROMPT; then PROMPT "$1"; else LOG "" "$1"; fi; }            # modal, waits for dismiss
errdlg() { if have ERROR_DIALOG; then ERROR_DIALOG "$1"; else LOG "red" "$1"; fi; }
led()    { have LED && LED "$@" 2>/dev/null; return 0; }
tune()   { have RINGTONE && RINGTONE --vibrate "$1" 2>/dev/null; return 0; }
okfx()   { led G SINGLE; tune "$OKTUNE"; info "$1"; }                           # success feedback
failfx() { led R DOUBLE; tune "$ERRTUNE"; errdlg "$1"; }                        # failure feedback
spin_start() { SPINID=""; have START_SPINNER && SPINID="$(START_SPINNER "$1" 2>/dev/null)"; return 0; }
spin_stop()  { have STOP_SPINNER && [ -n "${SPINID:-}" ] && STOP_SPINNER "$SPINID" 2>/dev/null; SPINID=""; return 0; }

bbout()   { sh "$BB" "$@" 2>&1; }                                              # capture combined output
runinfo() { _o="$(sh "$BB" "$@" 2>&1)"; info "${_o:-(no output)}"; }           # info action -> modal
# runop "<clean success msg>" "<spinner text>" <op> [args] ; feedback on result
runop() {
  _msg="$1"; _spin="$2"; shift 2
  spin_start "$_spin"; _o="$(sh "$BB" "$@" 2>&1)"; _rc=$?; spin_stop
  if [ "$_rc" -eq 0 ] && ! printf '%s\n' "$_o" | grep -q '^ERR'; then okfx "$_msg"; return 0
  else failfx "$_msg
$_o"; return 1; fi
}

pick() { _t="$1"; _o="$2"; _oi="$IFS"; IFS='
'; set -- $_o; IFS="$_oi"; LIST_PICKER "$_t" "$@"; }

# pick_lib -> echoes "category/Name" (category filter with "All"); empty on cancel
pick_lib() {
  LIBS="$(sh "$BB" lib-list 2>/dev/null)"; [ -z "$LIBS" ] && { errdlg "No library payloads on the bunny."; return 1; }
  CATS="$(printf '%s\n' "$LIBS" | sed 's#/.*##' | sort -u)"
  N="$(printf '%s\n' "$LIBS" | grep -c .)"
  C="$(pick "Category ($N payloads)" "All
$CATS")" || return 1
  if [ "$C" = "All" ]; then
    P="$(pick "Payload (all $N)" "$LIBS")" || return 1
    printf '%s' "$P"
  else
    NAMES="$(printf '%s\n' "$LIBS" | sed -n "s#^$C/##p")"
    P="$(pick "$C" "$NAMES")" || return 1
    printf '%s/%s' "$C" "$P"
  fi
}

# assign a library payload to a switch, with feedback + post-assign config
assign_flow() {
  _sw="$1"; _lib="$2"
  if runop "Assigned to switch$_sw:
$_lib" "Assigning $_lib -> switch$_sw..." assign "$_sw" "$_lib"; then
    config_flow "$_sw"
  fi
}

# detect + set required configuration on the freshly-assigned switch payload
# (backed by bb.sh cfg-list/cfg-set; inert until those ops exist)
config_flow() {
  _sw="$1"
  have TEXT_PICKER || return 0
  _cfg="$(sh "$BB" cfg-list "$_sw" 2>/dev/null)"; [ -z "$_cfg" ] && return 0
  _cn="$(printf '%s\n' "$_cfg" | grep -c .)"
  CONFIRMATION_DIALOG "This payload has $_cn setting(s) to configure. Set them now?" || return 0
  printf '%s\n' "$_cfg" | while IFS="$TAB" read -r _k _v; do
    [ -n "$_k" ] || continue
    _new="$(TEXT_PICKER "Set $_k" "$_v")" || continue
    [ -n "$_new" ] && sh "$BB" cfg-set "$_sw" "$_k" "$_new" >/dev/null 2>&1
  done
  info "Configuration saved to switch$_sw."
}

# --- loading screen: wait for an armed bunny (spinner + LED + jingle) ---------
led B FAST
spin_start "lab81 · BashBunny Manager - linking to bunny..."
i=0; while [ ! -e /dev/ttyACM2 ] && [ ! -e /dev/ttyACM3 ] && [ "$i" -lt 40 ]; do sleep 1; i=$((i+1)); done
spin_stop
if [ -e /dev/ttyACM2 ] || [ -e /dev/ttyACM3 ]; then
  led G SOLID; tune "$OKTUNE"
else
  led R SOLID; errdlg "No BashBunny found. Arm it (switch pos 3, closest to USB) + dock, then re-run."
  led OFF; exit 0
fi
sleep 2
# backend label for the menu title (msd/console)
BK="$(bbout status 2>/dev/null | sed -n 's/^backend: //p' | head -1)"
[ -n "$BK" ] && TITLE="BashBunny Manager [$BK]" || TITLE="BashBunny Manager"

# --- main menu ---------------------------------------------------------------
while true; do
  A="$(LIST_PICKER "$TITLE" "Switches" "Loot" "Upload payload" "Library" "Backup/Restore" "Status" "Safe-eject & Exit" "Switches")" || break
  case "$A" in
    Switches)
      # Show the current assignment inline (SW1 = <payload> / SW2 = <payload>); tap a line to preview it.
      SWS="$(bbout switches 2>/dev/null)"
      L1="$(printf '%s\n' "$SWS" | sed -n '1p')"; [ -n "$L1" ] || L1="SW1 = ?"
      L2="$(printf '%s\n' "$SWS" | sed -n '2p')"; [ -n "$L2" ] || L2="SW2 = ?"
      S="$(LIST_PICKER "Switches" "$L1" "$L2" "Assign -> SW1" "Assign -> SW2" "Swap SW1/SW2" "Clear a switch" "Assign -> SW1")" || continue
      if [ "$S" = "$L1" ]; then runinfo preview "switch1/payload.txt"
      elif [ "$S" = "$L2" ]; then runinfo preview "switch2/payload.txt"
      else case "$S" in
        "Assign -> SW1") L="$(pick_lib)" && assign_flow 1 "$L" ;;
        "Assign -> SW2") L="$(pick_lib)" && assign_flow 2 "$L" ;;
        "Swap SW1/SW2")  CONFIRMATION_DIALOG "Swap switch1 and switch2?" && runop "Swapped SW1 <-> SW2" "Swapping..." swap ;;
        "Clear a switch") W="$(LIST_PICKER "Clear which" "1" "2" "1")" || continue
                          CONFIRMATION_DIALOG "Erase switch$W?" && runop "Cleared switch$W" "Clearing switch$W..." clear-switch "$W" ;;
      esac; fi ;;
    Loot)
      S="$(LIST_PICKER "Loot" "List" "Download all -> Pager" "Download one" "Empty loot" "List")" || continue
      case "$S" in
        "List") runinfo loot-list ;;
        "Download all -> Pager")
          spin_start "Downloading loot -> FromBashBunny..."
          _o="$(bbout loot-pull-all "$LOOT")"; _rc=$?; spin_stop
          if [ "$_rc" -eq 0 ] && ! printf '%s\n' "$_o" | grep -q '^ERR'; then
            led G SINGLE; tune "$OKTUNE"; info "Loot download complete.
$_o
-> $LOOT"
          else failfx "Loot download failed:
$_o"; fi ;;
        "Download one")
          FILES="$(sh "$BB" loot-list 2>/dev/null | cut -f2)"; [ -z "$FILES" ] && { info "No loot on the bunny."; continue; }
          F="$(pick "Loot file" "$FILES")" || continue
          runop "Downloaded: $F
-> $LOOT" "Downloading $F..." loot-pull "$F" "$LOOT" ;;
        "Empty loot") CONFIRMATION_DIALOG "Delete ALL loot on the bunny?" && runop "Loot emptied on the bunny" "Emptying loot..." loot-empty ;;
      esac ;;
    "Upload payload")
      ITEMS="$(ls -1 "$STAGE" 2>/dev/null)"; [ -z "$ITEMS" ] && { info "Put payloads in:
$STAGE
(organized as <category>/<Name>/)"; continue; }
      M="$(LIST_PICKER "Upload" "Sync whole folder" "Pick one payload" "Pick one payload")" || continue
      if [ "$M" = "Sync whole folder" ]; then
        CONFIRMATION_DIALOG "Sync $STAGE -> bunny library?" && runop "Synced staging -> bunny library" "Syncing..." upload "$STAGE" sync
      else
        DIRS="$(cd "$STAGE" 2>/dev/null && for d in */; do [ -d "$d" ] && printf '%s\n' "${d%/}"; done)"
        FILES="$(cd "$STAGE" 2>/dev/null && for f in *; do [ -f "$f" ] && printf '%s\n' "$f"; done)"
        CHOICES="$(printf '%s\n%s\n' "$DIRS" "$FILES" | sed '/^$/d')"
        [ -z "$CHOICES" ] && { info "Nothing to upload in $STAGE."; continue; }
        IT="$(pick "Category or file" "$CHOICES")" || continue
        if [ -d "$STAGE/$IT" ]; then
          PAYS="$(cd "$STAGE/$IT" 2>/dev/null && for d in */; do [ -d "$d" ] && printf '%s\n' "${d%/}"; done)"
          [ -z "$PAYS" ] && { info "No payload folders under $IT."; continue; }
          P="$(pick "$IT" "$PAYS")" || continue
          runop "Uploaded to library:
$IT/$P" "Uploading $IT/$P..." upload "$STAGE/$IT/$P" dir "$IT"
        else
          runop "Uploaded to library:
uploaded/$IT" "Uploading $IT..." upload "$STAGE/$IT" file
        fi
      fi ;;
    Library)
      S="$(LIST_PICKER "Library" "Browse payloads" "Delete a payload" "Readiness check" "Browse payloads")" || continue
      case "$S" in
        "Browse payloads")
          L="$(pick_lib)" || continue
          ACT="$(LIST_PICKER "$L" "Assign -> SW1" "Assign -> SW2" "Preview" "Back" "Preview")" || continue
          case "$ACT" in
            "Assign -> SW1") assign_flow 1 "$L" ;;
            "Assign -> SW2") assign_flow 2 "$L" ;;
            "Preview") runinfo preview "library/$L/payload.txt" ;;
            "Back") : ;;
          esac ;;
        "Delete a payload") L="$(pick_lib)" && CONFIRMATION_DIALOG "Delete $L from library?" && runop "Deleted from library:
$L" "Deleting..." delete-lib "$L" ;;
        "Readiness check") W="$(LIST_PICKER "Check which switch" "1" "2" "1")" || continue; runinfo readiness "$W" ;;
      esac ;;
    "Backup/Restore")
      S="$(LIST_PICKER "Backup/Restore" "Backup config -> Pager" "Restore config" "Backup config -> Pager")" || continue
      case "$S" in
        "Backup config -> Pager") T="$BACKUP/$(bb_stamp)"; runop "Backed up switch config -> Pager:
$T" "Backing up..." backup "$T" ;;
        "Restore config") SNAPS="$(ls -1 "$BACKUP" 2>/dev/null)"; [ -z "$SNAPS" ] && { info "No backups on the Pager yet."; continue; }
                SN="$(pick "Restore which" "$SNAPS")" || continue
                CONFIRMATION_DIALOG "Restore $SN onto the bunny?" && runop "Restored switch config from:
$SN" "Restoring..." restore "$BACKUP/$SN" ;;
      esac ;;
    Status) runinfo status ;;
    "Safe-eject & Exit") runop "Synced - safe to undock. Re-arm the bunny before use." "Ejecting..." eject; break ;;
  esac
done
led OFF
LOG "" "BashBunny Manager: done."
exit 0
