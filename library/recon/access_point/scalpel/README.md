# SCALPEL — Surgical Handshake Capture

A **Recon payload** for the WiFi Pineapple Pager. After you select an access point
(or a client) in Recon, SCALPEL deterministically captures a WPA/WPA2 handshake for
*that AP only* — no blanket deauth, minimal disruption — and reports the
hashcat-ready result.

> **Authorized testing only.** SCALPEL locks the radio to a target channel and may
> deauthenticate a client to force a handshake. Use only on networks you own or have
> written permission to test.

## What it does

The Pager's native handshake collection is passive and opportunistic: it only lands
a handshake when the channel-hopping engine happens to be on the right channel at
the right moment. SCALPEL makes it deterministic and scoped:

1. Reads the selected device from the recon environment
   (`_RECON_SELECTED_AP_*` / `_RECON_SELECTED_CLIENT_*`).
2. Refuses non-PSK targets (WPA3/SAE/OWE/OPEN/WEP have no crackable handshake).
3. Locks the recon engine to the AP's channel (`PINEAPPLE_EXAMINE_BSSID`).
4. Optionally deauthenticates one client (`DEAUTH_CLIENT`) to force a reconnect.
5. Watches `/root/loot/handshakes/` for a new `.22000` (hccapx) record matching the
   target BSSID, and stops the instant one lands.

Captured handshakes stay in `/root/loot/handshakes/` (native `.pcap` + `.22000`),
ready for `scp` and offline cracking with hashcat `-m 22000`.

## Install

Recon payloads live under `recon/access_point/` (AP-targeted) or `recon/client/`
(client-targeted). SCALPEL is an AP payload:

```sh
scp -r scalpel root@172.16.42.1:/root/payloads/recon/access_point/
```

Or, if payloads live on the SD card:

```sh
scp -r scalpel root@172.16.42.1:/mmc/root/payloads/recon/access_point/
```

Then SSH in and make it executable:

```sh
ssh root@172.16.42.1
chmod +x /root/payloads/recon/access_point/scalpel/payload.sh
```

To also use SCALPEL's single-client mode from the client list, copy it there too:

```sh
cp -r /root/payloads/recon/access_point/scalpel /root/payloads/recon/client/scalpel
```

## Usage

- **Active** — deauth to force a reconnect. Fast and deterministic; use this if you
  want a handshake *now* (scoped to the selected BSSID).
- **Passive** — lock the channel and wait for a client to reconnect naturally. Quiet
  but slow: WPA sessions only refresh ~every 5 minutes, so it may take several
  minutes. Only reliable if a client is actively present and reconnects.
- **Auto** (default) — asks when clients are present; drops to passive when none.

Run as a **client** payload to surgically deauth exactly one device; run as an **AP**
payload to deauth all clients of that BSSID (or enter one MAC).

While it runs, SCALPEL shows a "HACK THE PLANET" banner and live progress in the
payload log.

## Configuration

Edit the variables at the top of `payload.sh`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SCALPEL_MODE` | `auto` | `passive` / `active` / `auto` |
| `SCALPEL_TARGET_CLIENT` | empty | single MAC, or empty = all clients |
| `SCALPEL_TIMEOUT` | `120` | active: overall seconds cap |
| `SCALPEL_PASSIVE_TIMEOUT` | `360` | passive: seconds to wait for a reconnect |
| `SCALPEL_DEAUTH_INTERVAL` | `6` | seconds between deauth bursts / checks |
| `SCALPEL_MAX_DEAUTH` | `10` | max deauth bursts before giving up |

## Notes & limits

- WPA3/SAE/OWE have no crackable handshake; SCALPEL exits with a notice.
- **DFS (5 GHz)** and **6 GHz** channels can't be deauthed (regulatory); SCALPEL
  falls back to passive lock-and-wait.
- **PMF / 802.11w** clients ignore injected deauth; SCALPEL waits for a natural
  reconnect instead.
- Half-handshakes (M1+M2) are still crackable; the native engine's `.22000` output
  already covers this.

## Legal

For authorized security testing and education only. Deauthenticating clients can
disrupt networks and may be illegal without explicit written permission. Not
affiliated with or endorsed by Hak5. Users are solely responsible for compliance
with applicable laws.
