# External MediaTek Radio Loader/Remover

A simple, robust payload for seamlessly managing external MediaTek USB Wi-Fi adapters on the WiFi Pineapple. It handles driver loading, configuration mirroring, and automatic cleanup.

Works with multiple radios via a external USB hub, tested with 2 external radios at once

## THIS PAYLOAD IS NOT REQUIRED FOR THE MK7AC ADAPTER. IT IS ALREADY PLUG AND PLAY

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
* **Modern MediaTek Chipsets Only:** 
* **Supported Drivers:** The device must have kernel support (`mt76`). Realtek and older chips are **not supported**.

### How it Works
1.  **Detection:** Checks the external USB bus and all interfaces for vendor specific "ff" interfaces.
2.  **Mirror Mode:**
    * **If found:** It loads the driver and reads the bands from your Internal Radio (`wlan1mon`). It then applies those same bands to the External Radio (`wlan2mon`), acting as a "helper" for hopping.
    * **If missing:** It disables the external radio config and restarts services to return to a clean state.
3.  **Safety:** It **never** overrides your Internal Radio settings.

### Troubleshooting
If the script runs but errors with **"Driver Failed to Load"**, your adapter is likely unsupported or requires a driver not present in the firmware. Unlucky—it won't work.
