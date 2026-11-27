"""Deep scan: spare USB adapters listen in monitor mode while a wardrive or Recon runs.

Which adapter listens is decided so that no band loses its managed scans: every band of the listening adapter must
still be swept by another adapter, and 6 GHz by another 6 GHz adapter. The built-in radio, an adapter on a network
and the only 6 GHz adapter always keep scanning normally.

With All adapters listen, every USB adapter beyond the few that keep each band in managed sweeps listens, each on its
own share of the channels, as many as the frame reader can keep up with. An adapter that drops out hands its channels
to the others at once and listens again once it is back.

The listen pattern follows flock-you (11, 6 and 1 at 250 ms, downwards, as Flock cameras hop upwards every 125 ms)
and SquachWatch (the other 2.4 GHz channels by how busy they are, and a slice of the busy 5 GHz channels).
"""

import multiprocessing
import os
import queue
import threading
import time

from . import faults, planner, radio_helper

DRIVERS = frozenset({"mt7921u", "mt7925u", "mt76x2u", "mt76x0u", "rtw88_8822bu", "rtw88_8821cu", "ath9k_htc"})
FLOCK_CHANNELS = (11, 6, 1)
FLOCK_DWELL, FILL_DWELL, FILL_BUDGET = 250, 110, 900
SLICE5_MS, LOOK5_BUSY, LOOK5_QUIET = 1500, 250, 150
SLOW_SWITCH_MS, SLOW_DWELL = 40, 150
SWITCH_MS = 30
CPU_LIMIT = 25.0
FORWARD_QUEUE = 64
LISTEN_CAP = 6
START_CAP = 3
CAPTURE_BUDGET = 18.0
OVERHEAD = 1.5
PSC6 = tuple(range(5, 234, 16))
LOOK6 = 150
STAGGER = 1.5
CALM = 6
MOVED_FOR = 30.0
CALM_MOST = 48
RETRY_JOIN = 60.0
MAX_STEPS = 64
REASONS = {
    "builtin": "Built-in: always scans normally",
    "only6": "Only 6 GHz radio: scans normally",
    "no_monitor": "No monitor mode in this driver",
    "connected": "Connected to a network: left alone",
    "band": "Needed to keep its bands scanned",
    "other": "Another adapter listens",
    "chosen": "Not the adapter picked in Settings",
    "keeper": "Keeps its bands in normal scans",
    "cap": "Listen limit for this CPU reached",
    "held": "Paused to save USB power",
    "refused": "Could not listen: tried again soon",
}


def _is_alfa(adapter):
    """By the name the adapter gives itself; the label is shared by every adapter with the same chip id."""
    text = str(adapter.get("product") or adapter.get("label") or "").lower()
    return "alfa" in text or "awus036ax" in text.replace(" ", "")


def assign(adapters, nodes=(), helper=None, choice="auto"):
    """Roles for the adapters of a wardrive: {"monitor": adapter or None, "roles": {interface: "monitor" | "managed"},
    "reasons": {interface: why it is not the monitor}, "unavailable": why there is no monitor, or ""}.

    helper: the radio helper's `adapters` answer, which says which adapter is connected or carries the default route.
    nodes: the bands ("wifi24", "wifi5") of the nodes in use; they cover 2.4 and 5 GHz but never 6 GHz."""
    live = {a.get("interface"): a for a in helper or ()}
    roles = {a["interface"]: "managed" for a in adapters}
    reasons = {}
    node_bands = set()
    for band in nodes:
        node_bands.add({"wifi24": "2.4", "wifi5": "5"}.get(band, band))
    node_bands &= {"2.4", "5"}
    candidates = []
    for a in adapters:
        name = a["interface"]
        state = live.get(name, {})
        if not a.get("external"):
            reasons[name] = REASONS["builtin"]
        elif not a.get("monitor") or a.get("driver") not in DRIVERS or state.get("monitor") is False:
            reasons[name] = REASONS["no_monitor"]
        elif state.get("connected") or state.get("default_route"):
            reasons[name] = REASONS["connected"]
        elif not _covered(a, adapters, node_bands):
            reasons[name] = REASONS["only6"] if "6" in a.get("bands", ()) and not any(
                o is not a and "6" in o.get("bands", ()) for o in adapters) else REASONS["band"]
        else:
            candidates.append(a)
    picked = None
    if choice not in (None, "", "auto"):
        picked = next((a for a in candidates if a["interface"] == choice), None)
        if picked is None:
            why = reasons.get(choice) or ("Not plugged in" if choice not in roles else REASONS["band"])
            return {"monitor": None, "roles": roles, "reasons": reasons,
                    "unavailable": "%s: %s" % (choice, why)}
    elif candidates:
        picked = sorted(candidates, key=lambda a: ("6" in a.get("bands", ()), _is_alfa(a),
                                                   adapters.index(a)))[0]
    if picked is None:
        if not any(a.get("external") for a in adapters):
            why = "Needs a USB Wi-Fi adapter with monitor mode"
        elif len([a for a in adapters if a.get("external")]) == 1:
            only = next(a for a in adapters if a.get("external"))
            why = reasons.get(only["interface"]) or "Needs a second USB adapter"
            if why == REASONS["only6"] or why == REASONS["band"]:
                why = "Needs a second USB adapter; %s keeps 6 GHz" % only.get("label", only["interface"])
        else:
            why = "No spare adapter can listen without losing a band"
        return {"monitor": None, "roles": roles, "reasons": reasons, "unavailable": why}
    roles[picked["interface"]] = "monitor"
    for a in candidates:
        if a is not picked:
            reasons[a["interface"]] = REASONS["other"]
    return {"monitor": picked, "roles": roles, "reasons": reasons, "unavailable": ""}


