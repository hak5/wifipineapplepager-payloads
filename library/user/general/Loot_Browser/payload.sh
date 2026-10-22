#!/bin/bash
# Title: Loot Browser
# Author: Jenx
# Description: Browse /root/loot on the Pager screen. Walk the folders, read the text and log files, and get an info card (with where to copy it) for anything that can't be shown here. Read-only. Matches the Dockside / Dockside Dark themes automatically.
# Version: 1.1
# Category: general

# ---------------------------------------------------------------------------
# Controls (hold the Pager the normal way):
#   Browse:  Up/Down pick      Green/Right open      Left up a folder   Red exit
#   Reading: Up/Down line       Left/Right page      Green page down    Red back
#   Info:    Green/Red back to the list
#   Power = the Pager's usual display sleep
#
# A small native binary (source + build.sh included; freestanding, integer-only).
# It takes the screen with the official UI_TAKEOVER / UI_RELEASE handoff and only
# ever READS from /root/loot - it never writes, moves or deletes anything, and it
# can't browse above /root/loot. Text files open in a scrolling reader; anything
# that isn't text (pcap, handshakes, images...) shows an info card telling you to
# copy it off. The screen font is capitals-only, so names and text show in caps.
# ---------------------------------------------------------------------------

DIR=""
for d in "${_PAYLOAD_HOME:-}" \
         "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" \
         "/root/payloads/user/general/Loot_Browser"; do
    [ -n "$d" ] || continue
    [ -f "$d/lootbrowser" ] && { DIR="$d"; break; }
done
[ -z "$DIR" ] && { LOG red "lootbrowser binary not found. Reinstall the Loot_Browser folder."; exit 1; }
chmod +x "$DIR/lootbrowser" 2>/dev/null

[ -d /root/loot ] || { LOG yellow "No /root/loot folder yet - run a payload that saves loot first."; sleep 2; exit 0; }

# Detect the active theme so the browser can match it. If it's Dockside or
# Dockside Dark the browser draws a matching Finder window; any other theme
# uses the browser's own look.
THEME=$(curl --unix-socket /tmp/api.sock -s http://localhost/api/pager/preferences/get 2>/dev/null | sed -n 's/.*"theme_name":"\([^"]*\)".*/\1/p')
[ -n "$THEME" ] && echo "$THEME" > /tmp/loot.theme 2>/dev/null

cleanup() { UI_RELEASE 2>/dev/null; rm -f /tmp/loot.theme 2>/dev/null; }
trap cleanup EXIT INT TERM

UI_TAKEOVER 2>/dev/null
"$DIR/lootbrowser"
