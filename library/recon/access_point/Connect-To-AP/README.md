# Connect-To-AP

## Description
Connect to a selected 2.4GHz access point directly from the Recon interface with intelligent credential management. This payload streamlines WiFi network connections by remembering passwords for previously connected networks.

## Features
- **2.4GHz Network Support**: Connects via wlan0cli interface to 2.4GHz networks (channels 1-14)
- **Hidden SSID Support**: Prompts for SSID name when connecting to hidden networks
- **Credential Memory**: Saves and recalls passwords for previously connected networks
- **Encryption Support**: Handles Open, WPA, WPA2, and WPA3 (SAE) networks
- **IP Assignment Monitoring**: Waits for DHCP to assign an IP address with helpful status messages
- **MetaPayload Integration**: Optionally updates global TARGET_SUBNET variable when connected

## Usage
1. Run a Recon scan to discover access points
2. Select a 2.4GHz access point from the Recon results
3. Launch the "Connect-To-AP" payload
4. Enter the network password (or use saved credentials)
5. Optionally save the password for future connections
6. Wait for IP address assignment

## Notes
- Only 2.4GHz networks are supported (wlan0cli limitation)
- Hidden networks require manual SSID entry
- Passwords are stored in plain text in the remembered APs file
- MetaPayload integration is optional but recommended for automated subnet targeting

## Author
spencershepard (GRIMM)

