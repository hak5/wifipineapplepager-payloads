#!/bin/sh
# Title: 1988 Listener
# Description: persistent background listener that will trigger an easter egg link, lights, and sound when the OG code is entered
# Author: m0usem0use
# Version: 1
# Device: WiFi Pineapple Pager

DEVICE="/dev/input/event0"
BUFFER_FILE="/tmp/1988_buffer"
echo -n > "$BUFFER_FILE"

# Sequence: UP UP DOWN DOWN LEFT RIGHT LEFT RIGHT B A START
TARGET="6750209 6750209 7077889 7077889 6881281 6946817 6881281 6946817 19922945 19988481 7602177"

echo "1988 Listener Active."

# Using cat|hexdump (Stable but Laggy)
cat "$DEVICE" | hexdump -e '4/4 "%u " "\n"' | while read sec usec typecode value; do
    if [ "$value" = "1" ]; then
        echo -n "$typecode " >> "$BUFFER_FILE"
        CURRENT_TAIL=$(tail -c 200 "$BUFFER_FILE")
        
        case "$CURRENT_TAIL" in
            *"$TARGET"*) 
                # TRIGGER ACTIONS
                if [ -x /usr/bin/LED ]; then LED SPECIAL; fi
                if [ -x /usr/bin/RINGTONE ]; then
                    echo "Contra:d=4,o=3,b=160:16d#,16d#,16f,16f,16g#,16f,16d#,16d#,16f,16f,16g#,16f,16c#,16c#,16f,16f,16g#,16f,16c#,16c#,16f,16f,16g#,16f" > /tmp/nat.rtttl
                    RINGTONE /tmp/nat.rtttl
                fi
                if [ -x /usr/bin/LOG ]; then LOG "OG CONTRA CODE! mousemouse.org/hak5"; fi
                if [ -x /usr/bin/ALERT ]; then ALERT "OG CONTRA CODE! mousemouse.org/hak5"; fi
                
                echo -n > "$BUFFER_FILE"
                (sleep 10; LED OFF) & 
                ;; 
        esac
    fi
done