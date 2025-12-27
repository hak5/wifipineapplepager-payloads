#!/bin/bash
#Title: toggle privacy mode
#Description: Enables and disables privacy mode by edit the degub.json       
#Author: Rootjunky
#Version: 1

FILE=/usr/debug.json

# create file if missing
[ -f "$FILE" ] || echo '{}' > "$FILE"

if grep -q '"censor"[[:space:]]*:[[:space:]]*true' "$FILE"; then
    echo '{ "censor": false }' > "$FILE"
LOG "Please reboot for privacy mode to turn off"
else
    echo '{ "censor": true }' > "$FILE"
LOG "Please reboot for privacy mode to take effect"
fi