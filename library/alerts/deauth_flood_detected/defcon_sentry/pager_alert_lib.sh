#!/bin/bash
# Shared alert library for the DEFCON Pager defensive handlers.
# Sourced by each handler's payload.sh on-device and by the host test harness.
# Side effects go through ALERT/RINGTONE/VIBRATE/LED/LOG, which are real
# DuckyScript commands on-device and recorder stubs in tests.

# Epoch seconds, overridable for deterministic tests.
now_epoch() { echo "${NOW_OVERRIDE:-$(date +%s)}"; }

# Uppercase, strip all whitespace; keep colons.
# NOTE: delete explicit whitespace chars, NOT the [:space:] class — BusyBox tr
# treats "[:space:]" as a literal set (which includes ':') and would strip the
# colons out of MAC addresses.
sanitize_mac() {
  printf '%s' "${1:-}" | tr -d ' \t\n\r' | tr 'a-f' 'A-F'
}

# Exit 0 when MAC looks randomized (locally administered + unicast):
# second hex nibble is one of 2,6,A,E.
is_randomized_mac() {
  local mac; mac="$(sanitize_mac "${1:-}")"
  [ "${#mac}" -ge 2 ] || return 1
  case "${mac:1:1}" in
    2|6|A|E) return 0 ;;
    *) return 1 ;;
  esac
}

# --- state store (CSV: key,count,window_start,last_alert,last_seen) ---

state_read_row() { # file key
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -F, -v k="$key" '$1==k{print; exit}' "$file"
}

state_upsert_row() { # file key count window_start last_alert last_seen
  local file="$1" key="$2" count="$3" ws="$4" la="$5" ls="$6"
  local tmp="${file}.tmp.$$"
  mkdir -p "$(dirname "$file")"
  { [ -f "$file" ] && awk -F, -v k="$key" '$1!=k' "$file"
    printf '%s,%s,%s,%s,%s\n' "$key" "$count" "$ws" "$la" "$ls"
  } > "$tmp"
  mv -f "$tmp" "$file"
}

state_prune() { # file max_age now
  local file="$1" max_age="$2" now="$3"
  [ -f "$file" ] || return 0
  local cutoff=$((now - max_age)) tmp="${file}.tmp.$$"
  awk -F, -v c="$cutoff" '$5>=c' "$file" > "$tmp" && mv -f "$tmp" "$file"
}

with_lock() { # lockfile cmd...
  local lockfile="$1"; shift
  { exec 9>"$lockfile"; } 2>/dev/null || { "$@"; return $?; }
  # Blocking exclusive lock. Uses only flags common to BusyBox flock (which has
  # no -w timeout) and util-linux flock. flock auto-releases when the holder's
  # fd closes (e.g. the process dies), so blocking on this tiny critical section
  # cannot hang indefinitely. On hosts without flock (e.g. macOS) it's a no-op.
  command -v flock >/dev/null 2>&1 && flock -x 9 2>/dev/null || true
  "$@"; local rc=$?
  flock -u 9 2>/dev/null
  exec 9>&-
  return $rc
}

# --- loud alert wrapper (uses config env: LED_STATE, RINGTONE_NAME) ---
# On the Pager, `RINGTONE --vibrate <name>` plays a saved ringtone AND buzzes the
# motor in sync — one call for audible + tactile. (Bare `VIBRATE 300 100 ...`
# millisecond args are NOT valid on this firmware; VIBRATE also wants an
# rtttl/name.) For a discreet vibrate-only alert, set RINGTONE_VIBRATE_ONLY=1.
alert_fire() { # message
  local msg="${1:-}"
  LED "${LED_STATE:-ATTACK}" 2>/dev/null || true
  if [ -n "${RINGTONE_VIBRATE_ONLY:-}" ]; then
    VIBRATE "${RINGTONE_NAME:-urgent}" >/dev/null 2>&1 &
  else
    RINGTONE --vibrate "${RINGTONE_NAME:-urgent}" >/dev/null 2>&1 &
  fi
  ALERT "$msg" || true
  LOG "$msg" || true
  return 0
}

# --- deauth repeat-offense engine ---

