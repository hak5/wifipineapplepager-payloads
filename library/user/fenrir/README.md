# FENRIR WiFi Pineapple Pager Payload Suite

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

  █████▒▓█████  ███▄    █  ██▀███   ██▓ ██▀███
 ▓██   ▒ ▓█   ▀  ██ ▀█   █ ▓██ ▒ ██▒▓██▒▓██ ▒ ██▒
 ▒████ ░ ▒███   ▓██  ▀█ ██▒▓██ ░▄█ ▒▒██▒▓██ ░▄█ ▒
 ░▓█▒  ░ ▒▓█  ▄ ▓██▒  ▐▌██▒▒██▀▀█▄  ░██░▒██▀▀█▄
 ░▒█░    ░▒████▒▒██░   ▓██░░██▓ ▒██▒░██░░██▓ ▒██▒
  ▒ ░    ░░ ▒░ ░░ ▒░   ▒ ▒ ░ ▒▓ ░▒▓░░▓  ░ ▒▓ ░▒▓░
  ░       ░ ░  ░░ ░░   ░ ▒░  ░▒ ░ ▒░ ▒ ░  ░▒ ░ ▒░
  ░ ░       ░      ░   ░ ░   ░░   ░  ▒ ░  ░░   ░
            ░  ░         ░    ░      ░     ░

                        FENRIR
                 COMPLETE ATTACK ENGINE v1.0
```

---

## THIS IS NOT A COLLECTION OF RANDOM PAYLOADS

**FENRIR is a COMPLETE OFFENSIVE ATTACK ENGINE.**

Each payload is designed to chain into the next. One tool feeds another. Together, they form an integrated attack lifecycle that takes you from zero knowledge to full credential harvest with AUTOMATED handoffs between stages.

**This is how real attacks work:**
1. You don't just "scan" - you IDENTIFY targets
2. You don't just "deauth" - you FORCE reconnection to YOUR network
3. You don't just "lure" - you CAPTURE and ENUMERATE every victim
4. You don't just "phish" - you HARVEST credentials with MFA bypass

**FENRIR does ALL of this. In sequence. Automatically.**

---

## THE ATTACK ENGINE

```
  ╔═══════════════════════════════════════════════════════════════╗
  ║                    FENRIR ATTACK CHAIN                        ║
  ╠═══════════════════════════════════════════════════════════════╣
  ║                                                               ║
  ║   [1] HUGINN ──────► Passive recon, target identification    ║
  ║         │                                                     ║
  ║         ▼                                                     ║
  ║   [2] FENRIS ──────► Deauth storm, force disconnection       ║
  ║         │                                                     ║
  ║         ▼                                                     ║
  ║   [3] SKOLL ───────► Evil Twin, karma lure, catch victims    ║
  ║         │                                                     ║
  ║         ├──────────► [4] MUNINN (auto-triggers on connect)   ║
  ║         │                  └─► Client enumeration            ║
  ║         │                                                     ║
  ║         ├──────────► [4] LOKI (credential harvest)           ║
  ║         │                  └─► Phishing portals, MFA capture ║
  ║         │                                                     ║
  ║         └──────────► [4] PMKID_HUNTER (offline crack)        ║
  ║                            └─► Hashcat-ready captures        ║
  ║                                                               ║
  ║   [5] EINHERJAR ───► Multi-Pager swarm coordination          ║
  ║                            └─► Distributed attacks           ║
  ║                                                               ║
  ╚═══════════════════════════════════════════════════════════════╝
```

---

## PAYLOAD DIRECTORY STRUCTURE

Payloads are numbered in attack order so you always know what comes next:

```
/root/payloads/user/fenrir/
├── 1_huginn/           [RECON]    WiFi + BLE identity fusion
├── 2_fenris/           [ATTACK]   Deauthentication storms
├── 3_skoll/            [ATTACK]   Karma/Evil Twin luring
├── 4_loki/             [HARVEST]  Credential phishing portals
├── 4_pmkid_hunter/     [CRACK]    Clientless WPA hash capture
└── 5_einherjar/        [C2]       Multi-Pager swarm control

/root/payloads/alerts/pineapple_client_connected/
└── muninn/             [AUTO]     Triggers on client connect
    └── payload.sh