def _covered(adapter, adapters, node_bands):
    others = [o for o in adapters if o is not adapter and o.get("bands")]
    for band in adapter.get("bands", ()):
        managed = any(band in o.get("bands", ()) for o in others)
        if band == "6":
            if not managed:
                return False
        elif not managed and band not in node_bands:
            return False
    return True


def keeps_six(adapters, roles):
    """Whether some managed adapter still sweeps 6 GHz, when any adapter can."""
    if not any("6" in a.get("bands", ()) for a in adapters):
        return True
    return any("6" in a.get("bands", ()) and roles.get(a["interface"]) == "managed" for a in adapters)


def _can_listen(adapter, state):
    return bool(adapter.get("external") and adapter.get("monitor") and adapter.get("driver") in DRIVERS and
                state.get("monitor") is not False)


def all_listen(cfg, adapters, helper=None):
    """Whether All adapters listen applies: Deep scan on, the setting on Auto, the monitor adapter on Auto and at
    least two USB adapters that can listen."""
    if not cfg.get("deep_scan") or cfg.get("deep_scan_all", "auto") != "auto":
        return False
    if cfg.get("deep_scan_adapter", "auto") not in (None, "", "auto"):
        return False
    live = {a.get("interface"): a for a in helper or ()}
    return sum(1 for a in adapters if _can_listen(a, live.get(a["interface"], {}))) >= 2


def assign_all(adapters, helper=None, cap=LISTEN_CAP, held=(), listening=(), stay=()):
    """Roles with All adapters listen: the fewest USB adapters that keep every band any adapter has in managed
    sweeps (6 GHz by a 6 GHz radio), and up to `cap` of the others listening. The built-in radio, an adapter on a
    network, one without monitor mode and the adapters in `held` or `stay` stay managed. The adapters in `held` are
    paused and sweep nothing, so their bands must be kept by others; those in `stay` sweep as usual. Adapters already
    in `listening` keep listening rather than trade places with an equal one.

    {"monitor": first listener or None, "monitors": [...], "roles", "reasons", "unavailable"}."""
    live = {a.get("interface"): a for a in helper or ()}
    listening = set(listening)
    roles = {a["interface"]: "managed" for a in adapters}
    reasons, candidates = {}, []
    for a in adapters:
        name, state = a["interface"], live.get(a["interface"], {})
        if not a.get("external"):
            reasons[name] = REASONS["builtin"]
        elif not _can_listen(a, state):
            reasons[name] = REASONS["no_monitor"]
        elif state.get("connected") or state.get("default_route"):
            reasons[name] = REASONS["connected"]
        elif name in held:
            reasons[name] = REASONS["held"]
        elif name in stay:
            reasons[name] = REASONS["refused"]
        else:
            candidates.append(a)
    need, have = set(), set()
    for a in adapters:
        need.update(a.get("bands") or ())
        if a not in candidates and a["interface"] not in held:
            have.update(a.get("bands") or ())
    pool = list(candidates)
    while need - have and pool:
        missing = need - have
        best = sorted(pool, key=lambda a: (-len(missing & set(a.get("bands") or ())), a["interface"] in listening,
                                           "6" not in (a.get("bands") or ()), not _is_alfa(a),
                                           -len(a.get("bands") or ()), adapters.index(a)))[0]
        if not missing & set(best.get("bands") or ()):
            break
        pool.remove(best)
        have.update(best.get("bands") or ())
        reasons[best["interface"]] = REASONS["keeper"]
    pool.sort(key=lambda a: (a["interface"] not in listening, "6" in (a.get("bands") or ()), _is_alfa(a),
                             adapters.index(a)))
    chosen, over = pool[:max(0, cap)], pool[max(0, cap):]
    for a in over:
        reasons[a["interface"]] = REASONS["cap"]
    for a in chosen:
        roles[a["interface"]] = "monitor"
    if not chosen:
        single = assign(adapters, (), helper)
        why = single["unavailable"] or "No spare adapter can listen without losing a band"
        return {"monitor": None, "monitors": [], "roles": roles, "reasons": reasons, "unavailable": why}
    return {"monitor": chosen[0], "monitors": chosen, "roles": roles, "reasons": reasons, "unavailable": ""}


