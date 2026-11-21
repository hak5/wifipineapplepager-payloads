package main

import (
	"reflect"
	"strconv"
	"testing"
	"time"
)

var t0 = time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)

func adv(addr string, rssi int) Advert { return Advert{Addr: addr, RSSI: rssi, Company: -1} }

func TestHitsWiFi(t *testing.T) {
	got := HitsWiFi()
	if want := []int{1, 2, 3, 4, 5, 13, 14}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
	for in, want := range map[string]string{FormatChannelRuns(got): "1-5, 13-14", FormatChannelRuns(nil): "",
		FormatChannelRuns([]int{3}): "3", FormatChannelRuns([]int{1, 3, 4}): "1, 3-4"} {
		if in != want {
			t.Errorf("got %q want %q", in, want)
		}
	}
}

func TestBLELabel(t *testing.T) {
	tests := []struct {
		d    BLEDevice
		want string
	}{
		{BLEDevice{Name: "TAG", Brand: "APPLE", Type: "X"}, "TAG"},
		{BLEDevice{Brand: "APPLE", Type: "AIRPODS"}, "APPLE AIRPODS"},
		{BLEDevice{Brand: "UNKNOWN", Type: "FAST PAIR", Addr: "4B:63:B5:11:22:33"}, "FAST PAIR 4B:63:B5"},
		{BLEDevice{Brand: "UNKNOWN", Type: "EDDYSTONE", Addr: "4B:63:B5:11:22:33"}, "EDDYSTONE 4B:63:B5"},
		{BLEDevice{Brand: "UNKNOWN", Type: "OTHER", Addr: "4B:63:B5:11:22:33"}, "UNKNOWN 4B:63:B5"},
		{BLEDevice{Brand: "GOOGLE", Type: "FAST PAIR"}, "GOOGLE FAST PAIR"},
		{BLEDevice{Brand: "BOSE", Type: "OTHER"}, "BOSE DEVICE"},
		{BLEDevice{Addr: "4B:63:B5:11:22:33"}, "UNKNOWN 4B:63:B5"},
	}
	for _, tc := range tests {
		if got := bleLabel(tc.d); got != tc.want {
			t.Errorf("got %q want %q", got, tc.want)
		}
	}
}

func TestTrackerDevices(t *testing.T) {
	tr := NewBLETracker(30 * time.Second)
	a := Advert{Addr: "AA", Random: true, RSSI: -80, Company: 0x4C, MfrKind: "AIRPODS", Name: "BUDS", HasTx: true, TxPower: 4}
	tr.Observe(a, t0)
	a.Name, a.RSSI = "", -60 // sticky name
	tr.Observe(a, t0.Add(time.Second))
	tr.Observe(adv("BB", -60), t0.Add(time.Second))
	tr.Observe(adv("A0", -60), t0.Add(time.Second))
	tr.ObserveAddr("CC", t0.Add(time.Second))

	now := t0.Add(1500 * time.Millisecond)
	ds := tr.Devices(now)
	var order []string
	for _, d := range ds {
		order = append(order, d.Addr)
	}
	// AA smoothed mean(-80,-60) = -70; A0/BB -60; CC -100
	if want := []string{"A0", "BB", "AA", "CC"}; !reflect.DeepEqual(order, want) {
		t.Fatalf("order %v", order)
	}
	aa := ds[2]
	if aa.RSSI != -70 || aa.Peak != -60 || aa.Name != "BUDS" || aa.Label != "BUDS" || aa.Maker != "APPLE" ||
		!aa.Random || !aa.HasTx || aa.TxPower != 4 || aa.AdvPerSec != 2/1.5 {
		t.Errorf("AA %+v", aa)
	}
	if ds[3].RSSI != -100 {
		t.Errorf("addr-only %+v", ds[3])
	}

	// outside the 2 s window the smoothed value falls back to the last advert
	// while that advert is under 5 s old, and to -100 after that
	for _, d := range tr.Devices(t0.Add(4 * time.Second)) {
		if d.Addr == "AA" && d.RSSI != -60 {
			t.Errorf("fallback %+v", d)
		}
	}
	later := t0.Add(20 * time.Second)
	for _, d := range tr.Devices(later) {
		if d.Addr == "AA" && d.RSSI != -100 {
			t.Errorf("stale fallback %+v", d)
		}
	}
	if got := tr.Count(later); got != 4 {
		t.Errorf("count %d", got)
	}
	if got := tr.Count(t0.Add(32 * time.Second)); got != 0 {
		t.Errorf("count after expiry %d", got)
	}
}

