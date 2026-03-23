# Route

**Route** is a network utility payload for the WiFi Pineapple Pager that displays routing table information, showing how network traffic is directed through the system.

## Features

* **Multiple View Options:** Choose from 5 different route views
* **IPv4/IPv6 Support:** Filter routes by IP version
* **Interface Filtering:** View routes for a specific network interface
* **Automatic Installation:** Installs route utilities automatically if not present on the device
* **Automatic Logging:** All results are saved to `/root/loot/route/` with timestamps
* **Modern Command Support:** Uses `ip route` (preferred) with fallback to `route` command

## View Options

1. **All routes** - Shows all routing table entries (default)
2. **IPv4 routes only** - Displays only IPv4 routing entries
3. **IPv6 routes only** - Displays only IPv6 routing entries
4. **Default route only** - Shows only the default gateway route
5. **Routes for specific interface** - Filters routes by network interface name

## Usage

1. Launch the payload from the WiFi Pineapple Pager menu
2. Review the available view options displayed on screen
3. Press the **UP** button to continue
4. Select a view type (1-5) using the number picker
5. If selecting interface view (option 5), enter the interface name when prompted
6. The route output will be displayed and automatically saved to the loot directory

## Output

All route results are saved to:
```
/root/loot/route/<timestamp>_route_<view_name>
```

The output uses numerical addresses (no DNS resolution) for faster display and consistent formatting.

## Technical Notes

* **Requirements:** The `ip` command (from iproute2) or `route` command (from net-tools) will be automatically installed via opkg if not present
* **Command Preference:** The payload prefers the modern `ip route` command but will fall back to the traditional `route` command if needed
* **Performance:** Numerical address display is used by default to avoid DNS lookups and improve response time
* **Interface Names:** Common interface names include `eth0`, `wlan0`, `br-lan`, etc.

## Route Information Displayed

The routing table typically shows:
- **Destination:** Network destination or host
- **Gateway:** Gateway address used to reach the destination
- **Interface:** Network interface used for the route
- **Metric:** Route priority (lower is preferred)
- **Flags:** Route characteristics (U=up, G=gateway, H=host, etc.)

This information is essential for understanding network topology, troubleshooting connectivity issues, and analyzing network routing behavior.

