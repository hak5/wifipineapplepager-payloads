# VENUS

**Flytrap rogue AP for the WiFi Pineapple Pager.**

VENUS scans the air from your Pager, clones a network you select, and puts a
captive portal in front of it. Every device that associates lands as a fly on
an animated spiderweb on the Pager's own screen. The screen is the tool: D-pad
to choose a target, **A** to spring the trap, **A** again to add a deauth lure,
**B** to drop it.

```
RECON   ▸ pick an SSID from a live scan            ▸ A traps it
TRAP    ▸ spiderweb + one fly per associated client
          ▸ UP/DOWN selects a fly
          ▸ A toggles the optional deauth lure
          ▸ B drops the trap and returns to RECON
```

> **Authorized testing only.** VENUS impersonates a Wi-Fi network, can
> deauthenticate nearby clients, and logs anything submitted to its portal.
> Use it only on networks you own or have written permission to test.

---

## What actually happens

1. `venus.py` picks a managed radio for the AP and another for recon, avoiding
   the default-route/uplink interface and firmware `*mon`/`*cli`/`*wpa` vifs.
   For a 5 or 6 GHz target it checks each radio's phy and moves the AP to one
   that actually reports that band.
2. Before arming, VENUS refuses to use a radio whose phy is serving the
   Pager's own uplink or a firmware management/AP vif, so a flytrap can't take
   the Pager's own WiFi offline.
3. Recon runs `iw dev <iface> scan` and publishes the AP list to
   `/tmp/venus_state.json`.
4. You press **A** on a target. The engine:
   - creates a dedicated AP virtual interface (`venus0`) on the selected
     radio's phy, so it never destroys the radio's existing role,
   - writes a private `hostapd.conf` to `/tmp/venus_hostapd.conf` and starts
     hostapd on the selected channel (2.4, 5, or 6 GHz); if the firmware's
     `wpad-basic-mbedtls` rejects an advanced option it retries with a
     conservative config,
   - assigns `192.168.69.1/24`, starts a built-in raw-socket DHCP server (no
     UDP :67 conflict with the firmware dnsmasq) and a wildcard DNS responder,
   - starts the captive portal on port 80 (or 8080 + nftables/iptables
     redirect).
5. Client discovery is authoritative: `iw dev <ap_iface> station dump`.
   DHCP leases (written by the built-in server in dnsmasq-compatible format)
   and `/proc/net/arp` enrich each client with IP, hostname, and vendor. If
   the driver cannot report stations, active leases are used as a fallback.
6. The UI reads the state file and draws a fly for each client. New clients
   flash the screen, buzz, and chirp. Portal hits and form submissions have
   their own sounds.
7. Optionally, **A** on the trap screen enables the lure. The engine tunes a
   monitor interface on the second radio to the trap channel and runs
   `aireplay-ng --deauth 5 -a <BSSID>` bursts. The lure is off by default.

The engine and UI are separate crash domains. If the UI dies, the engine keeps
running and `payload.sh` can fall back to the LOG display. If the engine dies,
the UI shows the waiting screen and the payload reports the failure.

---

## Files

```
venus/
├── payload.sh             launcher, authorization gate, supervision, cleanup
├── venus.py               radio/AP/portal/DNS/lure engine + selftest + simulate
├── pager_ui.py            on-device flytrap UI + headless renderer
├── venus.conf.example     optional site overrides (copy to venus.conf)
├── portal/
│   ├── index.html         captive portal (SSID/title templated)
│   └── success.html       post-submit page
├── lib/
│   ├── pagerctl.py        ctypes wrapper for the Pager display/input
│   └── libpagerctl.so     firmware display/input library (MIPS, do not rebuild)
└── tests/
    └── test_venus.py      hardware-free unit + loopback portal tests
```

Communication:

| Path | Direction | Purpose |
| --- | --- | --- |
| `/tmp/venus_state.json` | engine → UI | phase, AP list, clients, counts, events |
| `/tmp/venus_cmd.jsonl` | UI → engine | `trap`, `untrap`, `lure`, `rescan`, `clear`, `shutdown` |
| `/tmp/venus_run.log` | both → disk | engine stderr/stdout and UI output |
| `/tmp/venus_hostapd.conf` | engine | private hostapd config |
| `/tmp/venus_dnsmasq.conf` | engine | private dnsmasq config (fallback only) |
| `/tmp/venus_leases` | engine | DHCP leases (dnsmasq-compatible) parsed by the engine |
| `venus0` | engine | dedicated AP virtual interface, deleted on exit |

