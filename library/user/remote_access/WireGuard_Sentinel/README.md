# WireGuard-Sentinel
Persistent WireGuard VPN tunnel for the WiFi Pineapple Pager with health monitoring, automatic reconnection, and peer failover.


- **Author:** D-L3aN
- **Version:** 1.0
- **Category:** remote_access
- **Net Mode:** Client

---

## Authorised Use Only

For authorised security testing and remote administration of your own
infrastructure. Do not connect to endpoints you do not control.

---

## Features

| Feature | Description |
|---|---|
| **One-touch tunnel** | Establishes WireGuard tunnel with a single confirmation |
| **Auto-recovery** | Monitors tunnel health and reconnects on failure |
| **Peer failover** | Falls back to a backup endpoint if primary fails |
| **Session logging** | Timestamped log of all tunnel events |
| **Key generation** | Generates WireGuard keypair if none exists |

---

## Configuration

Edit the configuration block at the top of `payload.sh`:

| Variable | Description |
|---|---|
| `WG_PRIMARY_ENDPOINT` | Primary server `host:port` |
| `WG_PRIMARY_PUBKEY` | Primary server's public key |
| `WG_BACKUP_ENDPOINT` | Optional backup endpoint |
| `WG_BACKUP_PUBKEY` | Optional backup server's public key |
| `WG_LOCAL_ADDRESS` | Local tunnel IP in CIDR (e.g., `10.13.13.2/24`) |
| `HEALTH_CHECK_TARGET` | IP to ping for health checks (usually tunnel gateway) |
| `HEALTH_CHECK_INTERVAL` | Seconds between health checks |
| `MAX_FAILURES_BEFORE_RECONNECT` | Failed checks before reconnect attempt |

---

## Usage

1. Copy `payload.sh` to `/root/payloads/user/remote_access/wireguard_sentinel/`
2. Install dependencies:
   ```bash
   opkg update && opkg install wireguard-tools kmod-wireguard 
---

## Pull Request Description

```markdown
## Summary

 **WireGuard Sentinel**, a persistent VPN payload with health
monitoring, automatic reconnection, and peer failover. Fills the gap
for operators who need WireGuard connectivity with resilience features
beyond what the existing Tailscale suite provides.

## Motivation

The `remote_access` category currently offers a comprehensive Tailscale
lifecycle suite. WireGuard Sentinel adds:
- Native WireGuard (not Tailscale-dependent)
- Automatic tunnel recovery on failure
- Primary/backup peer failover
- Session logging for engagement documentation

## What It Does

- Generates WireGuard config from operator-provided endpoint/pubkey
- Establishes tunnel via `wg-quick up`
- Optional guard mode: pings health target, reconnects on failure
- Failover to backup endpoint if primary recovery fails
- Logs all events to `/root/loot/wireguard_sentinel/`

## Testing

| Device | Firmware | Result |
|---|---|---|
| WiFi Pineapple Pager | Current | Pass (basic tunnel) |

Guard mode tested with simulated tunnel drops. Button-B exit mechanism
may need adjustment per firmware.

## Notes for Maintainers

- Uses standard DuckyScript commands: `LOG`, `CONFIRMATION_DIALOG`,
  `START_SPINNER`, `STOP_SPINNER`, `PROMPT`, `ERROR_DIALOG`, `LED`,
  `RINGTONE` [citation:3][citation:11]
- Configuration placeholders follow repository standards: no live URLs,
  no real keys [citation:12]
- Loot written to `/root/loot/wireguard_sentinel/`
- Directory name `wireguard_sentinel` follows naming conventions [citation:12]
Credit - D-L3aN
Fixes: N/A
Related: `library/user/remote_access/tailscale_*`
