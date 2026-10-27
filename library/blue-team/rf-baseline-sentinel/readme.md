**Title:** RF-Baseline Sentinel

**Description:** Passive RF behavioral baseline & anomaly correlation engine for the WiFi Pineapple Pager. Learns what "normal" looks like in an RF environment over time, then alerts on statistically significant deviations. Detects surveillance, rogue infrastructure, and RF anomalies without transmitting or interacting with observed devices.

**Author:** D-L3aN

**Version:** 1.0

**Category:** Blue-Team

**Net Mode:** NAT

# RF-Baseline Sentinel

> **A passive, longitudinal RF behavioral baseline and anomaly correlation engine for the WiFi Pineapple Pager.**

RF-Baseline Sentinel learns what "normal" looks like in your RF environment over time — then alerts you when reality deviates. It's a **defensive blue-team tool** designed to help security researchers, red teamers operating in hostile environments, and privacy-conscious operators detect surveillance, rogue infrastructure, and RF anomalies that static signature-based tools miss.

---

## Table of Contents

- [Concept](#concept)
- [Why This Exists](#why-this-exists)
- [How It Works](#how-it-works)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Understanding the Output](#understanding-the-output)
- [Anomaly Examples](#anomaly-examples)
- [Ethical Use & Legal](#ethical-use--legal)
- [Limitations](#limitations)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)
- [Acknowledgments](#acknowledgments)

---

## Concept

Traditional RF monitoring tools work on **static signatures** — "alert me when I see a deauth flood," "alert me when I see SSID `FreeWiFi`." These work well for known threats but miss everything else.

RF-Baseline Sentinel takes a different approach: **statistical behavioral profiling**.

Over days or weeks, it silently observes your RF environment and builds a baseline model:

- How many access points typically exist at 3 PM on a Tuesday?
- What's the normal client-to-AP ratio in your office?
- Which BSSIDs are "always there" vs. transient?
- What's the typical signal strength distribution?

Once the baseline is established, it flags statistically significant deviations — not because they match a known attack, but because **they don't match reality**.

---

## Why This Exists

This payload fills a gap that no other WiFi Pineapple Pager payload addresses:

| Existing Tools | RF-Baseline Sentinel |
|---|---|
| Static signatures ("alert on any deauth") | Behavioral baselines ("alert when deauth is anomalous for *this* time and place") |
| One-shot scanning | Longitudinal learning over days/weeks |
| Manual threshold tuning | Automatic statistical thresholds (z-score based) |
| Human interprets raw data | Automated correlation and contextual alerts |
| Reactive to known attacks | Detects novel/unknown anomalies |

**Real-world scenarios where this matters:**

- **Detecting targeted surveillance** — an unexpected AP appearing near your location at the same time every day
- **Rogue AP / evil twin detection** — a new BSSID appearing that mimics your baseline AP's characteristics
- **RF interference tracking** — gradual or sudden shifts in the RF landscape
- **Travel security** — carry the Pager, build a baseline of your home environment, then get alerted when something changes
- **Red team OPSEC** — detect when *you* are being monitored during an engagement

---

## How It Works

The payload runs in two phases: a learning phase that builds a statistical model of your environment, and a monitoring phase that compares new observations against that model.

### Phase 1: Learning Mode

During the initial training period (default: 100 samples, one per minute), the payload:

1. Reads the Pager's passive recon database at `/root/recon/recon.db`
2. Records AP count, client count, and hour-of-day for each sample
3. Populates a `bssid_registry` table tracking every BSSID seen
4. **Does not alert** — it's building the model

### Phase 2: Monitoring Mode

Once the baseline is established:

1. Takes a new sample every 2 minutes
2. Computes the z-score for the current AP count vs. historical average for **that hour of day**
3. If |z-score| > `Z_THRESHOLD` (default: 3.0), triggers an alert
4. Logs all alerts to `anomalies.log` with full context

### Why Hour-of-Day Matters

RF environments are highly time-dependent. A university campus at 3 AM looks nothing like it does at 3 PM. By baselining per-hour, the payload avoids false positives from normal temporal variation.

---

## Features

- ✅ **Fully passive** — reads existing recon data, does not transmit, does not scan actively
- ✅ **Longitudinal learning** — builds a statistical model over days/weeks
- ✅ **Hour-aware baselines** — accounts for time-of-day variation
- ✅ **Z-score anomaly detection** — statistically rigorous, no manual threshold tuning required
- ✅ **Persistent storage** — SQLite database survives reboots
- ✅ **BSSID registry** — tracks first-seen and last-seen for every device
- ✅ **Multi-modal alerts** — LED, vibration, and log file
- ✅ **Zero external dependencies** — uses only tools present on stock Pager firmware
- ✅ **Recoverable** — can pause, resume, or reset the baseline at any time
- ✅ **Exportable** — baseline DB can be pulled off-device for external analysis

---

## Requirements

| Requirement | Notes |
|---|---|
| WiFi Pineapple Pager | Current firmware |
| Recon service running | Default on stock firmware; can be enabled via Pager UI |
| `sqlite3` | Present on stock firmware |
| `bc` | For floating-point math; install via `opkg install bc` if missing |
| DuckyScript + Bash | Standard Pager payload environment |

**Storage:** The baseline grows by roughly 1 KB per day under normal conditions. A 30-day baseline uses less than 1 MB.

---

## Installation

### Option 1: Via Payload Library (Recommended)

1. On your Pager, navigate to **Payloads → Blue Team → RF-Baseline Sentinel**
2. Ensure recon is running: `Pager UI → Recon → Start`
3. Run the payload

### Option 2: Manual Install

Copy the payload to the library:

```bash
scp library/blue-team/rf-baseline-sentinel/payload.sh root@pager:/root/payloads/library/blue-team/rf-baseline-sentinel/
```

SSH into the Pager:

```bash
ssh root@pager
```

Make it executable:

```bash
chmod +x /root/payloads/library/blue-team/rf-baseline-sentinel/payload.sh
```

Run it:

```bash
/root/payloads/library/blue-team/rf-baseline-sentinel/payload.sh
```

### Option 3: Running on Boot

To have RF-Baseline Sentinel start automatically on boot, add this to `/etc/rc.local`:

```bash
nohup /root/payloads/library/blue-team/rf-baseline-sentinel/payload.sh > /dev/null 2>&1 &
```

---

## Configuration

Edit the top of `payload.sh` to customize the following options:

| Variable | Default | Description |
|---|---|---|
| `BASELINE_DIR` | `/root/loot/rf-baseline` | Where the SQLite DB and logs are stored |
| `LEARNING_MODE` | `true` | Set to `false` after baseline is established |
| `Z_THRESHOLD` | `3.0` | Anomaly sensitivity in standard deviations |
| `MIN_SAMPLES` | `100` | Minimum samples before baseline is valid |
| `LEARN_INTERVAL` | `60` | Seconds between samples during learning |
| `MONITOR_INTERVAL` | `120` | Seconds between samples during monitoring |

### Recommended Configuration by Use Case

| Use Case | `Z_THRESHOLD` | `MIN_SAMPLES` | Learning Period |
|---|---|---|---|
| Home / office (stable) | 3.0 | 100 | About 1 week |
| Travel / mobile | 4.0 | 500 | About 2 weeks |
| Red team OPSEC | 2.5 | 200 | About 3 days |
| Long-term monitoring | 3.5 | 1000 | About 30 days |

---

## Usage

### Basic Run

Execute the payload:

```bash
/root/payloads/library/blue-team/rf-baseline-sentinel/payload.sh
```

The payload will:

1. Create the baseline directory and database if they don't exist
2. Enter learning mode (if `LEARNING_MODE="true"`)
3. Transition to monitoring mode after `MIN_SAMPLES` are collected
4. Continue monitoring indefinitely

### Check Status

How many samples have been collected:

```bash
sqlite3 /root/loot/rf-baseline/baseline.db "SELECT COUNT(*) FROM scans;"
```

View recent anomalies:

```bash
tail -20 /root/loot/rf-baseline/anomalies.log
```

Export the baseline for analysis:

```bash
sqlite3 /root/loot/rf-baseline/baseline.db ".dump" > baseline-export.sql
```

### Reset Baseline

To wipe and start fresh:

```bash
rm /root/loot/rf-baseline/baseline.db
```

### Export for External Analysis

Pull the baseline DB and analyze it in your tool of choice:

```bash
scp root@pager:/root/loot/rf-baseline/baseline.db ./
sqlite3 baseline.db "SELECT * FROM scans;" | column -t -s'|'
```

---

## Understanding the Output

### Successful Startup

```
LOG: RF-Baseline Sentinel starting...
LOG: RF-Baseline Sentinel: Learning mode active
LOG: Collecting baseline samples... (12/100)
LOG: Collecting baseline samples... (45/100)
LOG: Collecting baseline samples... (100/100)
LOG: Baseline established with 100 samples.
LOG: Entering continuous monitoring mode...
```

### Anomaly Alert

```
LOG: RF Anomaly: AP count increase (current: 47, baseline: 22, z-score: 4.12)
```

When an anomaly is detected, you get three simultaneous signals:

- **Red LED blink** on the Pager
- **200ms vibration** pulse
- **Log entry** in `anomalies.log`

### Log File Format

Each line in `anomalies.log` follows this format:

```
TIMESTAMP | EVENT_TYPE | MESSAGE
```

| Event Type | Meaning |
|---|---|
| `RF Anomaly` | Statistical deviation detected |
| `New BSSID` | Previously unseen BSSID appeared (future feature) |
| `Baseline` | Baseline milestone reached |

---

## Anomaly Examples

### Example 1: Sudden AP Spike

Normally 20 APs are in range at your location. At 3:45 PM, 47 appear.

```
2026-10-14 15:45:12 | RF Anomaly: AP count increase (current: 47, baseline: 22, z-score: 4.12)
```

**Possible causes:**

- Rogue AP deployment
- Nearby event bringing many devices
- Attacks involving many virtual APs
- Legitimate environmental change (new router, neighbor's new AP)

**Action:** Correlate with physical observations. Check the BSSID registry for new entries.

### Example 2: AP Count Drop

Normally 15 APs are in range. At 2:15 AM, only 3 appear.

```
2026-10-15 02:15:04 | RF Anomaly: AP count decrease (current: 3, baseline: 15, z-score: -5.23)
```

**Possible causes:**

- RF jamming (wideband or targeted)
- Physical obstruction blocking signal
- Power outage in the area
- Your own equipment being moved

**Action:** Check if the Pager itself is functioning correctly. Verify with a second device.

### Example 3: Time-of-Day Anomaly

The payload has learned that 3 PM on Tuesdays usually has around 50 APs. Today at 3 PM, there are 12.

```
2026-10-20 15:02:31 | RF Anomaly: AP count decrease (current: 12, baseline: 50, z-score: -3.87)
```

This is a **time-aware anomaly**. The same raw number (12 APs) would be normal at 3 AM but anomalous at 3 PM. This is the key differentiator from static-threshold tools.

---

## Ethical Use & Legal

### What This Payload Does

- Reads **existing passive recon data** already collected by the Pager
- Stores statistical summaries locally on the device
- Alerts the operator via LED, vibration, and log
- Does **not** transmit anything over the network
- Does **not** perform active scanning
- Does **not** interact with any observed device

### What This Payload Does NOT Do

- Does not deauthenticate any client
- Does not create any AP
- Does not inject any packet
- Does not exfiltrate any data
- Does not modify any observed device

### Legal Considerations

Passive RF observation is generally legal in most jurisdictions when performed on public airwaves using equipment you own. However:

- **Do not use this to monitor individuals** without their consent
- **Do not use this in locations where you lack authorization** to operate RF monitoring equipment
- **Laws vary by country** — some jurisdictions restrict passive WiFi monitoring more than others
- **Corporate environments** may have policies restricting RF monitoring even if it's technically legal

**The author assumes no liability for misuse.** This tool is intended for authorized security research, red teaming, and personal privacy defense.

### Ethical Framing

This payload is explicitly designed as a **defensive** tool:

- It helps **you** detect when **you** are being surveilled
- It helps **security teams** detect rogue infrastructure on their networks
- It helps **red teamers** maintain OPSEC during authorized engagements
- It provides **no offensive capability whatsoever**

If you're looking for a tool to attack WiFi networks, this isn't it. There are dozens of other payloads for that. This one exists to help you know when you're the target.

---

## Limitations

- **Learning period required** — the payload is useless until it has collected enough samples. Give it at least a few days.
- **Environment change false positives** — if you move the Pager to a new location, expect anomalies until a new baseline is learned.
- **Recon DB schema dependency** — assumes the standard Pager recon DB schema. May need adjustment for custom firmware.
- **No BSSID-level anomaly detection yet** — currently only AP and client counts are baselined. BSSID-level profiling is on the roadmap.
- **CPU and battery cost** — running the payload continuously will drain the Pager's battery faster than idle. Consider running it on a schedule rather than 24/7.
- **Time-of-day only, not day-of-week** — the current baseline groups all Mondays together with all Sundays. Day-of-week awareness is on the roadmap.

---

## Roadmap

- [ ] **BSSID-level baselining** — flag when a new BSSID appears that matches the characteristics of an existing one (evil twin detection)
- [ ] **Day-of-week awareness** — separate baselines for weekdays vs. weekends
- [ ] **Signal strength distribution profiling** — detect anomalous RSSI patterns
- [ ] **Client behavior baselining** — flag unusual client counts
- [ ] **Alerting integrations** — webhook / MQTT / email notifications
- [ ] **Baseline export/import** — move baselines between Pagers
- [ ] **Web dashboard** — visualize the baseline over time
- [ ] **Adaptive thresholding** — automatically tune `Z_THRESHOLD` based on false positive rate

---

## Contributing

Contributions are welcome. If you're submitting a PR:

1. **Follow Hak5's payload guidelines** — proper headers, directory structure, no external staging
2. **Test on real hardware** — the Pager's MIPS environment has quirks that emulators miss
3. **Include timing measurements** — especially for baseline learning phases
4. **Document new configuration options** in the header comments

### Development Setup

Clone the repository:

```bash
git clone https://github.com/YOUR-USERNAME/wifipineapplepager-payloads.git
cd wifipineapplepager-payloads
```

Create a branch:

```bash
git checkout -b feat/rf-baseline-improvement
```

Make your changes, then commit and push:

```bash
git add .
git commit -m "Describe your change"
git push origin feat/rf-baseline-improvement
```

Then open a PR against `hak5/wifipineapplepager-payloads:master`.

---

## License

MIT License. You are free to use, modify, and distribute this payload. Attribution appreciated but not required.

---

## Disclaimer

**This payload is provided for educational and authorised security research purposes only.**

Payloads from this repository may execute commands on your device. Use them at your own risk. The author makes no guarantees as to effectiveness, safety, or fitness for any particular purpose.

You are solely responsible for complying with all applicable laws in your jurisdiction. Passive RF monitoring may be regulated differently than active scanning in your country — verify before use.

**Hak5 LLC and the WiFi Pineapple Pager are trademarks of Hak5 LLC. This payload is an independent community contribution and is not officially endorsed by Hak5.**

---

*Built for the WiFi Pineapple Pager. Passive by design. Defensive by intent.*
