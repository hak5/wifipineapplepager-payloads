#!/usr/bin/env python3
# PHONEPHREAK engine - phone number OSINT for the WiFi Pineapple Pager.
# PhoneInfoga-style recon, pure stdlib (python3-light), no external packages.
#
# Offline:  E.164 parse/validate, country + line-type analysis, format
#           variants, investigation link pack.
# Online:   DuckDuckGo exact-match footprint check (optional, no API key).
import argparse
import json
import os
import re
import signal
import sys
import time

VERSION = "1.0.0"

# ---------------------------------------------------------------------------
# Country calling codes -> (ISO, country, primary timezone)
# ---------------------------------------------------------------------------
CC = {
    1: ("US/CA", "United States / Canada (NANP)", "UTC-5..-8"),
    7: ("RU", "Russia / Kazakhstan", "UTC+3"),
    20: ("EG", "Egypt", "UTC+2"), 27: ("ZA", "South Africa", "UTC+2"),
    30: ("GR", "Greece", "UTC+2"), 31: ("NL", "Netherlands", "UTC+1"),
    32: ("BE", "Belgium", "UTC+1"), 33: ("FR", "France", "UTC+1"),
    34: ("ES", "Spain", "UTC+1"), 36: ("HU", "Hungary", "UTC+1"),
    39: ("IT", "Italy", "UTC+1"), 40: ("RO", "Romania", "UTC+2"),
    41: ("CH", "Switzerland", "UTC+1"), 43: ("AT", "Austria", "UTC+1"),
    44: ("GB", "United Kingdom", "UTC+0"), 45: ("DK", "Denmark", "UTC+1"),
    46: ("SE", "Sweden", "UTC+1"), 47: ("NO", "Norway", "UTC+1"),
    48: ("PL", "Poland", "UTC+1"), 49: ("DE", "Germany", "UTC+1"),
    51: ("PE", "Peru", "UTC-5"), 52: ("MX", "Mexico", "UTC-6"),
    53: ("CU", "Cuba", "UTC-5"), 54: ("AR", "Argentina", "UTC-3"),
    55: ("BR", "Brazil", "UTC-3"), 56: ("CL", "Chile", "UTC-4"),
    57: ("CO", "Colombia", "UTC-5"), 58: ("VE", "Venezuela", "UTC-4"),
    60: ("MY", "Malaysia", "UTC+8"), 61: ("AU", "Australia", "UTC+10"),
    62: ("ID", "Indonesia", "UTC+7"), 63: ("PH", "Philippines", "UTC+8"),
    64: ("NZ", "New Zealand", "UTC+12"), 65: ("SG", "Singapore", "UTC+8"),
    66: ("TH", "Thailand", "UTC+7"),
    81: ("JP", "Japan", "UTC+9"), 82: ("KR", "South Korea", "UTC+9"),
    84: ("VN", "Vietnam", "UTC+7"), 86: ("CN", "China", "UTC+8"),
    90: ("TR", "Turkey", "UTC+3"), 91: ("IN", "India", "UTC+5:30"),
    92: ("PK", "Pakistan", "UTC+5"), 93: ("AF", "Afghanistan", "UTC+4:30"),
    94: ("LK", "Sri Lanka", "UTC+5:30"), 95: ("MM", "Myanmar", "UTC+6:30"),
    98: ("IR", "Iran", "UTC+3:30"),
    211: ("SS", "South Sudan", "UTC+3"), 212: ("MA", "Morocco", "UTC+1"),
    213: ("DZ", "Algeria", "UTC+1"), 216: ("TN", "Tunisia", "UTC+1"),
    218: ("LY", "Libya", "UTC+2"), 220: ("GM", "Gambia", "UTC+0"),
    221: ("SN", "Senegal", "UTC+0"), 234: ("NG", "Nigeria", "UTC+1"),
    254: ("KE", "Kenya", "UTC+3"), 255: ("TZ", "Tanzania", "UTC+3"),
    256: ("UG", "Uganda", "UTC+3"),
    351: ("PT", "Portugal", "UTC+0"), 352: ("LU", "Luxembourg", "UTC+1"),
    353: ("IE", "Ireland", "UTC+0"), 354: ("IS", "Iceland", "UTC+0"),
    358: ("FI", "Finland", "UTC+2"), 370: ("LT", "Lithuania", "UTC+2"),
    371: ("LV", "Latvia", "UTC+2"), 372: ("EE", "Estonia", "UTC+2"),
    380: ("UA", "Ukraine", "UTC+2"),
    420: ("CZ", "Czechia", "UTC+1"), 421: ("SK", "Slovakia", "UTC+1"),
    501: ("BZ", "Belize", "UTC-6"), 502: ("GT", "Guatemala", "UTC-6"),
    503: ("SV", "El Salvador", "UTC-6"), 504: ("HN", "Honduras", "UTC-6"),
    505: ("NI", "Nicaragua", "UTC-6"), 506: ("CR", "Costa Rica", "UTC-6"),
    507: ("PA", "Panama", "UTC-5"), 509: ("HT", "Haiti", "UTC-5"),
    591: ("BO", "Bolivia", "UTC-4"), 593: ("EC", "Ecuador", "UTC-5"),
    595: ("PY", "Paraguay", "UTC-4"), 598: ("UY", "Uruguay", "UTC-3"),
    852: ("HK", "Hong Kong", "UTC+8"), 853: ("MO", "Macau", "UTC+8"),
    855: ("KH", "Cambodia", "UTC+7"), 856: ("LA", "Laos", "UTC+7"),
    886: ("TW", "Taiwan", "UTC+8"),
    960: ("MV", "Maldives", "UTC+5"), 961: ("LB", "Lebanon", "UTC+2"),
    962: ("JO", "Jordan", "UTC+3"), 963: ("SY", "Syria", "UTC+3"),
    964: ("IQ", "Iraq", "UTC+3"), 965: ("KW", "Kuwait", "UTC+3"),
    966: ("SA", "Saudi Arabia", "UTC+3"), 967: ("YE", "Yemen", "UTC+3"),
    968: ("OM", "Oman", "UTC+4"), 970: ("PS", "Palestine", "UTC+2"),
    971: ("AE", "UAE", "UTC+4"), 972: ("IL", "Israel", "UTC+2"),
    973: ("BH", "Bahrain", "UTC+3"), 974: ("QA", "Qatar", "UTC+3"),
    994: ("AZ", "Azerbaijan", "UTC+4"), 995: ("GE", "Georgia", "UTC+4"),
}
CC_SORTED = sorted(CC.keys(), key=lambda c: -len(str(c)))

