#!/bin/sh
# BashBunny Manager backend — transport-agnostic ops over a docked BashBunny (arming mode).
# Backends: msd (Pager mounts the udisk LUN; plain file ops) | console (bunnyarm.py getty).
# Env: BB_BACKEND(msd|console, auto if unset) BB_MOUNT(default /mnt/bb_udisk) BB_NO_MOUNT(1=skip mount)
#      BB_PORT(console) BB_PY(python3) BB_ARM_PY(bunnyarm.py path)
BB_MOUNT="${BB_MOUNT:-/mnt/bb_udisk}"

_pay()  { printf '%s' "$BB_MOUNT/payloads"; }
_loot() { printf '%s' "$BB_MOUNT/loot"; }
meta_title()   { grep -m1 -iE '^# *title:'   "$1" 2>/dev/null | sed 's/^# *[Tt]itle: *//'; }
meta_version() { grep -m1 -iE '^# *version:' "$1" 2>/dev/null | sed 's/^# *[Vv]ersion: *//'; }
_basename_noext() { b="$(basename "$1")"; printf '%s' "${b%.*}"; }

# --- MSD backend -------------------------------------------------------------
# Compact switch summary for the UI: "SW1 = <title> [v<version>]" per switch.
msd_switches() {
  for s in 1 2; do
    f="$(_pay)/switch$s/payload.txt"
    if [ -f "$f" ]; then
      t="$(meta_title "$f")"; [ -z "$t" ] && t="(untitled)"
      v="$(meta_version "$f")"; [ -n "$v" ] && t="$t v$v"
    else t="(empty)"; fi
    echo "SW$s = $t"
  done
}

msd_status() {
  echo "backend: msd"
  for s in 1 2; do
    f="$(_pay)/switch$s/payload.txt"
    if [ -f "$f" ]; then t="$(meta_title "$f")"; [ -z "$t" ] && t="(untitled)"; else t="(empty)"; fi
    echo "switch$s: $t"
  done
  echo "firmware: n/a (mount mode)"
  free="$(df -k "$BB_MOUNT" 2>/dev/null | awk 'NR==2{print $4}')"
  tot="$(df -k "$BB_MOUNT" 2>/dev/null | awk 'NR==2{print $2}')"
  echo "udisk: $(( ${free:-0} / 1024 )) MB free / $(( ${tot:-0} / 1024 )) MB"
}

msd_lib_list() {
  L="$(_pay)/library"; [ -d "$L" ] || return 0
  ( cd "$L" && find . -name payload.txt 2>/dev/null \
      | sed 's#^\./##; s#/payload.txt$##' | sort )
}

msd_preview() {
  rel="$1"; [ -n "$rel" ] || { echo "usage: preview <relpath>" >&2; return 2; }
  case "$rel" in *..*) echo "bad path" >&2; return 2 ;; esac
  f="$(_pay)/$rel"; [ -f "$f" ] || { echo "not found: $rel" >&2; return 1; }
  head -20 "$f"
}

