**Client Wifi Picker**

**Overview**
This payload quickly switches the WiFi Pineapple Pager client WiFi between saved
networks you have already entered, so you do not have to type SSIDs and passwords
every time. It prompts the user, applies the chosen network settings via UCI, and
reloads wireless.

**What it does**
- Presents a menu of configured SSIDs via Pager dialogs
- Prompts for a selection and confirmation
- Updates the client mode (sta) wireless profile with the selected SSID,
  encryption type, and password
- Reloads WiFi to apply changes
- Writes status updates to the Pager log throughout the process

**Configuration**
Profiles are stored using the Pager CONFIG commands:
`PAYLOAD_SET_CONFIG`, `PAYLOAD_GET_CONFIG`, and `PAYLOAD_DEL_CONFIG`. These values
persist across firmware upgrades.

Run the `switch_client_wifi_configuration` payload to create, view, or update profiles.
The configuration payload saves profiles under the payload name `switch_client_wifi`.
If you want to add or delete networks later, run the configuration payload again.

**Notes**
- Encryption choices: Open, WPA2 PSK, WPA2 PSK/WPA3 SAE, WPA3 SAE (personal).
- The script targets the client interface section `wlan0cli`.

**Usage**
1) Copy both payload folders to the Pager.
2) Run `switch_client_wifi_configuration` to enter SSIDs, encryption types, and passwords.
3) Run `switch_client_wifi` and select the desired network.

**Files**
- `payload.sh`: Main payload script for the Pager
