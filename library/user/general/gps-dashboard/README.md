# GPS Dashboard

**GPS Dashboard** is a live, auto-refreshing readout of everything gpsd
currently knows: connection/fix status, satellite constellation breakdown,
position, speed and heading, and UTC time.

- **Author:** KJ4M
- **Version:** 1.0

## Why?

[GPS Checker](../gps-checker) tells you *why* GPS isn't producing a fix.
Once it is working, GPS Dashboard gives you a live view of what it's
actually seeing - useful for confirming position while wardriving, watching
a fix improve as you get a clearer view of sky, or just checking what your
GPS currently reports without re-running a check by hand.

## Usage

Run the payload. It samples gpsd and logs one block per sample, refreshing
roughly every 3-4 seconds (a fast, bounded gpsd sample - typically ~1-2s -
plus a short window to check for the exit button press):

```
SEQ 42
[2026-08-11 02:38:33 UTC] FIX: 3D
Lat/Lon: 33.464887, -86.612453
Speed: 4.3 km/h  Heading: 184° (S)
Sats: GPS 5/8 used  GLONASS 2/3 used
```

Each block scrolls onto the log rather than replacing the previous one
(the Pager's payload console doesn't support redrawing in place), so the
incrementing **SEQ** number is there to make it obvious at a glance that
the payload is still actively updating and hasn't frozen.

Before a fix, it still shows connection and satellite state, with position,
speed, heading, and the UTC timestamp blanked. If gpsd isn't reachable, or
no GPS device is attached, it says so instead of showing stale data.

Press **B** to exit.

This payload only displays GPS state - it doesn't restart gpsd or diagnose
problems. If GPS isn't working at all, run **GPS Checker** first.
