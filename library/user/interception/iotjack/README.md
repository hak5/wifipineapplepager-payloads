# IoTJACK - IoT Exploitation Toolkit

An offensive LAN/IoT payload for the WiFi Pineapple Pager. IoTJACK scans the
local network for IoT devices, fingerprints them, and runs per-protocol
attack modules against the classics: smart plugs, MQTT brokers, UPnP
gateways, TR-064 routers, RTSP cameras, and raw-port printers.

> **Authorized testing only.** IoTJACK actively exploits devices: it recovers
> Wi-Fi credentials from smart plugs, captures MQTT traffic, tests default
> camera passwords, and can change device state (relay toggle, MQTT publish,
> NAT mappings, printer display). Run it only on networks and devices you own
> or have written permission to test.

## Why it is different

The Pager library already covers WPA handshakes, PMKID, deauth, probe recon,
captive portals, and discovery honeypots (MIRRORCAST). IoTJACK works one
layer up: it attacks the **devices on the network**, not the Wi-Fi. Every
module speaks its target's own protocol in pure Python - no external tools.

## Modules

| Module | Protocol | Read actions | Write actions (confirmed on screen) |
| --- | --- | --- | --- |
| Kasa | TP-Link XOR/JSON, TCP 9999 | sysinfo, **Wi-Fi creds** (`netif get_stainfo`), bound cloud account, power meter | relay toggle |
| MQTT | MQTT 3.1.1, TCP 1883 | anonymous probe, wildcard `#` capture | publish |
| IGD | UPnP SOAP, 1900/7547+ | external IP, list port mappings | add mapping, remove mapping |
| TR-064 | SOAP, TCP 7547 | device info, **Wi-Fi key recovery** (`GetSecurityKeys`) | - |
| RTSP | RTSP, TCP 554 | DESCRIBE, **8 default cred pairs** (Basic + Digest), stream list | - |
| PJL | PJL, TCP 9100 | printer ID, status, config, filesystem list | display message |

### Kasa: the headliner

Legacy TP-Link Kasa devices (HS100/HS110 smart plugs, LB bulbs, wall
switches, KP strips) accept unauthenticated commands on TCP 9999. The
`netif.get_stainfo` reply contains the SSID and, on a lot of firmware, the
**Wi-Fi password** of the network the device joined. `cnCloud.get_info`
returns the bound TP-Link account email. Newer devices that moved to the
KLAP protocol (2023+ firmware) simply won't answer - that's logged as a
miss, not an error.

### IGD mappings are reversible

Anything IoTJACK adds via `AddPortMapping` is tagged with the description
prefix `IoTJACK`, and the module menu includes **Remove a mapping**. Clean
up after yourself before the engagement ends.

## Requirements

- WiFi Pineapple Pager, firmware **2.0.0-stable** or newer
- `python3-light` (about 3 MB) - the payload offers to install it
- An interface with an IPv4 address on the target network

No other packages. The engine is pure stdlib (`socket`, `http.client`,
`concurrent.futures`, `ipaddress`, `hashlib`, `base64`).

## Installation

Copy the `iotjack` directory to one of the Pager payload locations:

```text
/root/payloads/user/interception/iotjack/
/mmc/root/payloads/user/interception/iotjack/
```

Files:

```text
iotjack/
  payload.sh    Pager UI, scope gate, menus, write-action confirmations
  iotjack.py    scanner + protocol modules
  README.md     this file
```

Ensure Unix LF line endings and that `payload.sh` is executable:

```sh
chmod +x /root/payloads/user/interception/iotjack/payload.sh
```

## Usage

1. Put the Pager on the target network (client mode or the open AP; any
   interface with an IPv4 address that can reach the devices).
2. Run **IoTJACK** from the payload menu.
3. Confirm the authorization gate.
4. Select the interface.
5. **Scan network** (fast: 10 IoT-heavy ports per host; full: 22 ports).
   Devices are fingerprinted as `kasa`, `mqtt`, `router`, `camera`,
   `printer`, `web` or `linux-device`.
6. **Attack a device** - pick from the scan results or enter an IP. The
   module menu puts the fingerprint-matched module first. Read actions just
   loot; anything that changes the device asks first.
7. **Quick wins** - run the high-value reads against everything at once:
   Kasa cred dump on all smart plugs, MQTT capture on all open brokers,
   RTSP default-cred audit on all cameras.

## Loot

All output goes to `/root/loot/iotjack/`:

| File | Contents |
| --- | --- |
| `events.jsonl` | one JSON object per action and result |
| `ui.log` | human-readable activity log |
| `scan_*.json` | discovery results with fingerprints |
| `mqtt_<ip>.jsonl` | captured MQTT messages per broker |

Example Kasa loot event:

```json
{"ts": "2026-11-07T08:31:04+0000", "kind": "kasa", "target": "10.0.0.42", "action": "creds", "result": {"status": 1, "stainfo": {"ssid": "LabCorp WiFi", "key": "WpaPassw0rd!", "key_type": 3}}}
```

## Command-line use

The engine can be driven directly for scripting or debugging:

```sh
cd /root/payloads/user/interception/iotjack

# List usable interfaces
python3 iotjack.py ifaces

# Fast scan of the interface's /24, JSON to stdout
python3 iotjack.py scan --iface wlan0open --profile fast --json

# Kasa: pull the Wi-Fi credentials the plug is connected with
python3 iotjack.py kasa --target 10.0.0.42 --action creds

# MQTT: 30 seconds of wildcard capture
python3 iotjack.py mqtt --target 10.0.0.10 --action capture --seconds 30

# IGD: enumerate mappings, then open and later remove one
python3 iotjack.py igd --target 10.0.0.1 --iface wlan0open --action enum
python3 iotjack.py igd --target 10.0.0.1 --iface wlan0open --action map \
    --ext-port 2323 --int-port 23 --internal-ip 10.0.0.60 --proto tcp \
    --desc audit
python3 iotjack.py igd --target 10.0.0.1 --iface wlan0open --action unmap \
    --ext-port 2323 --proto tcp

# TR-064: device info + Wi-Fi keys
python3 iotjack.py tr064 --target 10.0.0.1

# RTSP: default-cred audit
python3 iotjack.py rtsp --target 10.0.0.51

# PJL: identify printer and list stored files
python3 iotjack.py pjl --target 10.0.0.33 --action id
python3 iotjack.py pjl --target 10.0.0.33 --action ls
```

Every command logs a JSON result to the loot directory and exits 0 on
success, 1 on failure.

## How it works

- **Scanner**: threaded TCP connect sweep (fast profile: 23, 80, 554, 1883,
  7547, 8080, 8291, 9100, 9999, 37777) over the interface's /24, then
  per-host protocol probes for fingerprinting.
- **Kasa**: XOR autokey cipher (key starts at 0xAB) over a 4-byte length
  prefix, per the reversed TP-Link protocol.
- **MQTT**: minimal 3.1.1 client (CONNECT/SUBSCRIBE/PUBLISH/PING) - enough
  to probe anonymous access, capture `#`, and publish QoS 0 messages.
- **IGD**: SSDP `M-SEARCH` for `InternetGatewayDevice`, description parse
  for the WANIPConnection/WANPPPConnection control URL, then SOAP
  (`GetExternalIPAddress`, `GetGenericPortMappingEntry`, `AddPortMapping`,
  `DeletePortMapping`).
- **TR-064**: SOAP `GetInfo` + `GetSecurityKeys` against the DSLForum
  services. Reports `401` as "auth required" instead of failing.
- **RTSP**: `DESCRIBE` unauthenticated first, then Basic or Digest (MD5,
  qop=auth) with a small default-cred list; parses SDP stream names.
- **PJL**: raw 9100 with UEL framing; `FSDIRLIST` parsing for stored files.

## Scope and safety

- The scope gate requires explicit confirmation at every launch.
- Read actions only observe and record. Write actions (relay, publish,
  mapping add/remove, printer display) each show exactly what will happen
  and wait for confirmation.
- IGD mappings added by IoTJACK are tagged `IoTJACK ...` so they are easy to
  find and remove.
- The payload changes nothing on the Pager itself: no config changes, no
  persistence, no services installed. All state lives in the loot directory.

Limitations: KLAP-encrypted Kasa devices, MQTT brokers that require auth,
digest-only TR-064 routers, and cameras with non-default credentials all
report a clean "no" rather than breaking - this payload does not brute
force beyond the documented default list, and it does not crack Wi-Fi.

## Troubleshooting

**No interfaces listed.** The radio has no IPv4 address. Join the target
network first, then refresh.

**Scan finds nothing.** Client isolation is probably on, or the subnet isn't
a /24. IoTJACK scans the interface's /24 by default.

**Kasa device found but no creds.** Newer firmware removed `key` from
`get_stainfo` or moved to KLAP. The sysinfo and cloud account may still be
readable.

**IGD actions say "no IGD found".** The gateway doesn't expose UPnP IGD, or
SSDP is blocked. Nothing to attack with this module.

**TR-064 reports 401.** The router requires authentication (e.g. Fritz!Box).
Out of scope for this payload.

**RTSP finds no working creds.** Good - the camera isn't on defaults. Move
on; the payload does not brute force.

## Uninstall

```sh
rm -rf /root/payloads/user/interception/iotjack
rm -rf /root/loot/iotjack
```

## Version

1.0.0 - initial release for Pager firmware 2.0.0-stable.

## Legal

Provided for authorized security testing and education only. Users are
solely responsible for compliance with applicable laws and engagement
rules. Not affiliated with or endorsed by Hak5, TP-Link, or any vendor
named in this document.
