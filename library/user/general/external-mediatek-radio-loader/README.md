# External MediaTek Radio Loader/Remover

A simple, robust payload for seamlessly managing external MediaTek USB Wi-Fi adapters on the WiFi Pineapple. It handles driver loading, configuration mirroring, and automatic cleanup.

### ⚡ Usage Instructions (Important)
You must run this payload **every time you change the physical state** of the adapter.

1.  **When you PLUG IN the adapter:**
    * Connect the USB adapter.
    * **Run this payload.**
    * *Result:* The script detects the device, loads the drivers, and mirrors your internal radio settings to the external one.

2.  **When you UNPLUG the adapter:**
    * Disconnect the USB adapter.
    * **Run this payload again.**
    * *Result:* The script detects the device is missing, safely disables the external interface configuration, and restarts PineAP to prevent errors.

---

### Requirements
* **Modern MediaTek Chipsets Only:** This script targets endpoint `.3`, which is the standard for modern dual-band chips (e.g., **MT7612U**, **MT7921 / AMD RZ608**).
* **Supported Drivers:** The device must have kernel support (`mt76`). Realtek and older chips are **not supported**.

### How it Works
1.  **Detection:** Checks the external USB bus (`1-1.1`) at interface `.3`.
2.  **Mirror Mode:**
    * **If found:** It loads the driver and reads the bands from your Internal Radio (`wlan1mon`). It then applies those same bands to the External Radio (`wlan2mon`), acting as a "helper" for hopping.
    * **If missing:** It disables the external radio config and restarts services to return to a clean state.
3.  **Safety:** It **never** overrides your Internal Radio settings.

### Troubleshooting
If the script runs but errors with **"Driver Failed to Load"**, your adapter is likely unsupported or requires a driver not present in the firmware. Unlucky—it won't work.
