# Power Aware Display

A native WiFi Pineapple Pager menu and independent screen timer with separate
battery and external-power profiles. Defaults: **60 seconds on battery** and
**Never on external power**. Changes do not restart the Pager UI or PineAP.

## Installation and first use

Install this complete directory as
`/root/payloads/user/general/Power-Aware-Display/`. Keep `input-watch` executable.
No package downloads or compilation on the Pager are required.

1. Open **Payloads > General > Power Aware Display**.
2. Select **Calibrate power**. Follow the prompts to sample external USB power,
   then battery power. This takes six samples in each state. Reconnect USB when
   finished if desired. Calibration is required when no USB online sensor exists.
3. Set **Battery timeout** and **External timeout**. Use **0 for Never**, or
   **15 to 86400 seconds**. Defaults are 60 and 0.
4. Select **Enable**. This installs the bundled OpenWrt init script, starts the
   worker and enables it at boot. Simply opening the payload does not enable it.
5. Open **Status** to check Service, Boot, power, configured and active timeouts,
   idle seconds, physical event count, observer health and the current phase.

Status is a snapshot. Close and reopen it to refresh. **Recent events** shows
power transitions, timeout changes, sleep and game pauses. The menu can be closed
while the service runs. Edits apply automatically and start a fresh idle period.

**Disable** stops the worker and observer, disables boot startup, and returns
control to the native display timers. Native brightness and timeout preferences
are never changed. Disable before removing the payload directory. Configuration
is retained so the payload can be enabled again without recalibration.

## Requirements and behavior

- WiFi Pineapple Pager with OpenWrt/procd, Bash, curl and the native display API.
- `/dev/input/event0` for physical buttons; a prebuilt static MIPS32r2 little-endian
  Linux observer is included alongside its C source and build command.
- Root execution, as with the Pager's normal payload launcher.
- The inspected firmware exposes `/sys/class/power_supply/bq27546-0` and
  `/sys/class/backlight/backlight_pwm/brightness`.

The observer opens the button device without `EVIOCGRAB`. Physical presses and
held-button repeats reset a monotonic inactivity timer without consuming the
native controls. Only timestamps and an event count are stored, never key names.
The worker calls the native wake API every two seconds while the screen should
stay on, then requests native sleep at the deadline. It does not synthesize
button events, write to the framebuffer, edit firmware or restart services.

Periodic wake calls prevent the firmware's own cached timers from expiring before
the selected deadline. Saving display preferences through the firmware API alone
did not reliably update its active timers, which is why this payload keeps its
own timer. If the native UI is absent or suspended by a game, display control
pauses and resumes with a fresh interval when the UI returns. A failed observer
or invalid runtime configuration keeps the screen awake instead of blanking it
without reliable activity information. The implementation polls once per second.

## Limitations

- **Virtual Pager buttons while the screen is awake do not reset this timer.**
  Those events bypass Linux evdev. A virtual button that wakes an already sleeping
  native screen starts a fresh interval. Physical Pager controls are the tested
  activity source. Use Never when working exclusively through Virtual Pager.
- Only UI absence/suspension is used to detect display ownership by games.
  Games that use another mechanism need separate compatibility testing.
- The tested Pager has no separate AC/USB online sensor. Power detection is
  therefore an inference from owner-calibrated current readings. Different
  chargers, accessory loads or stale gauge readings can affect it.
- A full battery or a false charging flag does not establish cable presence.
  The detector prefers an explicit USB/AC online sensor when one is available.
  Otherwise it rejects overlapping calibration ranges, polls current every three
  seconds, and requires three consistent readings before switching profiles.
  Unknown readings use the battery timeout.
- Firmware APIs, input paths and backlight behavior may differ across versions.
  Validate on your Pager before relying on the service. No reboot was performed
  during acceptance testing; startup links and service supervision were verified.

## Files and terminal commands

Persistent configuration: `/etc/pager-power-display/{calibration,timeouts}`.
Temporary state and bounded recent events: `/tmp/pager-power-display/`.
Init script: `/etc/init.d/pager-power-display`.
No network connection is used; display requests use `/tmp/api.sock` locally.

```sh
bash /root/payloads/user/general/Power-Aware-Display/controller.sh status
bash /root/payloads/user/general/Power-Aware-Display/controller.sh events
bash /root/payloads/user/general/Power-Aware-Display/controller.sh settings 60 0
bash /root/payloads/user/general/Power-Aware-Display/controller.sh disable
```

The installer refuses to overwrite an unrelated init script or follow an init
symlink. Install the payload in a path without spaces or shell characters.
After an update, Disable then Enable to restart the worker on the new code.

## Build and tests

The included observer was built with Zig 0.13.0. It is static and needs no extra
runtime libraries. Rebuild from this directory:

```sh
zig cc -target mipsel-linux-musl -mcpu=mips32r2 -msoft-float \
  -std=c11 -O2 -static -s -Wall -Wextra -Werror input-watch.c -o input-watch
bash tests/controller-test.sh
```

Tests cover calibration, charging/full/battery inference, invalid values,
timeout persistence, exact idle boundaries, activity reset, observer failure,
fresh init installation and overwrite protection. They use temporary fixtures
and do not modify host services.

Live acceptance on one Pager:

- Never maintained full brightness beyond 80 seconds.
- A temporary 60-second external profile slept at the idle deadline and remained
  asleep. The external profile was then restored to Never.
- A physical green press opened Status normally, incremented the observer's
  event count and reset the worker's inactivity counter.
- Both native timeout editors opened and saved their defaults; the battery
  numeric keyboard was opened and confirmed.
- Disable stopped the worker and observer without changing stored native display
  settings. Enable started the worker and created the boot startup links.
- Power detection was checked with owner-confirmed battery, charging and
  plugged-in/full states. This is not a claim of testing on all firmware versions.

Author: Christophe ([gevrey](https://github.com/gevrey)).
See LICENSE for this payload's code. Bundled binary dependency notices are
in `licenses/` (musl and Zig). The supplied binary was rebuilt from the included
source with the command above and compared byte for byte.
