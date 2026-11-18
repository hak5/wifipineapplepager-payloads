# KEYSMITH

**Default-WPA key recovery for the WiFi Pineapple Pager.**

KEYSMITH reads what a router is already broadcasting — its SSID and BSSID —
derives the factory-default WPA key that the ISP or manufacturer generated
from that data, proves the candidate by completing a real 4-way handshake,
joins the network, and puts the plaintext passphrase on the Pager's screen.

No handshake capture. No wordlist. No deauth. The key is computed, then
verified by associating with the access point.

> **Authorized testing only.** KEYSMITH derives default keys and associates
> with the selected network. Use it only on networks you own or have written
> permission to test. Most routers that still ship a derivable default key are
> old, unpatched consumer gear; recovering one is not permission to use it.

```
TARGETS   ▸ live scan, sorted by whether a known scheme matches
            ▸ UP/DOWN chooses an AP, A plans the attack
PLAN      ▸ every default-key scheme the SSID/BSSID pair matches
            ▸ A derives and attacks, B goes back
DERIVE    ▸ per-scheme progress; candidate keys accumulate
HANDSHAKE ▸ one candidate at a time, live 4-way result
RESULT    ▸ the plaintext PSK, the algorithm, the lease
            ▸ A disconnects, B rescans
```

The engine and the UI are separate processes. The UI only reads
`/tmp/keysmith_state.json` and appends to `/tmp/keysmith_cmd.jsonl`; a crashed
UI cannot leave the radio half-configured, and a slow derivation (Thomson is
21.8 million SHA-1 operations) never freezes the display. **B** aborts at any
point, and the derived key list is already on disk.

---

## What actually happens

1. `ks/scan.py` picks a managed interface on **phy1** only. phy0 carries the
   Pager's management uplink: scanning it drops the phone tether and the stock
   UI, so the code refuses to use it even if asked by name.
2. `iw dev <iface> scan` is parsed into SSID, BSSID, channel, band, security
   and vendor. Each AP is annotated with the number of default-key schemes its
   SSID/BSSID pair matches; matched APs sort first, then by signal.
3. `ks/matcher.py` applies RouterKeygen's rule table: SSID patterns, OUI
   prefixes, and the vendor-specific MAC reconstruction used when the beacon
   hides the BSSID (Sitecom, Eircom, Pirelli, Verizon, Thomson).
4. `ks/keygens.py` runs the matching generators — MD5/SHA-1 transforms,
   per-vendor alphabets, and lookup tables for Tele2 and OTE Huawei.
5. `ks/wpa.py` writes a private `wpa_supplicant` config and tests each
   candidate. A wrong PSK is rejected right after the second handshake
   message (`4-Way Handshake failed - pre-shared key may be incorrect`), so a
   bad candidate costs about a second instead of a full association timeout.
   On success it daemonizes the supplicant, requests a lease with `udhcpc`
   through a hook that **does not** install a default route or touch
   `/etc/resolv.conf`, and reports the IP, gateway and DNS servers.
6. Results land in `/root/loot/keysmith/`.

If `wpa_supplicant` is missing, KEYSMITH still derives and displays the key
and marks it **unverified** — the derivation never depends on the radio.

---

## Coverage

42 generators, ported from RouterKeygen:

| Family | Schemes |
| --- | --- |
| Thomson / SpeedTouch | `Thomson`, `Speedport500` |
| Huawei | `Huawei`, `HG824x`, `OteHuawei`, `OteBAUD` |
| Zyxel / Comtrend | `Zyxel`, `Comtrend`, `Tecom` |
| Alice / Pirelli | `AliceItaly`, `AliceGermany`, `Pirelli`, `ArnetPirelli`, `Discus` |
| Sitecom / D-Link | `Sitecom`, `SitecomWLR400x`, `SitecomWLR2100`, `Dlink` |
| Belkin / Verizon / Sky | `Belkin`, `Verizon`, `SkyV1` |
| ISP rebrands | `Teletu`, `Infostrada`, `InterCable`, `Ono`, `CabovisaoSagem`, `PBS`, `Axtel`, `WifimediaR`, `Pldt`, `Eijsink`, `Gontwifi`, `Andared`, `Conn`, `Tpw4g`, `Wlan2`, `Wlan6`, `Eircom` |
| Generic | `Bssid`, `BaseX`, `Arcadyan`, `Upc07` |

