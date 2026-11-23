# PagerTAK Deauth Alert – Hak5 WiFi Pineapple Pager Alert Payload

**Author:** SECT0101
**Version:** 1.0
**Alert type:** `deauth_flood_detected`
**Requires:** [PagerTAK](../../../user/general/PagerTAK) configured at least once

---

## 📡 Overview

When the Pager detects a **deauthentication / disassociation flood**, this alert payload pushes it to your **TAK Server**:

- a **map marker** at the Pager's position, red and *suspect* by default, named `DEAUTH <last 3 octets of source MAC>` (full MAC in remarks), with the source, AP/BSSID and client MACs in its remarks
- a **GeoChat** message to *All Chat Rooms*:
  `ALERT: deauth flood near PAGER-1 - src de:ad:be:ef:00:01, AP aa:bb:cc:00:11:22`

It suits a Pager left as a **facility security sensor**: anyone on the TAK Server sees a Wi-Fi attack near the Pager in real time.

## ⚙️ How it delivers

| PagerTAK state | What happens |
|---|---|
| **Running** | The alert is queued onto PagerTAK's live connection (instant, store-and-forward) |
| **Not running** | A short one-shot connection uses PagerTAK's saved server, protocol and certificates |

Repeat floods from the **same source MAC** are suppressed for `DEDUPE_SECONDS` (default 5 min). They update the same marker instead of adding new ones.

The marker marks **where the Pager heard the attack**, not where the attacker is. The attacker is somewhere within Wi-Fi range of the Pager.

## 🔧 Options (top of `payload.sh`)

| Option | Default | Notes |
|---|---|---|
| `SEND_MARKER` | `1` | map marker at the Pager position |
| `SEND_CHAT` | `1` | GeoChat to All Chat Rooms |
| `LOCAL_ALERT` | `1` | also show `ALERT` on the Pager |
| `DEDUPE_SECONDS` | `300` | per source MAC |
| `MARKER_TYPE` | `a-s-G` | `a-s-G` suspect, `a-h-G` hostile, `a-u-G` unknown |
| `MARKER_STALE_MIN` | `30` | minutes on the map |
| `PAGERTAK_DIR` | `/root/payloads/user/general/PagerTAK` | where PagerTAK's `certs/` live |

## 🧰 Installation

```
scp -r PagerTAK_Deauth_Alert root@172.16.52.1:/root/payloads/alerts/deauth_flood_detected/
```

Enable it on the Pager under the **Alerts** payloads for *Deauth Flood Detected*.

A log is kept at `/root/loot/PagerTAK/alerts.log`.

## ⚠️ Disclaimer

Detection only: this payload does not transmit anything over the air except the report to your TAK Server. Use it on networks you are authorized to monitor.
