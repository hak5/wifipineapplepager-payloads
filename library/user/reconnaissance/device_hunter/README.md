# Device Hunter (WiFi Pineapple Pager Payload)

**Device Hunter** turns your WiFi Pineapple Pager into a “hot/cold” tracker for nearby APs and Clients by watching **signal strength (dBm)** in real time. Manually enter in your target's MAC address or pick a target from recon results, then hunt it down using LED + sound + vibration feedback.

- **Author:** RocketGod — https://betaskynet.com and NotPike helped — https://bad-radio.solutions   
- **Crew:** The Pirates' Plunder — https://discord.gg/thepirates

---

## What it does

- Pulls the top nearby targets from **Recon (AP list)**
- Lets you **scroll and select** a target on the Pager
- Starts a Pineapple **monitor** for the target MAC
- Continuously displays the latest **signal level** and a simple bar meter
- Gives “hotter/colder” feedback:
  - **LED patterns** change by signal level
  - **Clicks** speed up as you get closer
  - **Vibration** kicks in at the strongest level

---

## Usage

1. Run the payload on the Pineapple Pager.
2. Select "Manual?" or "Scan?" to pick mode.
3. Use the Pager controls:
   - **UP/DOWN:** scroll targets
   - **A:** start hunting the selected target
   - **A (during hunt):** stop hunting

---

## Signal feedback levels

The payload maps signal strength to four levels:

- **Level 1 (weak):** below ~`-75 dBm`
- **Level 2 (medium):** `-75 dBm` to `-56 dBm`
- **Level 3 (strong):** `-55 dBm` to `-36 dBm`
- **Level 4 (hot):** `-35 dBm` or stronger (includes vibration)

A simple 20-char bar is printed each update:
- `################----` (stronger)
- `###-----------------` (weaker)

---

## Notes

- Uses `_pineap RECON APS limit=20 format=json` for target selection.
- Uses `_pineap MONITOR <mac> rate=200 timeout=3600` for tracking.
- The 'any' flag for _pineap MONITOR will scan for any packets not just from APs. 
- Cleanup is aggressive by design (kills monitor processes, clears temp files, resets examine lock, turns LEDs off).
