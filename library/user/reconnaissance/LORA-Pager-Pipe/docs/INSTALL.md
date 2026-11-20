# Install LORA-Pager-Pipe

LORA-Pager-Pipe is a receive-only LoRa observation payload for the Hak5 WiFi Pineapple Pager and Glytch Mesh Mod. It saves local sessions and can run alongside the Pager's native Wi-Fi wardriving. It does not replace the Pager firmware.

## Requirements

- WiFi Pineapple Pager with current firmware. The native list menu requires firmware 1.0.8 or newer. Check the actual installed version before deployment.
- Glytch Mesh Mod connected over USB. Its SX1262 is controlled through a CH341 USB-to-SPI bridge; this is not a USB serial LoRaPipe node.
- A compatible GNSS receiver configured in **Settings → GPS**, or another verified gpsd source, for geolocated captures. The Mesh Mod itself does not supply GPS.
- Free space on the Pager's MMC storage for dependencies and session logs.
- Internet access for initial dependency installation and optional uploads. Recording is local and does not require an Internet connection.

The payload and all helper source files must be installed together. Do not copy `payload.sh` alone.

## Copy the payload

Copy the contents of the repository's `payload/` directory to:

```text
/root/payloads/user/reconnaissance/LORA-Pager-Pipe/
```

For example, from a machine with SSH access to the Pager:

```sh
scp -r payload root@172.16.52.1:/root/payloads/user/reconnaissance/LORA-Pager-Pipe
```

Use the Pager's actual address when it differs from the default USB/management address. Confirm that the destination contains `payload.sh`, `lpp.py`, helper modules, and `assets/`; some SCP clients create an additional `payload/` directory if the destination already exists.

Run the payload from **Payloads → User → Reconnaissance → LORA-Pager-Pipe**. The native UI commands require the Pager payload runner; launching the script from an ordinary SSH shell does not provide that UI context.

## Dependencies

On every launch, the payload checks Python 3 and the dependencies for the selected radio backend. It offers to install missing required packages to MMC using the configured OpenWrt package feeds: `python3`, `libusb-1.0-0` for Glytch, or `python3-pyserial` for a configured serial LoRaPipe backend. Installation requires confirmation, connectivity and free space. Already installed packages are not replaced or upgraded; a package that is installed but unusable needs its MMC paths and firmware compatibility checked. The payload rechecks dependencies after installation before opening its main menu.

Missing decoding support prompts a separate, optional offer to install `python3-cryptography`. Declining it or an optional installation failure leaves raw capture available. The startup check does not change the backend, touch the radio, test GPS, or require a region to have been chosen. AES and signature self-tests still run in the capture preflight.

For a manual Python installation:

```sh
opkg update
opkg install -d mmc python3
```

The dependency-only CLI emits a bounded list of fixed dependency tokens for the launcher. Use `doctor` for the full region, radio, GPS and cryptography preflight before capturing:

```sh
python3 /root/payloads/user/reconnaissance/LORA-Pager-Pipe/lpp.py dependencies
python3 /root/payloads/user/reconnaissance/LORA-Pager-Pipe/lpp.py doctor
```

The payload includes the unmodified Python source of **PyUSB 1.3.1** under `lib/usb/`, including its BSD 3-Clause license. The Pager feed checked during development did not supply a PyUSB package; do not try to install `python3-pyusb`. If `doctor` reports missing bundled PyUSB, reinstall the complete payload directory. The entry point puts its own `lib/` directory on Python's import path, so no system-wide PyUSB installation or `pip` command is required.

The Glytch backend also needs the system **libusb-1.0** library. Local AES decoding and MeshCore advertisement signature verification can both use **`python3-cryptography`**; the Pager's official package version 41.0.7 was installed and loaded during development. Check whether each dependency is already installed before installing a missing package to MMC:

```sh
opkg status libusb-1.0-0
opkg status python3-cryptography
opkg update
for package in libusb-1.0-0 python3-cryptography; do
    opkg status "$package" 2>/dev/null | grep -q '^Status:.* installed$' ||
        opkg install -d mmc "$package"
done
```

Do not request replacement or upgrades of already installed system packages. The optional serial LoRaPipe backend needs PySerial separately. The decoder also supports existing PyCryptodome and PyNaCl installations, but they are not needed when the supported `cryptography` backend is available. Without the relevant cryptography backend, raw packets remain available and decoding/verification is reported as unavailable. Use matching packages from the Pager's configured feed; do not download architecture-mismatched wheels or compile replacements for system libraries.

