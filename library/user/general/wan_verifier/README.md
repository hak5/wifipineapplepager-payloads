# WAN Verifier

**WAN Verifier** is a lightweight utility for the WiFi Pineapple Pager. It allows you to quickly verify your external network footprint and compare it against a known baseline.

## Features

*   **Instant Verification:** Displays your Public IP, ISP, and geographic location.
*   **Baseline Comparison:** Checks if your current IP matches a stored "Baseline" IP (e.g., your home or lab connection).
*   **Safety Status:** Detects if you are exposed on a known "Home" network.
*   **API Redundancy:** Automatically falls back to secondary providers if the primary API is unreachable.
*   **Caching:** Caches results for 60 seconds to save data and battery on repeated checks.
*   **Developer API:** Can be called by other payloads to perform silent checks.

## Usage

1.  Connect the WiFi Pineapple to a network.
2.  Navigate to **WAN Verifier** in the payload menu.
3.  Launch the payload.
4.  Review your status:
    *   **IP:** Your visible public IP.
    *   **ISP:** The provider carrying your traffic (e.g., "Mullvad", "Comcast").
    *   **Status:** 
        *   `NO MATCH`: IP differs from your stored baseline.
        *   `MATCH`: You are currently on your stored baseline IP.

## Controls

*   **[A] Refresh:** Force a new lookup (bypasses cache).
*   **[<] Save as Baseline:** Save the current IP as your known baseline.
*   **[B] Exit:** Quit the application.

## Developer API

Other payloads can use `WAN Verifier` as a library to perform checks before running operations.

### Modes
*   **Check Mode:** `./payload.sh --check`
    *   Output: `NO_MATCH: <IP>` or `MATCH: <IP>`
    *   Exit Code: `0` (No Match), `1` (Match), `2` (No Internet), `3` (API Error)
*   **Silent Mode:** `./payload.sh --silent`
    *   Output: None
    *   Exit Code: Same as above.

### Example Usage
```bash
# Example: Only run if we are NOT on the baseline network
if /path/to/wan_verifier/payload.sh --silent; then
    LOG "Identity is masked (No Match). Proceeding..."
    # ... logic ...
else
    LOG "ABORT: Matches Baseline or No Connection!"
    exit 1
fi
```

## Requirements

*   Internet connection on the WiFi Pineapple.
*   `curl` and `jq` installed on the system.

## Configuration

The script uses **`http://ip-api.com/json`** as the primary provider and **`http://ipinfo.io/json`** as a fallback. You can modify these variables at the top of `payload.sh` if you prefer different services.
