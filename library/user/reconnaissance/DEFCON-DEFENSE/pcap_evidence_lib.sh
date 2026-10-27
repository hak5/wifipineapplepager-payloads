#!/bin/bash
# Shared passive-PCAP evidence helpers for DEFCON Defense.
#
# The library only invokes the Pager firmware's WIFI_PCAP_START/STOP receiver
# primitives. It never transmits frames, changes nearby networks, or starts an
# offensive capture workflow.

pcap_evidence_configure() {
  PCAP_EVIDENCE_DIR="${PCAP_EVIDENCE_DIR:-/root/loot/defcon_defense}"
  PCAP_EVIDENCE_PCAP_DIR="${PCAP_EVIDENCE_PCAP_DIR:-/root/loot/pcap}"
  PCAP_EVIDENCE_INDEX="${PCAP_EVIDENCE_INDEX:-$PCAP_EVIDENCE_DIR/pcap_index.tsv}"
  PCAP_EVIDENCE_STATE="${PCAP_EVIDENCE_STATE:-$PCAP_EVIDENCE_DIR/pcap_capture.psv}"
  PCAP_EVIDENCE_DEDUPE="${PCAP_EVIDENCE_DEDUPE:-$PCAP_EVIDENCE_DIR/pcap_dedupe.psv}"
  PCAP_EVIDENCE_LOCK="${PCAP_EVIDENCE_LOCK:-$PCAP_EVIDENCE_DIR/.pcap_capture.lock}"
  PCAP_EVIDENCE_DURATION="${PCAP_EVIDENCE_DURATION:-30}"
  PCAP_EVIDENCE_COOLDOWN="${PCAP_EVIDENCE_COOLDOWN:-300}"
  PCAP_EVIDENCE_MAX_BYTES="${PCAP_EVIDENCE_MAX_BYTES:-268435456}"
  PCAP_EVIDENCE_MIN_FREE_BYTES="${PCAP_EVIDENCE_MIN_FREE_BYTES:-67108864}"
  mkdir -p "$PCAP_EVIDENCE_DIR" "$PCAP_EVIDENCE_PCAP_DIR"
}

pcap_evidence_field() {
  local value="${1:-}"
  value="${value//$'\t'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  value="${value//|/ }"
  printf '%.128s' "$value"
}

pcap_evidence_tsv_append() { # output field...
  local output="$1" field separator=""
  shift
  {
    for field in "$@"; do
      printf '%s' "$separator"
      pcap_evidence_field "$field"
      separator=$'\t'
    done
    printf '\n'
  } >> "$output"
}

pcap_evidence_now() {
  date +%s
}

pcap_evidence_index_init() {
  pcap_evidence_configure
  if [ ! -s "$PCAP_EVIDENCE_INDEX" ]; then
    printf 'epoch\tid\tevent\tseverity\tssid\tbssid\tband\tchannel\tsignal_dbm\tduration_seconds\tsize_bytes\tsha256\tstatus\ttrigger\tpath\n' \
      > "$PCAP_EVIDENCE_INDEX"
  fi
}

pcap_evidence_total_bytes() {
  pcap_evidence_configure
  find "$PCAP_EVIDENCE_PCAP_DIR" -type f -exec wc -c {} \; 2>/dev/null \
    | awk '{total += $1} END {printf "%.0f", total+0}'
}

pcap_evidence_free_bytes() {
  pcap_evidence_configure
  df -k "$PCAP_EVIDENCE_PCAP_DIR" 2>/dev/null \
    | awk 'NR==2 {printf "%.0f", $4 * 1024; found=1} END {if (!found) print 0}'
}

pcap_evidence_human_bytes() {
  awk -v bytes="${1:-0}" 'BEGIN {
    if (bytes >= 1073741824) printf "%.1f GB", bytes/1073741824
    else if (bytes >= 1048576) printf "%.0f MB", bytes/1048576
    else if (bytes >= 1024) printf "%.0f KB", bytes/1024
    else printf "%d B", bytes
  }'
}

