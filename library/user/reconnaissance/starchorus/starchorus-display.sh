#!/bin/sh
#
# Title:        Starchorus -- on-device dashboard (passive)
# Description:  Reads the starchorus.json the collector already wrote and shows it on the
#               device's 480x222 screen: a summary (counts, band split, freshness,
#               crowding), the strongest networks, bands & security, logical devices / merged
#               SSIDs, probe requests, stations, and air quality (channel crowding) -- with a
#               button menu to refresh, inspect, and start/stop the collector. It NEVER transmits:
#               it only reads a local JSON file. No deauth, no rogue AP, no scan, no association.
# Author:       Starchorus
# Version:      0.1.0
# Category:     reconnaissance
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs on the device (uses the device's display commands LOG / LIST_PICKER / START_SPINNER /
# WAIT_FOR_BUTTON_PRESS, which exist only inside the payload runtime) AND on a dev machine
# (every device command has a plain-text fallback, so `sh starchorus-display.sh --once summary` prints
# the same dashboard to stdout for testing). Needs `jq` -- confirmed present on the device, but built
# WITHOUT the Oniguruma regex library, so no filter here may use test/match/sub/gsub/capture/scan/
# splits/split-2 (see the JQLIB block below and docs/device-notes.md), the --selftest included. A jq that
# lacks or breaks one of the builtins the filters use would leave the counters blank without a word, so
# the summary / top / bands screens print one red line when a cheap probe of that path fails, and
# --selftest names the builtin that does.
#
#   payload usage:  starchorus-display.sh              # interactive menu loop (press B to exit)
#   test usage:     starchorus-display.sh --once summary tests/fixtures/field-probes.json
#   device check:   sh starchorus-display.sh --selftest   # one PASS/FAIL line per jq builtin + the JQLIB helpers +
#                                                  # one end-to-end summary; exit 0 = all pass, 1 = any FAIL
#                                                  # (read-only, sends nothing, works even without jq)
#
# Reads $STARCHORUS_DIR/starchorus.json by default; pass a file as the last argument to override.
#
# The only output is LOG lines: append-only (a payload cannot register screens of its own), nothing
# is sent, no LED or buzzer is driven. Red marks an alarm and nothing else: an open/WEP network, or the
# one "jq incomplete" line (counts may be blank, see jq_warn); nothing is green.

# shellcheck disable=SC2016  # every jq filter below is a literal program; no shell expansion intended
STARCHORUS_DIR=${STARCHORUS_DIR:-/root/loot/starchorus}
JSON=${STARCHORUS_JSON:-$STARCHORUS_DIR/starchorus.json}
GEN=0; LASTG=

# ------------------------------------------------------------------ device command shims
# On the device these are real commands; elsewhere (or with STARCHORUS_DISPLAY_PLAIN=1) everything falls back
# to stdout, colour words dropped, so the same script is testable. Detected via LIST_PICKER: device-only,
# unlike LOG, which clashes with macOS /usr/bin/log on a dev machine.
if [ "${STARCHORUS_DISPLAY_PLAIN:-0}" != 1 ] && command -v LIST_PICKER >/dev/null 2>&1; then ONDEV=1; else ONDEV=0; fi

log() {  # log [red|blue] "text..."  -- red = an alarm, blue = a heading (that is the whole palette)
    case "$1" in red|blue) color=$1; shift ;; *) color= ;; esac
    if [ "$ONDEV" = 1 ]; then LOG ${color:+"$color"} "$*"; else printf '%s\n' "$*"; fi
}
logeach() { while IFS= read -r l; do log "$l"; done; }   # one LOG line per stdin line
spin_start() { if [ "$ONDEV" = 1 ]; then START_SPINNER "$1"; else printf '(( %s ))\n' "$1" >&2; echo _nospin; fi }
spin_stop()  { [ "$ONDEV" = 1 ] && STOP_SPINNER "$1" 2>/dev/null; return 0; }
err_dialog() { if [ "$ONDEV" = 1 ]; then ERROR_DIALOG "$1"; else printf 'ERROR: %s\n' "$1" >&2; fi }

# pick "Title" opt1 opt2 ... default -> the chosen option; the dev fallback echoes the default (last
# arg), so the menu flows run non-interactively
pick() { if [ "$ONDEV" = 1 ]; then LIST_PICKER "$@"; else for last; do :; done; printf '%s\n' "$last"; fi; }

# wait_exit SECS -> 0 if the user pressed B (leave), 1 on timeout (refresh & loop)
wait_exit() {
    [ "$ONDEV" = 1 ] || return 0   # dev fallback: one pass, then leave
    timeout "$1" WAIT_FOR_BUTTON_PRESS B >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 0 ] && return 0
    [ "$rc" -eq 124 ] || sleep "$1"   # the wait itself failed: still pace the refresh loop
    return 1
}

# ------------------------------------------------------------------ data access (jq, read-only)
# The "jq not found" gate sits right before the dispatch at the bottom of this file, not here: --selftest
# has to run (and report "FAIL: jq present") on a box without jq, and it needs every function below.
json_ok() { [ -s "$JSON" ] && jq -e . "$JSON" >/dev/null 2>&1; }

