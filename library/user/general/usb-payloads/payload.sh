#!/bin/bash
# title: USB Payloads
# description: Mount/Unmount USB storage and link payloads from USB
# author: RootJunky
# version: 2

USB_MOUNT="/usb"
USB_PAYLOADS="$USB_MOUNT/payloads"
LINK_PATH="/root/payloads/user/usb"

mkdir -p "$USB_MOUNT"

# Detect USB block device
DEVICE=$(blkid | grep -o '/dev/sd[a-z][0-9]\+' | head -n 1)

if [ -z "$DEVICE" ]; then
    LOG "No USB storage device detected."
    exit 1
fi

PROMPT "This payload will setup the symlink to Run payloads from usb/payloads folder"

CHOICE=$(LIST_PICKER "USB Payloads" \
"Mount USB + Link Payloads" \
"Unmount USB + Remove Link" \
"Refresh Link Only" \
"Exit"\
"Mount USB + Link Payloads")

case "$CHOICE" in

"Mount USB + Link Payloads")
    if mount | grep -q "^$DEVICE "; then
        LOG "USB already mounted."
    else
        mount "$DEVICE" "$USB_MOUNT" && LOG "Mounted $DEVICE at $USB_MOUNT"
    fi

    mkdir -p "$USB_PAYLOADS"

    [ -e "$LINK_PATH" ] && rm -rf "$LINK_PATH"

    ln -s "$USB_PAYLOADS" "$LINK_PATH"

    if [ -L "$LINK_PATH" ]; then
        LOG "USB payload symlink created."
        LOG "$LINK_PATH -> $USB_PAYLOADS"
    else
        LOG "Failed creating symlink."
    fi
    ;;

"Unmount USB + Remove Link")
    [ -e "$LINK_PATH" ] && rm -rf "$LINK_PATH"

    if mount | grep -q "^$DEVICE "; then
        umount "$DEVICE" && LOG "USB unmounted."
    else
        LOG "USB not mounted."
    fi
    ;;

"Refresh Link Only")
    if [ ! -d "$USB_PAYLOADS" ]; then
        LOG "USB payload folder missing. Creating..."
        mkdir -p "$USB_PAYLOADS"
    fi

    [ -e "$LINK_PATH" ] && rm -rf "$LINK_PATH"
    ln -s "$USB_PAYLOADS" "$LINK_PATH"

    if [ -L "$LINK_PATH" ]; then
        LOG "Symlink refreshed."
    else
        LOG "Failed refreshing symlink."
    fi
    ;;

*)
    LOG "Cancelled."
    exit 0
    ;;
esac

LOG "Reopen Payload Menu to access USB."
exit 0