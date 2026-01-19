# [mobile2gps](https://github.com/ryanpohlner/mobile2gps)

A payload for the Hak5 WiFi Pineapple Pager that lets you use your mobile phone as the Pager's GPS.

## How It Works

mobile2gps creates a bridge between your mobile phone's location data and the Pager's GPS system:

1. **Fake GPS Device**: The server creates a pseudo-terminal (PTY) that acts as a fake serial GPS device
2. **gpsd Integration**: The server starts `gpsd` (GPS daemon) and points it to the fake GPS device
3. **HTTPS Server**: A web server runs on port 1993, serving a web page that uses the browser's Geolocation API
4. **Connectivity**: Your mobile phone connects to the Pager's Management AP, allowing it to access the web server at `https://172.16.52.1:1993`
5. **Data Conversion**: Your mobile browser sends GPS coordinates to the web server, which converts them to NMEA GPRMC sentences
6. **GPS Feed**: The NMEA sentences are written to the fake GPS device, which gpsd reads and makes available to the Pager's GPS system

## Installation

1. Download the payload (using `git clone`, the [ZIP](https://github.com/ryanpohlner/mobile2gps/archive/refs/heads/main.zip), or a payload downloader on the Pager)
2. [Build](#building) or [download](https://github.com/ryanpohlner/mobile2gps/releases/) the `mobile2gps` server binary and place it in the payload folder
3. Copy  `payload.sh`, `mobile2gps` (the binary), and `index.html` to `/mmc/root/payloads/user/general/mobile2gps` on your Pager

## <a name="building"></a>Building

Pre-compiled server binaries are available [here](https://github.com/ryanpohlner/mobile2gps/releases/).

It is not recommended to try building on the Pager.

This folder contains build scripts that automatically configure cross-compilation for the Pager's architecture (MIPS 24KEc soft-float).

**Prerequisites:** Go 1.21 or later must be installed on your computer. 

### Windows

1. Install [Go](https://go.dev/dl/) if you haven't already
2. Open PowerShell in the project directory
3. Run the build script:
   ```powershell
   .\build.ps1
   ```

### Linux / macOS

1. Install Go if you haven't already:
   ```bash
   # Ubuntu/Debian
   sudo apt-get install golang-go
   
   # macOS (using Homebrew)
   brew install go
   
   # Or download from https://go.dev/dl/
   ```
2. Build using the Makefile:
   ```bash
   make build
   ```

## FAQ / Issues

**Q: The connection between my phone and the Pager is unstable.**

A: The Pager's Management AP does not have internet access (unless it is also connected to a network with Client Mode). Without internet access, your phone might switch to a different known network you are in range of. How you handle this problem will vary. iOS will pop-up a prompt to "Keep Trying Wi-Fi" to stay connected to the Management AP. You may want/need to delete the known network(s) to prevent switching. 

If the Pager is in Client Mode (connected to a network, like your home Wi-Fi) while you are connected to the Management AP, going outside the range of the client network may also trigger your phone to try switching networks.

**Q: mobile2gps reports a valid position but the Pager's GPS settings shows my position is 0, 0.**

A: Try restarting the Pager and run mobile2gps again.

**Q: Do I need to configure the Serial Device or Baud Rate on the Pager?**

A: No, mobile2gps interacts directly with gpsd. These settings are ignored and have no effect.

## Acknowledgements

- **iphone-gpsd** by Balint Seeber - https://spench.net/drupal/software/iphone-gps
- **NoSleep.js** by Rich Tibbett - https://github.com/richtr/NoSleep.js

## Support me

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/ryanpohlner)

