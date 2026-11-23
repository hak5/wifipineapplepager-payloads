# PagerTAK – Hak5 WiFi Pineapple Pager Payload

**Author:** SECT0101
**Version:** 2.3.2
**Category:** General
**Platform:** Hak5 WiFi Pineapple Pager (with USB GPS)
**Protocol:** TAK Cursor-on-Target (CoT) XML over TLS / TCP / UDP

---

## 📡 Overview

**PagerTAK** turns the WiFi Pineapple Pager into a TAK end user device. It reads the Pager's GPS and reports its position to a **TAK Server** as a Cursor-on-Target (CoT) event, so the Pager shows up on ATAK, WinTAK, iTAK, WebTAK and CloudTAK maps like any other team member.

On top of that it does **TAK GeoChat**, **alerts** (911 and ATAK's other alert types), **field reports**, a **map on the Pager screen**, and turns the Pager's radios into **TAK sensors**: rogue / evil-twin access points, trackers following you, drone Remote ID, Wi-Fi site surveys and a fox hunt. A **web console** puts all of it in a browser on your laptop or phone.

The core is plain Bash plus Pager DuckyScript commands, with nothing to compile. TLS needs `openssl`. Everything else is optional and installed only when you first use that feature, after asking (see *Requirements*).

---

## ✨ Features

**TAK basics**
- **Position reporting (SA)** at a configurable interval as a friendly ground unit (`a-f-G-U-C`): callsign, team color and role; GPS accuracy, height, course and speed; battery, charging and satellites in remarks; `takv` so TAK shows it as a Pager
- **GeoChat**: All Chat Rooms or a **direct message** to any TAK user seen; **quick messages** (Copy, WILCO, Say again, …, editable in the web console); **reply** to the last message in two clicks; **delivered / read receipts** both ways (ticks in ATAK and CloudTAK, and in the web console); an **unread count** and a magenta LED until you open Chat; store-and-forward while offline; log in `/root/loot/PagerTAK/chat_YYYYMMDD.log`
- **Alerts**: 911 Alert, Ring The Bell, Geo-fence Breached, Troops In Contact or a named Custom alert, to everyone or only to people you pick, repeated with every position report until you cancel (the cancel goes to the same people). Incoming alerts from other users raise a full-screen `ALERT`
- **Three transports**: `tls` (8089, client certificate, recommended), `tcp` (8087), `udp` (send-only); auto-reconnect with backoff and LED status
- **No fix?** Sends the last known fix or a manual position, marked *NO FIX*. If the clock is clearly wrong it is set from GPS, because TAK drops CoT with bad timestamps
- **TAK channels**: choose which server groups you send to and receive from (web console)
- On-device **setup wizard** and **Settings** menu, saved with `PAYLOAD_SET_CONFIG`; on-device `.p12` → PEM conversion, or upload PEMs in the web console

**Field tools**
- **Field reports**: SALUTE, SITREP, MEDEVAC 9-line (opens in ATAK's 9-line tool) and Damage assessment, as TAK markers plus a GeoChat summary, with MGRS and DTG filled in (see *Field reports* below)
- **Map on the Pager screen**: USGS basemaps (ATAK map source XML), your position and heading, TAK users, markers, alerts, nearest-contacts sidebar, scale bar, chat banner; tiles cached for offline use (see *Map setup* below)
- **Contacts**: nearest TAK users and markers with distance and bearing (`ALPHA-1 1.2km NE`); **Navigate to** shows a live arrow, range and bearing to one contact
- **Man-down watchdog**: warns you, then sends 911 by itself if you stop moving; can also watch chosen teammates
- **Range filter**: hide TAK items farther than a set distance (web console and Pager map)

**Sensors** (Wi-Fi and Bluetooth radios as TAK sensors)
- **Sensor stats**: Wi-Fi recon counts (APs, open APs, clients) in every position report (see *Sensor stats* below)
- **Evil-twin / rogue AP watch**: learn the site's networks, then alert on evil twins, security downgrades and new open APs (see *Evil-twin watch* below)
- **Trackers / counter-surveillance**: AirTag / Find My, Tile, SmartTag, Google FMDN, Flock, Axon; alerts when one follows you (see *Trackers* below)
- **Drone Remote ID**: drones and their operators on the TAK map (see *Drone Remote ID* below)
- **Site survey**: walk the site, get an ATAK data package (KML + CSV) on the TAK Server (see *Site survey* below)
- **Geofences**: zones that alert when people, drones, one chosen contact or you enter or leave, optionally as a TAK alert; drawn in the web console or set around your position on the Pager
- **SIGINT** (web console, receive-only): radio channel control, Wi-Fi AP / client / probe tables, fox hunt with a signal trail

**Web console** (see *details* below)
- Everything above in a browser over USB, Wi-Fi or NetBird, with a login: map with measure, range rings, MGRS, markers and drawings you can send to everyone or one person, offline map download, KML/KMZ overlays, trails, CoT details, photo and file sharing, and a QR code on the Pager screen to open it from a phone

---

## 🎮 Controls

| Button | Action |
|---|---|
| **A** (green) | Menu (see below) |
| **UP** | Quick message to All Chat Rooms |
| **DOWN** | Type a message to All Chat Rooms |
| **RIGHT** | Send position now |
| **LEFT** | Status (link, last report, GPS, contacts, queued messages) |
| **B** (red) | Exit (asks first) |

### Menu

`>` opens a submenu, `< Back` goes up a level. Each menu reopens on your last pick.

```
PagerTAK
├── Map
├── Contacts          nearest first · Navigate to · Show on map · Direct message · Geofence alert
├── Chat >            Reply to … · Message All · Quick message All · Direct message · Chat history · Clear chat history   (shows "(3 new)")
├── Reports >         SALUTE · SITREP · MEDEVAC 9-line · Damage assessment · Report history
├── Sensors >         Geofences > · Evil-twin watch > · Trackers / counter-surv > · Drone Remote ID > · Site survey > · Man-down watchdog > · Sensor stats · Deauth alerts
├── SEND ALERT        alert type, everyone or chosen contacts (shows CANCEL ALERT while active)
├── Send position now
├── Status
├── Settings >
│   ├── TAK server >  Server host · Protocol · Port · Certificates
│   ├── Identity >    Callsign · Team color · Role
│   ├── Position >    Manual position · Report interval
│   ├── Map >         Map source · Custom tile URL · Cache map tiles
│   ├── Web console > On/Off · Show address · Show QR code · Set password · Listen on · Port · HTTPS
│   ├── Chat sound
│   ├── Clear received items
│   └── Reset all settings
└── Exit PagerTAK
```

### Map controls

| Button | Action |
|---|---|
| **D-pad** | Pan (switches to PAN mode) |
| **A** (green) | Re-center on me (FOLLOW mode) |
| **hold B (red) + UP / DOWN** | Zoom in / out |
| **hold B (red) + LEFT / RIGHT** | Show / hide the nearest-contacts sidebar |
| **hold B (red) + A (green)** | Next basemap (remembered for next time) |
| **tap B (red)** | Back to PagerTAK |

**Navigate to** (from *Contacts*): a big arrow to the contact with range, bearing and the age of their last update. North is up while you stand still (the Pager has no compass, so turn until the N mark points north); while you move faster than about 1 m/s the arrow follows your GPS course instead. **A** (green) opens the map on the contact, **B** (red) goes back.

Symbols: **cyan ring/arrow** = you (arrow when moving, gray when there is no fix), **circles** = TAK users in their team color, **diamonds** = map markers by affiliation (red hostile, orange suspect, yellow unknown, green neutral).

## 💡 LED States

| LED | Meaning |
|---|---|
| Magenta solid | Setup |
| Cyan slow | Connecting to TAK Server |
| Green solid | Connected, GPS fix |
| Yellow solid | Connected, no GPS fix (last known / manual position) |
| Red slow | Disconnected, retrying |
| Magenta slow | Unread chat (until you open *Chat* on the Pager or in the web console) |

---

## 🧰 Requirements

- WiFi Pineapple Pager with a USB GPS, configured under **Settings > GPS** (run the `gps-checker` payload if unsure). Without GPS, set a manual position.
- A network path from the Pager to your TAK Server: client-mode Wi-Fi, a phone hotspot or USB tether, or a VPN (`WIREGUARD_CONFIGURE` / `OPENVPN_CONFIGURE`, or the [NetBird VPN payload](../../remote_access/NetBird_VPN)).
- **TLS mode:** `openssl` (the payload offers to install it: `opkg update && opkg install openssl-util`) and a TAK client certificate.

Optional, only when you use the feature. PagerTAK asks before installing anything:

| Feature | Needs |
|---|---|
| Map on the Pager screen | `python3-light`, current firmware (`UI_TAKEOVER`). The screen driver ships with PagerTAK |
| Web console | `python3-light` (Leaflet is included) |
| QR code on the Pager screen | `python3-light`, `qrencode` |
| Sensor stats, evil-twin watch, site survey, SIGINT Wi-Fi tables | `sqlite3-cli`, and Recon running |
| Trackers / counter-surveillance | Bluetooth tools (`btmon`, `hcitool`) |
| Drone Remote ID | `python3-light`, `tcpdump` (decoder included) |
| Fox hunt, radio control | the Pager's own `_pineap` and `PINEAPPLE_EXAMINE_*` (built in) |
| Photo / file sharing, TAK channels | the TAK Server's Marti API (8443 with your certificate, or 8080) |
| Certificate enrollment, .p12 import, connection test | `openssl-util` (the same as TLS mode) |

Storage: everything installs to the SD card (`/mmc`) when the internal flash is short.

---

## ⚙️ Installation

1. Copy the `PagerTAK` folder to the Pager:
   ```
   scp -r PagerTAK root@172.16.52.1:/root/payloads/user/general/
   ```
2. On the Pager, open **Payloads > User > General > PagerTAK**.
3. The first run asks how to set up:
   - **On the Pager**: the setup wizard asks for the server, protocol, port, callsign, team and role.
   - **In a web browser**: PagerTAK starts the web console in setup mode and shows its address (A shows a QR code). In the browser you enter the server, add a certificate, set your callsign, test the connection, and press **Finish setup**.
4. **TLS mode** needs a client certificate. Pick whichever is easiest (details below): enroll with your TAK username and password, import the ATAK connection package, upload a `.p12`, or copy files into `certs/`.
5. Optional: **Settings > Web console** to use PagerTAK from a browser, and **Sensors** to turn on the sensors you want.

### Certificates (TLS / port 8089)

- **Enroll with your TAK account** (easiest, needs the server's certificate enrollment on port 8446). In the web console: *Settings > Enroll with your TAK account*. On the Pager: *Settings > TAK server > Enroll*, or pick *Enroll* when the first run finds no certificate. The Pager makes its own key and the TAK Server signs it, like ATAK's *Use Authentication*. The key never leaves the Pager, and no `.p12` conversion is needed, so this also works on firmware that can't read old `.p12` files. Log: `/tmp/pagertak-enroll.log`.
- **Import an ATAK connection package** (web console, *Settings > Import a connection package*): the `.zip` your TAK admin hands out for ATAK. PagerTAK reads the server, port and protocol from its `.pref` and converts the `.p12` files inside. A package without a client certificate (an enrollment package) sets the server, and you then enroll.
- **Upload a certificate** (web console, *Settings > Upload a certificate*): a `.p12` (the Pager converts it, password default `atakatak`) or an unencrypted PEM.
- **Test connection** (web console *Settings*, or Pager *Settings > TAK server*) checks the address, the port, TLS, your client certificate and the server certificate, and says which one fails. The status shows how many days your certificate has left, and PagerTAK warns 30 days before it expires.

Or create a **dedicated client certificate for the Pager** on your TAK Server (for example `makeCert.sh client pager01`) and do one of the following:

- **Copy the .p12 files:** copy `pager01.p12` and `truststore-root.p12` into `certs/`. On first run, PagerTAK asks for each password (TAK default prefilled) and converts them.
  TAK Server `.p12` files use older RC2/3DES encryption, which OpenSSL 3 only reads with its legacy module. If that module is missing, PagerTAK offers to install `libopenssl-legacy` (opkg, needs internet). A wrong password is detected separately and asked again. Conversion errors are logged to `/tmp/pagertak-cert.log`.
- **Or convert on your TAK Server or a PC** and copy only the PEM files. **This is required on Pager firmware whose OpenSSL can't load the legacy module**, which shows up as `symbol not found` in `/tmp/pagertak-cert.log`:
  ```
  # OpenSSL 3 (Ubuntu 22.04+, most TAK servers). Drop -legacy on OpenSSL 1.1
  openssl pkcs12 -legacy -in pager01.p12 -nodes -out client.pem -passin pass:atakatak
  openssl pkcs12 -legacy -in truststore-root.p12 -nokeys -out ca.pem -passin pass:atakatak
  scp client.pem ca.pem root@172.16.52.1:/root/payloads/user/general/PagerTAK/certs/
  ```
  `-nodes` writes the private key **without** a password, which PagerTAK needs. Treat `client.pem` like a password and don't commit it anywhere.

`client.pem` (cert plus private key) is required. `ca.pem` is optional but recommended; without it the server certificate is **not** verified.

---

## 🗺️ Map setup

The map is optional. The first time you open **Menu > Map**, PagerTAK offers to install `python3-light` from opkg (to the SD card when available). Nothing else is downloaded: the screen driver, `map/pagerfb.py`, is PagerTAK's own pure-Python code. It draws to the Pager's framebuffer, reads the buttons, and decodes PNG tiles itself. USGS basemaps are fetched as PNG for the Pager screen; the browser map still uses the normal tiles.

The map takes over the screen with the `UI_TAKEOVER` / `UI_RELEASE` commands, so it needs **current Pager firmware**. While the map is open, PagerTAK keeps reporting position and receiving chat in the background.

### Basemaps (ATAK map source XML)

Basemaps use the same **ATAK map source XML** format (`<customMapSource>`) as ATAK. They live in `map/sources/`. Built in:

| Source | Content | Max zoom |
|---|---|---|
| **USGS Topo** (default) | Topographic: roads, names, contours, hydrography | 16 |
| **USGS Imagery** | Aerial orthoimagery (NAIP) | 16 |
| **USGS Imagery Topo** | Imagery with roads, names and contours on top | 16 |

These come from the USGS National Map and are public-domain US-government data. They cover the US only.

- **Use your own ATAK sources:** copy any ATAK `customMapSource` XML into `map/sources/`. Supported URL tokens: `{$z} {$x} {$y} {$q}` (quadkey) and `{$serverpart}`. WMS and multi-layer XMLs are not supported.
- **Pick a source** in **Settings > Map source**, or switch on the map with **hold B (red) + A (green)**.
- **Custom tile URL** (Settings) adds a plain `{z}/{x}/{y}` server as the *Custom* source, e.g. a self-hosted TileServer GL.
- Tiles are cached per source in `tiles/<source>/` and download on demand while the map is open and the Pager is online.
- **Settings > Cache map tiles** pre-downloads zoom 10–16 around your position for offline use. It is capped at 6,000 tiles per run.

> ⚠️ Only cache sources whose terms allow it. **Google** tiles are not included: Google's terms prohibit caching, pre-fetching and offline use. The public **OpenStreetMap** tile servers also forbid bulk/offline downloading. The USGS services are public domain.

Without tiles, the map still works on a dark grid with all contacts, markers, distances and the scale bar.

## 📝 Field reports

**Menu > Reports**. Each report asks for a location: **at my position**, **offset from me** (direction plus distance in meters, e.g. "300 m NE"), or an **entered lat,lon**. The location is converted to **MGRS** on the Pager, and times use a military **DTG** (`201530Z NOV 26`). Every report asks for confirmation before sending. It then goes out as a TAK marker plus a GeoChat summary to All Chat Rooms, appears on the Pager's map, and is logged to `/root/loot/PagerTAK/reports.log`.

| Report | What you fill in | In TAK |
|---|---|---|
| **SALUTE** | Size, Activity, Location, Unit/uniform, Time, Equipment, plus notes | Marker typed *suspect / hostile / unknown / neutral*, full SALUTE in remarks |
| **SITREP** | Status, situation, PAX, needs (multi-select) | Spot marker colored by status (green / yellow / orange / red); each new SITREP updates the same marker |
| **MEDEVAC 9-line** | Lines 1–9 (precedence, litter/ambulatory and nationality counts by tapping each line) | `b-r-f-h-c` with ATAK's `<_medevac_>` detail, so it **opens in ATAK's 9-line MEDEVAC tool**. Line 2 is remembered |
| **Damage assessment** | Structure, damage level, hazards (multi-select), injured, trapped/missing, access, notes | Spot marker colored by damage (black destroyed, red major, orange minor, yellow affected, green none) |

Picks that offer **Other (type)** let you type a custom value.

## 🛡️ Evil-twin / rogue AP watch

**Menu > Sensors > Evil-twin watch**, or the *Sensors* tab of the web console. It is detection only: it reads the Pager's recon database and transmits nothing over the air. It needs **Recon running** and `sqlite3` (`opkg install sqlite3-cli`).

1. **Learn site Wi-Fi.** Name the site profile (e.g. `HQ`) and choose how many minutes to learn. Walk the facility while the Pager records every access point it hears; press B to stop early.
2. **Approve.** You get a list of every network heard, with its AP count and security. Toggle the ones that are **yours**, then **Save**.
In the web console, *Find networks* lists what recon heard in the last 5 to 240 minutes; tick your networks, name the site and **Save**.

3. **Watch: ON.** Every 30 s PagerTAK checks the last 90 s of recon and alerts on:

| Alert | Meaning | Severity |
|---|---|---|
| **EVIL TWIN** | One of your network names broadcast from an access point that is **not** approved | High: hostile marker + full-screen alert |
| **DOWNGRADE** | One of your networks seen open or with weaker security than approved | High |
| **NEW OPEN AP** | An open network that was not there when the site was learned (on by default) | Medium: suspect marker |
| **NEW AP** | Any access point not seen while learning (off by default; noisy in busy areas) | Low |

Each alert puts a marker at the Pager's position, which is where it was heard. It also posts a GeoChat message to All Chat Rooms and logs to `/root/loot/PagerTAK/watch.log`. The same access point won't alert again for 30 minutes.

- **Approve AP from alert:** if a legitimate new AP was installed, approve it straight from the alert list.
- **Review protected networks** lists what the profile protects.
- **Profiles** are saved in `watch/<profile>.approved` and `watch/<profile>.known`, so you can keep one per facility. The watch resumes automatically when PagerTAK starts.
- **To verify on your Pager:** the watch assumes the recon database updates each AP's time when it is heard again (other payloads label that column "Last seen").

## 🕵️ Trackers / counter-surveillance

**Menu > Sensors > Trackers / counter-surv**. The Pager **listens only**: it uses passive Bluetooth LE (`hcitool lescan --passive` + `btmon`, so no scan requests are sent) plus the Wi-Fi recon database. It needs `bluez-utils`, which it offers to install (on the Pager, or with *Install Bluetooth tools* in the web console's *Sensors* tab).

| Detects | How |
|---|---|
| **Apple Find My** (AirTag and Find My accessories) | Apple advertisement type 0x12 |
| **Tile** | Bluetooth service 0xFEED / 0xFEEC |
| **Samsung SmartTag** | Bluetooth service 0xFD5A |
| **Google Find My Device** tags | Service data 0xFEAA with frame 0x40/0x41 |
| **Flock Safety** cameras / Penguin batteries | BLE names (Flock / Penguin / FS Ext Battery), manufacturer 0x09C8, MAC prefix b4:1e:52, Wi-Fi `Flock-*` / `Penguin-*` |
| **Axon (TASER)** body cams / devices | MAC prefixes 00:25:DF, 00:58:28, 00:C0:D4, 84:70:03 (Bluetooth and Wi-Fi) |

**Alerts** each place a marker where the Pager heard the device, post a GeoChat message, and log to `/root/loot/PagerTAK/trackers.log`:

- **FOLLOWING** (high, on by default): the same tracker was seen for **10+ minutes** at **3+ places at least 200 m apart**, so you moved and it came along. AirTags separated from their owner keep the same address for about a day, which is the stalking case this targets. A stationary tag nearby does not trigger it.
- **Flock / Axon nearby** (on by default): once per device per hour.
- **Every tracker seen** (off by default): very noisy in public.
- **Send alerts to TAK** can be turned off to keep alerts on the Pager only.
- **Detected devices** lists what has been heard this session (type, MAC, times seen, minutes). Pick one to **ignore** it, e.g. your own or a teammate's tag.

Thresholds (`FOLLOW_MIN_SEC`, `FOLLOW_MIN_PLACES`, `FOLLOW_MIN_DIST`, `TRK_INTERVAL`) are at the top of `include/trackers.sh`. Following detection needs a GPS fix.

## 🚁 Drone Remote ID → TAK

**Menu > Sensors > Drone Remote ID**. It passively receives FAA / ASTM F3411 Remote ID broadcasts over **Wi-Fi** (beacon and NAN) and **Bluetooth**, and puts drones and their operators on the TAK map.

- **Receiver:** `map/rid_decode.py`, PagerTAK's own decoder (Python standard library only). It reads Wi-Fi beacon and NAN frames from `tcpdump` on `wlan1mon` and Bluetooth advertisements from `btmon`, and decodes the Basic ID, Location, Self-ID, System and Operator ID messages. It needs `python3-light`, which it offers to install.
- **Bridge:** `map/rid_bridge.py` turns the receiver's live state into TAK events on PagerTAK's existing connection.

| In TAK | CoT type | Notes |
|---|---|---|
| **Drone** | `a-u-A-M-H-Q` rotary / VTOL, `a-u-A-M-F-Q` fixed-wing, `a-u-A` other | Updated about every 3 s, 30 s stale. Remarks: UAS ID, type, status, geo/AGL altitude, speed, heading, operator ID, Self-ID, MAC |
| **Operator / home point** | `a-u-G-E-S-E` | From the System message, linked to its drone |
| **New drone alert** | GeoChat to All | Once per drone, plus a Pager alert, logged to `/root/loot/PagerTAK/drones.log` |

Drones also appear on the Pager map and in **Active drones** (pick one to center the map on it). The receiver saves a CSV of every track to `/root/loot/PagerTAK/drones.csv`.

- **Wi-Fi channel:** while the drone watch is on, the worker parks the Wi-Fi monitor interface on one channel (default **6**, where Wi-Fi Remote ID is broadcast) and **restores it when turned off**. Turn it off when you need full-band recon (e.g. for the evil-twin watch). Bluetooth Remote ID is unaffected.
- **Receiver status** shows Wi-Fi/Bluetooth capture health and frame counts.

## 🗺️ Site survey → ATAK data package

**Menu > Sensors > Site survey**, for pre-site assessments. Walk a site and hand the main body its Wi-Fi picture before they arrive. It reads the recon database and transmits nothing over the air. It needs Recon running, `sqlite3`, and `python3-light` to build the package.

1. **Start survey:** name it (defaults to your evil-twin site profile name) and walk the site with a GPS fix. Every 15 s the Pager records each access point recon heard (signal, security, channel) with your position, plus your track.
2. **Stop survey:** PagerTAK offers to **build and upload** right away.
3. **The data package** (`survey_<name>_<date>.zip`, ATAK `MissionPackageManifest` v2) contains:
   - a **KML overlay** with one folder per category:
     - **Your networks** (blue, from your evil-twin profile)
     - **Open** (red)
     - **Weak WEP/WPA** (orange)
     - **Secured WPA2/WPA3** (green)
     - **Hidden** (gray)
     - the **survey track**
   - a **CSV** of every AP (BSSID, SSID, security, channel, best signal, samples, position)
   - a **summary.txt** with counts and the open networks
4. **Upload:** `POST /Marti/sync/missionupload` (multipart `assetfile`, SHA-256 checked) with the Pager's client cert, then marked public so it shows in the server's **Data Packages**. If **Share with all TAK users** is on (default), a `b-f-t-r` file-share goes out, so every ATAK user gets a one-tap download, plus a GeoChat summary.

- **AP positions:** each AP is placed at the **signal-weighted center of its 3 strongest samples**, which is where you were when it was loudest. Walk the perimeter and through the building for best results.
- **TAK API port:** 8443 by default (client-cert HTTPS), or 8080 for an unauthenticated HTTP server. Set it in the menu.
- **Past surveys:** every survey is kept in `/root/loot/PagerTAK/surveys/`, and any of them can be rebuilt or re-uploaded from **Past surveys**. A failed upload leaves the package in loot.

## 🖥️ Web console

PagerTAK in a browser, for when you have a laptop or phone with you. It runs on the Pager while PagerTAK is running.

**Turn it on:** *Settings > Web console > Web console: OFF*. The first time, it asks to install `python3-light` if it is missing (the Leaflet map library comes with PagerTAK), then asks you for a password. It suggests a random one, which you can keep or change. Then browse to any address it shows: the Pager's host name, its IP on your network, or **http://172.16.52.1:8484** over the Pager's USB connection.

What you get:

- **Map**: your position and heading, TAK users in their team colors, markers by affiliation, drones, report markers. Same basemaps as the Pager map (`map/sources/*.xml`). Tiles come through the Pager, and every tile you view is cached for offline use on the Pager's own map. Right-click (long-press) the map to set your manual position or start a report there.
- **Chat**: All Chat Rooms and direct messages, with quick-message buttons and history from the chat log. Your direct messages show *✓ delivered* and *✓✓ read* when the other side sends receipts. Opening the Chat tab marks messages read on the Pager too. Edit the quick messages under *Settings > Quick messages*. Delete one message with its **×**, or everything with *Clear chat history* (also on the Pager under *Chat*). This only clears the Pager's copy; other TAK devices keep theirs.
- **Alerts**: the SEND ALERT button opens the alert dialog (see *Alerts* below); a red banner shows while yours is active.
- **Contacts**: TAK users only, nearest first with range and bearing, with a *Message* button.
- **Items**: everything else on the map, grouped as *My markers*, drones and operators, aircraft, ground units / vehicles / incidents, vessels, and markers and other. **Show on the map** switches hide whole groups (with counts); hidden groups are also hidden on the Pager's map. **Clear received items** wipes everything received from TAK off the Pager; your own markers and zones stay.
- **Reports**: full SALUTE, SITREP, MEDEVAC 9-line and Damage forms, with *Pick on map* for the location. They are the same CoT as the Pager menus (MEDEVAC still opens in ATAK's 9-line tool).
- **Sensors**: evil-twin watch, tracker watch, drone Remote ID (with channel), sensor stats, man-down watchdog, geofence list, site survey start/stop (with build and upload to TAK) and past survey downloads, plus the latest alerts. Site networks can be learned and approved here too (*Find networks*), and the Bluetooth tools installed.
- **SIGINT** (receive-only, runs only while the tab is open):
  - **Radio**: lock the monitor radio (`wlan1mon`) to one channel, or set recon hopping back to fast / slow. Refused while drone watch or a fox hunt owns the radio.
  - **Wi-Fi**: access points (SSID, MAC, channel, security, signal, open / hidden counts), clients (and the AP they are on) and probe requests (which networks each device is calling for), with search and a 5 / 15 / 60 minute window. Randomized MACs are tagged.
  - **Fox hunt**: pick a device (*Hunt*) or type a MAC. Live dBm, a strength bar and a graph, and a colored trail of readings at your GPS positions with the strongest one ringed. Optionally locks the radio to the target's channel for faster readings (uses the Pager's `_pineap MONITOR` and `PINEAPPLE_EXAMINE_*`, as Hak5's Device Hunter does).
- **Settings**: **TAK channels** at the top (*Load channels*, tick In / Out per server group, *Save channels*, like ATAK's channel picker), callsign, team, role, manual position, interval, TAK server, **certificate upload** (client and CA PEM, so no `scp` needed), map tile mode and coordinate format, browser alert sound / pop-ups, and the web password.

**Map tools** (all in the browser, nothing extra on the Pager):

- **Measure**: click points for distance and bearing per leg plus the total; double-click to finish. **Clear** removes measurements and rings.
- **Right-click (long-press) the map** for: set manual position, report here, **drop marker** (spot in a color, or hostile / suspect / unknown / neutral / friendly point), **range rings** (4 rings at the spacing you choose), **geofence circle**.
- **Who gets it**: markers and zones each have *Don't send (only on this map)*, *Send to everyone* or *Send only to* one TAK user (addressed with `<marti><dest callsign>`). Send a kept marker later, resend it, or delete it from the map popup or *Contacts > My markers*. Deleting something you sent also removes it in TAK for whoever got it.
- **MGRS** under the cursor and in popups (switch to lat, lon in Settings).
- **Geofences**: **Zone** draws a polygon (click corners, *Finish*), or right-click for a circle. Choose who triggers it: TAK users, drones, anything that moves, or you. The Pager checks every 10 s and alerts on enter / leave (Pager screen, ringtone, web alert, optional GeoChat). Zones can also be shown in TAK as drawings. Zones are listed under *Sensors* with *Show* and *Delete*, and are saved in `geofences.txt`.
- **Alerts in the browser**: a sound for incoming chat, alerts, sensors and geofences. Pop-up notifications need HTTPS.

**Alerts (the SEND ALERT button)**: pick the type (911 Alert, Ring The Bell, Geo-fence Breached, Troops In Contact, or Custom with your own name for it) and who gets it (everyone, or only the people you tick). After *Send* you get a 5-second countdown with a big **CANCEL**. While it is on, a red banner says what is active and who it went to; *Cancel alert* sends the cancel to the same people. The Pager menu offers the same types and recipients.

**Man-down watchdog** (*Sensors* tab, or Pager *Sensors > Man-down watchdog*), off until you turn it on:
- *Watch me*: no movement (25 m) and no Pager button press for the minutes you set gives a warning (ringtone, Pager screen, orange banner with **I'M OK** in the browser). 60 s later a 911 alert goes out automatically with "Man down" in the remarks. Any Pager button or *I'M OK* resets it.
- *Watch these TAK users*: tick people to watch. If one stops reporting or stops moving for the set time, you get an alert (and an optional GeoChat "CHECK ON ..."). It clears when they move again.

**Geofence alerts to TAK**: a zone can also send ATAK's *Geo-fence Breached* alert, to everyone or one person, when something enters it, so everyone's ATAK sounds, not just yours.

**Offline maps**: *Offline* on the map downloads the area on screen, from 2 zoom levels out to the zoom you pick, onto the Pager (it shows the tile count and size first; limit 25,000 tiles; checks free space). Progress shows on the map; you can stop it. The Pager map and the web console then work there without internet.

**Layers**: *Layers* on the map turns on **breadcrumb trails** (last hour: you, TAK users, drones; kept on the Pager, drawn in the browser) and manages **KML / KMZ overlays** (up to 4 MB each, stored on the Pager in `overlays/`, each switched on or off per browser). Points, lines and polygons with their KML colors; descriptions are shown as plain text. Overlays show in the web console only, not on the Pager screen. Not drawn: image overlays (`GroundOverlay`), network links and 3D models.

**Send a photo or file**: the paperclip in Chat sends a photo or file (up to 8 MB) to everyone or to the person picked in the chat *To* box. The Pager wraps it in a TAK data package, uploads it to the TAK Server (same API as the site survey) and sends the file-share message; ATAK offers to download it.

**Range filter**: *All ranges / 1-100 km* next to the basemap list hides TAK items farther than that from you, on the web map, in Contacts, and on the Pager's map. It is saved on the Pager.

**CoT details**: *Details* in any map popup shows the item's type in words (affiliation, dimension, what it is), UID, how it was placed, times and stale, MGRS and lat/lon, height, accuracy, course and speed, team and role, battery, device, endpoint and remarks, plus the raw CoT.

**QR code**: Pager *Settings > Web console > Show QR code* draws the web address as a QR code on the Pager screen, so a phone can open it without typing (installs `qrencode`, about 40 KB, the first time).

**Speed**

- Tiles: by default the Pager serves tiles it already has, and sends your browser straight to the internet for the rest while it saves a copy in the background. If your browser is offline, the tile is fetched through the Pager instead. *Settings > Map > Tiles* has the other two modes (through the Pager only, internet only).
- One connection is reused for many requests, cached tiles are kept by the browser for 30 days, and the page only downloads updates when something changed. It stops polling while the tab is in the background.

**Security**

- Password login. The password is stored salted and hashed in `web/auth`; sessions last 12 hours. After 5 wrong passwords the browser is locked out for 60 s, doubling each time.
- **Listen on** controls where the page can be reached. Change it on the Pager (*Settings > Web console > Listen on*) or in the console (*Settings > Web console access*):
  - **All interfaces** (default): every network the Pager is on, so the console opens by host name, IP or the USB address. Anyone on those networks can reach the login page, so use a strong password.
  - **USB + VPN**: the USB address plus the NetBird / WireGuard address (`wt0`, `wg0`), so you can reach the console from anywhere on your NetBird network.
  - **USB only**: just the Pager's USB/management address.
- **HTTPS** (optional): a self-signed certificate made on the Pager. Needs `openssl-util` and `python3-openssl`. Accept the browser warning once.
- The page cannot be used from other websites: every change needs a header that cross-site pages cannot send, and the cookie is `SameSite=Strict`.
- The web server never talks to TAK itself. It hands commands to PagerTAK through `/tmp/pagertak/webcmd/`, so everything still goes out over PagerTAK's one TAK connection.

Files: `web/pagertak_web.py` (server, Python standard library only), `web/static/` (page), `include/web.sh` (start/stop, command handling, Pager menu). Log: `/tmp/pagertak-web.log`.

## 📶 Sensor stats

With **Settings > Sensor stats** on (default) and `sqlite3` installed (`opkg install sqlite3-cli`), each position report includes counts from the Pager's recon database (`/root/recon/recon.db`) over the last `RECON_WINDOW` seconds:

- **In remarks**, readable by anyone who taps the Pager in TAK:
  `Sensor 5m: 143 APs (12 open), 37 clients`
- **As a hidden detail element** that TAK clients ignore but Node-RED and other tools can parse:
  `<__pagertak_recon window="300" aps="143" open="12" clients="37"/>`

Counts come from whatever the Pager's recon engine has recorded, so recon must be running.

## 🔧 Configuration

All options are set on the device (**A > Settings**) and kept across reboots. The `# Options` block at the top of `payload.sh` only holds the **defaults**:

| Option | Default | Notes |
|---|---|---|
| `TAK_HOST` | `tak.example.com` | placeholder, set in the wizard |
| `TAK_PROTO` | `tls` | `tls` / `tcp` / `udp` |
| `TAK_PORT` | `8089` | 8089 TLS, 8087 TCP/UDP |
| `CALLSIGN` | `PAGER-1` | |
| `TEAM` / `ROLE` | `Cyan` / `Team Member` | standard ATAK team colors and roles |
| `SA_INTERVAL` | `30` | seconds; stale time = interval + 30 s |
| `CLIENT_PEM` / `CA_PEM` | `client.pem` / `ca.pem` | file names in `certs/` |
| `CHAT_RINGTONE` | `bonus` | `none` for silent |
| `GPS_TIME_SYNC` | `1` | set the clock from GPS if the year is < 2025 |
| `QUICK_MESSAGES` | Copy, WILCO, Say again, … | defaults; edit them in the web console (*Settings > Quick messages*) |
| `CHAT_RECEIPTS` | `1` | send delivered / read receipts for direct messages; also in the web console |
| `RECON_STATS` / `RECON_WINDOW` | `1` / `300` | sensor counts in position reports |
| `MAP_SOURCE` | `USGS Topo` | basemap `<name>` from `map/sources/*.xml` |
| `MAP_TILE_URL` | `https://tiles.example.com/{z}/{x}/{y}.png` | optional *Custom* source (placeholder) |
| `MAP_ZOOM` | `15` | starting zoom |
| `TRACK_MAX_AGE` | `1800` | seconds before contacts/markers drop off the map and list |
| `RX_FEED_MIN_SEC` | `10` | feeds and markers: at most one update per item every N seconds (TAK users, chat and alerts always get through) |
| `COT_RADIUS_KM` | `0` | range filter for TAK items (0 = everything); also on the web map |
| `WEB_PORT` | `8484` | web console port; the console stays off until you turn it on |
| `MANDOWN_MINUTES` | `10` | man-down watchdog time; the watchdog stays off until you turn it on |

**Settings > Reset all settings** clears the saved configuration.

---

## 📁 Files

| Path | What it is |
|---|---|
| `payload.sh` | the payload: settings, TAK connection, chat, alerts, menus |
| `include/` | modules: `reports`, `watch` (evil twin), `trackers`, `remoteid`, `survey`, `sigint` (radio, fox hunt), `geofence`, `watchdog` (man-down), `web` (web console glue) |
| `map/` | Pager map viewer, QR screen, Remote ID receiver (`rid_decode.py`) and bridge, survey package builder, `sources/` basemaps |
| `web/` | web console server (`pagertak_web.py`, Python standard library) and `static/` page, with Leaflet in `static/leaflet/` |
| `certs/` | your TAK certificates (git-ignored) |

Created on the Pager as you use it (git-ignored, kept when you update the folder): `geofences.txt`, `items.txt` (your markers), `overlays/`, `tiles/`, `watch/` (site profiles), `web/auth` (web password hash), `web/tls/`. Logs and loot go to `/root/loot/PagerTAK/`; live state to `/tmp/pagertak/`.

To update PagerTAK, copy the new folder over the old one. Your settings live in the Pager's payload config, so they survive.

---

## 📝 Notes & Limitations

- The Pager's UID (`PagerTAK-xxxxxxxx`) is generated once and saved, so it keeps the same map icon across runs.
- **Direct messages** need the recipient to have reported a position since PagerTAK started. That is how the Pager learns their UID.
- In **UDP** mode the Pager can send position and chat but cannot receive.
- **Received items expire the way they do in ATAK**: each item is dropped when its own CoT stale time passes, when another client deletes it (`t-x-d-d`), or after `TRACK_MAX_AGE` without an update. TAK users are the exception: past their stale time they stay on the map greyed out, like in ATAK, until `TRACK_MAX_AGE`. Stale times are counted from each event's own time, so a clock difference between devices does not remove fresh contacts. The Pager prunes them from memory every minute. Feeds that keep re-sending an item (traffic, ADS-B) keep it on the map; hide the group in *Items*, or untick the feed's TAK channel so the server stops sending it.
- Group/mission chat rooms are shown on screen when received, but you can only send to All or to a single contact.
- **Busy servers**: the receiver splits the stream with awk and thins out data feeds (`RX_FEED_MIN_SEC`), so chat stays on time even when the server also sends aircraft, ships, lightning and other feeds. The best fix is on the server, though: give the Pager's TAK user only the groups it needs (in the web console, *Settings > TAK channels*, or the TAK Server's group settings), so feeds you don't need are never sent. That saves battery and data too.
- **Receipts** (`b-t-f-d` / `b-t-f-r`, matched on `messageId`) are sent with both `<__chatreceipt>` (ATAK) and `<__chat>` (CloudTAK). The first few receipts other apps send the Pager are kept in `/root/loot/PagerTAK/receipts_sample.log`, to compare formats if a client does not show the ticks. Read means you opened *Chat* on the Pager or the Chat tab in the web console; a message that only scrolled past on the Pager's main screen stays unread.
- Sensors share one monitor radio (`wlan1mon`): drone watch parks it on one channel, and a fox hunt or a radio lock holds it too. PagerTAK refuses conflicting changes and tells you which feature has the radio.
- The man-down watchdog cannot tell a dropped Pager from one sitting on a desk. Turn it off when you are not in the field.

---

## 🧪 Tested

Tested off the device against a mock TAK Server (TCP 8087 and mutual-TLS 8089), a mock Marti API and test doubles for the Pager commands, newest first. Real-hardware checks so far: TLS connection with server-converted certificates, ATAK connection package import, chat both ways with ATAK and CloudTAK with delivered / read receipts, deleting and clearing chat, photo sharing, KML overlays, Pager geofences, the Pager map (zoom, pan) with a manual position, and the web console over Wi-Fi.

- 2.3: connection check and TCP link without the `timeout` command or Bash's `/dev/tcp` (Python fallback), with the reason a port did not answer; enrollment against a server whose port 8446 has a public certificate (TAK CA first, then the public CA list, never unchecked); evil-twin learning and saving from the web console against a recon database; receipts matched with the console and payload in different time zones. Shared with [PineappleTAK](https://github.com/SECT0101/PineappleTAK-MK7) and checked on a real WiFi Pineapple Mark VII and TAK Server: enrollment, TLS connection, chat, evil-twin watch, tracker watch, drone Remote ID and start at boot.
- 2.2: delivered / read receipts both ways (receipt sent for a direct message, read receipt when Chat is opened, status of our own message moving to delivered then read and never back), unread count and reply, quick messages saved and cleared from the web console, a geofence for one contact, and the Navigate screen drawn into a file-backed framebuffer; receiver throughput with 6 MB of simulated busy-server traffic (20,000 aircraft updates plus chats): 6.5 s against about 5 minutes before, every chat and contact delivered; TAK users kept (greyed) past their stale time and dropped after `TRACK_MAX_AGE`; stale time measured from the event's own time with the Pager clock 10 minutes off; enrollment with a password containing quotes, a backslash, a space and `$`; everything below with Python modules that python3-light lacks blocked (`urllib`, `uuid`, `email`, `xml`, `ctypes` and others). Screen driver: PNG decoding checked pixel-exact against a reference decoder for RGB, RGBA, gray, gray+alpha, 1/4/8-bit palette and all five row filters; the map and the self-test drawn into a file-backed framebuffer and checked as screenshots. Browser setup end to end: setup mode, server settings, enrollment against a mock TAK Server (wrong password refused; CSR subject built from the server's `tls/config`; signed certificate and CA saved), ATAK connection package import, `.p12` upload (wrong password reported), connection test against a mutual-TLS server (no certificate, rejected certificate, success), Finish setup releasing the waiting payload; photo shared to a mock Marti API with the client certificate and the result written to the chat; setup page checked in headless Chrome. Own Remote ID receiver decoded Wi-Fi beacon (message pack), NAN service discovery and Bluetooth (btmon) Remote ID into the same state the bridge reads; file upload over TLS when the API certificate name does not match the address (falls back and still sends), with the reason shown in the page when an upload fails.
- 2.1: stale times read from CoT (pure-Bash ISO time conversion), already-stale events dropped, a TDOT-style incident expiring on its stale time, `t-x-d-d` delete removing an item, memory pruning, category counts and hide filters (web and Pager map), *Clear received items*, ADS-B aircraft no longer shown as drones, Contacts and Items tabs checked in headless Chrome.
- 2.0: every alert type to everyone and to chosen contacts (multiple `<marti><dest>`), repeat with position reports, and cancel to the same people; Pager alert menu with recipients; geofence entry sending a Geo-fence Breached alert; man-down warning and automatic 911 with remarks, and check-on alerts for a watched user; range filter on tracks; CoT details from single-quoted ATAK events; trails; offline area job against a local tile server (count check, 25,000 limit, progress); KMZ overlay upload and drawing (points, lines, polygons); a photo sent as a data package to one contact through a mock Marti API (hash checked, `b-f-t-r` addressed to that contact); unauthenticated uploads refused; QR screen rendered through the pagerctl test double and decoded back to the address; alert dialog, countdown, layers, details and offline dialogs driven in headless Chrome with no page errors.
- 1.9 web console: change-only updates and connection reuse checked; tile redirect, background caching and fetch-through-Pager checked against a local tile server; TAK channels loaded and saved against a mock Marti API (`/Marti/api/groups/all`, `PUT /Marti/api/groups/active?clientUid=`); radio lock / hop, fox hunt start / readings / trail / stop and channel restore, Wi-Fi AP / client / probe tables against a recon database and `_pineap` test doubles; markers and geofence drawings (`u-d-c-c`, `u-d-f`) reaching a mock TAK Server; geofence enter alerts and GeoChat from a simulated contact; JS MGRS matched the awk version; measure, zone drawing, marker and range-ring tools driven in headless Chrome with no page errors.
- 1.8 web console: login, wrong-password lockout, missing-header and path-traversal requests refused; chat All and DM, all four reports, 911 and cancel, settings, sensor toggles and survey start/stop sent from the browser API and checked at a mock TAK Server; PEM certificates uploaded from the browser, then switched to TLS 8089 and connected with mutual TLS; the Pager menu flow (install check, password, start, address); page checked in headless Chrome at laptop and phone sizes with no script errors.
- Core: SA, GeoChat All/DM both directions, XML escaping, chunked stream reassembly, 911 send and receive, auto-reconnect, no-fix and manual position.
- Site survey: simulated walk with changing signals; AP positions landed at each AP's signal peak; package uploaded to a mock Marti API (hash verified), marked public, and file-share `b-f-t-r` sent; manifest and KML parsed. Hidden-network parsing fixed in the shared recon query (also used by the evil-twin watch, re-tested).
- Drone Remote ID: PagerTAK's receiver decoded a Wi-Fi beacon capture (Basic ID + Location + System + Self-ID message pack); the bridge sent a moving rotary-wing UAS, its operator home point, and one new-drone GeoChat to TAK.
- Tracker watch: parser checked on `btmon`-format output built from BlueZ's own print formats (trackers, Flock, Axon detected; iPhone, Eddystone and phone decoys ignored); FOLLOWING fired once the simulated Pager had moved past 3 places 200 m+ apart.
- Evil-twin watch: learn → approve → watch against a recon database, with evil twin, downgrade and new-open alerts reaching TAK, and no repeats or false alerts on known networks.
- Reports: all four sent end to end through the menus; events checked as well-formed XML; MEDEVAC fields match ATAK-CIV's MedLine handler; MGRS checked against a reference library on 2,000+ points worldwide.
- Map rendered off-device into a file-backed framebuffer through `pagerfb` (tiles, markers, sidebar, zoom, pan/follow), plus tile caching against a local tile server.
- Pager DuckyScript commands used: `LOG`, `LED`, `GPS_GET`, `BATTERY_PERCENT`, `BATTERY_CHARGING`, `TEXT_PICKER`, `LIST_PICKER`, `NUMBER_PICKER`, `CONFIRMATION_DIALOG`, `PROMPT`, `ALERT`, `ERROR_DIALOG`, `RINGTONE`, `START_SPINNER`/`STOP_SPINNER`, `WAIT_FOR_INPUT`, `PAYLOAD_GET_CONFIG`/`PAYLOAD_SET_CONFIG`/`PAYLOAD_DEL_CONFIG`, `UI_TAKEOVER`/`UI_RELEASE`, `PINEAPPLE_EXAMINE_CHANNEL`/`_BSSID`/`_RESET`, plus the Pager's `_pineap` tool.

## 🙏 Credits

- [pagerctl](https://github.com/pineapple-pager-projects/pineapple_pager_pagerctl) (MIT): `map/pagerfb.py` follows its drawing API and uses its 5x7 bitmap font
- [goatak](https://github.com/kdudkov/goatak) and [PyTAK](https://github.com/snstac/pytak), for how TAK Server certificate enrollment works
- Hak5's IRC Chat payload (Hackazillarex), for the button-loop chat pattern
- [Leaflet](https://leafletjs.com) 1.9.4 (BSD-2-Clause, Volodymyr Agafonkin), the web console map, included in `web/static/leaflet` with its license
- ATAK-CIV (open source), for the MEDEVAC `<_medevac_>` field definitions
- The ASTM F3411 / ASD-STAN Remote ID message formats and the [opendroneid core-c](https://github.com/opendroneid/opendroneid-core-c) reference, which `rid_decode.py` was written from; Remote ID Radar (JustCallMeKoko, Hak5 payload library) for showing it works on the Pager's radios
- Hak5's Device Hunter and C5 Wardriver payloads, for how to use `_pineap` and `PINEAPPLE_EXAMINE_*`
- [Flock-You](https://github.com/colonelpanichacks/flock-you) (MIT), for the Flock / Penguin signatures; BluePine (cncartist) for the Axon OUI list and the btmon scanning approach

---

## ⚠️ Disclaimer

Use only on networks and TAK Servers you are authorized to use. Sensors and SIGINT views are receive-only; follow your organization's rules and the law for monitoring radio traffic. Alerts go to everyone unless you pick recipients, and the man-down watchdog can send 911 by itself; test both with your team first.
