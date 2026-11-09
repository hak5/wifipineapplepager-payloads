# MIRRORCAST - Cast & Print Honeypot

A wireless discovery honeypot and castjack tool for the WiFi Pineapple Pager.
MIRRORCAST impersonates the cast and print devices people expect to find on a
network, records every client that comes looking, and can push media to real
Chromecast, AirPlay, DIAL and DLNA devices.

> **Authorized testing only.** Run MIRRORCAST only on networks you own or have
> written permission to test. It advertises fake services and can change what
> nearby cast devices are playing. You are responsible for your engagement
> scope and local law.

## Why it is different

The Pager payload library already covers deauthentication, PMKID and handshake
capture, probe recon, captive portals, SSID spam and Bluetooth scanning.
MIRRORCAST does not duplicate those. It works one layer up, at the discovery
and application layer:

- mDNS and SSDP service impersonation
- AirPlay, DIAL, Chromecast and IPP printer emulation
- print-job capture from real clients
- castjacking discovered media renderers

It does not crack Wi-Fi, capture WPA handshakes, deauthenticate clients, or
intercept TLS.

## Modes

### Honeypot

Advertises a believable display and printer on the local network:

| Service | mDNS | Port |
| --- | --- | --- |
| Chromecast | `_googlecast._tcp` | 8009 |
| AirPlay | `_airplay._tcp` | 7000 or 8080 |
| AirPlay audio (RAOP) | `_raop._tcp` | 5000 |
| DIAL | `_dial._tcp` | 8080 |
| IPP printer | `_ipp._tcp`, `_ipps._tcp`, `_printer._tcp` | 631 or 8080 |
| UPnP MediaRenderer | SSDP | 8080 |

By default the bait multiplexes AirPlay, DIAL and IPP on the primary HTTP port
(8080). Enabling **bind AirPlay 7000 and IPP 631** also listens on the standard
ports, which catches clients that connect directly instead of using the
advertised port.

Every probe is logged: mDNS questions, SSDP `M-SEARCH` requests and user
agents, HTTP headers, AirPlay play requests, DIAL launches, and IPP print
requests. IPP bodies are saved raw, and the document after the IPP
end-of-attributes tag is extracted separately.

The HTTP service also serves a "Display Ready" page for anyone who browses to
the bait address. SSDP replies point printer and renderer searches at
`/printer.xml` and `/renderer.xml`, while DIAL and root-device searches use
`/description.xml`.

### Scan

Discovers real cast and print devices on the local network using mDNS and SSDP,
enriches UPnP results with the device description, and saves the results as
JSON. Useful before a castjack run, or as a quick inventory of a target
network's media devices.

### Castjack

Discovers cast-capable devices, lets you pick one (or all of them), and pushes
a media URL:

- **Chromecast**: CASTV2 over TLS, launches the default media receiver and
  sends `LOAD`.
- **AirPlay**: HTTP `POST /play` with `Content-Location`.
- **DIAL**: `POST /apps/<app>` on the device's application URL.
- **DLNA**: UPnP `SetAVTransportURI` followed by `Play`.

The URL must be reachable by the target device. The Pager does not proxy the
media. For a lab, host a small media file on a web server that both the Pager
and the cast devices can reach, and use that URL instead of the default
`example.com` placeholder.

**Dry run** performs discovery and shows exactly what would be sent without
contacting a renderer. Use it to verify scope.

## Requirements

- WiFi Pineapple Pager on firmware **2.0.0-stable** or newer
- `python3-light` (about 3 MB)
- `python3-openssl` for Chromecast castjack (about 1 MB); AirPlay, DIAL and
  DLNA work without it
- An interface with an IPv4 address on the target network

The payload offers to install missing packages with `opkg`. To install them
ahead of time:

```sh
opkg update
opkg install python3-light python3-openssl
```

`python3-light` includes `http.server`, `socketserver`, `http.client`, `ssl`
stub, `json`, `threading`, `struct` and `socket`. The engine uses raw sockets
for mDNS and SSDP, so no `zeroconf` package is needed.

## Installation

Copy the `mirrorcast` directory to one of the Pager payload locations:

```text
/root/payloads/user/interception/mirrorcast/
/mmc/root/payloads/user/interception/mirrorcast/
```

Keep the files together:

```text
mirrorcast/
  payload.sh      Pager UI, scope gate, menus, button stop
  mirrorcast.py   discovery, honeypot and castjack engine
  lure.html       page served by the honeypot
  README.md       this file
```

Ensure Unix LF line endings and that `payload.sh` is executable:

```sh
chmod +x /root/payloads/user/interception/mirrorcast/payload.sh
```

## Usage

1. Put the Pager on the target network. An open AP (`wlan0open`), a client
   connection (`wlan0wpa`), or a management interface all work as long as the
   interface has an IPv4 address and reaches the devices you want to observe.
2. Run **MIRRORCAST** from the Pager payload menu.
3. Confirm the authorization gate.
4. Select the interface.
5. Pick a mode.

### Honeypot tips

- Choose a bait name that fits the environment: `Living Room TV`,
  `Office Printer`, `Conference Display`, or a custom name.
- Enabling **bind AirPlay 7000 and IPP 631** catches clients that connect
  directly instead of using the advertised HTTP port. Those ports are
  advertised either way. If a port is already in use, the engine logs it and
  keeps running.
- Press **A** while the honeypot is running to stop it. The payload always
  restores the LED to white and terminates the engine.
- Watch the display for the latest probe and event counters. Full detail is
  in the loot directory.

### Castjack tips

