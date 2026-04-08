#!/bin/bash
# Title: wifi loot viewer
# Author: f3bandit
# Description: Simple xml viewer that unzips all zip files in /mmc/root/loot/wifi then lists all xml files in /mmc/root/loot/wifi
# to be viewed thru the log viewer.
# Version: 1.2

TARGET_DIR="/mmc/root/loot/wifi"
TMP_FILE="/tmp/pager_xml_view.txt"

# ---- sanity checks ----
if [ ! -d "$TARGET_DIR" ]; then
    ERROR_DIALOG "Directory not found"
    exit 0
fi

if ! command -v unzip >/dev/null 2>&1; then
    ERROR_DIALOG "unzip not installed"
    exit 0
fi

# ---- unzip all zip files in target dir ----
START_SPINNER

FOUND_ZIP=0

while IFS= read -r -d '' zipfile; do
    FOUND_ZIP=1
    unzip -o "$zipfile" -d "$TARGET_DIR" >/dev/null 2>&1
done < <(find "$TARGET_DIR" -maxdepth 1 -type f -iname "*.zip" -print0)

STOP_SPINNER

# ---- completion popup, user dismisses and continues ----
PROMPT "All loot files processed!"

# ---- build XML file list ----
mapfile -t XML_FILES < <(find "$TARGET_DIR" -maxdepth 1 -type f -iname "*.xml" | sort)

if [ "${#XML_FILES[@]}" -eq 0 ]; then
    ERROR_DIALOG "No XML files found"
    exit 0
fi

build_picker_args() {
    local title="$1"
    local default="$2"
    shift 2

    local args=()
    args+=("$title")

    local item
    for item in "$@"; do
        args+=("$item")
    done

    args+=("$default")
    printf '%s\n' "${args[@]}"
}

OPTIONS=()
for f in "${XML_FILES[@]}"; do
    OPTIONS+=("$(basename "$f")")
done

DEFAULT="${OPTIONS[0]}"

mapfile -t PICKER_ARGS < <(build_picker_args "XML Viewer" "$DEFAULT" "${OPTIONS[@]}")
SELECTED=$(LIST_PICKER "${PICKER_ARGS[@]}") || exit 0

SELECTED_PATH=""
for f in "${XML_FILES[@]}"; do
    if [ "$(basename "$f")" = "$SELECTED" ]; then
        SELECTED_PATH="$f"
        break
    fi
done

if [ -z "$SELECTED_PATH" ] || [ ! -f "$SELECTED_PATH" ]; then
    ERROR_DIALOG "Selected file missing"
    exit 0
fi

# ---- format XML if xmllint exists, else copy raw ----
START_SPINNER
if command -v xmllint >/dev/null 2>&1; then
    xmllint --format "$SELECTED_PATH" > "$TMP_FILE" 2>/dev/null || cp "$SELECTED_PATH" "$TMP_FILE"
else
    cp "$SELECTED_PATH" "$TMP_FILE"
fi
STOP_SPINNER

# ---- show selected XML in log viewer ----
LOG clear
LOG blue "XML Viewer"
LOG blue "File: $SELECTED"
LOG blue "Path: $SELECTED_PATH"
LOG blue "--------------------------------"

while IFS= read -r line; do
    LOG "$line"
done < "$TMP_FILE"

exit 0
