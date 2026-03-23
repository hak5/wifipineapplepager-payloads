#!/bin/bash
# run_pager_payload.sh

PAYLOAD="$1"

if [ -z "$PAYLOAD" ] || [ ! -f "$PAYLOAD" ]; then
  echo "Usage: $0 payload.sh"
  exit 1
fi

echo "[+] Loading Pager Ducky shim"
source /usr/bin/pager_ducky_shim.sh

echo "[+] Running payload: $PAYLOAD"
echo "--------------------------------"

bash "$PAYLOAD"

echo "--------------------------------"
echo "[✓] Payload finished"
exit 0
