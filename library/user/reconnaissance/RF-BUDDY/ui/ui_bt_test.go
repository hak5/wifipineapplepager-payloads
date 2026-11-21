package main

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

// brandSnap builds a snapshot from "ADDR:BRAND:TYPE:RSSI" specs, strongest first.
func brandSnap(specs ...string) Snapshot {
	s := uiSnapshot()
	s.HasBT = true
	for _, sp := range specs {
		p := strings.Split(sp, ":")
		var rssi int
		fmt.Sscan(p[3], &rssi)
		s.BT = append(s.BT, BLEDevice{Addr: p[0], Label: "DEV " + p[0], Brand: p[1], Type: p[2], RSSI: rssi, Peak: rssi, LastSeen: time.Unix(0, 0)})
	}
	return s
}

func btUI(t *testing.T) (*ui, *recordingController) {
	u, ctrl, _, _ := overviewUI(t)
	u.setBTLevel(btLevelBrands)
	return u, ctrl
}

func press(u *ui, s Snapshot, buttons ...string) {
	for _, b := range buttons {
		u.HandleButton(b, s)
	}
}

var fixture = []string{
	"a1:APPLE:FIND MY:-50", "a2:APPLE:NEARBY:-55", "a3:APPLE:FIND MY:-60",
	"g1:GOOGLE:FAST PAIR:-65", "u1:UNKNOWN:OTHER:-70",
}

func TestBTDrillDownAndBackChain(t *testing.T) {
	u, ctrl := btUI(t)
	s := brandSnap(fixture...)
	if !u.LiveBT() {
		t.Fatal("LiveBT must be true on brands")
	}
	press(u, s, "A") // APPLE has the most devices
	if u.btLevel != btLevelTypes || u.btBrand != "APPLE" || !u.LiveBT() {
		t.Fatalf("A on brands: level=%d brand=%q", u.btLevel, u.btBrand)
	}
	press(u, s, "A") // FIND MY (2) first
	if u.btLevel != btLevelDevices || u.btType != "FIND MY" {
		t.Fatalf("A on types: level=%d type=%q", u.btLevel, u.btType)
	}
	press(u, s, "A")
	if u.btLevel != btLevelTrack || u.screen != screenBTTrack || len(ctrl.tracked) != 1 || ctrl.tracked[0] != "a1" || !u.LiveBT() {
		t.Fatalf("A on devices: level=%d screen=%d tracked=%v", u.btLevel, u.screen, ctrl.tracked)
	}
	if exit := u.HandleButton("B", s); exit || ctrl.untracks != 1 || u.btLevel != btLevelDevices || u.screen != screenBT {
		t.Fatalf("B on track: exit=%v untracks=%d level=%d", exit, ctrl.untracks, u.btLevel)
	}
	press(u, s, "B")
	if u.btLevel != btLevelTypes {
		t.Fatalf("B on devices: level=%d", u.btLevel)
	}
	press(u, s, "B")
	if u.btLevel != btLevelBrands || u.btBrand != "APPLE" {
		t.Fatalf("B on types: level=%d brand=%q (selection must be restored)", u.btLevel, u.btBrand)
	}
	if exit := u.HandleButton("B", s); !exit {
		t.Fatal("B on brands must exit")
	}
}

func TestBTBrandsButtons(t *testing.T) {
	u, ctrl := btUI(t)
	s := brandSnap(fixture...)
	press(u, s, "RIGHT")
	if u.btBrand != "GOOGLE" {
		t.Fatalf("RIGHT: %q", u.btBrand)
	}
	press(u, s, "RIGHT", "RIGHT", "RIGHT") // UNKNOWN last, clamps
	if u.btBrand != "UNKNOWN" {
		t.Fatalf("clamp: %q", u.btBrand)
	}
	press(u, s, "LEFT")
	if u.btBrand != "GOOGLE" {
		t.Fatalf("LEFT: %q", u.btBrand)
	}
	// UP/DOWN switch tabs as before
	press(u, s, "UP")
	if u.screen != screenOverview || u.band != Band24 || len(ctrl.bands) != 1 {
		t.Fatalf("UP: screen=%d band=%d", u.screen, u.band)
	}
	u.setBTLevel(btLevelBrands)
	press(u, s, "DOWN")
	if u.screen != screenOverview || u.band != Band5 {
		t.Fatalf("DOWN: screen=%d band=%d", u.screen, u.band)
	}
}

