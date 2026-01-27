# Curly - Web Recon & Vulnerability Scanner (WiFi Pineapple Pager Payload)

**Curly** transforms your WiFi Pineapple Pager into a portable web reconnaissance and vulnerability scanning tool using curl. Perfect for pentesting and bug bounty hunting on the go!

- **Author:** curtthecoder
- **Version:** 3.6

---

## What it does

Curly performs comprehensive web security testing using only curl:

- **IP Geolocation Lookup** - Resolves target IP and queries ipinfo.io for location, ISP, timezone data
- **SSL/TLS Security Analysis** 🔒 - Certificate expiration, TLS version detection, weak cipher identification, self-signed cert detection
- **Severity Scoring System** 📊 - All findings categorized as CRITICAL/HIGH/MEDIUM/LOW/INFO with beautiful summary report
- **Scan Time Tracking** ⏱️ *(NEW in v3.6)* - Estimated times before scans + actual elapsed time in final summary
- **Manual Verification Guides** 📖 *(NEW in v3.6)* - Step-by-step instructions on how to verify findings (XSS, SSRF, bypasses)
- **Content Verification System** 🎯 *(NEW in v3.6)* - Validates actual file content to eliminate false positives on sites with catch-all routing
- **Parameter Discovery** 🔍 - Tests 30+ common parameters for behavior changes, reflection, and pollution vulnerabilities
- **WAF/CDN Detection** - Identifies Cloudflare, Akamai, AWS CloudFront, Incapsula, Sucuri, ModSecurity
- **Technology Fingerprinting** - Detects web servers, CMS (WordPress, Drupal, Joomla), frameworks (React, Vue, Angular)
- **WordPress Security Tests** - Auto-runs when WordPress detected: user enumeration, xmlrpc, debug logs
- **Subdomain Enumeration** - Tests 50+ common subdomains (api, admin, dev, staging, etc.)
- **Information Gathering** - Headers, server fingerprinting, security header analysis
- **HTML Source Analysis** - Extracts emails, comments, API keys, internal URLs, TODOs
- **Enhanced Endpoint Discovery** - 50+ endpoints including Spring Boot Actuator, Laravel Telescope, Django debug
- **Cloud Metadata Endpoints** - Tests for AWS/GCP/Azure metadata SSRF vulnerabilities
- **Backup File Hunter** - Finds .bak, .old, .sql, .zip backup files
- **HTTP Methods Testing** - Smart detection of dangerous methods (PUT, DELETE, TRACE, PATCH)
- **Header Injection** - Tests for X-Forwarded-For, Host header, and bypass techniques
- **Cookie Security** - Analyzes HttpOnly, Secure, and SameSite flags
- **CORS Misconfiguration** - Detects weak CORS policies
- **Open Redirects** - Accurate detection of open redirect vulnerabilities
- **API Reconnaissance** - Discovers API endpoints and checks for sensitive data exposure

---

## Features

### 6 Scan Modes

1. **Quick Scan** - Fast reconnaissance (IP geo + SSL/TLS + WAF + tech + info + endpoints + HTML source)
2. **Full Scan (All Modules)** - Comprehensive security testing (all 17 modules including SSL/TLS + parameter discovery!)
3. **API Recon** - Focused API endpoint discovery + subdomain enumeration
4. **Security Audit** - Deep security testing (IP geo + SSL/TLS + tech + HTML + parameters + methods + headers + cookies + CORS + redirects + cloud metadata)
5. **Tech Fingerprint** - Identify IP location, SSL/TLS config, WAF, CDN, web server, and technology stack
6. **Subdomain Enum** - Test 50+ common subdomains for the target

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

### Discord Integration

- **Automatic Notifications:** Configure a Discord webhook to receive scan results directly in your Discord channel
- **Rich Results:** Get formatted messages with target info, scan mode, timestamp, and only imporant results show up on discord, or interesting findings
- **Optional:** Works seamlessly without webhook - just leave it blank for local-only results

---

## Usage