# Print 1 if any WATCH_MACS entry appears in the event (any field), else 0.
# Runs in a command-substitution subshell, so its IFS twiddling never leaks.
_sentry_targeted() { # src dst ap cli
  local src="$1" dst="$2" ap="$3" cli="$4"
  [ -n "${WATCH_MACS:-}" ] || { echo 0; return; }
  local m oldifs found=0
  oldifs="$IFS"; IFS=','
  for m in $WATCH_MACS; do
    IFS="$oldifs"
    m="$(sanitize_mac "$m")"; [ -z "$m" ] && continue
    if [ "$m" = "$src" ] || [ "$m" = "$dst" ] || [ "$m" = "$ap" ] || [ "$m" = "$cli" ]; then
      found=1; break
    fi
  done
  IFS="$oldifs"
  echo "$found"
}

sentry_process_event() {
  local now; now="$(now_epoch)"
  local state_dir="${STATE_DIR:-/root/loot/defcon_sentry}"
  local state_file="$state_dir/deauth_state.csv"
  local lock="$state_dir/.deauth.lock"
  mkdir -p "$state_dir"

  local src dst ap cli
  src="$(sanitize_mac "${_ALERT_DENIAL_SOURCE_MAC_ADDRESS:-}")"
  dst="$(sanitize_mac "${_ALERT_DENIAL_DESTINATION_MAC_ADDRESS:-}")"
  ap="$(sanitize_mac "${_ALERT_DENIAL_AP_MAC_ADDRESS:-}")"
  cli="$(sanitize_mac "${_ALERT_DENIAL_CLIENT_MAC_ADDRESS:-}")"

  printf '%s,src=%s,dst=%s,ap=%s,cli=%s\n' "$now" "$src" "$dst" "$ap" "$cli" \
    >> "$state_dir/events.log"

  # Targeting is independent of KEY_MODE and must survive the degenerate-key
  # guard below, so a watched MAC always alerts.
  local targeted; targeted="$(_sentry_targeted "$src" "$dst" "$ap" "$cli")"

  local key
  case "${KEY_MODE:-source_ap}" in
    source)        key="$src" ;;
    source_client) key="${src}|${cli}" ;;
    *)             key="${src}|${ap}" ;;
  esac
  # Drop only fully-unusable events that are NOT targeting a watched MAC.
  case "$key" in
    ""|"|")
      [ "$targeted" = "1" ] || return 0
      key="watched"
      ;;
  esac

  SENTRY_PENDING_ALERT=""
  with_lock "$lock" _sentry_update "$now" "$state_file" "$key" "$src" "$dst" "$ap" "$cli" "$targeted"
  # Start a short, passive evidence capture immediately after a confirmed red
  # alert. The shared helper supplies cross-process locking, cooldown, and
  # storage guards. Alert delivery never depends on capture availability.
  if [ -n "$SENTRY_PENDING_ALERT" ]; then
    local capture_result="UNAVAILABLE|||" capture_status capture_note
    local capture_ssid="<unknown>" capture_band="?" capture_channel="?" capture_signal="?"
    local recon_snapshot="${DEFCON_DEFENSE_SNAPSHOT:-/root/loot/defcon_defense/latest_snapshot.tsv}"
    local recon_row=""
    if [ -n "$ap" ] && [ -f "$recon_snapshot" ]; then
      recon_row="$(awk -F '\t' -v wanted="$ap" 'toupper($1)==wanted {print; exit}' "$recon_snapshot")"
      if [ -n "$recon_row" ]; then
        capture_ssid="$(printf '%s' "$recon_row" | cut -f2)"
        capture_channel="$(printf '%s' "$recon_row" | cut -f3)"
        capture_signal="$(printf '%s' "$recon_row" | cut -f5)"
        capture_band="$(printf '%s' "$recon_row" | cut -f8)"
      fi
    fi
    if type pcap_evidence_auto_start >/dev/null 2>&1; then
      capture_result="$(pcap_evidence_auto_start "DEAUTH_ACTIVITY" "HIGH" \
        "$capture_ssid" "$ap" "$capture_band" "$capture_channel" "$capture_signal" \
        2>/dev/null || true)"
    fi
    capture_status="${capture_result%%|*}"
    case "$capture_status" in
      CAPTURING) capture_note="PCAP: CAPTURING 00:${PCAP_EVIDENCE_DURATION:-30}" ;;
      BUSY) capture_note="PCAP: another evidence capture is active" ;;
      COOLDOWN) capture_note="PCAP: recent matching evidence already saved" ;;
      STORAGE_LIMIT) capture_note="PCAP: skipped by storage safety reserve" ;;
      *) capture_note="PCAP: unavailable; event log preserved" ;;
    esac
    alert_fire "$SENTRY_PENDING_ALERT
