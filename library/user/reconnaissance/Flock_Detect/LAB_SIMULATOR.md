# Flock Lab Simulator — Setup Guide

A MicroPython payload for the **Arduino Nano ESP32** that emulates Flock Safety surveillance device signatures (BLE + WiFi) for testing detection tools like [Flock-You](https://github.com/colonelpanichacks/flock-you) in a pen test lab.

---

## What It Does

- Broadcasts BLE advertisements and WiFi SSIDs that mimic real Flock Safety hardware
- Rotates through **4 device types** every 20 seconds: FS Ext Battery, Penguin, Pigvision, and Flock camera
- Each rotation generates a **unique MAC address** from confirmed Lite-On Technology OUI prefixes
- Includes the **XUNTONG (0x09C8) manufacturer ID** in BLE advertising data — the same signature real devices use
- The **onboard RGB LED** changes color to match the Flock-You detector's color key:
  - 🟡 **Yellow** — FS Ext Battery
  - 🟢 **Green** — Penguin
  - 🟣 **Magenta** — Pigvision
  - 🔵 **Cyan** — Other Flock

---

## What You Need

| Item | Notes |
|------|-------|
| **Arduino Nano ESP32** | The ESP32-S3 variant (ABX00083). Not the original Nano or Nano 33. |
| **USB-C cable** | Data-capable. Some cheap cables are charge-only and won't work. |
| **Computer** | Windows, Mac, or Linux. |

That's it. No external LEDs, no wiring, no breadboard.

---

## Step 1: Install MicroPython on the Nano ESP32

The Nano ESP32 ships with Arduino firmware. You need to replace it with MicroPython.

### 1a. Download MicroPython

Go to: **https://micropython.org/download/ARDUINO_NANO_ESP32/**

Download the latest `.bin` file (look for the one marked **v1.27.0** or newer).

### 1b. Put the Board in Bootloader Mode

1. Plug the Nano ESP32 into your computer via USB-C
2. **Double-tap** the white **RST** (reset) button on the board
3. The green LED should start pulsing — this means it's in bootloader (DFU) mode
4. A new serial port or DFU device should appear on your computer

### 1c. Flash MicroPython

**Option A — Using esptool (recommended):**

Install esptool if you don't have it:
```
pip install esptool
```

Erase the flash first:
```
esptool.py --chip esp32s3 --port /dev/ttyACM0 erase_flash
```

Then flash MicroPython:
```
esptool.py --chip esp32s3 --port /dev/ttyACM0 write_flash -z 0 ARDUINO_NANO_ESP32-20251209-v1.27.0.bin
```

> **Windows users:** Replace `/dev/ttyACM0` with your COM port (e.g., `COM3`). Check Device Manager under "Ports" to find it.

> **Mac users:** The port will look like `/dev/cu.usbmodem14101` or similar. Run `ls /dev/cu.*` to find it.

**Option B — Using Thonny (beginner-friendly):**

1. Download and install [Thonny](https://thonny.org/)
2. Go to **Tools → Options → Interpreter**
3. Select **MicroPython (ESP32-S3)**
4. Click **Install or update MicroPython**
5. Select the `.bin` file you downloaded
6. Click **Install**

### 1d. Verify It Worked

After flashing, press the RST button once. Open a serial terminal (Thonny, PuTTY, or `screen`) at **115200 baud**. You should see:

```
MicroPython v1.27.0 on 2025-12-09; Arduino Nano ESP32 with ESP32S3
Type "help()" for more information.
>>>
```

If you see `>>>`, MicroPython is running.

---

## Step 2: Upload the Script

You need to get `flock_lab_sim.py` onto the board and rename it so it runs automatically at boot.

### Option A — Using Thonny (easiest)

1. Open Thonny and connect to the board
2. Go to **File → Open** and select `flock_lab_sim.py` from your computer
3. Go to **File → Save As**
4. When asked where, choose **MicroPython device**
5. Save it as **`main.py`** — this makes it auto-run on boot

### Option B — Using mpremote (command line)

Install mpremote:
```
pip install mpremote
```

Upload the script as `main.py`:
```
mpremote cp flock_lab_sim.py :main.py
```

### Option C — Using ampy

Install ampy:
```
pip install adafruit-ampy
```

Upload:
```
ampy --port /dev/ttyACM0 put flock_lab_sim.py /main.py
```

---

## Step 3: Run It

After uploading as `main.py`, press the **RST** button on the board. The script starts automatically.

You should see:
```
Flock Lab Simulator - Identity Rotation + LED
Credits: O'Horo, ColonelPanic, Greenberg, 0xD34D, DeFlock, GainSec, EFF
Rotating every 20 seconds...
LED: Yellow=Battery | Green=Penguin | Magenta=Pigvision | Cyan=Flock
--------------------------------------------------------------------
[PENGUIN] 00:1e:c0:a3:4f:b1 | Penguin-A34F | PENGUIN_A34FB1
[BATTERY] 9c:2f:9d:c8:12:ee | FS Ext Battery-C812 | FS_PROD_C812EE
[PIGVISION] 74:4c:a1:5d:90:3a | Pigvision-5D90 | PIGVISION_5D903A
[FLOCK] e0:7e:67:f2:88:0c | flock-F288 | flock-F2880C
```

The onboard LED will change color with each rotation.

---

## Testing With a Detector

Point your Flock-You detector (OUI-SPY, Xiao ESP32-S3, or similar) at the Nano. It should pick up detections within seconds. The LED on your Nano will match the color category shown on the detector's display.

Recommended detector firmware: **Flock-You v9.15+** from [colonelpanichacks/flock-you](https://github.com/colonelpanichacks/flock-you)

---

## Troubleshooting

### "No serial port found"
- Make sure your USB-C cable supports data (not charge-only)
- Try a different USB port
- On Windows, you may need to install the ESP32-S3 USB driver

### "ImportError: no module named 'bluetooth'"
- Your MicroPython build may be too minimal. Re-flash with the official ARDUINO_NANO_ESP32 build from micropython.org which includes BLE support

### LED not working
- The Nano ESP32 RGB LED uses **inverted logic** (LOW = ON). This is handled in the code. If you see no LED activity, verify you have the correct board (ABX00083, not the older Nano)

### MAC address not changing (detector sees same MAC)
- This is a known ESP32-S3 MicroPython limitation. The WiFi MAC changes reliably but BLE MAC override depends on firmware. The detector should still trigger on BLE name + manufacturer ID even if the BLE MAC stays static.

### "OSError: -18" on gap_advertise
- The BLE advertising payload exceeded 31 bytes. This is handled in the current code by truncating the device name. If you modify profile names, keep them short.

---

## Customization

**Change rotation speed:**
Edit the `time.sleep(20)` at the bottom of the script. Value is in seconds.

**Add more OUI prefixes:**
Add entries to the `PROFILES` list. Format is `(tag, ble_name_prefix, ssid_prefix, oui_bytes)`. The tag must match a key in `COLORS` for LED support.

**Adjust LED brightness:**
The onboard LED is digital only (on/off per channel), so you can't dim it. For PWM dimming, you'd need to switch from `Pin` to `PWM` objects.

---

## Credits

This project builds on the work of many researchers and open-source contributors:

- **Ryan O'Horo** ([@ryanohoro](https://ryanohoro.com)) — Falcon camera teardown, OUI identification, Penguin BLE analysis
- **ColonelPanic** ([colonelpanic.tech](https://colonelpanic.tech)) — Flock-You detector firmware, OUI-SPY hardware, MAC prefix database
- **Will Greenberg** ([@wgreenberg](https://github.com/wgreenberg)) — XUNTONG manufacturer ID BLE detection
- **0xD34D** ([flock-spoof](https://github.com/0xD34D/flock-spoof)) — ESP32 spoofing reference implementation
- **DeFlock / FoggedLens** ([deflock.me](https://deflock.me)) — Crowdsourced ALPR camera data and MAC datasets
- **GainSec** — Raven BLE service UUID dataset
- **EFF** ([eff.org](https://www.eff.org/deeplinks/2024/04/defeat-flock)) — Flock Safety research and public analysis

---

## Legal

For **authorized security research and educational purposes only**. Ensure compliance with all applicable laws and regulations in your jurisdiction.
