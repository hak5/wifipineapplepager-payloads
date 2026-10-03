package main

import (
	"math"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	bleLost       = 5 * time.Second
	bleMaxDevices = 1024
	bleSmooth     = 2 * time.Second
	bleRateWin    = 10 * time.Second
	bleNoSignal   = -100
	bleTrendStep  = 3.0
)

// BLEDevice is the display state of one tracked BLE address.
type BLEDevice struct {
	Addr       string
	Random     bool
	Label      string
	Maker      string
	Kind       string
	Brand      string
	Type       string
	Appearance string
	Model      string   // decoded model, e.g. "AIRPODS PRO 2", "" when unknown
	AddrKind   string   // PUBLIC, STATIC, PRIVATE or NON-RESOLV
	MakerFull  string   // fuller maker name (company / member / OUI), "" when unknown
	BeaconInfo string   // e.g. "IBEACON 1234/5678", "EDDYSTONE URL"
	Services   []string // SIG names of advertised 16-bit services, at most 3
	FirstSeen  time.Time
	Name       string
	RSSI       int
	Peak       int
	AdvPerSec  float64
	TxPower    int
	HasTx      bool
	LastSeen   time.Time
}

// BLETrackView is the walk-around view of the one device being tracked.
type BLETrackView struct {
	BLEDevice
	Lost    bool
	PeakAt  time.Time
	Trend   string
	History []int
}

type bleSample struct {
	at   time.Time
	rssi int
}

type bleEntry struct {
	addr     string
	random   bool
	company  int
	mfrKind  string
	svcKind  string
	hint     string
	appearV  int // GAP appearance value, -1 when never seen
	services []int
	model    string
	beacon   string
	name     string
	cls      bleClass // identification, recomputed only when an input changes
	gen      int      // bumped on every input change; guards async classification
	lastRSSI int
	peak     int
	tx       int
	hasTx    bool
	first    time.Time
	last     time.Time   // any sighting, with or without RSSI
	lastAdv  time.Time   // last real advert (decoded, with RSSI)
	recent   []bleSample // adverts in the last bleRateWin
}

// BLETracker keeps per-device state from decoded adverts.
type BLETracker struct {
	mu      sync.Mutex
	expire  time.Duration
	devs    map[string]*bleEntry
	all     []time.Time // every advert in the last bleRateWin
	tracked string
	hist    []bleSample // tracked device adverts, last lockHistoryLen s
	tPeak   int
	tPeakAt time.Time
}

func NewBLETracker(expire time.Duration) *BLETracker {
	return &BLETracker{expire: expire, devs: map[string]*bleEntry{}, tPeak: bleNoSignal}
}

func (t *BLETracker) entry(addr string, at time.Time) *bleEntry {
	e := t.devs[addr]
	if e == nil {
		if len(t.devs) >= bleMaxDevices {
			t.evictOldestLocked()
		}
		e = &bleEntry{addr: addr, company: -1, appearV: -1, lastRSSI: bleNoSignal, peak: bleNoSignal, first: at}
		t.devs[addr] = e
	}
	if at.After(e.last) {
		e.last = at
	}
	return e
}

// evictOldestLocked drops the untracked entry with the oldest last-seen.
func (t *BLETracker) evictOldestLocked() {
	var victim *bleEntry
	for addr, e := range t.devs {
		if addr == t.tracked {
			continue
		}
		if victim == nil || e.last.Before(victim.last) || (e.last.Equal(victim.last) && e.addr < victim.addr) {
			victim = e
		}
	}
	if victim != nil {
		delete(t.devs, victim.addr)
	}
}

// fullClassify is the database-backed classifier; a variable so tests can
// make it slow and prove readers are not blocked.
var fullClassify = func(in bleClassIn) bleClass { return classifyBLE(in, true) }

// Observe records one decoded advert. Identification (which may need the
// embedded OUI database, loaded lazily) runs only when an identifying input
// changed and always outside the tracker lock, so a slow first load can never
// stall readers such as the render loop.
func (t *BLETracker) Observe(a Advert, at time.Time) {
	e, in, gen, changed := t.observe(a, at)
	if !changed {
		return
	}
	cls := fullClassify(in)
	t.mu.Lock()
	if t.devs[a.Addr] == e && e.gen == gen {
		e.cls = cls
	}
	t.mu.Unlock()
}