The CLI sets `CRYPTOGRAPHY_OPENSSL_NO_LEGACY=1` for its own process unless that variable is already configured. AES and Ed25519 use OpenSSL's default provider; this payload does not need legacy algorithms. On the tested Pager, the MMC `cryptography` installation could not initialize the legacy provider, and this supported setting restored AES operation. It does not modify the system OpenSSL configuration or other services. `doctor` verifies an AES known vector and, for MeshCore modes, an RFC 8032 Ed25519 signature instead of treating a successful import as proof that decoding works. [Cryptography's OpenSSL provider setting](https://cryptography.io/en/41.0.5/openssl/).

Do not run a bulk `opkg upgrade` or replace the Pager's system libraries. The root overlay is small; use the `mmc` package destination. Packages should be rechecked after a Pager firmware upgrade even when their files remain on MMC.

## GPS ownership on the tested Pager firmware

On firmware `20261019-0027-ga0cd21f-dirty`, PineAP can own the serial GPS directly. In that configuration, the `gpsd` init script intentionally refuses to start while the native `pineapgps` setting is enabled and a GPS device is configured. The Pager's native GPS display can therefore work while this payload reports that its local gpsd connection is unavailable. LORA-Pager-Pipe reads gpsd on `127.0.0.1:2947`; it does not open the GPS serial port or change its owner automatically.

The tested `pineapd` service also supports using gpsd instead of owning the serial port. Switching to that mode lets the native Pager and the payload use the same receiver through gpsd. This is a firmware-specific compatibility procedure, not a setting to apply blindly to other releases.

First stop LoRa capture and any native Wi-Fi recording. In **Settings → GPS**, confirm the receiver's current serial device and its documented baud rate. A USB hub changes the `/dev/serial/by-path/` name, so a previously saved path may no longer identify the connected receiver. Do not copy another device's bus path or assume every GNSS receiver uses 115200 baud.

These commands inspect only the relevant GPS settings and device links:

```sh
ls -l /dev/serial/by-path/
uci -q get gpsd.core.device
uci -q get gpsd.core.speed
uci -q get gpsd.core.enabled
uci -q get gpsd.core.listen_globally
uci -q get 'pineapd.@pineapd[0].pineapgps'
uci -q get 'pineapd.@pineapd[0].gpsdevice'
/etc/init.d/gpsd status
```

If this matches the native-owner configuration described above, the following command block backs up both configurations privately and switches the tested firmware to gpsd. Replace both placeholders with the receiver and baud rate you have verified. The checks prevent the example placeholders from being applied:

```sh
(
    set -eu
    umask 077
    VERIFIED_BY_PATH='/dev/serial/by-path/REPLACE_WITH_YOUR_RECEIVER'
    VERIFIED_GPS_BAUD='REPLACE_WITH_VERIFIED_BAUD'
    case "$VERIFIED_BY_PATH" in
        /dev/serial/by-path/*) ;;
        *) printf '%s\n' 'Use the verified /dev/serial/by-path device.' >&2; exit 1 ;;
    esac
    [ -c "$VERIFIED_BY_PATH" ] || {
        printf '%s\n' 'The selected receiver is not an available serial device.' >&2
        exit 1
    }
    case "$VERIFIED_GPS_BAUD" in
        4800|9600|19200|38400|57600|115200|230400) ;;
        *) printf '%s\n' 'Set a supported, verified receiver baud rate.' >&2; exit 1 ;;
    esac

    gps_backup_dir="/root/lora-pager-pipe-gps-backup-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir "$gps_backup_dir"
    cp /etc/config/gpsd "$gps_backup_dir/gpsd"
    cp /etc/config/pineapd "$gps_backup_dir/pineapd"
    chmod 600 "$gps_backup_dir/gpsd" "$gps_backup_dir/pineapd"
    printf 'Private recovery backup: %s\n' "$gps_backup_dir"

    uci set gpsd.core.device="$VERIFIED_BY_PATH"
    uci set gpsd.core.speed="$VERIFIED_GPS_BAUD"
    uci set gpsd.core.enabled='1'
    uci set gpsd.core.listen_globally='0'
    uci set 'pineapd.@pineapd[0].pineapgps=0'
    uci set "pineapd.@pineapd[0].gpsdevice=$VERIFIED_BY_PATH"
    uci commit gpsd
    uci commit pineapd
    /etc/init.d/pineapd restart
    /etc/init.d/gpsd restart
)
```

Keep the backup private: the PineAP configuration can include network settings and must not be added to the payload or a public report. For recovery, stop recording, stop gpsd, restore the two saved configuration files to their original `/etc/config/` locations, and restart the services. If the restored settings select the native serial owner, gpsd remaining stopped is expected.

After switching, run the payload's `doctor` command and a short capture. A reachable daemon is not proof of a GNSS fix: confirm that session GPS status becomes `fix`, the fix age remains fresh, and receiver-reported UTC is available. Native Pager Wi-Fi recording should also be checked with the shared gpsd source. When the hub or receiver changes, recheck the physical device path before restarting either service.

## First capture

1. Open **Region** and select a profile suitable for your location and radio hardware. **Region → LoRa mode** selects Meshtastic, MeshCore, or alternating profiles.
2. Check that GNSS reports a valid fix outdoors. Missing or stale fixes must remain missing in the log; an advertised mesh-node position is not the receiver's position.
3. Make sure another program is not using the Glytch radio. MeshtasticD and this payload cannot independently control the same SX1262 at once.
4. Select **Capture → Start LoRa**. The worker records while the menu remains open.
5. Use **Status** to inspect the session. A running process alone does not prove reception; verify a known transmission on the selected frequency and modem preset.
6. Choose **Capture → Stop LoRa** before unplugging the radio or shutting down. **Exit** also closes a capture started by this payload.

The SX1262 listens on one frequency and modem configuration at a time. Channel/profile scanning can miss traffic transmitted while another profile is active.

**Observations → Recent packets** shows a bounded local snapshot of the latest saved packets, including available decoded names or message text, signal levels and the receive profile. **Device summaries** shows recognized source identities with their actual last-seen times. Meshtastic IDs are labeled **claimed**, because its packet header is not authenticated; MeshCore identities require a verified advertisement signature. Unknown sources remain in the packet view. Times are the recorded Pager timestamps displayed in UTC, not proof that the device clock was synchronized. Receiver/node coordinates and configuration keys are excluded from these views. Opening a view does not upload anything or pause capture.

## Wi-Fi alongside LoRa

The payload preserves the native Pager UI and Recon services. To combine observations, start native recording in **Recon → Settings**, choose the Wi-Fi bands there, then select **Capture → LoRa + existing Wi-Fi**. Native Wi-Fi recording remains under Recon control and must be stopped there separately.

This version does not silently rotate or stop an existing WiGLE/PCAP recording. A pre-existing capture may belong to another task or payload. Native WiGLE logs are only populated when the Pager has a valid GNSS position. Three-band Wi-Fi uses channel hopping; it does not monitor every 2.4, 5, and 6 GHz channel continuously.

Native Wi-Fi CSV and PCAP remain in the Pager's loot directories. LoRa sessions are separate local records. A session is not a native Kismet database merely because it uses SQLite; consult the export documentation for validated formats.

After stopping both recorders, use **Upload settings → Export / upload session → Attach Wi-Fi CSV** or **Attach Wi-Fi PCAP** and enter the absolute filename. The next export snapshots the selected file into the LoRa session. Recording files are never guessed or taken over; the original native files remain in place.

## Exports and uploads

Use **Upload settings → Export / upload session** after stopping capture. Keep the original local logs so an exporter can be updated without losing observations. The export and upload commands check which record types each service accepts; raw LoRa packets must not be relabeled as Wi-Fi rows.

Upload configuration is stored privately in:

```text
/root/.config/lora-pager-pipe/config.json
```

It is not part of the payload or repository. Keep this file out of backups intended for publication. Native text entry is visible on the Pager screen; credentials are passed to the helper over standard input and must not appear in session logs or command-line arguments.

Upload destinations are fixed to the supported service hosts so a configuration change cannot redirect credentials to another server. Credentials alone do not establish that a service accepts a particular export. **Allow uploads** enables a service; **Automatic uploads** is a separate, explicit per-service setting. Review what will be sent, including location information, before enabling it. Original logs are retained after uploads.

Automatic upload runs after a clean LoRa stop and after successfully attaching a native recording, only for services with both options enabled. Each pass advances eligible uploads and pending server jobs within a four-minute budget. Queued imports, rate limits, and uncertain results remain recorded for later review when the budget ends. A native Wi-Fi file must be closed and attached before it can be included. If automatic upload is disabled, choose the manual upload action. Starting another LoRa capture is blocked while an upload holds the capture lock.

## Troubleshooting

- **Missing UI command:** launch from the Pager's Payloads menu and check the firmware version.
- **Dependency failure:** check Internet access and MMC space; run `doctor`. Do not replace system packages to satisfy a dependency.
- **Radio busy:** stop the existing radio application through its own control interface before starting this collector.
- **No LoRa observations:** check frequency, bandwidth, spreading factor, coding rate, sync word, antenna, and nearby traffic. Radio availability is not proof of a successful capture.
- **No locations:** check the receiver connection, gpsd status, and an unobstructed sky view. Recording without a fix must not invent coordinates.
- **Capture exits:** inspect `worker.log` in that session. Interrupted sessions and raw observations are retained for diagnosis.
- **Empty native WiGLE CSV:** the Pager may not have obtained a valid GNSS fix during the recording.

## Upstream references

- [Hak5 payload contribution requirements](https://github.com/hak5/wifipineapplepager-payloads)
- [Hak5 advanced-payload and package requirements](https://documentation.hak5.org/wifi-pineapple-pager/payloads-1/advanced-payloads)
- [Hak5 GPS setup](https://documentation.hak5.org/wifi-pineapple-pager/gps)
- [Native WiGLE commands](https://documentation.hak5.org/wifi-pineapple-pager/wifi-pineapple-commands/wigle)
- [Native Wi-Fi PCAP commands](https://documentation.hak5.org/wifi-pineapple-pager/wifi-pineapple-commands/wifi_pcap)
- [Glytch Mesh Mod hardware](https://shop.hak5.org/products/glytch-mesh-mod-for-pager)
- [Glytch Mesh Mod setup and source](https://github.com/glytchtech/Pager-Mod-Docs/tree/main/Mesh)

Repository submission should contain inspectable source and required assets. Hak5's current guidance does not accept custom compiled binary components; review its live requirements before submitting a pull request. Local parser tests, device UI checks, radio reception, and successful live uploads are separate validation steps.
