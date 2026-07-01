# GBC Emulator

A browser-based Game Boy Color emulator for the WiFi Pineapple Pager.

Play any `.gb` or `.gbc` ROM in your laptop/desktop browser while the pager screen displays the game info and your pager's physical buttons control the game.

## How it works

1. The payload starts a lightweight Python HTTP server on port 8080
2. The pager screen shows the server URL (e.g. `http://172.16.42.1:8080`)
3. Open that URL in any browser on the same network
4. Pick a ROM from the list or upload your own `.gb` / `.gbc` file
5. The Game Boy Color emulator runs at full speed in the browser
6. Pager physical buttons (D-pad, Green=A, Red=B) are forwarded to the game

## Requirements

- At least one `.gb` or `.gbc` ROM file placed in the payload directory
  (`/root/payloads/user/games/zelda_gbc/`)
- `libpagerctl.so` in the payload directory (from the Hak5 Pager SDK)
- Python 3 on the pager (standard)

## Controls

| Pager button | GBC action |
|---|---|
| D-pad | D-pad |
| Green (A) | A button |
| Red (B) | B button |

**Keyboard (browser):** Z=A, X=B, Enter=START, Shift=SELECT, Arrow keys

## Stopping the server

- **Browser:** Click the **Stop Server** button (always visible, top of page)
- **Pager:** Hold the RED button for 1 second

## Files

| File | Purpose |
|---|---|
| `payload.sh` | Pager payload entry point |
| `server.py` | Python HTTP server — serves UI, lists ROMs, handles input |
| `index.html` | Self-contained GBC emulator (SM83 CPU, MBC3, PPU, color palettes) |
| `pagerctl.py` | Python wrapper for `libpagerctl.so` hardware control |

## Author

sinXne0
