# Quartermaster for the WiFi Pineapple Pager

Wardrive Wi-Fi, Bluetooth and LoRa mesh nodes from the Pager, with WiGLE logs, uploads, Drive Alerts and Recon.
It is the same Quartermaster that runs on the M5Stack CardputerZero, with screens drawn for the Pager's wide display
and controls made for the D-pad and the two buttons.

![Wardrive](screenshot.png)

## What it does

- **Wi-Fi wardriving** from the Pager's own monitor radio (PineAP's `wlan1mon`) on 2.4, 5 and 6 GHz. Quartermaster
  only listens: PineAP keeps its channel hopping and keeps running.
- **Bluetooth LE wardriving** from the Pager's Bluetooth radio. It only listens and never connects or pairs.
- **LoRa mesh nodes** (Meshtastic and MeshCore) and LoRaWAN, from a USB LoRa radio that is found by itself:
  - MeshToad, MeshStick, the Glytch Mesh Mod, RAK19714, uMesh and other CH341 sticks (USB `1a86:5512`). A free stick
    is driven directly and listens on Meshtastic, MeshCore and LoRaWAN in turn.
  - A stick or radio that `meshtasticd` already runs on the Pager is read through `meshtasticd` and is left in its care.
  - A Meshtastic board on USB (Heltec, LilyGO, RAK4631 and others) is read through its own firmware. Nothing is sent
    and no setting is changed.
- **USB Wi-Fi adapters** plugged into the Pager (through a hub) wardrive too, as on the CardputerZero.
- **GPS** from a USB GPS, set up by itself. When the Pager's GPS setting does not hear one, Quartermaster tries each
  USB serial port at the usual speeds through the Pager's own GPS setup, as picking it under Settings > GPS would.
  The Pager's status bar shows that GPS too.
- **ADS-B aircraft** on a tile of their own, from an RTL-SDR stick. The first time a stick is plugged in, Quartermaster
  asks to install `rtl-sdr` from the Pager's package feed.
- **WiGLE CSV logs** in `/root/loot/quartermaster`, with uploads to WiGLE, WDGWars and Wardrift.
- **Drive Alerts** for Flock cameras, Axon body cameras, Meta glasses and more, with buzzer tones and vibration.
- **Recon** of nearby Wi-Fi and Bluetooth devices, with the lists from SquachWatch.
- **Quartermaster Nodes** added by hand under Settings > Nodes.
- **Biscuit node mode**: pair the Pager with a Biscuit or Biscuit Pro and it scans 6 GHz for the Biscuit.

## Install

1. Copy this folder to `/root/payloads/user/reconnaissance/quartermaster/` on the Pager.
2. Open **Payloads > Reconnaissance > Quartermaster** on the Pager.
3. The first time, Quartermaster asks to install `python3`, `python3-pillow` and `python3-pyserial` from the Pager's
   package feed to its storage (`opkg -d mmc`). The Pager needs internet for this. With an RTL-SDR stick plugged in,
   it also asks to install `rtl-sdr`. Nothing else is downloaded.

## Controls

| Button | What it does |
| --- | --- |
| D-pad | Move. Held arrows repeat. |
| Green | Open or choose. On the wardrive screen it stops and saves. |
| Hold green | Actions for this screen. |
| Red | Back. On a Drive Alert it hides the alert. |
| Hold red for 2 seconds | Leave Quartermaster and give the screen back to the Pager. |

The screen stays lit while Quartermaster runs. To let it turn off, pick a time under **Settings > Screen timeout**.
Any button wakes it, and that press does nothing else.

## Upload keys

Keys are never written in `payload.sh`. Enter them under **Keys** on the Pager, or open **Keys > Phone setup** and
scan the QR code with a phone on the same network.

