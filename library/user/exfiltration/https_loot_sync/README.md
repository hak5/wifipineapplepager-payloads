# HTTPS Loot Sync

Packages the entire loot directory into a timestamped archive and uploads it to a controlled HTTPS endpoint with token-based authentication.

## Options
| Variable | Default | Description |
| --- | --- | --- |
| `LOOT_DIR` | `/root/loot` | Source directory to exfiltrate. |
| `OUTPUT_DIR` | `/root/loot/https-sync` | Where archives and logs are stored locally. |
| `SYNC_ENDPOINT` | `https://example.com/upload` | HTTPS endpoint receiving the archive. |
| `AUTH_TOKEN` | `REPLACE_ME` | Bearer token presented in the `Authorization` header. |
| `CA_CERT` | `` | Optional CA bundle or pin for mutual TLS validation. |

## Usage
1. Host your own HTTPS endpoint to receive `multipart/form-data` uploads. Populate `AUTH_TOKEN` with your secret.
2. Set `SYNC_ENDPOINT` to your collector URL. Optionally supply `CA_CERT` if you use a private CA.
3. Run the payload; it creates `loot-<timestamp>.tar.gz`, calculates SHA256, and posts both the file and checksum. Server responses are stored in `upload.response` alongside the log.
