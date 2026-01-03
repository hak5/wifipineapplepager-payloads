# Quick Clone Pro

**Author:** Aitema-GmbH
**Version:** 2.0
**Category:** recon/access_point
**Target:** WiFi Pineapple Pager

## Description

The definitive Evil Twin cloning payload. Clone any selected AP's SSID and MAC address directly into the Pineapple's Open AP configuration. Changes are **persistent** and visible in the Settings menu.

## Features

- **SSID Cloning**: Copy target network name
- **MAC Cloning**: Full BSSID impersonation (optional)
- **Persistent Config**: Uses UCI - survives reboot!
- **Open AP Integration**: Changes appear in Pineapple menu
- **SSID Pool Option**: Also add to pool for future use
- **Backup/Restore**: Can restore original config

## How It Works

Unlike the basic Quick Clone (which only uses SSID Pool), this payload:

1. Writes directly to `/etc/config/wireless` via UCI
2. Configures the actual Open AP (`wlan0open`)
3. Changes persist after payload exits
4. Visible in Pineapple's **Settings → Open AP** menu

## Usage

### Quick Start

```
Recon → Select AP → Payloads → Quick Clone Pro → Answer prompts → Done!
```

### Workflow

```
┌─────────────────────────────────────────────────────────────────┐
│                          RECON                                  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  FRITZ!Box 7590    AA:BB:CC:DD:EE:FF   -45dBm   WPA2   CH6 ││
│  └─────────────────────────────────────────────────────────────┘│
│                              ↓ Select                           │
└─────────────────────────────────────────────────────────────────┘
                               ↓
┌─────────────────────────────────────────────────────────────────┐
│                     QUICK CLONE PRO                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ① Clone this network?                    [Yes] / [No]          │
│     SSID: FRITZ!Box 7590                                        │
│     MAC:  AA:BB:CC:DD:EE:FF                                     │
│                                                                  │
│  ② Also clone MAC address?                [Yes] / [No]          │
│     [Yes] = Full impersonation                                  │
│     [No]  = SSID only                                           │
│                                                                  │
│  ③ Also add to SSID Pool?                 [Yes] / [No]          │
│     [Yes] = Saves for future                                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
                               ↓
┌─────────────────────────────────────────────────────────────────┐
│                     CONFIGURATION APPLIED                        │
│                                                                  │
│  Open AP now configured as:                                     │
│    SSID: FRITZ!Box 7590                                         │
│    MAC:  AA:BB:CC:DD:EE:FF                                      │
│                                                                  │
│  ✓ PERSISTENT - Check Settings → Open AP                        │
│                                                                  │
│  ④ Restore original config?               [Yes] / [No]          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Options Explained

### Clone MAC Address?

| Option | Result |
|--------|--------|
| **Yes** | Full clone - SSID + MAC (BSSID) |
| **No** | Only SSID, keep Pineapple's MAC |

**Full clone benefits:**
- Harder to detect with WIDS
- Clients may auto-connect if they trust the BSSID
- More convincing impersonation

### Add to SSID Pool?

| Option | Result |
|--------|--------|
| **Yes** | Saves SSID permanently for SSID Pool feature |
| **No** | Only configures Open AP |

### Restore Original?

| Option | Result |
|--------|--------|
| **Yes** | Reverts Open AP to previous SSID/MAC |
| **No** | Keeps new config (persistent until changed) |

## Technical Details

### UCI Commands Used

```bash
# Set SSID
uci set wireless.wlan0open.ssid='TARGET_SSID'

# Set MAC (optional)
uci set wireless.wlan0open.macaddr='AA:BB:CC:DD:EE:FF'

# Enable Open AP
uci set wireless.wlan0open.disabled='0'

# Write to flash
uci commit wireless

# Apply changes
wifi reload
```

### Configuration File

Changes are written to: `/etc/config/wireless`

```
config wifi-iface 'wlan0open'
    option device 'radio0'
    option ifname 'wlan0open'
    option mode 'ap'
    option ssid 'CLONED_SSID'        ← Changed
    option macaddr 'AA:BB:CC:DD:EE:FF' ← Changed
    option disabled '0'
```

### Backup Location

Original config is backed up to:
- `/tmp/quickclone_backup_ssid`
- `/tmp/quickclone_backup_mac`

These are deleted after restore or if user keeps new config.

## LED States

| State | Color | Meaning |
|-------|-------|---------|
| SETUP | Magenta | Ready / Prompts |
| ATTACK | Yellow | Applying config |
| FINISH | Green | Complete |
| FAIL | Red | Error |

## Comparison: Quick Clone vs Quick Clone Pro

| Feature | Quick Clone | Quick Clone Pro |
|---------|-------------|-----------------|
| SSID Clone | ✓ | ✓ |
| MAC Clone | ✗ | ✓ |
| Persistent | ✗ (SSID Pool only) | ✓ (UCI config) |
| Open AP Menu | ✗ | ✓ |
| Survives Reboot | Pool only | Full config |
| Backup/Restore | ✗ | ✓ |

## Troubleshooting

### Changes Not Visible in Menu

Wait 5-10 seconds after payload completes. The Pineapple UI may need to refresh.

### MAC Not Changing

Some drivers may not support MAC spoofing. Check with:
```bash
cat /sys/class/net/wlan0open/address
```

### "UCI Error"

The wireless config may be locked. Try:
```bash
wifi down
wifi up
```

## Security Notes

- **Authorization Required**: Only clone networks you own or have permission to test
- **Detection**: Full BSSID cloning is more convincing but still detectable
- **Legal**: Network impersonation may be illegal in your jurisdiction

## Changelog

### Version 2.0
- Complete rewrite using UCI
- Added MAC cloning
- Persistent configuration
- Backup/restore functionality
- SSID Pool integration option

### Version 1.0
- Initial release (SSID Pool only)

## License

[Hak5 License](https://github.com/hak5/wifipineapplepager-payloads/blob/master/LICENSE)
