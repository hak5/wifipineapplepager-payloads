"""Mode S and ADS-B frames to aircraft, from the published message formats.

Frames come as raw hex lines ("*8d4840d6202cc371c32ce0576098;"), as rtl_adsb prints them. Nothing is trusted
without its parity: DF17 and DF18 must have a parity remainder of zero, DF11 too. DF4, DF5, DF20 and DF21 carry
the address in their parity, so they are only taken for an aircraft already heard with good parity.

A position is decoded from an even and an odd CPR frame heard within PAIR_SECONDS (global decode), else from one
frame and the aircraft's own last position. The receiver's position is never the reference: one frame only gives one
answer within half a zone of the reference, and an aircraft further off would be put at a wrong place that looks
right. So the first position always comes from a pair. It and any position that does not agree with the one before it
are only held back until the next one agrees.

An airborne velocity also says how far the GNSS height is from the barometric one, and an emergency status (type 28)
carries the squawk. A velocity of 0 kt has no direction, so it leaves the track unknown.

DF4, DF5, DF20 and DF21 are only taken when they look right: an altitude close to the last one known, or a squawk or
altitude that came the same in the reply before. rtl_adsb prints noise too, and a noise frame can carry a known
address in its parity.
"""

import math

POLY = 0x1FFF409
PAIR_SECONDS = 10.0
REFERENCE_SECONDS = 600.0
LOCAL_KM = 180 * 1.852
RANGE_KM = 450.0
SLACK_KM = 2.0
FASTEST_KM_S = 0.6
FRESH_SECONDS = 60.0
FORGET_SECONDS = 300.0
MAX_AIRCRAFT = 4000
EARTH_KM = 6371.0088
NZ = 15
_CHARS = "#ABCDEFGHIJKLMNOPQRSTUVWXYZ##### ###############0123456789######"
_GOOD = frozenset(range(1, 27)) | {32} | frozenset(range(48, 58))


def _tables():
    last = []
    for byte in range(256):
        crc = byte << 16
        for _ in range(8):
            crc <<= 1
            if crc & 0x1000000:
                crc ^= POLY
        last.append(crc & 0xFFFFFF)
    tables = [tuple(last)]
    for _ in range(10):
        before = tables[0]
        tables.insert(0, tuple(((r << 8) & 0xFFFFFF) ^ last[r >> 16] for r in before))
    return tuple(tables)


_LONG = _tables()
_SHORT = _LONG[7:]


def syndrome(data):
    """The parity remainder of a 7 or 14 byte frame: 0 for a good DF17, the address for a good DF4/5/20/21."""
    if len(data) == 14:
        t = _LONG
        return (t[0][data[0]] ^ t[1][data[1]] ^ t[2][data[2]] ^ t[3][data[3]] ^ t[4][data[4]] ^ t[5][data[5]] ^
                t[6][data[6]] ^ t[7][data[7]] ^ t[8][data[8]] ^ t[9][data[9]] ^ t[10][data[10]] ^
                (data[11] << 16 | data[12] << 8 | data[13]))
    t = _SHORT
    return t[0][data[0]] ^ t[1][data[1]] ^ t[2][data[2]] ^ t[3][data[3]] ^ (data[4] << 16 | data[5] << 8 | data[6])


def _bit(value, index, width=13):
    return (value >> (width - 1 - index)) & 1


def gillham(ac13):
    """Feet from a 100 ft Gillham code laid out as the 13 bit AC field, or None."""
    c1, a1, c2, a2, c4, a4, b1, d1, b2, d2, b4, d4 = (_bit(ac13, i) for i in (0, 1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12))
    gray = d1 << 8 | d2 << 7 | d4 << 6 | a1 << 5 | a2 << 4 | a4 << 3 | b1 << 2 | b2 << 1 | b4
    fives = gray
    shift = gray >> 1
    while shift:
        fives ^= shift
        shift >>= 1
    hundreds = c1 << 2 | c2 << 1 | c4
    hundreds ^= hundreds >> 1
    hundreds ^= hundreds >> 2
    if hundreds in (0, 5, 6):
        return None
    if hundreds == 7:
        hundreds = 5
    if fives & 1:
        hundreds = 6 - hundreds
    feet = fives * 500 + hundreds * 100 - 1300
    return feet if feet >= -1200 else None


