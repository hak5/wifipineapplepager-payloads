#!/bin/bash
## Title: Export Handshakes
## Auther : BlackGrouse
## Version: 1.2

## This file can be edited to also do the loot directory etc.


# 1. FIND THE DRIVE
USB_RAW=$(lsblk -nlo NAME,TYPE | grep 'part' | grep -v 'mmcblk' | awk '{print $1}' | head -n1)

if [ -z "$USB_RAW" ]; then
    ERROR_DIALOG "Error" "No USB found."
    exit 1
fi

USB_DEV="/dev/$USB_RAW"
MOUNT_DIR="/tmp/export"
mkdir -p "$MOUNT_DIR"

# 2. MOUNT WITHOUT LOCKING
# We use 'noatime' to reduce the number of writes to the USB
M_ID=$(START_SPINNER "Connecting...")
mount -o sync,noatime "$USB_DEV" "$MOUNT_DIR" 2>/dev/null
STOP_SPINNER "$M_ID"

# 3. FAST COPY (Renaming Colons)
HANDSHAKE_SRC="/root/loot/handshakes"
TIMESTAMP=$(date +%H%M%S)
EXPORT_DIR="$MOUNT_DIR/HS_$TIMESTAMP"
mkdir -p "$EXPORT_DIR"

C_ID=$(START_SPINNER "Writing...")
for FILE in "$HANDSHAKE_SRC"/*; do
    [ -e "$FILE" ] || continue
    SAFE_NAME=$(basename "$FILE" | tr ':' '_')
    cp "$FILE" "$EXPORT_DIR/$SAFE_NAME"
done
# Force write to hardware
sync
STOP_SPINNER "$C_ID"

# 4. THE BYPASS
# Instead of a standard unmount which hangs, we 'lazy' detach 
# and immediately tell the Pager UI to move on.
cd /
umount -l "$MOUNT_DIR" 2>/dev/null

# 5. FORCE UI EXIT
# We show one final prompt. Once you click 'OK', the script ends.
PROMPT "Export Done" "Files saved to HS_$TIMESTAMP. You can pull the USB now."

# Skip the confirmation dialogs to prevent the UI from getting stuck
# in a loop. Just exit the script cleanly.
exit 0