pcap_evidence_count() {
  pcap_evidence_import_existing
  awk -F '\t' 'NR>1 && $13 == "SAVED" {count++} END {print count+0}' "$PCAP_EVIDENCE_INDEX"
}

pcap_evidence_mtime() {
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || pcap_evidence_now
}

pcap_evidence_import_existing() {
  local active_path="" capture_status="" _state_id _state_epoch file clean_path epoch id size
  local token="${BASHPID:-$$}.${RANDOM:-0}" found missing
  pcap_evidence_index_init
  found="$PCAP_EVIDENCE_DIR/.pcap-found.$token"
  missing="$PCAP_EVIDENCE_DIR/.pcap-missing.$token"
  if [ -s "$PCAP_EVIDENCE_STATE" ]; then
    IFS='|' read -r capture_status _state_id _state_epoch active_path _ < "$PCAP_EVIDENCE_STATE" || true
  fi
  if [ "$capture_status" != "CAPTURING" ]; then
    active_path=""
  fi
  find "$PCAP_EVIDENCE_PCAP_DIR" -type f 2>/dev/null | sort > "$found" || {
    rm -f "$found" "$missing"
    return 1
  }
  # Build the unindexed list in one pass. The previous implementation started
  # one awk process per PCAP and became quadratic as evidence accumulated.
  awk -F '\t' -v index_file="$PCAP_EVIDENCE_INDEX" -v active="$active_path" '
    FILENAME == index_file {if (FNR > 1) indexed[$15]=1; next}
    $0 != active && !indexed[$0] {print}
  ' "$PCAP_EVIDENCE_INDEX" "$found" > "$missing" || {
    rm -f "$found" "$missing"
    return 1
  }
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    clean_path="$(pcap_evidence_field "$file")"
    epoch="$(pcap_evidence_mtime "$file")"
    id="legacy-${epoch}-$(basename "$file" | tr -c 'A-Za-z0-9._-' '_')"
    size="$(wc -c < "$file" | tr -d ' ')"
    printf '%s\t%s\tLEGACY_CAPTURE\tINFO\t<unknown>\t?\t?\t?\t?\t0\t%s\tpending\tSAVED\tlegacy\t%s\n' \
      "$epoch" "$(pcap_evidence_field "$id")" "$size" "$clean_path" \
      >> "$PCAP_EVIDENCE_INDEX"
  done < "$missing"
  rm -f "$found" "$missing"
}

pcap_evidence_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  else
    printf 'unavailable'
  fi
}

pcap_evidence_storage_ok() {
  local used free
  used="$(pcap_evidence_total_bytes)"
  free="$(pcap_evidence_free_bytes)"
  [ "${used:-0}" -lt "$PCAP_EVIDENCE_MAX_BYTES" ] 2>/dev/null || return 1
  # Some host test doubles do not expose df data. Treat zero as unknown rather
  # than as a full disk; the on-device build reports a real positive value.
  [ "${free:-0}" -eq 0 ] 2>/dev/null || \
    [ "$free" -gt "$PCAP_EVIDENCE_MIN_FREE_BYTES" ] 2>/dev/null
}

pcap_evidence_capture_active() {
  pcap_evidence_configure
  [ -d "$PCAP_EVIDENCE_LOCK" ] || return 1
  local pid=""
  [ -f "$PCAP_EVIDENCE_LOCK/pid" ] && pid="$(cat "$PCAP_EVIDENCE_LOCK/pid" 2>/dev/null)"
  if printf '%s' "$pid" | grep -Eq '^[0-9]+$' && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  rm -rf -- "$PCAP_EVIDENCE_LOCK"
  return 1
}

pcap_evidence_lock_acquire() {
  pcap_evidence_configure
  pcap_evidence_capture_active && return 1
  mkdir "$PCAP_EVIDENCE_LOCK" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$PCAP_EVIDENCE_LOCK/pid"
}

