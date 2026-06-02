# 👓 Smart Glasses Detector — WiFi Pineapple Pager Payload
> **⚠️ EDUCATIONAL PURPOSES ONLY**
> This tool is provided strictly for educational use, privacy awareness research, and authorized security testing. Always ensure you have proper authorization before scanning any environment. Unauthorized surveillance detection or interference with wireless devices may violate local laws. The author assumes no liability for misuse.

---

## How It Works

Most smart glasses (Meta Ray-Ban, Snap Spectacles, Bose Frames, etc.) communicate primarily over Bluetooth Low Energy rather than WiFi. Every BLE device broadcasts **advertising frames** that contain a **manufacturer company ID** — a unique identifier assigned by the Bluetooth SIG that cannot be randomized or spoofed.

This payload uses the Pineapple Pager's built-in Bluetooth scan. 



---

## Features

- **Passive BLE scanning** — listens to advertising frames without connecting to any device
- **Dual detection** — matches both company IDs (`btmon`) and device names (`hcitool lescan`)
- **RSSI signal strength** — estimates proximity to detected glasses (<1m, 1–3m, 3–8m, 8–15m, >15m)
- **Real-time LED feedback** — DPAD pulsates cyan during scan, flashes red on detection
- **Haptic alerts** — vibration on each detection
- **120-second scan** — fixed duration with wall-clock deadline for reliable timing
- **Auto-install** — installs `bluez-utils` via `opkg` on first run if not present
- **Privacy-focused** — no MAC addresses or identifying data are logged or saved
- **Clean exit** — all temp files removed and LEDs turned off on completion

---

## Installation

### Prerequisites

- Hak5 WiFi Pineapple Pager with firmware 1.0.x or later
- Internet connection on first run (to install `bluez-utils` if not already present)

### Steps

1. Connect to your Pineapple Pager via SSH:
   ```
   ssh root@172.16.42.1
   ```

2. Create the payload directory:
   ```
   mkdir -p /root/payloads/user/reconnaissance/Looking Glass
   ```

3. Copy the payload file to the Pager. From your computer:
   ```
   scp payload.sh root@172.16.42.1:/root/payloads/userreconnaissance/Looking_Glass/payload.sh
   ```

4. The payload will now appear in the Pager's payload menu under **Reconnaissance → Looking Glass**.

---

## Usage

1. Navigate to **Payloads → Reconnaissance → Looking Glass on the Pager
2. Press the center button to launch
3. The DPAD LEDs will pulsate cyan while scanning
4. When smart glasses are detected:
   - LEDs flash red rapidly (3 pulses)
   - Pager vibrates
   - LOG shows the brand name and estimated distance
5. After 120 seconds the scan ends and a summary is displayed



## Troubleshooting

| Issue | Solution |
|---|---|
| "bluez-utils install failed" | Connect the Pager to the internet via `WIFI_CONNECT` and retry |
| "No Bluetooth adapter" | Reboot the Pager — the BT radio occasionally needs a cold start |
| "BT adapter won't start" | Reboot the Pager and run the payload again |
| "BLE scan failed" | Another process may be using the BT adapter — reboot and retry |
| No detections | Ensure the glasses are powered on (not in the case) and within ~10m |
| LEDs stay on after exit | Run `DPADLED off` from an SSH session |


## License

This project is released under the [MIT License](LICENSE).

---

## Disclaimer

This tool is intended **solely for educational purposes and authorized security research**. It passively listens to publicly broadcast BLE advertising frames — it does not connect to, interfere with, or extract data from any device.

The detection of smart glasses in a given area does not imply that recording or surveillance is occurring. Smart glasses broadcast BLE advertisements whenever they are powered on, regardless of whether cameras or microphones are active.

**Use responsibly. Know your local laws. Get authorization before scanning.**
