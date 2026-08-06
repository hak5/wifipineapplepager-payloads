# SharkJack Launcher

**Author:** InfoSecREDD
**Version:** 4.6

Pager payload that runs **Hak5 Shark Jack** library payloads on the **Hak5 Pager**: emulation layer for `eth0` → **USB External Ethernet mod** or **Pager Wi‑Fi WAN** (`wlan0cli`), menus to browse/run/activate payloads, optional GitHub library sync, and safe handling of `halt` / `poweroff` / `reboot`.

If this README and `payload.sh` disagree, trust the **`# Version:`** line in `payload.sh`.

## What you need

| Requirement | Notes |
|-------------|--------|
| **WAN link (pick one)** | **USB:** External Ethernet mod (Hak5 ethernet_mod); default `lsusb` `0bda:8152`. **Wi‑Fi:** set **`SHARKJACK_WAN_LINK=wlan`** (aliases `wifi`, `wlan0cli`) — uses **`wlan0cli`** (Pager internal WAN) by default. |
| **`lsusb`** | USB mode only: `opkg install usbutils` if missing |
| **Netdev** | USB: usually `eth1`. Wi‑Fi WAN: usually `wlan0cli`. Override via `hub/.eth_mod_if` (see below). |
| **Download library** | `wget` or `curl` over **Wi‑Fi** (or any path to the internet) |
| **Wi‑Fi client + AP** | **Client (STA) mode** must be **associated to an access point** with internet before the **first** download of the Shark Jack library (menu **5**) or other online setup—otherwise the device has no route to GitHub. Configure Wi‑Fi in the Pager UI as needed. |
| **Run payloads** | USB: adapter plugged in and iface up (or `SHARKJACK_SKIP_USB_CHECK=1`). **WLAN:** `wlan0cli` present/up (or skip check). |

## Install on the Pager

1. Copy `payload.sh` into your payload library (same layout as other Hak5 payloads), e.g.:

```sh
mkdir -p /root/payloads/user/general/SharkJack_Launcher
# copy payload.sh here
chmod +x /root/payloads/user/general/SharkJack_Launcher/payload.sh
```

2. On device: **Payloads → General → SharkJack Launcher** (exact path depends on firmware).

3. First launch creates **`SHARKJACK_HUB`** (default `/root/sharkjack`), the **library** tree, and loot links. If the default path is not writable, the script falls back to `/tmp/sharkjack-library` and explains via `ALERT`.

4. To **download the official Shark Jack payload library** (main menu **5**) on a fresh install, ensure the Pager is in **Wi‑Fi client mode** and **connected to an access point** that provides internet. Without that link, `wget` / `curl` cannot fetch the archive.

## Hub layout

| Path | Role |
|------|------|
| `$SHARKJACK_HUB/library` | Payload library (categories with `payload.sh` files) |
| `$SHARKJACK_HUB/loot` | Symlink to `LOOT_ROOT` (default `/root/loot`) |
| `$SHARKJACK_HUB/launcher` | Symlink to this payload’s home |
| `$SHARKJACK_HUB/activated_payload` | One line: absolute path to Hak5 “active” payload (set via **Set active** or `ACTIVATE`) |
| `$SHARKJACK_HUB/.eth_mod_if` | Optional one-line netdev name (USB default `eth1`, wlan default `wlan0cli`). Legacy: `.wan_if` is still read if present. |

## Main menu (LCD)

| Key | Action |
|-----|--------|
| **0** | Exit launcher |
| **1** | Browse categories → run a payload (USB Eth mod required) |
| **2** | Quick run — full path to `payload.sh`; default is **activated** payload if set, else `library/recon/ipinfo/...` |
| **3** | Set active payload (Hak5 `ACTIVATE` — no USB check) |
| **4** | Clear activation |
| **5** | Download / replace library from official GitHub archive (Wi‑Fi OK) |
| **6** | Switch mode (Hak5 `switch1` / `switch2` / `switch3` file + prompts) |
| **7** | Help (compat commands summary) |

Cancel on a picker **redisplays** the menu; it does not exit the launcher (see `set -e` + `|| true` on pickers in `payload.sh`).

### Inside Browse / Activate

- Category list: **`0`** = back to main menu.
- Payload pages: **`0`** = next page, **`9`** = main menu, number = run or set active (depending on entry point).

## Emulated SharkJack behavior

The script defines shell wrappers so Shark Jack payloads see familiar commands:

