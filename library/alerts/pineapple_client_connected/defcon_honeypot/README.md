# DEFCON Honeypot — Decoy AP Connect Alert

Auto-fires on `pineapple_client_connected`. Warns when something joins the
**decoy AP you run on purpose**, so an unexpected connection gets your attention.

## Operator setup (required)
Run an **open** AP in PineAP with a **neutral SSID that does NOT impersonate a
real network** (e.g. `pineapple_decoy`, not a nearby coffee-shop's name).
No karma / association attack — just a plain open AP clients may choose to join.

## Tuning (edit CONFIG in `payload.sh`)
- `COOLDOWN_SECONDS` (default 600) — quiet time per client after a warning.

## Output
- `STATE_DIR/honeypot.csv` — every connect: `ts,client,ap,ssid,randomized`.

## Arming
Name the directory `defcon_honeypot` (no `DISABLED.` prefix) or enable it in the
Alerts menu.
