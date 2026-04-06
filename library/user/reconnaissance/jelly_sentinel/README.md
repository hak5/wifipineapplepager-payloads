JELLY SENTINEL
Authorized Network Security Assessment for Home \& SMB Environments
by hackagocthi

WHAT IT DOES

Jelly Sentinel is a native network security assessment tool built for the WiFi Pineapple Pager.

Drop it on a network, run it, and walk away with a structured, scored report covering:

* devices
* vulnerabilities
* misconfigurations
* network anomalies

No laptop required.

Built for pentesters, IT consultants, and security-conscious users.



AUTHORIZATION REQUIRED

Jelly Sentinel is designed for authorized security testing only.

The tool enforces a consent step before execution.
Use only on networks you own or have permission to assess.



HOW IT WORKS

Jelly Sentinel runs multiple phases to build a complete network picture:

Phase 0 — Preflight
Battery check, GPS capture (if available), interface validation.

Phase 0B — Authorization
Tester + target input, scan mode selection, explicit consent required.

Phase 1 — WiFi Audit
Open networks, WPS detection, hidden SSIDs, PMF and isolation checks.

Phase 2 — Device Discovery
Fast subnet scan (nmap -sn), device inventory, vendor lookup, IPv6 discovery.

Phase 3 — Fingerprinting + CVE + SSL
Port scanning, banner extraction, CVE matching, SSL inspection.

Phase 4 — Risk Checks
Default credentials, admin panels, Telnet/FTP/SMB/SNMP, RTSP/MQTT/SIP/TR-069, DNS rebinding.

Phase 5 — Bluetooth Scan
Detects nearby devices and flags discoverable ones.

Phase 6 — Passive Traffic Analysis
Traffic capture, DNS analysis, top talkers, anomaly detection.

Phase 7 — Delta Comparison
Tracks new findings, resolved issues, and new devices.

Phase 8/9 — Reporting
Executive summary, CVSS-weighted score, structured findings, CSV export.



CVE DETECTION

HIGH   = exact vulnerable version
MEDIUM = likely affected product
LOW    = vendor observed

Confidence affects severity and wording to reduce false positives.



RISK SCORING

Score range: 0–100

75–100 = CRITICAL
50–74  = HIGH
25–49  = MEDIUM
0–24   = LOW



SCAN MODES

Quick   = fast scan, minimal checks
Full    = complete assessment
Stealth = minimal footprint



LOOT STRUCTURE

/root/loot/jelly\_sentinel/<timestamp>/

Includes report.txt, executive\_summary.txt, findings.csv, fingerprint.txt, devices.txt,
wifi.txt, bluetooth.txt, ssl\_certs.txt, banner\_cves.txt, dns\_queries.txt,
top\_talkers.txt, traffic.pcap, ipv6.txt, raw.txt



NOTES

* Ensure wlan0cli is connected
* Uses native Pineapple tools only
* No external dependencies



REQUIREMENTS

WiFi Pineapple Pager



DISCLAIMER

For authorized testing only.