func TestTrackerAdvPerSec(t *testing.T) {
	tr := NewBLETracker(time.Minute)
	for i := 0; i < 50; i++ {
		tr.Observe(adv("AA", -70), t0.Add(time.Duration(i)*100*time.Millisecond))
	}
	if got := tr.AdvPerSec(t0.Add(5 * time.Second)); got != 5 {
		t.Errorf("got %v", got)
	}
	if got := tr.AdvPerSec(t0.Add(30 * time.Second)); got != 0 {
		t.Errorf("stale %v", got)
	}
}

func TestTrackHistoryLostTrend(t *testing.T) {
	tr := NewBLETracker(10 * time.Second)
	if tr.Tracked(t0) != nil {
		t.Fatal("nil when not tracking")
	}
	tr.Observe(adv("AA", -90), t0.Add(-time.Hour)) // pre-track data not in history
	tr.Track("AA")
	// seconds 0-4: -80 ; 5-9: -70 (rising); gap at second 10; sample at 11
	for s := 0; s < 10; s++ {
		r := -80
		if s >= 5 {
			r = -70
		}
		tr.Observe(adv("AA", r), t0.Add(time.Duration(s)*time.Second))
		tr.Observe(adv("AA", r-2), t0.Add(time.Duration(s)*time.Second+500*time.Millisecond))
	}
	now := t0.Add(9*time.Second + 900*time.Millisecond)
	v := tr.Tracked(now)
	if len(v.History) != lockHistoryLen {
		t.Fatalf("len %d", len(v.History))
	}
	if v.History[lockHistoryLen-1] != -71 || v.History[lockHistoryLen-10] != -81 || v.History[0] != -100 {
		t.Errorf("history %v", v.History)
	}
	if v.Trend != TrendRising || v.Lost || v.Peak != -70 || !v.PeakAt.Equal(t0.Add(5*time.Second)) {
		t.Errorf("view %+v", v)
	}

	// signal lost after 5 s, survives expiry, gaps are -100
	late := t0.Add(9*time.Second + 500*time.Millisecond + 20*time.Second)
	v = tr.Tracked(late)
	if v == nil || !v.Lost || v.Addr != "AA" {
		t.Fatalf("lost view %+v", v)
	}
	if tr.Count(late) != 1 {
		t.Error("tracked device must not expire")
	}
	if v.History[lockHistoryLen-1] != -100 {
		t.Error("gap should be -100")
	}
	tr.Untrack()
	if tr.Tracked(late) != nil || tr.Count(late) != 0 {
		t.Error("untrack")
	}
}

func TestTrackUnseenAndTrends(t *testing.T) {
	tr := NewBLETracker(time.Second)
	tr.Track("ZZ")
	if v := tr.Tracked(t0); v == nil || !v.Lost || v.RSSI != -100 || v.Label != "UNKNOWN ZZ" {
		t.Errorf("unseen %+v", v)
	}
	mk := func(prev, cur int) []int {
		h := make([]int, lockHistoryLen)
		for i := range h {
			h[i] = bleNoSignal
		}
		for i := 0; i < 5; i++ {
			h[lockHistoryLen-10+i], h[lockHistoryLen-5+i] = prev, cur
		}
		return h
	}
	for _, tc := range []struct {
		h    []int
		want string
	}{
		{mk(-80, -77), TrendRising}, {mk(-70, -73), TrendFalling}, {mk(-70, -72), TrendSteady},
		{mk(bleNoSignal, -50), TrendSteady},
	} {
		if got := bleTrend(tc.h); got != tc.want {
			t.Errorf("got %s want %s", got, tc.want)
		}
	}
}

func TestObserveSteadyStateDoesNotAllocateWithWindow(t *testing.T) {
	tr := NewBLETracker(30 * time.Second)
	at := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	a := Advert{Addr: "AA:BB:CC:DD:EE:01", RSSI: -60, Company: -1}
	step := 10 * time.Millisecond // 100 adverts/s -> ~1000 live samples
	for i := 0; i < 3000; i++ {
		at = at.Add(step)
		tr.Observe(a, at)
	}
	allocs := testing.AllocsPerRun(2000, func() {
		at = at.Add(step)
		tr.Observe(a, at)
	})
	if allocs > 0.5 {
		t.Fatalf("Observe allocs/op = %v, want amortized ~0 (no per-advert window copy)", allocs)
	}
}

