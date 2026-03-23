# Neon Bikes

**Author:** wickedNull  
**Category:** Games  
**Version:** 1.1

Light cycle arena game for the Hak5 WiFi Pineapple Pager. Race your neon trail against a CPU opponent — first to crash loses.

## Controls

| Button | Action |
|--------|--------|
| D-Pad | Steer your bike |
| A (GREEN) | Start / Restart |
| B (RED) | Quit / Back to title |

## Install

```bash
scp -r neon_bikes/ root@172.16.52.1:/root/payloads/user/games/
```

Then launch from the Pager payload menu under **Games > Neon Bikes**.

## Requirements

- PAGERCTL utility must be installed (provides `libpagerctl.so` and `pagerctl.py`)
- Python3 on MMC (`opkg install -d mmc python3`)

## Troubleshooting

If the game crashes or the screen goes blank, check the log:

```bash
cat /tmp/neon_bikes.log
```

The `lib/` directory is auto-populated on first run by copying from the PAGERCTL utility location.

