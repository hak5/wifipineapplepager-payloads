#!/bin/bash
# Title: Run Payloads In Terminal
# Author: RootJunky
# Description: Installs run.sh and shim file so payloads can be executed in the terminal.
# Version: 1.0

CONFIRMATION_DIALOG "This will setup the files need to run payloads from terminal"
PAYLOAD_DIR="$PWD"

FILES=(
  "run.sh"
  "pager_ducky_shim.sh"
)

for file in "${FILES[@]}"; do
  if [ -f "$PAYLOAD_DIR/$file" ]; then
    cp "$PAYLOAD_DIR/$file" /usr/bin/
    chmod +x "/usr/bin/$file"
    LOG "[+] Installed $file to /usr/bin"
  else
    LOG "[-] Missing file: $file"
  fi
done

LOG "[✓] Setup complete"
CONFIRMATION_DIALOG "USAGE: run.sh payload.sh"
