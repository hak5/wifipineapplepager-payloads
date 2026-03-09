# 💾 DUMPY_REVERSE_DUCKY

**Counterintelligence & Mass Storage Exfiltration for the WiFi Pineapple Pager.**

### 🎯 The Philosophy

> Have you ever came across a flashdrive you couldnt ignore? Its precious loot, but smart enough not to trust anything? Well today you're in luck. I present the **DUMPY_REVERSE_DUCKY**: counterintelligence made easy. Making sure theres no fowl play. Checking the drive might save your life and guess what? Once its passed the hump youre ready to dump. No fowl play detected? Grab all the loot and get it ejected.

---

## 🛠️ Technical Specifications

* **HID Lockout (Pre-emptive):** Immediately executes `rmmod usbhid` upon hardware detection to neuter any HID-based attack strings.
* **Double-Lock Interrogation:** Cross-references `/proc/bus/input/devices` with the `bInterfaceClass` sysfs tree. If class `03` (HID) is present, the script kills the session.
* **Stationary Tagging:** Refined UI logic ensures the index remains fixed when a file is tagged, preventing accidental scrolls during field ops.
* **High-Value Regex Logic:** Scans filenames for high-priority targets (`wallet`, `kdbx`, `key`, `secret`, `credential`) and sorts them to the top of the buffer.

---

## 🕹️ Field Controls

* **UP / DOWN:** Navigate file manifest.
* **B BUTTON:** Toggle Tag (`[X]`) for Exfiltration.
* **A BUTTON:** Commit selection and initiate Dump.
* **EXIT TRAP:** Triggers a persistent 10s "WAIT TO REMOVE" UI lock to prevent filesystem corruption.

---

## 🔔 Audible & Visual Cues

| Event | Audio Trigger | Visual State |
| --- | --- | --- |
| **Boot/Armed** | `RINGTONE ring1` | Sentinel Armed |
| **Fowl Play** | `RINGTONE warning` | ALERT: FOWL PLAY DETECTED |
| **Drive Clear** | `RINGTONE health` | PASSED THE HUMP / READY TO DUMP |
| **Commit** | `RINGTONE leveldone` | Exfiltrating... |
| **Completion** | `RINGTONE success` | SAFE TO REMOVE |

---

## ⚠️ Operational Warnings

* **Storage Capacity:** I have successfully tested this script with a **128GB flash drive** full of movies. While it works, be aware that high-capacity drives will naturally take longer to index and list.
* **Compression Overhead:** This script utilizes `tar` for exfiltration. Large file sets will result in longer compression times due to the Pineapple's CPU limitations. Plan your field time accordingly.
* **Power Draw:** Large external drives may exceed the Pager's power delivery capabilities. If you experience flickering or crashes during a dump, check your power supply.

---

## ⚖️ Disclaimer & Development

**No Guarantees:** While I have designed this script to be a "Ducky Killer," the nature of specialized hardware and "morphing" USB controllers means no detection method is 100% infallible. New hardware revisions may bypass standard interrogation.

**The Grind:** I have poured an immense amount of time into the interrogation phase of this script. I have iterated through over 100 versions of the detection loop—tuning timing, CPU priority, and driver manipulation—to ensure the fastest possible "handshake" analysis. This is the result of my exhaustive testing to ensure I have the best possible chance of spotting the fowl play before it spots me.