1. Load the **Curly** payload on your WiFi Pineapple Pager
2. **(Optional)** Configure Discord webhook in `payload.sh`:
   - Get webhook URL from Discord: Server Settings → Integrations → Webhooks → New Webhook
   - Edit line 11: `DISCORD_WEBHOOK="https://discord.com/api/webhooks/YOUR_WEBHOOK_HERE"`
3. Enter target URL when prompted (e.g., `example.com` - no need for https://)
4. Select scan mode (1-6) using number picker
5. Press **A** to start the scan
6. Watch results in real-time on the Pager display
7. Results auto-saved to `/root/loot/curly/` (and sent to Discord if configured)

---

## What it Detects

### Security Issues

- ✅ **IP Geolocation** - IP address, hostname, city, region, country, ISP/organization, coordinates, timezone
- 🔒 **SSL/TLS Security** *(NEW in v3.5)* - Expired/expiring certificates, self-signed certs, weak ciphers (DES, RC4, MD5), outdated TLS versions (1.0/1.1), certificate chain issues
- 📊 **Severity Scoring** *(NEW in v3.5)* - CRITICAL/HIGH/MEDIUM/LOW/INFO classification for all findings with summary report
- 🔍 **Parameter Discovery** *(NEW in v3.5)* - Tests debug, auth, data, config parameters (~30 total); detects reflection, behavior changes, parameter pollution
- ✅ **WAF/CDN Protection** - Cloudflare, Akamai, AWS CloudFront, Incapsula, Sucuri, ModSecurity
- ✅ **Technology Stack** - Web servers, CMS platforms, frontend frameworks, libraries with versions
- ✅ **WordPress Vulnerabilities** - User enumeration API, xmlrpc.php, debug logs, wp-admin access (with content verification to prevent false positives)
- ✅ **Subdomains** - Tests 50+ common subdomains (api, admin, dev, staging, mail, etc.)
- ✅ **HTML Source Secrets** - Email addresses, API keys, internal URLs, TODO comments, stack traces
- ✅ **Missing security headers** - X-Frame-Options, CSP, HSTS, X-Content-Type-Options
- ✅ **Information disclosure** - Server version, X-Powered-By, tech stack leakage
- ✅ **Exposed sensitive files** - `.git`, `.env`, `.aws/credentials`, `.svn`, `.hg` (with content verification to eliminate false positives)
- ✅ **Enhanced endpoints** - Spring Boot Actuator, Laravel Telescope, Django debug, Tomcat manager (50+ paths)
- ✅ **Cloud SSRF (Smart Detection)** - AWS/GCP/Azure metadata endpoint testing with intelligent false positive reduction
- ✅ **Backup files** - .bak, .old, .sql, .zip, .tar.gz with 80+ combinations tested
- ✅ **API documentation** - `/swagger.json`, `/openapi.json`, GraphQL endpoints (validates JSON format to prevent false positives)
- ✅ **Dangerous HTTP methods** - PUT, DELETE, TRACE, PATCH (smart detection, filters rate limiting)
- ✅ **Cookie security** - Missing HttpOnly, Secure, SameSite flags
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

### Subdomains Tested (50+)

```
www, api, admin, dev, staging, test, beta, demo, portal, dashboard
app, mail, ftp, vpn, ssh, remote, store, shop, blog, forum
status, help, support, cdn, static, assets, images, media, upload
files, mobile, m, secure, login, auth, sso, sandbox, uat, qa
prod, old, new, v2, api2, backend, server, db, database, cloud
git, gitlab, jenkins, monitor
```

---

## Output

All results are saved to timestamped files in `/root/loot/curly/`:

```
/root/loot/curly/example.com_20260106_143022.txt
```

Each loot file contains:
- Full scan report with timestamps
- Discovered vulnerabilities with severity markers ([!!!] CRITICAL, [!!] HIGH, [!] MEDIUM, [-] LOW, [*] INFO)
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
2. **API hunting** - Use API Recon mode to find undocumented endpoints
3. **Header bypass** - Identify potential authentication bypasses
4. **Information gathering** - Collect server fingerprints and tech stack info
5. **Sensitive files** - Find exposed configuration and credential files

---

## Technical Details

- **Timeout:** 10 seconds per request (prevents hanging on slow targets)
- **HTTP/HTTPS:** Auto-detects or defaults to HTTPS
- **Non-blocking:** LED and sound feedback during scans
- **Portable:** All results stored locally on Pager

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
   [*] SSL Certificate valid for 201 days
   [*] TLS Version: TLSv1.3
   [*] Certificate chain valid

   [*] WAF: Cloudflare detected
   [*] Web Server: nginx/1.18.0
   [*] CMS: WordPress detected
   [*] Frontend: React detected
   [!] Missing: X-Frame-Options
   [!] Missing: CSP
   [!] FOUND [200]: /api/v1
   [!] FOUND [200]: /swagger.json
   [!] FOUND [200]: /sitemap_index.xml

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
5. Discord notification sent! 📱 (if webhook configured)
6. Next steps: Behind Cloudflare, WordPress + React stack, review swagger.json
   - Fix 2 MEDIUM issues (missing security headers)
   - Review API documentation at /swagger.json
```

### Discord Notification Example

When configured, you'll receive a Discord message like:
```
🎯 Curly Scan Complete
Target: `api.example.com`
Scan Mode: 1
Timestamp: Mon Jan 12 15:30:22 EST 2026

📎 Attachment: api.example.com_20260112_153022.txt
```

---

## Notes

- Designed for **authorized penetration testing** and bug bounty programs
- Always obtain permission before scanning targets
- Some tests may trigger WAFs or security monitoring
- Results are indicators - manual verification recommended
- Combine with other Pineapple payloads for complete assessment

---

## What's New in v3.6

### Major Update - Comprehensive Security Scanner (v3.6):

**⏱️ Scan Time Tracking**
- **Estimated Time Display** - Shows expected scan duration before each mode starts
  - Quick Scan: ~30-45 seconds
  - Full Scan: ~2-25 minutes
  - API Recon: ~45-60 seconds
  - Security Audit: ~90-120 seconds
  - Tech Fingerprint: ~20-30 seconds
  - Subdomain Enum: ~30-45 seconds
- **Actual Elapsed Time** - Displays real scan duration in severity summary box
  - Formatted as "Xm Ys" for scans over 1 minute, or just "Ys" for shorter scans
  - Helps benchmark performance and plan scanning sessions
  - Useful for tracking efficiency on different targets

**📖 Manual Verification Guides**
- **Parameter Discovery Guide** - Step-by-step instructions when reflected parameters are found
  - Browser testing workflow for XSS verification
  - curl command examples for quick testing
  - Edge case testing suggestions (page=999999 to trigger errors)
  - Eliminates guesswork on how to verify findings and shit like that
- **X-Original-URL Bypass Guide** - Shows exact commands to verify ACL bypasses
  - Pre-filled curl examples with target URL
  - Multiple test paths (/admin, /console)
  - Clear success criteria explanation
- **SSRF Verification Guide** - Comprehensive SSRF testing instructions
  - Burp Collaborator / webhook.site integration steps
  - Internal network access testing examples
  - AWS/GCP/Azure metadata exploitation commands
  - Only displays when SSRF findings are detected

**🔒 SSL/TLS Security Analysis**
- **Certificate Expiration Monitoring** - Alerts on expired certs (CRITICAL) or certs expiring within 30 days (HIGH)
- **TLS Version Detection** - Identifies outdated/insecure TLS versions (TLS 1.0/1.1 = HIGH, SSLv2/v3 = CRITICAL)
- **Weak Cipher Detection** - Flags dangerous ciphers (NULL, EXPORT, DES, RC4, MD5, anon) as CRITICAL
- **Self-Signed Certificate Detection** - Identifies self-signed certs (HIGH severity)
- **Certificate Chain Validation** - Checks for chain issues (MEDIUM severity)
- **Portable Date Parsing** - Works on both Linux and OpenWrt systems
- **Smart Skip for HTTP** - Gracefully skips SSL checks for HTTP-only sites

**📊 Severity Scoring System**
- **Five-Tier Classification:**
  - 🔴 **CRITICAL** `[!!!]` - Immediate threats: exposed configs, SSRF, expired SSL, API keys in source, backup files, debug logs
  - 🟠 **HIGH** `[!!]` - Serious issues: open redirects, CORS wildcards, X-Powered-By disclosure, parameter reflection, TLS 1.0/1.1
  - 🟡 **MEDIUM** `[!]` - Security improvements needed: missing headers, cookie flags, WordPress enumeration, certificate chain issues
  - 🟢 **LOW** `[-]` - Minor issues: missing SameSite, xmlrpc.php accessible, developer comments
  - ℹ️ **INFO** `[*]` - Informational: server types, technologies detected, email addresses, valid SSL certs
- **Summary Report** - Color-coded box at scan end showing counts by severity
- **Risk Prioritization** - Instantly see which findings need immediate attention
- **Comprehensive Coverage** - ALL 17 modules now use severity scoring

**🔍 Parameter Discovery**
- **Balanced Testing** - Tests ~30 common parameters (debug, test, dev, admin, user, id, key, config, etc.)
- **Multiple Detection Methods:**
  - Status code changes (e.g., 200 → 500) = MEDIUM severity
  - Response size differences (>100 bytes) = LOW severity
  - Parameter reflection in response = LOW severity (needs manual verification)
- **Parameter Pollution Testing** - Detects HTTP Parameter Pollution (HPP) vulnerabilities
- **Smart Baseline Comparison** - Compares against normal page response to reduce false positives
- **Ignores Rate Limiting** - Skips HTTP 429 responses to eliminate noise
- **Summary Report** - Lists all interesting parameters discovered at end of scan

**🎯 Intelligent SSRF Detection**
- **Baseline Comparison** - Compares test responses against normal homepage
- **Content Analysis** - Scans for actual AWS/GCP/Azure metadata keywords
- **Response Size Checking** - Flags significant size differences (>1000 bytes)
- **Three-Tier Confidence Levels:**
  - `[!!!]` = High confidence (actual metadata content found) - **REPORT THIS!**
  - `[?]` = Requires manual verification (suspicious but needs confirmation)
  - `[*]` = Likely false positive (normal page response)
- Dramatically reduced false positives for cloud metadata testing

**🔍 Enhanced Detection Accuracy**
- **Cloudflare Detection** - More reliable WAF/CDN identification
  - DNS Nameserver Checking as fallback when HTTP headers don't reveal Cloudflare
  - Detects Cloudflare even when proxy/CDN headers are stripped or hidden
  - Queries for `*.ns.cloudflare.com` nameservers to confirm Cloudflare usage
  - Eliminates false negatives where Cloudflare was present but not detected
- **WordPress Detection** - Fixed false positives with smarter CMS detection
  - Technical Indicator Matching: Only detects when actual WordPress files/paths are present
  - Looks for generator meta tags, `/wp-content/themes/`, `/wp-content/plugins/`, `/wp-includes/`
  - No longer triggers on pages that merely mention "WordPress" in content
  - Still validates with endpoint checks (wp-json, wp-login.php) for confirmation

**📱 Discord Webhook Integration**
- **Automatic Notifications** - Send scan results to your Discord channel
  - Configure once, get instant notifications on every scan
  - Includes formatted message with target, scan mode, and timestamp
  - Results sent as downloadable text file attachment
  - Completely optional - works great without it too!

**🗺️ Enhanced Coverage**
- **Sitemap Discovery** - Added `/sitemap_index.xml` to endpoint testing
  - Many sites use sitemap index files that point to multiple sitemaps
  - Better coverage for large sites with multiple sitemap files

**🎯 Content Verification System**
- **WordPress Detection** - Dramatically improved accuracy with content verification
  - Checks actual WordPress content (wp-json API namespace, login form elements)
  - No longer triggers on sites that return HTTP 200 for everything (e.g., Facebook, large CDNs)
  - Verifies `/wp-json/` contains valid WordPress REST API JSON
  - Confirms `/wp-login.php` has real WordPress login form elements
  - Eliminates false positives from sites that merely mention "WordPress" in content
- **Critical File Detection** - Validates actual file content, not just HTTP status codes
  - **/.env files** - Verifies KEY=value format, not HTML redirects
  - **/phpinfo.php** - Confirms presence of "PHP Version" or phpinfo() output
  - **/.git, /.aws files** - Ensures content isn't HTML (actual git/aws files)
  - **/swagger.json, /openapi.json** - Validates JSON contains "swagger" or "openapi" keys
  - Prevents CRITICAL false alarms on sites with catch-all routing (SPAs, frameworks)
- **Intelligent HTTP 200 Handling**
  - Many modern sites (Facebook, Google, SPAs) return 200 for all paths
  - Scanner now verifies response content matches expected file type
  - Only reports findings when content is verified as legitimate
  - Saves time and eliminates noise in scan results

**🔧 Bug Fixes & UX Improvements**
- **Reduced False Positives** - Parameter Discovery ignores HTTP 429 rate limiting responses
- **Lower Severity for Reflected Params** - Changed from HIGH to LOW (needs manual verification)
- **Removed Excessive Beeping** - No more beeping on each reflected parameter (too noisy)
- **Cleaner Output** - More actionable results with accurate severity ratings
- **Educational Tool** - Verification guides teach you how to exploit findings
- **Performance Optimization** - Only fetches content when status is 200 (reduces unnecessary requests)
- **Other Bug Fixes..**
---

## What's New in v3.0

### New Modules Added (v3.0):
- 🌍 **IP Geolocation Lookup** - Queries ipinfo.io for target IP location, ISP, timezone, and more
- 🔧 **Improved Detection** - Fixed false positives in TODO/FIXME, backup files, and error detection
- 🔄 **Automatic Redirect Following** - Now follows www redirects automatically (e.g., example.com → www.example.com)

### Previous Additions (v2.5):
- 💎 **HTML Source Analysis** - Extracts emails, comments, API keys, internal URLs, developer TODOs
- 🎯 **Enhanced Endpoint Discovery** - 50+ endpoints (Spring Boot, Laravel, Django, Tomcat)
- ☁️ **Cloud Metadata Endpoints** - SSRF testing for AWS/GCP/Azure metadata APIs
- 🎨 **WordPress Security Tests** - Auto-detects and tests WordPress-specific vulnerabilities

### Previous Additions (v2.0):
- 🛡️ **WAF/CDN Detection** - Identifies 6+ protection systems
- 🔍 **Technology Fingerprinting** - CMS, frameworks, libraries with versions
- 🌐 **Subdomain Enumeration** - Tests 50+ common subdomains
- 🗂️ **Backup File Hunter** - Tests 80+ backup file combinations
- 🍪 **Cookie Security Analysis** - HttpOnly, Secure, SameSite flag checking

### Improvements:
- ✅ **Smarter HTTP Methods Testing** - Filters rate limiting (429/503), only flags real vulnerabilities
- ✅ **Accurate Redirect Detection** - Fixed false positives, uses regex pattern matching
- ✅ **Better UX** - No need to type "https://", just enter domain name
- ✅ **6 Scan Modes** - More options for different use cases
- ✅ **Progress Indicators** - Live updates during subdomain scanning
- ✅ **Conditional Testing** - WordPress tests only run when WordPress is detected
- ✅ **Subdomain Summary** - Clear list of discovered subdomains at scan end

## Future Enhancements

Potential additions:
- JWT token testing and validation
- SQL injection probes
- XSS reflection testing
- Directory brute forcing with custom wordlists
- Proxy support for Burp Suite integration
- Subdomain takeover detection
- DNS zone transfer testing
- Response time analysis for timing attacks
- JSON/XML parsing and validation
- Custom wordlist support for parameter fuzzing

---

## Disclaimer

This tool is for **authorized security testing only**. Unauthorized access to computer systems is illegal. Always ensure you have explicit permission before testing any target. I am not responsible for misuse of this tool.

---

## Support the Project

If you find **Curly** useful and want to support continued development, consider buying me a coffee! ☕

<a href="https://buymeacoffee.com/curtthecoder" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

Your support helps keep this project active and enables new features!

---

**Happy Hunting!** 🎯