# NO REGEX IN ANY jq FILTER. The device's jq is built without Oniguruma (device-verified,
# docs/device-notes.md §2a): test/match/sub/gsub/capture/scan/splits/split-2 abort the whole program
# at call time (exit 5), and q() discards stderr, so a regex filter would silently print nothing
# (the band counts and the open/WEP line would come out EMPTY on the device).
# JQLIB holds string-builtin replacements; q() prepends it to every filter. A builtin not used here yet
# needs a device check first (§2a). tools/regress.d/jq-noregex.sh fails on a regex call and pins
# the meaning of bandnorm/sectag/isopenwep/secupper and the _WS membership (R3); display-selftest.sh (S8) repeats the
# regex scan after joining shell '' pairs, the --selftest included (it calls no regex builtin either).
#
# bandnorm ("2.4GHz"/" 5 GHz"/"6g" -> "2.4"/"5"/"6") follows the page's bandOf step for step
# (starchorus.html: .trim(), then /\s*ghz$/i): _trimws first, then each suffix cut followed by
# another _rtrimws; losing any of the three _rtrimws silently un-counts a band.
# _WS is the UNION (26) of the two measured references, so no band value either one normalises can
# drop out of the counts: Oniguruma "[[:space:]]" = the 25 Unicode White_Space codepoints (U+0009-
# U+000D, U+0020, U+0085, U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F, U+3000);
# the page's .trim() = the same minus U+0085 plus U+FEFF. Deliberate divergences from the page, both
# in the counting direction: U+0085 is trimmed here, and a bare trailing "g" is stripped here
# (iwinfo writes "6g").
# _rtrimws/_ltrimws are O(n^2) in the whitespace run (every slice copies); explode/implode would be
# linear but are not verified on the device's jq, and band strings are a handful of characters.
# rssit = the page's rssiT on an RSSI (a null would count as 1, as rssiT(null) does in JS; only apprep, i.e. the
# freshness line, still carries a null: pgaps below turns a missing RSSI into -75 dBm first, as normalizeDoc does).
# chloads / busiest (crowding and the busiest channel) follow the page's own pipeline, not apprep:
# pgaps = normalizeDoc for the fields the channel model reads (BSSID key via normMac or "ap<i>", duplicate
# BSSIDs merged with the strongest RSSI and the first non-empty channel/freq/width, a missing RSSI = -75 dBm,
# band via bandOf with its freq/channel fallback, a width outside 20/40/80/160/320 = none), sorted like
# S.apOrder (RSSI desc, then BSSID); chloads lists the channels per band in the order they first appear there
# and sums each load in that order (float addition is not associative: a tie can hinge on it); busiest is the
# FIRST channel with the highest load, as crowdingOf keeps it. _trimjs trims the page's .trim() set (_WS
# without U+0085). Not modelled (the collector writes neither): numeric STRINGS (the page's numOrNull reads
# "6" as 6, here only JSON numbers count), non-ASCII capitals in a BSSID (toLowerCase vs ascii_downcase).
# ld2 = channelLoad's Math.round(sum * 100) / 100 (the Air screen ranks on it, like airQuality); beaconpct = the page's
# beaconPct(band, n) for the n APs of ONE channel (rounded per channel, then summed and rounded again per band).
# oneline joins the lines of a text with a space: a newline in an SSID must not start a LOG line of its own (screen_top
# marks its alarm lines with a leading "!" that only the filter may write).
JQLIB='def _WS: ["\u0009","\u000A","\u000B","\u000C","\u000D","\u0020","\u0085","\u00A0","\u1680",
          "\u2000","\u2001","\u2002","\u2003","\u2004","\u2005","\u2006","\u2007","\u2008",
          "\u2009","\u200A","\u2028","\u2029","\u202F","\u205F","\u3000","\uFEFF"];
