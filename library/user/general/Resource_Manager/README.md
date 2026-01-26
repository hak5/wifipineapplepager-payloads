# Resource Manager

## Overview

Unified payload for **Payloads**, **Themes**, and **Ringtones** on the WiFi Pineapple Pager. Two update modes with interactive conflict resolution.

## Features

### Update Modes

- **Download All**: Downloads only items NOT already installed (skips existing)
- **Update Installed Only**: Updates only items already installed locally (skips new items)

### Smart Update Flow

1. Choose mode: Download All or Update Installed Only
2. Select resources: Everything or pick individually (Payloads/Themes/Ringtones)
3. Conflict handling (Update mode only): Review each update or batch overwrite/skip all

### Technical

- **Git-based caching** at `/mmc/root/pager_update_cache` for fast incremental updates
- **DISABLED. prefix** handling for payloads
- **Alerts auto-disabled** on first install (safety default)
- **Diff-based** change detection (Update mode)

## Local Paths

| Resource   | Path                    |
|------------|-------------------------|
| Payloads   | `/mmc/root/payloads`    |
| Themes     | `/mmc/root/themes`      |
| Ringtones  | `/mmc/root/ringtones`   |

## Credits

- Based on original update scripts by **cococode**
- Unified and enhanced by **Z3r0L1nk**
