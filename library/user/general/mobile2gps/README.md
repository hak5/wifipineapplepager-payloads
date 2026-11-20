# Mobile2GPS

Use your phone as the WiFi Pineapple Pager's GPS for wardriving. Connect to the Pager's Management AP and share your location through a web page. No phone app or separate GPS receiver needed.

Requires Pager firmware **2.0.0 or newer**.

## Installation

Install directly on the Pager through:

**Pager Portal > Payloads > Get Payloads > User Payloads > general > Mobile2GPS > Install**

This downloads the payload script but not the server binary. Running the payload will prompt you to download the server binary. The Pager needs internet access for the download.

Alternatively, [build the server binary yourself](#building) or download it from [Releases](https://github.com/ryanpohlner/mobile2gps/releases/), then copy `Mobile2GPS` to `/mmc/root/payloads/user/general/Mobile2GPS/` on the Pager.

## Using Mobile2GPS

1. Open **Mobile2GPS** under **Payloads > General** on the Pager and select **Start server**.
2. Enable the Pager's Management AP and connect your phone to it.
3. Open [https://172.16.52.1:1993](https://172.16.52.1:1993) in your phone's browser. The server uses a self-signed certificate, so accept the certificate warning for this address.
4. Press **Start** on the page and allow location access. Enable Precise Location if your phone offers it.
5. Select **GPS status** in the payload menu to check the coordinates reported by the Pager's selected GPS source.

Keep the page open in the foreground. Turn on **NoSleep** to help prevent the screen from locking; switching apps or locking the phone can interrupt updates.

**Exit (server stays on)** closes the menu while sharing continues. When finished, select **Stop server** to shut down Mobile2GPS and restore the previous GPS selection. GPS mode, serial device, and baud rate are configured automatically.

## Status and troubleshooting

`OK` means the phone has a fresh location with reported accuracy of 100 metres or better, and uploads to the server are succeeding.

- **POOR ACCURACY:** The reported accuracy is worse than 100 metres, so the position is marked invalid. Check Precise Location and try moving outdoors.
- **NO FIX:** No fresh location is available. Check the browser's location permission and keep the page open.
- **PAGER LINK ERROR / PAGER TIMEOUT:** Check that the server is running and your phone is still connected to the Management AP.

Locations expire after three seconds without fresh data. Old positions are discarded rather than saved for later upload.

If your phone keeps disconnecting, check whether it is switching to another Wi-Fi network. Choose to stay connected to the Management AP even if the phone reports no internet access.

## Building

Install [Go](https://go.dev/dl/) 1.21 or newer on your computer, then run from the project directory:

Windows (PowerShell):

```powershell
.\build.ps1
```

Linux / macOS:

```sh
make build
```

Both produce a `Mobile2GPS` binary for the Pager's MIPS little-endian, soft-float architecture.

## How it works

The Go server receives browser coordinates over HTTPS and converts them to NMEA GPRMC sentences. It feeds these through a virtual serial device to gpsd, using `GPS_CONFIGURE` to select gpsd as the Pager's GPS source.

## Acknowledgements

- [iphone-gpsd](https://spench.net/drupal/software/iphone-gps) by Balint Seeber
- [NoSleep.js](https://github.com/richtr/NoSleep.js) by Rich Tibbett

## Support me

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/ryanpohlner)

