📟 ENIsetup

External Network Interface Setup

What it does:
ENIsetup automatically finds your USB Wi-Fi antenna on the WiFi Pineapple Pager and sets it up as wlan2mon in monitor mode.

That’s it.

In plain terms

The Pager has internal antennas (wlan0, wlan1)

Your USB antenna can appear on different PHY numbers

ENIsetup:

Finds the USB antenna

Removes any old setup

Creates wlan2mon

Brings it up ready to use

You don’t need to guess PHY numbers or run manual iw commands.

When to use it

Run ENIsetup whenever you plug in a USB Wi-Fi antenna, especially before:

Antenna testing

Recon

Monitor / sniffing payloads

Result

After running ENIsetup:

iw dev


You will have:

wlan2mon  → USB antenna (monitor mode)


That’s the whole job.
Plug in → run → done.