```

---

## THE PAYLOADS

| # | Payload | Norse Reference | Function | Chains To |
|---|---------|-----------------|----------|-----------|
| 1 | **HUGINN** | Odin's thought raven | WiFi + BLE recon | FENRIS |
| 2 | **FENRIS** | The bound wolf | Deauth storms | SKOLL |
| 3 | **SKOLL** | Wolf chasing sun | Karma/Evil Twin | MUNINN, LOKI, PMKID |
| 4 | **MUNINN** | Odin's memory raven | Auto-enumeration | (alert payload) |
| 4 | **LOKI** | The trickster god | Credential harvest | EINHERJAR |
| 4 | **PMKID_HUNTER** | - | WPA hash capture | (offline crack) |
| 5 | **EINHERJAR** | Odin's army | Swarm coordination | (scales attacks) |

---

## HOW THE CHAIN WORKS

### Stage 1: HUGINN (Reconnaissance)
- Passive WiFi probe capture
- BLE device scanning
- MAC/vendor correlation
- Target identification

**Output:** List of devices, their probe requests, BLE signatures

**Chains to:** FENRIS (you now know WHO to attack)

---

### Stage 2: FENRIS (Disruption)
- Targeted or broadcast deauth
- Forces clients off legitimate APs
- Creates reconnection opportunity

**Output:** Disconnected clients looking for networks

**Chains to:** SKOLL (catch them when they reconnect)

---

### Stage 3: SKOLL (Luring)
- Broadcasts Evil Twin SSID
- Karma responds to probe requests
- Clients auto-connect to YOUR AP

**Output:** Victims connected to your network

**Chains to:** MUNINN (auto-enum), LOKI (harvest), PMKID (crack)

---

### Stage 4a: MUNINN (Auto-Enumeration)
- **ALERT PAYLOAD** - triggers automatically on client connect
- Resolves client IP
- Port scans, OS fingerprinting
- Service detection

**Output:** Intelligence on every connected victim

---

### Stage 4b: LOKI (Credential Harvest)
- Evil Portal with phishing templates
- Microsoft 365, Google, captive portal
- MFA token capture
- DNS spoofing

**Output:** Usernames, passwords, MFA tokens

---

### Stage 4c: PMKID_HUNTER (Hash Capture)
- Clientless WPA attack
- No handshake required
- Hashcat-ready output

**Output:** WPA hashes for offline cracking

---

### Stage 5: EINHERJAR (Force Multiplication)
- Coordinate multiple Pagers
- Commander/Warrior modes
- Distributed attacks
- Aggregate results

**Output:** Scaled attack coverage

---

## QUICK START

### 1. Install the Suite

```bash
# Create fenrir directory on Pager
ssh root@172.16.52.1 "mkdir -p /root/payloads/user/fenrir"

# Copy all payloads
scp -r 1_huginn/ root@172.16.52.1:/root/payloads/user/fenrir/
scp -r 2_fenris/ root@172.16.52.1:/root/payloads/user/fenrir/
scp -r 3_skoll/ root@172.16.52.1:/root/payloads/user/fenrir/
scp -r 4_loki/ root@172.16.52.1:/root/payloads/user/fenrir/
scp -r 4_pmkid_hunter/ root@172.16.52.1:/root/payloads/user/fenrir/
scp -r 5_einherjar/ root@172.16.52.1:/root/payloads/user/fenrir/

# Install MUNINN alert (MUST be folder/payload.sh structure)
ssh root@172.16.52.1 "mkdir -p /root/payloads/alerts/pineapple_client_connected/muninn"
scp muninn/payload.sh root@172.16.52.1:/root/payloads/alerts/pineapple_client_connected/muninn/payload.sh
ssh root@172.16.52.1 "chmod +x /root/payloads/alerts/pineapple_client_connected/muninn/payload.sh"
```

### 2. Run the Attack Chain

```
1. Launch 1_huginn    → Identify targets in range
2. Launch 2_fenris    → Deauth targets off their networks
3. Launch 3_skoll     → Pick an SSID, start Evil Twin
4. Wait for connects  → MUNINN auto-triggers!
5. Check /root/loot/  → Harvest your intelligence
```

---

## ATTACK SCENARIOS

### Corporate Credential Harvest
```
HUGINN  → Identify corporate devices by probes
FENRIS  → Deauth from corporate WiFi
SKOLL   → Broadcast "CorpGuest" or collected SSID
MUNINN  → Auto-enumerate connecting laptops
LOKI    → Microsoft 365 phishing portal
         → Harvest AD credentials
```

### Hotel/Conference Pwn
```
SKOLL   → Quick Karma (Hotel WiFi, Conference WiFi)
PMKID   → Grab hotel WPA hashes
LOKI    → "Free WiFi" registration portal
MUNINN  → Profile all connecting guests
```

### Distributed Red Team
```
EINHERJAR → Deploy 3+ Pagers as swarm
Commander → Coordinate recon sweep
Warriors  → Report back targets
Commander → Order synchronized deauth
All       → Run SKOLL simultaneously
           → Maximum victim capture
```

---

## LOOT STRUCTURE

```
/root/loot/
├── huginn/          # Probe logs, BLE scans, correlations
├── fenris/          # Deauth attack logs
├── skoll/           # SSID collections, karma sessions
├── muninn/          # Client enumeration reports
├── loki/            # HARVESTED CREDENTIALS
├── pmkid/           # WPA hashes (hashcat -m 22000)
└── einherjar/       # Swarm coordination results
```

---

## LED REFERENCE

| Color | Meaning |
|-------|---------|
| Cyan | Scanning/Startup |
| Amber | Processing/Collecting |
| Green | Active/Success |
| Red | Attack in progress |
| Magenta | Luring/Enumerating |
| White | Idle/Complete |

---

## REQUIREMENTS

- WiFi Pineapple Pager (firmware 1.0+)
- Monitor mode interface (wlan1mon)
- For PMKID: hcxdumptool, hcxtools
- For EINHERJAR: BLE adapter (hci0)
- For LOKI: nginx, php, dnsmasq

---

## LEGAL DISCLAIMER

FENRIR is designed for **authorized penetration testing** and **security research** only.

- Only use on networks you own or have written permission to test
- Unauthorized access to computer networks is illegal
- You are responsible for compliance with all applicable laws

---

## AUTHOR

**HaleHound**

---

## VERSION

**1.0.0** (2026-01-07)
- Complete attack engine release
- 7 integrated payloads
- Full attack chain automation
- MUNINN alert integration verified
