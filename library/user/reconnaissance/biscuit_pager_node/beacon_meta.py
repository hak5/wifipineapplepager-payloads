# Port of firmware/biscuit/common/WifiBeaconMetadata.h so Pager and Biscuit label networks identically.
SRC_RECEIVE, SRC_DS, SRC_HT = 0, 1, 2

TOKENS = {
    "Open": "[OPEN]", "Wep": "[WEP]", "WpaPersonal": "[WPA_PSK]", "Wpa2Personal": "[WPA2_PSK]",
    "Wpa3Personal": "[WPA3_PSK]", "WpaWpa2Personal": "[WPA_WPA2_PSK]", "Wpa2Enterprise": "[WPA2_ENTERPRISE]",
    "Wpa3Enterprise": "[WPA3_ENTERPRISE]", "Wapi": "[WAPI_PSK]", "Wpa2Wpa3Personal": "[WPA2_WPA3_PSK]",
    "WpaEnterprise": "[WPA_ENTERPRISE]", "Wpa2Wpa3Enterprise": "[WPA2_WPA3_ENTERPRISE]", "Owe": "[OWE]",
    "Unknown": "[UNDEFINED]",
}
KNOWN_AKMS = {1, 2, 3, 4, 5, 6, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 24, 25}


def _le16(d, o):
    return d[o] | (d[o + 1] << 8)


def _suite(d, o, a, b, c, t):
    return d[o] == a and d[o + 1] == b and d[o + 2] == c and d[o + 3] == t


def supported_5ghz(ch):
    if 36 <= ch <= 64 and (ch - 36) % 4 == 0:
        return True
    if 100 <= ch <= 144 and (ch - 100) % 4 == 0:
        return True
    return ch in (149, 153, 157, 161, 165, 169, 173, 177)


def supported(ch):
    return 1 <= ch <= 14 or supported_5ghz(ch)


def same_band(candidate, received):
    if not supported(received):
        return True
    return (candidate <= 14) == (received <= 14)


class _State:
    __slots__ = ("privacy", "malformed", "wapi", "rsn", "legacy", "unknown_akm", "mfpr", "mfpc", "akm",
                 "cckm", "wpa", "wpa_eap", "wpa_psk")

    def __init__(self):
        self.privacy = self.malformed = self.wapi = self.rsn = self.legacy = self.unknown_akm = False
        self.mfpr = self.mfpc = self.cckm = self.wpa = self.wpa_eap = self.wpa_psk = False
        self.akm = set()


def _parse_rsn(d, st):
    n = len(d)
    if n < 8 or _le16(d, 0) != 1:
        return False

    def cipher(o, group):
        if d[o] != 0x00 or d[o + 1] != 0x0F or d[o + 2] != 0xAC:
            return False
        t = d[o + 3]
        legacy = t in (1, 2, 5)
        modern = t in (4, 8, 9, 10) or (group and t == 7)
        use_group = (not group) and t == 0
        if not legacy and not modern and not use_group:
            return False
        if legacy:
            st.legacy = True
        return True

    if not cipher(2, True):
        return False
    c = 6
    count = _le16(d, c); c += 2
    if count == 0 or count > (n - c) // 4:
        return False
    for _ in range(count):
        if not cipher(c, False):
            return False
        c += 4
    if n - c < 2:
        return False
    count = _le16(d, c); c += 2
    if count == 0 or count > (n - c) // 4:
        return False
    for _ in range(count):
        if _suite(d, c, 0x00, 0x40, 0x96, 0):
            st.cckm = True
        elif d[c] != 0x00 or d[c + 1] != 0x0F or d[c + 2] != 0xAC:
            st.unknown_akm = True
        elif d[c + 3] in KNOWN_AKMS:
            st.akm.add(d[c + 3])
        else:
            st.unknown_akm = True
        c += 4
    if c == n:
        return True
    if n - c < 2:
        return False
    caps = _le16(d, c); c += 2
    st.mfpr = bool(caps & (1 << 6))
    st.mfpc = bool(caps & (1 << 7))
    if c == n:
        return True
    if n - c < 2:
        return False
    count = _le16(d, c); c += 2
    if count > (n - c) // 16:
        return False
    c += count * 16
    if c == n:
        return True
    if n - c != 4:
        return False
    if d[c] != 0x00 or d[c + 1] != 0x0F or d[c + 2] != 0xAC:
        return False
    return d[c + 3] in (6, 11, 12, 13)


def _parse_wpa(d, st):
    n = len(d)
    if n < 12 or not _suite(d, 0, 0x00, 0x50, 0xF2, 1) or _le16(d, 4) != 1:
        return False

    def valid(o):
        return d[o] == 0x00 and d[o + 1] == 0x50 and d[o + 2] == 0xF2 and d[o + 3] in (1, 2, 4, 5)

    if not valid(6):
        return False
    c = 10
    count = _le16(d, c); c += 2
    if count == 0 or count > (n - c) // 4:
        return False
    for _ in range(count):
        if not valid(c):
            return False
        c += 4
    if n - c < 2:
        return False
    count = _le16(d, c); c += 2
    if count == 0 or count > (n - c) // 4:
        return False
    for _ in range(count):
        if _suite(d, c, 0x00, 0x50, 0xF2, 1):
            st.wpa_eap = True
        elif _suite(d, c, 0x00, 0x50, 0xF2, 2):
            st.wpa_psk = True
        else:
            return False
        c += 4
    return c == n or n - c == 2