def _rtrimws: _WS as $ws | until(length == 0 or ((.[-1:]) as $c | $ws | index($c)) == null; .[:-1]);
def _ltrimws: _WS as $ws | until(length == 0 or ((.[0:1]) as $c | $ws | index($c)) == null; .[1:]);
def _trimws: _ltrimws | _rtrimws;
def bandnorm: (. // "") | tostring | ascii_downcase | _trimws
         | (if endswith("ghz") then rtrimstr("ghz") | _rtrimws else . end)
         | (if endswith("g")   then rtrimstr("g")   | _rtrimws else . end);
def rssit: (if . == null then 1 else ((. + 90) / 60 | if . < 0 then 0 elif . > 1 then 1 else . end) end);
def fctr($b; $ch): if $ch == null then null elif $b == "2.4" then (if $ch == 14 then 2484 else 2407 + 5 * $ch end) elif $b == "5" then 5000 + 5 * $ch elif $b == "6" then (if $ch == 2 then 5935 else 5950 + 5 * $ch end) else null end;
def apprep: {b: (.band | bandnorm), ch: (.channel | if type == "number" then . else null end), fq: (.freq | if type == "number" then . else null end),
             w: (.width | if type == "number" and (. as $w | [20,40,80,160,320] | index($w)) != null then . else 20 end),
             r: (.rssi | if type == "number" then (if . < -120 then -120 elif . > 0 then 0 else . end) else null end),
             ls: (.last_seen | if type == "number" then . else null end)};
def apspan: (.fq // fctr(.b; .ch)) as $f | if $f == null then null else [$f - .w / 2, $f + .w / 2] end;
def tierof($g): if $g == null or .ls == null or .ls <= 0 then null else ($g - .ls) as $age | if $age < -300 then null else (if $age < 0 then 0 else $age end) as $a | (if $a < 60 then 0 elif $a < 300 then 1 elif $a < 900 then 2 else 3 end) end end;
def chload($A; $b; $ch): (fctr($b; $ch)) as $f | if $f == null then {load: 0, co: 0, adj: 0}
  else ([$A[] | select(.b == $b and .ch != null) | . as $x | ($x | apspan) as $sp | select($sp != null)
        | select(((if $sp[1] < $f + 10 then $sp[1] else $f + 10 end) - (if $sp[0] > $f - 10 then $sp[0] else $f - 10 end)) > 0) | {r: ($x.r | rssit), same: ($x.ch == $ch)}]) as $O
    | {load: ([$O[].r] | add // 0), co: ([$O[] | select(.same)] | length), adj: ([$O[] | select(.same | not)] | length)} end;
def _WSP: _WS | map(select(. != "\u0085"));
def _trimjs: _WSP as $ws | until(length == 0 or ((.[0:1]) as $c | $ws | index($c)) == null; .[1:])
                         | until(length == 0 or ((.[-1:]) as $c | $ws | index($c)) == null; .[:-1]);
def pgband($f; $ch): (if . == null then "" else tostring end) | _trimjs
  | (if ascii_downcase | endswith("ghz") then .[:-3] | _trimjs else . end)
  | if . == "2.4" or . == "5" or . == "6" then .
    elif $f != null and $f >= 5925 then "6" elif $f != null and $f >= 5000 then "5" elif $f != null and $f >= 2400 then "2.4"
    elif $ch != null and $ch > 177 then "6" elif $ch != null and $ch >= 32 and $ch <= 177 then "5"
    elif $ch != null and $ch >= 1 and $ch <= 14 then "2.4" else "unknown" end;
def pgmac: tostring | _trimjs | ascii_downcase | ([split("-")[] | ":" + .] | add | .[1:])
  | if length == 12 and ([range(0; 12) as $i | .[$i:$i+1] | . as $c
        | select((["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"] | index($c)) != null)] | length) == 12
    then . as $s | [range(0; 6) as $i | ":" + $s[$i * 2:$i * 2 + 2]] | add | .[1:] else . end;
def pgaps: .aps as $R | [range(0; $R | length) as $i | $R[$i] | select(type == "object")
    | (.channel | if type == "number" then . else null end) as $ch | (.freq | if type == "number" then . else null end) as $fq
    | {id: (if .bssid == null or (.bssid | tostring | _trimjs) == "" then "ap\($i)" else (.bssid | pgmac) end),
       r: (.rssi | if type == "number" then (if . < -120 then -120 elif . > 0 then 0 else . end) else null end),
       ch: $ch, fq: $fq, w: (.width | if type == "number" and (. as $w | [20,40,80,160,320] | index($w)) != null then . else null end),
       b: (.band | pgband($fq; $ch))}]
  | group_by(.id)
  | map({id: .[0].id, r: ([.[].r | select(. != null)] | max // -75), ch: ([.[].ch | select(. != null)] | .[0]),
         fq: ([.[].fq | select(. != null)] | .[0]), w: ([.[].w | select(. != null)] | .[0] // 20),
         b: ([.[].b | select(. != "unknown")] | .[0] // "unknown")})
  | sort_by(-.r, .id);
def chloads: pgaps as $A
  | [("2.4", "5", "6") as $b | [$A[] | select(.b == $b and .ch != null) | .ch] as $L
     | [range(0; $L | length) as $i | $L[$i] as $x | select(($L[:$i] | index($x)) == null) | $x][] | {b: $b, ch: .}]
  | map(. + {load: chload($A; .b; .ch).load});
def busiest: chloads | if length == 0 then null else (map(.load) | max) as $m | map(select(.load == $m)) | .[0] end;
def ld2: (. * 100 | round) / 100;
def beaconpct($b; $n): ($n * ((if $b == "2.4" then 192 else 20 end) + 200 * 8 / (if $b == "2.4" then 1 else 6 end)) / (102.4 * 10) * 10 | round) / 10;
def oneline: tostring | split("\n") | .[0:1] + (.[1:] | map(" " + .)) | add // "";
def probers: .unassociated[] | select(.probes and (.probes|length>0));
def secupper: (. // "") | tostring | ascii_upcase;
def isopenwep: secupper | (. == "" or . == "OPEN" or contains("WEP"));
def sectag: secupper
         | if . == "" or . == "OPEN" or . == "NONE" then "Open"
           elif contains("WEP") then "WEP"
           elif contains("WPA3") or contains("SAE") then "WPA3"
           elif contains("OWE") then "OWE"
           elif contains("WPA2") or contains("RSN") then "WPA2"
           elif contains("WPA") then "WPA"
           else "other" end;
'
# jq helper: run a filter over the JSON, empty output on any error.
q() { jq -r "$JQLIB$1" "$JSON" 2>/dev/null; }
band_n() { q "[.aps[] | select((.band | bandnorm)==\"$1\")] | length"; }
client_counts() { free=$(q '.unassociated | length'); assoc=$(q '[.aps[].clients // [] | length] | add // 0'); }

# Visible failure marker. q() sends jq's stderr to /dev/null on purpose (a screen must never print jq
# noise), which is exactly how a missing builtin turned into silently blank counters. jq_healthy makes
# ONE jq call through the same JQLIB path the screens use, on known values, and compares the whole answer
# with the expected array: any jq error (a builtin that is absent or fails when it is called) leaves the
# output empty, so the comparison fails. The probe covers the JQLIB helpers plus add / group_by / sort_by
# (called outside JQLIB by the summary, top and bands filters); --selftest probes each builtin on its own.
# jq_warn is the one place that turns a failed probe into a red line, called first thing in those three
# screens. When the probe passes it prints nothing, so the healthy output is unchanged.
JQ_PROBE='[(" 5 GHz" | bandnorm), ("6g" | bandnorm), ("WPA2/WPA3" | sectag), ("" | sectag), (null | isopenwep),
          ([[1, 2], [3]] | map(length) | add),
          (["b", "a", "b"] | group_by(.) | map({k: .[0], n: length}) | sort_by(-.n) | .[0].k)]'
JQ_PROBE_WANT='["5","6","WPA3","Open",true,3,"b"]'
jq_healthy() { [ "$(jq -n -c "$JQLIB$JQ_PROBE" 2>/dev/null)" = "$JQ_PROBE_WANT" ]; }
jq_warn() { jq_healthy || log red "jq incomplete on this device -- counts may be blank. Run: sh starchorus-display.sh --selftest"; }

# D4 (same wording as the web page): the passivity claim, replaced by the ACTIVE line when the capture
# came from the collector's opt-in active scan (source contains "active" in any case, e.g. iw-scan-ACTIVE).
RX_SHORT="rx only"
claim() {  # claim [short]
    if [ "$(q '(.source // "") | tostring | ascii_downcase | contains("active")')" = true ]; then
        printf '%s\n' "ACTIVE SCAN · the collector sent probe requests"
    elif [ "${1:-}" = short ]; then printf '%s\n' "$RX_SHORT"
    else printf '%s\n' "rx only, nothing sent"; fi
}

age_str() {  # "42s ago" / "5m ago" / "3h ago" since .generated (unix seconds), or nothing
    g=$(q '.generated // empty'); [ -n "$g" ] || return
    now=$(date +%s 2>/dev/null) || return
    d=$((now - g)); [ "$d" -lt 0 ] && d=0
    if [ "$d" -lt 90 ]; then echo "${d}s ago"; elif [ "$d" -lt 5400 ]; then echo "$((d/60))m ago"; else echo "$((d/3600))h ago"; fi
}

# GEN, the generation counter: moves only when the collector wrote a NEW capture (a different
# `generated`), so a stalled collector shows a stalled GEN.
gen_tick() { g=$(q '.generated // empty'); if [ -n "$g" ] && [ "$g" != "$LASTG" ]; then GEN=$((GEN + 1)); LASTG=$g; fi; }
# D1 freshness: the page's four stages and words (ENCODING.fresh.words); undated (no capture time,
# last_seen <= 0, or later than generated + 300 s) is counted and named.
fresh_line() {   # -> "heard < 1 min 4 · heard < 5 min 3 · heard < 15 min 3 · on record 1 [· undated n]"
    q '(.generated | if type == "number" then . else null end) as $g | [.aps[] | apprep | tierof($g)] as $t
       | [range(0;4) as $i | ($t | map(select(. == $i)) | length)] as $c | ($t | map(select(. == null)) | length) as $u
       | "heard < 1 min \($c[0]) · heard < 5 min \($c[1]) · heard < 15 min \($c[2]) · on record \($c[3])" + (if $u > 0 then " · undated \($u)" else "" end)'
}
# D11 crowding 1-5: the busiest channel's overlap (sum of rssiT over the APs whose span overlaps its own
# 20 MHz) against [1.5, 3, 5, 8]; the same words as the page's Air drawer.
crowd_level() { q '[chloads[].load] | (max // 0) as $m | 1 + ([1.5, 3, 5, 8] | map(select($m >= .)) | length)'; }
crowd_word() { case "$1" in 1) echo quiet ;; 2) echo light ;; 3) echo moderate ;; 4) echo busy ;; *) echo "very busy" ;; esac; }
# -> "2.4 GHz ch 6": the FIRST channel of chloads with the highest load, i.e. the page's crowdingOf (strict ">"
# over bands 2.4, 5, 6 and, per band, the channels in the order they first appear in S.apOrder). Not max_by: it
# keeps the LAST maximum, which would name a different channel than the page on every tie.
crowd_busiest() { q 'busiest | if . == null then "" else .b + " GHz ch " + (.ch + 0 | tostring) end'; }

# ------------------------------------------------------------------ screens
# Every screen appends a fresh LOG block stamped with GEN: the device log cannot redraw in place.
ready() { json_ok || { log "no data"; return 1; }; gen_tick; }

screen_summary() {
    jq_warn
    if ! json_ok; then log "no starchorus.json yet -- start the collector (menu > Collector)"; return; fi
    gen_tick
    aps=$(q '.aps | length')
    open=$(q '[.aps[] | select(.security | isopenwep)] | length')
    client_counts
    b24=$(band_n 2.4); b5=$(band_n 5); b6=$(band_n 6)
    probing=$(q '[probers] | length')
    center=$(q '.center.label // "This device"')
    a=$(age_str)
    lvl=$(crowd_level); bz=$(crowd_busiest)
    log blue  "Starchorus  ~  $center"
    log       "GEN $GEN ${a:+· $a}  ($(claim))"
    log       "APs $aps   ·   2.4:$b24  5:$b5  6:$b6"
    log       "Clients  $free free · $assoc associated"
    log       "$(fresh_line)"
    log       "Crowding ${lvl:-1}/5 ($(crowd_word "${lvl:-1}"))${bz:+ · busiest $bz}"
    [ "${probing:-0}" -gt 0 ] && log "Probe requests: $probing client(s) naming a network"
    if [ "${open:-0}" -gt 0 ]; then log red "Open/WEP networks: $open"; else log "No open/WEP networks"; fi
    tpl_line "$aps" "$b24" "$b5" "$b6" "${open:-0}" "${lvl:-1}"
}

screen_top() {   # strongest networks by RSSI
    jq_warn; ready || return
    log blue "Strongest networks (GEN $GEN)"
    # the alarm is decided HERE, from the security field (isopenwep, the rule of the summary's Open/WEP count), and carried
    # as a leading "!" / " ", never by searching the rendered line: with the SSID included a WPA2 "OpenWrt" would come out
    # red and an AP with security "" (open, as the summary and the page count it) would not
    q '[.aps[] | {s:((.ssid // "") | oneline), b:(.band | bandnorm), r:(.rssi // -99), sec:((.security // "") | oneline), a:(.security | isopenwep)}]
        | sort_by(.r) | reverse | .[0:8][]
        | (if .a then "!" else " " end) + (.r|tostring) + " dBm  " + (if .s=="" then "<hidden>" else .s end) + "  " + .b + "G  " + .sec' \
      | while IFS= read -r line; do
            case "$line" in '!'*) log red "${line#?}" ;; *) log "${line#?}" ;; esac
        done
}

screen_bands() {   # band split + security tally
    jq_warn; ready || return
    log blue "Bands & security (GEN $GEN)"
    for band in 2.4 5 6; do
        n=$(band_n "$band")
        log "  ${band} GHz: ${n:-0} AP(s)"
    done
    q '[.aps[] | (.security | sectag)]
        | group_by(.) | map({k:.[0], n:length}) | sort_by(-.n) | .[]
        | "  " + .k + ": " + (.n|tostring)' \
      | while IFS= read -r line; do
            case "$line" in *"Open:"*|*"WEP:"*) log red "$line" ;; *) log "$line" ;; esac
        done
}