func TestBTTypesAndDevicesArrows(t *testing.T) {
	u, _ := btUI(t)
	s := brandSnap(fixture...)
	press(u, s, "A") // APPLE
	press(u, s, "DOWN")
	if u.btType != "NEARBY" {
		t.Fatalf("DOWN: %q", u.btType)
	}
	press(u, s, "UP")
	if u.btType != "FIND MY" {
		t.Fatalf("UP: %q", u.btType)
	}
	press(u, s, "RIGHT")
	if u.btType != "NEARBY" {
		t.Fatalf("RIGHT: %q", u.btType)
	}
	press(u, s, "LEFT", "A") // FIND MY devices: a1, a3
	press(u, s, "DOWN")
	if u.btAddr != "a3" {
		t.Fatalf("DOWN: %q", u.btAddr)
	}
	press(u, s, "RIGHT") // clamps
	if u.btAddr != "a3" {
		t.Fatalf("RIGHT clamp: %q", u.btAddr)
	}
	press(u, s, "UP")
	if u.btAddr != "a1" {
		t.Fatalf("UP: %q", u.btAddr)
	}
	press(u, s, "LEFT") // clamps
	if u.btAddr != "a1" {
		t.Fatalf("LEFT clamp: %q", u.btAddr)
	}
}

func TestBTSelectionSurvivesResort(t *testing.T) {
	u, _ := btUI(t)
	s := brandSnap(fixture...)
	press(u, s, "RIGHT") // GOOGLE
	// GOOGLE grows to the top of the brand order; selection follows the name
	re := brandSnap("g1:GOOGLE:FAST PAIR:-40", "g2:GOOGLE:FAST PAIR:-41", "g3:GOOGLE:FAST PAIR:-42", "a1:APPLE:FIND MY:-50")
	press(u, re, "RIGHT")
	if u.btBrand != "APPLE" {
		t.Fatalf("after re-sort RIGHT: %q", u.btBrand)
	}
	press(u, re, "LEFT")
	if u.btBrand != "GOOGLE" {
		t.Fatalf("after re-sort LEFT: %q", u.btBrand)
	}
	// type level
	u, _ = btUI(t)
	t1 := brandSnap("a1:APPLE:FIND MY:-50", "a2:APPLE:NEARBY:-55", "a3:APPLE:NEARBY:-56")
	press(u, t1, "A", "DOWN") // NEARBY is first (2), FIND MY second; DOWN -> FIND MY
	if u.btType != "FIND MY" {
		t.Fatalf("type = %q", u.btType)
	}
	t2 := brandSnap("a1:APPLE:FIND MY:-50", "a2:APPLE:FIND MY:-51", "a3:APPLE:FIND MY:-52", "a4:APPLE:NEARBY:-55")
	press(u, t2, "DOWN")
	if u.btType != "NEARBY" {
		t.Fatalf("type after re-sort DOWN = %q", u.btType)
	}
	// device level
	u, _ = btUI(t)
	d1 := brandSnap("x:A:T:-50", "y:A:T:-55", "z:A:T:-60")
	press(u, d1, "A", "A", "DOWN", "DOWN")
	if u.btAddr != "z" {
		t.Fatalf("addr = %q", u.btAddr)
	}
	d2 := brandSnap("z:A:T:-45", "x:A:T:-50", "y:A:T:-55")
	press(u, d2, "DOWN")
	if u.btAddr != "x" {
		t.Fatalf("after re-sort DOWN: %q", u.btAddr)
	}
}

func TestBTFallbackWhenSelectionGone(t *testing.T) {
	u, ctrl := btUI(t)
	s := brandSnap(fixture...)
	press(u, s, "RIGHT") // GOOGLE
	gone := brandSnap("a1:APPLE:FIND MY:-50", "u1:UNKNOWN:OTHER:-70")
	press(u, gone, "A") // GOOGLE is gone -> index 0 = APPLE
	if u.btLevel != btLevelTypes || u.btBrand != "APPLE" {
		t.Fatalf("brand fallback: level=%d brand=%q", u.btLevel, u.btBrand)
	}
	u.btType = "NEARBY" // vanished type
	press(u, gone, "A")
	if u.btLevel != btLevelDevices || u.btType != "FIND MY" {
		t.Fatalf("type fallback: level=%d type=%q", u.btLevel, u.btType)
	}
	u.btAddr = "nope"
	press(u, gone, "A")
	if len(ctrl.tracked) != 1 || ctrl.tracked[0] != "a1" {
		t.Fatalf("addr fallback tracked=%v", ctrl.tracked)
	}
}

