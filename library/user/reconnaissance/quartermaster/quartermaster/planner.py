"""Shares the Wi-Fi channels of a country between the nodes in use, so that together they finish a sweep soonest.

Each node scans only its share. The channels a country allows are those of ESP-IDF 5.5 for the ESP32-C5, so a
node is never given a channel it would skip. Adapters in the Cardputer keep sweeping every channel: Linux does not
let Quartermaster limit them.

A wireless node scans with the same times on each channel, but after every 0.6 s or so of scanning it goes back to
the hub's channel to hand over what it heard, which takes up to 150 ms. Its channels take it longer, so the split
counts its time as AIR_SLOWER times the time on the channels and gives it a smaller share.
"""

from collections import namedtuple

ACTIVE_MIN, ACTIVE_MAX, PASSIVE = 30, 80, 110
TIMES = (ACTIVE_MIN, ACTIVE_MAX, PASSIVE)
GHZ5 = (36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144,
        149, 153, 157, 161, 165, 169, 173, 177)
BUSY = (1, 6, 11)
BUSY_FROM = 3
AIR_SLOWER = 1.15

_CE = (13, ((36, 64), (100, 140), (149, 173)))
_RULES = {
    "01": (11, ((36, 64),)),
    "AU": (13, ((36, 64), (100, 116), (132, 144), (149, 165), (173, 173))),
    "BR": (13, ((36, 64), (100, 140), (149, 165))),
    "CA": (13, ((36, 64), (100, 144), (149, 165), (173, 177))),
    "CN": (13, ((36, 64), (149, 165))),
    "GB": (13, ((36, 64), (100, 144), (149, 165))),
    "HK": (13, ((36, 64), (100, 144), (149, 165))),
    "IN": (13, ((36, 64), (100, 140), (149, 173))),
    "JP": (13, ((36, 64), (100, 144))),
    "KR": (13, ((36, 64), (100, 140), (149, 165))),
    "MX": (13, ((36, 64), (100, 144), (149, 165))),
    "NZ": (13, ((36, 64), (100, 144), (149, 173))),
    "TW": (13, ((36, 64), (100, 144), (149, 165))),
    "US": (11, ((36, 64), (100, 144), (149, 165), (173, 177))),
}
_RULES.update(dict.fromkeys(("AT", "BE", "BG", "CH", "CY", "CZ", "DE", "DK", "EE", "ES", "FI", "FR", "GR", "HR", "HU",
                             "IE", "IS", "IT", "LI", "LT", "LU", "LV", "MT", "NL", "NO", "PL", "PT", "RO", "SE", "SI",
                             "SK"), _CE))
COUNTRIES = tuple(sorted(_RULES))

Plan = namedtuple("Plan", "version country ghz2 ghz5 active_min active_max passive ble")


def channels(country):
    """(band, channel) of every channel a node scans in the country, 2.4 GHz first. Never channel 14."""
    top, ranges = _RULES.get(country, _RULES["01"])
    ghz5 = [("5", ch) for ch in GHZ5 if any(low <= ch <= high for low, high in ranges)]
    return [("2.4", ch) for ch in range(1, top + 1)] + ghz5


def passive(band, channel):
    """The node listens without asking on DFS channels and on 12 to 14 and 169 to 177."""
    if band == "2.4":
        return channel >= 12
    return 52 <= channel <= 144 or channel >= 169


def cost(band, channel, times=TIMES):
    return times[2] if passive(band, channel) else times[1]


def bitmaps(share):
    """ESP-IDF channel bitmaps of a share. A band without channels is skipped (bit 0)."""
    ghz2 = ghz5 = 0
    for band, channel in share:
        if band == "2.4":
            ghz2 |= 1 << channel
        else:
            ghz5 |= 1 << (GHZ5.index(channel) + 1)
    return ghz2 or 1, ghz5 or 1


def share_of(plan):
    """The (band, channel) a plan scans."""
    found = [("2.4", ch) for ch in range(1, 15) if not plan.ghz2 & 1 and plan.ghz2 >> ch & 1]
    return found + [("5", ch) for i, ch in enumerate(GHZ5) if not plan.ghz5 & 1 and plan.ghz5 >> (i + 1) & 1]


def sweep_ms(share, times=TIMES):
    return sum(cost(band, ch, times) for band, ch in share)


def _items(country, count, bands=None):
    items = [item for item in channels(country) if bands is None or item[0] in bands]
    if count >= BUSY_FROM:
        items += [("2.4", ch) for ch in BUSY if ("2.4", ch) in items]
    return items