---

## Requirements

- WiFi Pineapple Pager firmware **2.0.0-stable or newer**.
- `python3-light` (standard on current firmware). The engine uses **only**
  modules in `python3-light` — no `email`, `urllib`, or `http.server` — so it
  runs without `python3-email`/`python3-urllib`.
- `hostapd` and `iw` (standard on current firmware). The launcher checks for
  both and refuses to start if one is missing.
- `dnsmasq` is **not required** — VENUS ships its own raw-socket DHCP server.
  It is used only as a last-resort fallback if raw sockets are unavailable.
- `python3-ctypes` for the **on-device UI** (it loads `libpagerctl.so`).
  Without it the payload still works but falls back to the LOG text display.
- Optional: `aireplay-ng` from aircrack-ng for the deauth lure.
- Two usable radios for simultaneous trap + recon + lure. The Pager's primary
  tri-band radio and secondary 2.4 GHz radio normally cover this.

One-line install for the full experience:

```sh
opkg update && opkg install python3-light python3-ctypes
```

(`hostapd` and `iw` ship with the firmware; install only if missing.)

`libpagerctl.so` in `lib/` is a MIPS binary copied from the Pager firmware
payload library. It will not load on a development PC; that is expected. The
UI has a headless mode for local work and falls back to the LOG display when
the native library or framebuffer is unavailable.

---

## Install

Copy the whole directory to either payload root:

```sh
scp -r venus root@172.16.42.1:/root/payloads/user/interception/
```

or, if you keep payloads on the microSD:

```sh
scp -r venus root@172.16.42.1:/mmc/root/payloads/user/interception/
```

Then make the launcher executable:

```sh
chmod +x /root/payloads/user/interception/venus/payload.sh
```

The launcher also finds itself when the directory is named differently, as
long as `venus.py` sits next to `payload.sh`.

Optional configuration:

```sh
cp /root/payloads/user/interception/venus/venus.conf.example \
   /root/payloads/user/interception/venus/venus.conf
vi /root/payloads/user/interception/venus/venus.conf
```

Run **VENUS** from the Pager payload menu. Confirm the authorization prompt.

---

## Controls

### RECON screen

| Input | Action |
| --- | --- |
| UP / DOWN | move the target selection |
| A | clone the selected SSID and start the trap |
| B | shut down VENUS and return to the stock Pager UI |

The list shows SSID, channel, band, RSSI bars, security, and the selected row.
Empty-SSID (hidden) networks are skipped with a status message.

### TRAP screen

| Input | Action |
| --- | --- |
| UP / DOWN | select a fly (client) |
| A | toggle the deauth lure (if a second radio and `aireplay-ng` exist) |
| B | drop the trap and go back to RECON |

The right panel shows total clients, portal hits, form submissions, uptime, and
the selected client's MAC suffix, vendor, RSSI, IP, hostname, and idle time.
Flies are deterministic per MAC, so they do not jump around between frames.
Inactive clients stay on the web in gray; they are removed when the trap drops.

A/B presses in the first 2.5 seconds are ignored because firmware 2.0.0 emits
stale button events from the press that launched the payload.

### LED states

| Color | Meaning |
| --- | --- |
| Blue | launcher/preflight |
| Cyan | recon / idle |
| Pulsing red | trap live, lure enabled |
| Dim green | trap live, lure off |
| White | stopped / cleaned up |

---

## Loot

The launcher uses `/root/loot/venus/`, or `/mmc/root/loot/venus/` when a
microSD loot tree exists.

| Path | Contents |
| --- | --- |
| `events.jsonl` | every engine event (INFO/WARN/TRAP/CAUGHT/PORTAL/SUBMIT/LURE/ERROR) |
| `portal_submissions.jsonl` | one JSON record per portal POST, with source IP, MAC, user agent, and form fields |
| `last_run.log` | copy of the last `/tmp/venus_run.log` |
| `captures/` | reserved for future payload captures; currently unused |

`portal_submissions.jsonl` is written mode `0600`. With capture enabled
(default), field values are stored in clear so you can see exactly what the
portal received. Set `VENUS_NO_CAPTURE=1` to store field names with
`"[redacted]"` values instead.

---

## Configuration

Copy `venus.conf.example` to `venus.conf` next to `payload.sh`. Every value is
optional. The launcher sources it before building engine arguments.

