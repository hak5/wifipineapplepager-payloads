#!/bin/bash
# Passive RF inventory and classification helpers for DEFCON_DEFENSE.
# This library only parses PineAP Recon results and local state files. It does
# not transmit frames or alter nearby networks.

rf_sanitize_mac() {
  printf '%s' "${1:-}" | tr -d ' \t\n\r' | tr 'a-f' 'A-F'
}

rf_band_for() { # frequency_mhz channel
  local freq="${1:-0}" channel="${2:-0}"
  awk -v f="$freq" -v c="$channel" 'BEGIN {
    f += 0; c += 0
    if ((f >= 2400 && f < 2500) || (f == 0 && c >= 1 && c <= 14)) print "2.4GHz"
    else if ((f >= 4900 && f < 5900) || (f == 0 && c >= 15 && c <= 196)) print "5GHz"
    else print "other"
  }'
}

rf_normalize_json() { # recon_json snapshot_tsv
  local input="$1" output="$2"
  local tmp="${2}.tmp.${BASHPID:-$$}.${RANDOM:-0}"
  jq -e 'type == "array"' "$input" >/dev/null 2>&1 || return 1
  jq -r '
    def text_or($fallback): if . == null or . == "" then $fallback else tostring end;
    # The Pager firmware builds jq without its optional regex engine, so MAC
    # validation must use character codes instead of test()/match().
    def hex_pair:
      length == 2 and
      (explode | all((. >= 48 and . <= 57) or (. >= 65 and . <= 70)));
    def mac_address:
      split(":") as $parts
      | ($parts | length) == 6 and ($parts | all(hex_pair));
    def band($freq; $channel):
      (($freq | tonumber?) // 0) as $f
      | (($channel | tonumber?) // 0) as $c
      | if (($f >= 2400 and $f < 2500) or ($f == 0 and $c >= 1 and $c <= 14)) then "2.4GHz"
        elif (($f >= 4900 and $f < 5900) or ($f == 0 and $c >= 15 and $c <= 196)) then "5GHz"
        else "other" end;
    [
      .[]? as $ap
      | (($ap.beacon // [])[]?, ($ap.response // [])[]?)
      | {
          bssid: (($ap.mac // "") | tostring | ascii_upcase),
          ssid: (.ssid | text_or("<hidden>")),
          channel: (.channel | text_or("?")),
          freq: (.freq | text_or("?")),
          signal: (.signal | text_or("?")),
          time: (.time | text_or("?")),
          packets: ($ap.packets | text_or("0"))
        }
      | select(.bssid | mac_address)
      | . + {band: band(.freq; .channel)}
    ]
    # Recon may report both a hidden beacon and a named probe response for the
    # same radio. Keep one best live row per BSSID, preferring a visible SSID,
    # stronger signal, and newer observation.
    | group_by(.bssid)
    | map(sort_by([
        (if .ssid == "<hidden>" then 0 else 1 end),
        ((.signal | tonumber?) // -999),
        ((.time | tonumber?) // 0)
      ]) | last)
    | sort_by(((.signal | tonumber?) // -999))
    | reverse
    | .[]
    | [.bssid, .ssid, .channel, .freq, .signal, .time, .packets, .band]
    | @tsv
  ' "$input" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$output"
}

rf_watch_contains() { # watched_tsv bssid
  local watched="$1" bssid
  bssid="$(rf_sanitize_mac "$2")"
  [ -f "$watched" ] || return 1
  awk -F '\t' -v b="$bssid" '$1 == b {found=1; exit} END {exit !found}' "$watched"
}

rf_watch_count() { # watched_tsv
  [ -f "$1" ] || { echo 0; return; }
  awk -F '\t' '$1 ~ /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/ {count++} END {print count+0}' "$1"
}

rf_watch_upsert() { # watched_tsv bssid ssid channel band
  local watched="$1" bssid ssid channel band tmp
  bssid="$(rf_sanitize_mac "$2")"
  ssid="$(rf_clean_field "$3")"
  channel="$(rf_clean_field "$4")"
  band="$(rf_clean_field "$5")"
  printf '%s' "$bssid" | awk 'BEGIN {ok=0} /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/ {ok=1} END {exit !ok}' || return 1
  mkdir -p "$(dirname "$watched")"
  tmp="${watched}.tmp.$$"
  {
    [ -f "$watched" ] && awk -F '\t' -v b="$bssid" '$1 != b' "$watched"
    printf '%s\t%s\t%s\t%s\n' "$bssid" "$ssid" "$channel" "$band"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  sort -t "$(printf '\t')" -k2,2 -k1,1 "$tmp" > "${tmp}.sorted" || {
    rm -f "$tmp" "${tmp}.sorted"
    return 1
  }
  mv -f "${tmp}.sorted" "$watched"
  rm -f "$tmp"
}

rf_watch_remove() { # watched_tsv bssid
  local watched="$1" bssid tmp
  bssid="$(rf_sanitize_mac "$2")"
  [ -f "$watched" ] || return 0
  tmp="${watched}.tmp.$$"
  awk -F '\t' -v b="$bssid" '$1 != b' "$watched" > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$watched"
}

rf_watch_classify() { # watched_tsv bssid ssid channel
  local watched="$1" bssid ssid="$3" channel="$4" exact
  local expected_ssid expected_channel _band
  bssid="$(rf_sanitize_mac "$2")"
  [ -f "$watched" ] || { echo "NONE"; return; }

  exact="$(awk -F '\t' -v b="$bssid" '$1 == b {print; exit}' "$watched")"
  if [ -n "$exact" ]; then
    IFS=$'\t' read -r _ expected_ssid expected_channel _band <<< "$exact"
    if [ "$ssid" != "<hidden>" ] && [ "$expected_ssid" != "<hidden>" ] && \
       [ -n "$expected_ssid" ] && [ "$ssid" != "$expected_ssid" ]; then
      echo "WATCHED_BSSID_SSID_CHANGE"
    elif [ -n "$expected_channel" ] && [ "$expected_channel" != "?" ] && \
         [ "$channel" != "$expected_channel" ]; then
      echo "WATCHED_AP_CHANNEL_CHANGE"
    else
      echo "NONE"
    fi
  elif [ "$ssid" != "<hidden>" ] && awk -F '\t' -v s="$ssid" \
      '$2 == s && $2 != "<hidden>" {found=1; exit} END {exit !found}' "$watched"; then
    echo "WATCHED_SSID_NEW_BSSID"
  else
    echo "NONE"
  fi
}

rf_observation_is_actionable() { # seen_epoch now_epoch max_age session_start_epoch
  local seen="${1:-}" now="${2:-0}" max_age="${3:-0}" session_start="${4:-0}"
  # Tests and callers that explicitly disable both guards retain the historical
  # classification behavior. The Pager runtime always supplies both guards.
  if [ "${max_age:-0}" -le 0 ] 2>/dev/null && [ "${session_start:-0}" -le 0 ] 2>/dev/null; then
    return 0
  fi
  case "$seen:$now:$max_age:$session_start" in
    *[!0-9:]*) return 1 ;;
  esac
  # A five-second future allowance tolerates a Recon/API write racing the
  # local date read, while rejecting invalid clocks and cached observations.
  if [ "$max_age" -gt 0 ] 2>/dev/null; then
    [ $((now - seen)) -le "$max_age" ] && [ $((seen - now)) -le 5 ] || return 1
  fi
  # A payload restart must not replay a row that PineAP learned before this
  # monitoring session. A still-present transmitter will receive a newer
  # Recon timestamp and become actionable during the next scan cycle.
  [ "$session_start" -le 0 ] 2>/dev/null || [ "$seen" -gt "$session_start" ]
}

rf_build_threat_snapshot() { # watched trusted baseline snapshot deauth_events now output [max_age] [session_start]
  local watched="$1" trusted="$2" baseline="$3" snapshot="$4"
  local deauth="$5" now="$6" output="$7"
  local tmp="${7}.tmp.${BASHPID:-$$}.${RANDOM:-0}"
  local max_age="${8:-0}" session_start="${9:-0}"
  local watched_in="$watched" trusted_in="$trusted" baseline_in="$baseline" deauth_in="$deauth"
  [ -f "$watched_in" ] || watched_in=/dev/null
  [ -f "$trusted_in" ] || trusted_in=/dev/null
  [ -f "$baseline_in" ] || baseline_in=/dev/null
  [ -f "$deauth_in" ] || deauth_in=/dev/null
  [ -f "$snapshot" ] || return 1

  awk -v watched="$watched_in" -v trusted="$trusted_in" -v baseline="$baseline_in" \
      -v deauth="$deauth_in" -v snapshot="$snapshot" -v now="$now" \
      -v cutoff="$((now - 120))" -v max_age="$max_age" -v session_start="$session_start" '
    BEGIN {FS="\t"; OFS="\t"}
    function channel_ok(spec, channel, values, n, i) {
      gsub(/[ \r]/, "", spec)
      if (spec == "" || spec == "*") return 1
      n=split(spec, values, ",")
      for (i=1; i<=n; i++) if (values[i] == channel) return 1
      return 0
    }
    FILENAME == watched {
      split($0, a, "\t"); b=toupper(a[1])
      if (b != "") {wssid[b]=a[2]; wchan[b]=a[3]; if (a[2] != "<hidden>") watched_ssid[a[2]]=1}
      next
    }
    FILENAME == trusted {
      if ($0 ~ /^[ \t]*#/ || $0 ~ /^[ \t]*$/) next
      split($0, a, "|"); b=toupper(a[2]); gsub(/[ \t\r]/, "", b)
      key=a[1] SUBSEP b; trusted_pair[key]=1; trusted_channels[key]=a[3]
      trusted_ssid[a[1]]=1; trusted_bssid[b]=1
      next
    }
    FILENAME == baseline {
      b=toupper($0); gsub(/[ \t\r]/, "", b)
      if (b != "") {baseline_bssid[b]=1; baseline_rows++}
      next
    }
    FILENAME == deauth {
      split($0, a, ",")
      if ((a[1] + 0) >= cutoff) {
        split(a[4], pair, "="); b=toupper(pair[2]); if (b != "") deauth_count[b]++
      }
      next
    }
    FILENAME == snapshot {
      if ($8 != "2.4GHz" && $8 != "5GHz") next
      seen=$6+0
      if (max_age > 0 && ($6 !~ /^[0-9]+$/ || seen < now-max_age || seen > now+5)) next
      if (session_start > 0 && ($6 !~ /^[0-9]+$/ || seen <= session_start)) next
      b=toupper($1); ssid=$2; channel=$3; event="NONE"; color="red"
      if (deauth_count[b] > 0) event="DEAUTH_ACTIVITY"
      else if (b in wssid) {
        if (ssid != "<hidden>" && wssid[b] != "<hidden>" && wssid[b] != "" && ssid != wssid[b])
          event="WATCHED_BSSID_SSID_CHANGE"
        else if (wchan[b] != "" && wchan[b] != "?" && channel != wchan[b])
          event="WATCHED_AP_CHANNEL_CHANGE"
      }
      else if (ssid != "<hidden>" && (ssid in watched_ssid)) event="WATCHED_SSID_NEW_BSSID"
      else if ((ssid SUBSEP b) in trusted_pair) {
        key=ssid SUBSEP b
        if (!channel_ok(trusted_channels[key], channel)) event="TRUSTED_AP_CHANNEL_CHANGE"
      }
      else if (ssid in trusted_ssid) event="TRUSTED_SSID_NEW_BSSID"
      else if (b in trusted_bssid) event="TRUSTED_BSSID_SSID_CHANGE"
      else if (baseline_rows > 0 && !(b in baseline_bssid)) {event="NEW_BSSID"; color="yellow"}

      if (event != "NONE") print b, ssid, channel, $8, $5, $7, event, deauth_count[b]+0, color, $4
    }
  ' "$watched_in" "$trusted_in" "$baseline_in" "$deauth_in" "$snapshot" > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$output"
}

rf_write_baseline() { # snapshot_tsv baseline_bssids
  local snapshot="$1" baseline="$2" tmp="${2}.tmp.$$"
  mkdir -p "$(dirname "$baseline")"
  awk -F '\t' '$1 ~ /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/ {print $1}' "$snapshot" \
    | sort -u > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$baseline"
}

rf_baseline_contains() { # baseline bssid
  local baseline="$1" bssid
  bssid="$(rf_sanitize_mac "$2")"
  [ -f "$baseline" ] || return 1
  awk -v b="$bssid" '$0 == b {found=1; exit} END {exit !found}' "$baseline"
}

rf_trusted_ssid() { # trusted_conf ssid
  local trusted="$1" ssid="$2"
  [ -f "$trusted" ] || return 1
  awk -F '|' -v s="$ssid" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    $1 == s {found=1; exit}
    END {exit !found}
  ' "$trusted"
}

rf_trusted_bssid() { # trusted_conf bssid
  local trusted="$1" bssid
  bssid="$(rf_sanitize_mac "$2")"
  [ -f "$trusted" ] || return 1
  awk -F '|' -v b="$bssid" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    {gsub(/[ \t\r]/, "", $2); bssid=toupper($2)}
    bssid == b {found=1; exit}
    END {exit !found}
  ' "$trusted"
}

rf_trusted_pair() { # trusted_conf ssid bssid
  local trusted="$1" ssid="$2" bssid
  bssid="$(rf_sanitize_mac "$3")"
  [ -f "$trusted" ] || return 1
  awk -F '|' -v s="$ssid" -v b="$bssid" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    {gsub(/[ \t\r]/, "", $2); bssid=toupper($2)}
    $1 == s && bssid == b {found=1; exit}
    END {exit !found}
  ' "$trusted"
}

rf_channel_allowed() { # trusted_conf ssid bssid channel
  local trusted="$1" ssid="$2" bssid channel="$4"
  bssid="$(rf_sanitize_mac "$3")"
  [ -f "$trusted" ] || return 1
  awk -F '|' -v s="$ssid" -v b="$bssid" -v c="$channel" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
    {
      gsub(/[ \t\r]/, "", $2); row_bssid=toupper($2)
      if ($1 != s || row_bssid != b) next
      channels=$3; gsub(/[ \t\r]/, "", channels)
      if (channels == "" || channels == "*") {allowed=1; exit}
      n=split(channels, values, ",")
      for (i=1; i<=n; i++) if (values[i] == c) {allowed=1; exit}
    }
    END {exit !allowed}
  ' "$trusted"
}

rf_classify_observation() { # trusted baseline bssid ssid channel
  local trusted="$1" baseline="$2" bssid ssid="$4" channel="$5"
  bssid="$(rf_sanitize_mac "$3")"

  if rf_trusted_pair "$trusted" "$ssid" "$bssid"; then
    if rf_channel_allowed "$trusted" "$ssid" "$bssid" "$channel"; then
      echo "NONE"
    else
      echo "TRUSTED_AP_CHANNEL_CHANGE"
    fi
  elif rf_trusted_ssid "$trusted" "$ssid"; then
    echo "TRUSTED_SSID_NEW_BSSID"
  elif rf_trusted_bssid "$trusted" "$bssid"; then
    echo "TRUSTED_BSSID_SSID_CHANGE"
  elif [ -s "$baseline" ] && ! rf_baseline_contains "$baseline" "$bssid"; then
    echo "NEW_BSSID"
  else
    echo "NONE"
  fi
}

rf_signal_meets_threshold() { # signal_dbm minimum_dbm
  awk -v s="${1:-}" -v m="${2:--72}" 'BEGIN {
    if (s !~ /^-?[0-9]+([.][0-9]+)?$/) exit 0
    exit !(s + 0 >= m + 0)
  }'
}

rf_state_should_alert() { # state event bssid now threshold window cooldown
  local state="$1" event="$2" bssid="$3" now="$4"
  local threshold="$5" window="$6" cooldown="$7"
  local row count first last last_alert tmp alert=0
  bssid="$(rf_sanitize_mac "$bssid")"
  mkdir -p "$(dirname "$state")"
  row="$(awk -F '|' -v e="$event" -v b="$bssid" '$1==e && $2==b {print; exit}' "$state" 2>/dev/null)"
  if [ -n "$row" ]; then
    IFS='|' read -r _ _ count first last last_alert <<< "$row"
  else
    count=0; first="$now"; last=0; last_alert=0
  fi
  if [ $((now - last)) -gt "$window" ]; then count=0; first="$now"; fi
  count=$((count + 1)); last="$now"
  if [ "$count" -ge "$threshold" ] && \
     { [ "$last_alert" -eq 0 ] || [ $((now - last_alert)) -ge "$cooldown" ]; }; then
    alert=1; last_alert="$now"
  fi

  tmp="${state}.tmp.$$"
  { [ -f "$state" ] && awk -F '|' -v e="$event" -v b="$bssid" '!($1==e && $2==b)' "$state"
    printf '%s|%s|%s|%s|%s|%s\n' "$event" "$bssid" "$count" "$first" "$last" "$last_alert"
  } > "$tmp" && mv -f "$tmp" "$state"
  echo "$alert"
}

rf_count_band() { # snapshot_tsv band
  awk -F '\t' -v b="$2" '$8 == b && !seen[$1]++ {count++} END {print count+0}' "$1"
}

rf_ui_metrics() { # snapshot_tsv threats_tsv watched_tsv -> 2.4|5|threats|watched
  local snapshot="$1" threats="$2" watched="$3"
  local snapshot_in="$snapshot" threats_in="$threats" watched_in="$watched"
  [ -f "$snapshot_in" ] || snapshot_in=/dev/null
  [ -f "$threats_in" ] || threats_in=/dev/null
  [ -f "$watched_in" ] || watched_in=/dev/null
  awk -F '\t' -v snapshot="$snapshot_in" -v threats="$threats_in" -v watched="$watched_in" '
    FILENAME == snapshot {
      if (($8 == "2.4GHz" || $8 == "5GHz") && !aps[$8 SUBSEP $1]++) bands[$8]++
      next
    }
    FILENAME == threats {if (NF >= 9 && $1 != "") threat_count++; next}
    FILENAME == watched {
      b=toupper($1)
      if (b ~ /^([0-9A-F][0-9A-F]:){5}[0-9A-F][0-9A-F]$/) watched_count++
    }
    END {print bands["2.4GHz"]+0 "|" bands["5GHz"]+0 "|" threat_count+0 "|" watched_count+0}
  ' "$snapshot_in" "$threats_in" "$watched_in"
}

rf_count_config_rows() { # pipe-delimited config
  [ -f "$1" ] || { echo 0; return; }
  awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/ {count++} END {print count+0}' "$1"
}

rf_clean_field() {
  local value="${1:-}"
  value="${value//$'\t'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  printf '%.96s' "$value"
}

rf_append_finding() { # file epoch type bssid ssid channel freq signal band
  local file="$1"; shift
  mkdir -p "$(dirname "$file")"
  if [ ! -s "$file" ]; then
    printf 'epoch\ttype\tbssid\tssid\tchannel\tfrequency_mhz\tsignal_dbm\tband\n' > "$file"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(rf_clean_field "$1")" "$(rf_clean_field "$2")" "$(rf_clean_field "$3")" \
    "$(rf_clean_field "$4")" "$(rf_clean_field "$5")" "$(rf_clean_field "$6")" \
    "$(rf_clean_field "$7")" "$(rf_clean_field "$8")" >> "$file"
}