NANP_TOLLFREE = {"800", "833", "844", "855", "866", "877", "888"}
NANP_PREMIUM = {"900"}


def normalize(raw):
    """Return (e164_digits or None, error)."""
    s = raw.strip()
    s = re.sub(r"[\s\-\.\(\)]", "", s)
    if s.startswith("+"):
        s = s[1:]
    elif s.startswith("00"):
        s = s[2:]
    if not s or not s.isdigit():
        return None, "not a digits-only number (use +CC... format)"
    if len(s) < 5 or len(s) > 15:
        return None, "length %d outside E.164 bounds (5-15 digits)" % len(s)
    return s, None


def find_cc(digits):
    for code in CC_SORTED:
        if digits.startswith(str(code)):
            return code
    return None


def nanp_area_info(nsn):
    area = nsn[:3]
    if area in NANP_TOLLFREE:
        return "toll-free", "Toll-free service"
    if area in NANP_PREMIUM:
        return "premium", "Premium-rate service"
    # NANP area codes are NXX: N=2-9; N11 are service codes; N9X reserved.
    if area[0] in "01" or area[1:] == "11" or area[1] == "9":
        return "invalid", "Invalid NANP area code"
    return "unknown", "NANP numbers are portable - mobile/landline/VoIP " \
                      "cannot be determined offline"


