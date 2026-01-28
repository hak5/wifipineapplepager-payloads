# GARMR - KARMA + Evil Portal Combined

**Version 4.7.0** | *Named after the blood-stained hound that guards the gates of HALE*

```
                              .......::.:....
                        ..::------------------::..
                      .:-=======================-::.
                    .:---====================-----::.
                  .:::::::-----=-----=--=---:::::::...
                ....:::::----====-=--====--------:::...
                ...::------::---=========--::::::--::.
                ....:::........:.:::::::..........:::.
                 .....      ........::..      ...   ..
                 . .            ..::....       ...
                              ...::.   ...
                   ..         .::.      ...          .
                  .:..     ......        .....      ....
               ... .:...........      .    .   .....::.
               ........  ..   ...       .....  ..........
                             .....      .....   ...
                              ...... .......
                           ...::.........:::.
                          ....... ....:......
                          ....     .  ....

  ▄████     ▄▄▄       ██▀███   ███▄ ▄███▓ ██▀███
 ██▒ ▀█▒   ▒████▄    ▓██ ▒ ██▒▓██▒▀█▀ ██▒▓██ ▒ ██▒
▒██░▄▄▄░   ▒██  ▀█▄  ▓██ ░▄█ ▒▓██    ▓██░▓██ ░▄█ ▒
░▓█  ██▓   ░██▄▄▄▄██ ▒██▀▀█▄  ▒██    ▒██ ▒██▀▀█▄
░▒▓███▀▒    ▓█   ▓██▒░██▓ ▒██▒▒██▒   ░██▒░██▓ ▒██▒
 ░▒   ▒     ▒▒   ▓▒█░░ ▒▓ ░▒▓░░ ▒░   ░  ░░ ▒▓ ░▒▓░
  ░   ░      ▒   ▒▒ ░  ░▒ ░ ▒░░  ░      ░  ░▒ ░ ▒░
░ ░   ░      ░   ▒     ░░   ░ ░      ░     ░░   ░
      ░          ░  ░   ░            ░      ░

                  GUARDS THE GATES
```

---

## Overview

GARMR combines **SKOLL's KARMA luring** with **LOKI's credential harvesting** into a single, streamlined payload. It broadcasts enticing SSIDs, responds to probe requests, and serves convincing phishing portals to capture credentials - all with real-time push notifications to your phone.

