"""LoRaWAN operators heard with the Cap LoRa-1262, for the LoRaWAN kind of Drive Alerts.

Every LoRaWAN data frame carries its device address in the clear, and the start of that address is the NetID of
the network that runs it. A NetID names an operator: a utility's meters, a city's sensors, The Things Network. One
alert per operator, not per device, as a street of meters is one fact. The payload stays encrypted and is never read.

The frame layout, the NetID rules, the operator registry and when a frame counts follow SquachWatch
(SquachWatch-CYD, GPL-3.0, lora_lorawan.cpp, lora_opalert.cpp and lora_netid_table.h), whose registry comes from the
LoRa Alliance NetID allocation as The Things Network publishes it.
"""

UNCONF_UP, UNCONF_DOWN, CONF_UP, CONF_DOWN = 2, 3, 4, 5
DATA = (UNCONF_UP, UNCONF_DOWN, CONF_UP, CONF_DOWN)
UPLINK = (UNCONF_UP, CONF_UP)
CONFIRM_SECONDS = 3600.0
CAP = 16
_NWKID_BITS = (6, 6, 9, 11, 12, 13, 15, 17)

REGISTRY = {
    0x000000: "Private/experimental nodes", 0x000001: "Private/experimental nodes", 0x000002: "Actility",
    0x000003: "Proximus", 0x000004: "Swisscom", 0x000006: "EchoStar Mobile", 0x000007: "Bouygues Telecom",
    0x000008: "Orbiwise", 0x000009: "SENET", 0x00000A: "KPN", 0x00000B: "EveryNet", 0x00000D: "SK Telecom",
    0x00000E: "SagemCom", 0x00000F: "Orange", 0x000010: "A2A Smart City", 0x000012: "Kerlink",
    0x000013: "The Things Network", 0x000015: "Cisco Systems", 0x000017: "MultiTech Systems", 0x000018: "Loriot",
    0x000019: "NNNCo", 0x00001F: "Axatel", 0x000022: "Comcast", 0x000023: "Ventia", 0x000030: "SoftBank",
    0x000035: "Shenzhen Tencent Computer Systems Company Limited", 0x000036: "Netze BW GmbH", 0x000037: "Tektelic",
    0x000038: "Charter Communicaton", 0x000039: "Amazon", 0x00003A: "Minol ZENNER", 0x00003B: "Semtech",
    0x00003C: "Helium", 0x00003E: "Unidata", 0x00003F: "Birdz", 0x600001: "Digita", 0x600002: "Netmore",
    0x600003: "QuaeNet Inc.", 0x600004: "eleven-x", 0x600005: "IoT Network AS", 0x600007: "EDF", 0x600008: "Unidata",
    0x60000A: "Öresundskraft", 0x60000E: "Spark", 0x600010: "Senet", 0x600013: "Actility", 0x600014: "Kerlink",
    0x600016: "Cisco", 0x600017: "Schneider Electric", 0x600018: "Minol ZENNER Connect GmbH",
    0x60001A: "NEC Corporation", 0x60001B: "Shenzhen Tencent Computer Systems Company Limited",
    0x60001C: "MachineQ/Comcast", 0x60001D: "NTT (Nippon Telephone and Telegraph)", 0x60001F: "KPN",
    0x600020: "Spectrum", 0x600021: "Microshare Inc.", 0x600024: "Netze BW GmbH", 0x600025: "Tektelic",
    0x600027: "Birdz", 0x600028: "Charter Communication", 0x600029: "Machines Talk",
    0x60002A: "Neptune Technology Group", 0x60002B: "Amazon", 0x60002C: "myDevices",
    0x60002D: "Decentralized Wireless Foundation Inc", 0x60002E: "Eutelsat S.A.", 0x600030: "EchoStar Mobile",
    0x600032: "Orange", 0xC00002: "ResIOT", 0xC00003: "SYSDEV", 0xC00005: "Macnica",
    0xC00008: "Definium Technologies", 0xC0000A: "SenseWay", 0xC0000B: "3S", 0xC0000D: "Packetworx",
    0xC0000F: "Antenna Hungaria Co", 0xC00012: "Netmore", 0xC00013: "Lyse AS", 0xC00014: "VTC Digicom",
    0xC00015: "Machines Talk", 0xC00016: "Schneider Electric", 0xC00017: "Connexin",
    0xC00018: "Minol ZENNER Connect GmbH", 0xC00019: "Telekom Srbija", 0xC0001A: "REQUEA",
    0xC0001B: "Sensor Network Services", 0xC0001D: "Boston Networks Limited", 0xC0001F: "mcf88 SRL",
    0xC00020: "NEC Corporation", 0xC00021: "Hiber", 0xC00024: "NTT (Nippon Telephone and Telegraph)",
    0xC00025: "International Centre for Free and Open Source Software (ICFOSS)", 0xC00028: "Lacuna Space",
    0xC00029: "Andorra Telecom", 0xC0002A: "Xiamen Milesight IoT Co., Ltd.", 0xC0002B: "Grenoble Alps University",
    0xC0002E: "Spectrum", 0xC0002F: "Afnic", 0xC00032: "Microshare Inc.", 0xC00033: "HEIG-VD",
    0xC00037: "Alperia Fiber", 0xC00038: "First Snow Co., Ltd", 0xC00039: "Acklio", 0xC0003B: "Meshed Pty Ltd",
    0xC0003C: "Birdz", 0xC0003D: "Arthur D Riley & Co Ltd", 0xC0003E: "Komro GmbH", 0xC0003F: "RSAWEB",
    0xC00040: "Ceske Radiokomunikace", 0xC00041: "CM Systems LLC", 0xC00042: "MIOT Melita.io Technology GmbH",
    0xC00043: "PROESYS S.r.l.", 0xC00044: "MeWe, Inc", 0xC00045: "Alpha-Omega Technology GmbH & Co. KG",
    0xC00046: "SSE Contracting Limted t/a Mayflower Smart Control", 0xC00047: "VEGA Grieshaber KG",
    0xC00048: "Afghan Wireless Communication Company", 0xC00049: "API-K", 0xC0004A: "Decstream LLC",
    0xC0004B: "Nova Track Ltd", 0xC0004C: "IMT Atlantique", 0xC0004D: "Machines Talk",
    0xC0004E: "Yosensi Sp. z o.o.", 0xC0004F: "The Saira 2.0, LLC dba The IoT Solutions",
    0xC00050: "Neptune Technology Group", 0xC00051: "myDevices", 0xC00052: "Savoie Mont Blanc University",
    0xC00053: "Decentralized Wireless Foundation Inc", 0xC00054: "X-Telia Group Inc", 0xC00055: "Deviceroy",
    0xC00056: "Eutelsat S.A.", 0xC00057: "Bejing Dingtek Technology Corp. Ltd",
    0xC00058: "The Things Network Foundation", 0xC00059: "Quandify AB", 0xC0005A: "Hutchison Drei Austria GmbH",
    0xC0005B: "Agrology, PBC", 0xC0005C: "mHascaro GmbH", 0xC00068: "ELSYS", 0xC00074: "Swisscom",
    0xE00020: "Techtenna b.v.", 0xE00030: "LNX Solutions", 0xE00040: "Cometa Sas",
}


