# HIDX StealthLink

This payload is the Wifi Pineapple Pager implementation of the HIDX Stealthlink Client for O.MG Devices. It allows for stealthy remote access to host machines - even airgapped systems.  The O.MG connects to the Pager's wireless network, and the Pager acts as a bridge from your terminal device (smartphone, laptop, etc.) to the target system.

## O.MG Device & Host Setup

Follow the instructions for setting up the O.MG Device and Host system with HIDX Stealthlink:

- Windows: https://github.com/O-MG/O.MG-Firmware/wiki/HIDX-StealthLink---macOS-Python---Shell
- macOS: https://github.com/O-MG/O.MG-Firmware/wiki/HIDX-StealthLink---macOS-Python---Shell
- Linux: https://github.com/O-MG/O.MG-Firmware/wiki/HIDX-StealthLink---Linux---Shell

## Pager Setup

You will need to run the Management Network AP for the O.MG Device to connect to. Take care that the SSID and password match what is configured on the O.MG Device.

## Workflow
1. Connect the configured O.MG Device to the target system via USB.
2. Run the HIDX code on the host system.
3. On the Wifi Pineapple Pager, run this payload.  Once the payload is running, the O.MG Device should connect to the Management Network AP, and the HIDX Stealthlink Client on the pager will connect to the O.MG Device. You will receive a pager alert when the connection is established.
4. SSH into the pager and `tmux a -t hidx` to access the HIDX Stealthlink Client session and interact with the target system remotely.

# Resources

- [O.MG Wiki](https://github.com/O-MG/O.MG-Firmware/wiki)

- [O.MG Stealthlink Firmware & Tools - GitHub](https://github.com/O-MG/O.MG-Firmware)

- [O.MG devices - Hak5](https://hak5.org/products/omg-cable)