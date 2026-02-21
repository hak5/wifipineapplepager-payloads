# Reverse Shell (SSH Reverse Tunnel)

This payload creates an **SSH reverse tunnel** from a remote host back to a **WiFi Pineapple Pager**.  
It is designed to run on the Pineapple and uses `sshpass` for non-interactive authentication.

## Features

- Automatic installation check for `sshpass`
- Saves remote host credentials (user, IP, password) for reuse
- Reachability check before starting the tunnel
- Optional detection and termination of an existing tunnel
- Health check to confirm the reverse tunnel is active
- Displays the command needed on the remote host to connect back

## Requirements

- WiFi Pineapple Pager (with DuckyScript / Payload framework)
- `sshpass`
- SSH access to the remote host
- Network reachability between Pineapple and remote host

## How It Works

1. Prompts for:
   - Remote host username
   - Remote host IP
   - Remote host password
   - Reverse tunnel port
2. Verifies the remote host is reachable.
3. Starts an SSH reverse tunnel using port forwarding.
4. Confirms the tunnel is running and healthy.
5. Outputs the command to be executed on the remote host to connect back.

## Remote Host Command

Once the tunnel is established, run this **on the remote host**:

```bash
ssh <username>@localhost -p <port>
