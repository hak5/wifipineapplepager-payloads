#!/bin/bash
# title: Favorites Manager
# Description: Add, remove, or update payloads in the favorites folder
# Author: RootJunky
# Version: 3.2

BASE_DIR="/root/payloads/user"
DEST_DIR="/root/payloads/user/1-favorites"

CONFIRMATION_DIALOG "Manage your favorites: Add, Remove, or Update payloads"

mkdir -p "$DEST_DIR"

while true; do

  LOG
  LOG "What would you like to do?"
  LOG "--------------------------"
  LOG "1) Add payload to favorites"
  LOG "2) Remove payload from favorites"
  LOG "3) Update favorites"
  LOG "4) Exit payload"

  LOG green "Press the GREEN button once ready"
  WAIT_FOR_BUTTON_PRESS A

  ACTION=$(NUMBER_PICKER "Enter a number" 1)

  #################################
  # EXIT
  #################################
  if [ "$ACTION" = "4" ]; then
    LOG "Exiting Favorites Manager."
    exit 0
  fi

  #################################
  # UPDATE FAVORITES
  #################################
  
 

  if [ "$ACTION" = "3" ]; then

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
  if [ "$ACTION" = "2" ]; then

    mapfile -t FAVORITES < <(
      find "$DEST_DIR" -mindepth 1 -maxdepth 1 -type d
    )

    if [ ${#FAVORITES[@]} -eq 0 ]; then
      ALERT "Favorites folder is empty."
      continue
    fi

    LOG
    LOG "Select a favorite to remove:"
    LOG "-----------------------------"

    for i in "${!FAVORITES[@]}"; do
      LOG "$((i+1))) $(basename "${FAVORITES[$i]}")"
    done

    LOG green "Press the GREEN button once ready"
    WAIT_FOR_BUTTON_PRESS A

    RM_CHOICE=$(NUMBER_PICKER "Enter a number" 1)

    if ! [[ "$RM_CHOICE" =~ ^[0-9]+$ ]] || ((RM_CHOICE < 1 || RM_CHOICE > ${#FAVORITES[@]})); then
      ALERT "Invalid selection."
      continue
    fi

    TARGET="${FAVORITES[$((RM_CHOICE-1))]}"
    NAME=$(basename "$TARGET")

    rm -rf "$TARGET"
    LOG "🗑️ '$NAME' removed from favorites."
    continue
  fi

  #################################
  # ADD TO FAVORITES
  #################################

  mapfile -t CATEGORIES < <(
    find "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d \
    ! -path "$DEST_DIR"
  )

  if [ ${#CATEGORIES[@]} -eq 0 ]; then
    ALERT "No folders found in $BASE_DIR"
    continue
  fi

  LOG
  LOG "Select a category:"
  LOG "------------------"

  for i in "${!CATEGORIES[@]}"; do
    LOG "$((i+1))) $(basename "${CATEGORIES[$i]}")"
  done

  LOG green "Press the GREEN button once ready"
  WAIT_FOR_BUTTON_PRESS A

  CAT_CHOICE=$(NUMBER_PICKER "Enter a number" 1)

  if ! [[ "$CAT_CHOICE" =~ ^[0-9]+$ ]] || ((CAT_CHOICE < 1 || CAT_CHOICE > ${#CATEGORIES[@]})); then
    ALERT "Invalid selection."
    continue
  fi

  SELECTED_CATEGORY="${CATEGORIES[$((CAT_CHOICE-1))]}"

  mapfile -t PAYLOADS < <(
    find "$SELECTED_CATEGORY" -mindepth 1 -maxdepth 1 -type d
  )

  if [ ${#PAYLOADS[@]} -eq 0 ]; then
    ALERT "No payload folders found in $(basename "$SELECTED_CATEGORY")"
    continue
  fi

  LOG
  LOG "Select a payload to favorite:"
  LOG "-----------------------------"

  for i in "${!PAYLOADS[@]}"; do
    LOG "$((i+1))) $(basename "${PAYLOADS[$i]}")"
  done

  LOG green "Press the GREEN button once ready"
  WAIT_FOR_BUTTON_PRESS A

  PAYLOAD_CHOICE=$(NUMBER_PICKER "Enter a number" 1)

  if ! [[ "$PAYLOAD_CHOICE" =~ ^[0-9]+$ ]] || ((PAYLOAD_CHOICE < 1 || PAYLOAD_CHOICE > ${#PAYLOADS[@]})); then
    ALERT "Invalid selection."
    continue
  fi

  SELECTED_PAYLOAD="${PAYLOADS[$((PAYLOAD_CHOICE-1))]}"
  PAYLOAD_NAME=$(basename "$SELECTED_PAYLOAD")

  LOG
  LOG "Copying '$PAYLOAD_NAME' to favorites..."

  cp -r "$SELECTED_PAYLOAD" "$DEST_DIR/"

  LOG "'$PAYLOAD_NAME' added to favorites."


done