def _cut(items, count, times, weights):
    """Cut the channels, in order, into `count` runs, run k for a node `weights[k]` times as slow: the slowest run as
    quick as can be, then fewest runs that cross from one band into the other."""
    costs = [cost(band, ch, times) for band, ch in items]
    total = len(items)
    sums = [0]
    for value in costs:
        sums.append(sums[-1] + value)

    def crosses(i, j):
        return int(items[i][0] != items[j - 1][0])

    best = {(0, 0): (0, 0, None)}
    for k in range(1, count + 1):
        for j in range(k, total - (count - k) + 1):
            choice = None
            for i in range(k - 1, j):
                before = best.get((k - 1, i))
                if before is None:
                    continue
                score = (max(before[0], (sums[j] - sums[i]) * weights[k - 1]), before[1] + crosses(i, j), i)
                if choice is None or score[:2] < choice[:2]:
                    choice = score
            if choice is not None:
                best[(k, j)] = choice
    cuts, j = [], total
    for k in range(count, 0, -1):
        i = best[(k, j)][2]
        cuts.append(items[i:j])
        j = i
    return cuts[::-1]


def _spread(items, nodes, times, weight):
    """Nodes that cannot scan every band: the slowest channels first, each to the least busy node that can take it."""
    shares = {node_id: [] for node_id, _ in nodes}
    loads = dict.fromkeys(shares, 0)
    bands = {node_id: {b for b, cap in (("2.4", "wifi24"), ("5", "wifi5")) if cap in caps} for node_id, caps in nodes}
    for band, ch in sorted(items, key=lambda item: (-cost(item[0], item[1], times), item)):
        able = [node_id for node_id, _ in nodes if band in bands[node_id] and (band, ch) not in shares[node_id]]
        if able:
            node_id = min(able, key=lambda n: (loads[n], len({b for b, _ in shares[n]} | {band}), n))
            shares[node_id].append((band, ch))
            loads[node_id] += cost(band, ch, times) * weight[node_id]
    return shares


def split(country, nodes, times=TIMES, bands=None, slow=()):
    """{node id: [(band, channel)]} for nodes given as (node id, capabilities), on the bands kept (None: all). The
    nodes in `slow` are wireless nodes.

    Every channel goes to one node, except that with three nodes or more 1, 6 and 11 go to two different nodes."""
    nodes = sorted((node_id, frozenset(caps)) for node_id, caps in nodes)
    if not nodes:
        return {}
    weight = {node_id: AIR_SLOWER if node_id in slow else 1.0 for node_id, _ in nodes}
    items = _items(country, len(nodes), bands)
    if any(not {"wifi24", "wifi5"} <= caps for _, caps in nodes):
        shares = _spread(items, nodes, times, weight)
    else:
        cuts = _cut(items, min(len(nodes), len(items)), times, [weight[node_id] for node_id, _ in nodes]) \
            if items else []
        shares = {node_id: list(cuts[i]) if i < len(cuts) else [] for i, (node_id, _) in enumerate(nodes)}
        for node_id in shares:
            for item in set(shares[node_id]):
                while shares[node_id].count(item) > 1:
                    shares[node_id].remove(item)
                    others = [n for n in shares if item not in shares[n]]
                    taker = min(others, key=lambda n: (sweep_ms(shares[n], times) * weight[n], "2.4" not in
                                                       {b for b, _ in shares[n]}, n))
                    shares[taker].append(item)
    return {node_id: sorted(share, key=lambda item: (item[0] != "2.4", item[1])) for node_id, share in shares.items()}


def make(country, nodes, previous=None, version=1, times=TIMES, bands=None, slow=()):
    """The plan of each node, given as (node id, capabilities, Bluetooth wanted), on the bands kept (None: all). The
    nodes in `slow` are wireless nodes.

    A node whose share, times and Bluetooth are what it already has keeps its plan and version; the others get
    `version`."""
    country = country if country in _RULES else "01"
    previous = previous or {}
    shares = split(country, [(node_id, caps) for node_id, caps, _ in nodes], times, bands, slow)
    plans = {}
    for node_id, caps, ble in nodes:
        ghz2, ghz5 = bitmaps(shares[node_id])
        plan = Plan(version, country, ghz2, ghz5, times[0], times[1], times[2], bool(ble) and "ble" in caps)
        old = previous.get(node_id)
        plans[node_id] = old if old is not None and old._replace(version=version) == plan else plan
    return plans


def arguments(plan):
    """The fields of the #PLAN command."""
    return (str(plan.version), plan.country, "%04x" % plan.ghz2, "%x" % plan.ghz5, str(plan.active_min),
            str(plan.active_max), str(plan.passive), "1" if plan.ble else "0")
