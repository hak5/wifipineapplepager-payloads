# Switch Evil Portal (WiFi Pineapple Pager)

This payload allows you to switch between installed Evil Portal captive portals at runtime using the WiFi Pineapple Pager UI.

It presents a numbered menu of available portals and updates the active portal instantly.

---

## Overview

Evil Portal normally serves content from a single fixed portal directory.

This payload works with a symlink-based portal layout:

`/root/portals/current -> /root/portals/<portal-name>`

By updating the `current` symlink, Evil Portal immediately begins serving a different captive portal **without restarting services or the device**.

### What This Payload Does

✔ Enumerates available portals in `/root/portals/`
✔ Prompts the user with a numbered selection menu
✔ Switches the active portal via Evil Portal’s init script
✔ Changes take effect immediately

## Requirements

- WiFi Pineapple Pager
- Evil Portal installed and working
- Multiple portals installed in `/root/portals/`
- A `current` symlink must exist: `/root/portals/current`
- Evil Portal init script must support: `/etc/init.d/evilportal switch <portal-name>`

> ## Important
> The switch command is not part of Evil Portal by default.
> See Notes below for details.

---

## Installation

Copy this payload directory to: `/root/payloads/user/evil_portal/switch_evil_portal`

The final layout should be:

```text
/root/payloads/user/evil_portal/
└── switch_evil_portal
    ├── payload.sh
    └── README.md
```

---

## Usage (Pager UI)

1. Open **payloads** → **user** → **evil_portal**
2. Launch **switch_evil_portal**
3. Select a portal number when prompted
4. The active captive portal updates instantly

---

## Example

If `/root/portals/` contains:

```text
Default/
google-login/
starbucks-login/
current -> Default
```

Selecting 2 will update: `current -> google-login`

---

## Logging

Portal switches are logged via syslog:

```bash
logread | grep evilportal
```

---

## Notes on Compatibility

This payload **requires an enhancement** to the Evil Portal init script that adds:

```bash
/etc/init.d/evilportal switch <portal-name>
```

That enhancement is **not included** in this payload repository.

For installation instructions and the init script patch, see:

[evilportal_switch](https://github.com/knight-scott/evilportal-switch)

---

## Author & Credits

- Evil Portal originally developed by newbi3 for WiFi Pineapple Mark VII
- Adapted for WiFi Pineapple Pager by PentestPlaybook
- Switch payload & helper concept by 0x4B

This payload is provided as an optional enhancement for advanced Evil Portal users.

---

## Resources

- [WiFi Pineapple Docs](https://docs.hak5.org/)
- [OpenWrt Documentation](https://openwrt.org/docs/start)
- [Hak5 Forums](https://forums.hak5.org/)
- [nftables Wiki](https://wiki.nftables.org/)

---
