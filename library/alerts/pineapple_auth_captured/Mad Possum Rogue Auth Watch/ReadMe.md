# Mad Possum Rogue Auth Watch
Wi‑Fi Pineapple Pager Payload  
Defensive Monitoring & Real‑Time Alerting

---

## Overview

Mad Possum Rogue Auth Watch is a defensive monitoring payload for the Wi‑Fi Pineapple that watches system logs in real time for signs of:

- Rogue / Evil Twin access points
- Suspicious authentication attempts
- PineAP, Karma, probe, and association activity

When suspicious behavior is detected, the script:
- Logs detailed event data
- Triggers a pager-style alert with a custom ringtone
- Sends a system log notification for visibility

This payload is designed for blue‑team awareness, RF monitoring, and situational alerting during assessments or defensive deployments.

---

## What This Script Does

### Core Functions
- Continuously monitors Pineapple system logs using `logread -f`
- Filters for Wi‑Fi attack–related keywords:
  - pineap
  - association
  - auth
  - karma
  - probe
- Extracts RF metadata when available:
  - BSSID
  - Channel
  - RSSI (signal strength)
- Writes structured alerts to a persistent log file
- Plays a pager sound when activity is detected
- Sends a system notification using `logger`

---

## File & Directory Structure

| Path | Purpose |
|-----|--------|
| /sd/logs/madpossum_rogue_auth_watch/ | Main log directory |
| alerts.log | Event and alert log |
| .initialized | First‑run dependency check flag |
| Digimon.rtttl | Pager ringtone (customizable) |

---

## First‑Run Behavior

On first execution, the script:
- Creates the log directory if it does not exist
- Verifies required binaries:
  - grep
  - awk
  - logger
- Logs any missing dependencies
- Writes a first‑run flag to prevent repeated checks

This ensures stability without impacting runtime performance. 

---

## Configurable Variables (What You Can Change)

These variables are defined at the top of the script and can be safely customized:

```bash
LOG_DIR="/sd/logs/madpossum_rogue_auth_watch"
ALERT_LOG="$LOG_DIR/alerts.log"
FIRST_RUN_FLAG="$LOG_DIR/.initialized"
RINGTONE="/usr/share/sounds/pager/Digimon.rtttl"