def line_type(cc, nsn):
    """Best-effort line-type detection for common numbering plans."""
    if cc == 1:
        return nanp_area_info(nsn)
    if cc == 44:  # UK
        if nsn.startswith("7"):
            return "mobile", "UK mobile range"
        if nsn.startswith(("800", "808")):
            return "toll-free", "UK freephone"
        if nsn.startswith("9"):
            return "premium", "UK premium rate"
        if nsn.startswith("56"):
            return "voip", "UK VoIP (56) range"
        if nsn.startswith(("1", "2", "3")):
            return "landline", "UK geographic"
    if cc == 49:  # Germany
        if nsn.startswith(("15", "16", "17")):
            return "mobile", "German mobile range"
        if nsn.startswith("800"):
            return "toll-free", "German freephone"
        if nsn.startswith("900"):
            return "premium", "German premium rate"
        return "landline", "German geographic"
    if cc == 33:  # France
        if nsn.startswith(("6", "7")):
            return "mobile", "French mobile range"
        if nsn.startswith("8"):
            return "special", "French special-rate (8xx)"
        if nsn.startswith(("1", "2", "3", "4", "5")):
            return "landline", "French geographic"
    if cc == 34:  # Spain
        if nsn.startswith(("6", "7")):
            return "mobile", "Spanish mobile range"
        if nsn.startswith(("800", "900")):
            return "toll-free", "Spanish freephone"
        if nsn.startswith("9"):
            return "landline", "Spanish geographic"
    if cc == 39:  # Italy
        if nsn.startswith("3"):
            return "mobile", "Italian mobile range"
        return "landline", "Italian geographic/fixed"
    if cc == 31:  # Netherlands
        if nsn.startswith("6"):
            return "mobile", "Dutch mobile range"
        return "landline", "Dutch geographic/fixed"
    if cc == 91:  # India
        if nsn[0] in "6789":
            return "mobile", "Indian mobile range"
        return "landline", "Indian fixed line"
    if cc == 61:  # Australia
        if nsn.startswith("4"):
            return "mobile", "Australian mobile range"
        if nsn.startswith("1800"):
            return "toll-free", "Australian freephone"
        return "landline", "Australian geographic"
    if cc == 81:  # Japan
        if nsn.startswith(("70", "80", "90")):
            return "mobile", "Japanese mobile range"
        return "landline", "Japanese fixed line"
    if cc == 55:  # Brazil (area code (2) + 9xxxx mobile)
        if len(nsn) >= 3 and nsn[2] == "9":
            return "mobile", "Brazilian mobile range"
        return "landline", "Brazilian fixed line"
    if cc == 52:  # Mexico
        if len(nsn) >= 2:
            return "unknown", "Mexican plans are portable - type undetermined"
    if cc == 86:  # China
        if nsn.startswith("1"):
            return "mobile", "Chinese mobile range"
        return "landline", "Chinese fixed line"
    if cc == 7:   # Russia/KZ
        if nsn.startswith("9"):
            return "mobile", "Russian mobile range (9xx)"
        return "landline", "Russian geographic"
    return "unknown", "no offline line-type data for this country"


def formats(digits, cc):
    nsn = digits[len(str(cc)):]
    if cc == 1 and len(nsn) == 10:
        intl = "+1 %s %s %s" % (nsn[:3], nsn[3:6], nsn[6:])
        natl = "(%s) %s-%s" % (nsn[:3], nsn[3:6], nsn[6:])
    else:
        intl = "+%s %s" % (cc, nsn)
        natl = nsn
    return {
        "e164": "+%s" % digits,
        "international": intl,
        "national": natl,
        "rfc3966": "tel:+%s" % digits,
    }


