# 🛡️ TRIG_MAC v1.2.0

### WiFi + BLE Identity Correlator | WiFi Pineapple Pager

**TRIG_MAC** is a tactical target-tracking engine built specifically for the Pineapple Pager. It bridges the gap between passive WiFi sniffing and BLE discovery by correlating MAC addresses with SSID probe requests. The engine is optimized for the Pager’s hardware constraints, utilizing a stable passive handshake to switch between frequencies without the radio hangs or firmware crashes common in standard scripts.

---

## 🕹️ OPERATOR CONTROLS

| Input | Action |
| --- | --- |
| **UP** | **Add SSID Target** (Network name to watch for) |
| **DOWN** | **Add BLE MAC** (Bluetooth address to track) |
| **LEFT** | **Add WiFi MAC** (Client device to monitor) |
| **A (Select)** | **INITIATE** (Start scanning loop) |
| **B (Back)** | **WIPE DB** (Clear all targets and flash memory) |

---

## 🚀 DEPLOYMENT

1. **Launch:** Fire up the payload on the Pager.
2. **Restore:** Select **YES** to reload saved targets. The screen will scroll `LOAD BLE/WF/SSID` to confirm the active watch list is hot.
3. **Configure:** Use the D-pad to add new targets.
4. **Arm:** Press **A**. The Pager chimes (`RINGTONE alert`) and the LED hits **GREEN** for 3 seconds.
5. **Monitor:** Once the title bar hits **WARDEN ACTIVE**, the loop is live.

---

## 📋 DATA & EXTRACTION LOGIC

**TRIG_MAC** doesn't just ping—it extracts intelligence:

* **SSID Targets:** When a target network is found, the engine pulls the **Source MAC** of the device searching for it.
* **MAC Targets:** When a target device is hit, the engine extracts the **SSID** they are probing for (identifying home/work network history).
* **Logging:** All hits are timestamped and saved to: `/root/loot/TRIG_MAC/hits.log`.

---

## 🛠️ HARDWARE SPECS

* **Feedback:** Visual OLED text, RGB LED pulses, and audible `alert` chimes.
* **Passive Handshake:** Uses `SIGINT` and process-tracking for `hcitool` and `tcpdump`. This prevents "Device Busy" errors by allowing the radio firmware to cycle gracefully between Bluetooth and WiFi Monitor modes.
* **Persistence:** Target lists are synced to the Pineapple's internal config database (`PAYLOAD_SET_CONFIG`) automatically after every addition.

