# PagerMesh – Hak5 WiFi Pineapple Pager Payload

**Author:** SECT0101
**Version:** 1.0.1
**Category:** General
**Platform:** Hak5 WiFi Pineapple Pager (and a USB GPS for position) with a Meshtastic radio: the Glytch Mesh Mod, a Wi-Fi radio, or a USB radio
**Protocol:** Meshtastic client API (TCP 4403 or USB serial), the one the phone app uses

> Tested on a Pager with a Heltec radio over Wi-Fi. If you use the Glytch Mesh Mod or a USB radio, please report what works and what does not (see *Testing* below).

---

## 📡 Overview

**PagerMesh** puts Meshtastic on the WiFi Pineapple Pager, the way [PagerTAK](https://github.com/SECT0101/PagerTAK) puts TAK on it. The Pager becomes the screen, keyboard, GPS and map for a Meshtastic radio, driven from the Pager itself or from a browser.

It talks to the radio the way the Meshtastic phone app does, over one of three connections (chosen on first run, on the Pager or in a web browser):

| Connection | Radio | How |
|---|---|---|
| **Glytch Mesh Mod** | the Mod on the Pager's USB-A port | Glytch's Meshtastic payload installs and runs **meshtasticd** on the Pager; PagerMesh connects to it on `127.0.0.1:4403` |
| **Wi-Fi radio** | any Meshtastic radio with Wi-Fi (ESP32 boards: Heltec V3 / V4, LilyGO T-Beam, Station G2…) | turn on Wi-Fi in the radio's *Network* settings; PagerMesh connects to the radio's address, port 4403. The Pager and the radio must be on the same network |
| **USB radio** | a Meshtastic radio plugged into the Pager's USB-A port | the radio's USB serial API (`/dev/ttyUSB*` / `/dev/ttyACM*`) |

---

## ✨ Features

- **Mesh chat**: send and receive on every channel the radio has; **direct messages** to any node with a *delivered* tick when the node acks; **quick messages** (Copy, WILCO, Say again, …); **conversations** (one per DM contact and one per channel, newest first, with unread counts); the **last 7 days of chat** come back when PagerMesh starts; **delete** a message, a conversation or all chats (on the Pager and in the web console; this also deletes them from the chat logs); a sound and new messages on the Pager screen; log in `/root/loot/PagerMesh/chat_YYYYMMDD.log`
- **Node list**: every node heard, nearest first, with **range and bearing from the Pager's GPS**, battery, SNR, hops and *last heard* (`BASE 2.4km NE 87% 3m`)
- **Map on the Pager screen**: USGS basemaps, your position, mesh nodes, nearest-nodes sidebar, chat banner, tiles cached for offline use; **Navigate to** a node shows a live arrow, range and bearing
- **Pager GPS over the mesh**: on the channel you pick (off until you pick one; a public channel asks to confirm), every 5 / 15 / 30 / 60 minutes (15 by default, like Meshtastic), or only when you press *Send position now*
- **Web console** in any browser on the Pager's USB / management network: map with nodes and waypoints, node table and details, chat, SIGINT, radio and bridge settings, *Send position*. Password login.
- **Radio settings** on the Pager and in the web console: **node name**, region, modem preset, role, hop limit, position and telemetry intervals, Wi-Fi, MQTT, Bluetooth, display, power, **channels** (name, key, MQTT up/down, position precision) with a **share link and QR code**, restart. Only the fields you change are written; the radio keeps everything else. Region, preset, Wi-Fi and channel changes ask first
- **Node tools**: details (hardware, role, last heard, position age, MQTT, favorite, packets and RSSI heard), **traceroute** with SNR per hop, **request position**, **favorites**, **hide old nodes**
- **Waypoints**: mesh waypoints on both maps; drop one from the web map (name, description, expiry) and delete your own
- **Navigate from the Pager map**: press **A** on a centered map, pick a node or waypoint in the nearest list, **A** again for the arrow, range and bearing
- **Set the Pager's location on the web map** (click the map) when there is no GPS fix; it is sent with the position reports and used for range / bearing
- **Direct message alert** on the Pager: its own sound and light, optionally a popup
- **Mesh SIGINT**: every packet the radio passes on, including channels you have no key for (shown as encrypted), with RSSI, SNR and hops; traffic per node and per type, packets per minute, position trails on the web map, **pcap / CSV export**, and a **modem preset scan** that listens on each preset and puts the radio back afterwards
- **Mesh ↔ TAK bridge**: mesh nodes become TAK contacts, and chat on one mesh channel and TAK *All Chat Rooms* go both ways (TLS 8089 with a client certificate, TCP 8087, or UDP). Direct messages are never bridged
- **Setup on the Pager or in a web browser**, like PagerTAK: pick the connection, **Test connection**, save. Change it later in *Settings > Radio connection* or the web console's *Settings* tab
- **Sets up the Mesh Mod for you**: if meshtasticd is not installed or not running, PagerMesh runs Glytch's payload to install it, start it, and (once, if you agree) turn on *Enable at Boot*

---

## ✅ Requirements

| What | Why |
|---|---|
| A Meshtastic radio | the [Glytch Mesh Mod](https://github.com/glytchtech/Pager-Mod-Docs/tree/main/Mesh), a radio with Wi-Fi, or a USB radio |
| Mesh Mod only: Glytch's Meshtastic payload at `/root/payloads/user/general/Meshtastic/payload.sh` | installs and runs meshtasticd. PagerMesh does not include it: get it from [glytchtech/Pager-Mod-Docs](https://github.com/glytchtech/Pager-Mod-Docs/tree/main/Mesh) |
| `python3-light` | the mesh service, map and web console (asks before installing, about 5 MB) |
| USB GPS (Pager *Settings > GPS*) | range / bearing and sending your position. Everything else works without one |
| Internet, first time only | installing Meshtastic and python3-light; map tiles (cached afterwards) |

> ⚠️ **Mesh Mod on current Pager firmware:** Glytch's installer (Version 9) checks for one exact Pager kernel build and stops with *"Unsupported Pager kernel build"* on newer firmware. The fix is a one-line change waiting in [Pager-Mod-Docs PR #5](https://github.com/glytchtech/Pager-Mod-Docs/pull/5). Until it is merged, use the `payload.sh` from that pull request.

> ⚠️ **Mesh Mod and SD card packages:** Glytch's installer also refuses to run while any package is installed on the SD card (`/mmc`). PagerMesh checks this first and lists them; remove them (`opkg remove <name>`), install Meshtastic, then reinstall them if you need them. PagerMesh itself only installs to main storage.

---

## 🚀 Install

1. Copy the `PagerMesh` folder to `/root/payloads/user/general/PagerMesh/`.
2. Mesh Mod only: copy Glytch's `payload.sh` to `/root/payloads/user/general/Meshtastic/payload.sh` (its own folder, next to PagerMesh, not inside it).
3. Run **PagerMesh** from the payload menu (General). It installs `python3-light` if needed, then asks **PagerMesh setup: On the Pager / In a web browser**:
   - **On the Pager**: pick *Glytch Mesh Mod*, *Wi-Fi radio* (enter its IP address and port, 4403) or *USB radio* (pick the port). Wi-Fi and USB are tested before saving.
   - **In a web browser**: say where your browser is (*Pager Wi-Fi / USB-C*, or *Same Wi-Fi as the Pager*), set a web password, open the address the Pager shows (`http://172.16.52.1:8585` on the Pager's own Wi-Fi or USB-C), sign in, choose the radio on the *Settings* page, **Test connection**, **Save and connect**. The web console stays on afterwards.
4. Mesh Mod: the first run installs Meshtastic if needed (about 5 minutes, needs internet, **do not interrupt**), starts meshtasticd, and asks once whether it should start at every boot (recommended).
5. In the **Meshtastic phone app**, set the radio's **Region** and **node name** (LoRa settings). The radio does not transmit until a region is set; PagerMesh warns you while it is unset. (Mesh Mod: connect the app to the Pager at `172.16.52.1`.)

### Wi-Fi radio tips

- In the radio's settings (Meshtastic app > *Network*) turn **Wi-Fi on** and join the same network as the Pager: either the Pager's own management Wi-Fi, or a network the Pager joins as a client. The radio shows its IP address on its screen and in the app.
- With Wi-Fi on, Meshtastic turns the radio's Bluetooth off, so the phone app connects over Wi-Fi too.
- A radio serves one API client at a time: while PagerMesh is connected, the phone app may be dropped (and the other way round).

### USB radio tips

- Plug the radio into the Pager's USB-A port; it shows up as `/dev/ttyUSB0` or `/dev/ttyACM0`. The GPS's port is hidden from the list.
- If no port appears, the Pager may lack the driver for that radio's USB chip (CP210x, CH340, …): please report it with the output of `lsusb` and `dmesg | tail`.

---

## 🎮 Controls

Main screen:

| Button | Action |
|---|---|
| **A** | Menu: Map, Nodes, Chat >, Send position now, SIGINT >, Status, Settings >, Exit |
| **UP** | Quick message to the primary channel |
| **DOWN** | Type a message to the primary channel |
| **RIGHT** | Send position now |
| **LEFT** | Status (node, region, nodes heard, GPS, web console address) |
| **B** | Exit (Meshtastic keeps running for the phone app) |

**Nodes**: pick a node → *Navigate to*, *Show on map*, *Direct message*, *Details*, *Traceroute*, *Request position*, *Add to / Remove from favorites*.
**Chat**: *Conversations* (pick one to read it, *Reply*, delete a message or *Delete conversation* (asks first); opening it clears its unread count), *Message channel*, *Quick message channel*, *Direct message*, *Delete all chats* (asks first).
**SIGINT**: *Traffic stats*, *Last packets*, *Save capture to loot* (pcap + CSV), *Preset scan*, *Stop preset scan*.
**Settings**: *Radio connection*, *Radio settings* (name, region, preset, role, hop limit, radio position, channel QR code, restart radio), *Send position*, *TAK bridge*, *DM alert*, *Hide old nodes*, *Web console*, *Message sound*, *Meshtastic at boot*.

**Map** (same viewer as PagerTAK): D-pad pans, **A** re-centers; **A** on a centered map opens the pick list (**UP / DOWN** pick a node or waypoint, **A** navigate, **LEFT / RIGHT** show it on the map, **B** cancel); **hold B + UP / DOWN** zooms, **hold B + LEFT / RIGHT** toggles the nearest-nodes list, **hold B + A** next basemap, **tap B** exits.

### LED

| LED | Meaning |
|---|---|
| Magenta | Setup / checking |
| Cyan, slow | Connecting to meshtasticd |
| Green | Connected to the mesh |
| Red, slow | Disconnected, retrying |

---

## 🌐 Web console

*Settings > Web console > Turn ON* asks for a password (8 characters or more) and starts the console. *Listen on* chooses where browsers can reach it:

| Listen on | Address | |
|---|---|---|
| **Same Wi-Fi as the Pager** (default) | `http://172.16.52.1:8585`, plus `http://<Pager's address on your Wi-Fi>:8585` | any device on the network the Pager joined as a client. Anyone on that network can reach the sign-in page, so use a strong password |
| **Pager Wi-Fi / USB-C** | `http://172.16.52.1:8585` only | only devices on the Pager's own management Wi-Fi or USB-C |

The Pager shows every address in *Status*, *Settings > Web console > Show address*, and when the console starts. Browser setup asks the same question first.

It shows the map with every node and waypoint that has a position, the node table (click a node for its details and tools, double-click to message it), chat by conversation with quick-message buttons, and the *SIGINT* tab. **Click the map** to set the Pager's location or drop a waypoint. *Send position* broadcasts the Pager's position. The *Settings* tab has the radio connection (with *Test connection*; it switches as soon as you save), **Radio settings**, **Channels** (with the share link / QR code), **PagerMesh** options and the **Mesh ↔ TAK bridge**.

Security: salted password hash in `web/auth`, session cookie (HttpOnly, SameSite=Strict), lock-out after repeated wrong passwords, and every action needs a header a cross-site page cannot send. By default it listens on the Pager's management network only.

---

## ⚙️ Settings

Saved with `PAYLOAD_SET_CONFIG`; the values under `# Options` in `payload.sh` are only defaults.

| Setting | Default | |
|---|---|---|
| Send position: share on | nobody (off) | the mesh channel for the Pager's position. A public channel (no key, the default key or a simple key) asks to confirm: anyone on it can see where the Pager is |
| Send position: how often | every 15 min | 5 / 15 / 30 / 60 min or manual only. Less often saves airtime on busy meshes |
| Radio connection | set on first run | Glytch Mesh Mod / Wi-Fi radio / USB radio, changed on the Pager or in the web console |
| Web console | off | on / off, *Listen on* (every address, or only the Pager's own Wi-Fi / USB-C), password, address |
| Message sound | `bonus` | ringtone for new messages, or none |
| DM alert | sound + light | direct messages: sound + light, + popup, or off |
| Hide old nodes | show all | hide nodes not heard for 1 / 2 / 6 / 24 hours |
| Map-set location | none | set by clicking the web map; used when there is no GPS fix |
| TAK bridge | off | server, protocol (TLS / TCP / UDP), port, mesh nodes to TAK, chat both ways, mesh channel |
| Meshtastic at boot | asked on first run | runs Glytch's *Enable at Boot* ON / OFF |

`payload.sh` options: `MESH_HOST` / `MESH_PORT` (meshtasticd API), `NODE_MAX_AGE` (seconds a node stays on the map, default 2 h), `QUICK_MESSAGES`, `MAP_SOURCE`, `MAP_ZOOM`, `WEB_PORT`.

Radio settings (name, region, channels and the rest) are kept **on the radio**: change them in PagerMesh or the Meshtastic phone app, whichever is at hand. Most changes make the radio restart; PagerMesh reconnects by itself.

---

## 🛰️ Mesh SIGINT

PagerMesh works at the mesh level, with what the radio passes to its app: every packet it decodes, and packets on channels it has no key for (sender, size, RSSI, SNR, hops; shown as *ENCRYPTED*). The web console's *SIGINT* tab shows packets per minute, packet types, traffic per node (packets, last / average RSSI, SNR, encrypted count) and the last packets, and can draw position trails on the map. **pcap** export uses LINKTYPE_USER0 (147), one Meshtastic MeshPacket per record, for a Wireshark Meshtastic dissector or your own tools; **CSV** has one line per packet. On the Pager, *SIGINT > Save capture to loot* writes both to `/root/loot/PagerMesh`.

**Preset scan** sets the radio to each modem preset in turn (it restarts each time), listens for 30 s to 5 min, counts packets and nodes, and then puts the radio's LoRa settings back exactly as they were. If PagerMesh is stopped during a scan, it puts them back the next time it connects. You are off your own mesh while a scan runs.

Raw LoRa capture (frequency scanning, LoRaTap) needs changes to the radio firmware and is not part of PagerMesh.

---

## 🔗 Mesh ↔ TAK bridge

*Settings > TAK bridge* on the Pager, or the web console's *Settings > Mesh ↔ TAK bridge*:

- **Mesh → TAK**: every mesh node with a position becomes a TAK contact (`PagerMesh.!nodeid`, cyan team member) with battery, SNR and hops in the remarks; resent every 5 minutes and when it moves.
- **Chat**: only on a mesh channel with its own key. Channel 0 is public on most meshes (no key, the default key or a well-known simple key), so it can't be picked; until you pick a private channel, chat is paused and node positions still go to TAK. Text on the chosen channel goes to TAK *All Chat Rooms* under the sender's name; *All Chat Rooms* messages from TAK go to that mesh channel as `[callsign] text` (at most one every 5 s). Direct messages are never bridged, in either direction.
- **TLS** (8089) needs `client.pem` (certificate and key, unencrypted PEM) and ideally `ca.pem` in `PagerMesh/certs/`, and `openssl` (`opkg install openssl-util`). If PagerTAK is installed and has its certificates, PagerMesh uses those. **TCP** (8087) needs nothing; **UDP** sends only.

---

## 🧩 How it works

```
 Mesh Mod (SX1262, USB) ── meshtasticd ── TCP 127.0.0.1:4403 ─┐
 Wi-Fi radio (ESP32) ──────────────────── TCP <radio>:4403 ───┼── PagerMesh mesh service (mesh/pagermesh.py)
 USB radio ────────────────────────────── /dev/ttyUSB0 ───────┘     ├── files in /tmp/pagermesh ── payload.sh menus, Pager map
                                                                    └── web console (web/pagermesh_web.py)
```

- `mesh/pagermesh.py` keeps one connection to the radio (meshtasticd, a Wi-Fi radio or a USB radio), reads the node database and channels, follows packets (text, position, node info, telemetry, acks), and sends chat and positions. Standard library only.
- `mesh/radiocfg.py` reads and changes the radio's settings: PagerMesh keeps each settings section as the radio sent it and replaces only the fields you edit, so settings it does not know stay untouched. Changes go to the radio as admin messages from the local app (no remote admin).
- `mesh/sigint.py` keeps the packet log, traffic stats, trails and the pcap / CSV export; `mesh/takbridge.py` is the TAK bridge.
- `map/qrcodegen.py` is Project Nayuki's QR code generator (MIT) for the channel QR code; `map/pagermesh_qr.py` shows it on the Pager screen.
- `mesh/meshproto.py` is a small Meshtastic protobuf reader / writer for the fields PagerMesh uses, plus the TCP and serial stream framing (no `protobuf` or `pyserial` package needed on the Pager; the serial port is set up with busybox `stty`).
- `payload.sh` reads the Pager GPS (`GPS_GET`, `gpspipe`), runs the menus, and hands commands to the service through `/tmp/pagermesh/outbox`.
- `map/` is PagerTAK's Pager map viewer and pure-Python screen driver.

Position packets are sent as `POSITION_APP` broadcasts on the chosen channel with the Pager GPS fix (location source *external*). Direct messages ask for an ack, like the phone app.

---

## 🧪 Testing

Testers welcome, especially with the Glytch Mesh Mod or a USB radio. Please open an issue with:

- the connection you used (Mesh Mod / Wi-Fi / USB), the radio model and its Meshtastic firmware version
- Pager firmware version, and for the Mesh Mod whether you used the PR #5 installer
- whether PagerMesh and the **Meshtastic phone app** can be connected at the same time (radios may allow only one API client at a time; PagerMesh keeps its connection open)
- whether messages, direct-message ticks, positions and the node list match what the phone app shows
- whether other nodes see the Pager's position

No radio? `tools/fake_meshtasticd.py` in the repository simulates meshtasticd with demo nodes, settings changes, restarts, traceroutes and waypoints, and `tools/fake_takserver.py` stands in for a TAK Server (see the main README).

---

## 🛠️ Troubleshooting

| Problem | Fix |
|---|---|
| *Glytch Meshtastic payload not found* | Copy Glytch's `payload.sh` to `/root/payloads/user/general/Meshtastic/` |
| *Unsupported Pager kernel build* | Use the installer from [PR #5](https://github.com/glytchtech/Pager-Mod-Docs/pull/5) |
| *Packages installed on the SD card* | `opkg remove` the listed packages, install Meshtastic, reinstall them |
| *Meshtoad USB radio … is not present* | The Mod is not detected: reseat it; check `lsusb` shows `1a86:5512`; try another USB device in the port |
| Wi-Fi radio: *refused the connection* | Wi-Fi is off in the radio, or a wrong port (4403) |
| Wi-Fi radio: *cannot reach* | The Pager and the radio are not on the same network; check the radio's IP address on its screen |
| USB radio: no port in the list | Re-plug it; the Pager may lack the USB driver for that radio (report `lsusb` / `dmesg`) |
| Region not set | *Settings > Radio settings > Region* on the Pager, the web console's *Radio settings*, or the phone app |
| No nodes | Give it a few minutes outdoors; check region and channel match your mesh |
| Phone app keeps disconnecting | Exit PagerMesh while you use the phone app, then report it (see *Testing*) |
| Can't open the web console from my home Wi-Fi | Check *Settings > Web console* is on and *Listen on* is *Same Wi-Fi as the Pager* (the default from 1.0.1), or use the Pager's own Wi-Fi / USB-C at `172.16.52.1` |
| Messages from one radio never arrive | Another app (phone over Bluetooth, a browser, a gateway) may be connected to the same radio and take them; disconnect it. `tail -40 /tmp/pagermesh/packets.log` shows every packet PagerMesh gets |
| Radio settings: *not connected to the radio* | The radio is restarting after a change; wait a few seconds |
| TAK bridge: *no client.pem* | Put `client.pem` (and `ca.pem`) in `PagerMesh/certs/`, or use TCP 8087 |
| TAK bridge: *TLS needs the openssl command* | `opkg install openssl-util` |
| Logs | `/tmp/pagermesh-service.log`, `/tmp/pagermesh-map.log`, `/tmp/pagermesh/packets.log`; meshtasticd: `logread -e meshtasticd` |

---

## 📄 License

GPL-3.0 (see `LICENSE` in the repository). `map/qrcodegen.py` is © Project Nayuki, MIT License (notice in the file). Meshtastic and meshtasticd are © Meshtastic LLC (GPL-3.0); Meshtastic® is a registered trademark of Meshtastic LLC. PagerMesh is a community project and is not affiliated with Meshtastic, Glytch or Hak5.
