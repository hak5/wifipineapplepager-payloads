OSINT-U-Asked

Lightweight username reconnaissance payload powered by a JSON site database.

Author: Hackazillarex
Version: 1.0
Credits: Sherlock-Project (data.json inspiration & structure)

- Overview -

OSINT-U-Asked is a lightweight Bash-based OSINT payload designed for username reconnaissance across multiple platforms. It leverages a structured data.json file (inspired by the Sherlock Project) to dynamically generate and test profile URLs.

This payload is designed for controlled environments and authorized OSINT/security testing operations.

- Features -

Username reconnaissance across multiple platforms

JSON-driven architecture (easy to expand)

Multiple detection methods:

HTTP status code analysis

Error message fingerprinting

Redirect URL comparison

Automatic jq dependency installation (OpenWRT/opkg environments)

Organized session-based loot storage

Clean logging and result summary

Lightweight & portable Bash implementation

- How It Works -

Prompts user for a username via TEXT_PICKER

Loads platform definitions from data.json

Iterates through each platform:

Generates target URL

Performs detection based on defined errorType

- Logs findings -

Saves discovered accounts into a session-based loot directory

- Detection Methods Supported -

1. status_code

Checks HTTP response codes (e.g., 404, 400, 403) to determine existence.

2. message

Searches for a known error string within the response body.

3. response_url

Follows redirects and compares final URL against known failure URL.

- Directory Structure -

/root/
 ├── payloads/user/reconnaissance/OSINT-U-Asked/
 │     ├── OSINT-U-Asked.sh
 │     └── data.json
 │
 └── loot/osint/
       └── session_YYYYMMDD_HHMMSS/
             └── found_accounts.txt

Each execution creates a new timestamped session directory.

- Ethical & Legal Notice -

This tool is intended strictly for:

Authorized penetration testing

Open Source Intelligence investigations

Security research

Defensive operations

Unauthorized reconnaissance against systems or individuals may violate local, national, or international laws.

Use responsibly.