pcap_evidence_lock_release() {
  pcap_evidence_configure
  rm -rf -- "$PCAP_EVIDENCE_LOCK"
}

pcap_evidence_clear_all() {
  local capture_pid="" current_pid="${BASHPID:-$$}"
  pcap_evidence_configure

  if [ -f "$PCAP_EVIDENCE_LOCK/pid" ]; then
    capture_pid="$(cat "$PCAP_EVIDENCE_LOCK/pid" 2>/dev/null)"
  fi
  if pcap_evidence_capture_active; then
    type WIFI_PCAP_STOP >/dev/null 2>&1 && WIFI_PCAP_STOP >/dev/null 2>&1 || true
    if printf '%s' "$capture_pid" | grep -Eq '^[0-9]+$' && \
       [ "$capture_pid" != "$current_pid" ] && [ "$capture_pid" != "$$" ]; then
      kill "$capture_pid" 2>/dev/null || true
    fi
  fi

  pcap_evidence_lock_release
  find "$PCAP_EVIDENCE_PCAP_DIR" -type f -exec rm -f -- {} \; 2>/dev/null || true
  rm -f -- "$PCAP_EVIDENCE_INDEX" "$PCAP_EVIDENCE_STATE" "$PCAP_EVIDENCE_DEDUPE"
  pcap_evidence_index_init
}

pcap_evidence_dedupe_allowed() { # event bssid now
  local event bssid now row last
  pcap_evidence_configure
  event="$(pcap_evidence_field "$1")"
  bssid="$(pcap_evidence_field "$2" | tr 'a-f' 'A-F')"
  now="$3"
  row="$(awk -F '|' -v e="$event" -v b="$bssid" '$1==e && $2==b {print; exit}' \
    "$PCAP_EVIDENCE_DEDUPE" 2>/dev/null)"
  [ -n "$row" ] || return 0
  last="$(printf '%s' "$row" | cut -d '|' -f3)"
  [ $((now - ${last:-0})) -ge "$PCAP_EVIDENCE_COOLDOWN" ]
}

pcap_evidence_dedupe_mark() { # event bssid now
  local event bssid now tmp
  pcap_evidence_configure
  event="$(pcap_evidence_field "$1")"
  bssid="$(pcap_evidence_field "$2" | tr 'a-f' 'A-F')"
  now="$3"
  tmp="${PCAP_EVIDENCE_DEDUPE}.tmp.$$"
  {
    [ -f "$PCAP_EVIDENCE_DEDUPE" ] && \
      awk -F '|' -v e="$event" -v b="$bssid" '!($1==e && $2==b)' "$PCAP_EVIDENCE_DEDUPE"
    printf '%s|%s|%s\n' "$event" "$bssid" "$now"
  } > "$tmp" && mv -f "$tmp" "$PCAP_EVIDENCE_DEDUPE"
}

pcap_evidence_state_write() { # status id epoch path event severity ssid bssid band channel signal duration trigger
  pcap_evidence_configure
  local tmp="${PCAP_EVIDENCE_STATE}.tmp.${BASHPID:-$$}.${RANDOM:-0}" field separator=""
  {
    for field in "$@"; do
      printf '%s' "$separator"
      pcap_evidence_field "$field"
      separator='|'
    done
    printf '\n'
  } > "$tmp"
  mv -f "$tmp" "$PCAP_EVIDENCE_STATE"
}

pcap_evidence_state_status() {
  pcap_evidence_configure
  [ -s "$PCAP_EVIDENCE_STATE" ] || { echo "IDLE"; return; }
  local status _id epoch _path _event _severity _ssid _bssid _band _channel _signal duration _trigger
  local elapsed remaining
  IFS='|' read -r status _id epoch _path _event _severity _ssid _bssid _band _channel \
    _signal duration _trigger < "$PCAP_EVIDENCE_STATE" || true
  if [ "$status" = "CAPTURING" ]; then
    if ! pcap_evidence_capture_active; then
      echo "INTERRUPTED"
      return
    fi
    elapsed=$(( $(pcap_evidence_now) - ${epoch:-0} ))
    remaining=$(( ${duration:-0} - elapsed ))
    [ "$remaining" -lt 0 ] && remaining=0
    printf 'CAPTURING 00:%02d' "$remaining"
  else
    printf '%s' "$status"
  fi
}

