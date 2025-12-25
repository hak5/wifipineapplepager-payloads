#!/bin/bash
# Title: Log Viewer
# Author: Brandon Starkweather

# --- CONFIG ---
# Defaulting directly to LOOT as requested
TARGET_PATH="/root/loot"

# --- 1. INTRO & FOLDER SELECTION ---
# We skip the Source Select and go straight to sub-folders in Loot

if [ ! -d "$TARGET_PATH" ]; then
    PROMPT "ERROR: Loot dir not found."
    exit 1
fi
cd "$TARGET_PATH"

SUB_DIRS=$(ls -d */ 2>/dev/null)
if [ -z "$SUB_DIRS" ]; then
    PROMPT "EMPTY LOOT
    
No folders found
in /root/loot."
    exit 1
fi

count=1
LIST_STR=""
for d in $SUB_DIRS; do
    clean_name=$(echo "$d" | sed 's|/$||')
    LIST_STR="$LIST_STR $count:$clean_name"
    count=$((count + 1))
done

PROMPT "1 Ring 2 Find Them

SELECT LOOT FOLDER:

$LIST_STR

Press OK."

DIR_ID=$(NUMBER_PICKER "Enter Folder ID:" 1)

CURRENT_COUNT=1
TARGET_SUB=""
for d in $SUB_DIRS; do
    if [ "$CURRENT_COUNT" -eq "$DIR_ID" ]; then
        TARGET_SUB="$d"
        break
    fi
    CURRENT_COUNT=$((CURRENT_COUNT + 1))
done

if [ -z "$TARGET_SUB" ]; then exit 1; fi
cd "$TARGET_SUB"

# --- 2. FILE SELECTION ---
FILES=$(ls *.txt *.log *.nmap *.gnmap *.xml 2>/dev/null)

if [ -z "$FILES" ]; then
    PROMPT "NO FILES
    
No logs/scans found."
    exit 1
fi

count=1
LIST_STR=""
for f in $FILES; do
    LIST_STR="$LIST_STR $count:$f"
    count=$((count + 1))
done

PROMPT "SELECT FILE:

$LIST_STR

Press OK."

FILE_ID=$(NUMBER_PICKER "Enter File ID:" 1)

CURRENT_COUNT=1
TARGET_FILE=""
for f in $FILES; do
    if [ "$CURRENT_COUNT" -eq "$FILE_ID" ]; then
        TARGET_FILE="$f"
        break
    fi
    CURRENT_COUNT=$((CURRENT_COUNT + 1))
done

if [ -z "$TARGET_FILE" ]; then exit 1; fi

# --- 3. VIEW MODE SELECTION (SWAPPED) ---
# Default (1) is now Parsed/Color
PROMPT "VIEW MODE

1. Parsed Log (Color)
2. Raw Log (Standard)

Press OK."

MODE_ID=$(NUMBER_PICKER "Select Mode" 1)

PROMPT "LOADING LOG...
$TARGET_FILE

Press OK to Generate."

LOG blue "=== FILE: $TARGET_FILE ==="

# --- 4. GENERATION ENGINE ---

if [ "$MODE_ID" -eq 1 ]; then
    # === PARSED MODE (DECONSTRUCTOR) - NOW DEFAULT ===
    while IFS= read -r line; do
        if [ -z "$line" ]; then continue; fi

        # A. TIMESTAMP (Yellow)
        TS=$(echo "$line" | grep -oE "[0-9]{2}:[0-9]{2}:[0-9]{2}")
        if [ -n "$TS" ]; then
            LOG yellow "TIME: $TS"
        fi

        # B. STATUS (Green/Red)
        if echo "$line" | grep -qiE "error|down|closed|fail|refused|denied|critical"; then
            LOG red "STATUS: FAILURE"
        elif echo "$line" | grep -qiE "open|up|success|connected|established|200 OK"; then
            LOG green "STATUS: SUCCESS"
        fi

        # C. ADDRESS (Blue) - IP or MAC
        IP=$(echo "$line" | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}")
        MAC=$(echo "$line" | grep -oE "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}")
        
        if [ -n "$IP" ]; then
            LOG blue "ADDR: $IP"
        fi
        if [ -n "$MAC" ]; then
            LOG blue "ADDR: $MAC"
        fi

        # D. INFO (White)
        CLEAN_MSG="$line"
        if [ -n "$TS" ]; then CLEAN_MSG=$(echo "$CLEAN_MSG" | sed "s/$TS//g"); fi
        if [ -n "$IP" ]; then CLEAN_MSG=$(echo "$CLEAN_MSG" | sed "s/$IP//g"); fi
        if [ -n "$MAC" ]; then CLEAN_MSG=$(echo "$CLEAN_MSG" | sed "s/$MAC//g"); fi
        
        CLEAN_MSG=$(echo "$CLEAN_MSG" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
        if [ -n "$CLEAN_MSG" ]; then
            LOG "INFO: $CLEAN_MSG"
        fi

        LOG "---"

    done < "$TARGET_FILE"

elif [ "$MODE_ID" -eq 2 ]; then
    # === RAW MODE ===
    while IFS= read -r line; do
        LOG "$line"
    done < "$TARGET_FILE"

else
    LOG red "INVALID MODE SELECTED"
fi

LOG blue "=== END OF FILE ==="

exit 0