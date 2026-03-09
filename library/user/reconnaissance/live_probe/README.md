# Live Probe Monitor

Captures WiFi probe requests on the Pineapple Pager's monitor interface (wlan1mon). Displays MAC addresses, target SSIDs, and when available, the BSSID of APs being probed. Supports 2.4/5/6 GHz bands.

## Output Options

At startup, select output mode:
- **0** = Screen only
- **1** = Discord webhook
- **2** = Save to loot file
- **3** = Discord + loot

## Configuration (Optional)

Create `client_probe_mon.conf` in the same directory as `payload.sh`:
```bash
DISCORD_WEBHOOK="https://discord.com/api/webhooks/YOUR_WEBHOOK_URL"
WEBHOOK_ENABLED=true     
SAVE_TO_LOOT=true        
WEBHOOK_BATCH_SIZE=5
```

**Note:** Config file settings override menu selections. Use Unix line endings (LF).

## Usage

Run from payload menu, select output mode, press B to stop.

## Author
dudgy