def ac13_feet(ac13):
    """Feet from a 13 bit altitude code (DF0/4/16/20), or None when absent or metric."""
    if not ac13 or ac13 & 0x40:
        return None
    if ac13 & 0x10:
        return (((ac13 & 0x1F80) >> 2) | ((ac13 & 0x20) >> 1) | (ac13 & 0x0F)) * 25 - 1000
    return gillham(ac13)


def ac12_feet(ac12):
    """Feet from the 12 bit altitude of an airborne position: the 13 bit code without its M bit."""
    return ac13_feet(((ac12 & 0xFC0) << 1) | (ac12 & 0x3F)) if ac12 else None


def squawk(id13):
    a = _bit(id13, 5) << 2 | _bit(id13, 3) << 1 | _bit(id13, 1)
    b = _bit(id13, 11) << 2 | _bit(id13, 9) << 1 | _bit(id13, 7)
    c = _bit(id13, 4) << 2 | _bit(id13, 2) << 1 | _bit(id13, 0)
    d = _bit(id13, 12) << 2 | _bit(id13, 10) << 1 | _bit(id13, 8)
    return "%d%d%d%d" % (a, b, c, d)


def callsign(me):
    out = []
    for shift in range(42, -1, -6):
        code = (me >> shift) & 0x3F
        if code not in _GOOD:
            return None
        out.append(_CHARS[code])
    text = "".join(out)
    return text if text.strip() else None


def nl(lat):
    """Number of longitude zones at a latitude."""
    lat = abs(lat)
    if lat < 1e-9:
        return 59
    if lat > 87.0:
        return 1
    if lat == 87.0:
        return 2
    a = 1 - math.cos(math.pi / (2 * NZ))
    b = math.cos(math.radians(lat)) ** 2
    return int(math.floor(2 * math.pi / math.acos(1 - a / b)))


def cpr_global(even, odd, odd_newest):
    """(lat, lon) from an even and an odd (lat_cpr, lon_cpr) pair as 17 bit integers, or None."""
    lat0, lon0 = even[0] / 131072.0, even[1] / 131072.0
    lat1, lon1 = odd[0] / 131072.0, odd[1] / 131072.0
    j = math.floor(59 * lat0 - 60 * lat1 + 0.5)
    rlat0 = 6.0 * (j % 60 + lat0)
    rlat1 = 360.0 / 59 * (j % 59 + lat1)
    if rlat0 >= 270:
        rlat0 -= 360
    if rlat1 >= 270:
        rlat1 -= 360
    if abs(rlat0) > 90 or abs(rlat1) > 90:
        return None
    zones = nl(rlat0)
    if zones != nl(rlat1):
        return None
    if odd_newest:
        lat, n, lon_cpr = rlat1, max(zones - 1, 1), lon1
    else:
        lat, n, lon_cpr = rlat0, max(zones, 1), lon0
    m = math.floor(lon0 * (zones - 1) - lon1 * zones + 0.5)
    lon = 360.0 / n * (m % n + lon_cpr)
    if lon >= 180:
        lon -= 360
    return lat, lon


def cpr_local(lat_cpr, lon_cpr, odd, ref_lat, ref_lon):
    """(lat, lon) from one frame and a reference less than half a zone away."""
    lat_c, lon_c = lat_cpr / 131072.0, lon_cpr / 131072.0
    dlat = 360.0 / (59 if odd else 60)
    j = math.floor(ref_lat / dlat) + math.floor(0.5 + (ref_lat % dlat) / dlat - lat_c)
    lat = dlat * (j + lat_c)
    if abs(lat) > 90:
        return None
    dlon = 360.0 / max(nl(lat) - odd, 1)
    m = math.floor(ref_lon / dlon) + math.floor(0.5 + (ref_lon % dlon) / dlon - lon_c)
    lon = dlon * (m + lon_c)
    if lon >= 180:
        lon -= 360
    elif lon < -180:
        lon += 360
    return lat, lon