_valid_sw() { case "$1" in 1|2) return 0 ;; *) return 1 ;; esac; }
_safe_rel() { case "$1" in *..*|/*) return 1 ;; *) return 0 ;; esac; }

msd_assign() {
  sw="$1"; lib="$2"
  _valid_sw "$sw" || { echo "ERR bad switch: $sw" >&2; return 2; }
  { [ -n "$lib" ] && _safe_rel "$lib"; } || { echo "ERR bad lib name" >&2; return 2; }
  src="$(_pay)/library/$lib"; dst="$(_pay)/switch$sw"
  [ -d "$src" ] || { echo "ERR no such library payload: $lib" >&2; return 1; }
  rm -rf "$dst"; mkdir -p "$dst"
  if cp -a "$src"/. "$dst"/ 2>/dev/null || cp -r "$src"/. "$dst"/ 2>/dev/null; then
    sync 2>/dev/null; echo "OK assigned '$lib' -> switch$sw"
  else echo "ERR assign failed" >&2; return 1; fi
}

msd_swap() {
  a="$(_pay)/switch1"; b="$(_pay)/switch2"; t="$(_pay)/.swap.$$"
  # Recover, don't destroy: a temp left by a prior interrupted swap holds real
  # payload data. Route it back into whichever switch is missing; only discard
  # it when both switches are already present (a genuine orphan).
  for old in "$(_pay)"/.swap.*; do
    [ -d "$old" ] || continue
    if [ ! -d "$a" ]; then mv "$old" "$a"
    elif [ ! -d "$b" ]; then mv "$old" "$b"
    else rm -rf "$old"; fi
  done
  mkdir -p "$a" "$b"                  # normalize: a missing switch counts as empty
  if mv "$a" "$t" && mv "$b" "$a" && mv "$t" "$b"; then
    mkdir -p "$a" "$b"; sync 2>/dev/null; echo "OK swapped switch1<->switch2"
  else
    # best-effort: return the temp to whichever switch is now missing (no data loss)
    if [ -d "$t" ]; then
      if [ ! -d "$a" ]; then mv "$t" "$a" 2>/dev/null
      elif [ ! -d "$b" ]; then mv "$t" "$b" 2>/dev/null; fi
    fi
    echo "ERR swap failed" >&2; return 1
  fi
}

msd_clear_switch() {
  sw="$1"; _valid_sw "$sw" || { echo "ERR bad switch: $sw" >&2; return 2; }
  d="$(_pay)/switch$sw"; rm -rf "$d"; mkdir -p "$d"; sync 2>/dev/null
  echo "OK cleared switch$sw"
}

msd_loot_list() {
  L="$(_loot)"; [ -d "$L" ] || return 0
  ( cd "$L" && find . -type f 2>/dev/null | sed 's#^\./##' | sort ) | while IFS= read -r rel; do
      sz="$(wc -c < "$L/$rel" | tr -d ' ')"; printf '%s\t%s\n' "$sz" "$rel"
    done
}

msd_loot_pull() {
  rel="$1"; dest="$2"
  { [ -n "$rel" ] && _safe_rel "$rel" && [ -n "$dest" ]; } || { echo "usage: loot-pull <relpath> <destdir>" >&2; return 2; }
  src="$(_loot)/$rel"; [ -f "$src" ] || { echo "ERR not found: $rel" >&2; return 1; }
  mkdir -p "$dest/$(dirname "$rel")"; cp -a "$src" "$dest/$rel" && echo "OK pulled $rel"
}

msd_loot_pull_all() {
  dest="$1"; [ -n "$dest" ] || { echo "usage: loot-pull-all <destdir>" >&2; return 2; }
  L="$(_loot)"; [ -d "$L" ] || { echo "OK pulled 0 (0 skipped)"; return 0; }
  got=0; skip=0
  # Iterate via a tempfile, not a pipe: a `find | while` subshell can't export got/skip to the caller.
  lst="$(mktemp)"; ( cd "$L" && find . -type f 2>/dev/null | sed 's#^\./##' ) > "$lst"
  while IFS= read -r rel; do
    s="$L/$rel"; d="$dest/$rel"
    if [ -f "$d" ] && cmp -s "$s" "$d"; then skip=$((skip+1)); continue; fi
    mkdir -p "$dest/$(dirname "$rel")"; cp -a "$s" "$d" && got=$((got+1))
  done < "$lst"
  rm -f "$lst"
  echo "OK pulled $got ($skip skipped)"
}

msd_loot_empty() {
  L="$(_loot)"; [ -d "$L" ] && { rm -rf "$L"/* "$L"/.[!.]* 2>/dev/null; }
  mkdir -p "$L"; sync 2>/dev/null; echo "OK emptied loot"
}

msd_upload() {
  src="$1"; mode="$2"; cat3="$3"; lib="$(_pay)/library"
  [ -n "$src" ] || { echo "usage: upload <srcpath> <file|dir|sync> [category]" >&2; return 2; }
  case "$mode" in
    file)
      [ -f "$src" ] || { echo "ERR not a file: $src" >&2; return 1; }
      name="$(_basename_noext "$src")"
      case "$name" in ""|.|..|*/*) echo "ERR bad name: $name" >&2; return 2 ;; esac
      dst="$lib/uploaded/$name"
      mkdir -p "$dst"; cp -a "$src" "$dst/payload.txt" && { sync 2>/dev/null; echo "OK uploaded file -> uploaded/$name"; }
      ;;
    dir)
      [ -d "$src" ] || { echo "ERR not a dir: $src" >&2; return 1; }
      name="$(basename "$src")"
      case "$name" in ""|.|..|*/*) echo "ERR bad name: $name" >&2; return 2 ;; esac
      cat="$cat3"; [ -n "$cat" ] || cat="uploaded"
      case "$cat" in *..*|*/*) echo "ERR bad category: $cat" >&2; return 2 ;; esac
      dst="$lib/$cat/$name"; rm -rf "$dst"; mkdir -p "$dst"
      cp -a "$src"/. "$dst"/ && { sync 2>/dev/null; echo "OK uploaded dir -> $cat/$name"; }
      ;;
    sync)
      [ -d "$src" ] || { echo "ERR not a dir: $src" >&2; return 1; }
      mkdir -p "$lib"; cp -a "$src"/. "$lib"/ && { sync 2>/dev/null; echo "OK synced staging -> library"; }
      ;;
    *) echo "ERR bad mode: $mode (file|dir|sync)" >&2; return 2 ;;
  esac
}

