📡 Digital Tails – v2

Persistent Device Detection Payload

If Recon tells you what is around you,
Digital Tails tells you what is staying.

Overview

Digital Tails is a passive Wi-Fi awareness payload designed to identify devices that appear to be persistently present near you over time, potentially indicating that a device is following, co-moving, or repeatedly appearing in your immediate area.

It does not capture handshakes, deauth, inject traffic, or interact with networks in any way.

Digital Tails works entirely from Recon’s passive scan data and is therefore:

Low noise

Low risk

Continuous

Suitable for walking or driving

Version 2 builds on the original concept by adding temporal intelligence and signal strength context, making results significantly more meaningful and actionable.

What Digital Tails Does (In Plain English)

Digital Tails:

Reads recent Wi-Fi device sightings from recon.db

Tracks how often the same MAC address appears

Observes signal strength consistency

Highlights devices that:

Appear repeatedly

Remain nearby

Do so across multiple scans

The goal is pattern detection, not identification.

Key Concepts
Persistence

A device that appears in many consecutive scans is more interesting than one that appears once.

Signal Strength

A strong or stable RSSI suggests physical proximity, not just background noise.

Time Window

Digital Tails does not rely on a single scan. It uses a sliding time window to build context.

Version Differences (v1 vs v2)
🔹 Digital Tails v1

Baseline visibility

Reads MAC + RSSI from Recon

Displays most recently seen devices

No memory beyond the current scan

No persistence scoring

Useful for:

Spot-checking nearby devices

Confirming Recon is working

Limitations

No way to tell if a device is “sticking around”

No prioritisation

No historical context

🔹 Digital Tails v2 (Current)

Behaviour-based detection

v2 introduces state, memory, and logic.

New Capabilities

Sliding scan window

Per-device persistence tracking

Rolling bitmask history

Strong-signal correlation

Priority flagging

Pager-friendly visual output

This transforms Digital Tails from a viewer into a detector.

How Digital Tails v2 Works (Logic Flow)
1️⃣ Data Source

Digital Tails reads from:

/mmc/root/recon/recon.db


Specifically:

wifi_device.mac

wifi_device.signal

No packets are captured directly by Digital Tails.

2️⃣ Scan Window

Each device is tracked across a rolling window:

Setting	Default
Scan interval	5 seconds
Window size	12 scans
Time covered	~60 seconds

Every scan shifts the window forward.

3️⃣ Bitmask Tracking (Core Logic)

Each MAC address is represented internally like this:

MAC | 010111011101 | RSSI


Where:

1 = device seen in that scan

0 = device not seen

Length = window size

This allows Digital Tails to answer:

“How often has this device appeared recently?”

Note:
No long-term storage — this is short-term situational awareness.

4️⃣ Persistence Scoring

The number of 1s in the bitmask = persistence score

Example:

010111011101 → 8 / 12


This means the device appeared in:

8 of the last 12 scans

5️⃣ Signal Strength Correlation

RSSI is used to distinguish:

Nearby devices

Passing/background devices

Default threshold:

STRONG_RSSI = -55 dBm

What Is Displayed on Screen

Each visible line represents one device.

Example output:

!! 9A:FD:71:C8  seen:9/12  rssi:-48  #######

How to Read the Display
Flags
Symbol	Meaning
!!	Persistent and strong signal (high interest)
!	Persistent but weaker signal
	Normal background device
MAC Address

Only the last 4 octets are shown to:

Save screen space

Improve readability

Reduce unnecessary exposure

Full MACs remain available in Recon.

Seen Count
seen:9/12


Means:

Device appeared in 9 of the last 12 scans

High likelihood of physical proximity or co-movement

RSSI
rssi:-48


Lower absolute value = stronger signal
(-48 is much closer than -78)

Signal Bars

Visual strength indicator:

#######


Quick at-a-glance proximity estimation.

Typical Interpretation Scenarios
Walking

Background MACs flicker (low seen count)

Devices moving with you rise to the top

Your own phone will often show as !! (future whitelist feature)

Driving

Passing APs appear briefly

Vehicles with onboard Wi-Fi may persist

Strong + persistent devices are rare and notable

Static Position

Home devices stabilise

Persistent external devices stand out clearly

What Digital Tails Does NOT Do

❌ Identify owners

❌ Decrypt traffic

❌ Track across reboots

❌ Store long-term history

❌ Perform active attacks

It is situational awareness, not surveillance.

Why Digital Tails v2 Is Better
Area	v1	v2
Persistence	❌	✅
Signal context	❌	✅
Noise reduction	❌	✅
Meaningful alerts	❌	✅
Walking / driving usable	⚠️	✅
Pager-friendly	⚠️	✅
Best Practices

Let it run continuously

Watch changes, not just flags

Combine with Recon for full visibility

Expect your own devices to appear (whitelist is next)

Future Development (Planned)

MAC whitelisting

Target alert companion payload

Bluetooth device correlation

Location fingerprinting

Multi-session persistence

Summary

Digital Tails v2 turns passive Wi-Fi noise into behavioural insight.