| Variable | Default | Meaning |
| --- | --- | --- |
| `VENUS_HTTP_PORT` | `80` | portal port; falls back to 8080 + redirect |
| `VENUS_AP_IP` | `192.168.69.1` | AP address, DHCP router/DNS, portal host |
| `VENUS_PORTAL_TITLE` | `Sign in to Wi-Fi` | portal heading |
| `VENUS_PASSWORD` | empty | WPA2-PSK passphrase; empty = open clone |
| `VENUS_COUNTRY` | `US` | regulatory country for 5/6 GHz hostapd |
| `VENUS_NO_PORTAL` | `0` | `1` = AP/DHCP/DNS/lure only, no HTTP portal |
| `VENUS_NO_CAPTURE` | `0` | `1` = redact form values in loot |
| `VENUS_LURE` | `0` | `1` = start with the deauth lure already enabled |
| `VENUS_NO_LURE` | `0` | `1` = remove the lure option entirely |
| `VENUS_NO_GUARD` | `0` | `1` = disable the shared-radio safety guard (see below) |
| `VENUS_SCAN_INTERVAL` | `6` | seconds between recon sweeps |
| `VENUS_LURE_INTERVAL` | `8` | seconds between deauth bursts |
| `VENUS_IFACE` | auto | AP radio override (e.g. `wlan1`) |
| `VENUS_RECON_IFACE` | auto | recon radio override (e.g. `wlan0`) |
| `VENUS_PAGERCTL` | `1` | `0` = skip the native UI, use LOG fallback |
| `VENUS_OUI_FILE` | empty | optional IEEE/nmap OUI file for more vendor names |

---

## Testing on a development machine

None of these touch a radio:

```sh
# From the repository root:
python3 -m unittest discover -s venus/tests -v

# Built-in engine assertions (parsers, configs, DNS, MAC/vendor, state):
python3 venus/venus.py selftest

# Render both screens with a no-op pager:
python3 venus/pager_ui.py --sample --frames 2
python3 venus/pager_ui.py --sample --recon --frames 2

# Shell syntax check:
bash -n venus/payload.sh
```

Dry-run the whole pipeline without hardware:

```sh
# Terminal 1: fake APs and clients, no radios touched
python3 venus/venus.py simulate \
    --loot /tmp/venus-sim/loot \
    --state /tmp/venus-sim/state.json \
    --cmd /tmp/venus-sim/cmd.jsonl \
    --duration 30

# Terminal 2: point the headless UI at the simulated engine
VENUS_STATE=/tmp/venus-sim/state.json \
VENUS_CMD=/tmp/venus-sim/cmd.jsonl \
python3 venus/pager_ui.py --headless --frames 3
```

Local verification for this build:

- `89/89` unit tests pass (`unittest discover`).
- `17/17` engine self-test checks pass.
- Headless trap screen renders (`screen=trap`, 3 sample clients).
- Headless recon screen renders (`screen=recon`, 3 sample APs).
- DHCP discover/offer/ack packet round-trip and lease-pool unit tests pass.
- Live `simulate` → headless UI integration renders captured clients from the
  state file.
- `bash -n payload.sh` passes.

---

## First-run hardware checklist

The radio paths cannot be fully validated off-device. On your first run, on a
bench network you own:

1. Run `iw dev` and note the managed radios and monitor vifs. If auto-selection
   picked the wrong radio, set `VENUS_IFACE` / `VENUS_RECON_IFACE`.
2. Start VENUS. Confirm the RECON screen fills with nearby APs. If it stays on
   `SCANNING`, check `/tmp/venus_run.log` for the `iw ... scan` error.
3. Trap a 2.4 GHz open or WPA2 network first. Confirm a phone sees the cloned
   SSID, joins, receives a `192.168.69.x` lease, and gets the portal.
4. Confirm the phone appears as a fly and in `iw dev <iface> station dump`.
5. Submit a harmless test value to the portal and confirm
   `portal_submissions.jsonl` records it.
6. On a second device, press **A** on the trap screen to enable the lure.
   Confirm a monitor radio exists and `aireplay-ng` is installed. If not, the
   engine logs the reason and leaves the trap up.
7. Press **B** twice (drop trap, then quit from RECON). Confirm the stock Pager
   UI returns and no VENUS-owned processes or interfaces remain:
   `pgrep -af 'venus|hostapd'` should show nothing, and `iw dev` should no
   longer list `venus0`.

If you have to recover the stock UI manually:

```sh
/etc/init.d/pineapplepager start
```

---

## Caveats and failure modes

- **WPA3 / 6 GHz clones are open.** A real 6 GHz network requires WPA3/SAE,
  and an open clone will not attract devices that enforce it. VENUS logs a
  warning when the selected target is WPA3 or 6 GHz. 2.4 GHz open/WPA2 targets
  are the reliable case.