def distance_km(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2
    return 2 * EARTH_KM * math.asin(min(1.0, math.sqrt(a)))


class Aircraft:
    __slots__ = ("address", "good", "messages", "last", "flight", "category", "alt_baro", "alt_geom", "gs", "track",
                 "baro_rate", "geom_rate", "ias", "tas", "mag_heading", "squawk", "lat", "lon", "pos_time", "placed",
                 "held", "even", "odd", "alt_time", "alt_seen", "squawk_seen", "geom_delta", "emergency")

    def __init__(self, address, now):
        self.address, self.good, self.messages, self.last = address, 0, 0, now
        self.flight = self.category = self.squawk = None
        self.alt_baro = self.alt_geom = self.gs = self.track = self.baro_rate = self.geom_rate = None
        self.ias = self.tas = self.mag_heading = None
        self.lat = self.lon = self.pos_time = self.held = self.even = self.odd = None
        self.alt_time = self.alt_seen = self.squawk_seen = self.geom_delta = self.emergency = None
        self.placed = False

    def report(self, now):
        out = {"hex": "%06x" % self.address}
        for key in ("flight", "category", "alt_baro", "alt_geom", "gs", "track", "baro_rate", "geom_rate", "ias",
                    "tas", "mag_heading", "squawk"):
            value = getattr(self, key)
            if value is not None:
                out[key] = value
        if self.placed and now - self.pos_time <= FRESH_SECONDS:
            out.update(lat=round(self.lat, 6), lon=round(self.lon, 6), seen_pos=round(max(0.0, now - self.pos_time), 1))
        out["messages"] = self.messages
        out["seen"] = round(max(0.0, now - self.last), 1)
        return out


class Decoder:
    """Aircraft by address, fed one frame at a time. receiver is the (lat, lon) of the stick, or None."""

    def __init__(self):
        self.planes = {}
        self.receiver = None
        self.frames = self.taken = self.dropped = 0

    def line(self, raw, now):
        """One line of rtl_adsb output, as bytes. True when it told something about an aircraft."""
        if raw[:1] != b"*":
            return False
        end = raw.find(b";")
        if end != 15 and end != 29:
            return False
        try:
            data = bytes.fromhex(raw[1:end].decode("ascii"))
        except ValueError:
            return False
        return len(data) * 2 == end - 1 and self.frame(data, now)

    def frame(self, data, now):
        self.frames += 1
        df = data[0] >> 3
        long = len(data) == 14
        if df == 17 or df == 18:
            if not long or (df == 18 and data[0] & 7) or syndrome(data):
                return False
            plane = self._good(data[1] << 16 | data[2] << 8 | data[3], now)
            if plane is not None:
                self._extended(plane, int.from_bytes(data[4:11], "big"), now)
        elif df == 11:
            if long or syndrome(data):
                return False
            plane = self._good(data[1] << 16 | data[2] << 8 | data[3], now)
        elif df in (4, 5, 20, 21) and long == (df >= 20):
            plane = self.planes.get(syndrome(data))
            if plane is None:
                return False
            plane.messages += 1
            plane.last = now
            field = (data[2] << 8 | data[3]) & 0x1FFF
            if df & 1:
                code = squawk(field)
                if code == plane.squawk_seen:
                    plane.squawk = code
                plane.squawk_seen = code
            else:
                self._reply_altitude(plane, ac13_feet(field), now)
        else:
            return False
        if plane is None:
            return False
        self.taken += 1
        return True

    def _good(self, address, now):
        plane = self.planes.get(address)
        if plane is None:
            if len(self.planes) >= MAX_AIRCRAFT:
                self.forget(now)
                if len(self.planes) >= MAX_AIRCRAFT:
                    return None
            plane = self.planes[address] = Aircraft(address, now)
        plane.good += 1
        plane.messages += 1
        plane.last = now
        return plane

    @staticmethod
    def _reply_altitude(plane, feet, now):
        if feet is None:
            return
        seen, plane.alt_seen = plane.alt_seen, feet
        if seen is not None and abs(feet - seen) <= 100 or plane.alt_baro is not None and \
                abs(feet - plane.alt_baro) <= 500 + 100 * max(0.0, now - plane.alt_time):
            plane.alt_baro, plane.alt_time = feet, now

    def _extended(self, plane, me, now):
        tc = me >> 51
        if 1 <= tc <= 4:
            name = callsign(me)
            if name is not None:
                plane.flight = name
            plane.category = "%s%d" % ("DCBA"[tc - 1], (me >> 48) & 7)
        elif 9 <= tc <= 18 or 20 <= tc <= 22:
            feet = ac12_feet((me >> 36) & 0xFFF)
            if tc <= 18:
                if feet is not None:
                    plane.alt_baro, plane.alt_time = feet, now
            elif feet is not None:
                plane.alt_geom = feet
            self._position(plane, (me >> 34) & 1, (me >> 17) & 0x1FFFF, me & 0x1FFFF, now)
        elif tc == 19:
            self._velocity(plane, me)
        elif tc == 28 and (me >> 48) & 7 == 1:
            plane.emergency = (me >> 45) & 7
            code = (me >> 32) & 0x1FFF
            if code:
                plane.squawk = plane.squawk_seen = squawk(code)

    def _velocity(self, plane, me):
        sub = (me >> 48) & 7
        if sub in (1, 2):
            vx, vy = (me >> 32) & 0x3FF, (me >> 21) & 0x3FF
            if vx and vy:
                scale = 4 if sub == 2 else 1
                vx, vy = (vx - 1) * scale, (vy - 1) * scale
                if (me >> 42) & 1:
                    vx = -vx
                if (me >> 31) & 1:
                    vy = -vy
                plane.gs = round(math.hypot(vx, vy), 1)
                plane.track = round(math.degrees(math.atan2(vx, vy)) % 360, 1) if vx or vy else None
        elif sub in (3, 4):
            if (me >> 42) & 1:
                plane.mag_heading = round(((me >> 32) & 0x3FF) * 360 / 1024.0, 1)
            speed = (me >> 21) & 0x3FF
            if speed:
                speed = (speed - 1) * (4 if sub == 4 else 1)
                if (me >> 31) & 1:
                    plane.tas = speed
                else:
                    plane.ias = speed
        else:
            return
        delta = me & 0x7F
        if delta:
            plane.geom_delta = (delta - 1) * 25 * (-1 if (me >> 7) & 1 else 1)
        rate = (me >> 10) & 0x1FF
        if rate:
            rate = (rate - 1) * 64 * (-1 if (me >> 19) & 1 else 1)
            if (me >> 20) & 1:
                plane.baro_rate = rate
            else:
                plane.geom_rate = rate

    def _position(self, plane, odd, lat_cpr, lon_cpr, now):
        if not lat_cpr and not lon_cpr:
            return
        mine = (lat_cpr, lon_cpr, now)
        other = plane.even if odd else plane.odd
        if odd:
            plane.odd = mine
        else:
            plane.even = mine
        here, fix, paired = self.receiver, None, False
        if other is not None and now - other[2] <= PAIR_SECONDS:
            fix = cpr_global(other, mine, True) if odd else cpr_global(mine, other, False)
            paired = fix is not None
        before = (plane.lat, plane.lon, plane.pos_time) if plane.placed else plane.held
        if fix is None and before is not None and now - before[2] <= REFERENCE_SECONDS:
            fix = self._near(cpr_local(lat_cpr, lon_cpr, odd, before[0], before[1]), before[0], before[1])
        if fix is None:
            return
        if here is not None and distance_km(here[0], here[1], fix[0], fix[1]) > RANGE_KM:
            if paired:
                plane.placed, plane.held = False, None
            return
        if before is not None and distance_km(before[0], before[1], fix[0], fix[1]) <= \
                SLACK_KM + FASTEST_KM_S * max(0.0, now - before[2]):
            plane.lat, plane.lon, plane.pos_time, plane.placed, plane.held = fix[0], fix[1], now, True, None
        else:
            plane.placed, plane.held = False, (fix[0], fix[1], now)

    @staticmethod
    def _near(fix, lat, lon):
        return fix if fix is not None and distance_km(lat, lon, fix[0], fix[1]) <= LOCAL_KM else None

    def forget(self, now):
        """Aircraft not heard for FORGET_SECONDS are dropped."""
        gone = [address for address, plane in self.planes.items() if now - plane.last > FORGET_SECONDS]
        for address in gone:
            del self.planes[address]

    def aircraft(self, now):
        """The aircraft heard in the last FRESH_SECONDS with good parity at least twice, as readsb's aircraft.json
        lists them."""
        return [plane.report(now) for plane in self.planes.values()
                if plane.good >= 2 and now - plane.last <= FRESH_SECONDS]
