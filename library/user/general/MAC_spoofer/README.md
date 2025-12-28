# MAC Spoofer

**MAC Spoofer** is an identity management payload for the WiFi Pineapple Pager.

### Features

* **Smart Interface Sorting:** Automatically prioritizes client (`wlan0cli`) and monitor (`wlan1mon`) interfaces for faster selection.
* **True Hardware Detection:** Identifies the permanent factory MAC address for backups, ensuring "Restore" always reverts to the real hardware state.
* **Categorized Identities:** Profiles are grouped by environment (Home, Corporate, Commercial, Industrial, Wired) for quick selection.
* **Safety Restore:** Includes a "Restore Original" option to revert to factory settings without rebooting.

### Workflow Tutorial

**1. Workflow Briefing** The payload begins with a brief overview of the process and a safety warning regarding network disconnection.

![Startup](screens/Capture01.png)

**2. Select Interface** The tool scans for all available network interfaces, prioritizing the most useful ones at the top of the list. Enter the ID of the interface you wish to spoof.

![Interface List](screens/Capture02.png)

![Interface Selection](screens/Capture03.png)

**3. Select Environment** Choose the category that matches your target environment. (0: Restore, 1-5: Spoof Profiles).

![Environment List](screens/Capture04.png)

![Category Selection](screens/Capture05.png)

**4. Select Device Profile** Select the specific device to emulate. The script generates a valid MAC address using that vendor's OUI and a randomized suffix.

![Profile List](screens/Capture06.png)

![Profile Selection](screens/Capture07.png)

**5. Confirm Action** Review your selection. The screen displays the target Interface, the new Hostname, and the new MAC address for confirmation.

![Confirm Spoof](screens/Capture08.png)

**6. Apply & Verify** The tool temporarily disables the network interface, applies the new identity, and re-enables it. It then verifies the active state against the kernel.

![Success](screens/Capture09.png)

### Technical Notes

* **Persistence:** All changes are volatile. Rebooting the device will automatically reset the MAC address to its hardware default.
* **Connection Drop:** Running this payload while connected to a network will drop the connection. Reconnection is required after the spoof is applied.


### 📊 OUI Verification Chart

| Category | Device Profile | Script OUI | Registered Vendor | Status |
| :--- | :--- | :--- | :--- | :--- |
| **Home** | Apple iPhone 15 | `F0:99:B6` | Apple, Inc. | ✅ Verified |
| | Samsung Smart TV | `84:C0:EF` | Samsung Electronics Co.,Ltd | ✅ Verified |
| | Amazon Echo Dot | `FC:D7:49` | Amazon Technologies Inc. | ✅ Verified |
| | Sony PlayStation 5 | `00:D9:D1` | Sony Interactive Entertainment | ✅ Verified |
| **Corporate** | HP LaserJet Pro | `00:21:5A` | Hewlett Packard | ✅ Verified |
| | Cisco IP Phone | `00:08:2F` | Cisco Systems, Inc. | ✅ Verified |
| | Polycom Conf Phone | `00:04:F2` | Polycom | ✅ Verified |
| | Dell Latitude Laptop | `F8:BC:12` | Dell Inc. | ✅ Verified |
| **Commercial** | Zebra Scanner | `00:A0:F8` | Zebra Technologies Inc | ✅ Verified |
| | Verifone POS | `00:0B:4F` | Verifone, Inc. | ✅ Verified |
| | Ingenico Reader | `00:03:81` | Ingenico International | ✅ Verified |
| | Axis Security Camera | `AC:CC:8E` | Axis Communications AB | ✅ Verified |
| **Industrial** | Siemens Simatic PLC | `00:1C:06` | Siemens Numerical Control Ltd | ✅ Verified |
| | Rockwell Automation | `00:00:BC` | Rockwell Automation | ✅ Verified |
| | Honeywell Controller| `00:30:AF` | Honeywell GmbH | ✅ Verified |
| | Schneider Electric | `00:00:54` | Schneider Electric | ✅ Verified |
| **Ethernet** | MSI Gaming Desktop | `D8:CB:8A` | Micro-Star Intl (MSI) | ✅ Verified |
| | Moxa NPort Gateway | `00:90:E8` | Moxa Technologies Corp | ✅ Verified |

