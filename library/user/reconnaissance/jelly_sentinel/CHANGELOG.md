# Jelly Sentinel — Changelog

## v1.1 (2026-05-02)

### Bug Fixes

**Router credential false positive**
- Replaced naive HTTP status code check (`200`/`302` = success) with vendor-specific authentication verification
- TP-Link: POSTs to stok API and validates session token in response
- ASUS: POSTs to `login.cgi` and checks for `asus_token` cookie
- Netgear: Validates response body contains dashboard content, not a login page
- MikroTik: Checks for RouterOS/webfig content in response body
- Generic fallback: Requires body to contain dashboard keywords AND not contain login form keywords

**PMF (Protected Management Frames) false positive**
- WPA3/SAE networks mandate PMF implicitly — no longer flags PMF as missing when connected to a WPA3 AP
- PMF check now scoped to connected AP's BSSID only, not all APs in scan range
- Eliminates false positives from neighbor WPA2 networks without PMF

**DNS rebinding false positive**
- Replaced `rebind-test.example.com` (nonexistent domain, always NXDOMAIN) with real external domains (`doubleclick.net`, `google.com`, `example.com`)
- Only fires if a real external domain actually resolves to a private RFC1918 IP
- Renamed finding to "DNS Rebinding Confirmed" to distinguish from theoretical risk

**AP count showing cumulative database total**
- Fixed SQL query to scope AP count to current scan session only using `time` unix epoch column
- Falls back to last 5 minutes if scan window returns zero results
- Eliminates 85,000+ AP counts from cumulative wardriving history in recon DB

**OUI vendor lookup returning blank**
- `whoismac` outputs a leading newline before `VENDOR:` line, causing `head -1` to return empty
- Fixed to use `grep -m1 "^VENDOR:"` to find the vendor line regardless of leading whitespace
- Strips `VENDOR: ` prefix and `(UAA)`/`(MAL)`/`(IAB)` suffixes for clean vendor names
- Worked around `whoismac` TTY detection issue (silent in pipe, works to file) using temp file pattern

**EasyMesh/AP nodes misclassified as ROUTER**
- Networking vendor OUI match (TP-Link, ASUS, Netgear, etc.) no longer automatically classifies a device as ROUTER
- Vendor-based ROUTER classification now requires open management ports (80/443/8080/8443) to confirm
- Only the actual gateway IP is unconditionally classified as ROUTER
- Eliminates false ROUTER classification of EasyMesh nodes, range extenders, and managed switches