func TestBTEmptyLevelsAllowBackAndRender(t *testing.T) {
	now := time.Date(2026, 10, 1, 12, 42, 0, 0, time.Local)
	u, ctrl := btUI(t)
	s := brandSnap(fixture...)
	press(u, s, "A", "A") // APPLE / FIND MY devices
	empty := brandSnap()
	press(u, empty, "A", "LEFT", "RIGHT", "UP", "DOWN")
	if u.btLevel != btLevelDevices || len(ctrl.tracked) != 0 {
		t.Fatalf("empty devices: level=%d tracked=%v", u.btLevel, ctrl.tracked)
	}
	u.Render(empty, now)
	press(u, empty, "B")
	press(u, empty, "A", "DOWN")
	if u.btLevel != btLevelTypes {
		t.Fatalf("empty types: level=%d", u.btLevel)
	}
	u.Render(empty, now)
	press(u, empty, "B")
	press(u, empty, "A", "LEFT", "RIGHT")
	if u.btLevel != btLevelBrands {
		t.Fatalf("empty brands: level=%d", u.btLevel)
	}
	u.Render(empty, now)
	if !u.HandleButton("B", empty) {
		t.Fatal("B must exit from empty brands")
	}
}

func TestBTTrackNavigatesWithinBrandAndType(t *testing.T) {
	u, ctrl := btUI(t)
	s := brandSnap("a1:APPLE:FIND MY:-50", "a2:APPLE:NEARBY:-52", "a3:APPLE:FIND MY:-60", "g1:GOOGLE:FAST PAIR:-65")
	press(u, s, "A", "A", "A") // APPLE, FIND MY, track a1
	press(u, s, "RIGHT")       // a3, skipping a2 (other type)
	press(u, s, "RIGHT")       // clamps
	press(u, s, "LEFT")
	if got := strings.Join(ctrl.tracked, ","); got != "a1,a3,a1" {
		t.Fatalf("tracked = %s", got)
	}
	if u.btLevel != btLevelTrack {
		t.Fatalf("level = %d", u.btLevel)
	}
	press(u, s, "UP")
	if u.audio {
		t.Fatal("UP must toggle audio on track")
	}
}

func TestBTTrackMark(t *testing.T) {
	u, ctrl, marks, clock := overviewUI(t)
	s := brandSnap("a1:APPLE:FIND MY:-50")
	u.setBTLevel(btLevelBrands)
	press(u, s, "A", "A", "A")
	s.BTTrack = &BLETrackView{BLEDevice: BLEDevice{Addr: "a1", Label: "DEV A", RSSI: -61}}
	u.HandleButton("A", s)
	if len(marks.marks) != 1 || !marks.marks[0].BT || marks.marks[0].BTAddr != "a1" || marks.marks[0].RSSI != -61 || marks.marks[0].BTLabel != "DEV A" {
		t.Fatalf("marks = %+v", marks.marks)
	}
	want := "MARK 3 @ " + clock.Now().Format("15:04") + " - -61 DBM"
	if u.toast != want {
		t.Fatalf("toast = %q, want %q", u.toast, want)
	}
	if len(ctrl.tracked) != 1 {
		t.Fatalf("tracked = %v", ctrl.tracked)
	}
}

func TestBTWiFiTabsUnchanged(t *testing.T) {
	u, ctrl, _, _ := overviewUI(t)
	s := brandSnap(fixture...)
	press(u, s, "A") // Wi-Fi overview A locks, not a BT action
	if len(ctrl.tracked) != 0 || u.screen == screenBT {
		t.Fatalf("Wi-Fi A leaked into BT: screen=%d", u.screen)
	}
}

