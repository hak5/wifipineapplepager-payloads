# FENRIS - Deauth Storm

**Version 2.0.7** | *Named after the monstrous wolf who breaks free from his chains - FENRIS tears clients away from their access points*

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

  █████▒▓█████  ███▄    █  ██▀███   ██▓  ██████
 ▓██   ▒ ▓█   ▀  ██ ▀█   █ ▓██ ▒ ██▒▓██▒▒██    ▒
 ▒████ ░ ▒███   ▓██  ▀█ ██▒▓██ ░▄█ ▒▒██▒░ ▓██▄
 ░▓█▒  ░ ▒▓█  ▄ ▓██▒  ▐▌██▒▒██▀▀█▄  ░██░  ▒   ██▒
 ░▒█░    ░▒████▒▒██░   ▓██░░██▓ ▒██▒░██░▒██████▒▒
  ▒ ░    ░░ ▒░ ░░ ▒░   ▒ ▒ ░ ▒▓ ░▒▓░░▓  ▒ ▒▓▒ ▒ ░
  ░       ░ ░  ░░ ░░   ░ ▒░  ░▒ ░ ▒░ ▒ ░░ ░▒  ░ ░
  ░ ░       ░      ░   ░ ░   ░░   ░  ▒ ░░  ░  ░
            ░  ░         ░    ░      ░        ░

                        FENRIS
                   Deauth Storm v2.0.7
```

## What It Does

Automated deauthentication attacks using the Pager's native `PINEAPPLE_DEAUTH_CLIENT` command. Integrates with PineAP recon data to intelligently target access points and force client disconnections.

## Attack Modes

### 1. Targeted Mode
- Select a specific AP from recon data
- Broadcast deauth to all clients on that AP
- Configurable burst count and rounds
- Useful for focused attacks

### 2. Storm Mode
- Attack ALL discovered access points
- Cycles through every AP in range
- Maximum disruption in the area
- Ideal for creating chaos before Evil Twin attacks

## How It Works

1. Retrieves AP list from PineAP recon data
2. Sends broadcast deauth frames (FF:FF:FF:FF:FF:FF)
3. Configurable packet count and timing
4. Logs all activity for operational records

## Integration with FENRIR Suite

FENRIS is designed to work with other FENRIR payloads:

```
HUGINN (recon) → identifies targets
       ↓
FENRIS (deauth) → disconnects clients
       ↓
SKOLL (karma) → lures reconnecting clients
       ↓
LOKI (portal) → harvests credentials
```

## Usage

1. **Run Recon First** - FENRIS needs AP data from PineAP
2. Launch FENRIS payload
3. Select attack mode:
   - **Targeted**: Pick one AP, configure burst settings
   - **Storm**: Attack all APs in range
4. Configure parameters:
   - Packets per burst (default: 50)
   - Number of bursts/rounds (0 = continuous)
5. Press **A** anytime to stop the attack

## LED Indicators

| Color | Status |
|-------|--------|
| Cyan | Scanning for targets |
| Amber | Selecting target |
| Red | Attack in progress |
| Green | Attack complete |
| Magenta | Error |

## Output

Logs saved to `/root/loot/fenris/`:
- `deauth_TIMESTAMP.log` - Targeted attack logs
- `storm_TIMESTAMP.log` - Storm attack logs

## Configuration

Default settings in `payload.sh`:
```bash
DEFAULT_BURST_COUNT=50       # Deauth packets per burst
DEFAULT_BURST_DELAY=2        # Seconds between bursts
MAX_TARGETS=20               # Maximum concurrent targets
```

## Notes

- Deauth attacks are **highly detectable** by WIDS/WIPS
- Most effective when target clients have auto-reconnect enabled
- Combine with SKOLL (Karma) for Evil Twin attacks
- Some clients may not respond to broadcast deauth - use targeted mode

## Legal Warning

Deauthentication attacks are illegal without explicit authorization. Only use in controlled environments or with written permission.

## Author

HaleHound

## Version

**2.0.7** (2026-01-11)
- Field tested and verified working
- Clean log output format
- Integrated with FENRIR suite v2.0.7
