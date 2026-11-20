# Biscuit Pager Node — GUI version

Extract the `biscuit_pager_node` folder into
`/root/payloads/user/reconnaissance/` (or its `/mmc/root/` equivalent).
Run **Biscuit Pager Node (GUI)**. If needed: `chmod +x payload.sh`.
The no-GUI payload can remain installed alongside this version; run only one
node at a time because they use the same radio.

The original splash appears at startup. A switches dashboard/details;
B or Power exits and restores the Pager service and radio configuration.
The dashboard shows unique networks seen, unique networks submitted, queued
network records, elapsed time, and sweeps. Details shows ACKs, TX errors,
repeated updates, held records, and tuning time.

## Setup

Python 3.11 with `python3-light` and `python3-ctypes` is required on MMC.
The launcher checks actual imports, includes MMC native library paths, and
offers installation. Only an explicit Yes proceeds. No, Cancel, blank output,
or a failed dialog exits before installation and before changing the radio.

The GUI uses [pagerctl](https://github.com/pineapple-pager-projects/pineapple_pager_pagerctl).
It discovers an existing upstream PAGERCTL installation, or offers to download
the wrapper and prebuilt MIPS library from that repository. This requires internet
access. If upstream does not provide the binary at the expected locations,
build/install PAGERCTL using its README, or copy `pagerctl.py` and
`libpagerctl.so` together into this payload's `lib/` folder. No upstream binary
is bundled in this ZIP. The download tracks upstream main.

Use Extended node mode and manager firmware supporting 6 GHz; start a wardrive
on the manager. Secure mode and old firmware have separate dashboard messages.

## Counter and connection meaning

Sent networks counts distinct BSSIDs submitted to the radio without a local TX
error. Updates TX includes repeat sightings. Neither proves manager ingestion.
Radio ACKs are short-window observations, not application acknowledgments.
The status becomes unverified after 10 seconds without a radio ACK. After
20 seconds without a previously observed ACK the node returns to discovery.
An assigned manager with no observed ACK stays unverified.
Channel changes are rapid; the stats sample may catch the home channel.
The scanner writes statistics every two seconds; the GUI reads them five times
a second. Stale statistics and node termination are shown explicitly.

Logs: `/tmp/biscuit_python.log`, `/tmp/biscuit_opkg.log`,
`/tmp/biscuit_pagerctl_install.log`, `/tmp/biscuit_gui.log`,
`/tmp/biscuit_node_gui.log`. Stats: `/tmp/biscuit_node_gui_stats.json`.

This build has not been exercised on Pager hardware. Display ownership,
physical buttons, radio timing and upstream native-library loading require a
device smoke test. The GUI uses the documented pagerctl Python API.
