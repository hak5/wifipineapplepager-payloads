# PHONEPHREAK - Phone Number OSINT

PhoneInfoga-style phone number reconnaissance for the WiFi Pineapple Pager.
Turns a phone number into an OSINT report - fully offline, with an optional
online footprint check.

> Research only numbers you are authorized to investigate. PHONEPHREAK uses
> public data and numbering-plan metadata only; you are responsible for
> applicable law and platform terms.

## What it does

For each number (TEXT_PICKER input or bulk file):

- **Validates and normalizes** to E.164 (`+CC...`, handles `00` prefixes,
  spaces, dashes, dots, parentheses)
- **Country + timezone** from the calling code (~150 calling codes)
- **Line-type detection** for common numbering plans:
  - NANP (+1): toll-free (800/833/844/855/866/877/888), premium (900),
    invalid area codes; notes that mobile/landline is not determinable
    offline because of portability
  - UK: mobile (7x), freephone (800/808), premium (9x), VoIP (56x),
    geographic
  - DE, FR, ES, IT, NL, IN, AU, JP, BR, CN, RU: mobile/landline/toll-free
    ranges
- **Format variants**: E.164, international, national, `tel:` (RFC3966)
- **Investigation link pack**: wa.me (WhatsApp), t.me (Telegram), Google /
  Bing / DuckDuckGo exact-match dorks, Truecaller, sync.me, whocalld,
  freecarrierlookup
- **Optional online check**: exact-match web footprint via DuckDuckGo HTML
  (counts public pages containing the number; needs internet and
  `python3-openssl`)
- **QR handoff**: displays a QR of the wa.me link so you can scan it with a
  phone

## Requirements

- WiFi Pineapple Pager, firmware **2.0.0-stable** or newer
- `python3-light` (payload offers to install it if missing)
- `python3-openssl` only for the optional online footprint check (the payload
  offers to install it automatically when you pick the online check)

The Pager's `opkg` has `install`/`remove` disabled, so the payload bundles
`install_pkg.py`, which installs packages via `opkg download` + Python
`tarfile` (resolving dependencies). No manual `opkg install` is needed.

## Installation

```text
/root/payloads/user/reconnaissance/phonephreak/
/mmc/root/payloads/user/reconnaissance/phonephreak/
```

Files:

```text
phonephreak/
  payload.sh       Pager UI
  phonephreak.py   analysis engine
  install_pkg.py   dependency installer (opkg install is disabled on the Pager)
  README.md        this file
```

## Usage

1. Run **PHONEPHREAK** from the payload menu and confirm the research
   notice.
2. **Lookup a number** - enter in any common format (`+1 555 123 4567`,
   `0044 7911 123456`, ...). The screen shows country, timezone, line type
   and notes; the full report saves to loot.
3. Optionally run the online footprint check, and/or show a QR for the
   WhatsApp link.
4. **Bulk from file** - point it at a text file with one number per line;
   every valid number gets a `.txt` and `.json` report.

### Loot

`/root/loot/phonephreak/`:

| File | Contents |
| --- | --- |
| `<digits>.txt` | human-readable report |
| `<digits>.json` | machine-readable report (all fields + links) |

## Command-line use

```sh
cd /root/payloads/user/reconnaissance/phonephreak

python3 phonephreak.py "+1 212 555 0147"
python3 phonephreak.py "+44 7911 123456" --online
python3 phonephreak.py --bulk /root/loot/phonephreak/numbers.txt
python3 phonephreak.py "+91 98765 43210" --json
```

## Notes and limits

- Carrier cannot be determined offline for most countries - number
  portability means prefixes no longer map to operators. The report says so
  and links carrier-lookup services instead of guessing.
- The WhatsApp/Telegram links are handoff links: opening them on a phone
  reveals whether the account exists. The payload does not scrape those
  platforms.
- The online check is a best-effort exact-match search; rate limits and
  captive portals will fail it cleanly.

## Uninstall

```sh
rm -rf /root/payloads/user/reconnaissance/phonephreak
rm -rf /root/loot/phonephreak
```

## Version

1.0.0 - initial release for Pager firmware 2.0.0-stable.

## Legal

For authorized research and education only. Not affiliated with Hak5,
PhoneInfoga, or any linked service. Users are solely responsible for
compliance with applicable laws.
