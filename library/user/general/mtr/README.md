# MTR (My Traceroute)

**MTR** is a network diagnostic tool that combines the functionality of the `traceroute` and `ping` programs in a single network diagnostic tool for the WiFi Pineapple Pager.

## Features

* **Combined Traceroute and Ping:** MTR continuously probes the network path to a target host
* **Real-time Statistics:** Shows packet loss, latency, and network path information
* **Automatic Installation:** Installs mtr automatically if not present on the device
* **Automatic Logging:** All results are saved to `/root/loot/mtr/` with timestamps
* **Configurable Probes:** Choose the number of probes to send to each hop

## Usage

1. Launch the payload from the WiFi Pineapple Pager menu
2. Enter the target hostname or IP address (default: 8.8.8.8)
3. Select the number of probes to send (default: 10)
4. The mtr output will be displayed and automatically saved to the loot directory

## Output

All mtr results are saved to:
```
/root/loot/mtr/<timestamp>_<target_host>
```

The output uses numerical addresses (no DNS resolution) for faster display and consistent formatting.

## Technical Notes

* **Requirements:** The `mtr` command will be automatically installed via opkg if not present
* **Network Requirements:** Device must be in client mode with a valid network connection
* **Performance:** Numerical address display (`-n` flag) is used by default to avoid DNS lookups and improve response time
* **Report Mode:** Uses `-r` flag for report mode, which outputs statistics and exits (better for automated logging)

## MTR Flags Used

- `-c <count>`: Set the number of probes to send to each hop
- `-n`: Show numerical addresses instead of resolving hosts
- `-r`: Report mode - outputs statistics and exits (non-interactive)

## Example Output

MTR combines traceroute and ping functionality, showing:
- Network path (hops) to the target
- Packet loss percentage at each hop
- Average, best, and worst latency times
- Number of packets sent and received

This makes it ideal for diagnosing network connectivity issues and identifying problematic network segments.