pcap_evidence_state_for_bssid() { # bssid
  pcap_evidence_configure
  local wanted status state_bssid
  local _id _epoch _path _event _severity _ssid _band _channel _signal _duration _trigger
  wanted="$(pcap_evidence_field "$1" | tr 'a-f' 'A-F')"
  if [ -s "$PCAP_EVIDENCE_STATE" ]; then
    IFS='|' read -r status _id _epoch _path _event _severity _ssid state_bssid _band \
      _channel _signal _duration _trigger < "$PCAP_EVIDENCE_STATE" || true
    state_bssid="$(printf '%s' "$state_bssid" | tr 'a-f' 'A-F')"
    if [ -n "$wanted" ] && [ "$state_bssid" = "$wanted" ]; then
      pcap_evidence_state_status
      return
    fi
  fi
  if [ -s "$PCAP_EVIDENCE_INDEX" ] && awk -F '\t' -v b="$wanted" \
      'NR>1 && toupper($6)==b && $13=="SAVED" {found=1} END {exit !found}' \
      "$PCAP_EVIDENCE_INDEX"; then
    echo "EVIDENCE SAVED"
  else
    echo "NO PCAP YET"
  fi
}

pcap_evidence_begin() { # event severity ssid bssid band channel signal trigger dedupe duration
  local event severity ssid bssid band channel signal trigger dedupe duration now id path
  pcap_evidence_configure
  event="$1"; severity="$2"; ssid="$3"; bssid="$4"; band="$5"
  channel="$6"; signal="$7"; trigger="$8"; dedupe="${9:-0}"; duration="${10:-$PCAP_EVIDENCE_DURATION}"
  now="$(pcap_evidence_now)"

  type WIFI_PCAP_START >/dev/null 2>&1 || { echo "UNAVAILABLE|||"; return 1; }
  pcap_evidence_storage_ok || { echo "STORAGE_LIMIT|||"; return 1; }
  if [ "$dedupe" = "1" ] && ! pcap_evidence_dedupe_allowed "$event" "$bssid" "$now"; then
    echo "COOLDOWN|||"
    return 1
  fi
  pcap_evidence_lock_acquire || { echo "BUSY|||"; return 1; }

  path="$(WIFI_PCAP_START 2>/dev/null || true)"
  if [ -z "$path" ]; then
    pcap_evidence_lock_release
    echo "FAILED|||"
    return 1
  fi

  id="${now}-$$-${RANDOM:-0}"
  pcap_evidence_state_write "CAPTURING" "$id" "$now" "$path" "$event" "$severity" \
    "$ssid" "$bssid" "$band" "$channel" "$signal" "$duration" "$trigger"
  [ "$dedupe" = "1" ] && pcap_evidence_dedupe_mark "$event" "$bssid" "$now"
  printf 'CAPTURING|%s|%s|%s\n' "$id" "$path" "$now"
}