- **`ifconfig` / `route` / `ip` / `ping` / `arp`**: logical **`eth0`** maps to **`SHARKJACK_WAN_IF`** (USB `eth1` or **`wlan0cli`** when **`SHARKJACK_WAN_LINK=wlan`**). **`ip`** and **`route`** output rewrites the real netdev name to **`eth0`** so patterns like **`ip addr \| grep eth0`** keep working.
- **`tcpdump`**, **`arp-scan`**, **`nmap`**, **`lldpd`**, **`netdiscover`**, **`traceroute`**: **`eth0`** (and forms like **`--interface=eth0`**, **`-i eth0`**, **`-I eth0`**, **`-e eth0`**) is mapped to **`SHARKJACK_WAN_IF`**. **`arp-scan`** with no interface (e.g. **`--localnet`**) prepends **`--interface=$SHARKJACK_WAN_IF`**. **`netdiscover`** with no **`-i`** prepends **`-i $SHARKJACK_WAN_IF`**. Install **`opkg`** packages as needed.
- **`LED`**, **`SWITCH`**, **`BATTERY`**, **`NETMODE`**, **`GET_WAN_IP`**, **`SERIAL_WRITE`**, **`LIST`**, **`ACTIVATE`**, **`UPDATE_PAYLOADS`**, **`ENSURE_LOOT`**, **`C2CONNECT`**, **`C2EXFIL`**, etc. — see on-device **Help** and [Hak5 Shark Jack docs](https://docs.hak5.org/shark-jack/).

**`C2EXFIL`:** supports **`C2EXFIL STRING <file> <label>`** (Hak5 style) and **`C2EXFIL <file> <label>`** (two args, file must exist).

**`halt` / `poweroff` / `reboot`:** simulated (`exit 120`) so the Pager returns to the launcher unless **`SHARKJACK_ALLOW_HALT=1`** (dangerous on a live router).

## Environment variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `SHARKJACK_HUB` | `/root/sharkjack` | Hub directory (library, loot link, activation file) |
| `SHARKJACK_LIBRARY` | `$SHARKJACK_HUB/library` | Library root |
| `LOOT_ROOT` | `/root/loot` | Loot tree |
| `SHARKJACK_ETH_ALIAS` | `eth0` | Name payloads use |
| `SHARKJACK_WAN_LINK` | `usb` | `usb` = External Ethernet mod; **`wlan`** = Pager internal WAN (**`wlan0cli`**). Aliases: `wifi`, `wlan0cli` |
| `SHARKJACK_WAN_IF` | `eth1` or `wlan0cli` | Real netdev (depends on `SHARKJACK_WAN_LINK`; Hak5 env name kept) |
| `SHARKJACK_USB_ETH_ID` | `0bda:8152` | `lsusb` match for the mod (USB mode only) |
| `SHARKJACK_SKIP_USB_CHECK` | `0` | `1` = skip USB check when **running** payloads (e.g. desktop test) |
| `SHARKJACK_MENU_PAUSE_MS` | `0` | Delay after splash / fallback when `WAIT_FOR_INPUT` missing |
| `SHARKJACK_MENU_READY` | `wait` | Before pickers: `wait` = any button; also `off`, `sleep`, `prompt`, … |
| `SHARKJACK_RAINBOW` | `1` | `0` = skip boot rainbow LED sequence |
| `SHARKJACK_SKIP_NET_RESTORE` | `0` | `1` = skip `ubus` / `ifup` restore on launcher **exit** |
| `SHARKJACK_UBUS_IF` | *(empty)* | OpenWrt ubus logical iface name if it differs from netdev |
| `SHARKJACK_ALLOW_HALT` | `0` | `1` = real `halt`/`poweroff`/`reboot` |
| `SHARKJACK_GITHUB_ARCHIVE_URL` | Hak5 `master` tarball | Mirror or pin another branch here |
| `PAGE_SIZE` | `4` | Payloads per page in category browse |

## Network note

Default mode targets the **USB External Ethernet mod**. With **`SHARKJACK_WAN_LINK=wlan`**, stack commands use **Pager internal Wi‑Fi WAN** (`wlan0cli` by default). On exit, the script best-effort restores the chosen netdev (`ubus` + `ifdown`/`ifup`) unless `SHARKJACK_SKIP_NET_RESTORE=1`. If OpenWrt’s logical name differs (e.g. `wan` vs `wlan0cli`), set **`SHARKJACK_UBUS_IF`** as needed.

## Offline / desktop smoke test

```sh
SHARKJACK_SKIP_USB_CHECK=1 SHARKJACK_MENU_PAUSE_MS=0.2 bash /path/to/payload.sh
# Wi‑Fi WAN instead of USB:
SHARKJACK_WAN_LINK=wlan SHARKJACK_SKIP_USB_CHECK=1 SHARKJACK_MENU_PAUSE_MS=0.2 bash /path/to/payload.sh
```

(`LOG` / `NUMBER_PICKER` must exist or the script will fail early—firmware provides these on device.)

## Repo

Official payloads archive: [hak5/sharkjack-payloads](https://github.com/hak5/sharkjack-payloads).
