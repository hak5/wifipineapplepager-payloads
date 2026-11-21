# DEFCON Sentry — Repeat-Offense Deauth Alert

Auto-fires on `deauth_flood_detected`. Instead of buzzing on every frame, it
warns **only when the same attacker keeps flooding**.

## Tuning (edit the CONFIG block in `payload.sh`)
- `REPEAT_THRESHOLD` (default 3) — hits from one offender before warning.
- `WINDOW_SECONDS` (default 120) — window those hits must fall within.
- `COOLDOWN_SECONDS` (default 300) — quiet time after a warning for that offender.
- `KEY_MODE` — `source` (attacker MAC), `source_ap` (attacker+AP, default),
  `source_client` (attacker+victim).
- `WATCH_MACS` — comma-separated MACs that are *yours*; a flood touching one
  warns instantly, bypassing the threshold.

## Output
- `STATE_DIR/events.log` — every deauth event, even when silent.
- `STATE_DIR/deauth_state.csv` — per-offender counters.

## Arming
Ensure this directory is named `defcon_sentry` (no `DISABLED.` prefix), or
enable it in the Pager's Alerts menu. Requires PineAP recon/listening active.
