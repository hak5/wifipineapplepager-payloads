#!/bin/bash
# Title: WiGLE Own AP Filter
# Description: Removes the Pager's own access points (Management AP, Open AP,
#              Evil WPA, PineAP) from WiGLE wardrive logs before upload, so
#              they don't end up on wigle.net. Matches by the Pager's own
#              MAC addresses and by the Management AP SSID.
# Author: DerSeb90
# Version: 1.0
# Category: general

# =============================================================================
# CONFIG
# =============================================================================

WIGLE_DIR=/root/loot/wigle

# Keep an untouched copy of every file that was changed (<name>.csv.bak).
KEEP_BACKUP=true

# Files modified less than this many seconds ago are treated as the log that
# is currently being written and are skipped (stop WiGLE logging first).
ACTIVE_FILE_AGE=30

# Additional SSIDs to drop (exact match), e.g. a phone hotspot you carry.
EXTRA_SSIDS=()

# =============================================================================
# COLLECT OWN IDENTIFIERS
# =============================================================================

TMPDIR_F=$(mktemp -d /tmp/wigle_filter.XXXXXX)
trap 'rm -rf "$TMPDIR_F"' EXIT INT TERM
MACS="$TMPDIR_F/macs"
SSIDS="$TMPDIR_F/ssids"
: > "$MACS"; : > "$SSIDS"

# 1) Every MAC address of every local interface (radios, VIFs, monitor, ...).
cat /sys/class/net/*/address 2>/dev/null >> "$MACS"
iw dev 2>/dev/null | awk '$1 == "addr" {print $2}' >> "$MACS"

# 2) MACs configured in UCI for all wireless interfaces (AP clones, etc.).
uci -q show wireless 2>/dev/null | grep -E '\.macaddr=' | cut -d= -f2- | tr -d "'" >> "$MACS"

# 3) SSID of the Management AP. SSIDs of the Open / Evil WPA APs are NOT
#    filtered by name, since they often impersonate real networks; those are
#    caught by MAC instead.
mgmt_ssid=$(uci -q get wireless.wlan0mgmt.ssid 2>/dev/null)
[ -n "$mgmt_ssid" ] && printf '%s\n' "$mgmt_ssid" >> "$SSIDS"
for s in "${EXTRA_SSIDS[@]}"; do printf '%s\n' "$s" >> "$SSIDS"; done

# Normalize MACs: uppercase, drop empties / all-zero.
tr 'a-f' 'A-F' < "$MACS" | grep -E '^([0-9A-F]{2}:){5}[0-9A-F]{2}$' \
    | grep -v '^00:00:00:00:00:00$' | sort -u > "$MACS.n"
mv "$MACS.n" "$MACS"

LOG "Own MACs: $(wc -l < "$MACS")"
LOG "Mgmt SSID: ${mgmt_ssid:-<none>}"

# =============================================================================
# FILTER
# =============================================================================
# WiGLE CSV: line 1 = WigleWifi pre-header, line 2 = column header,
# then MAC,SSID,... ; SSID may be quoted ("" escapes a quote).

filter_awk='
BEGIN {
    while ((getline l < macfile) > 0) mac[l] = 1
    while ((getline l < ssidfile) > 0) if (l != "") ssid[l] = 1
}
NR <= 2 { print; next }
{
    c = index($0, ",")
    m = toupper(substr($0, 1, c - 1))
    rest = substr($0, c + 1)
    if (substr(rest, 1, 1) == "\"") {
        s = ""; i = 2; n = length(rest)
        while (i <= n) {
            ch = substr(rest, i, 1)
            if (ch == "\"") {
                if (substr(rest, i + 1, 1) == "\"") { s = s "\""; i += 2; continue }
                break
            }
            s = s ch; i++
        }
    } else {
        e = index(rest, ","); s = (e ? substr(rest, 1, e - 1) : rest)
    }
    if ((m in mac) || (s in ssid)) { dropped++; next }
    print
}
END { print dropped + 0 > dropfile }
'

now=$(date +%s)
files=0; changed=0; removed=0; skipped=0
for f in "$WIGLE_DIR"/*.csv; do
    [ -f "$f" ] || continue
    head -n 1 "$f" | grep -q '^WigleWifi' || continue
    files=$((files + 1))

    mtime=$(date -r "$f" +%s 2>/dev/null || echo 0)
    if [ $((now - mtime)) -lt "$ACTIVE_FILE_AGE" ]; then
        LOG yellow "Skip (active): $(basename "$f")"
        skipped=$((skipped + 1))
        continue
    fi

    out="$TMPDIR_F/out.csv"
    awk -v macfile="$MACS" -v ssidfile="$SSIDS" -v dropfile="$TMPDIR_F/drop" \
        "$filter_awk" "$f" > "$out" || continue
    d=$(cat "$TMPDIR_F/drop" 2>/dev/null); d=${d:-0}

    if [ "$d" -gt 0 ]; then
        [ "$KEEP_BACKUP" = true ] && [ ! -f "$f.bak" ] && cp -p "$f" "$f.bak"
        # Keep the original mtime so a re-run doesn't mistake it for the
        # active log.
        touch -r "$f" "$TMPDIR_F/ref"
        cat "$out" > "$f"
        touch -r "$TMPDIR_F/ref" "$f"
        LOG "$(basename "$f"): -$d"
        changed=$((changed + 1))
        removed=$((removed + d))
    fi
done

msg="WiGLE Own AP Filter\n\nFiles: $files\nCleaned: $changed\nRows removed: $removed"
[ "$skipped" -gt 0 ] && msg="$msg\nSkipped (active): $skipped\nStop WiGLE and run again."
ALERT "$msg"
exit 0
