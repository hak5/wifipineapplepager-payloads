# Whois

**Whois** is a network utility payload for the WiFi Pineapple Pager that queries registration information for domain names and IP addresses from whois databases.

## Features

* **Domain Information:** Query registration details for domain names
* **IP Address Information:** Query network information for IP addresses
* **Automatic Installation:** Installs whois automatically if not present on the device
* **Automatic Logging:** All results are saved to `/root/loot/whois/` with timestamps (full unfiltered output)
* **Filtered Display:** Automatically filters out verbose boilerplate text (terms, ICANN notices, disclaimers) for better readability on small screens
* **Network Validation:** Ensures device has network connectivity before querying

## Usage

1. Launch the payload from the WiFi Pineapple Pager menu
2. Enter the target domain name or IP address (default: example.com)
3. The whois query will be executed and results displayed
4. Results are automatically saved to the loot directory

## Output

All whois results are saved to:
```
/root/loot/whois/<timestamp>_<target>
```

**Note:** The displayed output is filtered to remove verbose sections (terms and conditions, ICANN notices, disclaimers, etc.) for better readability on the small screen. The full unfiltered output is always saved to the loot file for complete reference.

## Technical Notes

* **Requirements:** The `whois` command will be automatically installed via opkg if not present
* **Network Requirements:** Device must be in client mode with a valid network connection to query whois servers
* **Query Types:** Supports both domain names (e.g., example.com) and IP addresses (e.g., 8.8.8.8)
* **Response Time:** Query time depends on the whois server response and may vary by domain/IP

## Example Queries

* **Domain names:** `example.com`, `google.com`, `github.com`
* **IP addresses:** `8.8.8.8`, `1.1.1.1`, `192.168.1.1`

## Information Retrieved

Whois queries typically return:
- Domain registration information (for domains)
- Registrar details
- Registration and expiration dates
- Name servers
- Contact information (if available)
- Network information (for IP addresses)
- Organization and location data

This makes it useful for reconnaissance and gathering information about domains and IP addresses during network analysis.

