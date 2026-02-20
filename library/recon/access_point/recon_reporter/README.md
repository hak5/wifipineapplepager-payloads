# Recon Reporter

Generate structured recon reports (CSV + JSON) for selected APs and clients from the Recon UI.

## Description

Recon Reporter is a recon payload that captures the selected AP/client metadata exposed by the Pager and writes structured output to local storage. It is designed for authorized testing only and does not perform active attacks.

## Features

- Outputs JSON per run for easy parsing
- Appends AP and client rows to CSV summaries
- Captures SSID activity fields when provided (beaconed/probed/responded)
- Per-target folders with latest report link
- Change detection vs previous run with optional alerts
- Optional environment dump for troubleshooting
- Works with AP selection, client selection, or both
- Interactive configuration with saved settings
- Sampling mode (multiple snapshots over time)

## Requirements

- WiFi Pineapple Pager (Recon payload support)
- Firmware that exports recon selection env variables

## Installation

Copy the payload directory to your Pager:

```bash
scp -r library/recon/access_point/recon_reporter root@172.16.42.1:/root/payloads/recon/access_point/
chmod +x /root/payloads/recon/access_point/recon_reporter/payload
```

## Configuration

Edit `/root/payloads/recon/access_point/recon_reporter/payload`:

- `INTERACTIVE_CONFIG`: Prompt for runtime options
- `SAVE_CONFIG`: Persist options via `PAYLOAD_SET_CONFIG`
- `OUTPUT_DIR`: Where reports are stored
- `PER_TARGET_DIR`: Store output under `OUTPUT_DIR/<target_id>/`
- `ENABLE_JSON`: Toggle per-run JSON output
- `ENABLE_CSV`: Toggle CSV summary output
- `INCLUDE_ENV_DUMP`: Save raw `_RECON_*` vars for debugging
- `ENABLE_DIFF`: Compare against last run for that target
- `ALERT_ON_CHANGES`: Show alert when changes detected
- `IGNORE_DIFF_KEYS`: Comma list of fields to ignore in diff
- `CLEANUP_DAYS`: Auto-delete old JSON/ENV/changes (0 = disabled)
- `SAMPLE_COUNT`: Number of samples per run
- `SAMPLE_INTERVAL`: Seconds between samples

## Usage

1. Start Recon in the Pager UI.
2. Select an AP or client.
3. Run **Recon Reporter** from the Recon payloads list.
4. Inspect output in the configured `OUTPUT_DIR`.

## Output

- JSON report: `YYYYMMDD-HHMMSS_<target>.json`
- Env dump: `YYYYMMDD-HHMMSS_<target>.env`
- Change report: `YYYYMMDD-HHMMSS_<target>.changes.txt`
- CSV summaries:
  - `ap_summary.csv`
  - `client_summary.csv`

## Troubleshooting

- If reports are empty, check the env dump to see which `_RECON_*` variables your firmware provides.
- Ensure the payload is launched from the Recon UI (not the general payload list).
- Sampling uses the current recon selection context; keep Recon running to capture updated metrics.

## Legal

Use only on networks and devices you own or have explicit authorization to test.
