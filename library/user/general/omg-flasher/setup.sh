#!/bin/bash
# Install once on the Pager, over SSH or through payload.sh.
set -e
SETUP_HOME="${_PAYLOAD_HOME:-${PAYLOAD_HOME:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}}"
cd -- "$SETUP_HOME"
export PATH="/mmc/usr/bin:/mmc/usr/sbin:$PATH"
export LD_LIBRARY_PATH="/mmc/usr/lib:${LD_LIBRARY_PATH:-}"
opkg update
# User-space runtime on EMMC; kernel driver must match Pager firmware.
opkg -d mmc install python3 python3-pip ca-bundle
opkg install kmod-usb-serial-cp210x
python3 -m pip install --no-deps --no-compile --target ./lib -r requirements.txt
PYTHONPATH="$PWD/lib${PYTHONPATH:+:$PYTHONPATH}" python3 -c \
    'import esptool, serial, intelhex; assert esptool.__version__ == "4.8.1"; print("Dependencies ready")'