msd_delete_lib() {
  lib="$1"; { [ -n "$lib" ] && _safe_rel "$lib"; } || { echo "ERR bad name" >&2; return 2; }
  d="$(_pay)/library/$lib"; [ -d "$d" ] || { echo "ERR no such payload: $lib" >&2; return 1; }
  rm -rf "$d"; sync 2>/dev/null; echo "OK deleted $lib"
}

msd_backup() {
  dest="$1"; [ -n "$dest" ] || { echo "usage: backup <destdir>" >&2; return 2; }
  mkdir -p "$dest"; : > "$dest/manifest.txt.tmp"    # truncate any stale tmp from an interrupted run
  for s in 1 2; do
    src="$(_pay)/switch$s"; rm -rf "$dest/switch$s"; mkdir -p "$dest/switch$s"
    [ -d "$src" ] && cp -a "$src"/. "$dest/switch$s"/ 2>/dev/null
    t="$(meta_title "$dest/switch$s/payload.txt")"; [ -z "$t" ] && t="(empty)"
    echo "switch$s: $t" >> "$dest/manifest.txt.tmp"
  done
  mv "$dest/manifest.txt.tmp" "$dest/manifest.txt" || { echo "ERR backup manifest write failed" >&2; return 1; }
  echo "OK backed up -> $dest"
}

msd_restore() {
  src="$1"; [ -n "$src" ] && [ -d "$src/switch1" ] || { echo "ERR no backup at: $src" >&2; return 1; }
  for s in 1 2; do
    [ -d "$src/switch$s" ] || continue
    dst="$(_pay)/switch$s"; rm -rf "$dst"; mkdir -p "$dst"; cp -a "$src/switch$s"/. "$dst"/ 2>/dev/null
  done
  sync 2>/dev/null; echo "OK restored from $src"
}

msd_readiness() {
  sw="$1"; _valid_sw "$sw" || { echo "ERR bad switch: $sw" >&2; return 2; }
  f="$(_pay)/switch$sw/payload.txt"; [ -f "$f" ] || { echo "ERR switch$sw empty" >&2; return 1; }
  am="$(grep -m1 -E '^ATTACKMODE' "$f" 2>/dev/null | sed 's/^ATTACKMODE *//')"
  echo "ATTACKMODE: ${am:-(none)}"
  miss=0
  # unique /tools/<name> references (first path segment under /tools)
  deps="$(grep -oE '/tools/[A-Za-z0-9._-]+' "$f" 2>/dev/null | sort -u)"
  for dep in $deps; do
    if [ -e "$BB_MOUNT$dep" ]; then echo "present: $dep"; else echo "MISSING: $dep"; miss=$((miss+1)); fi
  done
  if [ "$miss" -eq 0 ]; then echo "readiness: OK"; else echo "readiness: MISSING $miss"; fi
}

# Config = top-level `KEY=value` assignments whose value is empty or a placeholder
# (CHANGE/REPLACE/YOUR/ENTER/TODO/EXAMPLE/PLACEHOLDER/XXX / <...>) — i.e. the ones a
# freshly-assigned payload still needs the operator to fill in. Output: KEY<TAB>rawvalue.
msd_cfg_list() {
  sw="$1"; _valid_sw "$sw" || { echo "ERR bad switch: $sw" >&2; return 2; }
  f="$(_pay)/switch$sw/payload.txt"; [ -f "$f" ] || return 0
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$f" 2>/dev/null | while IFS= read -r _l; do
    _k="${_l%%=*}"; _val="${_l#*=}"
    _v="${_val%\"}"; _v="${_v#\"}"; _v="${_v%\'}"; _v="${_v#\'}"      # strip one layer of quotes
    _vu="$(printf '%s' "$_v" | tr 'a-z' 'A-Z')"
    case "$_vu" in
      ""|*CHANGE*|*REPLACE*|*YOUR*|*ENTER*|*TODO*|*EXAMPLE*|*PLACEHOLDER*|XXX*|"<"*)
        printf '%s\t%s\n' "$_k" "$_val" ;;
    esac
  done
}

