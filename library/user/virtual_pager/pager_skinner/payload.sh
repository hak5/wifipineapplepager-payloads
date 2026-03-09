#!/bin/bash
# Title: Pager Skinner
# Description: Installs and switches between Virtual Pager UI skins.
# Author: Amilious
# Version: 1.1   # <-- Increment this when you make significant changes
CURRENT_VERSION="1.1"   # <-- Must match the # Version: above

# Unique payload name for config storage
PAYLOAD_NAME="pagerskinner"

# Config options
CONFIG_SKIN="current_skin"
CONFIG_VERSION="payload_version"

# Get the needed directories
PAYLOAD_DIR="$(dirname "$(realpath "$0")")"   # Directory containing payload.sh
SKINS_DIR="/mmc/root/ui_skins"                # Where installed skins live
BACKUP_DIR="$SKINS_DIR/default"               # Default (backup) skin
SKINS_ZIP_DIR="$PAYLOAD_DIR/skins"            # Dedicated folder for skin .zip files

# Check if unzip is available
if ! command -v unzip >/dev/null 2>&1; then
    LOG red "unzip not found. Installing..."
    opkg update
    opkg install unzip
    if [ $? -ne 0 ]; then
        LOG red "Failed to install unzip. Aborting."
        exit 1
    fi
fi

# Ensure main directories exist
mkdir -p "$SKINS_DIR"
mkdir -p "$SKINS_ZIP_DIR"
first=0
version_updated=0

# Version Check & Update Prompt
STORED_VERSION=$(PAYLOAD_GET_CONFIG "$PAYLOAD_NAME" "$CONFIG_VERSION")
if [ -z "$STORED_VERSION" ] || [ "$STORED_VERSION" != "$CURRENT_VERSION" ]; then
    # First run or version upgrade
    if [ -n "$STORED_VERSION" ]; then
        PROMPT "Pager Skinner has been updated!\n\nOld version: $STORED_VERSION\nNew version: $CURRENT_VERSION\n\n• Now uses a dedicated 'skins/' folder for .zip files\n• Improved first-run experience\n• Better version tracking\n\nEnjoy the new features!"
        version_updated=1
    fi

    # Always update to current version
    PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" "$CONFIG_VERSION" "$CURRENT_VERSION"
fi

# Backup default UI images only if backup doesn't already exist or is empty
if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
    LOG "Backing up default UI images..."
    mkdir -p "$BACKUP_DIR"
    cp -r /pineapple/ui/images/* "$BACKUP_DIR/"
    LOG green "Backup completed."

    # First run: set current skin to default
    PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" "$CONFIG_SKIN" "default"
    first=1
else
    LOG "Default backup already exists. Skipping backup."
fi

# === Automatically install ALL .zip files from the dedicated skins folder ===
installed_count=0
if [ -d "$SKINS_ZIP_DIR" ]; then
    for zipfile in "$SKINS_ZIP_DIR"/*.zip; do
        [ -f "$zipfile" ] || continue

        skin_name="$(basename "$zipfile" .zip)"
        target_dir="$SKINS_DIR/$skin_name"

        if [ ! -d "$target_dir" ] || [ -z "$(ls -A "$target_dir" 2>/dev/null)" ]; then
            LOG "Installing skin from $(basename "$zipfile") ..."
            mkdir -p "$target_dir"
            unzip -o "$zipfile" -d "$target_dir" >/dev/null 2>&1
            if [ $? -eq 0 ]; then
                LOG green "Skin '$skin_name' installed successfully."
                ((installed_count++))
            else
                LOG red "Failed to extract $zipfile"
            fi
        fi
    done
fi

if [ $installed_count -gt 0 ]; then
    LOG green "$installed_count new skin(s) installed."
fi

# Get currently stored skin
CURRENT_SKIN=$(PAYLOAD_GET_CONFIG "$PAYLOAD_NAME" "$CONFIG_SKIN")
if [ -z "$CURRENT_SKIN" ]; then
    CURRENT_SKIN="default"
    PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" "$CONFIG_SKIN" "default"
fi
LOG "Currently loaded skin: $CURRENT_SKIN"

# Show first-run info (only on true first install)
if [ "$first" -eq 1 ]; then
    PROMPT "Welcome to Pager Skinner!\n\nA new directory has been created:\n$SKINS_DIR\n\nto store all your UI skins.\n\nTo add more skins:\nPlace .zip files in:\n$SKINS_ZIP_DIR\n\nThey will be automatically installed when you run this payload."
fi

# Build numbered skin list and prompt text
LOG "\n────────────────────────────────────"
LOG "── Available skins ─────────────────"
LOG "────────────────────────────────────"

SKINS=()
i=1
current_index=0
prompt_text=""

for dir in "$SKINS_DIR"/*/ ; do
    if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
        skin_name=$(basename "$dir")
        SKINS+=("$skin_name")

        if [ "$skin_name" = "$CURRENT_SKIN" ]; then
            line=" $i) $skin_name  ← current"
            LOG blue "$line"
            current_index=$i
        else
            line=" $i) $skin_name"
            LOG "$line"
        fi

        prompt_text="${prompt_text}${line}\n"
        ((i++))
    fi
done

LOG "────────────────────────────────────\n"

# Fallback
[ "$current_index" -eq 0 ] && current_index=1

# Show skin selection dialog
PROMPT "Select a skin:\n$prompt_text"

# Use NUMBER_PICKER with pre-selected current skin
SELECTED=$(NUMBER_PICKER "Skin Number (1-$((i-1)))" "$current_index") || {
    LOG red "Selection cancelled."
    exit 0
}

# Validate selection
if ! [[ "$SELECTED" =~ ^[0-9]+$ ]] || [ "$SELECTED" -lt 1 ] || [ "$SELECTED" -gt ${#SKINS[@]} ]; then
    LOG red "Invalid selection."
    exit 1
fi

# Apply the chosen skin
__spinnerid=$(START_SPINNER "Skinning...")

CHOSEN_SKIN="${SKINS[$((SELECTED-1))]}"
LOG "Applying skin: $CHOSEN_SKIN ..."

rm -rf /pineapple/ui/images/*
cp -r "$SKINS_DIR/$CHOSEN_SKIN"/* /pineapple/ui/images/

PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" "$CONFIG_SKIN" "$CHOSEN_SKIN"

STOP_SPINNER "$__spinnerid"
LOG green "Skin '$CHOSEN_SKIN' applied successfully!"
LOG "The Virtual Pager UI should now reflect the new skin.\nIf not, clear browser cache and hard reload!"