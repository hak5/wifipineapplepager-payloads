package main

import "testing"

func TestAppleModelTable(t *testing.T) {
	want := map[uint16]struct {
		name  string
		beats bool
	}{
		0x0220: {"AIRPODS", false}, 0x0F20: {"AIRPODS 2", false}, 0x1320: {"AIRPODS 3", false},
		0x0E20: {"AIRPODS PRO", false}, 0x1420: {"AIRPODS PRO 2", false}, 0x2420: {"AIRPODS PRO 2", false},
		0x0A20: {"AIRPODS MAX", false}, 0x0320: {"POWERBEATS 3", true}, 0x0B20: {"POWERBEATS PRO", true},
		0x0C20: {"BEATS SOLO PRO", true}, 0x1120: {"BEATS STUDIO BUDS", true}, 0x1620: {"STUDIO BUDS+", true},
		0x1020: {"BEATS FLEX", true}, 0x0520: {"BEATSX", true}, 0x0620: {"BEATS SOLO 3", true},
		0x0920: {"BEATS STUDIO 3", true}, 0x1220: {"BEATS FIT PRO", true},
	}
	if len(appleModels) != len(want) {
		t.Fatalf("%d models, want %d", len(appleModels), len(want))
	}
	for id, w := range want {
		pairing := append([]byte{0x07, 0x19, 0x01, byte(id >> 8), byte(id)}, make([]byte, 22)...)
		a := parseOne(t, mfr(0x4C, pairing...))
		kind := "AIRPODS"
		if w.beats {
			kind = "BEATS"
		}
		if a.Model != w.name || a.MfrKind != kind {
			t.Errorf("%#04x: model %q kind %q, want %q/%q", id, a.Model, a.MfrKind, w.name, kind)
		}
	}
}

func TestMicrosoftDeviceTypes(t *testing.T) {
	want := map[byte]string{1: "XBOX ONE", 6: "IPHONE", 7: "IPAD", 8: "ANDROID", 9: "WINDOWS DESKTOP",
		11: "WINDOWS PHONE", 12: "LINUX", 13: "WINDOWS IOT", 14: "SURFACE HUB", 15: "WINDOWS LAPTOP", 16: "WINDOWS TABLET"}
	for ty, name := range want {
		// the upper three bits of the byte are a version and must be ignored
		a := parseOne(t, mfr(0x06, 0x01, ty|0xA0, 0x80))
		if a.Model != name || a.Kind != "WINDOWS" {
			t.Errorf("%d: %+v", ty, a)
		}
	}
	for _, ty := range []byte{0, 2, 10, 17, 31} {
		if a := parseOne(t, mfr(0x06, 0x01, ty)); a.Model != "" || a.Kind != "WINDOWS" {
			t.Errorf("%d: %+v", ty, a)
		}
	}
	if msModel([]byte{0x03, 0x0F}) != "" || msModel(nil) != "" {
		t.Error("non-CDP must have no model")
	}
}

func TestIBeaconInfo(t *testing.T) {
	d := []byte{0x02, 0x15, 0xE2, 0xC5, 0x6D, 0xB5, 0xDF, 0xFB, 0x48, 0xD2, 0xB0, 0x60, 0xD0, 0xF5, 0xA7, 0x10, 0x96, 0xE0,
		0x00, 0x01, 0x00, 0x02, 0xC5}
	if a := parseOne(t, mfr(0x4C, d...)); a.BeaconInfo != "IBEACON 1/2" || a.Kind != "IBEACON" {
		t.Errorf("%+v", a)
	}
	d[18], d[19], d[20], d[21] = 0xFF, 0xFF, 0x00, 0x00
	if a := parseOne(t, mfr(0x4C, d...)); a.BeaconInfo != "IBEACON 65535/0" {
		t.Errorf("%+v", a)
	}
}
