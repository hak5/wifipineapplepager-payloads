# Netstat

**Netstat** is a network utility payload for the WiFi Pineapple Pager that displays active network connections, listening ports, and routing tables.

## Features

* **Multiple View Options:** Choose from 7 different connection views
* **IPv4/IPv6 Support:** Filter connections by IP version
* **Process Information:** View which processes are using network connections
* **Automatic Logging:** All results are saved to `/root/loot/netstat/` with timestamps

## View Options

1. **All connections** - Shows all active network connections (default)
2. **Listening ports only** - Displays only ports that are listening for incoming connections
3. **TCP connections only** - Shows only TCP protocol connections
4. **UDP connections only** - Shows only UDP protocol connections
5. **All with process information** - Shows all connections with associated process IDs and names
6. **IPv4 connections only** - Filters to show only IPv4 connections
7. **IPv6 connections only** - Filters to show only IPv6 connections

## Usage

1. Launch the payload from the WiFi Pineapple Pager menu
2. Review the available view options displayed on screen
3. Press the **UP** button to continue
4. Select a view type (1-7) using the number picker
5. The netstat output will be displayed and automatically saved to the loot directory

## Output

All netstat results are saved to:
```
/root/loot/netstat/<timestamp>_netstat_<view_name>
```

The output uses numerical addresses (no DNS resolution) for faster display and consistent formatting.

## Technical Notes

* **Requirements:** The `netstat` command must be available on the device
* **Permissions:** Viewing process information (option 5) may require elevated permissions and could show some permission warnings
* **Performance:** Numerical address display (`-n` flag) is used by default to avoid DNS lookups and improve response time

## Netstat Flags Used

- `-n`: Show numerical addresses instead of resolving hosts
- `-a`: Show all connections (listening and established)
- `-l`: Show only listening ports
- `-t`: Show TCP connections only
- `-u`: Show UDP connections only
- `-p`: Show process information
- `-4`: Show IPv4 connections only
- `-6`: Show IPv6 connections only

