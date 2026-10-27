# Known-Camera Ground-Truth Capture

**Goal:** park within radio range of a *confirmed* Flock camera and record exactly
what it broadcasts — WiFi SSID + OUI, and any BLE manufacturer ID / name — so we
can add its real signature to `oui_list.txt` and know the detector will fire.

**Why stationary, not a drive-by.** The Aug 28 drive produced nothing usable for
two reasons this procedure removes:

- **GPS smearing.** On that drive, fixed anchors (Whole Foods store APs) were
  smeared across ~5.8 mi because GPS updated slower than we drove. Parked at one
  spot there is a single fix, so every detection is correctly located.
- **BLE dwell.** BLE range is ~10–30 m and the scanner uses 8 s windows. Driving
  past a pole you're in range for a couple of seconds — often less than one
  window. Parked, you get dozens of windows, which is the only fair test of
  whether the camera emits *any* detectable BLE.

The method is **baseline subtraction**: capture a control location with no camera,
then the camera location. Whatever is new, strong, and persistent at the camera
site — and absent from the baseline — is the camera.

Pager SSH target used throughout: `root@172.16.52.1`. Loot lives at
`/mmc/root/loot/` on the device.

---

## 0. Pick the target (before you leave)

1. Find a confirmed Flock camera near you on <https://deflock.me> (community map),
   or one you can positively identify by sight — a solar panel + small camera head
   on a slim pole, usually facing a traffic lane.
2. Note a legal, safe **parking spot within ~30 m line-of-sight** of it, and a
   **baseline spot** a few hundred meters away with no camera in view.
3. Only observe passively from a public vantage. Do not touch, obstruct, or
   attempt to connect to the device — this is signal reconnaissance of what it
   broadcasts, nothing more.

---

## 1. Pre-flight (do this parked, engine on, before relying on anything)

```sh
# 1a. Confirm exactly ONE Flock_You is running (the UI runs payloads from a
#     /tmp copy, so a stale instance is easy to miss and will fight for the
#     BLE adapter). Expect zero or one.
ssh root@172.16.52.1 'ps w | grep -E "flock|hcitool|hcidump" | grep -v grep'

# 1b. Confirm a SOLID 3D GPS fix BEFORE capturing. Do not proceed on a 2D/no fix
#     — a bad fix is what ruined the last run.
ssh root@172.16.52.1 'gpspipe -w -n 20 | grep -m1 "\"mode\":3" && echo "3D FIX OK" || echo "NO 3D FIX — wait for open sky"'

# 1c. Confirm WiGLE recon is logging (pineapd --recon).
ssh root@172.16.52.1 'ps w | grep -E "pineap.*recon" | grep -v grep'
```

If GPS is not a 3D fix, wait with clear sky overhead until it is. Everything
downstream depends on this.

---

## 2. Baseline capture (control, no camera)

At the **baseline spot**, from the Pager UI:

1. Tap **wardrive_activate** (primes GPS hot-start, confirms WiGLE — it configures
   and exits).
2. Tap **Flock You (v9.19)** — starts BLE scanning + `flock_alladv_<ts>.csv`.
3. Sit **5 full minutes**. Note the wall-clock start/stop time.
4. Stop Flock You from the UI.

Record on paper / phone:

```
BASELINE  site=<desc>  gps=<lat,lon>  start=<HH:MM>  stop=<HH:MM>  camera=NONE
```

Note the newest `flock_alladv_*.csv` and newest `wigle-*.csv` filenames now — the
camera capture's files will be newer.

---

## 3. Camera capture (target)

Drive to the **camera spot**, park within range with the camera in sight.

1. Tap **wardrive_activate** again.
2. Tap **Flock You (v9.19)**.
3. Sit **10 full minutes** — longer than baseline, to give BLE many windows and
   let WiFi log the AP repeatedly at one fix.
4. Watch/feel the Pager: v9.19 buzzes + lights on any MANUF/OUI/NAME hit. A buzz
   here is itself a positive (note the time).
5. Stop Flock You.

Record:

```
CAMERA  site=<desc>  gps=<lat,lon>  start=<HH:MM>  stop=<HH:MM>
        camera=<deflock id or "visual: pole at <intersection>">
        buzzed=<yes/no, times>
```

Repeat sections 2–3 for a second camera if you can — two positives beat one.

---

## 4. Pull the logs