# G1/G2 (device bundling + ESS), a simplified on-glass count of the visualiser's heuristic (the full
# union-find lives in the HTML). Device = >= 2 BSSIDs sharing bytes 0-4, locally administered ones
# excluded; ESS = one SSID seen under >= 2 distinct bytes-0-4 prefixes.
screen_devices() {
    ready || return
    log blue "Logical grouping (GEN $GEN)"
    devlist=$(q '
      [ .aps[] | select(.bssid) | {bssid:(.bssid|ascii_downcase), ssid:(.ssid // "")} ]
      | map(. + { oui:(.bssid[0:8]), pfx:(.bssid[0:11]),
                  ul:( (.bssid[1:2]) as $c | ($c=="2" or $c=="6" or $c=="a" or $c=="e") ) })
      | map(select(.ul|not))
      | group_by(.pfx) | map(select(length>=2))' )
    ndev=$(printf '%s' "$devlist" | jq 'length' 2>/dev/null)
    ess=$(q '
      [ .aps[] | select((.ssid // "")!="") | {ssid:.ssid, dev:((.bssid // "")|ascii_downcase|.[0:11])} ]
      | group_by(.ssid) | map({ssid:.[0].ssid, devs:( [.[].dev] | unique | length)})
      | map(select(.devs>=2)) | length')
    log "Devices (multi-BSSID / multi-radio): ${ndev:-0}"
    log "Merged SSIDs (one name, >=2 devices): ${ess:-0}"
    [ "${ndev:-0}" -gt 0 ] && printf '%s' "$devlist" | jq -r '.[0:4][] | "  dev " + .[0].oui + "xx  (" + (length|tostring) + " radios)  " + (.[0].ssid|if .=="" then "<hidden>" else . end)' 2>/dev/null | logeach
}

screen_probes() {   # who is looking for which network (probe requests, rx only)
    ready || return
    log blue "Probe requests (GEN $GEN)  $(claim short)"
    n=$(q '[probers] | length')
    if [ "${n:-0}" -eq 0 ]; then log "No probe requests naming a network."; return; fi
    log "$n client(s) probing:"
    q '[probers | .probes[]]
        | group_by(.) | map({k:.[0], n:length}) | sort_by(-.n) | .[0:8][]
        | "  " + .k + "  (x" + (.n|tostring) + ")"' | logeach
}

# Stations: the strongest client MACs, rx only (a MAC is display, never transmission). Every
# optional field is coalesced; the total tie-break (-.r, .mac) makes the order deterministic.
screen_clients() {
    ready || return
    log blue "Stations (GEN $GEN)  $(claim short)"
    client_counts
    log "  ${free:-0} free · ${assoc:-0} associated"
    q '[ (.aps[] | .bssid as $b | (.clients // [])[] | {mac:(.mac // "?"), r:(.rssi // -99), a:$b, np:0}),
         (.unassociated[] | {mac:(.mac // "?"), r:(.rssi // -99), a:null, np:((.probes // []) | length)}) ]
        | sort_by(-.r, .mac) | .[0:8][]
        | ((.r|tostring) + " dBm  " + .mac + "  " + (if .a then "assoc " + .a else (if .np>0 then "probing" else "free" end) end))' | logeach
}

# Air quality: the page's Air drawer as a LOG block. Per band the busiest channels (overlap load) with
# co-/adjacent-channel counts, the least occupied of the usual set, and the beacon airtime as an
# ESTIMATED lower bound (one beacon per AP every 102.4 ms, 200 bytes at 1 Mbit/s on 2.4 GHz or
# 6 Mbit/s on 5/6 GHz).
# On the page's model, like the summary's crowding line: pgaps (duplicates merged, a missing RSSI = -75 dBm,
# band from freq/channel when the band field says nothing), channels ranked on the ROUNDED load (ld2) then the channel
# number, and the beacon estimate rounded per channel before the band sum (airQuality's beaconPctSum).
screen_air() {
    ready || return
    lvl=$(crowd_level)
    log blue "Air quality (GEN $GEN)"
    log "The air is $(crowd_word "${lvl:-1}") · crowding ${lvl:-1}/5"
    for band in 2.4 5 6; do
        q 'pgaps as $A | "'"$band"'" as $b
           | [$A[] | select(.b == $b and .ch != null)] as $P | ($P | length) as $n
           | if $n == 0 then "  \($b) GHz: no APs"
             else ([$P[].ch] | unique) as $C
               | ($C | map({ch: ., l: (chload($A; $b; .) | . + {load: (.load | ld2)})}) | sort_by(-.l.load, .ch) | .[0:3]) as $top
               | (if $b == "2.4" then [1,6,11] elif $b == "5" then [36,40,44,48,149,153,157,161,165] else [] end | map({ch: ., l: (chload($A; $b; .) | . + {load: (.load | ld2)})}) | sort_by(.l.load, .ch) | .[0]) as $q
               | ($C | map(. as $c | beaconpct($b; [$P[] | select(.ch == $c)] | length)) | add | . * 10 | round / 10) as $bp
               | "  \($b) GHz: \($n) APs · beacons >= \($bp)% (est.)",
                 ($top[] | "    ch \(.ch): \(.l.co) co · \(.l.adj) adjacent"),
                 (if $q == null then empty else "    least occupied: ch \($q.ch)" end)
             end' | logeach
    done
    log "estimate: 1 beacon per AP / 102.4 ms, 200 B, 1 Mbit/s (2.4) or 6 Mbit/s (5, 6)"
}

# Optional one-line template (operator-editable plain text; STARCHORUS_DISPLAY_TEMPLATE, else the first line of
# $STARCHORUS_DIR/display.tpl): {aps} {b24} {b5} {b6} {open} {crowding} {gen}. Only numbers are substituted;
# nothing else is read from the capture.
tpl_line() {   # tpl_line aps b24 b5 b6 open crowding
    t=${STARCHORUS_DISPLAY_TEMPLATE:-$(head -n 1 "$STARCHORUS_DIR/display.tpl" 2>/dev/null)}
    [ -n "$t" ] || return 0
    printf '%s\n' "$t" | sed -e "s/{aps}/$1/g" -e "s/{b24}/$2/g" -e "s/{b5}/$3/g" -e "s/{b6}/$4/g" -e "s/{open}/$5/g" -e "s/{crowding}/$6/g" -e "s/{gen}/$GEN/g" | cut -c1-80 | logeach
}

# ------------------------------------------------------------------ collector control (optional)
collector_menu() {
    if [ ! -x "$STARCHORUS_DIR/starchorus-collect.sh" ]; then log "collector not installed in $STARCHORUS_DIR"; return; fi
    case $(pick "Collector" "Status" "Start" "Stop" "Back" "Back") in
        Status) "$STARCHORUS_DIR/starchorus-collect.sh" --status 2>&1 | while IFS= read -r l; do log "${l#\[starchorus\] }"; done ;;
        Start)  id=$(spin_start "Starting collector"); setsid "$STARCHORUS_DIR/starchorus-collect.sh" </dev/null >/dev/null 2>"$STARCHORUS_DIR/collect.log" & spin_stop "$id"
                if [ "${STARCHORUS_ALLOW_ACTIVE:-0}" = 1 ]; then log "collector started · STARCHORUS_ALLOW_ACTIVE=1: it may run an ACTIVE scan"; else log "collector started ($RX_SHORT)"; fi ;;
        Stop)   "$STARCHORUS_DIR/starchorus-collect.sh" --stop >/dev/null 2>&1; log "collector stopped" ;;
    esac
}

# ------------------------------------------------------------------ --selftest (read-only device check)
# sh starchorus-display.sh --selftest       (over ssh or from a shell on the device; sends nothing, reads no capture)
# One "[display-selftest]   PASS: name" or "[display-selftest]   FAIL: name" line per check, then a last line
# "[display-selftest] SELFTEST: ALL PASS (N checks)" or "[display-selftest] SELFTEST: FAILED (k of N)"; exit 0
# only when every check passed. Written with printf straight to stdout, not through log(): it is meant to
# be read in a terminal. It runs the REAL JQLIB text above (never a copy) through the jq on PATH, in three
# layers so a failing jq shows WHICH piece is wrong: (1) one probe per jq builtin / syntax form the
# filters use, each on its own line; (2) a small table of bandnorm / secupper / isopenwep / sectag inputs
# (modelled on the oracle in tools/regress.d/jq-noregex.sh, far smaller); (3) the jq_healthy probe and
# screen_summary over a tiny embedded fixture. INFO lines are informational and never change the verdict.
# The one file it writes is that fixture (mktemp); a trap removes it again, also on INT/TERM.
ST_N=0; ST_FAIL=0; ST_TMP=
st_pass() { ST_N=$((ST_N + 1)); printf '[display-selftest]   PASS: %s\n' "$1"; }
st_fail() { ST_N=$((ST_N + 1)); ST_FAIL=$((ST_FAIL + 1)); printf '[display-selftest]   FAIL: %s\n' "$1"; }
st_info() { printf '[display-selftest]   INFO: %s\n' "$1"; }
# st_ck NAME WANT GOT RC: PASS iff jq exited 0 AND its compact output is exactly WANT (a jq that failed
# cannot pass by printing nothing); on FAIL the first line of what jq said is kept, it names the culprit.
st_ck() {
    if [ "$4" -eq 0 ] && [ "$3" = "$2" ]; then st_pass "$1"
    else st_fail "$1  (want $2, got: $(printf '%s\n' "$3" | sed -n 1p | cut -c1-90))"; fi
}
st_probe() {  # st_probe NAME 'FILTER' 'WANT-JSON': one builtin on its own, nothing else in the way
    st_got=$(jq -n -c "$2" 2>&1); st_rc=$?
    st_ck "jq $1" "$3" "$st_got" "$st_rc"
}
st_lib() {  # st_lib FN 'INPUT-JSON' 'WANT-JSON': FN of the real JQLIB applied to INPUT
    st_got=$(printf '%s\n' "$2" | jq -c "$JQLIB$1" 2>&1); st_rc=$?
    st_ck "$1 $2 -> $3" "$3" "$st_got" "$st_rc"
}
st_has() {  # st_has NAME TEXT grep-args...: PASS iff grep finds its pattern in TEXT (else show the counter lines)
    st_name=$1; st_text=$2; shift 2
    if printf '%s\n' "$st_text" | grep "$@" >/dev/null 2>&1; then st_pass "$st_name"
    else st_fail "$st_name  (got: $(printf '%s\n' "$st_text" | grep -E '^(APs |Open/WEP|No open/WEP|jq incomplete)' | tr '\n' '|'))"; fi
}
st_verdict() {
    if [ "$ST_FAIL" -eq 0 ]; then printf '[display-selftest] SELFTEST: ALL PASS (%s checks)\n' "$ST_N"; return 0; fi
    printf '[display-selftest] SELFTEST: FAILED (%s of %s)\n' "$ST_FAIL" "$ST_N"; return 1
}

display_selftest() {
    ONDEV=0   # plain-text path: log() prints to stdout, which is what the screen_summary check captures
    trap '[ -z "$ST_TMP" ] || rm -f "$ST_TMP"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if command -v jq >/dev/null 2>&1; then st_pass "jq present"; else
        st_fail "jq present"; st_info "no jq on PATH: every other check needs it, so they are skipped"
        st_verdict; return
    fi
    st_info "jq version: $(jq --version 2>&1 | sed -n 1p)"
    # No regex builtin is called anywhere in this file, the selftest included (see the no-regex rule above).

    # (1) every builtin / syntax form the JQLIB helpers and the screen filters rely on, one line each
    st_probe "builtin endswith" '[("5ghz" | endswith("ghz")), ("5ghz" | endswith("g5")), ("" | endswith("g"))]' '[true,false,false]'
    st_probe "builtin until" '[0 | until(. >= 3; . + 1)]' '[3]'
    st_probe "builtin index" '[([" ", "a"] | index(" ")), ([" ", "a"] | index("z"))]' '[0,null]'
    st_probe "builtin string slice .[a:b]" '["abcd" | .[:-1], .[0:1], .[-1:], .[1:3]]' '["abc","a","d","bc"]'
    st_probe "builtin array slice .[a:b]" '[[1, 2, 3, 4] | .[0:2], .[-1:]]' '[[1,2],[4]]'
    st_probe "builtin tostring" '[(5 | tostring), ("a" | tostring), (null | tostring), (true | tostring)]' '["5","a","null","true"]'
    st_probe "builtin ascii_downcase" '"AbC 5" | ascii_downcase' '"abc 5"'
    st_probe "builtin ascii_upcase" '"AbC 5" | ascii_upcase' '"ABC 5"'
    st_probe "builtin rtrimstr" '[("abcghz" | rtrimstr("ghz")), ("abc" | rtrimstr("x"))]' '["abc","abc"]'
    st_probe "builtin ltrimstr" '[("xxabc" | ltrimstr("xx")), ("abc" | ltrimstr("x"))]' '["abc","abc"]'
    st_probe "builtin contains" '[("WPA2" | contains("PA")), ("WPA2" | contains("X"))]' '[true,false]'
    st_probe "builtin startswith" '[("WPA2" | startswith("WP")), ("WPA2" | startswith("PA"))]' '[true,false]'
    st_probe "builtin split/1" '"a,b,c" | split(",")' '["a","b","c"]'
    st_probe "builtin group_by" '[1, 2, 1] | group_by(.)' '[[1,1],[2]]'
    st_probe "builtin sort_by" '[([{"r": 2}, {"r": 1}] | sort_by(.r) | map(.r)), ([{"n": 1}, {"n": 3}] | sort_by(-.n) | map(.n))]' '[[1,2],[3,1]]'
    st_probe "builtin reverse" '[1, 2, 3] | reverse' '[3,2,1]'
    st_probe "builtin unique" '[3, 1, 3] | unique' '[1,3]'
    st_probe "builtin add" '[([1, 2] | add), ([] | add // 0)]' '[3,0]'
    st_probe "builtin select" '[1, 2, 3] | map(select(. > 1))' '[2,3]'
    st_probe "syntax // (alternative operator)" '[(null // "x"), (false // "y"), ("z" // "w")]' '["x","y","z"]'
    st_probe "syntax \uXXXX escapes in string literals" '["\u0041", ("\u00A0\u3000\uFEFF" | length)]' '["A",3]'
    # the same for what the freshness, crowding, stations and air-quality screens use
    st_probe "builtin map" '[1, 2, 3] | map(. * 2)' '[2,4,6]'
    st_probe "builtin max" '[([3, 1, 2] | max), ([] | max)]' '[3,null]'
    st_probe "builtin range" '[range(0; 3)]' '[0,1,2]'
    st_probe "builtin round" '[(2.5 | round), (1.24 | round)]' '[3,1]'
    st_probe "builtin type" '[(1 | type), ("a" | type), (null | type)]' '["number","string","null"]'
    st_probe "builtin not / empty" '[(true | not), (false | not), ([1, empty, 2] | length)]' '[false,true,2]'
    st_probe "builtin sort_by with several keys" '[([{"r": 1, "m": "b"}, {"r": 1, "m": "a"}, {"r": 2, "m": "c"}] | sort_by(-.r, .m) | map(.m)), ([{"l": 1, "c": 6}, {"l": 1, "c": 1}, {"l": 0, "c": 11}] | sort_by([.l, .c]) | map(.c))]' '[["c","a","b"],[11,1,6]]'
    st_probe "syntax string interpolation" '"a\(1 + 1)b"' '"a2b"'
    st_probe "syntax def with \$parameters" 'def f($a; $b): $a + $b; f(1; 2)' '3'
    # the page-order channel model (chloads) merges duplicate BSSIDs with group_by and takes the FIRST non-empty value
    st_probe "builtin group_by keeps the input order inside a group" '[{"k": 2, "v": "a"}, {"k": 1, "v": "b"}, {"k": 2, "v": "c"}] | group_by(.k) | map(map(.v))' '[["b"],["a","c"]]'

    # (2) what the JQLIB helpers MEAN, on a small fixed table (input and expected value are JSON)
    st_lib bandnorm '"2.4GHz"' '"2.4"'
    st_lib bandnorm '" 5 GHz"' '"5"'
    st_lib bandnorm '"5GHZ"' '"5"'
    st_lib bandnorm '"6g"' '"6"'
    st_lib bandnorm '"5"' '"5"'
    st_lib bandnorm '"5\u00A0GHz"' '"5"'
    st_lib bandnorm '""' '""'
    st_lib bandnorm 'null' '""'
    st_lib secupper '"wpa2"' '"WPA2"'
    st_lib isopenwep '""' 'true'
    st_lib isopenwep '"OPEN"' 'true'
    st_lib isopenwep '"WEP"' 'true'
    st_lib isopenwep '"WPA2"' 'false'
    st_lib sectag '"WPA2/WPA3"' '"WPA3"'
    st_lib sectag '"SAE"' '"WPA3"'
    st_lib sectag '"OWE"' '"OWE"'
    st_lib sectag '"RSN"' '"WPA2"'
    st_lib sectag '"WEP"' '"WEP"'
    st_lib sectag '""' '"Open"'
    st_lib sectag '"CCMP"' '"other"'
    # busiest = the page's crowdingOf on a tie: ch 1 and ch 11 carry the same load, ch 1 holds the lower BSSID, so the page
    # meets it first and keeps it (jq max_by would keep the LAST maximum, ch 11)
    st_lib 'busiest | [.b, .ch]' '{"aps":[{"bssid":"02:00:00:00:00:02","rssi":-60,"channel":11,"band":"2.4"},{"bssid":"02:00:00:00:00:01","rssi":-60,"channel":1,"band":"2.4"}]}' '["2.4",1]'

    # (3) the marker's own probe, then the whole screen: a jq without a needed builtin would break exactly this output
    if jq_healthy; then st_pass "jq_healthy probe (the failure marker's own test)"
    else st_fail "jq_healthy probe (the failure marker's own test)"; fi
    ST_TMP=$(mktemp "${TMPDIR:-/tmp}/starchorus-display-st.XXXXXX" 2>/dev/null) || ST_TMP=
    if [ -n "$ST_TMP" ]; then
        # synthetic fixture: locally administered dummy BSSIDs, no real network data
        cat > "$ST_TMP" <<'ST_JSON'
{"source":"selftest","center":{"label":"selftest"},"unassociated":[],
 "aps":[{"bssid":"02:00:00:00:00:01","ssid":"Test-A","rssi":-40,"band":"2.4GHz","security":"WPA2/WPA3"},
        {"bssid":"02:00:00:00:00:02","ssid":"Test-B","rssi":-50,"band":" 5 GHz","security":"Open"},
        {"bssid":"02:00:00:00:00:03","ssid":"Test-C","rssi":-60,"band":"5","security":"WEP"},
        {"bssid":"02:00:00:00:00:04","ssid":"Test-D","rssi":-70,"band":"6g","security":"WPA3"}]}
ST_JSON
        JSON=$ST_TMP
        st_out=$(screen_summary 2>&1)
        rm -f "$ST_TMP"; ST_TMP=
        st_has "screen_summary: band counters are digits" "$st_out" -Eq '2\.4:[0-9]+ +5:[0-9]+ +6:[0-9]+'
        st_has "screen_summary: band counts match the fixture (2.4:1 5:2 6:1)" "$st_out" -qF '2.4:1  5:2  6:1'
        st_has "screen_summary: open/WEP line matches the fixture (2)" "$st_out" -qxF 'Open/WEP networks: 2'
    else
        st_fail "screen_summary end-to-end (no temp file for the fixture)"
    fi
    st_verdict
}

# ------------------------------------------------------------------ main loop
render() {
    case "$1" in
        top|bands|devices|probes|clients|air) "screen_$1" ;;
        *) screen_summary ;;
    esac
}

# --selftest is dispatched BEFORE the jq gate on purpose: without jq it still has to print "FAIL: jq present"
# and the FAILED line (exit 1) instead of taking the err_dialog + exit 1 path of a normal run.
if [ "${1:-}" = "--selftest" ]; then display_selftest; exit $?; fi
command -v jq >/dev/null 2>&1 || { err_dialog "jq not found -- cannot read starchorus.json"; exit 1; }

if [ "$1" = "--once" ]; then
    [ -n "$3" ] && JSON=$3
    render "$2"
    exit 0
fi

# interactive: a menu that returns to a self-refreshing summary; press B to leave any screen.
log blue "Starchorus -- dashboard"
log "Reads $JSON  ·  $(claim short)"
view=summary
while :; do
    render "$view"
    if [ "$view" = summary ]; then
        # live summary refreshes every ~4 s until B, then opens the menu
        if wait_exit 4; then
            sel=$(pick "Starchorus" "Summary" "Top networks" "Bands & security" "Devices & merges" "Probe requests" "Stations" "Air quality" "Collector" "Exit" "Summary")
            case "$sel" in
                "Summary") view=summary ;;
                "Top networks") view=top ;;
                "Bands & security") view=bands ;;
                "Devices & merges") view=devices ;;
                "Probe requests") view=probes ;;
                "Stations") view=clients ;;
                "Air quality") view=air ;;
                "Collector") collector_menu; view=summary ;;
                "Exit"|*) log "bye"; exit 0 ;;
            esac
        fi
    else
        log "Press B for the menu."
        wait_exit 30
        view=summary
    fi
    [ "$ONDEV" = 1 ] || exit 0   # dev fallback: no interactive loop
done