Picking a key opens the on-screen keyboard. Move with the D-pad and press green to type the key under the cursor.
The bottom row switches to capitals (ABC) or symbols (#+=) and has space, delete and Done. Red deletes the last
character, or goes back when the field is empty. Hold green to save.

## Quartermaster Nodes

Node firmware does not come with this payload, as payloads hold no binaries. Flash a node from a computer at
https://valleytechsolutions.github.io/Quartermaster/flasher/, then plug it into the Pager and add it under
**Settings > Nodes**.

## Biscuit node mode

The **Biscuit** tile on the menu makes the Pager a 6 GHz node for a Biscuit or Biscuit Pro. The Biscuit logs
everything with its own GPS; the Pager adds the 6 GHz band.

It works exactly like CodeHedge's Biscuit Pager Node payload. There is no pairing on the Pager: the Biscuit finds it
and adds it.

1. On the Biscuit, set node mode to **Extended**. Secure node mode does not take Pager nodes, and the Biscuit needs
   firmware v1.7.0 or newer, the release that added Pager nodes.
2. On the Pager, open **Biscuit** and press green. The tile shows **Waiting**.
3. In the Biscuit Manager app, search for nodes. The Pager shows up as a **Pager** node. Add it there. The tile shows
   **Joined**.
4. Start a wardrive on the Biscuit. The tile shows **Scanning** and the counters climb.
5. Press green on the Biscuit screen to stop node mode. Red goes back to the menu and node mode keeps running.

While node mode runs:

- The Pager comes up on the Biscuit as a Pager node (`Pager:v1.1.0`), and it sends only what CodeHedge's payload
  sends, with the same timings. It says `Pager:v1.1.0` again when the Biscuit adds it or gives it a job, and every
  30 s, so the Biscuit always shows it as a Pager.
- It scans 6 GHz only: the 15 main channels on three sweeps and all 59 on the fourth, 110 ms each. About once a
  second it goes back to 2.4 GHz channel 6 for 150 ms to talk to the Biscuit, and it never reports a network heard
  there.
- If the Biscuit stops answering for 20 s, the Pager waits to be found again.
- PineAP stops hopping `wlan1mon`. It gets its channels back when node mode stops or Quartermaster closes.
- Quartermaster's own wardrive and Recon wait until node mode is stopped.

## Files

| Path | What it is |
| --- | --- |
| `/root/loot/quartermaster/` | Logs, settings, keys and `errors.log` |
| `/tmp/quartermaster.log` | What the last start printed |

## Good to know

- Quartermaster never transmits on LoRa, never deauthenticates and never joins a network. The only frames it sends
  are Biscuit node messages on 2.4 GHz channel 6, while Biscuit node mode is on.
- Respect local laws and privacy. Upload only what you are allowed to collect.

## Source and credits

Source, tests and releases: https://github.com/valleytechsolutions/Quartermaster-Pager. The core is
[Quartermaster](https://github.com/valleytechsolutions/Quartermaster) by Valleytech Solutions, GPL-3.0.

- SquachWatch, created by Talking Sasquach, through
  [SquachWatch-CYD](https://github.com/skizzophrenic/SquachWatch-CYD) by skizzophrenic, GPL-3.0: detection types,
  address prefixes, evil twin, flood and burst checks, and the LoRaWAN frame layout.
- [Dragon Detector](https://github.com/valleytechsolutions/dragon-detector) by Valleytech Custom Solutions, MIT.
- [flock-you](https://github.com/colonelpanichacks/flock-you) by colonelpanichacks, MIT, with research by
  NitekryDPaul, DeFlockJoplin and wgreenberg.
- OUI Spy, Unified Blue and AXEOFF by colonelpanichacks, MIT. [nyanBOX](https://github.com/jbohack/nyanBOX) by
  jbohack, MIT. ESP32 Marauder by justcallmekoko.
- Biscuit node mode follows the [Biscuit Pager Node payload](https://github.com/hak5/wifipineapplepager-payloads/pull/396)
  by GSHD and CodeHedge, the reference for how it works. Biscuit is made by [BiscuitShop](https://biscuitshop.us).
- Meshtastic's device configurations for the CH341 LoRa sticks' pins, and its stream API.
