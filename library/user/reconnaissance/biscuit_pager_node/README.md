# Biscuit Pager Node

Turns the WiFi Pineapple Pager into a 6 GHz wardrive node for a Biscuit. The Pager
scans 6 GHz and sends what it hears to the Biscuit over ESP-NOW, and the Biscuit adds
the networks to the phone's wardrive like any other node.

The Pager is a scan-only node: it takes no channel lists, OTA updates or attack
commands from the Biscuit.

## Install

Copy this folder to the Pager at:

```
/root/payloads/user/reconnaissance/biscuit_pager_node/
```

Run "Biscuit Pager Node" from the Reconnaissance payloads. Press A to stop; the Pager
then shows how many networks it sent.

## Dependencies

Needs Python 3.11: `python3-base` on the root filesystem and `python3-light` on the SD
card (`opkg install -d mmc python3-light`). If Python is missing and the Pager has
internet, the payload offers to install it (about 4 MB, log in `/tmp/biscuit_opkg.log`).

## Biscuit setup

- Put the Biscuit in **Extended** node mode. The Pager will not join a Biscuit in
  Secure mode.
- The Biscuit needs firmware with 6 GHz node support. On older firmware the Pager
  holds the networks it finds and says the Biscuit firmware is too old.

