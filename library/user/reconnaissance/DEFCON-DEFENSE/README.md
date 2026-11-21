# DEFCON Defense

> **Author:** Henry Hu · **Project home:** https://github.com/ninedter/DEFCON-DEFENSE
> DEFCON-DEFENSE and RF-BUDDY are developed together there; this directory is a
> self-contained copy for the Pager payload library.

The single visible Pager entry point for the defensive payload package. It
combines passive 2.4/5 GHz monitoring, local alerting, evidence review, and the
curated manual tools in one menu.

Open it from **Payloads > reconnaissance > DEFCON-DEFENSE**. Version 4.20 runs a
dedicated full-screen MIPS application with these designed
480x222 Pager interfaces:

1. the **general screen**, with threat state, Live RF, monitored networks, and
   page navigation;
2. **Observed APs**, populated by the current passive Recon snapshot, with
   UP/DOWN selection and green-A watch/unwatch actions;
3. **My Watch List**, showing the saved user list even when an AP is no longer
   visible, with removal and a direct path back to observed APs for additions;
4. **threat detail**, with severity, plain-language event, affected network,
   secondary RF evidence, and live capture state; and
5. **PCAP Evidence**, with saved time, threat, SSID, size, status, details,
   on-demand SHA-256 verification, deletion confirmation, and Virtual Pager
   download instructions.

The same rendered canvas appears on the physical Pager and in authenticated
Virtual Pager. The bridge is active only while the application is running and
falls back to the stock Pager display when it exits.

While the application is open it freezes the stock Pager UI process (SIGSTOP)
and takes exclusive use of the buttons; pressing B on the general screen
resumes it (SIGCONT), so the Pager menu returns immediately instead of
restarting through "Initializing system". Pressing the **power** button on any
screen also exits the same way, so the stock Pager gets the power button back;
use its Power Menu → **Shutdown** to turn the Pager off cleanly.

Long-running sessions use bounded Recon calls, unique atomic state updates,
low-churn Virtual Pager long polling, a periodically refreshed physical-input
descriptor, and a launch-only framebuffer ownership guard. If Recon stops
answering, the interface remains navigable and marks monitoring as
**DEGRADED** or **STALE** instead of presenting old data as live.

The resource-constrained path keeps two reusable RGB565 buffers and one reusable
canvas, uses fixed bitmap icons instead of a runtime TrueType parser, classifies
all observed APs in one `awk` pass per Recon cycle, computes UI metrics in one
pass, and performs one linear pre-existing-PCAP import when the UI session starts.
Its screen/button server listens only on `172.16.52.1` and requires the random
token injected into the authenticated Virtual Pager bridge.

The monitor ignores Recon rows older than 45 seconds and will not alert from an
observation cached before the current payload session. If a transmitter remains
active, its next post-launch Recon timestamp makes it eligible for detection.

Use it to:

- configure Recon to listen on 2.4 and 5 GHz;
- run passive trusted/watched-network correlation in the background while the
  general screen remains usable;
- watch the continuously refreshing **Live RF Traffic** dashboard with AP and
  packet totals, signal-quality bars, and 2.4/5 GHz activity;
- open **AP Watch List** to browse APs observed in monitored Recon traffic and
  use UP/DOWN plus green A to add or remove a specific AP from monitoring;
- open **Monitored Networks** to edit the saved user watch list, including APs
  that are no longer present in the current observation snapshot;
- keep **Threat Activity Live** continuously refreshing from Recon; malicious
  deauth/disassociation and watched/trusted identity indicators are rendered
  prominently in red while the page remains open;
- open the separate **Investigate Threats** native list with arrows and green A
  to select a current indicator for focused passive capture;
- use UP/DOWN to select, LEFT/RIGHT for the page action shown in each footer,
  green A to open/investigate, and red B for the action named in the footer;
- watch selected networks without a baseline, or optionally create a reviewed
  BSSID baseline for broader new-AP detection;
- monitor continuously for trusted-network impersonation, trusted AP identity
  changes, unexpected channel changes, and persistent strong new APs;
- receive ringtone/vibration alerts and review timestamped findings; recent
  deauth/disassociation events and identity anomalies are shown in red;
- immediately start a bounded 30-second passive PCAP for confirmed red alerts,
  with single-capture locking, per-event/BSSID cooldown, and storage guards;
- browse saved captures and retrieve them later with Virtual Pager's
  **Download Loot** control;
- use the confirmed **Clear Session** main-menu action to clear current alert
  history and all managed PCAP files without removing watched APs, the reviewed
  baseline, or trusted rules;
- open the non-transmitting hostile-RF emergency checklist;
- confirm that both automatic alert handlers are armed;
- launch PORT Alert or ICMP Alert;
- launch Find Hackers or Alien AP; and
- test the alert ringtone and vibration.

The automatic handlers remain in their firmware-required event directories:

- `alerts/deauth_flood_detected/defcon_sentry`
- `alerts/pineapple_client_connected/defcon_honeypot`

Enable PineAP recon/listening for the automatic deauth detector. The honeypot
also requires an intentional neutral open AP.

## Trusted networks

Before the event, edit `trusted_aps.conf` and add each authorized SSID/BSSID
pair. The third field is a comma-separated channel allowlist or `*`:

```text
SOC-Operations|00:11:22:33:44:55|1,6,11
SOC-Operations|00:11:22:33:44:66|36,40,44,48
```

Never put a PSK, password, token, or other secret in this file.

## Monitoring behavior

- Trusted SSID/BSSID or channel mismatches alert immediately.
- An unknown BSSID must be at least `-72 dBm` and appear in two scans within
  60 seconds before it alerts. This reduces noise at crowded venues.
- Per-finding alerts cool down for five minutes.
- Confirmed red alerts automatically begin a 30-second passive capture. A
  matching event/BSSID capture also cools down for five minutes, only one
  capture runs at a time, and capture stops before the 256 MB managed-PCAP quota
  or 64 MB free-space reserve is crossed.
- Optional-baseline `NEW_BSSID` items remain review-level and do not trigger an
  automatic capture.
- Watched networks, the optional baseline, and findings are stored under
  `/root/loot/defcon_defense/`. Firmware-native focused PCAPs are saved under
  `/root/loot/pcap/`.

`watched_aps.tsv` is also a user-editable, tab-separated list using one
`BSSID`, `SSID`, `channel`, and `band` entry per line with no header. This supports preloading an
authorized list before entering RF range; the native **My Watch List** screen
shows those entries without requiring a current observation. Never store a PSK,
password, token, or other secret in this file.

Capture metadata is stored in `/root/loot/defcon_defense/pcap_index.tsv`,
including timestamp, event, severity, SSID/BSSID, band/channel, signal,
duration, size, SHA-256 state, status, trigger, and file path. SHA-256 is
calculated on demand so importing a large pre-existing capture cannot block the
general screen. No capture is deleted automatically; **Clear Session** is an
explicit bulk-delete action that requires RIGHT to arm and then A within three
seconds. Repeated A presses alone cannot trigger it.

The baseline is optional. Create it only after reviewing the current
environment. A device already present in the baseline is treated as previously
seen; watched-network and trusted-network rules still take precedence.

The monitor only reads Recon observations. It does not send deauthentication,
disassociation, interference, or other countermeasure traffic.