def link_pack(digits):
    e164 = "+%s" % digits
    bare = digits
    q = '"%s"' % e164
    return {
        "whatsapp": "https://wa.me/%s" % bare,
        "telegram": "https://t.me/%s" % e164,
        "google": "https://www.google.com/search?q=%%22%s%%22" % e164.replace("+", "%2B"),
        "bing": "https://www.bing.com/search?q=%%22%s%%22" % e164.replace("+", "%2B"),
        "duckduckgo": "https://duckduckgo.com/?q=%%22%s%%22" % e164.replace("+", "%2B"),
        "truecaller": "https://www.truecaller.com/search/us/%s" % bare,
        "sync_me": "https://sync.me/search/?number=%s" % e164.replace("+", "%2B"),
        "whocalld": "https://whocalld.com/+%s" % bare,
        "freecarrierlookup_us": "https://freecarrierlookup.com/" ,
        "query": q,
    }


def analyze(raw):
    digits, err = normalize(raw)
    if not digits:
        return {"status": 0, "error": err, "input": raw}
    cc = find_cc(digits)
    if not cc:
        return {"status": 0, "error": "unknown country calling code",
                "input": raw}
    nsn = digits[len(str(cc)):]
    iso, country, tz = CC[cc]
    ltype, lnote = line_type(cc, nsn)
    if ltype == "invalid":
        return {"status": 0, "error": lnote, "input": raw}
    return {
        "status": 1,
        "input": raw,
        "valid": True,
        "e164": "+%s" % digits,
        "country_code": "+%d" % cc,
        "iso": iso,
        "country": country,
        "timezone": tz,
        "nsn": nsn,
        "nsn_length": len(nsn),
        "line_type": ltype,
        "line_note": lnote,
        "carrier": ("undetermined offline - number portability; "
                    "use the carrier links in the report"),
        "formats": formats(digits, cc),
        "links": link_pack(digits),
    }


# ---------------------------------------------------------------------------
# online footprint check (optional; no API key)
# ---------------------------------------------------------------------------

def _https_post(host, path, body, headers, timeout=10):
    """Minimal HTTPS POST using socket + ssl.

    Avoids http.client (which pulls in the ``email`` package, absent from
    python3-light). It also avoids the ``idna`` codec, which needs
    ``unicodedata`` (python3-codecs) and is missing on the Pager: the host is
    passed to ``getaddrinfo`` as ASCII bytes and ``server_hostname`` is not
    used, so neither path calls the ``idna`` encoder. The context is
    unverified (no CA bundle required); acceptable for a public search query.
    """
    import socket as _socket
    import ssl
    ctx = ssl._create_unverified_context()
    host_bytes = host.encode("ascii")
    req = "POST %s HTTP/1.1\r\nHost: %s\r\n" % (path, host)
    req += "Content-Length: %d\r\n" % len(body)
    req += "Connection: close\r\n"
    for k, v in headers.items():
        req += "%s: %s\r\n" % (k, v)
    req += "\r\n"
    payload = req.encode("utf-8", "ignore") + body.encode("utf-8", "ignore")
    with _socket.create_connection((host_bytes, 443), timeout=timeout) as sock:
        with ctx.wrap_socket(sock) as ssock:
            ssock.settimeout(timeout)
            ssock.sendall(payload)
            data = b""
            while True:
                try:
                    chunk = ssock.recv(65536)
                except _socket.timeout:
                    break
                if not chunk:
                    break
                data += chunk
                if len(data) > 262144:
                    break
    return data


def _http_status(data):
    idx = data.find(b"\r\n\r\n")
    head = data if idx == -1 else data[:idx]
    line = head.split(b"\r\n", 1)[0].decode("utf-8", "replace")
    parts = line.split(" ")
    if len(parts) >= 2 and parts[1].isdigit():
        return int(parts[1])
    return 0


