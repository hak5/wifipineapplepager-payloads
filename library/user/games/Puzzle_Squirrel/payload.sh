#!/bin/sh
# Title: Puzzle Squirrel
# Description: Shows links to my GitHub Pages CTFs

set -u

URL1="https://notorious-squirrel.github.io/Cyber-Nightmares/"
URL2="https://nexusai2040.github.io/NexusAi-2040/"

# Load Hak5 UI commands if present
if [ -f /lib/hak5/commands.sh ]; then
  # shellcheck disable=SC1091
  . /lib/hak5/commands.sh 2>/dev/null || true
fi

# Fallbacks (so something ALWAYS prints)
if ! command -v LOG >/dev/null 2>&1; then
  LOG() { echo "$*"; }
fi

# PROMPT is nice, but not guaranteed — make it optional
HAS_PROMPT=0
if command -v PROMPT >/dev/null 2>&1; then
  HAS_PROMPT=1
fi

# ---- UI ----
if [ "$HAS_PROMPT" -eq 1 ]; then
  PROMPT "Are you ready to enter?" || exit 0
fi

LOG ""
LOG "Open these on Laptop/Desktop (not optimised for mobile):"
LOG ""
LOG "1) $URL1"
LOG "2) $URL2"
LOG ""
LOG "Done."

# Keep it visible
sleep 40