- Run **Scan** first to confirm the target is visible.
- Use **Castjack - dry run** to verify discovery and target selection.
- Start with a single target. Castjacking every device on a production network
  is noisy and may interrupt presentations or media playback.
- DIAL app names vary by device. The default is `Browser`; if a DIAL launch
  fails, try the device's own app name or use DLNA where available.
- Modern Apple TVs and HomePods may require pairing or an encrypted AirPlay
  session. Plain AirPlay 1 renderers and many smart TVs work directly.

## Loot

All output goes to `/root/loot/mirrorcast/`:

| File | Contents |
| --- | --- |
| `events.jsonl` | One JSON object per event: mDNS query, SSDP search, HTTP request, TCP connect, print job, castjack result |
| `ui.log` | Human-readable activity log |
| `printjobs/*.ipp` | Raw IPP request bodies |
| `printjobs/*.doc` | Extracted print document data, when present |
| `scan_*.json` | Discovery results |
| `castjack_*.log` | Per-run castjack results |

Events include the source address, service, headers, user agent and, for print
jobs, byte counts and saved file paths. Example record:

```json
{"ts": "2026-11-06T22:31:04+0000", "kind": "http", "src": "192.168.1.44", "method": "GET", "path": "/description.xml", "headers": {"user-agent": "..."}}
```

## Command-line use

The engine can be used directly for testing or automation:

```sh
cd /root/payloads/user/interception/mirrorcast

# List interfaces with IPv4 addresses
python3 mirrorcast.py ifaces

# Discover cast and print devices
python3 mirrorcast.py scan --iface wlan0open --seconds 20

# Honeypot until stopped, with standard ports bound
python3 mirrorcast.py honeypot --iface wlan0open \
    --name "Living Room TV" --bind-defaults

# Push to one device discovered by a scan
python3 mirrorcast.py push --iface wlan0open \
    --target 192.168.1.50 --type chromecast --port 8009 \
    --url http://example.com/media.mp4

# Full castjack with its own discovery pass
python3 mirrorcast.py castjack --iface wlan0open \
    --url http://example.com/media.mp4 --seconds 15
```

`honeypot` accepts `--duration SECONDS` (`0` means until stopped). `scan` and
`castjack` accept `--loot DIR` to change the output directory.

## How it works

- **mDNS**: a raw UDP socket on `224.0.0.251:5353` advertises PTR, SRV, TXT
  and A records for each impersonated service, answers matching queries, and
  re-announces every 60 seconds. Queries are logged even when they do not
  match.
- **SSDP**: a UDP socket on `239.255.255.250:1900` answers `M-SEARCH` with
  DIAL, MediaRenderer and Printer descriptions, sends `ssdp:alive` NOTIFY
  messages, and points clients at the HTTP description.
- **HTTP**: a threaded server serves UPnP descriptions, DIAL endpoints,
  AirPlay `/play`, DLNA AVTransport SOAP, the lure page, and IPP.
- **Print capture**: IPP requests are streamed to disk, so large jobs do not
  sit in memory. A minimal successful IPP response keeps the client happy.
- **Chromecast**: CASTV2 protobuf messages are encoded by hand. The engine
  connects to port 8009 over TLS, launches `CC1AD845` (default media
  receiver), then sends `LOAD` with the media URL.
- **Cleanup**: signal handlers set a stop flag; the payload also watches the
  Pager input device and sends `SIGTERM` when A is pressed. Ports close and
  the LED returns to white.

## Scope and safety

MIRRORCAST is non-destructive and reversible:

- It does not modify the Pager's Wi-Fi configuration.
- It does not deauthenticate, jam, or crack Wi-Fi.
- It does not install persistence or change device settings.
- It only advertises local services and, in castjack mode, sends a media URL
  to devices you select.
- Stopping the payload closes all sockets and removes temporary files.

The honeypot does not capture credentials by itself. It logs metadata that
clients send to discovery services, which can include hostnames, device names,
model strings, user agents, and requested paths. In a client engagement that
authorizes credential capture, pair it with an authorized captive portal or
other in-scope collection method.

## Troubleshooting

**No interfaces listed.** The selected radio has no IPv4 address. Connect the
Pager to the network or bring up the AP interface, then refresh.

**mDNS or SSDP disabled in the log.** Another process is already bound to
port 5353 or 1900. Stop it, or run the honeypot on a different interface. The
remaining services keep working.

**Scan finds nothing.** Check that the Pager and target are on the same
broadcast domain, that client isolation is off, and that the target has not
disabled mDNS/SSDP. Try a longer scan (30-60 seconds) and verify with the
device's own discovery app.

**Castjack reports an SSL error.** Install `python3-openssl`. Chromecast uses
TLS on port 8009. AirPlay, DIAL and DLNA do not need Python's ssl module.

**Castjack returns 401 or 403.** The device requires pairing or
authentication. That is outside this payload's scope; try another target or
use dry run for inventory.

**DIAL launch fails.** Try a different app name. Some TVs only accept their
built-in browser or a vendor-specific app ID.

**Printer job is empty.** Some clients send IPP over TLS (IPPS) or use a
different print protocol. The raw request is still saved for analysis; TLS
payloads are not decrypted.

## Uninstall

Remove the payload directory and, if desired, its loot:

```sh
rm -rf /root/payloads/user/interception/mirrorcast
rm -rf /root/loot/mirrorcast
```

No services, init scripts, or system files are installed.

## Version

1.0.0 - initial release for Pager firmware 2.0.0-stable.

## Legal

Provided for authorized security testing and education only. Hak5 gear and
DuckyScript are trademarks of Hak5 LLC. This payload is not affiliated with or
endorsed by Hak5. Users are solely responsible for compliance with applicable
laws and engagement rules.
