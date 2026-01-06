## Client Wifi Picker Configuration

### Overview
This payload stores WiFi profiles for the Client Wifi Picker using the Pager CONFIG
commands. It prompts for SSIDs, encryption types, and passwords, then saves them
as persistent options under the payload name `switch_client_wifi`.

### What it does
- Prompts for SSID, encryption type, and password
- Supports Open, WPA2 PSK, WPA2 PSK/WPA3 SAE, and WPA3 SAE (personal)
- Saves profiles using `PAYLOAD_SET_CONFIG`
- Allows delete-all, delete-one, add-new, and view options for existing profiles

### Usage
1) Copy the payload folder to the Pager.
2) Run the configuration payload.
3) Add one or more networks when prompted.
4) Run the Client Wifi Picker payload to connect.

### Files
- `payload.sh`: Configuration payload script