func TestBrandAndTypeDerivation(t *testing.T) {
	tests := []struct {
		name       string
		a          Advert
		brand, typ string
		label      string
	}{
		{"company", Advert{Addr: "AA:BB:CC:DD:EE:01", Company: 0x4C, MfrKind: "FIND MY", Appearance: -1}, "APPLE", "FIND MY", "APPLE FIND MY"},
		{"unknown id", Advert{Addr: "AA:BB:CC:DD:EE:02", Company: 0xB5B5, Appearance: -1}, "ID B5B5", "OTHER", "ID B5B5 DEVICE"},
		{"hint", Advert{Addr: "AA:BB:CC:DD:EE:03", Company: -1, BrandHint: "TILE", SvcKind: "TRACKER", Appearance: -1}, "TILE", "TRACKER", "TILE TRACKER"},
		{"name word", Advert{Addr: "AA:BB:CC:DD:EE:04", Company: -1, Appearance: -1, Name: "NANOLEAF STRIP FCE"}, "NANOLEAF", "LIGHT", "NANOLEAF STRIP FCE"},
		{"name punct", Advert{Addr: "AA:BB:CC:DD:EE:05", Company: -1, Appearance: -1, Name: "[ZEBRA-QC] 35"}, "ZEBRA-QC", "OTHER", "[ZEBRA-QC] 35"},
		{"digit name", Advert{Addr: "AA:BB:CC:DD:EE:06", Company: -1, Appearance: -1, Name: "1234 5"}, "UNKNOWN", "OTHER", "1234 5"},
		{"unknown", Advert{Addr: "AA:BB:CC:DD:EE:07", Company: -1, Appearance: -1}, "UNKNOWN", "OTHER", "UNKNOWN AA:BB:CC"},
		{"appearance type", Advert{Addr: "AA:BB:CC:DD:EE:08", Company: 0x75, Appearance: 0x03C1}, "SAMSUNG", "KEYBOARD", "SAMSUNG KEYBOARD"},
	}
	for _, tc := range tests {
		tr := NewBLETracker(time.Minute)
		tr.Observe(tc.a, t0)
		d := tr.Devices(t0)[0]
		if d.Brand != tc.brand || d.Type != tc.typ || d.Label != tc.label {
			t.Errorf("%s: %q/%q/%q", tc.name, d.Brand, d.Type, d.Label)
		}
		if !d.FirstSeen.Equal(t0) {
			t.Errorf("%s: first seen %v", tc.name, d.FirstSeen)
		}
	}
}

func TestStickyAppearanceAndHint(t *testing.T) {
	tr := NewBLETracker(time.Minute)
	tr.Observe(Advert{Addr: "A", Company: -1, Appearance: 0x0941, BrandHint: "GOOGLE"}, t0)
	tr.Observe(Advert{Addr: "A", Company: -1, Appearance: -1}, t0.Add(time.Second))
	d := tr.Devices(t0.Add(time.Second))[0]
	if d.Appearance != "EARBUD" || d.Brand != "GOOGLE" || d.Type != "EARBUD" || !d.FirstSeen.Equal(t0) {
		t.Errorf("%+v", d)
	}
}

func TestTrackerCapsDevicesEvictingOldest(t *testing.T) {
	tr := NewBLETracker(time.Hour)
	addr := func(i int) string { return "A" + strconv.Itoa(i) }
	for i := 0; i < bleMaxDevices; i++ {
		tr.Observe(adv(addr(i), -70), t0.Add(time.Duration(i)*time.Millisecond))
	}
	tr.Track(addr(0)) // oldest, but tracked: must survive
	now := t0.Add(time.Minute)
	tr.Observe(adv("NEW", -60), now)
	if n := tr.Count(now); n != bleMaxDevices {
		t.Fatalf("count = %d, want %d", n, bleMaxDevices)
	}
	have := map[string]bool{}
	for _, d := range tr.Devices(now) {
		have[d.Addr] = true
	}
	if !have[addr(0)] || !have["NEW"] || have[addr(1)] {
		t.Fatalf("tracked kept=%v new=%v oldest-untracked evicted=%v", have[addr(0)], have["NEW"], !have[addr(1)])
	}
}

func TestTrackedGoesLostWhenOnlyAddressSightings(t *testing.T) {
	tr := NewBLETracker(time.Minute)
	tr.Track("AA")
	tr.Observe(adv("AA", -60), t0)
	// hcidump died: hcitool keeps reporting presence without RSSI
	for s := 1; s <= 10; s++ {
		tr.ObserveAddr("AA", t0.Add(time.Duration(s)*time.Second))
	}
	now := t0.Add(10 * time.Second)
	v := tr.Tracked(now)
	if !v.Lost || v.RSSI != bleNoSignal {
		t.Fatalf("stale real advert: Lost=%v RSSI=%d", v.Lost, v.RSSI)
	}
	if !v.LastSeen.Equal(now) {
		t.Fatalf("LastSeen = %v, device lists still use presence", v.LastSeen)
	}
	// still fresh 3 s after the real advert: falls back to the last RSSI
	if v := tr.Tracked(t0.Add(3 * time.Second)); v.Lost || v.RSSI != -60 {
		t.Fatalf("fresh: Lost=%v RSSI=%d", v.Lost, v.RSSI)
	}
	// addr-only device never seen with RSSI is lost
	tr.Track("BB")
	tr.ObserveAddr("BB", now)
	if v := tr.Tracked(now); !v.Lost {
		t.Fatal("never-advertised tracked device must be Lost")
	}
}
