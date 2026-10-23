#!/bin/bash
# Setup key for 2 Way Pager system
# setup_ssh.sh — one-time SSH key auth setup between macOS and hak5 WiFi Pineapple Pager 
# Run this once before starting ipager.py(iPager - macOS iMessage relay)
# Pager must be reachable (either as AP or on shared LAN)

PAGER_HOST="${1:-172.16.52.1}"
PAGER_USER="root"
KEY_PATH="$HOME/.ssh/pager_rsa"

echo "[*] iPager - iMessage Relay — SSH Setup"
echo "    Pager: $PAGER_USER@$PAGER_HOST"
echo ""

# Generate dedicated key if it doesn't exist
if [ ! -f "$KEY_PATH" ]; then
    echo "[*] Generating SSH key at $KEY_PATH ..."
    ssh-keygen -t rsa -b 2048 -f "$KEY_PATH" -N "" -C "ipager"
    echo "[✓] Key generated"
else
    echo "[*] Key already exists at $KEY_PATH — skipping generation"
fi

# Copy public key to Pager
echo "[*] Copying public key to Pager (password prompt expected) ..."
ssh-copy-id -i "$KEY_PATH.pub" -o StrictHostKeyChecking=no "$PAGER_USER@$PAGER_HOST"

if [ $? -eq 0 ]; then
    echo ""
    echo "[✓] Auth configured. Test with:"
    echo "    ssh -i $KEY_PATH $PAGER_USER@$PAGER_HOST 'echo OK'"
    echo ""
    echo "[*] Then start the relay:"
    echo "    python3 ipager.py"
else
    echo ""
    echo "[!] ssh-copy-id failed. Is the Pager reachable at $PAGER_HOST?"
    echo "    Try: ssh root@$PAGER_HOST"
fi
