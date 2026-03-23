#!/bin/bash
#Title: toggle privacy mode
#Description: Enables and disables privacy mode by edit the degub.json
#Author: Rootjunky
#Version: 2

FILE=/usr/debug.json

# create file if missing
[ -f "$FILE" ] || echo '{}' > "$FILE"

if grep -q '"censor"[[:space:]]*:[[:space:]]*true' "$FILE"; then
    echo '{ "censor": false }' > "$FILE"
LOG "Restarting server in 5 seconds to turn off privacy mode"
sleep 5
/etc/init.d/pineapplepager restart
else
    echo '{ "censor": true }' > "$FILE"
LOG "Restarting server in 5 seconds to enable privacy mode"
sleep 5
/etc/init.d/pineapplepager restart
fi
