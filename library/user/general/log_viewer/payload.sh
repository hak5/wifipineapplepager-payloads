#!/bin/bash
# Title: Log Viewer
# Author: Brandon Starkweather
# Description: High-performance log analysis tool for the WiFi Pineapple Pager.
# Version: 1.0

# --- CONFIG ---
TARGET_PATH="/root/loot"
RENDER_SCRIPT="/tmp/log_render.sh"

# --- 1. ARGUMENT CHECK ---

# Help Menu
if [ "$1" == "-help" ] || [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    echo "
LOG VIEWER HELP
---------------------------
Usage:   ./log_viewer.sh [file_path] [mode]

Arguments:
  file_path  : Full path to the log file you want to view.
  mode       : (Optional) 1 = Parsed (Color), 2 = Raw (Standard).
               Default is 1 (Parsed).

Examples:
  ./log_viewer.sh /root/loot/scan.txt 2   (View raw text)
  ./log_viewer.sh /root/loot/scan.txt 1   (View parsed color)
  ./log_viewer.sh                         (Run interactive menu)
"
    exit 0
fi

# Headless Mode Check
if [ -n "$1" ] && [ -f "$1" ]; then
    # === HEADLESS MODE ===
    TARGET_FILE="$1"
    
    # Optional: Second arg sets Mode (1=Parsed, 2=Raw). Default to 1 (Parsed).
    MODE_ID=${2:-1}
    
    # Headless always processes the full file (no tail prompt)
    USE_TAIL=0
    
    # Visual Confirmation
    LOG blue "Headless Load: $(basename "$TARGET_FILE")"

else
    # === INTERACTIVE MODE ===
    
    if [ ! -d "$TARGET_PATH" ]; then
        PROMPT "ERROR: Loot dir not found."
        exit 1
    fi
    cd "$TARGET_PATH"

    # BusyBox-Safe Directory List
    DIRS_RAW=$(ls -F | grep '/$' | sed 's|/$||')

    if [ -z "$DIRS_RAW" ]; then
        PROMPT "EMPTY LOOT
        
No folders found
in /root/loot."
        exit 1
    fi

    IFS=$'\n' read -rd '' -a DIR_ARRAY <<< "$DIRS_RAW"

    # --- 2. SELECT FOLDER (Vertical) ---
    LIST_STR=""
    count=1
    for d in "${DIR_ARRAY[@]}"; do
        LIST_STR="${LIST_STR}${count}: ${d}
"
        count=$((count + 1))
    done

    PROMPT "SELECT FOLDER:

$LIST_STR

Press Enter to Scroll."

    DIR_ID=$(NUMBER_PICKER "Enter Folder ID:" 1)
    if [ -z "$DIR_ID" ]; then exit 0; fi

    # Bounds Check
    if [ "$DIR_ID" -lt 1 ] || [ "$DIR_ID" -ge "$count" ]; then
        PROMPT "Invalid Selection."
        exit 1
    fi

    IDX=$((DIR_ID - 1))
    TARGET_SUB="${DIR_ARRAY[$IDX]}"
    cd "$TARGET_SUB"

    # --- 3. SELECT FILE ---
    FILES=$(ls *.txt *.log *.nmap *.gnmap *.xml 2>/dev/null)
    if [ -z "$FILES" ]; then
        PROMPT "NO FILES
        
No logs/scans found."
        exit 1
    fi

    count=1
    FILE_LIST_STR=""
    for f in $FILES; do
        FILE_LIST_STR="${FILE_LIST_STR}${count}: ${f}
"
        count=$((count + 1))
    done

    PROMPT "SELECT FILE:

$FILE_LIST_STR

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

    # --- 4. VIEW MODE ---
    PROMPT "VIEW MODE

1. Parsed Log (Color)
2. Raw Log (Standard)

Press OK."

    MODE_ID=$(NUMBER_PICKER "Select Mode" 1)

    # AUTO-LIMIT CHECK
    LINE_COUNT=$(wc -l < "$TARGET_FILE")
    USE_TAIL=0

    if [ "$LINE_COUNT" -gt 60 ]; then
        PROMPT "LARGE FILE
        
File has $LINE_COUNT lines.
Parsing all is slow.

View last 60 lines?
1. Yes (Fast)
2. No (Process All)"
        
        LIMIT_CHOICE=$(NUMBER_PICKER "Select Option" 1)
        if [ "$LIMIT_CHOICE" -eq 1 ]; then
            USE_TAIL=1
        fi
    fi

    PROMPT "RENDER LOG

Press OK to Start."
    
    # Add full path if we changed directories
    if [[ "$TARGET_FILE" != /* ]]; then
        TARGET_FILE="$(pwd)/$TARGET_FILE"
    fi
fi 
# === END OF INTERACTIVE BLOCK ===


# --- 5. COMPILED RENDER ENGINE (Shared) ---
LOG blue "=== FILE: $(basename "$TARGET_FILE") ==="

# Prepare Input Stream
if [ "$USE_TAIL" -eq 1 ]; then
    CMD="tail -n 60 \"$TARGET_FILE\""
else
    CMD="cat \"$TARGET_FILE\""
fi

if [ "$MODE_ID" -eq 1 ]; then
    # === PARSED MODE (PURE DATA) ===
    
    eval "$CMD" | awk '
    BEGIN { IGNORECASE = 1 }
    {
        line = $0;
        if (length(line) == 0) next;
        
        gsub(/"/, "\\\"", line);

        # 1. TIMESTAMP (Yellow)
        match(line, /[0-9]{2}:[0-9]{2}:[0-9]{2}/);
        if (RSTART > 0) {
            ts = substr(line, RSTART, RLENGTH);
            print "LOG yellow \"TIME: " ts "\"";
            sub(/[0-9]{2}:[0-9]{2}:[0-9]{2}/, "", line);
        }

        # 2. ADDRESS (Blue)
        while (match(line, /([0-9]{1,3}\.){3}[0-9]{1,3}/)) {
             ip = substr(line, RSTART, RLENGTH);
             print "LOG blue \"ADDR: " ip "\"";
             line = substr(line, 1, RSTART-1) substr(line, RSTART+RLENGTH);
        }
        while (match(line, /([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/)) {
             mac = substr(line, RSTART, RLENGTH);
             print "LOG blue \"ADDR: " mac "\"";
             line = substr(line, 1, RSTART-1) substr(line, RSTART+RLENGTH);
        }

        # 3. CREDENTIALS
        spacer_printed = 0;
        match(line, /(user(name)?|login)[:=][ \t]*[^ \t]+/);
        if (RSTART > 0) {
            full_match = substr(line, RSTART, RLENGTH);
            if (spacer_printed == 0) { print "LOG \" \""; spacer_printed = 1; }
            print "LOG green \"" full_match "\"";
            line = substr(line, 1, RSTART-1) substr(line, RSTART+RLENGTH);
        }
        match(line, /(pass(word)?|pwd|key)[:=][ \t]*[^ \t]+/);
        if (RSTART > 0) {
            full_match = substr(line, RSTART, RLENGTH);
            if (spacer_printed == 0) { print "LOG \" \""; spacer_printed = 1; }
            print "LOG red \"" full_match "\"";
            line = substr(line, 1, RSTART-1) substr(line, RSTART+RLENGTH);
        }

        # 4. INFO
        gsub(/^[ \t]+|[ \t]+$/, "", line);
        info_block = "";
        if (length(line) > 1) { info_block = "INFO: " line; }
        
        if (info_block != "") { print "LOG \" " info_block "\n---\""; }
        else { print "LOG \"---\""; }
    }
    ' > "$RENDER_SCRIPT"

    source "$RENDER_SCRIPT"
    rm "$RENDER_SCRIPT"

elif [ "$MODE_ID" -eq 2 ]; then
    # === RAW MODE (OPTIMIZED BATCH) ===
    
    eval "$CMD" | awk '
    BEGIN { buffer = ""; count = 0; }
    {
        gsub(/"/, "\\\"", $0);
        if (buffer != "") { buffer = buffer "\n" $0; } 
        else { buffer = $0; }
        count++;
        
        if (count >= 25) {
            print "LOG \"" buffer "\"";
            buffer = ""; count = 0;
        }
    }
    END { if (buffer != "") print "LOG \"" buffer "\""; }
    ' > "$RENDER_SCRIPT"
    
    source "$RENDER_SCRIPT"
    rm "$RENDER_SCRIPT"
fi

LOG blue "=== END OF FILE ==="
exit 0