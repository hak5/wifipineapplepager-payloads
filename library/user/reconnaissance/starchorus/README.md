# Starchorus

Starchorus is a strictly passive, receive-only Wi-Fi observation tool for the WiFi Pineapple Pager.
It reads what the Pager's recon service has already heard and draws the radio environment from it:
access points are stars, their clients orbit them as satellites, and the distance from the centre
follows the signal strength.

## Made for a second screen

The Pager's display is too small for a sky, so the Pager does the listening and a laptop, tablet or
phone does the looking. Connect any device to the Pager over USB-C or its management Wi-Fi and
open:

    http://172.16.52.1:8199/

The Pager serves the page itself; nothing needs to be installed on the viewing device, and any
current browser will do. The page refreshes every 5 seconds from the latest capture. It is served
on the management address only, so it never appears on other networks the Pager may join.

The Pager's own display carries a compact dashboard instead: seven screens of counts and lists, for
a glance when no second screen is to hand. To see what the second screen shows without a Pager,
open the demonstration at <https://starchorus.com/pager/>.

Project home, full documentation and source: <https://github.com/starchorus/pager>

Starchorus is an independent project, not affiliated with, sponsored or endorsed by Hak5. Hak5,
WiFi Pineapple and WiFi Pineapple Pager are trademarks of Hak5 LLC.

## Strictly passive

Starchorus never transmits. It does not deauthenticate, run an access point of its own, inject
frames, associate with any network or scan actively. It reads the recon database from a read-only
copy (`sqlite3 -readonly`), or receives in monitor mode. It does not change the LED. An active scan
exists in the collector only as a last resort behind the environment variable
`STARCHORUS_ALLOW_ACTIVE=1`; it is off by default, and no menu item or setting reaches it.

One collector runs per Pager, so that two loops never share the monitor interface or radio: starting
or stopping any instance stops every other collector loop on the device, and each loop so stopped is
named in the collector's LOG with its pid and working directory.

## Files

| File | Purpose |
|---|---|
| `payload.sh` | the payload: on-device menu, settings, start and stop |
| `starchorus-collect.sh` | passive collector; writes `starchorus.json` |
| `index.html` | the page, one self-contained file; it fetches only `starchorus.json` and sends nothing |
| `starchorus-display.sh` | dashboard on the Pager's display |
| `starchorus-serve.sh` | netcat fallback server for the page, used when no other web server is present |
| `LICENSE` | GNU General Public License, version 3 |

On its first run the payload copies the collector, the page, the dashboard and the fallback server
into `/root/loot/starchorus` and runs them from there; `starchorus.json` and the settings file
`settings.conf` live in the same directory. A collector already present there is never overwritten.
To take a newer version of this payload, delete `/root/loot/starchorus/starchorus-collect.sh` and
start the payload again; your settings are kept.

## Requirements

- The Pager with its recon service running. The collector reads the service's database read-only.
- `sqlite3` and `jq`, both present on the Pager.
- Optionally, a web server to serve the page: the payload uses `uhttpd`, otherwise `python3`,
  otherwise the bundled fallback server (reliable for `curl`, less so for a browser). Without one,
  the collector still writes `starchorus.json`, and the dashboard on the Pager works as usual.

## Running it

1. On the Pager's dashboard, open **Payloads**, then **Reconnaissance**, then **Starchorus**.
2. Choose **Start** and confirm 'Start collector, web page?'.
3. The dashboard opens on the Pager's display. Key B opens its menu.
4. On a laptop, tablet or phone connected over USB-C or the Pager's management Wi-Fi, open
   `http://172.16.52.1:8199/` for the full sky.

The payload's menu offers 'Start', 'Dashboard', 'Services' (collector and web page, each on or
off), 'Options', 'Status', 'Stop' and 'Exit'. 'Exit' leaves running services running; 'Stop' ends
the collector and the page server.

Over ssh, the same payload works without the menu:

```sh
payload.sh start           # start according to the settings
payload.sh stop            # stop the collector and the page server
payload.sh status          # status lines
payload.sh get [KEY]       # show one setting or all
payload.sh set KEY VALUE   # check and store a setting
payload.sh reset           # back to the defaults
```

## Settings

The menu and `payload.sh set` store only the keys you change, in `/root/loot/starchorus/settings.conf`.
The file is read line by line and never executed; unknown keys and invalid values are ignored. An
environment variable of the same meaning takes precedence over the file.

| Key | Default | Valid | Meaning |
|---|---|---|---|
| `window` | `3600` | `0` or `60`–`86400` | seconds of the recon record read per pass; `0` reads all of it |
| `interval` | `30` | `5`–`3600` | seconds between two writes of `starchorus.json` |
| `port` | `8199` | `1024`–`65535`, not `1471` | port of the page server |
| `bind` | `auto` | `auto`, `all` or an IPv4 address | address of the page server (command line only) |
| `vendor` | `on` | `on`, `off` | vendor names from the local OUI list |
| `own` | `off` | `on`, `off` | mark the Pager's own radios |
| `survey` | `off` | `on`, `off` | channel occupancy from the survey dump |
| `collector` | `on` | `on`, `off` | 'Start' starts the collector |
| `page` | `on` | `on`, `off` | 'Start' starts the page server |
| `dashboard` | `on` | `on`, `off` | open the dashboard after 'Start' |

A window of one hour keeps each pass small enough for the Pager's CPU; 'All' and windows above
six hours ask for confirmation first.

## Network exposure

The page and `starchorus.json` contain every MAC address and SSID the Pager has recorded. By
default (`bind=auto`) the page server listens only on the management address `172.16.52.1`
(`br-lan`: USB-C and the management Wi-Fi), so a network the Pager joins as a client does not
reach it. It never falls back to every interface on its own. `payload.sh set bind all` listens on
every interface and makes that data available to anyone on any network the Pager is on; use it
only where that is acceptable.

Radio monitoring is regulated differently from country to country. Use Starchorus only where you
are entitled to, and handle the recorded data with care.

## Licence

Starchorus is free software under the GNU General Public License, version 3 or (at your option) any
later version (`GPL-3.0-or-later`); see `LICENSE`. The font embedded in `index.html` is Overpass,
under the SIL Open Font License 1.1, whose text travels inside that file.
