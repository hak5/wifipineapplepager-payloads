# Chasing Your Tail NG - Pineapple Pager Payload 🔍

**Pineapple Pager Payload** | Category: Reconnaissance  
Based on: [ArgeliusLabs/Chasing-Your-Tail-NG](https://github.com/ArgeliusLabs/Chasing-Your-Tail-NG) (MIT)

> 🇩🇪 [Deutsche Version weiter unten](#deutsch)

---

## English

Detects whether you are being followed – by analysing recurring WiFi Probe Requests, optional Bluetooth scanning, GPS tracking, OUI vendor lookup and WiGLE geolocation.

> **v4.6:** Quick Start dialog (1=Standard / 2=Manual), zone detection via GPS · IP geolocation · manual picker, standard mode WiFi+BT (no GPS required), auto-cleanup of old reports/PCAPs, Watch-List display improvements.
> **v4.5:** Native Pineapple Pager Framework – no manual tcpdump, no custom channel hopping, no framebuffer hacking. Full Bluetooth + GPS + WiGLE integration. BT fingerprinting, Hotel-Scan mode, Watch-List management from display.

---

### How it works

1. **Dependency check** – python3 installed automatically via `opkg` if missing
2. **Quick Start** – `1=Standard` (WiFi+BT, 2 rounds, configured duration) or `2=Manual` for full configuration
3. **Zone detection** – GPS fix → Haversine match, fallback IP geolocation (ip-api.com), fallback manual picker
4. **Configuration** – rounds and duration selectable via NUMBER_PICKER (Manual mode only)
4. **Channel hopping** – `PINEAPPLE_HOPPING_START` activates built-in hopping
5. **PCAP capture** – `WIFI_PCAP_START` captures Probe Requests natively
6. **BT scan** – parallel Bluetooth Classic + BLE scan (optional)
7. **GPS tracking** – coordinates saved per round (optional)
8. **Analysis** – persistence scoring, OUI vendor lookup, spoofed MAC detection
9. **WiGLE lookup** – MAC, BT address and probe SSIDs looked up in WiGLE
10. **Report** – result on display + Markdown report in `/root/loot/`

---

### Scan Modes

| Mode | Description |
|------|-------------|
| 0 | WiFi only |
| 1 | WiFi + GPS |
| 2 | WiFi + Bluetooth |
| 3 | All modules (WiFi + GPS + BT) |
| 4 | Hotel Scan – BLE camera & beacon detection, RSSI distance estimate |

---

### Installation

```bash
cd /root/payloads/user/reconnaissance/
git clone https://github.com/tschakram/chasing-your-tail-pager.git chasing_your_tail
cd chasing_your_tail
cp config.example.json config.json
```

> ⚠️ The payload **must** be launched from the **Pager Dashboard**:  
> `Payloads → User → Reconnaissance → Chasing Your Tail NG`  
> Do not run via `bash payload.sh` in SSH – Pager APIs only work in Dashboard context.

---

### How to Use

#### Step 1 – Set up Ignore Lists

Add your own devices **before the first scan** to prevent false positives.
Files live in `/root/loot/chasing_your_tail/ignore_lists/` on the Pager (never committed to git).

**`mac_list.json`** – your own WiFi + Bluetooth devices:
```json
{
  "ignore_macs": ["AA:BB:CC:DD:EE:FF", "11:22:33:44:55:66"],
  "comments": {
    "AA:BB:CC:DD:EE:FF": "My Garmin GPS",
    "11:22:33:44:55:66": "My JBL Speaker"
  }
}
```

**`ssid_list.json`** – your home/office networks (suppresses probe-SSID false positives):
```json
{
  "ignore_ssids": ["MyHomeWiFi", "MyOfficeWiFi"],
  "comments": {
    "MyHomeWiFi": "Home network – ignore"
  }
}
```

> **Tip:** Run a scan in Mode 0 from home first. Any device appearing as suspicious is likely your own. Add its MAC to `mac_list.json`, then scan again.

---

#### Step 2 – Configure Known Zones (optional, for Watch-List)

GPS coordinates are **only stored in `config.json` on the Pager** – never in the repository.
Add a `watch_list` section with your real positions:

```json
"watch_list": {
  "default_zone_radius_m": 100,
  "known_zones": [
    { "name": "Home",   "lat": 0.000000, "lon": 0.000000, "radius_m": 150 },
    { "name": "Office", "lat": 0.000000, "lon": 0.000000, "radius_m": 100 }
  ]
}
```

The `config.example.json` in the repository contains only placeholder coordinates (`0.000000`).

---

#### Step 3 – Add Suspicious Devices to the Watch List

After each scan, the Pager display lets you add suspicious devices directly to the **Watch List**:

| Type | Use case | Triggers alert when… |
|------|----------|----------------------|
| **Dynamic** | Unknown device, seen repeatedly | Device appears at a new location (> 500 m away from last sighting) |
| **Static** | Known device (e.g. a neighbour's router) | Device appears outside its configured GPS zone |

- **Dynamic** is the right choice for suspected tracking – the device following you across locations is the red flag.
- **Static** is useful for devices you know belong to a fixed place (home, hotel, office).
  When you add a static entry with GPS, choose a named zone or the current GPS fix.

---

#### Step 4 – Choose Scan Settings

The **Persistence Score** (`appearances ÷ total rounds`) is the core metric.
A score ≥ 0.6 flags a device as suspicious.

| Use case | Rounds | Duration / round | Total time | Notes |
|----------|--------|-----------------|------------|-------|
| Quick spot-check | 2 | 120 s | ~ 4 min | Low confidence, catches obvious followers |
| Standard | 3 | 300 s | ~ 15 min | Good balance for most scenarios |
| **Recommended (mobile)** | **5** | **120 s** | **~ 10 min** | Best geographic diversity while moving |
| High confidence | 5 | 300 s | ~ 25 min | Suitable when making planned stops |

**Key principle:** Geographic diversity matters more than raw scan time.
A device seen at five different locations is far more suspicious than one seen for a long time at a single spot.

---

#### Example: 45-Minute Drive

**Recommended settings:** Mode 3 (WiFi + GPS + BT) · 5 rounds · 120 s/round

```
Start  →  [Round 1: 2 min]  →  drive 3–5 km
       →  [Round 2: 2 min]  →  drive 3–5 km
       →  [Round 3: 2 min]  →  drive 3–5 km
       →  [Round 4: 2 min]  →  drive 3–5 km
       →  [Round 5: 2 min]  →  Analysis + Report

Scanning: ~12 min  |  Driving between rounds: ~33 min
```

**How to read the results:**

| Persistence | Appearances | Verdict |
|-------------|-------------|---------|
| 1.00 | 5 / 5 | 🔴 Strong indicator – device is following you |
| 0.80 | 4 / 5 | 🔴 Very suspicious |
| 0.60 | 3 / 5 | 🟡 At threshold – investigate further |
| 0.40 | 2 / 5 | 🟢 Likely coincidence |
| 0.20 | 1 / 5 | 🟢 Not suspicious |

**Why short rounds work better when moving:**

- Short rounds (60–120 s) → captures happen at different locations → real geographic diversity
- Long rounds (300 s+) → stationary capture → nearby café or neighbour devices inflate the score
- With GPS enabled: the report shows coordinates per round, so you can see whether a device appeared consistently across your entire route

**Practical tips:**

- Use **Mode 1** (WiFi + GPS) when battery matters; switch to Mode 3 for full BT coverage
- Start a round, drive until it ends, let the next round begin – you don't need to stop
- If a device scores 0.6 on the first run, repeat the route: a real follower will score 1.0 consistently
- With WiGLE enabled: probe SSIDs in the report may reveal the follower's home network location

---

### File Structure

```
chasing_your_tail/
├── payload.sh              ← Main script
├── config.json             ← Local config (not in repo – Pager only!)
├── config.example.json     ← Config template with placeholder GPS
├── watch_list.example.json ← Watch-List template (placeholder MACs)
├── ignore_lists/
│   ├── mac_list.json       ← Placeholder (real list: loot dir, Pager only)
│   └── ssid_list.json      ← Placeholder (real list: loot dir, Pager only)
└── python/
    ├── pcap_engine.py      ← PCAP parser + persistence analysis
    ├── analyze_pcap.py     ← Main analysis + report generator
    ├── bt_scanner.py       ← Bluetooth Classic + BLE + SDP scanner
    ├── bt_fingerprint.py   ← BLE UUID/Appearance DB, risk scoring
    ├── hotel_scan.py       ← Mode 4: beacon + BLE camera detection
    ├── oui_lookup.py       ← Offline OUI vendor lookup (auto-update)
    ├── wigle_lookup.py     ← WiGLE API + GPS nearby-search
    ├── watch_list.py       ← Static/dynamic device watch-list
    ├── watchlist_add.py    ← CLI wrapper for Watch-List from display
    ├── zone_check.py       ← Zone detection (GPS Haversine / IP geolocation / manual)
    └── cleanup.py          ← Auto-cleanup of old reports/PCAPs/logs
```

**Loot** is saved to:

```
/root/loot/chasing_your_tail/
├── pcap/                    ← PCAP files
├── surveillance_reports/    ← Markdown reports
├── gps_track.csv            ← GPS coordinates per round
├── bt_scan_*.json           ← Bluetooth scan results
├── oui_cache.json           ← OUI vendor cache
├── wigle_cache.json         ← WiGLE result cache
└── ignore_lists/            ← MAC/SSID ignore lists
```

---

### Report Contents

Each report includes per suspicious device:

- MAC address + **vendor** (OUI lookup)
- **MAC type** – global (real) or local/spoofed
- Persistence score + appearances
- **WiGLE results:**
  - WiFi MAC location (if found)
  - Bluetooth MAC location (if found)
  - Probe SSID locations (home network geolocation)

---

### Persistence Score

| Score | Meaning |
|-------|---------|
| 1.00 | Device seen in all scan rounds 🔴 |
| 0.50 | Device seen in half the rounds 🟡 |
| < 0.6 | Not suspicious 🟢 |

Default threshold: **0.6** (configurable in `config.json`)

---

### LED States

| LED | Meaning |
|-----|---------|
| 🔵 Cyan blink | Initialisation |
| 🔵 Blue blink | Scanning |
| 🟡 Amber | Analysis |
| 🟢 Green | ✅ Nothing suspicious |
| 🔴 Red blink | ⚠️ Suspicious devices detected |

---

### OUI Vendor Lookup

- Offline IEEE OUI database (~39,000 entries)
- Auto-update weekly when internet is available
- Works for both WiFi and Bluetooth MAC addresses

---

### WiGLE Integration (optional)

1. Create account at [wigle.net](https://wigle.net)
2. Go to **Account → API Token**
3. Add to `config.json`:

```json
{
  "wigle": {
    "enabled": true,
    "api_name": "YOUR_API_NAME",
    "api_token": "YOUR_API_TOKEN"
  }
}
```

---

### Ignore Lists

Add your own devices to avoid false positives. See **[How to Use → Step 1](#step-1--set-up-ignore-lists)** for details.

The actual list files live in `/root/loot/chasing_your_tail/ignore_lists/` on the Pager (gitignored).
The `ignore_lists/` folder in the repository contains placeholder examples only.

---

### GPS Setup

- USB u-blox GNSS receiver or any gpsd-compatible device
- Cold start fix: ~2-5 minutes outdoors

```bash
GPS_CONFIGURE /dev/ttyACM0 9600
```

---

### Pager Framework APIs used

| API | Purpose |
|-----|---------|
| `LOG` | Display output |
| `GPS_GET` / `GPS_CONFIGURE` | GPS coordinates |
| `PINEAPPLE_HOPPING_START/STOP` | Channel hopping |
| `WIFI_PCAP_START/STOP` | Probe capture |
| `NUMBER_PICKER` | Interactive number input |
| `CONFIRMATION_DIALOG` | Yes/No prompt |
| `START_SPINNER / STOP_SPINNER` | Loading animation |
| `LED` | LED control |
| `VIBRATE` | Alert vibration |

---

### Legal

Analyses only **publicly broadcast radio signals** (Probe Requests on open ISM band 2.4/5 GHz). No connections established, no data intercepted, no active device contact. Use responsibly within applicable laws.

---

### Credits

- Original: [azmatt/chasing_your_tail](https://github.com/azmatt/chasing_your_tail)
- NG version: [ArgeliusLabs/Chasing-Your-Tail-NG](https://github.com/ArgeliusLabs/Chasing-Your-Tail-NG) – MIT
- Pineapple Pager port: [tschakram](https://github.com/tschakram)

---

---

<a name="deutsch"></a>
## 🇩🇪 Deutsch

Erkennt ob du verfolgt wirst – durch Analyse wiederkehrender WiFi-Probe-Requests, optionalen Bluetooth-Scan, GPS-Tracking, OUI-Herstellersuche und WiGLE-Geolokalisierung.

> **v4.6:** Quick-Start-Dialog (1=Standard / 2=Manuell), Zonenerkennung via GPS · IP-Geolokalisierung · manueller Picker, Standard-Modus WiFi+BT (kein GPS erforderlich), automatische Bereinigung alter Reports/PCAPs, Watch-List-Anzeige verbessert.
> **v4.5:** Natives Pineapple Pager Framework – kein manueller tcpdump, kein eigenes Channel-Hopping, kein Framebuffer-Hacking. Vollständige Bluetooth + GPS + WiGLE Integration. BT-Fingerprinting, Hotel-Scan-Modus, Watch-List-Verwaltung direkt vom Display.

---

### Wie es funktioniert

1. **Dependency-Check** – python3 wird automatisch via `opkg` installiert
2. **Quick-Start** – `1=Standard` (WiFi+BT, 2 Runden, konfigurierte Dauer) oder `2=Manuell` für volle Konfiguration
3. **Zonenerkennung** – GPS-Fix → Haversine-Abgleich, Fallback IP-Geolokalisierung (ip-api.com), Fallback manueller Picker
4. **Konfiguration** – Runden und Dauer per NUMBER_PICKER wählbar (nur Modus Manuell)
4. **Channel-Hopping** – `PINEAPPLE_HOPPING_START` aktiviert eingebautes Hopping
5. **PCAP-Capture** – `WIFI_PCAP_START` erfasst Probe-Requests nativ
6. **BT-Scan** – paralleler Bluetooth Classic + BLE Scan (optional)
7. **GPS-Tracking** – Koordinaten pro Runde gespeichert (optional)
8. **Analyse** – Persistence-Scoring, OUI-Herstellersuche, Spoofing-Erkennung
9. **WiGLE-Lookup** – MAC, BT-Adresse und Probe-SSIDs in WiGLE nachschlagen
10. **Report** – Ergebnis auf Display + Markdown-Report in `/root/loot/`

---

### Scan-Modi

| Modus | Beschreibung |
|-------|--------------|
| 0 | Nur WiFi |
| 1 | WiFi + GPS |
| 2 | WiFi + Bluetooth |
| 3 | Alle Module (WiFi + GPS + BT) |
| 4 | Hotel-Scan – BLE-Kameraerkennung, Beacon-Analyse, RSSI-Distanzschätzung |

---

### Installation

```bash
cd /root/payloads/user/reconnaissance/
git clone https://github.com/tschakram/chasing-your-tail-pager.git chasing_your_tail
cd chasing_your_tail
cp config.example.json config.json
```

> ⚠️ Der Payload **muss** über das **Pager-Dashboard** gestartet werden:  
> `Payloads → User → Reconnaissance → Chasing Your Tail NG`  
> Nicht über `bash payload.sh` in SSH – Pager-APIs funktionieren nur im Dashboard-Kontext.

---

### Verwendung

#### Schritt 1 – Ignore-Listen einrichten

Eigene Geräte **vor dem ersten Scan** eintragen, um Fehlalarme zu vermeiden.
Die Dateien liegen in `/root/loot/chasing_your_tail/ignore_lists/` auf dem Pager (nicht im Git).

**`mac_list.json`** – eigene WiFi- und Bluetooth-Geräte:
```json
{
  "ignore_macs": ["AA:BB:CC:DD:EE:FF", "11:22:33:44:55:66"],
  "comments": {
    "AA:BB:CC:DD:EE:FF": "Eigenes Garmin GPS",
    "11:22:33:44:55:66": "Eigener JBL Lautsprecher"
  }
}
```

**`ssid_list.json`** – eigene Heimnetzwerke (unterdrückt Probe-SSID-Fehlalarme):
```json
{
  "ignore_ssids": ["MeinHeimnetz", "Buero-WLAN"],
  "comments": {
    "MeinHeimnetz": "Heimnetz – ignorieren"
  }
}
```

> **Tipp:** Führe zuerst einen Scan im Modus 0 zuhause durch. Alle verdächtigen Geräte gehören wahrscheinlich dir selbst. MAC in `mac_list.json` eintragen, dann erneut scannen.

---

#### Schritt 2 – Bekannte Zonen konfigurieren (optional, für Watch-List)

GPS-Koordinaten werden **ausschließlich in `config.json` auf dem Pager** gespeichert – nie im Repository.
`watch_list`-Sektion in `config.json` eintragen:

```json
"watch_list": {
  "default_zone_radius_m": 100,
  "known_zones": [
    { "name": "Zuhause", "lat": 0.000000, "lon": 0.000000, "radius_m": 150 },
    { "name": "Büro",    "lat": 0.000000, "lon": 0.000000, "radius_m": 100 }
  ]
}
```

Die `config.example.json` im Repository enthält nur Platzhalter-Koordinaten (`0.000000`).

---

#### Schritt 3 – Verdächtige Geräte zur Watch-List hinzufügen

Nach jedem Scan können verdächtige Geräte direkt am Pager-Display zur **Watch-List** hinzugefügt werden:

| Typ | Anwendungsfall | Alarm wenn… |
|-----|---------------|-------------|
| **Dynamic** | Unbekanntes Gerät, mehrfach gesehen | Gerät taucht an einem neuen Ort auf (> 500 m entfernt) |
| **Static** | Bekanntes Gerät (z.B. Nachbar-Router) | Gerät taucht außerhalb seiner GPS-Zone auf |

- **Dynamic** ist die richtige Wahl bei Tracking-Verdacht – das Gerät folgt dir über verschiedene Orte.
- **Static** eignet sich für Geräte, die nur an einem festen Ort sein sollten (Zuhause, Hotel, Büro).

---

#### Schritt 4 – Scan-Einstellungen wählen

Der **Persistence-Score** (`Erscheinungen ÷ Runden gesamt`) ist die zentrale Kennzahl.
Ein Score ≥ 0,6 markiert ein Gerät als verdächtig.

| Anwendungsfall | Runden | Dauer/Runde | Gesamtzeit | Hinweis |
|----------------|--------|-------------|------------|---------|
| Schnellcheck | 2 | 120 s | ~ 4 Min. | Geringe Aussagekraft, offensichtliche Verfolger |
| Standard | 3 | 300 s | ~ 15 Min. | Gute Balance für die meisten Situationen |
| **Empfohlen (mobil)** | **5** | **120 s** | **~ 10 Min.** | Beste geografische Diversität beim Fahren |
| Hohe Sicherheit | 5 | 300 s | ~ 25 Min. | Geeignet für geplante Stopps |

**Grundprinzip:** Geografische Diversität schlägt reine Scan-Dauer.
Ein Gerät, das an fünf verschiedenen Orten auftaucht, ist wesentlich verdächtiger als eines, das lange an einem einzigen Ort zu sehen ist.

---

#### Beispiel: 45-Minuten-Fahrt

**Empfohlene Einstellung:** Modus 3 (WiFi + GPS + BT) · 5 Runden · 120 s/Runde

```
Start  →  [Runde 1: 2 Min.]  →  3–5 km fahren
       →  [Runde 2: 2 Min.]  →  3–5 km fahren
       →  [Runde 3: 2 Min.]  →  3–5 km fahren
       →  [Runde 4: 2 Min.]  →  3–5 km fahren
       →  [Runde 5: 2 Min.]  →  Analyse + Report

Scan-Zeit: ~12 Min.  |  Fahrzeit zwischen den Runden: ~33 Min.
```

**So liest du den Report:**

| Persistence | Erscheinungen | Bewertung |
|-------------|---------------|-----------|
| 1,00 | 5 / 5 | 🔴 Starker Hinweis – Gerät folgt dir |
| 0,80 | 4 / 5 | 🔴 Sehr verdächtig |
| 0,60 | 3 / 5 | 🟡 An der Schwelle – weiter beobachten |
| 0,40 | 2 / 5 | 🟢 Wahrscheinlich Zufall |
| 0,20 | 1 / 5 | 🟢 Nicht verdächtig |

**Warum kurze Runden beim Fahren besser funktionieren:**

- Kurze Runden (60–120 s) → Captures an verschiedenen Orten → echte geografische Diversität
- Lange Runden (300 s+) → stationäre Aufnahmen → Café-Nachbarn oder Anwohnergeräte erhöhen den Score künstlich
- Mit GPS: Der Report zeigt Koordinaten pro Runde – du siehst genau, ob ein Gerät über deine gesamte Route präsent war

**Praktische Tipps:**

- **Modus 1** (WiFi + GPS) bei Akkusorgen; **Modus 3** für vollständige BT-Abdeckung
- Runde starten, losfahren, die nächste Runde beginnt automatisch – kein Anhalten nötig
- Gerät mit Score 0,6 beim ersten Lauf: Route wiederholen. Ein echter Verfolger erreicht dann 1,0
- Mit WiGLE: Probe-SSIDs im Report können das Heimnetzwerk des Verfolgers verraten

---

### Report-Inhalt

Pro verdächtigem Gerät enthält der Report:

- MAC-Adresse + **Hersteller** (OUI-Lookup)
- **MAC-Typ** – global (echt) oder lokal/gespooft
- Persistence-Score + Erscheinungen
- **WiGLE-Ergebnisse:**
  - WiFi-MAC Standort (falls gefunden)
  - Bluetooth-MAC Standort (falls gefunden)
  - Probe-SSID Standorte (Heimnetz-Geolokalisierung)

---

### Getestet auf

- WiFi Pineapple Pager (OpenWrt 24.10.1, mipsel_24kc)
- Python 3.11.14
- u-blox GNSS Receiver (USB, gpsd 3.25)
- Bluetooth: hci0 (USB, BlueZ 5.72)