msd_cfg_set() {
  sw="$1"; key="$2"; val="$3"
  _valid_sw "$sw" || { echo "ERR bad switch: $sw" >&2; return 2; }
  case "$key" in ""|*[!A-Za-z0-9_]*) echo "ERR bad key: $key" >&2; return 2 ;; esac
  f="$(_pay)/switch$sw/payload.txt"; [ -f "$f" ] || { echo "ERR switch$sw empty" >&2; return 1; }
  grep -q "^$key=" "$f" || { echo "ERR no such setting: $key" >&2; return 1; }
  tmp="$f.cfgtmp.$$"
  awk -v k="$key" -v v="$val" '{ if (index($0, k"=")==1) print k"="v; else print }' "$f" > "$tmp" \
    && mv "$tmp" "$f" && sync 2>/dev/null && echo "OK set $key on switch$sw" \
    || { rm -f "$tmp"; echo "ERR cfg-set failed" >&2; return 1; }
}

# --- backend selection + eject -----------------------------------------------
BB_MOUNTED_BY_US=0

# find a block partition that looks like a docked bunny udisk (has payloads/ once mounted)
_try_mount_msd() {
  [ -d "$BB_MOUNT/payloads" ] && return 0            # already mounted (or fixture)
  [ "${BB_NO_MOUNT:-0}" = "1" ] && return 1
  mkdir -p "$BB_MOUNT"
  for dev in $(ls /dev/sd?1 2>/dev/null); do
    mount -t vfat -o rw "$dev" "$BB_MOUNT" 2>/dev/null \
      || mount "$dev" "$BB_MOUNT" 2>/dev/null || continue
    if [ -d "$BB_MOUNT/payloads" ]; then BB_MOUNTED_BY_US=1; return 0; fi
    umount "$BB_MOUNT" 2>/dev/null
  done
  return 1
}

bb_select_backend() {
  [ -n "$BB_BACKEND" ] && return 0
  if _try_mount_msd; then BB_BACKEND=msd; else BB_BACKEND=console; fi
}

msd_eject() {
  sync 2>/dev/null
  # Each op runs as its own process, so the in-process mount flag can't be trusted here;
  # unmount whenever BB_MOUNT is genuinely mounted (mounts source overridable for tests).
  if grep -q " $BB_MOUNT " "${BB_PROCMOUNTS:-/proc/mounts}" 2>/dev/null; then
    umount "$BB_MOUNT" 2>/dev/null
  fi
  echo "OK safe to undock"
}

BB_PY="${BB_PY:-/mmc/usr/bin/python3}"
_find_arm_py() {
  for c in "$BB_ARM_PY" "$(dirname "$0")/bunnyarm.py" "/root/payloads/user/utility/bunnyarm/bunnyarm.py"; do
    [ -n "$c" ] && [ -f "$c" ] && { BB_ARM_PY="$c"; return 0; }
  done; return 1
}
con_call() { _find_arm_py || { echo "ERR bunnyarm.py missing" >&2; return 1; }
  LD_LIBRARY_PATH=/mmc/usr/lib:/mmc/lib PATH=/mmc/usr/bin:"$PATH" \
    "$BB_PY" "$BB_ARM_PY" --stty --port "${BB_PORT:-/dev/ttyACM2}" "$@"; }
con_status()       { con_call status; }
con_switches()     { con_call switches; }
con_lib_list()     { con_call libpayloads; }
con_preview()      { con_call preview "$@"; }
con_assign()       { con_call assign "$@"; }
con_swap()         { con_call swap; }
con_clear_switch() { con_call clear-switch "$@"; }
con_loot_list()    { con_call loot-list; }
con_loot_pull()    { con_call loot-pull "$@"; }
con_loot_pull_all() { con_call loot-pull-all "$@"; }
con_loot_empty()   { con_call loot-empty; }
con_upload()       { con_call upload "$@"; }
con_delete_lib()   { con_call delete-lib "$@"; }
con_backup()       { con_call backup "$@"; }
con_restore()      { con_call restore "$@"; }
con_readiness()    { con_call readiness "$@"; }
con_cfg_list()     { con_call cfg-list "$@"; }
con_cfg_set()      { con_call cfg-set "$@"; }
con_eject() { con_call eject; }   # bunnyarm.py syncs + umounts internally and prints the OK line

# --- dispatch ----------------------------------------------------------------
op="$1"; [ $# -gt 0 ] && shift
bb_select_backend
fn="$(printf '%s' "$op" | tr '-' '_')"
case "$BB_BACKEND" in
  msd)     "msd_$fn" "$@" ;;
  console) "con_$fn" "$@" ;;
  *) echo "unknown backend: $BB_BACKEND" >&2; exit 2 ;;
esac
