# Curly - Web Recon & Vulnerability Scanner (WiFi Pineapple Pager Payload)

**Curly** transforms your WiFi Pineapple Pager into a portable web reconnaissance and vulnerability scanning tool using curl. Perfect for pentesting and bug bounty hunting on the go!

- **Author:** curtthecoder
- **Version:** 4.0

---

## What it does

Curly performs comprehensive web security testing using only curl (plus nmap for port scanning):

- **IP Geolocation Lookup** - Resolves target IP and queries ipinfo.io for location, ISP, timezone data
- **Protocol Availability Check** - Detects if site responds on HTTP, HTTPS, or both; checks for proper HTTP→HTTPS redirects
- **SSL/TLS Security Analysis** - Certificate expiration, TLS version detection, weak cipher identification, self-signed cert detection
- **DNS Record Enumeration** - A, AAAA, NS, MX, TXT, CNAME, SOA records + AXFR zone transfer attempts
- **Email Security Check** - SPF, DMARC, DKIM, and BIMI record analysis
- **Certificate Transparency (crt.sh)** - Discovers subdomains via CT logs; probes each for liveness
- **Port Scan** - nmap scan of web, service, and database ports with service identification
- **CSP Deep Analysis** - Evaluates Content-Security-Policy for unsafe directives and JSONP bypass vectors
- **Severity Scoring System** - All findings categorized as CRITICAL/HIGH/MEDIUM/LOW/INFO with summary report
- **Scan Time Tracking** - Estimated times before scans + actual elapsed time in final summary
- **Manual Verification Guides** - Step-by-step instructions on how to verify findings (XSS, SSRF, bypasses)
- **Content Verification System** - Validates actual file content to eliminate false positives on sites with catch-all routing
- **Parameter Discovery** - Tests 30+ common parameters for behavior changes, reflection, and pollution vulnerabilities
- **WAF/CDN Detection** - Identifies Cloudflare, Akamai, AWS CloudFront, Incapsula, Sucuri, ModSecurity
- **Technology Fingerprinting** - Detects web servers, CMS (WordPress, Drupal, Joomla), frameworks (React, Vue, Angular)
- **WordPress Version & Vulnerability Scanner** - Detects WP version via 6 methods, queries WPScan API for known CVEs, enumerates plugins/themes
- **WordPress Security Tests** - Auto-runs when WordPress detected: user enumeration, xmlrpc, debug logs
- **Information Gathering** - Headers, server fingerprinting, security header analysis
- **HTML Source Analysis** - Extracts emails, comments, API keys, internal URLs, TODOs
- **Enhanced Endpoint Discovery** - 50+ endpoints including Spring Boot Actuator, Laravel Telescope, Django debug
- **Cloud Metadata Endpoints** - Tests for AWS/GCP/Azure metadata SSRF vulnerabilities (with baseline comparison to eliminate false positives)
- **Backup File Hunter** - Finds .bak, .old, .sql, .zip backup files
- **HTTP Methods Testing** - Smart detection of dangerous methods (PUT, DELETE, TRACE, PATCH)
- **Header Injection** - Tests for X-Forwarded-For, Host header, and bypass techniques
- **Cookie Security** - Analyzes HttpOnly, Secure, SameSite flags + detects JavaScript cookies and cookie consent mechanisms
- **CORS Misconfiguration** - Detects weak CORS policies
- **Open Redirects** - Accurate detection of open redirect vulnerabilities
- **API Reconnaissance** - Discovers API endpoints and checks for sensitive data exposure

---

## Features

### 8 Scan Modes

1. **Quick Scan** - Fast reconnaissance (IP geo + protocol check + SSL/TLS + WAF + tech + WP vulns + info + endpoints + HTML source)
2. **Full Scan (All Modules)** - Comprehensive security testing (all modules including DNS, email security, CT subdomains, CSP, port scan, and more)
3. **API Recon** - Focused API endpoint discovery + CT subdomain enumeration
4. **Security Audit** - Deep security testing (IP geo + protocol + DNS + email security + SSL + tech + WP vulns + CSP + headers + cookies + CORS + redirects + cloud metadata)
5. **Tech Fingerprint** - Identify IP location, protocol availability, SSL/TLS config, WAF, CDN, web server, technology stack, and WordPress vulnerabilities
6. **Subdomain Enum** - Certificate Transparency (crt.sh) subdomain discovery with liveness probing
7. **DNS Recon** - Full DNS enumeration + email security records + CT subdomain discovery
8. **Port Scan** - IP geolocation + nmap port scan + SSL/TLS analysis