func TestBTHelpers(t *testing.T) {
	if got := fmtDBM(-100); got != "--" {
		t.Fatalf("fmtDBM(-100) = %q", got)
	}
	if got := fmtDBM(-55); got != "-55 DBM" {
		t.Fatalf("fmtDBM(-55) = %q", got)
	}
	u := &ui{btBrand: "NANOLEAF-INDUSTRIES-LIMITED", btType: "EDDYSTONE-UID", btLevel: btLevelDevices}
	if c := u.btBreadcrumb(); len(c) > btCrumbCells || !strings.HasSuffix(c, "EDDYSTONE-UID") {
		t.Fatalf("breadcrumb %q", c)
	}
	if got := wrapParts("FIND MY 8, NEARBY 5, AIRPLAY 3, +3", 26, 2); len(got) != 2 || got[0] != "FIND MY 8, NEARBY 5" {
		t.Fatalf("wrapParts = %q", got)
	}
}

func TestBTRenderSmoke(t *testing.T) {
	now := time.Date(2026, 10, 1, 12, 42, 0, 0, time.Local)
	for _, c := range previewCases(now) {
		if img := c.ui().Render(c.snap, now); img == nil || img.Bounds().Dx() != screenWidth {
			t.Fatalf("%s did not render", c.name)
		}
	}
	full := previewBTSnapshot(now)
	for level := btLevelBrands; level <= btLevelTrack; level++ {
		for _, snap := range []Snapshot{full, {HasBT: true}, {}} {
			u := newUI(nil, nil, func() time.Time { return now })
			u.btBrand, u.btType, u.btAddr = "APPLE", "FIND MY", "88:99:AA:BB:CC:DD"
			u.setBTLevel(level)
			if img := u.Render(snap, now); img == nil {
				t.Fatalf("level %d did not render", level)
			}
		}
	}
}

// Device rows sit under a BRAND > TYPE breadcrumb, so they show what tells
// devices apart: the name when advertised, otherwise the address.
func TestBTRowText(t *testing.T) {
	named := BLEDevice{Addr: "74:4D:BD:CD:0F:C5", Name: "NANOLEAF STRIP FCE", Label: "NANOLEAF STRIP FCE"}
	if got := btRowText(named); got != "NANOLEAF STRIP FCE" {
		t.Fatalf("named row = %q", got)
	}
	anon := BLEDevice{Addr: "FA:21:5F:AD:1C:E7", Random: true, Label: "APPLE FIND MY"}
	if got := btRowText(anon); got != "21:5F:AD:1C:E7 R" {
		t.Fatalf("anonymous row = %q", got)
	}
}

func TestBTPanelTexts(t *testing.T) {
	now := time.Date(2026, 10, 1, 12, 42, 0, 0, time.Local)
	for _, tc := range []struct {
		d                BLEDevice
		maker, kind, sig string
	}{
		{BLEDevice{Brand: "APPLE", Type: "AIRPODS", Model: "AIRPODS PRO 2", RSSI: -64, Peak: -61}, "APPLE", "AIRPODS PRO 2", "-64 (PK -61)"},
		{BLEDevice{Brand: "ID B5B5", MakerFull: " B5 LABS ", Type: "OTHER", RSSI: -100, Peak: -100}, "B5 LABS", "--", "-- (PK --)"},
		{BLEDevice{Brand: "ID B5B5", Type: "TV", RSSI: -70, Peak: -100}, "ID B5B5", "TV", "-70 (PK --)"},
		{BLEDevice{Brand: "UNKNOWN", Type: "OTHER", RSSI: -50, Peak: -50}, "--", "--", "-50 (PK -50)"},
	} {
		if g := btMakerText(tc.d); g != tc.maker {
			t.Errorf("maker %q want %q", g, tc.maker)
		}
		if g := btKindText(tc.d); g != tc.kind {
			t.Errorf("kind %q want %q", g, tc.kind)
		}
		if g := btSignalText(tc.d); g != tc.sig {
			t.Errorf("signal %q want %q", g, tc.sig)
		}
	}
	d := BLEDevice{LastSeen: now, FirstSeen: time.Date(2026, 10, 1, 4, 8, 25, 0, time.Local)}
	if g := btSeenText(d, now); g != "0S / 04:08:25" {
		t.Errorf("seen %q", g)
	}
	if g := btSeenText(BLEDevice{}, now); g != "-- / --" {
		t.Errorf("seen %q", g)
	}
	if got := topServices([]BLEDevice{{RSSI: -40}, {RSSI: -70, Services: []string{"HEART RATE"}}, {RSSI: -80, Services: []string{"HID"}}}); got != "HEART RATE" {
		t.Errorf("topServices %q", got)
	}
}