pcap_evidence_finish() { # id
  pcap_evidence_configure
  local wanted="$1" status id epoch path event severity ssid bssid band channel signal duration trigger
  local ended elapsed size sha saved_status
  [ -s "$PCAP_EVIDENCE_STATE" ] || { pcap_evidence_lock_release; return 1; }
  IFS='|' read -r status id epoch path event severity ssid bssid band channel signal duration trigger \
    < "$PCAP_EVIDENCE_STATE" || true
  [ "$status" = "CAPTURING" ] && [ "$id" = "$wanted" ] || return 1

  type WIFI_PCAP_STOP >/dev/null 2>&1 && WIFI_PCAP_STOP >/dev/null 2>&1 || true
  ended="$(pcap_evidence_now)"; elapsed=$((ended - ${epoch:-ended}))
  [ "$elapsed" -ge 0 ] 2>/dev/null || elapsed="${duration:-0}"
  if [ -f "$path" ]; then size="$(wc -c < "$path" | tr -d ' ')"; else size=0; fi
  if [ "$size" -gt 0 ] 2>/dev/null; then
    # Digesting a large capture synchronously can freeze the Pager UI for tens
    # of seconds. Record it immediately and let the operator verify SHA-256 on
    # demand from the evidence detail actions.
    saved_status="SAVED"; sha="pending"
  else
    saved_status="EMPTY"; sha="unavailable"
  fi

  pcap_evidence_index_init
  pcap_evidence_tsv_append "$PCAP_EVIDENCE_INDEX" "$epoch" "$id" "$event" "$severity" \
    "$ssid" "$bssid" "$band" "$channel" "$signal" "$elapsed" "$size" "$sha" \
    "$saved_status" "$trigger" "$path"
  pcap_evidence_state_write "$saved_status" "$id" "$epoch" "$path" "$event" "$severity" \
    "$ssid" "$bssid" "$band" "$channel" "$signal" "$elapsed" "$trigger"
  pcap_evidence_lock_release
  printf '%s|%s|%s\n' "$saved_status" "$path" "$size"
}

pcap_evidence_bounded_start() { # event severity ssid bssid band channel signal trigger dedupe duration
  local event="$1" severity="$2" ssid="$3" bssid="$4" band="$5" channel="$6" signal="$7"
  local trigger="${8:-automatic}" dedupe="${9:-1}" duration="${10:-$PCAP_EVIDENCE_DURATION}"
  local result status id path epoch worker_pid
  result="$(pcap_evidence_begin "$event" "$severity" "$ssid" "$bssid" "$band" "$channel" "$signal" \
    "$trigger" "$dedupe" "$duration")"
  status="${result%%|*}"
  if [ "$status" = "CAPTURING" ]; then
    IFS='|' read -r status id path epoch <<< "$result"
    (
      local worker_started worker_used worker_free worker_initial capture_size projected_used ticks=0
      worker_started=$SECONDS
      worker_used="$(pcap_evidence_total_bytes)"
      worker_initial="$(wc -c < "$path" 2>/dev/null)"
      while [ $((SECONDS - worker_started)) -lt "$duration" ]; do
        sleep 1
        capture_size="$(wc -c < "$path" 2>/dev/null)"
        projected_used=$(( ${worker_used:-0} - ${worker_initial:-0} + ${capture_size:-0} ))
        [ "$projected_used" -lt "$PCAP_EVIDENCE_MAX_BYTES" ] 2>/dev/null || break
        ticks=$((ticks + 1))
        if [ $((ticks % 5)) -eq 0 ]; then
          worker_free="$(pcap_evidence_free_bytes)"
          if [ "${worker_free:-0}" -gt 0 ] 2>/dev/null && \
             [ "$worker_free" -le "$PCAP_EVIDENCE_MIN_FREE_BYTES" ] 2>/dev/null; then
            break
          fi
        fi
      done
      pcap_evidence_finish "$id" >/dev/null 2>&1 || true
    ) >/dev/null 2>&1 &
    worker_pid=$!
    printf '%s\n' "$worker_pid" > "$PCAP_EVIDENCE_LOCK/pid"
    printf 'CAPTURING|%s|%s|%s\n' "$id" "$path" "$epoch"
  else
    printf '%s\n' "$result"
    return 1
  fi
}

pcap_evidence_auto_start() { # event severity ssid bssid band channel signal
  pcap_evidence_bounded_start "$1" "$2" "$3" "$4" "$5" "$6" "$7" \
    "automatic" 1 "$PCAP_EVIDENCE_DURATION"
}

pcap_evidence_manual_start() { # event severity ssid bssid band channel signal
  pcap_evidence_begin "$1" "$2" "$3" "$4" "$5" "$6" "$7" \
    "manual" 0 3600
}
