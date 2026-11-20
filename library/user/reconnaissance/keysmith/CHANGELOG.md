# Changelog

## 1.0.0

First release.

### Attack

- Reads beacon data only (SSID, BSSID, channel, band, security) and derives
  the factory-default WPA key, then proves it with a real 4-way handshake and
  associates. No handshake capture, no wordlist, no deauth.
- Candidate probing keys off `4-Way Handshake failed - pre-shared key may be
  incorrect`, so a wrong key costs about a second rather than a full
  association timeout.
- After a verified key, `wpa_supplicant` is daemonized and `udhcpc` requests a
  lease through a hook that installs neither a default route nor
  `/etc/resolv.conf` — the Pager's management uplink keeps working.
- Derived-only mode when `wpa_supplicant` is absent: the key is still shown,
  clearly marked unverified.

### Algorithms

- 42 RouterKeygen generators ported, including the vendor-specific MAC
  reconstruction for beacons that hide the BSSID (Sitecom, Eircom, Pirelli,
  Verizon, Thomson).
- `Upc07` is solved algebraically instead of brute-forcing 10,000 candidates
  per prefix, making Technicolor boxes usable on a Pager.
- Thomson's ASCII-to-hex quirk is preserved (upstream hashes `"LO4"` as
  `4C4F34`), and Alice's exact 256-character alphabet is used.
- Corrected `Bssid` rule parameters, `InterCable` carry handling, `TeleTu`
  table lookup and `OteHuawei` series gate against upstream vectors.
- Not ported and documented as gaps: `Telsey` (Jenkins lookup3) and
  `Upc07Ubee` (firmware-specific substitution table).

### Device integration

- Only phy1 is touched; phy0 is the management uplink and is refused even
  when named explicitly.
- Engine and UI are separate processes over a state file and a command file,
  so a crashed UI cannot leave the radio half-configured and a slow derivation
  cannot freeze the display.
- 480x222 UI: TARGETS, PLAN, DERIVE, HANDSHAKE, RESULT, ERROR. **B** aborts a
  derivation or a probe run at any point.
- Self-locating payload folder; category directory name does not matter.
- LOG fallback when `pagerctl` is unavailable, plus `install_pkg.py` for
  firmware 2.x where `opkg install` is disabled.

### Tests

- 74 hardware-free tests: all 40 upstream RouterKeygen vectors, matcher rule
  ordering and empty-BSSID reconstruction, `iw` parsing for WPA2/WPA3/WPA/WEP/
  open, probe success/wrong/timeout/driver-fallback, engine phases and loot,
  every UI screen and button path.

### Licence

- GPLv3. Algorithms, matching rules and lookup tables are ported from
  RouterKeygen by Rui Araújo and Luís Fonseca.
