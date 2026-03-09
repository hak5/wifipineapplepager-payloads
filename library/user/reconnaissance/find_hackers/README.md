# Find Hackers 
WiFi + BLE passive hacker detection payload for Hak5 Pineapple Pager. 

Designed for the **Hak5 Pineapple Pager**, capable of detecting suspicious network and Bluetooth activity and identifying nearby devices that may resemble and operate like common hacking tools (Pineapple Pager, WiFi Pineapple, Flipper Zero, stingray hunter).

> **For authorized security research, red-teaming, and situational awareness only.**  
> You are responsible for complying with all laws in your region.


## Features

| Feature | Description |
|--------|-------------|
| **WiFi SSID Detection** | Uses `_pineap RECON` to search for APs using SSIDs commonly found with Hak5 devices and stingray hunter hotspot |
| **WiFi Attack Detection** | Searches for spoofing APs and potential evil twins |
| **BLE Detection** | Uses `lescan` for BT filtering |
| **Continuous Monitor Mode** | Cycles WiFi → BLE → sleep delay — loops forever |
| **Logging** | Each hit is archived with timestamps |
| **SSID Pool Loot** | Logs SSID pool of spoofing APs |


## Functionality

WiFi SSID Detection
- Hak5 WiFi Pineapple Pager
    - Search for ssids with case insensitive substring "pager"
    - Default OPN ssid = "pager_open" "pager-open"
    - Alerts? - Yes.
    - False positives - Normal APs may have ssid containing "pager". Investigate the network. 

- Hak5 WiFi Pineapple
    - Search for ssids with case insensitive substring "pineapple"
    - Default setup ssid = "Pineapple_XXXX" where XXXX is last 4 characters of the devices MAC
    - Alerts? - Yes.
    - False positives - Normal APs may have ssid containing "pineapple". Investigate the network. 

- Orbic RC400L device
    - Search for ssids with case insensitive substring "RC400L". Common hotspot used with Rayhunter software (Stingray hunter). 
    - Alerts? - Yes.
    - False positives - Only searching for a hotspot model, there is no way to know if the rayhunter software is installed without getting network access. Context matters. Get a hit at a protest? Likely a stingray hunter device. At an airport? Likely a normal hotspot.

WiFi Attacks Detection
- Spoofing APs / Karma Attack
    - Search for APs rapidly changing their SSID (Default is 5 different SSIDs)
    - Alerts? - Yes.
    - False positives - A normal AP may change its name but if it does this multiple times quickly, it is suspicious behavior.

- Evil Twin APs
    - Search for APs with the same SSID but different MAC OUIs (different manufacturer). If more than 2 devices with different OUIs, ignore. Hard to tell which MAC may be suspicious.
    - Alerts? - No. Too many false positives. Will log hits.
    - Ignore OPEN APs, these may still be evil twins but should be caught.
    - False positives - It is hard to detect an evil twin unless you are familiar with the network and know which MACs are valid and how many devices there are.
    - False negatives - Hard to detect. Can update MAC address to look like it is the same equipment as valid AP.

BT Detection
- Flipper Zero
    - Search for Bluetooth device names with case insensitive substring "flipper" and for MAC with OUI equal to "0C:FA:22" for Flipper Devices Inc manufacturer.
    - Alerts? - Yes.
    - False positives - Normal Bluetooth devices may have name containing "flipper". Investigate the device.


## Output Files


- Log location: (appends to file on each run)
    ```
    /root/loot/find_hackers/collector.log
    ```

    *Timestamps are in Epoch*

- JSON file containing APs from recon (rewritten on each run)
    ```
    /root/loot/find_hackers/all_aps.json
    ```


- Karma attack AP's ssid pool
    ```
    /root/loot/find_hackers/<EPOCH_DATETIME>_<MAC>_ssid_pool.txt
    ```

    *If an AP is found to be spoofing SSID names like a Karma attack, a file will be created of all of the SSID names. This can contain SSIDs pulled in from a Pineapple Pager's SSID pool and could potentially be used to track a hacker's movements using
    [Wigle](https://wigle.net/).*


## Configuration

Static variables at top of file and can be updated.
```bash
# ---- FILES ----
LOOT_DIR="/root/loot/find_hackers"
RECON_OUTPUT_JSON="/root/loot/find_hackers/all_aps.json"
RECON_DB="/root/recon/recon.db"

# ---- BLE ----
BLE_IFACE="hci0"
BLE_SCAN_SECONDS=30
BT_TIMEOUT="20s"
FLIPPER_OUI="0C:FA:22"
FLIPPER_NAME="flipper"

# ---- WIFI ----
# Min amount an AP needs to change it's SSID to qualify as spoofing
MIN_SPOOFING_COUNT=5
SLEEP_BETWEEN_SCANS=15 # Time to restart wifi and bluetooth searches
```

Want to customize search? Comment out lines at the bottom of payload.
EX: Not searching for evil twins

```bash
while true; do
    # Get all APs and save to a JSON file
    get_aps_json

    # Search for hacking devices
    find_pagers
    find_pineapples
    find_rayhunters
    find_spoofing_aps
    # find_evil_twins
    find_flippers

    # Wait until next scan
    sleep "$SLEEP_BETWEEN_SCANS"
    LOG "\n\n"
done
```

## TODO
- Add GPS coordinates in logs when hits are found
- Search for SSIDs on restricted channels