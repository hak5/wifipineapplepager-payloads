#!/bin/bash
# Title:                USB Mount + Transfer Loot
# Description:          Mounts a USB drive and optionally copies loot to it (no persistent system changes). To use ensure you confirm at dialog boxes with all capitols "YES".
# Author:               Stuffy24
# Version:              1.0

# -----------------------
# CONFIG (safe defaults)
# -----------------------
MOUNTPOINT="/mnt/usb"
USB_ROOT="$MOUNTPOINT/pager-engagements"
# Loot sources to copy. Adjust if you store loot elsewhere.
LOOT_SOURCES="/root/loot /tmp/loot"

# -----------------------
# Helpers
# -----------------------
is_mounted() {
    # True if mountpoint is mounted
    grep -qsE "[[:space:]]$MOUNTPOINT[[:space:]]" /proc/mounts
}

mkdir_safe() {
    mkdir -p "$1" 2>/dev/null
}

# NOTE: This is the only area you may need to substitute on some systems.
# It tries common USB disk partition patterns.
find_usb_partition() {
    # Common first USB partition names:
    for dev in /dev/sda1 /dev/sdb1 /dev/sdc1 /dev/sdd1; do
        [ -b "$dev" ] && echo "$dev" && return 0
    done

    # Generic fallback: any /dev/sdXN partition
    for dev in /dev/sd[a-z][0-9]; do
        [ -b "$dev" ] && echo "$dev" && return 0
    done

    return 1
}

copy_dir_if_exists() {
    src="$1"
    dst="$2"

    if [ ! -d "$src" ]; then
        LOG "Skipping (not found): $src"
        return 0
    fi

    mkdir_safe "$dst"

    # Prefer cp -a if supported; fall back to cp -r
    if cp -a "$src/." "$dst/" 2>/dev/null; then
        LOG "Copied: $src -> $dst (cp -a)"
        return 0
    fi

    if cp -r "$src/." "$dst/" 2>/dev/null; then
        LOG "Copied: $src -> $dst (cp -r)"
        return 0
    fi

    LOG "ERROR: Copy failed: $src -> $dst"
    return 1
}

# -----------------------
# Start
# -----------------------
LOG "Starting USB mount + optional loot transfer"

mkdir_safe "$MOUNTPOINT"

if ! is_mounted; then
    DEV="$(find_usb_partition || true)"
    if [ -z "$DEV" ]; then
        LOG "ERROR: No USB partition device found"
        ERROR_DIALOG "No USB storage detected.\n\nInsert a USB flash drive and try again.\n\nIf inserted and still not detected, the device name may differ (see script function find_usb_partition())."
        exit 1
    fi

    LOG "Found USB partition candidate: $DEV"
    if mount "$DEV" "$MOUNTPOINT" 2>/dev/null; then
        LOG "USB mounted successfully at $MOUNTPOINT"
    else
        LOG "ERROR: Failed to mount $DEV at $MOUNTPOINT"
        ERROR_DIALOG "Failed to mount USB.\n\nCommon causes:\n- Unsupported filesystem (use ext4/exFAT/FAT32)\n- Partition not /dev/sda1 on this firmware\n\nAdjust find_usb_partition() if needed."
        exit 1
    fi
else
    LOG "USB already mounted at $MOUNTPOINT"
fi

# Create destination root on USB
mkdir_safe "$USB_ROOT"
if [ ! -d "$USB_ROOT" ]; then
    LOG "ERROR: Unable to create USB root folder: $USB_ROOT"
    ERROR_DIALOG "USB mounted but could not create folders on it.\n\nPossible cause: read-only filesystem or permissions."
    exit 1
fi

LOG "USB root ready: $USB_ROOT"

# Prompt user whether to transfer
choice=$(TEXT_PICKER "Transfer all loot to USB? (YES/NO)" "NO")
case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG "User cancelled"
        exit 0
        ;;
    $DUCKYSCRIPT_REJECTED)
        LOG "Dialog rejected - defaulting to NO"
        choice="NO"
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG "Dialog error - defaulting to NO"
        choice="NO"
        ;;
esac

choice_upper="$(echo "$choice" | tr '[:lower:]' '[:upper:]')"
if [ "$choice_upper" != "YES" ]; then
    LOG "No transfer selected. USB is mounted and ready."
    LOG "Mountpoint: $MOUNTPOINT"
    LOG "USB Root: $USB_ROOT"
    exit 0
fi

# Second confirmation (safety)
confirm=$(TEXT_PICKER "CONFIRM transfer? Type YES to proceed" "NO")
case $? in
    $DUCKYSCRIPT_CANCELLED)
        LOG "User cancelled"
        exit 0
        ;;
    $DUCKYSCRIPT_REJECTED)
        LOG "Dialog rejected - cancelling transfer"
        exit 0
        ;;
    $DUCKYSCRIPT_ERROR)
        LOG "Dialog error - cancelling transfer"
        exit 0
        ;;
esac

confirm_upper="$(echo "$confirm" | tr '[:lower:]' '[:upper:]')"
if [ "$confirm_upper" != "YES" ]; then
    LOG "Transfer cancelled (confirmation not YES)"
    exit 0
fi

# Transfer
TS="$(date +%Y-%m-%d_%H%M%S)"
DEST="$USB_ROOT/loot_transfer_${TS}"
mkdir_safe "$DEST"

LOG "Transferring loot to: $DEST"
fail_count=0

for src in $LOOT_SOURCES; do
    base="$(echo "$src" | sed 's#^/##' | tr '/' '_')"
    dst="$DEST/$base"
    if ! copy_dir_if_exists "$src" "$dst"; then
        fail_count=$((fail_count + 1))
    fi
done

# Write manifest
MANIFEST="$DEST/manifest.txt"
{
    echo "Loot transfer manifest"
    echo "Timestamp: $(date -Iseconds)"
    echo "Mountpoint: $MOUNTPOINT"
    echo "Destination: $DEST"
    echo "Sources: $LOOT_SOURCES"
    echo "Failures: $fail_count"
} > "$MANIFEST" 2>/dev/null

if [ "$fail_count" -eq 0 ]; then
    LOG "Loot transfer complete!"
    LOG "Saved to: $DEST"
else
    LOG "Loot transfer completed with warnings (failures=$fail_count)"
    LOG "Saved to: $DEST"
    ERROR_DIALOG "Transfer completed with warnings.\n\nDestination:\n$DEST\n\nFailures: $fail_count\n\nSome files may not have copied."
fi