def ddg_footprint(e164, timeout=10):
    """Exact-match DuckDuckGo HTML search. Returns match count or error."""
    try:
        import ssl  # noqa: F401
    except ImportError:
        return {"status": 0,
                "error": "online check needs python3-openssl (ssl module)"}
    # q="+15551234567" URL-encoded -> q=%22%2B15551234567%22
    body = "q=%22" + e164.replace("+", "%2B") + "%22"
    try:
        raw = _https_post("html.duckduckgo.com", "/html/", body, {
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "Mozilla/5.0 (X11; Linux mipsel) PHONEPHREAK/%s"
                          % VERSION,
        }, timeout=timeout)
    except Exception as exc:
        return {"status": 0, "error": "duckduckgo request failed: %s" % exc}
    status = _http_status(raw)
    if status != 200:
        return {"status": 0, "error": "duckduckgo http %d" % status}
    data = raw.decode("utf-8", "replace")
    hits = data.count("result__a")
    no = "No results" in data
    return {"status": 1, "exact_matches": 0 if no else hits,
            "note": "exact-match web footprint (public pages only)"}


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------

def report_text(r):
    L = []
    A = L.append
    A("=" * 46)
    A("PHONEPHREAK report - %s" % r["e164"])
    A("=" * 46)
    A("input        : %s" % r["input"])
    A("valid        : yes")
    A("country      : %s (%s)" % (r["country"], r["country_code"]))
    A("timezone     : %s" % r["timezone"])
    A("line type    : %s" % r["line_type"])
    A("line note    : %s" % r["line_note"])
    A("nsn          : %s (%d digits)" % (r["nsn"], r["nsn_length"]))
    A("carrier      : %s" % r["carrier"])
    A("")
    A("formats:")
    for k, v in r["formats"].items():
        A("  %-13s: %s" % (k, v))
    A("")
    A("investigation links:")
    for k, v in r["links"].items():
        if k == "query":
            continue
        A("  %-18s: %s" % (k, v))
    if "online" in r:
        A("")
        A("online footprint:")
        for k, v in r["online"].items():
            A("  %-13s: %s" % (k, v))
    A("")
    A("generated by PHONEPHREAK v%s - authorized research only" % VERSION)
    return "\n".join(L)


def save_report(loot_dir, r):
    os.makedirs(loot_dir, exist_ok=True)
    base = os.path.join(loot_dir, r["e164"].replace("+", ""))
    with open(base + ".txt", "w", encoding="utf-8") as f:
        f.write(report_text(r) + "\n")
    with open(base + ".json", "w", encoding="utf-8") as f:
        json.dump(r, f, indent=2)
    return base + ".txt"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(description="PHONEPHREAK engine")
    p.add_argument("number", nargs="?", help="phone number")
    p.add_argument("--loot", default="/root/loot/phonephreak")
    p.add_argument("--online", action="store_true",
                   help="also run the online footprint check (needs internet)")
    p.add_argument("--bulk", default="", help="file with one number per line")
    p.add_argument("--json", action="store_true")
    args = p.parse_args()

    def handle_sig(s, f):
        sys.exit(1)
    signal.signal(signal.SIGINT, handle_sig)
    signal.signal(signal.SIGTERM, handle_sig)

    if args.bulk:
        try:
            with open(args.bulk, "r", encoding="utf-8", errors="replace") as f:
                numbers = [l.strip() for l in f if l.strip()]
        except OSError as exc:
            print("cannot read %s: %s" % (args.bulk, exc))
            return 1
        ok = 0
        for num in numbers:
            r = analyze(num)
            if r.get("status"):
                save_report(args.loot, r)
                ok += 1
                print("%-18s %s (%s) %s" % (r["e164"], r["country"],
                                            r["country_code"], r["line_type"]))
            else:
                print("%-18s ERROR: %s" % (num[:18], r.get("error", "?")))
        print("done: %d/%d parsed, reports in %s" % (ok, len(numbers),
                                                     args.loot))
        return 0 if ok else 1

    if not args.number:
        p.print_help()
        return 1

    r = analyze(args.number)
    if not r.get("status"):
        if args.json:
            print(json.dumps(r))
        else:
            print("ERROR: %s" % r["error"])
        return 1

    if args.online:
        try:
            r["online"] = ddg_footprint(r["e164"])
        except Exception as exc:
            r["online"] = {"status": 0, "error": str(exc)}

    report_path = save_report(args.loot, r)
    if args.json:
        print(json.dumps(r))
    else:
        print(report_text(r))
        print("\nreport: %s" % report_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