### Visual & Audio Feedback

- **LED Patterns:**
  - Blue blinking = Scanning in progress
  - Red solid = Vulnerability found
  - Green solid = Scan complete

- **Sounds:**
  - Scan start notification
  - Alert when vulnerability detected
  - Completion chime

- **Vibration:** On scan completion

### Notification Integration

- **Discord Webhook** - Receive formatted scan results with all CRITICAL/HIGH/MEDIUM findings grouped by section
- **Slack Webhook** - Alternative to Discord; sends severity summary + key findings to any Slack channel
- **Optional:** Works seamlessly without either webhook — just leave them blank for local-only results

---

## Usage

1. Load the **Curly** payload on your WiFi Pineapple Pager
2. **(Optional)** Configure Discord webhook in `payload.sh`:
   - Get webhook URL from Discord: Server Settings → Integrations → Webhooks → New Webhook
   - Edit line 11: `DISCORD_WEBHOOK="https://discord.com/api/webhooks/YOUR_WEBHOOK_HERE"`
3. **(Optional)** Configure Slack webhook in `payload.sh`:
   - Get webhook URL from Slack: Apps → Incoming Webhooks → Add New Webhook
   - Edit line 12: `SLACK_WEBHOOK="https://hooks.slack.com/services/YOUR_WEBHOOK_HERE"`
4. **(Optional)** Configure WPScan API token for WordPress vulnerability lookup:
   - Register for a free token at https://wpscan.com/register (25 requests/day)
   - Edit line 13: `WPSCAN_API_TOKEN="your_token_here"`
   - Without a token, Curly still detects WP version and does basic age checks