$capture_note"
  fi
  return 0
}

_sentry_update() { # now state_file key src dst ap cli targeted
  local now="$1" state_file="$2" key="$3" src="$4" dst="$5" ap="$6" cli="$7" targeted="${8:-0}"
  local threshold="${REPEAT_THRESHOLD:-3}" window="${WINDOW_SECONDS:-120}" cooldown="${COOLDOWN_SECONDS:-300}"

  state_prune "$state_file" 3600 "$now"

  local row count ws la
  row="$(state_read_row "$state_file" "$key")"
  if [ -n "$row" ]; then
    count="$(printf '%s' "$row" | cut -d, -f2)"
    ws="$(printf '%s' "$row" | cut -d, -f3)"
    la="$(printf '%s' "$row" | cut -d, -f4)"
  else
    count=0; ws="$now"; la=0
  fi
  if [ $((now - ws)) -gt "$window" ]; then count=0; ws="$now"; fi
  count=$((count + 1))

  local cooled=0; [ $((now - la)) -ge "$cooldown" ] && cooled=1
  if [ "$cooled" -eq 1 ] && { [ "$targeted" = "1" ] || [ "$count" -ge "$threshold" ]; }; then
    la="$now"
    local tag="REPEATED DEAUTH FLOOD"; [ "$targeted" = "1" ] && tag="TARGETED DEAUTH (watched MAC)"
    local when; when="$(date -d "@$now" 2>/dev/null || echo "epoch $now")"
    SENTRY_PENDING_ALERT="$tag
Attacker: ${src:-?}
AP/BSSID: ${ap:-?}
Client:   ${cli:-?}
Hits:     ${count} in <=${window}s
Time:     ${when}"
  fi

  state_upsert_row "$state_file" "$key" "$count" "$ws" "$la" "$now"
}

# --- honeypot connect warning (dedup per client MAC) ---

honeypot_process_event() {
  local now; now="$(now_epoch)"
  local state_dir="${STATE_DIR:-/root/loot/defcon_sentry}"
  local state_file="$state_dir/honeypot_state.csv"
  local lock="$state_dir/.hp.lock"
  mkdir -p "$state_dir"

  local cli ap ssid
  cli="$(sanitize_mac "${_ALERT_CLIENT_CONNECTED_CLIENT_MAC_ADDRESS:-}")"
  ap="$(sanitize_mac "${_ALERT_CLIENT_CONNECTED_AP_MAC_ADDRESS:-}")"
  ssid="${_ALERT_CLIENT_CONNECTED_SSID:-}"
  [ -n "$cli" ] || return 0

  local rnd=no; is_randomized_mac "$cli" && rnd=yes
  printf '%s,%s,%s,%s,%s\n' "$now" "$cli" "$ap" "$ssid" "$rnd" >> "$state_dir/honeypot.csv"

  HONEYPOT_PENDING_ALERT=""
  with_lock "$lock" _honeypot_update "$now" "$state_file" "$cli" "$ap" "$ssid" "$rnd"
  # fire the (possibly blocking) alert AFTER the lock releases
  [ -n "$HONEYPOT_PENDING_ALERT" ] && alert_fire "$HONEYPOT_PENDING_ALERT"
  return 0
}

_honeypot_update() { # now state_file cli ap ssid rnd
  local now="$1" state_file="$2" cli="$3" ap="$4" ssid="$5" rnd="$6"
  local cooldown="${COOLDOWN_SECONDS:-600}"
  state_prune "$state_file" 86400 "$now"

  local row count la
  row="$(state_read_row "$state_file" "$cli")"
  if [ -n "$row" ]; then
    count="$(printf '%s' "$row" | cut -d, -f2)"
    la="$(printf '%s' "$row" | cut -d, -f4)"
  else
    count=0; la=0
  fi
  count=$((count + 1))

  if [ "$count" -eq 1 ] || [ $((now - la)) -ge "$cooldown" ]; then
    la="$now"
    local note=""; [ "$rnd" = "yes" ] && note="
(randomized MAC)"
    HONEYPOT_PENDING_ALERT="HONEYPOT: client joined decoy AP
Client: ${cli}${note}
SSID:   ${ssid:-?}
AP:     ${ap:-?}
Seen:   ${count}x"
  fi
  state_upsert_row "$state_file" "$cli" "$count" "$now" "$la" "$now"
}