```sh
cd ~/repos/PineapplePager

# WiFi (WiGLE) — grab anything newer than your baseline start
ssh root@172.16.52.1 'ls -1 /mmc/root/loot/wigle/wigle-*.csv | tail -4'
scp 'root@172.16.52.1:/mmc/root/loot/wigle/wigle-<CAMERA_TS>*.csv' loot/wigle/

# BLE diagnostic — the all-advert logs for baseline and camera
scp 'root@172.16.52.1:/mmc/root/loot/flock_you/flock_alladv_<BASELINE_TS>.csv' loot/flock_you/
scp 'root@172.16.52.1:/mmc/root/loot/flock_you/flock_alladv_<CAMERA_TS>.csv'   loot/flock_you/

# The detection output (if it buzzed, the hit is here)
scp 'root@172.16.52.1:/mmc/root/loot/flock_you/flock_hcitool_<CAMERA_TS>.txt' loot/flock_you/
```

---

## 5. Isolate the camera's fingerprint

### 5a. Did the detector already fire? (best case)

```sh
grep -v '^v9' loot/flock_you/flock_hcitool_<CAMERA_TS>.txt
```

Any `DECT:` line is a confirmed hit — it already carries MAC, signal type, and
RSSI. If so, the camera's OUI is the first 3 octets of that MAC. Skip to step 6.

### 5b. WiFi: what SSID/OUI appeared only at the camera?

```sh
CAM='loot/wigle/wigle-<CAMERA_TS>....csv'
# Strongest APs at the camera site (parked = these are physically near you)
awk -F, 'FNR>2 && length($1)==17 {print $7"\t"$1"\t"$2}' "$CAM" \
  | sort -rn | head -30
```

Look for: an SSID matching `Flock-<hex>`, or containing `Falcon`/`Solar`/`Cam`;
a strong RSSI (roughly -40 to -70 parked close); an OUI not already in
`oui_list.txt`. Cross out anything that was also strong in the baseline WiGLE file
(that's ambient, not the camera).

### 5c. BLE: subtract baseline from camera

```sh
B='loot/flock_you/flock_alladv_<BASELINE_TS>.csv'
C='loot/flock_you/flock_alladv_<CAMERA_TS>.csv'
# BLE MACs present at the camera but NOT at baseline, with manuf id + best RSSI
awk -F, 'NR>1{print $2}' "$B" | sort -u > /tmp/ble_base.txt
awk -F, 'NR>1{key=$2; if($4>r[key]||!(key in r)){r[key]=$4; mid[key]=$3; nm[key]=$5}}
         END{for(k in r) print r[k]"\t"k"\t"mid[k]"\t"nm[k]}' "$C" \
  | sort -rn > /tmp/ble_cam.txt
grep -vF -f /tmp/ble_base.txt /tmp/ble_cam.txt | head -30
```

A camera-attributable BLE device is: absent from baseline, strong and *persistent*
across the 10 min (re-seen, not a one-off passer-by), ideally with a distinctive
`manuf_id` or a `Flock`/`Penguin`/`Pigvision`/`FS Ext Battery` name. If nothing
survives this filter, that is itself the answer for this camera model: **it emits
no usable BLE, and WiFi is the only path** — record that result.

---

## 6. Add the confirmed signature to `oui_list.txt`

Only add a prefix you have **positively tied to a camera you identified** — a
wrong entry buzzes forever on innocent devices. Match the existing format
`OUI|CATEGORY|Label`:

```
# in payloads/library/user/reconnaissance/Flock_Detect/oui_list.txt
AA:BB:CC|FLOCK_VERIFIED|Flock Falcon WiFi (ground-truth <site>, <YYYY-MM-DD>)
```

Then re-check the drive data against the enriched list and redeploy:

```sh
./loot/flock_hits.sh   # re-scan all WiGLE loot with the new prefix
scp payloads/library/user/reconnaissance/Flock_Detect/oui_list.txt \
    root@172.16.52.1:/root/payloads/user/reconnaissance/Flock_Detect/oui_list.txt
```

Commit the change in `payloads/` and `loot/` with the site + date as provenance.

---

## Success criteria

- [ ] 3D GPS fix confirmed before each capture
- [ ] Baseline (no camera) + camera captures, times and coords logged on paper
- [ ] Camera physically identified (deflock id or photo), not assumed
- [ ] A signature that is present at the camera and absent at baseline — an SSID,
      an OUI, or a BLE manuf id/name — OR a documented "no usable BLE" result
- [ ] New prefix added to `oui_list.txt` as `FLOCK_VERIFIED` with provenance, and
      redeployed to the Pager

## Notes / gotchas

- Park legally and observe from a public vantage; capture only what is broadcast.
- If Flock You doesn't buzz but WiGLE logs a strong unknown SSID at the pole, the
  OUI path still wins — that's the expected outcome per the v9.19 field notes
  ("OUI is what catches Falcons; zero XUNTONG 0x09C8 across 1,477 devices").
- Keep the two captures close in time so the ambient RF background is similar —
  it makes the baseline subtraction cleaner.