`Upc07` is solved directly instead of brute-forcing 10,000 candidates per
prefix, which makes Technicolor routers usable on the Pager. `SLOW` schemes
(`Thomson`, `Speedport500`, `Comtrend`, `Hg824x`, `SitecomWLR400x`, `Upc07`)
are flagged in the PLAN screen so you know what you are starting.

Two upstream generators are deliberately **not** ported, and are documented as
gaps rather than silently returning wrong keys:

- `Telsey` — depends on Jenkins lookup3; not worth the risk of a subtly wrong
  port.
- `Upc07Ubee` — a large substitution table tied to one firmware build.

---

## Install

Copy the `keysmith/` folder to the Pager as a payload:

```
/root/payloads/user/reconnaissance/keysmith/
```

Then launch it from the Pager menu (Payloads ▸ user ▸ reconnaissance ▸
KEYSMITH). `payload.sh` self-locates, so the category folder name does not
matter.

Dependencies:

- `iw` (required)
- `python3-light` (required)
- `wpa_supplicant` (recommended; without it KEYSMITH is derive-only)
- `udhcpc` (recommended; without it association gets no IP)

Firmware 2.x disables `opkg install`, so `install_pkg.py` is bundled and used
by the launcher if a Python module is missing.

**Kill the stock Pager UI first.** `payload.sh` does this through the normal
payload SDK. If you run the engine by hand, stop `pineapplepager` yourself —
two processes must not drive the display.

---

## Manual use

```
python3 keysmith.py selftest        # no radio access
python3 keysmith.py run             # engine only
python3 ks/ui.py --headless --sample --frames 2
```

Commands are newline-delimited JSON appended to `/tmp/keysmith_cmd.jsonl`:

```
{"cmd":"scan"}
{"cmd":"plan","ap":0,"bssid":"00:0c:f6:f1:2f:fe"}
{"cmd":"attack"}
{"cmd":"stop"}
{"cmd":"disconnect"}
{"cmd":"shutdown"}
```

Environment overrides: `KEYSMITH_IFACE`, `KEYSMITH_LOOT`, `KEYSMITH_STATE`,
`KEYSMITH_CMD`, `KEYSMITH_MAX_TRIES`, `KEYSMITH_PROBE_TIMEOUT`,
`KEYSMITH_SCAN_INTERVAL`, `KEYSMITH_PAGERCTL=0`.

---

## Loot

```
/root/loot/keysmith/found.txt           one line per attack attempt
/root/loot/keysmith/keys_<bssid>.txt    every derived candidate + algorithm
/root/loot/keysmith/keysmith.log        launcher and engine log
```

`found.txt` columns: timestamp, SSID, BSSID, key (or `-`), algorithm (or `-`),
IP (or `-`), result.

---

## Tests

```
python3 -m unittest discover -s keysmith/tests -v
```

76 tests, no radio and no real network:

- all 40 RouterKeygen algorithm vectors, parsed from upstream when the source
  tree is present and embedded verbatim otherwise
- matcher rule ordering, empty-BSSID reconstruction, vendor OUI lookup
- `iw` scan parsing for WPA2, WPA3/SAE, WPA, WEP and open networks
- probe success, wrong key, driver fallback, timeout, no-supplicant
- engine phases, loot files, abort handling, command consumption
- UI rendering for every screen, selection wrap, every button command

---

## Credits and licence

The key-derivation algorithms, the SSID/BSSID matching rules and the Tele2 /
Alice / OTE lookup tables are ported from **[RouterKeygen](https://github.com/routerkeygen/routerkeygenPC)**
by **Rui Araújo** and **Luís Fonseca**, originally released under the GNU
General Public License v3. RouterKeygen itself builds on the research and code
of many others in the router-default-key community.

Because this is a derivative work, KEYSMITH is licensed **GPLv3** — see
`LICENSE`. The Pager UI, radio handling, association probing and engine are new.

`lib/libpagerctl.so` is the firmware's own display/input library, shipped
unmodified so the payload can draw. `lib/pagerctl.py` is the ctypes wrapper
from the Pager payload examples.

---

## Limitations

- Only networks whose default key is **derivable from SSID + BSSID** can be
  attacked. WPS PINs and per-device random keys are out of scope.
- WPA3/SAE-only networks will reject PSK candidates.
- The handshake probe associates with the target. It is not stealthy: the AP
  and any monitoring infrastructure will see the attempts.
- `Thomson` is CPU-bound (21.8M SHA-1). Expect minutes on the Pager; **B**
  aborts cleanly and keeps whatever was already written.
- Enterprise (802.1X) networks, 6 GHz WPA3-only APs, and routers already
  using unique keys are not supported.
