# 📡 AntennaCheka

**WiFi Pineapple Pager – Visual Antenna Benchmark Payload**

AntennaCheka is a **visual benchmarking payload** for the **Hak5 WiFi Pineapple Pager** that compares the **RSSI performance of the Pager’s internal antennas against an external USB-mounted antenna**.

It performs multiple packet captures across configurable channels, calculates average signal strength, and clearly reports **which antenna performs better**.

---

## 🔧 What AntennaCheka Does

* Automatically detects:

  * Pager internal antennas (`wlan0*`, `wlan1*`)
  * External USB antennas (`wlan2*`, `wlan_usb_*`, etc)
* Runs **multiple capture passes** for consistency
* Captures **RSSI and packet counts**
* Calculates:

  * Average RSSI per antenna
  * Total packets seen
  * RSSI difference (dB)
* Displays results on the Pager screen
* Saves results to `/root/loot/antennacheka/`

---

## 📦 Requirements

* Hak5 **WiFi Pineapple Pager**
* Firmware supporting monitor mode
* External USB Wi-Fi adapter with:

  * Supported chipset
  * Drivers already present on the Pager
* No additional packages required (uses built-ins)

---

## 📶 Understanding Pager Antennas (Important)

On the WiFi Pineapple Pager:

| Interface                        | Meaning                  |
| -------------------------------- | ------------------------ |
| `wlan0*`                         | Internal antenna (Pager) |
| `wlan1*`                         | Internal antenna (Pager) |
| `wlan2*`, `wlan3*`, `wlan_usb_*` | **External USB antenna** |

⚠️ **Anything other than wlan0 or wlan1 is treated as USB**
This is critical to correct detection.

---

## 🛠 Pre-Flight Checks (Recommended)

Before running AntennaCheka, confirm your USB antenna is detected and usable.

### 1️⃣ Check USB device is detected

```bash
lsusb
```

Look for a chipset entry such as:

* MediaTek
* Realtek
* Ralink

Example:

```
Bus 001 Device 008: ID 0e8d:7612 MediaTek Inc. Wireless
```

If it does **not** appear here, the Pager cannot see the device.

---

### 2️⃣ Check wireless interfaces

```bash
iw dev
```

You should see:

* `wlan0*` and/or `wlan1*` (internal)
* Possibly a new interface for USB

---

### 3️⃣ Check available PHYs

```bash
ls /sys/class/ieee80211
```

Example output:

```
phy0  phy1  phy5
```

* `phy0`, `phy1` → internal radios
* `phyX` (higher number) → USB radio

---

### 4️⃣ Manually create a monitor interface (if needed)

If your USB PHY exists but no monitor interface is present:

```bash
iw phy phyX interface add wlan2mon type monitor
ip link set wlan2mon up
```

Replace `phyX` with the correct PHY number (e.g. `phy5`).

Confirm with:

```bash
iw dev
```

---

## ▶️ Running AntennaCheka

Once the payload is installed:

1. Plug in your USB antenna
2. Run the payload from the Pager UI
3. The payload will:

   * Auto-detect antennas
   * Perform multiple capture runs
   * Cycle through configured channels
   * Display results when finished

---

## ⚙️ Configuration Options

Inside the script you can adjust:

```bash
CHANNELS=(1 6 11 36)   # Channels to test
PKTS=50               # Packets per capture
RUNS=3                # Number of full test runs
```

### Changing channels

Edit the `CHANNELS` array to suit your environment:

* 2.4 GHz: `1 6 11`
* 5 GHz: `36 40 44 48`
* Mixed: `1 6 11 36`

---

## 📊 Output & Results

At completion, AntennaCheka displays:

* Average RSSI per antenna
* Total packets captured
* RSSI difference (dB)
* **Best performing antenna**

Example:

```
Inbuilt avg RSSI: -63.2 dBm
USB avg RSSI:     -58.7 dBm
Best antenna: USB
RSSI difference: 4.5 dB
```

---

## 💾 Saved Results

Results are saved automatically to:

```bash
/root/loot/antennacheka/
```

Each run creates a timestamped file:

```
result_20260121_184233.txt
```

---

## 🧪 Troubleshooting

### USB antenna shows in `lsusb` but not `iw dev`

* Driver may not be loaded
* Firmware blob may be missing
* Try rebooting with antenna plugged in

### USB detected but no packets captured

* Wrong channel band
* Antenna does not support monitor mode
* Channel not active in your area

### Antennas detected “backwards”

* Ensure you are **not renaming wlan0/wlan1**
* AntennaCheka assumes:

  * `wlan0*`, `wlan1*` = internal
  * everything else = USB

---

## 🧠 Notes

* RSSI values are **relative**, not absolute
* Best results come from:

  * Busy RF environments
  * Repeating tests
  * Comparing antennas on the same band
* Packet count matters — more packets = more reliable average

---

## 🧑‍💻 Author

Custom payload developed for the **Hak5 WiFi Pineapple Pager**
Built for experimentation, learning, and antenna performance validation.

---


