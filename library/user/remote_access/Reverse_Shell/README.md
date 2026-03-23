# Reverse Shell (SSH Reverse Tunnel)

This payload creates an **SSH reverse tunnel** from a remote host back
to the device. It is designed to run within the DuckyScript/Payload
framework and uses `sshpass` for non-interactive authentication.

------------------------------------------------------------------------

## Features

-   Automatic installation check for `sshpass` (with user confirmation)
-   Persistent storage of:
    -   Remote host username
    -   Remote host IP
    -   Remote host password
-   Remote host reachability verification (ICMP + SSH port check)
-   Configurable remote and local ports
-   Detection of an already running reverse tunnel
-   Option to kill an existing tunnel
-   Tunnel health verification after startup
-   Displays exact command/URL to use on the remote host
-   Interactive prompts with confirmation dialogs

------------------------------------------------------------------------

## Requirements

-   Compatible Payload/DuckyScript environment
-   `sshpass` (auto-installed if missing)
-   SSH access to the remote host
-   Network connectivity between device and remote host

------------------------------------------------------------------------

## Stored Credential Paths

/mmc/root/payloads/user/remote_access/Reverse_Shell/remote_host_name.txt\
/mmc/root/payloads/user/remote_access/Reverse_Shell/remote_host_IP.txt\
/mmc/root/payloads/user/remote_access/Reverse_Shell/remote_host_passwd.txt

------------------------------------------------------------------------

## Port Configuration

You will be prompted to enter:

-   **Remote Port**
-   **Local Port**

### Examples

**SSH Reverse Access** - Remote Port: 7000 - Local Port: 22

**Virtual Pager Access** - Remote Port: 8080 - Local Port: 1471

------------------------------------------------------------------------

## How It Works

### 1. Dependency Check

Verifies whether `sshpass` is installed and prompts to install via
`opkg` if missing.

### 2. Collects Connection Details

Prompts for: - Remote host username (default: root if saved) - Remote
host IP - Remote host password - Remote port - Local port

All values are saved for reuse.

### 3. Reachability Check

Checks: - ICMP ping - OR SSH port 22 via netcat

Stops if unreachable.

### 4. Existing Tunnel Detection

Checks for: ssh -fN -R
`<REMOTE_PORT>`:localhost:`<LOCAL_PORT>`

Allows user to kill or keep existing tunnel.

### 5. Starts Reverse Tunnel

sshpass -p "`<password>`"\
ssh -fN\
-R `<REMOTE_PORT>`:localhost:`<LOCAL_PORT>`\
-o ExitOnForwardFailure=yes\
-o ServerAliveInterval=60\
-o ServerAliveCountMax=5\
-o StrictHostKeyChecking=no\
`<username>`@`<remote_ip>`

### 6. Tunnel Health Verification

Confirms process is running and displays remote usage instructions.

------------------------------------------------------------------------

## Remote Host Usage

### SSH Mode (7000 -\> 22)

Run on remote host: ssh root@localhost -p 7000

### Virtual Pager Mode (8080 -\> 1471)

Open in browser on remote host: http://localhost:8080

------------------------------------------------------------------------

## Custom Ports

SSH: ssh root@localhost -p `<REMOTE_PORT>`

Web: http://localhost:8080

------------------------------------------------------------------------

## Behavior Notes

-   Uses -fN (background, no command execution)
-   Keepalive options enabled
-   StrictHostKeyChecking disabled for automation
-   Clean exit on cancel/reject/error
