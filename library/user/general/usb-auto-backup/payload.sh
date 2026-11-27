#!/bin/bash
# Title: USB Auto Backup
# Description: Mount USB, choose backup type, then safely unmount
# Author: RootJunky
# Version: 2.3

MOUNTPOINT="/mnt/usb"
DEST="$MOUNTPOINT/pager"
LOGS="/var/log/pager_backup.log"

log() {
    echo "$(date) - $1" >> "$LOGS"
}

LOG "=== Backup Job Started ==="
log "=== Backup Job Started ==="

# -------------------------
# LIST PICKER MENU
# -------------------------
__option=$(LIST_PICKER "Backup Type" "Full Backup" "Loot Only" "Payloads Only" "Exit" "Full Backup") || exit 0

case "${__option}" in
  "Full Backup")
     SRC="/root"
     NAME="full"
     ;;
  "Loot Only")
     SRC="/root/loot"
     NAME="loot"
     ;;
  "Payloads Only")
     SRC="/root/payloads"
     NAME="payloads"
     ;;
  *)
     LOG "User exited"
     log "User exited"
     exit 0
esac

LOG "Selected: $NAME"
log "Selected: $NAME ($SRC)"

# -------------------------
# VERIFY SOURCE EXISTS
# -------------------------
if [ ! -d "$SRC" ]; then
    LOG "Source Missing"
    log "ERROR: Source directory $SRC does not exist"
    exit 1
fi

# -------------------------
# MOUNT USB
# -------------------------
mkdir -p "$MOUNTPOINT"

DEVICE=$(blkid | grep -o '/dev/sd[a-z][0-9]\+' | head -n 1)

if [ -z "$DEVICE" ]; then
    LOG "No USB Found"
    log "ERROR: No USB device found"
    exit 1
fi

LOG "USB detected"
log "USB device detected: $DEVICE"

if mount | grep -q "^$DEVICE "; then
    LOG "Already mounted"
    log "Device already mounted"
else
    mount "$DEVICE" "$MOUNTPOINT"
    if [ $? -ne 0 ]; then
        LOG "Mount failed"
        log "ERROR: Failed to mount $DEVICE"
        exit 1
    fi
    LOG "Mounted"
    log "Mounted $DEVICE at $MOUNTPOINT"
fi

# -------------------------
# PREP DESTINATION
# -------------------------
mkdir -p "$DEST"

DATE=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="$DEST/${NAME}_backup_$DATE.tar.gz"

LOG "Backing up please wait..."
log "Starting backup..."

# -------------------------
# RUN BACKUP (FIXED)
# -------------------------
tar -czhf "$BACKUP_FILE" -C "$SRC" . >> "$LOGS" 2>&1

if [ $? -eq 0 ]; then
    LOG "Backup Complete"
    log "SUCCESS: Backup created at $BACKUP_FILE"
else
    LOG "Backup Failed"
    log "ERROR: Backup failed"
    umount "$MOUNTPOINT"
    exit 1
fi

# -------------------------
# SAFE UNMOUNT
# -------------------------
sync

umount "$MOUNTPOINT"
if [ $? -eq 0 ]; then
    LOG "USB Removed Safe"
    log "USB safely unmounted"
else
    LOG "Unmount Failed"
    log "WARNING: Failed to unmount USB"
fi

LOG "=== Backup Done ==="
log "=== Backup Job Finished ==="

exit 0