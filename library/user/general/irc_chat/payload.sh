#!/bin/bash
# Title: IRC Chat
# Author: Hackazillarex
# Description: Chat via IRC
# Version: 1.0

# Web version to chat back via device is https://webchat.oftc.net 
SERVER="irc.oftc.net"
PORT=6667

################################
# Pick nickname
################################
LOG white "Pick IRC nickname..."
NICK=$(TEXT_PICKER "IRC Nickname" "PagerBot")
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        exit 0
        ;;
esac

################################
# Pick channel
################################
LOG white "Pick IRC channel..."
CHAN=$(TEXT_PICKER "IRC Channel (#channel)" "#testchannel")
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        exit 0
        ;;
esac

LOG white "Nick: $NICK"
LOG white "Channel: $CHAN"

################################
# Connect to IRC
################################
LOG white "Connecting to $SERVER..."
exec 3<>/dev/tcp/$SERVER/$PORT || { LOG red "Connection failed"; exit 1; }

echo "NICK $NICK" >&3
echo "USER $NICK 0 * :Pineapple Pager IRC" >&3
sleep 3
echo "JOIN $CHAN" >&3
LOG green "Joined $CHAN"

################################
# Background: IRC receive loop
################################
last_msg=""
receive_loop() {
    while read -r line <&3; do
        [[ $line == PING* ]] && echo "PONG ${line#PING }" >&3 && continue
        echo "$line" | grep -q "PRIVMSG" || continue

        USER=$(echo "$line" | awk -F'!' '{print substr($1,2)}')
        MSG=$(echo "$line" | sed -n 's/^:[^!]*![^ ]* PRIVMSG [^ ]* :\(.*\)$/\1/p')

        [[ -z $USER || -z $MSG || "$USER: $MSG" == "$last_msg" ]] && continue

        LOG white "<$USER> $MSG"
        last_msg="$USER: $MSG"
    done
}

receive_loop &  # start background loop
IRC_PID=$!

################################
# Main loop: DOWN to reply, B to exit
################################
LOG white "Press DOWN to reply, B to exit payload"

while :; do
    BUTTON=$(WAIT_FOR_INPUT 0.5)  
    [[ -z $BUTTON ]] && continue

    # Exit payload if B is pressed (unless TEXT_PICKER is active)
    if [[ "$BUTTON" == "B" ]]; then
        LOG red "Exiting payload..."
        kill $IRC_PID 2>/dev/null
        break
    fi

    # Reply flow for DOWN button
    if [[ "$BUTTON" == "DOWN" ]]; then
        resp=$(TEXT_PICKER "Reply to channel" "")
        case $? in
            $DUCKYSCRIPT_CANCELLED)
                LOG red "Reply cancelled"
                continue
                ;;
            $DUCKYSCRIPT_REJECTED)
                LOG red "Reply rejected"
                continue
                ;;
            $DUCKYSCRIPT_ERROR)
                LOG red "Picker error"
                continue
                ;;
        esac

        echo "PRIVMSG $CHAN :$resp" >&3
        LOG green "Sent: $resp"
    fi
done
