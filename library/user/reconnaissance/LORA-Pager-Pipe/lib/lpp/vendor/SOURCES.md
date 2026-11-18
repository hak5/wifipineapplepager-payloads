# Vendored source

`ch341.py` is an unmodified copy of
`src/openhop_core/hardware/ch341/ch341_async.py` from
[openHop Core](https://github.com/openhop-dev/openhop_core), commit
`e07722ea96093752ac8b3c6772d653f8b68224bf` (package version 1.1.3).
It is MIT licensed, copyright 2025 Lloyd Newton. The complete upstream
license is included as `LICENSE.openhop`.

Only this USB/SPI transport is included. This payload does not initialize
openHop's mesh router or transmit service. PyUSB source is separately included
at `../../usb` under its BSD 3-Clause license. The Pager supplies libusb as a
runtime package with its own license.