5. Enter target URL when prompted (e.g., `example.com` - no need for https://)
6. Select scan mode (1-8) using number picker
7. Press **A** to start the scan
8. Watch results in real-time on the Pager display
9. Results auto-saved to `/root/loot/curly/` (and sent to Discord/Slack if configured)

---

## What it Detects

### Security Issues

- ✅ **IP Geolocation** - IP address, hostname, city, region, country, ISP/organization, coordinates, timezone
- ✅ **Protocol Availability** - Detects HTTP/HTTPS availability; flags sites with no SSL (HIGH), missing HTTP→HTTPS redirects (MEDIUM), or secure HTTPS-only configs (INFO)
- ✅ **SSL/TLS Security** - Expired/expiring certificates, self-signed certs, weak ciphers (DES, RC4, MD5), outdated TLS versions (1.0/1.1), certificate chain issues
- ✅ **DNS Record Enumeration** - A, AAAA, NS, MX, TXT, CNAME, SOA records with provider identification; AXFR zone transfer attempts against all nameservers
- ✅ **Email Security** - SPF record + strictness (softfail vs reject), DMARC policy enforcement level, DKIM selector probing (12+ common selectors), BIMI brand indicator lookup
- ✅ **Certificate Transparency** - Queries crt.sh CT logs for all known subdomains; probes each for HTTP liveness; flags CNAME targets pointing to cloud services (potential subdomain takeover)
- ✅ **Port Scanning** - nmap scan of 26 common ports (web, admin, database, service); identifies open alternate admin panels (8080, 8443, etc.)
- ✅ **CSP Analysis** - Full Content-Security-Policy deep analysis: unsafe-inline, unsafe-eval, wildcard sources, missing directives, JSONP bypass CDNs, mixed content issues
- ✅ **Severity Scoring** - CRITICAL/HIGH/MEDIUM/LOW/INFO classification for all findings with summary report
- ✅ **Parameter Discovery** - Tests debug, auth, data, config parameters (~30 total); detects reflection, behavior changes, parameter pollution
- ✅ **WAF/CDN Protection** - Cloudflare, Akamai, AWS CloudFront, Incapsula, Sucuri, ModSecurity
- ✅ **Technology Stack** - Web servers, CMS platforms, frontend frameworks, libraries with versions
- ✅ **WordPress Version & CVE Scanner** - Detects WP version via 6 methods (RSS feed, Atom feed, meta generator, OPML, readme.html, CSS/JS query strings), queries WPScan API for known CVEs with titles/references/fix versions, enumerates plugins + themes with vulnerability lookup
- ✅ **WordPress Security Tests** - User enumeration API, xmlrpc.php, debug logs, wp-admin access (with content verification to prevent false positives)
- ✅ **HTML Source Secrets** - Email addresses, API keys, internal URLs, TODO comments, stack traces
- ✅ **Missing security headers** - X-Frame-Options, CSP, HSTS, X-Content-Type-Options
- ✅ **Information disclosure** - Server version, X-Powered-By, tech stack leakage
- ✅ **Exposed sensitive files** - `.git`, `.env`, `.aws/credentials`, `.svn`, `.hg` (with content verification to eliminate false positives)
- ✅ **Enhanced endpoints** - Spring Boot Actuator, Laravel Telescope, Django debug, Tomcat manager (50+ paths)
- ✅ **Cloud SSRF (Smart Detection)** - AWS/GCP/Azure metadata endpoint testing with baseline comparison — only fires if keywords appear in test response but NOT in the baseline page
- ✅ **Backup files** - .bak, .old, .sql, .zip, .tar.gz with 80+ combinations tested
- ✅ **API documentation** - `/swagger.json`, `/openapi.json`, GraphQL endpoints (validates JSON format to prevent false positives)
- ✅ **Dangerous HTTP methods** - PUT, DELETE, TRACE, PATCH (smart detection, filters rate limiting)
- ✅ **Cookie security** - Missing HttpOnly, Secure, SameSite flags; JavaScript cookie detection (document.cookie); cookie consent banner detection
- ✅ **CORS misconfigurations** - Wildcard and reflected origins
- ✅ **Open redirect vulnerabilities** - Accurate detection (no false positives!)
- ✅ **SSRF vectors** - Tests 8 common redirect parameters + cloud metadata
- ✅ **Sensitive data exposure** - API responses with passwords, tokens, keys

### Enhanced Endpoints Tested (50+)

**Common Files:**
```
/robots.txt, /sitemap.xml, /sitemap_index.xml, /.git/config, /.git/HEAD
/.git/index, /.svn/entries, /.hg/, /.env, /.aws/credentials
/phpinfo.php, /.well-known/security.txt
```

**Admin & Auth:**
```
/admin, /admin.php, /administrator, /login, /console
```

**API Endpoints:**
```
/api, /api/v1, /api/v2, /api/docs, /swagger.json, /swagger-ui.html
/openapi.json, /graphql, /graphiql
```

**Spring Boot Actuator:**
```
/actuator, /actuator/env, /actuator/health, /actuator/metrics
/actuator/mappings, /actuator/trace
```

**Debug & Monitoring:**
```
/debug, /trace, /metrics, /health, /status, /info
```

**Framework-Specific:**
```
/telescope (Laravel)
/__debug__/ (Django)
/manager/html, /manager/status (Tomcat)
```

---

## Output

All results are saved to timestamped files in `/root/loot/curly/`:

```
/root/loot/curly/example.com_20260106_143022.txt
```

Each loot file contains:
- Full scan report with timestamps and GPS coordinates (when available)
- Discovered vulnerabilities with severity markers (`[!!!]` CRITICAL, `[!!]` HIGH, `[!]` MEDIUM, `[-]` LOW, `[*]` INFO)
- Beautiful severity summary box at the end
- HTTP status codes
- Found endpoints
- Security header analysis
- SSL/TLS certificate analysis
- Parameter discovery results

---

## Bug Bounty Tips

This tool is perfect for initial reconnaissance:

1. **Quick triage** - Run quick scan on multiple targets
2. **Subdomain discovery** - Use Subdomain Enum (mode 6) or DNS Recon (mode 7) to find attack surface via CT logs
3. **Email spoofing** - DNS Recon identifies SPF softfail + missing DMARC (common report finding)
4. **API hunting** - Use API Recon mode to find undocumented endpoints
5. **Header bypass** - Identify potential authentication bypasses
6. **Information gathering** - Collect server fingerprints and tech stack info
7. **Sensitive files** - Find exposed configuration and credential files

---

## Technical Details

- **Timeout:** 10 seconds per request (prevents hanging on slow targets)
- **HTTP/HTTPS:** Auto-detects or defaults to HTTPS
- **Non-blocking:** LED and sound feedback during scans
- **Portable:** All results stored locally on Pager
- **BusyBox compatible:** Works with BusyBox nslookup, sed, awk (no GNU-specific features required)
- **DNS-over-HTTPS:** Falls back to Google DoH (dns.google) when nslookup results are incomplete
- **Memory-aware:** Large API responses (e.g., crt.sh JSON) written to temp files to avoid embedded device OOM

---

## Example Output

### IP Geolocation Lookup
```
[+] IP GEOLOCATION LOOKUP
[*] Target IP: 73.*.*.*

━━━ IP Information ━━━
  Hostname    : hostname
  Location    : Not Doxing myself
  Country     : US
  Postal Code : *****
  Coordinates : latitude.longitude
  Organization: Org
  Timezone    : America/New_York
━━━━━━━━━━━━━━━━━━━━━━
```

### Full Example Workflow

```bash
# Scenario: Bug bounty reconnaissance

1. Target: api.example.com (just type the domain!)
2. Select: Quick Scan (mode 1)
3. Results:
   [+] IP GEOLOCATION LOOKUP
   [*] Target IP: 104.26.*.*
   [*] Organization: AS13335 Cloudflare, Inc.

   [+] SSL/TLS SECURITY ANALYSIS
   [*] Certificate expires: Jul 15 23:59:59 2026 GMT
   [*] TLS Version: TLSv1.3
   [*] Cipher Suite: TLS_AES_256_GCM_SHA384
   [*] Certificate chain valid

   [*] WAF: Cloudflare detected
   [*] Web Server: nginx/1.18.0
   [*] CMS: WordPress detected
   [!] Missing: X-Frame-Options
   [!] Missing: CSP
   [!] FOUND [200]: /api/v1
   [!] FOUND [200]: /swagger.json

   ╔════════════════════════════════════╗
   ║    SEVERITY SUMMARY               ║
   ╠════════════════════════════════════╣
   ║  🔴 CRITICAL: 0
   ║  🟠 HIGH:     0
   ║  🟡 MEDIUM:   2
   ║  🟢 LOW:      0
   ║  ℹ️  INFO:     8
   ╠════════════════════════════════════╣
   ║  TOTAL FINDINGS: 10
   ║  ⏱️  ELAPSED TIME: 1m 23s
   ╚════════════════════════════════════╝

4. Loot saved to: /root/loot/curly/api.example.com_20260107_143022.txt
5. Discord/Slack notification sent! (if webhook configured)
6. Next steps: Behind Cloudflare, WordPress stack, review swagger.json
```

### Discord/Slack Notification Example

When configured, you'll receive a message with:
- Target, scan mode, timestamp, severity counts
- All CRITICAL/HIGH/MEDIUM findings grouped by section
- Results uploaded as a text file attachment

---

## Notes

- Designed for **authorized penetration testing** and bug bounty programs
- Always obtain permission before scanning targets
- Some tests may trigger WAFs or security monitoring
- Results are indicators — manual verification recommended
- Combine with other Pineapple payloads for complete assessment

---

## What's New in v4.0

### New Modules

**DNS Record Enumeration (`scan_dns_enum`)**
- Full DNS record lookup: A, AAAA, NS, MX, TXT, CNAME, SOA
- AXFR zone transfer attempts against every nameserver (verbose rejection reporting)
- Provider identification for NS/MX records (Cloudflare, Google, Mimecast, etc.)
- SPF record detection in TXT records

**Email Security Check (`scan_email_security`)**
- SPF record analysis — reports strictness (`~all` softfail vs `-all` reject)
- DMARC policy detection — flags `p=none` (monitoring only) and missing records
- DKIM probing — checks 12+ common selectors (default, google, mail, smtp, etc.)
- BIMI brand indicator lookup (optional/informational)

**Certificate Transparency (`scan_crt_sh`)**
- Queries crt.sh CT logs for all subdomains ever seen in certificates
- Deduplicates and probes each discovered subdomain for HTTP liveness
- Reports HTTP status code per subdomain
- Flags CNAMEs pointing to cloud services (GitHub Pages, S3, Heroku, etc.) as potential subdomain takeovers
- Replaces the old wordlist-based subdomain enumeration entirely — CT logs are more accurate and comprehensive

**CSP Deep Analysis (`scan_csp_analysis`)**
- Detects missing CSP header (flags as MEDIUM)
- Checks for `unsafe-inline`, `unsafe-eval` in script/style directives
- Identifies known JSONP bypass CDNs in source allowlists
- Flags missing `default-src`, `form-action`, `base-uri`, `object-src` directives
- Reports total CSP issue count

**Port Scan (`scan_ports`)**
- nmap scan of 26 ports: web (80, 443, 8080, 8443), admin (8888, 9090, 9200, 5601), databases (3306, 5432, 6379, 27017), and services
- Service name identification per open port
- Flags alternate web ports as potential admin panels (MEDIUM)
- Flags database ports exposed to internet (HIGH/CRITICAL)

### New Scan Modes

- **Mode 7 — DNS Recon:** `scan_dns_enum` + `scan_email_security` + `scan_crt_sh`
- **Mode 8 — Port Scan:** `scan_ip_geolocation` + `scan_ports` + `scan_ssl_tls`

### Updated Scan Modes

- **Mode 4 (Security Audit):** Now includes `scan_dns_enum`, `scan_email_security`, and `scan_csp_analysis`
- **Mode 6 (Subdomain Enum):** Now uses CT logs (`scan_crt_sh`) only — wordlist method removed
- **Mode 2 (Full Scan):** Includes all new modules; wordlist subdomain enumeration removed in favor of crt.sh
- **Mode 3 (API Recon):** Subdomain step now uses `scan_crt_sh` instead of wordlist, get better results this way in my opinion

### Slack Webhook Support

New `SLACK_WEBHOOK` config variable. Sends severity summary + CRITICAL/HIGH findings to any Slack channel as an alternative (or addition) to Discord.

### Bug Fixes

- **Cipher Suite display** — was showing the literal word "Cipher" instead of the cipher name (fixed `grep` to target `Cipher is X` line)
- **WordPress readme.html HTML** — was logging raw `<li>` HTML tags; now strips all tags before logging
- **AAAA Records** — was showing CNAME chain hostnames (domain names) in the IPv6 section; now filters to real IPv6 addresses only (must contain `:`)
- **CNAME false positives** — DoH queries returning SOA data or the queried domain itself are now suppressed; trailing dot stripped from results
- **SSRF false positives** — `check_metadata_content` now requires keywords to be absent from the baseline page; eliminates CONFIRMED CRITICAL false alarms on normal Shopify/CDN pages
- **Cookie name prefix** — HTTP/2 lowercase `set-cookie:` header was showing as part of the cookie name; fixed with `awk -F': '` parser instead of case-sensitive sed
- **doh_query Authority leakage** — DoH JSON `"data"` fields from the Authority (SOA) section were being extracted when there were no Answer records; now strips Authority section before parsing (or uses `jq .Answer[].data`)
- **A Records showing resolver IP** — BusyBox nslookup uses `:53` format (not `#53`); fixed filter to exclude both
- **GPS zeros logged** — suppressed GPS logging when coordinates are all zeros (no fix)
- **crt.sh BusyBox sed issue** — BusyBox `sed` doesn't interpret `\n` in replacements; switched to `jq` as primary parser with `awk gsub` fallback
- **crt.sh memory issue on full scan** — 248KB+ JSON variable assignment fails silently on embedded devices; fixed by writing directly to temp files with `curl -o`
- **Discord missing findings** — awk pattern missed `[!!]` HIGH severity entirely; hardcoded section filter replaced with dynamic section tracking

---

## What's New in v3.8

### WordPress Version & Vulnerability Scanner (v3.8):

**WordPress Version Detection (6 Methods)**
- **RSS Feed Generator** - Parses `<generator>` tag from `/feed/`
- **Atom Feed Generator** - Parses version attribute from `/feed/atom/`
- **Meta Generator Tag** - Extracts version from `<meta name="generator">` in HTML source
- **OPML Link** - Checks `/wp-links-opml.php` for generator version string
- **readme.html** - Reads version from WordPress readme file
- **CSS/JS Query Strings** - Fallback: finds most common `?ver=X.X.X` parameter across page assets

**Vulnerability Lookup via WPScan API**
- Free API integration using curl (25 free requests/day)
- CVE details: title, fixed-in version, reference URLs
- Severity classification: RCE/SQLi = CRITICAL, XSS/CSRF/SSRF = HIGH, Disclosure = MEDIUM
- Graceful fallback without API token (basic version age assessment)

**WordPress Plugin & Theme Enumeration**
- Extracts plugin slugs from page source `/wp-content/plugins/` paths
- Reads each plugin's `readme.txt` for version
- Queries WPScan API per plugin/theme for known vulnerabilities

---

## What's New in v3.7

### Protocol Availability Check (v3.7):
- Dual Protocol Testing — checks HTTP and HTTPS availability with status codes
- Redirect Verification — confirms HTTP→HTTPS redirect is enforced
- Identifies HTTP-only sites (HIGH), missing redirects (MEDIUM), secure configs (INFO)

### Automatic Update Checking (v3.7):
- Checks GitHub for newer versions on startup
- Displays "UPDATE AVAILABLE!" banner with version comparison
- Configurable via `ENABLE_UPDATE_CHECK=false`

### Enhanced Cookie Security Analysis (v3.7):
- `document.cookie` scanning — detects JS-set cookies that won't appear in HTTP headers
- Cookie consent detection (15+ CMP platforms: CookieBot, OneTrust, TrustArc, etc.)
- Manual verification guide when cookies are behind consent banners

---

## What's New in v3.6

### Major Update - Comprehensive Security Scanner (v3.6):
- Scan Time Tracking — estimated times before scans + actual elapsed time in summary
- Manual Verification Guides — step-by-step instructions for XSS, SSRF, bypass verification
- SSL/TLS Security Analysis — full certificate and cipher analysis
- Severity Scoring System — five-tier CRITICAL/HIGH/MEDIUM/LOW/INFO classification
- Parameter Discovery — 30 common parameters with reflection/behavior/pollution detection
- Intelligent SSRF Detection — baseline comparison with three-tier confidence levels
- Enhanced Detection Accuracy — improved Cloudflare and WordPress detection
- Discord Webhook Integration

---

## What's New in v3.0 / v2.x

- IP Geolocation Lookup
- HTML Source Analysis — emails, API keys, internal URLs, TODOs
- Enhanced Endpoint Discovery — 50+ endpoints
- Cloud Metadata Endpoints — AWS/GCP/Azure SSRF testing
- WordPress Security Tests
- WAF/CDN Detection
- Technology Fingerprinting
- Backup File Hunter
- Cookie Security Analysis
- CORS Misconfiguration Detection
- Open Redirect Detection

---

## Future Enhancements

Potential additions:
- JWT token testing and validation
- SQL injection probes
- XSS reflection testing
- Directory brute forcing with custom wordlists
- Proxy support for Burp Suite integration
- Response time analysis for timing attacks
- Custom wordlist support for parameter fuzzing
- WordPress plugin/theme semantic version comparison

---

## Disclaimer

This tool is for **authorized security testing only**. Unauthorized access to computer systems is illegal. Always ensure you have explicit permission before testing any target. I am not responsible for misuse of this tool. Dont' be an asshole!

---

## Support the Project

If you find **Curly** useful and want to support continued development, consider buying me a coffee! ☕

<a href="https://buymeacoffee.com/curtthecoder" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

Your support helps keep this project active and enables new features!

---

**Happy Hunting!** 🎯
