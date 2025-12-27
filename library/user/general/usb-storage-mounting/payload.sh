#!/bin/bash
# Title: USB Storage Mount (blkid)
# Description: Detects, mounts, and unmounts USB storage devices
# Author: RootJunky
# Version: 3

MOUNTPOINT="/usb"

# Create mount point if it doesn't exist
mkdir -p "$MOUNTPOINT"

# Detect USB storage partition
DEVICE=$(blkid | grep -o '/dev/sd[a-z][0-9]\+' | head -n 1)

# Check if a USB device was found
if [ -z "$DEVICE" ]; then
    echo "No USB storage device detected."
    LOG "No USB device found"
    exit 1
fi

# Check if device is already mounted
if mount | grep -q "^$DEVICE "; then
    echo "$DEVICE is already mounted. Unmounting..."
    umount "$DEVICE" && {
        LOG "USB device unmounted"
        echo "Unmounted $DEVICE"
    }
else
    echo "$DEVICE detected. Mounting..."
    mount "$DEVICE" "$MOUNTPOINT" && {
        LOG "USB device mounted at $MOUNTPOINT"
        echo "Mounted $DEVICE at $MOUNTPOINT"
    }

fi
