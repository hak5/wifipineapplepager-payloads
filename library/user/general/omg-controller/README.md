# O.MG Controller

**Author:** Gas Station Hot Dog  
**Version:** 1.6.4

Control an O.MG cable or plug from the WiFi Pineapple Pager. Browse and execute
payloads, import text files, edit source, manage backups, change USB descriptors,
and control USB and mouse-jiggler settings.

The Pager connects to the O.MG device's Wi-Fi network and communicates with it at
the fixed address **192.168.4.1**. Internet access is not required during use.

## Requirements

- WiFi Pineapple Pager running firmware **1.0.8 or later**.
- **Python 3.9 or later** installed on the Pager.
- An O.MG cable or plug with its Wi-Fi access point enabled.
- Writable storage in the installed controller folder for backups.

The controller targets O.MG firmware **v3.0.16.250816**. Other firmware versions
may use different API behavior. Execution supports the DuckyScript commands
listed under [Payload compatibility](#payload-compatibility).

## Installation

1. If Python is missing, connect the Pager to the Internet and run:

   ```sh
   opkg update
   opkg install -d mmc python3
   LD_LIBRARY_PATH=/mmc/usr/lib:/mmc/lib python3 --version
   ```

2. Copy the entire `omg-controller` folder to:

   ```text
   /root/payloads/user/general/omg-controller/
   ```

   Include all Python files, the `vendor` folder, and the `payloads` folder.
   The WebSocket dependency is bundled; no pip installation is needed.

3. Preserve Unix LF line endings and make the launcher executable:

   ```sh
   chmod +x /root/payloads/user/general/omg-controller/payload.sh
   ```

4. Connect the Pager to the O.MG device's Wi-Fi network.
5. Launch **Payloads > User > General > O.MG Controller** on the Pager.

When updating, exit the controller before replacing its files. Keep your
`backups` folder and any custom files in `payloads`.

## Main menu

| Option | Function |
| --- | --- |
| **Payloads** | Browse payload slots and open their action menus. |
| **Payload status** | Read the device's payload execution status. |
| **USB descriptors** | View or edit VID, PID, manufacturer, product, and serial values. |
| **Device status** | View firmware, device type, MAC address, uptime, and diagnostics. |
| **Extra** | Turn USB or the mouse jiggler on/off, measure connection timing, or restore a backup. |
| **Reboot** | Send a reboot command and close the controller. |
| **Exit** | Close the controller. |

Use **Back** or the normal cancel button to return from menus. Cancelling the
main menu exits the controller. Exiting does not stop a submitted O.MG USB payload
or undo USB and jiggler settings.

**Reboot takes effect immediately without confirmation.** Follow the displayed
instructions: wait for the O.MG access point to return, reconnect the Pager, then
launch the controller again.

## Working with payloads

The payload list shows slot numbers and a preview of the source's first nonblank
line. A leading `REM` and its following spaces or tabs are hidden for readability.
Available slots are labelled **Create New**.

Select a populated slot to access:

| Option | Function |
| --- | --- |
| **Execute** | Validate and submit the payload immediately, without confirmation. |
| **View** | Read the full source in numbered pages. Press A to open page navigation. |
| **Edit** | Modify the source with the Pager's line editor. |
| **Backup Payload** | Save a text backup on the Pager. |
| **Restore Payload Backup** | Choose a backup to restore into this slot. |
| **Clear Slot** | Remove the source after confirmation. |
| **Back** | Return to the payload list. |

Execution requires the O.MG device to be idle. A submission message means the
controller sent the payload; it does not confirm completion on the attached host.

### Create or import a payload

Select **Create New**, then choose:

- **Write new:** enter source using the line editor.
- **Import .txt:** choose a text file and save it directly into the selected slot.
- **Restore Payload Backup:** restore a saved backup into the selected slot.

For imports, copy UTF-8 `.txt` files into:

```text
/root/payloads/user/general/omg-controller/payloads/
```

Selecting an import file saves it without opening the editor or executing it.
The file must fit the slot, and the destination must still be empty.
`OMG-TTS-Windows.txt` is included as an example.

### Edit source

Choose **Edit** for an existing payload or **Write new** for an available slot.
Select a numbered line to edit it, insert a line before it, or delete it.
**Append line** adds a line at the end. **Save** asks for confirmation;
**Discard** leaves the device unchanged.

The editor preserves source whitespace and line endings. It checks slot capacity
and detects source changes made elsewhere before saving, then verifies the write.
Slots paired with **bootscript** must be edited through the O.MG web interface so
the compiled boot payload is also rebuilt.

## Backups and restores

Backups are UTF-8 `.txt` files stored on the Pager in:

```text
/root/payloads/user/general/omg-controller/backups/
```

Use **Backup Payload** to save a copy manually. The controller also backs up
existing source before replacing or clearing it. Empty slots do not need backups.

Filenames contain the slot number, up to ten characters of its preview title,
and the Pager's local date and time:

```text
001-My payload-2026-09-19_14-30-25.txt
```

Keep these filenames intact so the controller can recognize the backups and
their original slots.

**Restore Payload Backup** in a slot's menu restores into that selected slot.
Under **Extra**, it first offers the backup's original slot. Choose **No** to
select a different destination; **New Slot (empty)** identifies an available
destination that will not overwrite an existing payload. Restores require
confirmation.

If a write is interrupted, the slot may be incomplete. Keep the backup and use
the restore menu to recover it. Failed writes are not automatically retried.

## USB settings and connection tools

**USB descriptors** lets you view or edit the USB vendor ID, product ID,
manufacturer, product name, and serial number. Save the settings, then reboot
the O.MG device to apply them.

**Extra** provides USB on/off and mouse-jiggler on/off controls.
**Connection timing** measures three echo round trips to help assess connection
latency. Browsing a large number of slots or editing long payloads can take longer
because the controller reads their contents from the device.

## Payload compatibility

The controller can store and view plain-text source, but its execution compiler
supports a subset of DuckyScript using the **US keyboard layout**:

- `REM`, `REM_BLOCK` / `END_REM`.
- `STRING`, `STRINGLN`, `STRING_BLOCK` / `END_STRING`, and
  `STRINGLN_BLOCK` / `END_STRINGLN`.
- `DELAY`, `DEFAULT_DELAY`, and `DEFAULT_CHAR_DELAY`, at 10 ms resolution.
- `DUCKY_LANG US`.
- O.MG inline `REPEAT count command`, up to 1000 repeats.
- Common named keys, F1–F12, and modifier combinations.
- `USB ON/OFF`, `JIGGLER ON/OFF`, `USB_RESET`, and `CAPSLOCK_DISABLE`.

Functions, DEFINE substitution, other keyboard layouts, randomization,
geofencing, mouse commands, and other unlisted extensions are unsupported.
Unsupported syntax is rejected before execution. Use the O.MG web interface
to execute scripts that require those features. Importing or editing a script
does not guarantee that this controller can execute it.

## Troubleshooting

- **Cannot connect:** confirm that the Pager is connected to the O.MG access
  point and that the device is reachable at `192.168.4.1`.
- **Missing helper files:** copy the entire controller folder and launch it
  from the Pager payload menu. The launcher uses `PAYLOAD_HOME` to locate its files.
- **Python shared-library error:** verify the MMC Python installation and that
  its required libraries exist under `/mmc/usr/lib`.
- **Read or save error:** record the exact error and O.MG firmware version.
  For an interrupted save, retain the text backup for recovery.
- **Menus appear after stopping:** normal cancellation navigates back; termination
  signals exit. Pager firmware that reports both actions as cancellation may
  require choosing **Exit** from the main menu.

Automated tests cover simulated device responses and Pager menus. Behavior can
vary with device firmware; authentication used by other firmware is not supported.

## Credits and references

Bundled example: [OMG-TTS-Windows.txt by Kalani](https://github.com/hak5/omg-payloads/blob/master/payloads/library/prank/OMG-TTS-Windows.txt),
included unchanged with its original author credit.

- [Hak5 Pager payload documentation](https://documentation.hak5.org/wifi-pineapple-pager/payloads-1/introduction-to-payloads)
- [O.MG WebSocket API](https://github.com/O-MG/O.MG-Firmware/wiki/WebSocket-API)
- [Official O.MG frontend](https://github.com/O-MG/O.MG-Firmware/blob/stable/c2server/index.html)

Includes unmodified **websocket-client 1.9.0**, licensed under Apache-2.0, with
its license included in the bundled metadata. This is an independent controller,
not an official Hak5/O.MG integration.