**Key Features:**
- 3 core portal types (Microsoft 365, Google Workspace, WiFi Captive)
- 6 branded portals (Starbucks, McDonald's, Airport, Hotel, Xfinity, AT&T)
- KARMA SSID pool for probe response attacks
- NTFY push notifications for instant credential alerts
- MFA token capture with urgency notifications
- Toggle on/off by running again

---

## The Attack Chain

```
    ┌─────────────────────────────────────────────────────────────────┐
    │                    GARMR ATTACK FLOW                            │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │   STEP 1: SSID BROADCAST                                        │
    │   ════════════════════════                                      │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  GARMR broadcasts chosen SSID:                          │  │
    │   │                                                          │  │
    │   │  Portal: Microsoft 365 ──► "Microsoft WiFi"              │  │
    │   │  Portal: Google ─────────► "Google Guest"                │  │
    │   │  Portal: WiFi ───────────► "Free WiFi"                   │  │
    │   │                                                          │  │
    │   │  SSID matches portal branding for credibility            │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   STEP 2: KARMA POOL ACTIVATION                                 │
    │   ═════════════════════════════                                 │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  KARMA responds to ANY probe request:                    │  │
    │   │                                                          │  │
    │   │  Device probes: "HomeNetwork"  ──► GARMR: "Yes, I'm it!" │  │
    │   │  Device probes: "WorkGuest"    ──► GARMR: "Yes, I'm it!" │  │
    │   │  Device probes: "Starbucks"    ──► GARMR: "Yes, I'm it!" │  │
    │   │                                                          │  │
    │   │  Devices auto-connect to "remembered" networks           │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   STEP 3: CAPTIVE PORTAL REDIRECT                               │
    │   ═══════════════════════════════                               │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  All HTTP/HTTPS traffic redirected to phishing portal:  │  │
    │   │                                                          │  │
    │   │  DNS Spoofing ─────► All domains → Pager IP              │  │
    │   │  DNAT Rules ───────► Port 80/443 → Portal                │  │
    │   │  Captive Detection ► iOS/Android triggers login page     │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   STEP 4: CREDENTIAL HARVEST                                    │
    │   ══════════════════════════                                    │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  Portal captures credentials in stages:                  │  │
    │   │                                                          │  │
    │   │  Stage 1: Email ─────────► Captured + Notification       │  │
    │   │  Stage 2: Password ──────► Captured + URGENT Alert       │  │
    │   │  Stage 3: MFA Code ──────► Captured + "30 SECONDS!"      │  │
    │   │                                                          │  │
    │   │  Client authorized after capture = internet access       │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

---

## Portal Options

```
    ┌─────────────────────────────────────────────────────────────────┐
    │                    PORTAL SELECTION                             │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  [1] MICROSOFT 365                                       │  │
    │   ├─────────────────────────────────────────────────────────┤  │
    │   │  - Pixel-perfect Microsoft login page                    │  │
    │   │  - Multi-stage: Email → Password → MFA                   │  │
    │   │  - Includes "Forgot password" and "Sign-in options"      │  │
    │   │  - Redirects to office.com after capture                 │  │
    │   │                                                          │  │
    │   │  Best for: Corporate targets, business travelers         │  │
    │   │  SSIDs: Microsoft WiFi, Azure Guest, Office 365 WiFi,    │  │
    │   │         Microsoft Guest, Outlook WiFi, Teams Meeting     │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  [2] GOOGLE WORKSPACE                                    │  │
    │   ├─────────────────────────────────────────────────────────┤  │
    │   │  - Authentic Google sign-in appearance                   │  │
    │   │  - Multi-stage: Email → Password → 2FA                   │  │
    │   │  - Email chip display like real Google                   │  │
    │   │  - Redirects to google.com after capture                 │  │
    │   │                                                          │  │
    │   │  Best for: General public, Gmail users                   │  │
    │   │  SSIDs: Google WiFi, Google Guest, Google Free WiFi,     │  │
    │   │         Workspace WiFi, Gmail Guest, Google Starbucks    │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  [3] WIFI CAPTIVE PORTAL                                 │  │
    │   ├─────────────────────────────────────────────────────────┤  │
    │   │  - Generic "Free WiFi" sign-in page                      │  │
    │   │  - Single stage: Email + Password                        │  │
    │   │  - Modern gradient design                                │  │
    │   │  - Auto-selects branded variant based on SSID:           │  │
    │   │                                                          │  │
    │   │    "Starbucks WiFi"  → Starbucks branded portal          │  │
    │   │    "McDonald's WiFi" → McDonald's branded portal         │  │
    │   │    "Airport WiFi"    → Airport branded portal            │  │
    │   │    "Hotel WiFi"      → Hotel branded portal              │  │
    │   │    "xfinitywifi"     → Xfinity branded portal            │  │
    │   │    "attwifi"         → AT&T branded portal               │  │
    │   │                                                          │  │
    │   │  Best for: Public spaces, casual targets                 │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

---

## KARMA SSID Pool

```
    ┌─────────────────────────────────────────────────────────────────┐
    │                    KARMA SSID POOL                              │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │   When GARMR activates, it loads these SSIDs into KARMA:       │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  CORPORATE                                               │  │
    │   │  ├── Microsoft WiFi                                      │  │
    │   │  ├── Azure Guest                                         │  │
    │   │  ├── Google WiFi                                         │  │
    │   │  └── Google Guest                                        │  │
    │   │                                                          │  │
    │   │  PUBLIC                                                  │  │
    │   │  ├── Free WiFi                                           │  │
    │   │  ├── Guest                                               │  │
    │   │  ├── xfinitywifi                                         │  │
    │   │  ├── attwifi                                             │  │
    │   │  ├── Starbucks WiFi                                      │  │
    │   │  ├── Airport WiFi                                        │  │
    │   │  └── Hotel WiFi                                          │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   Devices probing for ANY of these = auto-connect attempt      │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

---

## Push Notifications (NTFY)

```
    ┌─────────────────────────────────────────────────────────────────┐
    │                    NTFY PUSH ALERTS                             │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │   GARMR sends real-time alerts to your phone via ntfy.sh:      │
    │                                                                 │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  NOTIFICATION STAGES                                     │  │
    │   ├─────────────────────────────────────────────────────────┤  │
    │   │                                                          │  │
    │   │  [EMAIL CAPTURED]                                        │  │
    │   │  ┌────────────────────────────────┐                      │  │
    │   │  │ GARMR: Email Captured          │  Priority: Default   │  │
    │   │  │ Target: victim@company.com     │  Tags: envelope      │  │
    │   │  │ IP: 172.16.52.100              │                      │  │
    │   │  └────────────────────────────────┘                      │  │
    │   │                                                          │  │
    │   │  [PASSWORD CAPTURED]                                     │  │
    │   │  ┌────────────────────────────────┐                      │  │
    │   │  │ GARMR: CREDS CAPTURED!         │  Priority: URGENT    │  │
    │   │  │ Email: victim@company.com      │  Tags: key, alert    │  │
    │   │  │ Password: Summer2026!          │                      │  │
    │   │  │ === TAP TO LOGIN ===           │  Click: login URL    │  │
    │   │  └────────────────────────────────┘                      │  │
    │   │                                                          │  │
    │   │  [MFA CODE CAPTURED]                                     │  │
    │   │  ┌────────────────────────────────┐                      │  │
    │   │  │ GARMR: MFA CODE!               │  Priority: URGENT    │  │
    │   │  │ Code: 847291                   │  Tags: stopwatch     │  │
    │   │  │ Email: victim@company.com      │                      │  │
    │   │  │ === 30 SECONDS! ===            │  Time-critical!      │  │
    │   │  └────────────────────────────────┘                      │  │
    │   │                                                          │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   SETUP:                                                        │
    │   1. Install ntfy app on your phone                            │
    │   2. Subscribe to your topic (e.g., ntfy.sh/garmr-hunt)        │
    │   3. GARMR prompts for topic on first run                      │
    │   4. Topic saved for future runs                               │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

---

## Technical Implementation

```
    ┌─────────────────────────────────────────────────────────────────┐
    │                 NETWORK HIJACKING STACK                         │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │   LAYER 1: DNS SPOOFING                                         │
    │   ═════════════════════                                         │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  dnsmasq --address="/#/172.16.52.1" --port=5353         │  │
    │   │                                                          │  │
    │   │  ALL DNS queries → Pager IP                              │  │
    │   │  google.com → 172.16.52.1                                │  │
    │   │  microsoft.com → 172.16.52.1                             │  │
    │   │  *.* → 172.16.52.1                                       │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   LAYER 2: TRAFFIC REDIRECTION (NFT)                            │
    │   ══════════════════════════════════                            │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  DNAT Rules on inet fw4:                                 │  │
    │   │                                                          │  │
    │   │  TCP 80  (HTTP)  → 172.16.52.1:80   [GARMR_HTTP]        │  │
    │   │  TCP 443 (HTTPS) → 172.16.52.1:80   [GARMR_HTTPS]       │  │
    │   │  UDP 53  (DNS)   → 172.16.52.1:5353 [GARMR_DNS_UDP]     │  │
    │   │  TCP 53  (DNS)   → 172.16.52.1:5353 [GARMR_DNS_TCP]     │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   LAYER 3: WEB SERVER (NGINX + PHP)                             │
    │   ═════════════════════════════════                             │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  /www/ symlinked to active portal:                       │  │
    │   │                                                          │  │
    │   │  /www/index.php   → Portal login page                    │  │
    │   │  /www/capture.php → Credential handler                   │  │
    │   │  /www/generate_204 → Android captive detection           │  │
    │   │  /www/hotspot-detect.html → iOS captive detection        │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │   LAYER 4: EVIL PORTAL API                                      │
    │   ════════════════════════                                      │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  Uses Pager's Evil Portal module for client auth:        │  │
    │   │                                                          │  │
    │   │  MyPortal.php → Extends Portal class                     │  │
    │   │  authorizeClient($ip) → Allows internet after capture    │  │
    │   │  helper.php → MAC/hostname lookup from DHCP leases       │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

---

## Chain Integration

```
    ┌─────────────────────────────────────────────────────────────────┐
    │                 FENRIR ATTACK CHAIN                             │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │   [1] HUGINN ─────► Identify target device (WiFi+BLE)          │
    │         │           "Apple iPhone, BLE: John's iPhone"          │
    │         ▼                                                       │
    │   [7] VERDANDI ──► Fingerprint for persistent tracking          │
    │         │           "Probing for: HomeWiFi, CorpGuest"          │
    │         ▼                                                       │
    │   [2] FENRIS ────► Deauth target from legitimate AP             │
    │         │           "Force disconnect from real network"        │
    │         ▼                                                       │
    │   ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓  │
    │   ┃ [3] GARMR ────► KARMA lure + Evil Portal capture        ┃  │
    │   ┃       │         "Broadcast SSIDs from probe history"    ┃  │
    │   ┃       │         "Serve phishing portal"                 ┃  │
    │   ┃       │         "Capture creds + MFA"                   ┃  │
    │   ┃       │         "Push notification to attacker"         ┃  │
    │   ┗━━━━━━━┿━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛  │
    │           │                                                     │
    │           ├─────────► Use creds for account access              │
    │           │           "Login with captured password"            │
    │           │                                                     │
    │           └─────────► [5] HATI for PMKID if WPA target          │
    │                       "Grab hash for offline cracking"          │
    │                                                                 │
    │   ═══════════════════════════════════════════════════════════   │
    │                                                                 │
    │   GARMR REPLACES:                                               │
    │   ┌─────────────────────────────────────────────────────────┐  │
    │   │  SKOLL (SSID luring) ──┐                                 │  │
    │   │                        ├──► GARMR = Combined             │  │
    │   │  LOKI (Evil Portal) ───┘                                 │  │
    │   └─────────────────────────────────────────────────────────┘  │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

---

## Use Cases

```
    ┌─────────────────────────────────────────────────────────────────┐
    │                      USE CASES                                  │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │   1. CORPORATE CREDENTIAL HARVEST                               │
    │      ┌─────────────────────────────────────────────────────┐   │
    │      │  Setup at coffee shop near target office.            │   │
    │      │  Broadcast "CorpGuest" or "Microsoft WiFi"           │   │
    │      │  Employees auto-connect, enter O365 creds.           │   │
    │      │  MFA code captured with 30-second window.            │   │
    │      │  Push notification = immediate account access.       │   │
    │      └─────────────────────────────────────────────────────┘   │
    │                                                                 │
    │   2. CONFERENCE/EVENT TARGETING                                 │
    │      ┌─────────────────────────────────────────────────────┐   │
    │      │  Deploy at security conference, hotel, airport.      │   │
    │      │  Broadcast "Hotel WiFi" or "Conference WiFi"         │   │
    │      │  Capture credentials from multiple attendees.        │   │
    │      │  High-value targets in concentrated area.            │   │
    │      └─────────────────────────────────────────────────────┘   │
    │                                                                 │
    │   3. SOCIAL ENGINEERING ENHANCEMENT                             │
    │      ┌─────────────────────────────────────────────────────┐   │
    │      │  Use VERDANDI to identify what networks target       │   │
    │      │  is probing for ("HomeNetwork", "WorkGuest").        │   │
    │      │  Configure GARMR with matching SSID.                 │   │
    │      │  Target sees "their" network, trusts the portal.     │   │
    │      └─────────────────────────────────────────────────────┘   │
    │                                                                 │
    │   4. AWARENESS DEMONSTRATIONS                                   │
    │      ┌─────────────────────────────────────────────────────┐   │
    │      │  Security awareness training for organizations.      │   │
    │      │  Show how easy credential theft is on open WiFi.     │   │
    │      │  Demonstrate MFA bypass via real-time capture.       │   │
    │      │  Prove that "Free WiFi" = dangerous.                 │   │
    │      └─────────────────────────────────────────────────────┘   │
    │                                                                 │
    │   5. RED TEAM OPERATIONS                                        │
    │      ┌─────────────────────────────────────────────────────┐   │
    │      │  Initial access via credential capture.              │   │
    │      │  Chain with deauth (FENRIS) for forced migration.    │   │
    │      │  Use fingerprinting (VERDANDI) for targeting.        │   │
    │      │  Maintain persistence across MAC rotations.          │   │
    │      └─────────────────────────────────────────────────────┘   │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

---

## LED Indicators

```
    ┌──────────────────┬──────────────────────────────┐
    │      Color       │          Meaning             │
    ├──────────────────┼──────────────────────────────┤
    │  Amber           │  Setup / Configuration       │
    │  Cyan            │  Network configuration       │
    │  Purple (R128)   │  ACTIVE - Hunting            │
    │  Green           │  Success / Credential saved  │
    │  Red             │  Error                       │
    │  White           │  Idle / Cleanup              │
    └──────────────────┴──────────────────────────────┘
```

---

## Requirements

- WiFi Pineapple Pager with:
  - Evil Portal module installed
  - nginx + PHP (standard on Pager)
  - nft (standard on Pager)
  - dnsmasq (standard on Pager)

No additional packages required.

---

## Output Files

```
/root/loot/garmr/
└── credentials.txt    # All captured credentials with timestamps

Format:
[2026-01-28 14:32:15] EMAIL: victim@company.com (IP: 172.16.52.100)
[2026-01-28 14:32:28] PASSWORD: Summer2026! (Email: victim@company.com)
[2026-01-28 14:32:45] MFA_CODE: 847291 (Email: victim@company.com)
[2026-01-28 14:32:45] === COMPLETE CAPTURE ===
```

---

## Portal Files

```
/root/portals/
├── garmr_shared/          # Shared PHP classes
│   ├── MyPortal.php       # Portal base class
│   └── helper.php         # MAC/hostname helpers
├── garmr_microsoft/       # Microsoft 365 portal
├── garmr_google/          # Google Workspace portal
├── garmr_wifi/            # Generic WiFi portal
├── garmr_starbucks/       # Starbucks branded
├── garmr_mcdonalds/       # McDonald's branded
├── garmr_airport/         # Airport branded
├── garmr_hotel/           # Hotel branded
├── garmr_xfinity/         # Xfinity branded
└── garmr_att/             # AT&T branded
```

---

## Operational Notes

```
    ┌─────────────────────────────────────────────────────────────────┐
    │                 OPERATIONAL NOTES                               │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │   STARTING:                                                     │
    │   - Run payload from Pager menu                                 │
    │   - Select portal type (1-3)                                    │
    │   - Select SSID from list                                       │
    │   - Confirm launch                                              │
    │   - LED turns Purple when hunting                               │
    │                                                                 │
    │   STOPPING:                                                     │
    │   - Run payload again while active                              │
    │   - Select "YES" to stop                                        │
    │   - Portal deactivated, SSID restored                           │
    │                                                                 │
    │   MFA TIMING:                                                   │
    │   - MFA codes valid ~30 seconds                                 │
    │   - URGENT notification sent immediately                        │
    │   - Have target login page ready                                │
    │   - Tap notification to open login URL                          │
    │                                                                 │
    │   SWITCHING PORTALS:                                            │
    │   - Run payload while active                                    │
    │   - Select "NO" to switch (not stop)                            │
    │   - Old portal deactivated                                      │
    │   - Select new portal and SSID                                  │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
```

---

## Author

**HaleHound**

---

## Version History

- **4.7.0** (2026-01-28) - Branded portals + local storage
  - Added 6 branded WiFi portals (Starbucks, McDonald's, Airport, Hotel, Xfinity, AT&T)
  - Portals stored locally in payload folder
  - Auto-select branded portal based on SSID choice
  - Improved portal activation sequence

- **4.4.1** (2026-01-27) - Stability fixes
  - Fixed DNAT rule persistence
  - Improved DNS spoofer startup
  - Better process cleanup on deactivation

- **4.2.0** (2026-01-27) - Proper startup sequence
  - Fixed portal activation order
  - Added verification steps
  - Improved stale process cleanup

- **4.0.0** (2026-01-27) - SKOLL + LOKI combined
  - Merged SKOLL KARMA functions
  - Merged LOKI Evil Portal functions
  - Single payload for complete attack

- **2.0.0** (2026-01-26) - Initial GARMR
  - Basic KARMA + Evil Portal
  - Microsoft and Google portals
  - NTFY push notifications