def listen_cap(stats, listeners):
    """How many adapters may listen, from what the frame reader measured: its Python cost per frame and the frames a
    second of each listener, with the helper's relay on top, kept within CAPTURE_BUDGET of one core. None before
    there is a measurement."""
    parse_us, fps = stats.get("parse_us"), stats.get("frames_per_s")
    if not listeners or not isinstance(parse_us, (int, float)) or not isinstance(fps, (int, float)) or fps <= 0:
        return None
    each = fps / listeners * parse_us * OVERHEAD / 1e4
    if each <= 0:
        return LISTEN_CAP
    return max(1, min(LISTEN_CAP, int(CAPTURE_BUDGET // each)))


def freq_of(band, channel):
    if band == "6":
        return 5950 + 5 * channel
    return (2484 if channel == 14 else 2407 + 5 * channel) if band == "2.4" else 5000 + 5 * channel


def band_channel(freq):
    freq = int(freq)
    if freq < 3000:
        return "2.4", (14 if freq == 2484 else (freq - 2407) // 5)
    if freq > 5925:
        return "6", (freq - 5950) // 5
    return "5", (freq - 5000) // 5


class HopPlan:
    """The monitor's listen pattern, rebuilt each cycle from how busy each channel was."""

    def __init__(self, country="US", mode="balanced", allowed=None):
        self.mode, self.country = mode, country
        found = planner.channels(country)
        allowed = set(allowed) if allowed else None
        ok = lambda band, ch: allowed is None or freq_of(band, ch) in allowed
        self.ghz2 = [ch for band, ch in found if band == "2.4" and ok(band, ch)]
        self.ghz5 = [ch for band, ch in found if band == "5" and ok(band, ch)]
        self.flock = [ch for ch in FLOCK_CHANNELS if ch in self.ghz2]
        self.fill = [ch for ch in self.ghz2 if ch not in self.flock]
        self.min_dwell = FILL_DWELL
        self.rates2, self.rates5, self.rates6 = {}, {}, {}
        self.quiet_next = 0

    def slower(self):
        self.min_dwell = max(self.min_dwell, SLOW_DWELL)

    def heard(self, per_freq):
        """Frames a second per frequency in the last stretch, folded in as SquachWatch does (3/4 old, 1/4 new). A
        channel missing from the stretch was silent, so it cools down too."""
        fresh = {}
        for freq, rate in per_freq.items():
            fresh[band_channel(freq)] = rate
        for band, table in (("2.4", self.rates2), ("5", self.rates5), ("6", self.rates6)):
            for ch in set(table) | {c for b, c in fresh if b == band}:
                table[ch] = (table.get(ch, 0.0) * 3 + fresh.get((band, ch), 0.0)) / 4
                if band != "2.4" and table[ch] < 0.25:
                    table[ch] = 0.0

    def _fill(self, dwell=None):
        if dwell is not None:
            return [(freq_of("2.4", ch), max(dwell, self.min_dwell)) for ch in self.fill]
        top = max([self.rates2.get(ch, 0.0) for ch in self.fill] or [0.0])
        shares = {ch: 2 if not top else (4 if self.rates2.get(ch, 0.0) * 4 >= top else
                                         2 if self.rates2.get(ch, 0.0) else 1) for ch in self.fill}
        total = sum(shares.values()) or 1
        return [(freq_of("2.4", ch), max(self.min_dwell, FILL_BUDGET * shares[ch] // total)) for ch in self.fill]

    def _slice5(self):
        out, budget = [], SLICE5_MS
        busy = sorted((ch for ch in self.ghz5 if self.rates5.get(ch)), key=lambda ch: -self.rates5[ch])
        for ch in busy:
            if budget < LOOK5_BUSY:
                break
            out.append((freq_of("5", ch), LOOK5_BUSY))
            budget -= LOOK5_BUSY
        quiet = [ch for ch in self.ghz5 if not self.rates5.get(ch)]
        taken = 0
        while quiet and taken < 2 and budget >= LOOK5_QUIET:
            ch = quiet[self.quiet_next % len(quiet)]
            self.quiet_next += 1
            out.append((freq_of("5", ch), max(LOOK5_QUIET, self.min_dwell)))
            budget -= LOOK5_QUIET
            taken += 1
        return out

    def build(self):
        """[(MHz, dwell ms)] for the helper's hop_plan."""
        flock = [(freq_of("2.4", ch), FLOCK_DWELL) for ch in self.flock]
        if self.mode == "flock":
            return flock * 4 + self._fill(FILL_DWELL)
        return flock + self._fill() + self._slice5()

    @staticmethod
    def cycle_seconds(plan):
        """How long the helper takes for one round of the plan: the dwells plus each channel change."""
        return sum(dwell + SWITCH_MS for _, dwell in plan) / 1000.0


class SplitPlan(HopPlan):
    """The listen patterns of several monitor adapters at once: each channel goes to one of them, so together they
    cover every channel they can tune. One adapter takes the Flock channels 11, 6 and 1; the other channels go to the
    adapter with the least to do, the busiest and slowest first. The 6 GHz preferred scanning channels go to 6 GHz
    adapters only when `six` says a 6 GHz radio still sweeps normally.

    radios: [(vif, bands, allowed MHz or None)]."""

    def __init__(self, country="US", mode="balanced", radios=(), six=False):
        super().__init__(country, mode)
        self.radios = [(vif, tuple(bands or ()), set(allowed) if allowed else None) for vif, bands, allowed in radios]
        self.six = six

    @classmethod
    def taking(cls, plan, radios, six):
        """A split plan that keeps what an earlier plan learned about how busy each channel is."""
        split = cls(plan.country, plan.mode, radios, six)
        split.rates2, split.rates5, split.rates6 = plan.rates2, plan.rates5, plan.rates6
        split.min_dwell, split.quiet_next = plan.min_dwell, plan.quiet_next
        return split

    @staticmethod
    def _can(radio, band, ch):
        _, bands, allowed = radio
        return band in bands and (allowed is None or freq_of(band, ch) in allowed)

    def _items(self):
        items = [(f, d) for f, d in self._fill()]
        for ch in self.ghz5:
            items.append((freq_of("5", ch), LOOK5_BUSY if self.rates5.get(ch) else max(LOOK5_QUIET, self.min_dwell)))
        if self.six:
            for ch in PSC6:
                items.append((freq_of("6", ch), LOOK6 if self.rates6.get(ch) else max(LOOK5_QUIET, self.min_dwell)))
        return items

    def build_all(self):
        """{vif: [(MHz, dwell ms)]}, each channel on one adapter only."""
        out = {vif: [] for vif, _, _ in self.radios}
        load = dict.fromkeys(out, 0)
        if not self.radios:
            return out
        order = {vif: i for i, (vif, _, _) in enumerate(self.radios)}
        flock = [r for r in self.radios if self.flock and all(self._can(r, "2.4", ch) for ch in self.flock)]
        items = self._items()
        if flock:
            keeper = min(flock, key=lambda r: (len(r[1]), order[r[0]]))
            steps = [(freq_of("2.4", ch), FLOCK_DWELL) for ch in self.flock]
            out[keeper[0]] = steps * (4 if self.mode == "flock" else 1)
            load[keeper[0]] = sum(d + SWITCH_MS for _, d in out[keeper[0]])
        else:
            items += [(freq_of("2.4", ch), FLOCK_DWELL) for ch in self.flock]
        for freq, dwell in sorted(items, key=lambda item: (-item[1], item[0])):
            band, ch = band_channel(freq)
            able = [r for r in self.radios if self._can(r, band, ch) and len(out[r[0]]) < MAX_STEPS]
            if not able:
                continue
            vif = min(able, key=lambda r: (load[r[0]], len(r[1]), order[r[0]]))[0]
            out[vif].append((freq, dwell))
            load[vif] += dwell + SWITCH_MS
        flock_freqs = {freq_of("2.4", ch) for ch in self.flock}
        for vif, steps in out.items():
            head = [s for s in steps if s[0] in flock_freqs and s[1] == FLOCK_DWELL]
            rest = sorted((s for s in steps if s not in head), key=lambda s: s[0])
            out[vif] = (head + rest)[:MAX_STEPS]
        return out


def wanted(cfg):
    return radio_helper.wanted(cfg)


def _node_bands(nodes):
    return {{"wifi24": "2.4", "wifi5": "5"}.get(n, n) for n in nodes} & {"2.4", "5"}


def _process_cpu(pid, proc="/proc"):
    """Seconds of CPU a process has used, or 0 when it cannot be read."""
    if not pid:
        return 0.0
    try:
        with open(os.path.join(proc, str(pid), "stat"), encoding="ascii", errors="replace") as handle:
            fields = handle.read().rsplit(")", 1)[1].split()
        return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")
    except (OSError, IndexError, ValueError):
        return 0.0


class DeepScan:
    """The radio helper session of one wardrive or Recon: the monitors, direct scans and tuning, all put back at stop.

    Nothing here runs unless one of the three settings is on."""

    def __init__(self, cfg, connect=radio_helper.connect, process=None, clock=time.monotonic):
        self.cfg = cfg
        self._connect = connect
        self._process = process
        self.clock = clock
        self.client = None
        self.state, self.detail = "off", ""
        self.roles = {"monitor": None, "monitors": [], "roles": {}, "reasons": {}, "unavailable": ""}
        self.listeners = {}
        self.steps = {}
        self.all_mode = False
        self.cap = START_CAP
        self.ceiling = LISTEN_CAP
        self._calm, self._calm_need = 0, CALM
        self.paused = set()
        self.held = set()
        self.joining = {}
        self._moved = {}
        self.refused = {}
        self.dropped = self.joined = 0
        self.timers = True
        self.tuned = []
        self.tuning = {}
        self.eased = set()
        self.stats = {}
        self.counts = {"flock": 0, "deauth": 0, "networks": 0}
        self.error = ""
        self.level = 0
        self.plan = None
        self.sinks = {}
        self.helper_adapters = []
        self._asked = set()
        self.node_bands = set()
        self._plan_at, self._cycle = 0.0, 3.0
        self._inbox = self._outbox = self._worker = None
        self._forward = queue.Queue(maxsize=FORWARD_QUEUE)
        self.forward_dropped = 0
        self._stop = threading.Event()
        self._lock = threading.RLock()
        self._threads = []
        self._cpu = {}
        self._cpu_at = None
        self._helper_pid = None
        self._last_adapters = []

    @property
    def vif(self):
        return next(iter(self.listeners), None)

    @property
    def monitor(self):
        for vif, entry in list(self.listeners.items()):
            return dict(entry["adapter"], interface=vif, role="monitor", original=entry["original"])
        return None

    def open(self):
        if not wanted(self.cfg):
            return False
        self.client, self.state, self.detail = self._connect()
        if self.client is not None and hasattr(self.client, "peer_pid"):
            self._helper_pid = self.client.peer_pid()
        return self.client is not None

    def plan_roles(self, adapters, nodes=()):
        """The adapters that keep scanning normally. The monitors, if any, are left out of them."""
        if self.client is None or not self.cfg.get("deep_scan"):
            return list(adapters)
        try:
            helper = self.client.request("adapters")["adapters"]
        except radio_helper.HelperError as exc:
            self.error = str(exc)[:80]
            return list(adapters)
        self.helper_adapters = helper
        self.node_bands = _node_bands(nodes)
        self._last_adapters = list(adapters)
        self.all_mode = all_listen(self.cfg, adapters, helper)
        if self.all_mode:
            self.roles = assign_all(adapters, helper, self.cap)
        else:
            self.roles = assign(adapters, nodes, helper, self.cfg.get("deep_scan_adapter", "auto"))
            self.roles["monitors"] = [self.roles["monitor"]] if self.roles["monitor"] is not None else []
        if not self.roles["monitors"] or not keeps_six(adapters, self.roles["roles"]):
            self.roles.update(monitor=None, monitors=[])
            return list(adapters)
        return [a for a in adapters if not any(a is m for m in self.roles["monitors"])]

    def managed(self, adapters):
        """The adapters that scan normally now: not listening, not about to listen and not paused."""
        busy = {e["original"] for e in self.listeners.values()} | set(self.listeners) | set(self.joining) | \
            self.paused
        return [a for a in adapters if a["interface"] not in busy and a.get("type") != "803"]

    def start(self, wifi_sink, frame_sink=None, deauth_sink=None, clash_sink=None):
        """Put the chosen adapters in monitor mode and start listening. False when none could, and then they must go
        back to managed scans; `managed` says which adapters scan normally either way."""
        monitors = list(self.roles.get("monitors") or ())
        if not monitors and self.roles.get("monitor") is not None:
            monitors = [self.roles["monitor"]]
        self.sinks = {"networks": wifi_sink, "frame": frame_sink, "deauth": deauth_sink, "clash": clash_sink}
        if self.client is None or not monitors:
            return False
        failed = None
        with self._lock:
            for adapter in monitors:
                try:
                    vif = self.client.request("monitor_start", iface=adapter["interface"])["vif"]
                except (radio_helper.HelperError, OSError) as exc:
                    failed = exc
                    self.refused[adapter["interface"]] = self.clock() + RETRY_JOIN
                    continue
                self._add(vif, adapter)
            try:
                if not self.listeners:
                    raise radio_helper.HelperError(str(failed))
                for vif in self._send_plan():
                    self._drop(vif, "", replan=False)
                if not self.listeners:
                    raise radio_helper.HelperError(self.error or "hop plan refused")
                self._start_worker()
                self.client.frames = self._receive
                for vif in list(self.listeners):
                    try:
                        self._capture(vif)
                    except (radio_helper.HelperError, OSError) as exc:
                        failed = exc
                        self._drop(vif, "", replan=False)
                if not self.listeners:
                    raise radio_helper.HelperError(str(failed))
            except (radio_helper.HelperError, OSError) as exc:
                self.error = "Monitor failed: %s. Scanning normally." % str(exc)[:60]
                self._stop_monitor()
                self.roles = dict(self.roles, monitor=None, monitors=[])
                return False
            if len(self.listeners) < len(monitors):
                self._replan()
        self._threads = [threading.Thread(target=self._dispatch, daemon=True, name="deepscan"),
                         threading.Thread(target=self._pump, daemon=True, name="deepscan-feed")]
        for thread in self._threads:
            thread.start()
        self._total_cpu(0.0)
        return True

    def _add(self, vif, adapter):
        freqs = next((h.get("freqs") for h in self.helper_adapters
                      if h.get("interface") == adapter["interface"]), None)
        self.listeners[vif] = {"adapter": adapter, "original": adapter["interface"], "freqs": freqs}
        self._make_plan()

    def _six_kept(self):
        """Whether a 6 GHz radio still sweeps normally, so the monitors may also listen on 6 GHz."""
        busy = {e["original"] for e in self.listeners.values()} | set(self.joining) | self.paused | self.held
        managed = [a for a in self._last_adapters if a["interface"] not in busy]
        return any("6" in (a.get("bands") or ()) for a in managed)

    def _make_plan(self):
        """The plan for the monitors there are now, keeping what the last plan learned."""
        old = self.plan
        country, mode = self.cfg.get("country", "US"), self.cfg.get("deep_scan_plan", "balanced")
        if not self.listeners:
            self.plan = None
            return
        if len(self.listeners) == 1:
            plan = HopPlan(country, mode, self.listeners[self.vif]["freqs"])
        else:
            radios = [(vif, e["adapter"].get("bands") or (), e["freqs"]) for vif, e in self.listeners.items()]
            plan = SplitPlan(country, mode, radios, self._six_kept())
        if old is not None:
            plan.rates2, plan.rates5, plan.rates6 = old.rates2, old.rates5, old.rates6
            plan.min_dwell, plan.quiet_next, plan.mode = old.min_dwell, old.quiet_next, old.mode
        self.plan = plan

    def _send_plan(self):
        """Each monitor's steps to the helper. Returns the monitors whose plan was refused."""
        if self.plan is None:
            return []
        if isinstance(self.plan, SplitPlan):
            plans = self.plan.build_all()
        else:
            plans = {self.vif: self.plan.build()}
        failed, cycles = [], []
        for vif, built in plans.items():
            steps = [[freq, 20, dwell] for freq, dwell in built][:MAX_STEPS]
            if not steps:
                continue
            try:
                reply = self.client.request("hop_plan", vif=vif, plan=steps)
            except radio_helper.HelperError as exc:
                self.error = str(exc)[:80]
                failed.append(vif)
                continue
            self.steps[vif] = steps
            measured = reply.get("cycle_ms") if isinstance(reply, dict) else None
            cycles.append(max(HopPlan.cycle_seconds([(f, d) for f, _, d in steps]),
                              measured / 1000.0 if isinstance(measured, (int, float)) else 0.0))
        self._plan_at = time.monotonic()
        if cycles:
            self._cycle = max(cycles)
        return failed

    def _capture(self, vif):
        if self.level >= 1:
            self.client.request("capture", vif=vif, mgmt_only=True)
        else:
            self.client.request("capture", vif=vif)

    def _start_worker(self):
        if self._worker is not None:
            return
        if self._process is not None:
            self._inbox, self._outbox, self._worker = self._process(self.vif, self.cfg.get("rssi_step", 4))
            return
        from . import monitor
        context = multiprocessing.get_context("spawn")
        reader, self._inbox = context.Pipe(duplex=False)
        self._outbox, writer = context.Pipe(duplex=False)
        self._worker = context.Process(target=monitor.run, args=(reader, writer, self.vif, self.cfg.get("rssi_step", 4)),
                                       daemon=True, name="deepscan-worker")
        self._worker.start()
        reader.close()
        writer.close()

    def _receive(self, body):
        try:
            self._forward.put_nowait(bytes(body))
        except queue.Full:
            self.forward_dropped += 1

    def _pump(self):
        while not self._stop.is_set():
            try:
                body = self._forward.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                self._inbox.send_bytes(body)
            except (OSError, ValueError):
                return
            self._cpu["pump"] = time.thread_time()

    def _dispatch(self):
        while not self._stop.is_set():
            try:
                if not self._outbox.poll(0.5):
                    self._upkeep()
                    continue
                kind, payload = self._outbox.recv()
            except (EOFError, OSError, ValueError):
                if not self._stop.is_set():
                    self.error = "Deep scan reader stopped. Scanning normally."
                return
            try:
                self._handle(kind, payload)
            except Exception:
                faults.note("Deep scan")
            self._upkeep()
            self._cpu["dispatch"] = time.thread_time()

    def _handle(self, kind, payload):
        if kind == "stats":
            payload = dict(payload, worker_cpu=payload.get("cpu"), cpu=self._total_cpu(payload.get("cpu")))
            self.stats = payload
            released = self._limit(payload) if self.all_mode else False
            self._degrade(payload, released)
            if self.plan is not None:
                self.plan.heard(payload.get("channels", {}))
            return
        if kind == "frame":
            self.counts["flock"] += 1
        elif kind == "deauth":
            self.counts["deauth"] += 1
        elif kind == "networks":
            self.counts["networks"] += len(payload)
        sink = self.sinks.get(kind)
        if sink is None:
            return
        if kind == "networks":
            sink(payload, self.monitor)
        else:
            sink(payload)

    def _limit(self, found):
        """With All adapters listen: as many monitors as the measured cost per frame allows, and never more than the
        whole CPU cost allowed last time it ran high. True when one was let go."""
        cap = listen_cap(found, len(self.listeners))
        if cap is None:
            return False
        self.cap = min(cap, self.ceiling)
        if len(self.listeners) <= max(1, self.cap) or not self._lock.acquire(blocking=False):
            return False
        try:
            while len(self.listeners) > max(1, self.cap):
                self._release_last("Busy CPU: %s scans normally again" % self._last_name())
        finally:
            self._lock.release()
        return True

    def _settle(self, cpu):
        """After the whole CPU cost ran high, one more adapter may listen only once it has stayed low long enough,
        and low enough to take one more; each time it runs high again, it waits twice as long."""
        count = len(self.listeners)
        if self.ceiling >= LISTEN_CAP or not count or cpu * (count + 1) / count > CPU_LIMIT * 0.8:
            self._calm = 0
            return
        self._calm += 1
        if self._calm >= self._calm_need and self.ceiling <= count:
            self.ceiling += 1
            self._calm = 0

    def _last_name(self):
        vif = next(reversed(self.listeners), None)
        return self.listeners[vif]["original"] if vif is not None else ""

    def _total_cpu(self, worker):
        """The share of one core Deep scan costs: the frame reader, the helper, and its threads in this process."""
        now = time.monotonic()
        spent = sum(self._cpu.values()) + getattr(self.client, "cpu", 0.0) + _process_cpu(self._helper_pid)
        last, self._cpu_at = self._cpu_at, (now, spent)
        if last is None or now <= last[0]:
            return worker
        return round((worker or 0.0) + 100.0 * max(0.0, spent - last[1]) / (now - last[0]), 1)

    def _helper_gone(self):
        closed = getattr(self.client, "closed", None)
        return isinstance(closed, threading.Event) and closed.is_set()

    def _upkeep(self):
        if self.listeners and self._helper_gone():
            self.release("The radio helper stopped. Scanning normally.")
            return
        if self.plan is None or self.client is None or not self.listeners or self.plan.mode != "balanced":
            return
        if time.monotonic() - self._plan_at >= max(3.0, self._cycle):
            if not self._lock.acquire(blocking=False):
                return
            try:
                for vif in self._send_plan():
                    if len(self.listeners) > 1:
                        self._drop(vif, self.error)
            finally:
                self._lock.release()

    def _degrade(self, found, released=False):
        gap = found.get("switch_gap_ms")
        if gap is not None and gap > SLOW_SWITCH_MS and self.plan is not None:
            self.plan.slower()
        cpu = found.get("cpu") or 0
        if cpu <= CPU_LIMIT:
            if self.all_mode:
                self._settle(cpu)
            return
        if len(self.listeners) > 1 or released:
            self._calm = 0
            if released:
                self.ceiling = min(self.ceiling, max(1, len(self.listeners)))
            elif self._lock.acquire(blocking=False):
                try:
                    self._release_last("Busy CPU: %s scans normally again" % self._last_name())
                    self.ceiling = max(1, len(self.listeners))
                finally:
                    self._lock.release()
            self.cap = min(self.cap, self.ceiling)
            self._calm_need = min(CALM_MOST, self._calm_need * 2)
            return
        self.level += 1
        try:
            if self.level == 1:
                for vif in list(self.listeners):
                    self.client.request("capture", vif=vif, mgmt_only=True)
            elif self.level == 2:
                self._forward.put_nowait(b"S")
            elif self.level == 3 and self.plan is not None:
                self.plan.mode = "flock"
                self._send_plan()
            elif self.level >= 4:
                self.cap = 0
                self.release("Busy CPU: Deep scan stopped. Scanning normally.")
        except (radio_helper.HelperError, queue.Full):
            pass

    def tune(self, adapters):
        if self.client is None or not self.cfg.get("radio_tuning"):
            return
        for a in adapters:
            name = a.get("interface")
            if not a.get("external") or name in self.listeners or name in self.eased:
                continue
            try:
                self.tuning[name] = self.client.request("tune", iface=name)
                if name not in self.tuned:
                    self.tuned.append(name)
            except radio_helper.HelperError as exc:
                self.tuning[name] = {"error": str(exc)[:60]}

    def ease(self, name):
        """Undo Radio tuning on one adapter while it stays plugged in, as USB power runs short."""
        if self.client is None or name not in self.tuned:
            return False
        try:
            self.client.request("untune", iface=name)
        except radio_helper.HelperError:
            return False
        self.tuned.remove(name)
        self.eased.add(name)
        self.tuning[name] = {"eased": True}
        return True

    def forget(self, name):
        """An eased adapter left, or another took its name: whatever has that name now is tuned as usual."""
        if name in self.eased:
            self.eased.discard(name)
            self.tuning.pop(name, None)

    def shed(self, why="USB power ran short: an adapter stopped listening"):
        """One listening adapter stops, and stays paused while it is plugged in, as USB power or the USB port runs
        short. The first monitor, which hears the Flock channels, stays. Returns its name, or None."""
        with self._lock:
            if len(self.listeners) < 2:
                return None
            name = self._last_name()
            self._release_last(why)
            self.paused.add(name)
            return name

    def watched(self):
        """(adapter, monitor interface) of each listening adapter, for Power guard to keep in view."""
        return [(e["adapter"], vif) for vif, e in list(self.listeners.items())]

    def moving(self):
        """Adapters Deep scan itself is moving between listening and normal scans, which are briefly in neither, so
        Power guard does not take that for an adapter that went away and came back."""
        return set(self.joining) | set(self._moved)

    def scanners(self, adapters):
        """The adapters as the Wi-Fi fleet should get them: with the helper for direct scans when that is on."""
        if self.client is None or not self.cfg.get("direct_scan"):
            return adapters
        return [dict(a, helper=self.client) if a.get("external") else a for a in adapters]

    def follow(self, adapters, present=None, nodes=None, held=()):
        """Adapters plugged in or pulled out during the drive: the monitors stay out of the managed scans, a new
        adapter gets tuned like the others. present: every Wi-Fi interface there is now; nodes: the bands of the
        nodes in use now; held: adapters Power guard paused.

        One monitor: when it went away, or its helper stopped, it is let go, so its adapter scans again once it is
        back. With All adapters listen: a monitor that dropped out hands its channels to the others at once, and an
        adapter that may listen does so STAGGER seconds after it shows up, also when it comes back."""
        if nodes is not None:
            self.node_bands = _node_bands(nodes)
        names = {a["interface"] for a in (adapters if present is None else present)}
        now = self.clock()
        with self._lock:
            self.held = set(held)
            gone = [vif for vif in self.listeners if vif not in names]
            self._moved = {name: at for name, at in self._moved.items()
                           if name not in names and now - at < MOVED_FOR}
            if not self.all_mode:
                if self.listeners and (gone or self._helper_gone()):
                    self.release("The monitor adapter went away. Scanning normally.", moved=not gone)
            elif self.listeners and self._helper_gone():
                self.release("The radio helper stopped. Scanning normally.")
            else:
                for vif in gone:
                    self.dropped += 1
                    self._drop(vif, "%s dropped out: its channels went to the other adapters" %
                               self.listeners[vif]["original"], replan=False, moved=False)
                if gone and self.listeners:
                    self._replan()
            self.paused = {name for name in self.paused if name in names}
            self.refused = {name: until for name, until in self.refused.items() if name in names and until > now}
            managed = [a for a in adapters if a["interface"] not in self.listeners and a.get("type") != "803"]
            self._last_adapters = managed + [e["adapter"] for e in self.listeners.values()]
            if not self.all_mode:
                chosen = self.roles.get("monitor")
                if self.vif is not None and chosen is not None and \
                        not _covered(chosen, managed + [chosen], self.node_bands):
                    self.release("Monitor handed back: another adapter left, so it scans its bands again.")
            elif self.client is not None and not self._helper_gone():
                self._balance(managed, set(held), now)
            managed = self.managed(managed)
        self.tune([a for a in managed if a["interface"] not in self.tuning])
        return self.scanners(managed)

    def _learn(self, adapters):
        """What the helper knows of adapters seen for the first time in this drive: their allowed channels and
        whether they are on a network. What it said of the others is kept, as a listening adapter has no managed
        interface to list."""
        known = {h.get("interface") for h in self.helper_adapters} | self._asked
        new = {a["interface"] for a in adapters} - known
        if not new:
            return
        self._asked |= new
        try:
            found = self.client.request("adapters")["adapters"]
        except (radio_helper.HelperError, OSError, KeyError, TypeError):
            return
        fresh = {h.get("interface") for h in found}
        self.helper_adapters = [h for h in self.helper_adapters if h.get("interface") not in fresh] + list(found)

    def _balance(self, managed, held, now):
        listening = {e["original"]: vif for vif, e in self.listeners.items()}
        pool = managed + [e["adapter"] for e in self.listeners.values()]
        self._learn(pool)
        roles = assign_all(pool, self.helper_adapters, self.cap, held | self.paused, set(listening),
                           set(self.refused))
        want = {a["interface"] for a in roles["monitors"]}
        handed = False
        for original, vif in listening.items():
            if original not in want:
                why = "Monitor handed back: %s scans its bands again." % original
                if roles["reasons"].get(original) == REASONS["cap"]:
                    why = "%s scans normally again: listen limit for this CPU." % original
                self._drop(vif, why, replan=False)
                handed = True
        if handed and self.listeners:
            self._replan()
        self.joining = {name: item for name, item in self.joining.items() if name in want}
        for adapter in roles["monitors"]:
            name = adapter["interface"]
            if name in listening:
                continue
            if name not in self.joining:
                self.joining[name] = (adapter, now)
                if self.timers:
                    timer = threading.Timer(STAGGER, self._join_due, args=(name,))
                    timer.daemon = True
                    timer.start()
            elif now - self.joining[name][1] >= STAGGER:
                self._join(name)
        adapters = [e["adapter"] for e in self.listeners.values()]
        self.roles = dict(roles, monitor=adapters[0] if adapters else None, monitors=adapters)

    def _join_due(self, name):
        with self._lock:
            if name in self.joining and not self._stop.is_set():
                self._join(name)

    def _join(self, name):
        adapter, _ = self.joining.pop(name)
        self._moved[name] = self.clock()
        if self.client is None or self._stop.is_set() or len(self.listeners) >= self.cap:
            return
        try:
            vif = self.client.request("monitor_start", iface=name)["vif"]
        except (radio_helper.HelperError, OSError) as exc:
            self.refused[name] = self.clock() + RETRY_JOIN
            self.error = "%s could not listen: %s" % (name, str(exc)[:50])
            return
        self._add(vif, adapter)
        try:
            if vif in self._send_plan():
                raise radio_helper.HelperError(self.error)
            if self._worker is None:
                self._start_worker()
                self._threads = [threading.Thread(target=self._dispatch, daemon=True, name="deepscan"),
                                 threading.Thread(target=self._pump, daemon=True, name="deepscan-feed")]
                for thread in self._threads:
                    thread.start()
            self.client.frames = self._receive
            self._capture(vif)
        except (radio_helper.HelperError, OSError) as exc:
            self.refused[name] = self.clock() + RETRY_JOIN
            self._drop(vif, "%s could not listen: %s" % (name, str(exc)[:50]))
            return
        self._moved.pop(name, None)
        self.joined += 1

    def _replan(self):
        self._make_plan()
        for vif in self._send_plan():
            if len(self.listeners) > 1:
                self._drop(vif, self.error, replan=False)

    def _drop(self, vif, why, replan=True, moved=True):
        """One monitor back to managed: the helper puts its adapter back, or forgets it when it went away."""
        entry = self.listeners.pop(vif, None)
        self.steps.pop(vif, None)
        if entry is None:
            return
        if moved:
            self._moved[entry["original"]] = self.clock()
        if why:
            self.error = why
        if self.client is not None:
            try:
                self.client.request("monitor_stop", vif=vif)
            except radio_helper.HelperError:
                pass
        if not self.listeners:
            if self.client is not None:
                self.client.frames = None
            self.plan = None
            self.roles = dict(self.roles, monitor=None, monitors=[])
        elif replan:
            self._replan()

    def _release_last(self, why):
        vif = next(reversed(self.listeners), None)
        if vif is not None:
            self._drop(vif, why)

    def radio_status(self):
        stats, out = self.stats, []
        for vif, entry in list(self.listeners.items()):
            adapter = entry["adapter"]
            out.append({"interface": vif, "method": "monitor", "sweeps": 0, "sweep_seconds": None,
                        "error": self.error if vif == self.vif else "", "label": adapter.get("label", ""),
                        "bands": [], "frames_per_s": stats.get("frames_per_s") if vif == self.vif else None,
                        "flock": self.counts["flock"] if vif == self.vif else 0, "original": entry["original"],
                        "channels": len({step[0] for step in self.steps.get(vif, ())})})
        return out

    def release(self, why, moved=True):
        """Hand every monitor adapter back to normal scans; the next look at the adapters picks them up."""
        self.error = why
        if moved:
            at = self.clock()
            for entry in list(self.listeners.values()):
                self._moved[entry["original"]] = at
        self._stop_monitor()
        self.plan = None
        self.roles = dict(self.roles, monitor=None, monitors=[])

    def _stop_monitor(self):
        with self._lock:
            if self.client is not None and self.listeners:
                self.client.frames = None
            for vif in list(self.listeners)[::-1]:
                if self.client is not None:
                    try:
                        self.client.request("monitor_stop", vif=vif)
                    except radio_helper.HelperError:
                        pass
                self.listeners.pop(vif, None)
                self.steps.pop(vif, None)

    def stop(self):
        """Put everything back: monitors to managed, tuning undone, then close. The helper also does this by itself
        when the connection closes, so a crash leaves nothing behind."""
        self._stop.set()
        self._stop_monitor()
        self.joining = {}
        for name in self.tuned[::-1]:
            try:
                self.client.request("untune", iface=name)
            except (radio_helper.HelperError, AttributeError):
                pass
        self.tuned = []
        if self._inbox is not None:
            try:
                self._inbox.send_bytes(b"")
            except (OSError, ValueError):
                pass
        if self._worker is not None and hasattr(self._worker, "join"):
            self._worker.join(timeout=3)
            if self._worker.is_alive():
                self._worker.terminate()
                self._worker.join(timeout=1)
        for end in (self._inbox, self._outbox):
            if end is not None and hasattr(end, "close"):
                end.close()
        for thread in self._threads:
            if thread is not threading.current_thread():
                thread.join(timeout=3)
        if self.client is not None:
            self.client.close()
            self.client = None

    def status(self):
        listeners = [{"interface": vif, "original": e["original"], "label": e["adapter"].get("label", ""),
                      "bands": list(e["adapter"].get("bands") or ()),
                      "channels": len({step[0] for step in self.steps.get(vif, ())})}
                     for vif, e in list(self.listeners.items())]
        return {"state": self.state, "detail": self.detail, "monitor": self.monitor, "vif": self.vif,
                "reasons": dict(self.roles.get("reasons", {})), "unavailable": self.roles.get("unavailable", ""),
                "stats": dict(self.stats), "counts": dict(self.counts), "error": self.error,
                "tuning": dict(self.tuning), "plan": self.cfg.get("deep_scan_plan", "balanced"),
                "level": self.level, "all": self.all_mode, "listeners": listeners, "cap": self.cap,
                "paused": sorted(self.paused), "joining": sorted(self.joining), "dropped": self.dropped,
                "joined": self.joined}