def _parse_wapi(d):
    n = len(d)
    if n < 20 or _le16(d, 0) != 1:
        return False
    c = 2
    count = _le16(d, c); c += 2
    if count == 0 or count > (n - c) // 4:
        return False
    for _ in range(count):
        if not _suite(d, c, 0x00, 0x14, 0x72, 2):
            return False
        c += 4
    if n - c < 2:
        return False
    count = _le16(d, c); c += 2
    if count == 0 or count > (n - c) // 4:
        return False
    for _ in range(count):
        if not _suite(d, c, 0x00, 0x14, 0x72, 1):
            return False
        c += 4
    if n - c < 6 or not _suite(d, c, 0x00, 0x14, 0x72, 1):
        return False
    c += 6
    if c == n:
        return True
    if n - c < 2:
        return False
    count = _le16(d, c); c += 2
    if count > (n - c) // 16:
        return False
    c += count * 16
    return c == n


def _classify(st):
    if st.malformed:
        return "Unknown"
    if st.mfpr and not st.mfpc:
        return "Unknown"
    if st.wapi:
        return "Unknown" if (st.rsn or st.wpa) else "Wapi"
    if st.rsn:
        if st.unknown_akm:
            return "Unknown"
        a = st.akm
        psk = bool(a & {2, 4, 6, 19, 20})
        sae = bool(a & {8, 9, 24, 25})
        rsn_ent = bool(a & {1, 3, 5, 11, 12, 13, 14, 15, 16, 17}) or st.cckm
        personal = psk or sae or st.wpa_psk
        enterprise = rsn_ent or st.wpa_eap
        owe = 18 in a
        if int(personal) + int(enterprise) + int(owe) > 1:
            return "Unknown"
        if owe:
            ok = not st.wpa and not st.legacy and st.mfpc and st.mfpr
            return "Owe" if ok else "Unknown"
        if psk or sae:
            if st.wpa_eap or (sae and st.wpa_psk):
                return "Unknown"
            if sae:
                if st.wpa or st.legacy or not st.mfpc:
                    return "Unknown"
                if psk:
                    return "Wpa2Wpa3Personal"
                return "Wpa3Personal" if st.mfpr else "Unknown"
            if st.wpa and st.wpa_psk:
                return "WpaWpa2Personal"
            return "Wpa2Personal"
        if rsn_ent:
            clean = not st.wpa and not st.legacy
            suite_b = bool(a & {12, 13})
            if suite_b and 1 not in a and clean and st.mfpr:
                return "Wpa3Enterprise"
            if 5 in a and 1 not in a and clean and st.mfpc and st.mfpr:
                return "Wpa3Enterprise"
            if 1 in a and 5 in a and clean and st.mfpc and not st.mfpr:
                return "Wpa2Wpa3Enterprise"
            return "Wpa2Enterprise"
        return "Unknown"
    if st.wpa:
        if st.wpa_eap == st.wpa_psk:
            return "Unknown"
        return "WpaEnterprise" if st.wpa_eap else "WpaPersonal"
    return "Wep" if st.privacy else "Open"


def parse(frame, rx_channel):
    """Returns (auth_token, channel, channel_source) for an 802.11 beacon/probe response (no FCS)."""
    n = len(frame)
    if n < 36:
        return TOKENS["Unknown"], rx_channel, SRC_RECEIVE
    st = _State()
    st.privacy = bool(frame[34] & 0x10)
    ds = ht = 0
    c = 36
    while n - c >= 2:
        eid, ln = frame[c], frame[c + 1]
        c += 2
        if ln > n - c:
            st.malformed = True
            if eid == 48:
                st.rsn = True
            if eid == 221:
                st.wpa = True
            break
        d = frame[c:c + ln]
        if eid == 3 and ln == 1 and supported(d[0]):
            if same_band(d[0], rx_channel):
                ds = d[0]
        elif eid == 61 and ln >= 22 and supported(d[0]) and same_band(d[0], rx_channel):
            ht = d[0]
        elif eid == 48:
            if st.rsn:
                st.malformed = True
            st.rsn = True
            if not _parse_rsn(d, st):
                st.malformed = True
        elif eid == 68:
            if st.wapi:
                st.malformed = True
            st.wapi = True
            if not _parse_wapi(d):
                st.malformed = True
        elif eid == 221 and ln >= 4:
            if _suite(d, 0, 0x00, 0x50, 0xF2, 1):
                if st.wpa:
                    st.malformed = True
                st.wpa = True
                if not _parse_wpa(d, st):
                    st.malformed = True
        c += ln
    if c != n:
        st.malformed = True
    token = TOKENS[_classify(st)]
    if ds:
        return token, ds, SRC_DS
    if ht:
        return token, ht, SRC_HT
    return token, rx_channel, SRC_RECEIVE


def ssid_raw(frame):
    """Mirror of extractSsidRaw: (bytes, status) with status 0 missing, 1 hidden, 2 present, 3 malformed."""
    n = len(frame)
    if n < 36:
        return b"", 3
    c = 36
    while n - c >= 2:
        eid, ln = frame[c], frame[c + 1]
        c += 2
        if ln > n - c:
            return b"", 3
        if eid == 0:
            if ln > 32:
                return b"", 3
            return bytes(frame[c:c + ln]), (1 if ln == 0 else 2)
        c += ln
    if c != n:
        return b"", 3
    return b"", 0