def _index():
    found = {}
    for net_id, operator in REGISTRY.items():
        kind = net_id >> 21
        found.setdefault((kind, net_id & ((1 << _NWKID_BITS[kind]) - 1)), (net_id, operator))
    return found


_BY_PREFIX = _index()


def dev_addr(frame):
    """The device address of a LoRaWAN data frame as (message type, address), or None for anything else."""
    if len(frame) < 12:
        return None
    mtype, major = frame[0] >> 5, frame[0] & 3
    if major or mtype not in DATA or 8 + (frame[5] & 15) > len(frame) - 4:
        return None
    return mtype, int.from_bytes(frame[1:5], "little")


def lookup(address):
    """(NetID, operator, exact) for a device address, or None when no registry row has its prefix. exact is False
    for types 3 to 7, where only part of the NetID reaches the air and the row is the likeliest owner."""
    kind = 0
    while kind < 7 and address & (0x80000000 >> kind):
        kind += 1
    bits = _NWKID_BITS[kind]
    nwk_id = ((address << (kind + 1)) & 0xFFFFFFFF) >> (32 - bits)
    row = _BY_PREFIX.get((kind, nwk_id))
    if row is None:
        return None
    return row[0], row[1], kind < 3


def address_for(net_id):
    """02:4C:57 and the three NetID bytes: an address no radio has, the same for one operator on every drive."""
    return "02:4C:57:%02X:%02X:%02X" % (net_id >> 16 & 255, net_id >> 8 & 255, net_id & 255)


class Operators:
    """Which operators count. An uplink carries a CRC the radio has checked, so it counts at once. A downlink has
    none, so the same operator must be heard again within the hour."""

    def __init__(self):
        self.heard = {}

    def note(self, frame, rssi, now):
        """The operator a frame names as {"net_id", "operator", "address", "rssi", "exact"}, or None."""
        found = dev_addr(frame)
        if found is None:
            return None
        mtype, address = found
        row = lookup(address)
        if row is None or row[0] <= 1:
            return None
        net_id, operator, exact = row
        slot = self.heard.get(net_id)
        if slot is None:
            if len(self.heard) >= CAP:
                del self.heard[min(self.heard, key=lambda key: self.heard[key][0])]
            slot = self.heard[net_id] = [now, mtype in UPLINK]
        elif not slot[1]:
            slot[1] = mtype in UPLINK or now - slot[0] <= CONFIRM_SECONDS
        slot[0] = now
        if not slot[1]:
            return None
        return {"net_id": net_id, "operator": operator, "address": address_for(net_id),
                "rssi": max(-127, min(0, rssi)) if isinstance(rssi, (int, float)) else None, "exact": exact}
