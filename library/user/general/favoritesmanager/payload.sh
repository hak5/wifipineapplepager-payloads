#!/usr/bin/env bash
# title: Favorites Manager
# Description: Add, remove, or update payloads in the favorites folder
# Author: RootJunky
# Version: 4

BASE_DIR="/root/payloads/user"
DEST_DIR="/root/payloads/user/1-favorites"

CONFIRMATION_DIALOG "Manage your favorites: Add, Remove, or Update payloads"

mkdir -p "$DEST_DIR"

while true; do

  LOG
  LOG "What would you like to do?"
  LOG "--------------------------"

  ACTION=$(LIST_PICKER "Favorites Manager" \
    "Add payload to favorites" \
    "Remove from favorites" \
    "Update favorites" \
    "Exit payload" "Add payload to favorites") || exit 0

  #################################
  # EXIT
  #################################
  case "$ACTION" in
    "Exit payload")
      LOG "Exiting Favorites Manager."
      exit 0
      ;;
  esac

  #################################
  # UPDATE FAVORITES
  #################################
  if [ "$ACTION" = "Update favorites" ]; then

    CONFIRMATION_DIALOG "If payloads in the main directory have been updated with github then this will update the payloads in favorites"

    mapfile -t FAVORITES < <(
      find "$DEST_DIR" -mindepth 1 -maxdepth 1 -type d
    )

    if [ ${#FAVORITES[@]} -eq 0 ]; then
      ALERT "Favorites folder is empty."
      continue
    fi

    LOG
    LOG "Updating favorites..."
    LOG "--------------------"

    for FAVORITE in "${FAVORITES[@]}"; do
      NAME=$(basename "$FAVORITE")

      SOURCE=$(find "$BASE_DIR" -type d -name "$NAME" \
        ! -path "$DEST_DIR/*" | head -n 1)

      if [ -z "$SOURCE" ]; then
        ALERT "Source not found for '$NAME'"
        continue
      fi

      rm -rf "$FAVORITE"
      cp -r "$SOURCE" "$DEST_DIR/"

      LOG "Updated '$NAME'"
    done

    LOG
    LOG "Favorites update complete."
    continue
  fi

  #################################
  # REMOVE FROM FAVORITES
  #################################
  if [ "$ACTION" = "Remove from favorites" ]; then

    mapfile -t FAVORITES < <(
      find "$DEST_DIR" -mindepth 1 -maxdepth 1 -type d
    )

    if [ ${#FAVORITES[@]} -eq 0 ]; then
      ALERT "Favorites folder is empty."
      continue
    fi

    OPTIONS=()
    declare -A MAP

    for DIR in "${FAVORITES[@]}"; do
      NAME=$(basename "$DIR")
      OPTIONS+=("$NAME")
      MAP["$NAME"]="$DIR"
    done

    CHOICE=$(LIST_PICKER "Remove Favorite" "${OPTIONS[@]}") || continue

    TARGET="${MAP[$CHOICE]}"

    rm -rf "$TARGET"
    LOG "🗑️ '$CHOICE' removed from favorites."
    continue
  fi

  #################################
  # ADD TO FAVORITES
  #################################
  if [ "$ACTION" = "Add payload to favorites" ]; then

    mapfile -t CATEGORIES < <(
      find "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d \
      ! -path "$DEST_DIR"
    )

    if [ ${#CATEGORIES[@]} -eq 0 ]; then
      ALERT "No folders found in $BASE_DIR"
      continue
    fi

    CAT_OPTIONS=()
    declare -A CAT_MAP

    for DIR in "${CATEGORIES[@]}"; do
      NAME=$(basename "$DIR")
      CAT_OPTIONS+=("$NAME")
      CAT_MAP["$NAME"]="$DIR"
    done

    CAT_CHOICE=$(LIST_PICKER "Select Category" "${CAT_OPTIONS[@]}") || continue
    SELECTED_CATEGORY="${CAT_MAP[$CAT_CHOICE]}"

    mapfile -t PAYLOADS < <(
      find "$SELECTED_CATEGORY" -mindepth 1 -maxdepth 1 -type d
    )

    if [ ${#PAYLOADS[@]} -eq 0 ]; then
      ALERT "No payload folders found in $CAT_CHOICE"
      continue
    fi

    PAYLOAD_OPTIONS=()
    declare -A PAYLOAD_MAP

    for DIR in "${PAYLOADS[@]}"; do
      NAME=$(basename "$DIR")
      PAYLOAD_OPTIONS+=("$NAME")
      PAYLOAD_MAP["$NAME"]="$DIR"
    done

    PAYLOAD_CHOICE=$(LIST_PICKER "Select Payload" "${PAYLOAD_OPTIONS[@]}") || continue
    SELECTED_PAYLOAD="${PAYLOAD_MAP[$PAYLOAD_CHOICE]}"

    LOG
    LOG "Copying '$PAYLOAD_CHOICE' to favorites..."

    cp -r "$SELECTED_PAYLOAD" "$DEST_DIR/"

    LOG "'$PAYLOAD_CHOICE' added to favorites."
    continue
  fi

done