func (t *BLETracker) observe(a Advert, at time.Time) (e *bleEntry, in bleClassIn, gen int, changed bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	e = t.entry(a.Addr, at)
	changed = !e.cls.valid
	set := func(dst *string, v string) {
		if v != "" && *dst != v {
			*dst, changed = v, true
		}
	}
	if e.random != a.Random {
		e.random, changed = a.Random, true
	}
	set(&e.name, a.Name)
	if a.Company >= 0 && e.company != a.Company {
		e.company, changed = a.Company, true
	}
	set(&e.mfrKind, a.MfrKind)
	set(&e.svcKind, a.SvcKind)
	set(&e.hint, a.BrandHint)
	set(&e.model, a.Model)
	set(&e.beacon, a.BeaconInfo)
	if a.Appearance >= 0 && e.appearV != a.Appearance {
		e.appearV, changed = a.Appearance, true
	}
	for _, u := range a.ServiceUUIDs {
		if len(e.services) >= advMaxServices {
			break
		}
		seen := false
		for _, v := range e.services {
			seen = seen || v == u
		}
		if !seen {
			e.services, changed = append(e.services, u), true
		}
	}
	if a.HasTx {
		e.tx, e.hasTx = a.TxPower, true
	}
	e.lastRSSI = a.RSSI
	if at.After(e.lastAdv) {
		e.lastAdv = at
	}
	if a.RSSI > e.peak {
		e.peak = a.RSSI
	}
	e.recent = append(pruneSamples(e.recent, at.Add(-bleRateWin)), bleSample{at, a.RSSI})
	t.all = append(pruneTimes(t.all, at.Add(-bleRateWin)), at)
	if a.Addr == t.tracked {
		t.hist = append(pruneSamples(t.hist, at.Add(-lockHistoryLen*time.Second)), bleSample{at, a.RSSI})
		if a.RSSI > t.tPeak {
			t.tPeak, t.tPeakAt = a.RSSI, at
		}
	}
	if changed {
		e.gen++
		in = e.classIn()
		// Provisional, database-free answer until the full one is stored.
		e.cls = classifyBLE(in, false)
	}
	return e, in, e.gen, changed
}

// ObserveAddr records presence only (no RSSI) for hcitool-only fallback.
func (t *BLETracker) ObserveAddr(addr string, at time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.entry(addr, at)
}

// pruneSamples/pruneTimes reslice instead of copying; the following append
// reallocates only when the backing array is exhausted (amortized O(1)).
func pruneSamples(s []bleSample, cutoff time.Time) []bleSample {
	i := 0
	for i < len(s) && s[i].at.Before(cutoff) {
		i++
	}
	return s[i:]
}

func pruneTimes(s []time.Time, cutoff time.Time) []time.Time {
	i := 0
	for i < len(s) && s[i].Before(cutoff) {
		i++
	}
	return s[i:]
}

func (t *BLETracker) expireLocked(now time.Time) {
	for addr, e := range t.devs {
		if addr != t.tracked && now.Sub(e.last) > t.expire {
			delete(t.devs, addr)
		}
	}
}

func (t *BLETracker) Count(now time.Time) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.expireLocked(now)
	return len(t.devs)
}

func (t *BLETracker) Devices(now time.Time) []BLEDevice {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.expireLocked(now)
	out := make([]BLEDevice, 0, len(t.devs))
	for _, e := range t.devs {
		out = append(out, e.device(now))
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].RSSI != out[j].RSSI {
			return out[i].RSSI > out[j].RSSI
		}
		return out[i].Addr < out[j].Addr
	})
	return out
}

func (e *bleEntry) device(now time.Time) BLEDevice {
	sum, n, cnt := 0, 0, 0
	for _, s := range e.recent {
		if now.Sub(s.at) <= bleSmooth {
			sum += s.rssi
			n++
		}
		if now.Sub(s.at) <= bleRateWin {
			cnt++
		}
	}
	rssi := bleNoSignal
	switch {
	case n > 0:
		rssi = int(math.Round(float64(sum) / float64(n)))
	case !e.lastAdv.IsZero() && now.Sub(e.lastAdv) < bleLost:
		rssi = e.lastRSSI
	}
	span := now.Sub(e.first).Seconds()
	if span > bleRateWin.Seconds() {
		span = bleRateWin.Seconds()
	}
	if span < 1 {
		span = 1
	}
	c := e.cls
	if !c.valid {
		c = bleClass{brand: "UNKNOWN", typ: "OTHER"}
	}
	d := BLEDevice{
		Addr: e.addr, Random: e.random, Kind: c.typ, Brand: c.brand, Type: c.typ,
		Name: e.name, RSSI: rssi, Peak: e.peak, AdvPerSec: float64(cnt) / span,
		TxPower: e.tx, HasTx: e.hasTx, LastSeen: e.last,
		Appearance: c.appear, FirstSeen: e.first,
		Model: e.model, AddrKind: c.addrKind, MakerFull: c.makerFull,
		BeaconInfo: e.beacon, Services: c.services,
	}
	if c.brand != "UNKNOWN" {
		d.Maker = c.brand
	}
	d.Label = bleLabel(d)
	return d
}

// nameWord returns the first word of name trimmed to letters/digits at both
// ends, or UNKNOWN when the name has no letter.
func nameWord(name string) string {
	hasLetter := false
	for i := 0; i < len(name); i++ {
		if c := name[i]; c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' {
			hasLetter = true
			break
		}
	}
	if !hasLetter {
		return "UNKNOWN"
	}
	w := name
	if i := strings.IndexByte(w, ' '); i >= 0 {
		w = w[:i]
	}
	alnum := func(c byte) bool {
		return c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z'
	}
	for len(w) > 0 && !alnum(w[0]) {
		w = w[1:]
	}
	for len(w) > 0 && !alnum(w[len(w)-1]) {
		w = w[:len(w)-1]
	}
	if w == "" {
		return "UNKNOWN"
	}
	return w
}

