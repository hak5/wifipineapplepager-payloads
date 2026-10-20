# O.MG Flasher for the WiFi Pineapple Pager

Run the official O.MG firmware installation flow from the Pager's Payloads menu.
Select **v3 stable** or **v4 alpha**, download or reuse cached official firmware,
and program the connected O.MG device through its USB programmer.

Author: **Gas Station Hot Dog**.

Based on the [official O.MG WebFlasher](https://github.com/O-MG/WebFlasher).

## Install

Copy this entire `omg-flasher` directory to the Pager:

```sh
scp -r omg-flasher root@172.16.52.1:/mmc/root/payloads/user/general/
ssh root@172.16.52.1 'chmod +x /mmc/root/payloads/user/general/omg-flasher/payload.sh /mmc/root/payloads/user/general/omg-flasher/setup.sh'
```

Use the Pager's address if different. Available EMMC space and an Internet
connection are required for initial setup and firmware downloads. Subsequent
flashes can use the offline cache. Set the Pager's date/time correctly for HTTPS. On first launch the
payload offers to install Python, pip, CA certificates and the CP210x driver.
User-space packages go to EMMC; the matching kernel driver is installed
through the Pager's own package feed. The payload installs esptool 4.8.1,
pyserial 3.5 and intelhex 2.3.0 into its own `lib` directory. These are the
pure-Python modules needed for this serial API; unrelated esptool dependencies
are deliberately omitted so MIPS native extension compilation is unnecessary.

**Dependency installation can take several minutes, and the Pager may lag
while it runs.** Let it finish while log output is progressing. You can monitor
the installation over SSH using the commands below.

The launcher uses the Pager's `_PAYLOAD_HOME` (or `PAYLOAD_HOME`) to locate
installed files when the Pager runs its generated script from `/tmp`. Direct
SSH execution falls back to the script directory.

## Run

1. Connect the **official O.MG Programmer** to the Pager's **USB host port** using
   the appropriate host adapter. Connect the O.MG device to the programmer.
   Its **PWR, USB and OMG** indicators must all be on.
2. Open **Payloads → User → General → O.MG Flasher**.
3. Use the firmware picker to select **v3 stable** or **v4 alpha (Elite only)**.
   Then choose **Online: Latest** or **Cache: <version>** in the source picker.
   The cache option displays its verified release tag, or **Cache: None**.
   Multiple Silicon Labs programmers trigger an additional port selector.
4. v4 requires you to confirm that this is an **Elite** Cable, Plug or Adapter.
5. The payload identifies the hardware, downloads or reuses verified firmware,
   checks new downloads against their official Git blob checksums, and shows the
   exact version and device MAC before writing anything.
6. Choose whether to pre-erase, then confirm installation. Flashing replaces
   configuration and initializes payload slots, as the default web flasher does.
   Keep the programmer attached and the Pager powered through completion.
7. Once all segments pass readback verification, unplug the programmer and
   connect the O.MG device to a normal USB port.

## Release selection and compatibility

As verified on October 2, 2026, the latest versions are `v3.0-260728` and
`v4.0-260221`. These are examples, **not pinned defaults**. Online preparation
queries the official release list, including prereleases and additional pages,
and selects the newest published tag for the chosen major version. v3 excludes
prereleases. v4 includes them. Firmware files come from the selected tag's
resolved commit, so a moving branch cannot mix files from different builds.

The **v4 alpha** option selects upstream's experimental v4 series and requires
an **Elite device**. Hardware
capacity cannot prove Elite product identity; the user must confirm the model.

The current WebFlasher's eFuse gate rejects older 1MB hardware and directs it to
the Advanced Flasher. This payload preserves that gate and accepts the recognized
2MB device value. Both official 1MB/2MB memory maps are represented for download
validation, but the flashing entry point does not bypass the hardware gate.

## How it matches WebFlasher

Based on WebFlasher commit `a26e96f6480a0715936b16fadd9cc19010775368`:

- Uses the Silicon Labs USB vendor filter and 115200 baud.
- Uses the official memory map and file order, with RF initialization at
  `0x1fc000`, boot image at `0x00000`, application at `0x10000`, web UI at
  `0x80000`, initialization at `0x7f000`, settings at `0x7c000`, Wi-Fi at `0x7e000`.
- Applies the same first `00 20 → 03 30` boot image patch.
- Generates the same initialization string, boot/HID/keylog/payload slot
  allocation, `flasher=webflasherv2`, and `devicename=O.MG` configuration.
- Zero-fills the settings and Wi-Fi sectors with the web flasher's default
  behavior. Custom Wi-Fi overrides and diagnostic firmware upload are not part
  of this payload; configure Wi-Fi afterward through the O.MG interface.
- Optional pre-erase writes `0xff` over exactly 1,022,976 bytes from address zero,
  as WebFlasher does, leaving upper flash outside that range untouched.
  Progress identifies each of the 63 chunks, ending with `Verified pre-erase 63/63`.

Python esptool replaces browser WebSerial and the JavaScript serial transport.
The Pager UI uses a single background `session`: it connects, uploads the RAM
stub, downloads and validates the firmware, waits for your confirmation, and
flashes through that same open serial connection. It closes the port on success,
cancellation or error. Confirmation expires after 15 minutes. It does not close
and reopen the port between preparation and installation. The separate SSH
`prepare` and `flash` commands remain available for manual use.
The payload connects directly using the ESP8266/ESP8285 loader, skipping the
generic autodetector's unsupported newer-ESP32 probe. It still validates the
chip signature, supported flash capacity and device identity before flashing.
The default `web_reset` follows the official WebFlasher's programmer control
signals: DTR off/RTS on for 2 seconds, then DTR on/RTS off and a 1-second wait.
The port opens with DTR and RTS initially off. esptool then synchronizes without
applying another reset. `default_reset` remains available for troubleshooting.
Serial synchronization retains esptool's eight-reply handshake but waits up to
1 second for each reply instead of its stock 100ms initial-response timeout.
This reduces rapid retries and buffer clearing while the Pager/programmer is
starting up. It does not bypass sync replies, chip checks or write verification.
It runs the ESP8266 RAM stub, writes the same prepared bytes and additionally
verifies every written segment using the device's MD5 command. Write blocks are
2KB so padding cannot overwrite neighboring 4KB configuration sectors. SHA-256
checks protect prepared files from accidental changes before installation.

## Firmware cache and offline use

Verified downloads are kept on EMMC under
`/mmc/root/payloads/user/general/omg-flasher/cache/<channel>/<flash-capacity>/`.
The cache folder is inside the installed payload directory. v3 and v4 have
separate caches. Online mode checks the latest official release and its commit;
if that version is already cached, firmware files are not downloaded again.
A new release is saved only after all files pass validation, then the other
cache entries for that channel/capacity are removed. A successful online check
of an already cached release also removes redundant entries. Only the newest
release is retained for each series and flash capacity; updating v4 leaves v3
available. A failed refresh preserves the working cache. Cache entries include the prepared WebFlasher
bytes and manifest; SHA-256 checks and memory-layout checks run before reuse.

Choose **Cache: <version>** to skip all firmware network requests. It selects
the newest verified cached release for your chosen channel and detected capacity.
The summary explicitly says **offline cache; latest unchecked**. Online mode
also falls back to verified cached firmware if its release check fails because
of a network outage or GitHub rate limit. Invalid release metadata is an error.
If you choose offline cache and no valid matching release is available, a picker
offers **Download firmware** or **Exit**. Download requires Internet and saves
the verified firmware in the cache before the usual flash confirmation.
Exit closes the serial connection without writing firmware.
Dependencies must already be installed to operate entirely offline.

Device MAC and port bindings are refreshed for the current connected device.
Run logs remain separate. Keep the payload's `cache` directory when updating
the payload to preserve offline firmware. Only the five most recent `run-*`
log directories are retained. Temporary firmware copies in retained runs
are removed on exit; persistent firmware lives in the payload's cache.

For SSH download-only use (no serial connection):

```sh
python3 omg_flasher.py download --channel v4 --directory /tmp/omg-download --cache-dir ./cache
python3 omg_flasher.py download --channel v4 --directory /tmp/omg-offline --cache-dir ./cache --offline
```

## Logs and troubleshooting

Each run retains its manifest and `flash.log` under
`/mmc/root/loot/omg-flasher/run-*`. Cached/offline use is identified in the log
and final confirmation summary. A device
MAC/capacity change between preparation and installation aborts before writes.
Connection and RAM stub upload failures happen before firmware writes. RAM stub
upload is done before downloading in the Pager UI, so it does not report READY
until the serial transport and stub are working.

To monitor dependency installation, SSH into the Pager and follow the latest
run's live output:

```sh
ssh root@172.16.52.1
RUN=$(ls -td /mmc/root/loot/omg-flasher/run-* | head -n 1)
tail -f "$RUN/current.log"
```

Press **Ctrl+C** to stop watching; installation keeps running. To see whether
the installer processes are still active:

```sh
ps w | grep -E '[o]pkg|[p]ip|[s]etup.sh|[p]ython3'
```

`current.log` contains live output. `flash.log` receives that output after the
installation command finishes. To inspect recent output without following it:

```sh
tail -n 50 "$RUN/current.log"
```

- **No programmer:** verify USB host wiring and the CP210x kernel package. The
  Pager's internal CH347 and unrelated UARTs are excluded.
- **Cannot connect:** close other programs using the port, reconnect the
  programmer and check all three lights. The default uses the official web
  flasher's longer reset sequence. `RESET_MODE` in `payload.sh` can be set
  to `no_reset` for a programmer manually placed in download mode.
- **Dependency installation:** run `bash setup.sh` over SSH and inspect the
  package errors. A kernel version mismatch needs the correct Pager package
  feed/firmware, not an arbitrary third-party kernel module.
- **HTTPS/API errors:** check time, certificates and Internet access. GitHub's
  unauthenticated API quota can require waiting before another attempt.
- **Flash/verification failure:** success is never reported for a failed write.
  Reconnect and run again. Do not use partially programmed firmware.
- **Interrupted run:** when no flasher process is running, remove the empty
  `/mmc/root/loot/omg-flasher/.lock` directory if a power loss left it behind.

## SSH and development

For connection failures, exit the Pager payload and run this diagnostic over
SSH. It uses the same reset and connection path but does not upload a RAM stub,
download firmware or write flash. `--trace` records transmitted/received packets:

```sh
export PATH="/mmc/usr/bin:$PATH"
export LD_LIBRARY_PATH="/mmc/usr/lib:${LD_LIBRARY_PATH:-}"
python3 -u /mmc/root/payloads/user/general/omg-flasher/omg_flasher.py probe --port /dev/ttyUSB0 --trace > /tmp/omg-serial-trace.log 2>&1
cat /tmp/omg-serial-trace.log
```

The diagnostic resets the connected O.MG device. Run it when no flasher is active.

On the Pager, after setup, you can use the Python backend directly:

```sh
cd /mmc/root/payloads/user/general/omg-flasher
export PATH="/mmc/usr/bin:$PATH"
export LD_LIBRARY_PATH="/mmc/usr/lib:${LD_LIBRARY_PATH:-}"
python3 omg_flasher.py ports
python3 omg_flasher.py prepare --channel v3 --port /dev/ttyUSB0 --directory /tmp/omg-prepared
python3 omg_flasher.py summary --directory /tmp/omg-prepared
python3 omg_flasher.py flash --port /dev/ttyUSB0 --directory /tmp/omg-prepared --yes
```

For v4 select `--channel v4` during preparation and add `--elite-confirmed` to
the flash command. Add `--pre-erase` only when desired. `--yes` acknowledges
replacement of device firmware/configuration. Download-only validation requires
no serial device or esptool installation:

```sh
python3 omg_flasher.py download --channel v4 --directory /tmp/omg-download
```

Verified locally: both latest official release downloads, Git blob checksums,
prepared memory layouts, boot/config patches, simulated write/readback success
and failure, identity checks, and Bash syntax. **Physical Pager/USB programmer
flashing has not been tested in this workspace.**

## Sources and notices

- [O.MG WebFlasher](https://github.com/O-MG/WebFlasher)
- [Official firmware releases](https://github.com/O-MG/O.MG-Firmware/releases)
- [v4 compatibility notes](https://github.com/O-MG/O.MG-Firmware/releases/tag/v4.0-260221)
- [Hak5 Pager payload examples](https://github.com/hak5/wifipineapplepager-payloads)
- [esptool 4.8.1](https://github.com/espressif/esptool/tree/v4.8.1)

O.MG firmware/WebFlasher are owned by Mischief Gadgets LLC and retain their
original license, included as `UPSTREAM-LICENSE.txt`. No O.MG firmware is bundled
in the installation archive. esptool and its runtime downloads retain their
respective licenses. This is an unofficial Pager adaptation.
