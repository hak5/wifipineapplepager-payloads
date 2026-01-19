# SKOLL - Karma/Evil Twin Orchestrator

**Version 2.0.7** | *Named after the wolf who chases the sun - SKOLL lures victims with familiar network names, drawing them into the trap*

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

  ██████  ██ ▄█▀ ▒█████   ██▓     ██▓
 ▒██    ▒  ██▄█▒ ▒██▒  ██▒▓██▒    ▓██▒
 ░ ▓██▄   ▓███▄░ ▒██░  ██▒▒██░    ▒██░
   ▒   ██▒▓██ █▄ ▒██   ██░▒██░    ▒██░
 ▒██████▒▒▒██▒ █▄░ ████▓▒░░██████▒░██████▒
 ▒ ▒▓▒ ▒ ░▒ ▒▒ ▓▒░ ▒░▒░▒░ ░ ▒░▓  ░░ ▒░▓  ░
 ░ ░▒  ░ ░░ ░▒ ▒░  ░ ▒ ▒░ ░ ░ ▒  ░░ ░ ▒  ░
 ░  ░  ░  ░ ░░ ░ ░ ░ ░ ▒    ░ ░     ░ ░
       ░  ░  ░       ░ ░      ░  ░    ░  ░

                        SKOLL
               Karma Orchestrator v2.0.7
```

## What It Does

Automated SSID pool management and karma attack configuration. SKOLL responds to client probe requests with matching network names, luring them to connect to your Evil Twin access point.

## Attack Modes

### 1. Quick Karma
- Displays list of 13 common high-value SSIDs
- User picks ONE SSID to broadcast (xfinitywifi, attwifi, Starbucks, etc.)
- Sets that SSID as the Open AP broadcast name
- Seeds karma pool with ALL common SSIDs for probe responses
- Option to keep broadcasting after exit or restore original

### 2. Passive Collection
- Listens for probe requests from nearby devices
- Automatically collects SSIDs clients are looking for
- Builds targeted pool based on local environment
- Option to activate karma with collected SSIDs

### 3. Aggressive Hunt
- Combines collection and karma simultaneously
- Continuously adds new SSIDs while responding
- Maximum coverage and effectiveness
- Runs until manually stopped

### 4. Custom Setup
- Manual SSID pool management
- Add/remove individual SSIDs
- Direct karma start/stop control
- View current pool status

### 5. FENRIS Chain
- Optimized for post-deauth attacks
- Designed to pair with FENRIS payload
- Catches reconnecting clients
- Prepares for LOKI credential harvest

## How Karma Works

1. Client device broadcasts "looking for [SSID]" probes
2. SKOLL's SSID pool contains matching network names
3. Pager responds: "I am [SSID], connect to me"
4. Client connects to your Evil Twin
5. Traffic flows through your controlled AP
6. LOKI portal harvests credentials

## Integration with FENRIR Suite

```
FENRIS (deauth) → forces client disconnection
       ↓
SKOLL (karma) → responds to reconnect probes
       ↓
Client connects → to Evil Twin AP
       ↓
LOKI (portal) → harvests credentials
```

## Pre-Seeded SSIDs

Quick Karma mode includes these high-value targets:
- xfinitywifi
- attwifi
- Starbucks WiFi
- Google Starbucks
- McDonald's Free WiFi
- NETGEAR
- linksys
- default
- Home WiFi
- Guest
- FreeWiFi
- Airport WiFi
- Hotel WiFi

## Usage

1. Launch SKOLL payload
2. Select attack mode
3. Configure options (duration, randomization, etc.)
4. Press **A** to stop when complete

### Recommended Flow:
```
1. Run HUGINN → identify targets
2. Run FENRIS → deauth clients
3. Run SKOLL → catch reconnections
4. Run LOKI → harvest credentials
```

## LED Indicators

| Color | Status |
|-------|--------|
| Cyan | Scanning/Startup |
| Amber | Collecting probes |
| Green | Karma active |
| Magenta | Luring (alternating) |
| Red | Error |

## Output

Files saved to `/root/loot/skoll/`:
- `collected_TIMESTAMP.txt` - SSIDs from passive collection
- `final_pool_TIMESTAMP.txt` - Active pool at session end
- `chain_ssids_TIMESTAMP.txt` - FENRIS chain mode results
- `skoll.log` - Session log
- `aggressive_TIMESTAMP.log` - Aggressive mode logs

## DuckyScript Commands Used

```bash
# SSID Pool Management
PINEAPPLE_SSID_POOL_CLEAR
PINEAPPLE_SSID_POOL_ADD [ssid]
PINEAPPLE_SSID_POOL_DELETE [ssid]
PINEAPPLE_SSID_POOL_LIST
PINEAPPLE_SSID_POOL_START {randomize}
PINEAPPLE_SSID_POOL_STOP

# Automatic Collection
PINEAPPLE_SSID_POOL_COLLECT_START
PINEAPPLE_SSID_POOL_COLLECT_STOP

# Filtering
PINEAPPLE_MAC_FILTER_MODE [allow|deny]
PINEAPPLE_MAC_FILTER_ADD [list] [mac]
PINEAPPLE_SSID_FILTER_MODE [allow|deny]
PINEAPPLE_SSID_FILTER_ADD [list] [ssid]
```

## Best Practices

1. **Location matters** - High-traffic areas yield more probes
2. **Combine with FENRIS** - Deauth forces reconnection attempts
3. **Use aggressive mode** - Catches SSIDs you didn't anticipate
4. **Review collected SSIDs** - Remove duplicates and junk
5. **Chain to LOKI** - Complete the attack with credential harvest

## Legal Warning

Evil Twin and karma attacks are illegal without explicit authorization. Only use in controlled environments or with written permission.

## Author

HaleHound

## Version

**2.0.7** (2026-01-11)
- Field tested and verified working
- Quick Karma mode operational
- Integrated with FENRIR suite v2.0.7