func bleLabel(d BLEDevice) string {
	if d.Name != "" {
		return d.Name
	}
	if d.Model != "" {
		return d.Model
	}
	brand, typ := d.Brand, d.Type
	if brand == "" {
		brand = "UNKNOWN"
	}
	if typ == "" {
		typ = "OTHER"
	}
	if brand == "UNKNOWN" {
		a := d.Addr
		if len(a) > 8 {
			a = a[:8]
		}
		if typ == "OTHER" {
			return "UNKNOWN " + a
		}
		return typ + " " + a
	}
	if typ == "OTHER" {
		return brand + " DEVICE"
	}
	return brand + " " + typ
}

// AdvPerSec is the all-device advert rate over the last 10 s.
func (t *BLETracker) AdvPerSec(now time.Time) float64 {
	t.mu.Lock()
	defer t.mu.Unlock()
	n := 0
	for _, at := range t.all {
		if now.Sub(at) <= bleRateWin {
			n++
		}
	}
	return float64(n) / bleRateWin.Seconds()
}

// Track starts (or replaces) tracking of addr and resets history and peak.
func (t *BLETracker) Track(addr string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.tracked, t.hist, t.tPeak, t.tPeakAt = addr, nil, bleNoSignal, time.Time{}
}

func (t *BLETracker) Untrack() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.tracked, t.hist, t.tPeak, t.tPeakAt = "", nil, bleNoSignal, time.Time{}
}

// Tracked returns the tracked device view, or nil when not tracking.
func (t *BLETracker) Tracked(now time.Time) *BLETrackView {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.tracked == "" {
		return nil
	}
	t.expireLocked(now)
	e := t.devs[t.tracked]
	if e == nil {
		e = &bleEntry{addr: t.tracked, company: -1, appearV: -1, lastRSSI: bleNoSignal, peak: bleNoSignal}
	}
	v := &BLETrackView{BLEDevice: e.device(now), PeakAt: t.tPeakAt}
	v.Peak = t.tPeak
	v.Lost = e.lastAdv.IsZero() || now.Sub(e.lastAdv) >= bleLost
	v.History = t.history(now)
	v.Trend = bleTrend(v.History)
	return v
}

// history buckets tracked adverts into lockHistoryLen one-second means.
func (t *BLETracker) history(now time.Time) []int {
	sum := make([]int, lockHistoryLen)
	cnt := make([]int, lockHistoryLen)
	for _, s := range t.hist {
		age := int(now.Sub(s.at) / time.Second)
		if age < 0 {
			age = 0
		}
		if age >= lockHistoryLen {
			continue
		}
		sum[age] += s.rssi
		cnt[age]++
	}
	h := make([]int, lockHistoryLen)
	for age := 0; age < lockHistoryLen; age++ {
		v := bleNoSignal
		if cnt[age] > 0 {
			v = int(math.Round(float64(sum[age]) / float64(cnt[age])))
		}
		h[lockHistoryLen-1-age] = v
	}
	return h
}

// bleTrend compares the last 5 seconds with the 5 before; missing seconds are ignored.
func bleTrend(h []int) string {
	mean := func(s []int) (float64, bool) {
		sum, n := 0, 0
		for _, v := range s {
			if v != bleNoSignal {
				sum += v
				n++
			}
		}
		if n == 0 {
			return 0, false
		}
		return float64(sum) / float64(n), true
	}
	if len(h) < 10 {
		return TrendSteady
	}
	cur, ok1 := mean(h[len(h)-5:])
	prev, ok2 := mean(h[len(h)-10 : len(h)-5])
	if !ok1 || !ok2 {
		return TrendSteady
	}
	switch d := cur - prev; {
	case d >= bleTrendStep:
		return TrendRising
	case d <= -bleTrendStep:
		return TrendFalling
	}
	return TrendSteady
}

// HitsWiFi lists 2.4 GHz Wi-Fi channels overlapped by BLE advertising channels 37/38/39.
func HitsWiFi() []int {
	var out []int
	for ch := 1; ch <= 14; ch++ {
		c := 2407 + 5*ch
		if ch == 14 {
			c = 2484
		}
		for _, f := range []int{2402, 2426, 2480} {
			if d := c - f; d >= -10 && d <= 10 {
				out = append(out, ch)
				break
			}
		}
	}
	return out
}

// FormatChannelRuns renders e.g. [1 2 3 4 5 13 14] as "1-5, 13-14".
func FormatChannelRuns(chs []int) string {
	s := ""
	for i := 0; i < len(chs); {
		j := i
		for j+1 < len(chs) && chs[j+1] == chs[j]+1 {
			j++
		}
		if s != "" {
			s += ", "
		}
		if j == i {
			s += strconv.Itoa(chs[i])
		} else {
			s += strconv.Itoa(chs[i]) + "-" + strconv.Itoa(chs[j])
		}
		i = j + 1
	}
	return s
}