- **WEP targets are cloned as open.** hostapd does not reproduce WEP; the
  portal still works, but clients may refuse the security mismatch.
- **DFS channels can delay beacons.** If the target is on a 5 GHz DFS channel
  (52–144), hostapd may perform CAC for up to ~60 seconds before beacons.
  VENUS logs this and keeps the trap up; `health_check` drops it if hostapd
  exits.
- **Some drivers cannot do AP + monitor at once.** The lure needs a second
  radio. If no usable monitor interface exists, the lure disables itself.
- **No internet passthrough.** Clients get DHCP, DNS, and the portal; they do
  not get real upstream connectivity. This is deliberate for a flytrap.
- **Randomized MACs** are labeled `Private (randomized)` and drawn magenta.
  Vendor attribution is best-effort from the bundled OUI table or an external
  file.
- **The portal port fallback is best-effort.** If port 80 is busy, VENUS binds
  8080 and installs a redirect (nftables first, iptables second); if neither
  is usable the portal stays on 8080 with no redirect.
- **The AP runs on a dedicated vif.** `venus0` is created with
  `iw phy <phy> interface add venus0 type __ap` and deleted on exit, so the
  selected radio's original role is restored. If the driver refuses a new
  vif, VENUS falls back to converting the base radio and restores its link
  type on teardown.
- **VENUS refuses to share the Pager's own radio.** The Pager's client-mode
  uplink (`wlan0cli`) and its management/Open/Evil-WPA APs live on the
  internal 2.4 GHz radio, which the firmware drives through its own hostapd.
  Starting a flytrap on that same phy can drag the Pager's connection onto
  your channel and take it offline. Before arming, VENUS checks whether the
  AP radio's phy is serving the uplink or an active firmware AP; if every
  band-capable radio is busy it refuses the trap with a clear message rather
  than risk the Pager. `VENUS_NO_GUARD=1` overrides this for a bench radio
  you know is safe.
- **The DHCP server needs raw sockets.** It runs as root via AF_PACKET, which
  is available on the Pager. If it cannot open the socket, VENUS falls back
  to `dnsmasq` (DHCP only).
- **The engine needs only `python3-light`.** The portal is a small raw-socket
  HTTP server (not `http.server`) and form parsing is hand-rolled, so VENUS
  avoids the `email` and `urllib` packages, which are not part of
  `python3-light`. No `python3-email`/`python3-urllib` package is required.
- **Native UI requires the MIPS library.** `libpagerctl.so` is not portable to
  x86; use headless/sample mode off-device.
- **Deauth is disruptive and legally sensitive.** Leave the lure off unless
  your authorization covers it.

---

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `WAITING FOR ENGINE` | Engine died or has not written state. Read `/tmp/venus_run.log` and `<loot>/last_run.log`. |
| `engine failed to start` dialog | Missing `python3-light`, `hostapd`, or `iw`; the dialog and run log name the missing item. |
| `No module named 'email'` or `'urllib'` | Old build used `http.server`/`urllib`; redeploy this build — the engine now uses only `python3-light` modules. |
| Trap fails immediately | Wrong radio/channel, interface busy, or regulatory rejection. With `VENUS_PAGERCTL=0`, inspect `/tmp/venus_hostapd.log`. |
| `refusing to arm` error | The Pager's client-mode uplink or management AP is active on the only band-capable radio. Turn those off, or override with `VENUS_NO_GUARD=1`. |
| `SCANNING` never fills | Recon radio is the uplink or is in a mode that cannot scan; try `VENUS_RECON_IFACE` or rely on the firmware `*mon` vif. |
| Trap is up, no flies | Clients may not auto-join an open clone; try the lure, a 2.4 GHz target, and confirm the SSID is not hidden. |
| Portal never appears | Confirm DHCP leases in `/tmp/venus_leases` and that the portal bound (`http_port` in state). Probe `http://192.168.69.1/`. |
| No sound/vibration | `pagerctl` could not init; the UI would have fallen back to LOG. Check the run log. |
| Buttons act twice | Firmware 2.0.0 stale events; the 2.5 s debounce handles the launch press. If it persists, check the input queue for repeating events. |
| Stock UI gone after a crash | `/etc/init.d/pineapplepager start`. |

---

## Legal

VENUS is for authorized security testing and lab use. Running a rogue AP, and
especially deauthenticating clients, can disrupt networks and may be illegal
without explicit written permission. You are responsible for how you use it.
