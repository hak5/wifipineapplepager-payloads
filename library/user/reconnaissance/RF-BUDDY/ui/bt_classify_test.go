package main

import (
	"reflect"
	"strings"
	"testing"
	"time"
)

// observeAd decodes one advert from the given AD structures sent from the
// display address addr and runs it through a fresh tracker.
func observeAd(t *testing.T, addr string, random bool, ads ...[]byte) BLEDevice {
	t.Helper()
	var w [6]byte
	for i := 0; i < 6; i++ {
		b, err := hexByte(addr[i*3 : i*3+2])
		if err != nil {
			t.Fatal(err)
		}
		w[i] = b
	}
	var ad []byte
	for _, x := range ads {
		ad = append(ad, x...)
	}
	typ := byte(0)
	if random {
		typ = 1
	}
	got := ParseLEAdvertEvent(legacyEvt(legacy(w, typ, ad, -50)))
	if len(got) != 1 {
		t.Fatalf("decode: %+v", got)
	}
	tr := NewBLETracker(time.Minute)
	tr.Observe(got[0], t0)
	return tr.Devices(t0)[0]
}

func hexByte(s string) (byte, error) {
	b := hx(&testing.T{}, s)
	return b[0], nil
}

func nameAD(s string) []byte { return append([]byte{byte(1 + len(s)), 0x09}, s...) }

func svcAD(uuids ...int) []byte {
	ad := []byte{byte(1 + 2*len(uuids)), 0x03}
	for _, u := range uuids {
		ad = append(ad, byte(u), byte(u>>8))
	}
	return ad
}

func apple(tlv ...byte) []byte { return mfr(0x4C, tlv...) }

func TestClassifyPrecedence(t *testing.T) {
	const priv = "6A:11:22:33:44:55" // random, top bits 01: resolvable private
	pods := []byte{0x07, 0x19, 0x01, 0x14, 0x20, 0x75, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	tests := []struct {
		name          string
		addr          string
		random        bool
		ads           [][]byte
		brand, typ    string
		model, addrK  string
		label         string
		maker, beacon string
	}{
		{name: "company known beats everything", addr: priv, random: true,
			ads:   [][]byte{apple(0x10, 0x05, 1, 2, 3, 4, 5), nameAD("NANOLEAF X")},
			brand: "APPLE", typ: "NEARBY", addrK: "PRIVATE", label: "NANOLEAF X", maker: "APPLE"},
		{name: "byte-swapped company", addr: priv, random: true,
			ads:   [][]byte{mfr(0x4C00, 1, 2, 3)},
			brand: "APPLE", typ: "OTHER", addrK: "PRIVATE", label: "APPLE DEVICE", maker: "APPLE"},
		{name: "unknown id with nothing else (real packet B payload, private addr)", addr: priv, random: true,
			ads:   [][]byte{mfr(0xB5B5, 0x13, 0x52, 0x36)},
			brand: "ID B5B5", typ: "OTHER", addrK: "PRIVATE", label: "ID B5B5 DEVICE"},
		{name: "Tile uuid, no company", addr: priv, random: true,
			ads:   [][]byte{svcAD(0xFEED)},
			brand: "TILE", typ: "TRACKER", addrK: "PRIVATE", label: "TILE TRACKER", maker: "TILE"},
		{name: "member uuid beats name keyword", addr: priv, random: true,
			ads:   [][]byte{svcAD(0xFEED), nameAD("SONOS ONE")},
			brand: "TILE", typ: "SPEAKER", addrK: "PRIVATE", label: "SONOS ONE"},
		{name: "name keyword, no company (Nanoleaf strip)", addr: priv, random: true,
			ads:   [][]byte{nameAD("Nanoleaf Strip FCE")},
			brand: "NANOLEAF", typ: "LIGHT", addrK: "PRIVATE", label: "NANOLEAF STRIP FCE"},
		{name: "public OUI", addr: "F8:FF:C2:12:34:56", random: false,
			ads:   [][]byte{{0x02, 0x01, 0x06}},
			brand: "APPLE", typ: "OTHER", addrK: "PUBLIC", label: "APPLE DEVICE", maker: "APPLE"},
		{name: "static address never uses OUI", addr: "F8:FF:C2:12:34:56", random: true,
			ads:   [][]byte{{0x02, 0x01, 0x06}},
			brand: "UNKNOWN", typ: "OTHER", addrK: "STATIC", label: "UNKNOWN F8:FF:C2"},
		{name: "private address never uses OUI", addr: "68:DB:F5:12:34:56", random: true,
			ads:   [][]byte{{0x02, 0x01, 0x06}},
			brand: "UNKNOWN", typ: "OTHER", addrK: "PRIVATE", label: "UNKNOWN 68:DB:F5"},
		{name: "non-resolvable never uses OUI", addr: "28:DB:F5:12:34:56", random: true,
			ads:   [][]byte{{0x02, 0x01, 0x06}},
			brand: "UNKNOWN", typ: "OTHER", addrK: "NON-RESOLV", label: "UNKNOWN 28:DB:F5"},
		{name: "same OUI on a public address does", addr: "68:DB:F5:12:34:56", random: false,
			ads:   [][]byte{{0x02, 0x01, 0x06}},
			brand: "AMAZON", typ: "OTHER", addrK: "PUBLIC", label: "AMAZON DEVICE"},
		{name: "company beats OUI", addr: "F8:FF:C2:12:34:56", random: false,
			ads:   [][]byte{mfr(0x75, 1)},
			brand: "SAMSUNG", typ: "OTHER", addrK: "PUBLIC", label: "SAMSUNG DEVICE"},
		{name: "first word of name", addr: priv, random: true,
			ads:   [][]byte{nameAD("Foobar Baz 12")},
			brand: "FOOBAR", typ: "OTHER", addrK: "PRIVATE", label: "FOOBAR BAZ 12"},
		{name: "name word beats unknown company id", addr: priv, random: true,
			ads:   [][]byte{mfr(0xB5B5, 1), nameAD("Foobar")},
			brand: "FOOBAR", typ: "OTHER", addrK: "PRIVATE", label: "FOOBAR"},
		{name: "hint when no other clue", addr: priv, random: true,
			ads:   [][]byte{{0x03, 0x16, 0x9F, 0xFE}, mfr(0xB5B5, 1)},
			brand: "GOOGLE", typ: "OTHER", addrK: "PRIVATE", label: "GOOGLE DEVICE"},
		{name: "airpods pro 2 model", addr: priv, random: true,
			ads:   [][]byte{apple(pods...)},
			brand: "APPLE", typ: "AIRPODS", model: "AIRPODS PRO 2", addrK: "PRIVATE", label: "AIRPODS PRO 2"},
		{name: "beats model uses BEATS kind", addr: priv, random: true,
			ads:   [][]byte{apple(append([]byte{0x07, 0x19, 0x01, 0x11, 0x20}, make([]byte, 22)...)...)},
			brand: "APPLE", typ: "BEATS", model: "BEATS STUDIO BUDS", addrK: "PRIVATE", label: "BEATS STUDIO BUDS"},
		{name: "unknown apple model", addr: priv, random: true,
			ads:   [][]byte{apple(append([]byte{0x07, 0x19, 0x01, 0xEE, 0xEE}, make([]byte, 22)...)...)},
			brand: "APPLE", typ: "AIRPODS", model: "", addrK: "PRIVATE", label: "APPLE AIRPODS"},
		{name: "CDP windows laptop", addr: priv, random: true,
			ads:   [][]byte{mfr(0x06, 0x01, 0x0F, 0x80, 0x00)},
			brand: "MICROSOFT", typ: "WINDOWS", model: "WINDOWS LAPTOP", addrK: "PRIVATE", label: "WINDOWS LAPTOP"},
		{name: "ibeacon major/minor", addr: priv, random: true,
			ads: [][]byte{apple(0x02, 0x15, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
				0x04, 0xD2, 0x16, 0x2E, 0xC5)},
			brand: "APPLE", typ: "IBEACON", addrK: "PRIVATE", label: "APPLE IBEACON", beacon: "IBEACON 1234/5678"},
		{name: "eddystone url", addr: priv, random: true,
			ads:   [][]byte{{0x06, 0x16, 0xAA, 0xFE, 0x10, 0xF8, 0x03}},
			brand: "UNKNOWN", typ: "EDDYSTONE", addrK: "PRIVATE", label: "EDDYSTONE 6A:11:22", beacon: "EDDYSTONE URL"},
		{name: "service kind heart rate", addr: priv, random: true,
			ads:   [][]byte{svcAD(0x180F, 0x180D)},
			brand: "UNKNOWN", typ: "HEART RATE", addrK: "PRIVATE", label: "HEART RATE 6A:11:22"},
		{name: "battery alone ignored", addr: priv, random: true,
			ads:   [][]byte{svcAD(0x180F)},
			brand: "UNKNOWN", typ: "OTHER", addrK: "PRIVATE", label: "UNKNOWN 6A:11:22"},
		{name: "le audio", addr: priv, random: true,
			ads:   [][]byte{svcAD(0x184E)},
			brand: "UNKNOWN", typ: "LE AUDIO", addrK: "PRIVATE", label: "LE AUDIO 6A:11:22"},
		{name: "appearance last", addr: priv, random: true,
			ads:   [][]byte{{0x03, 0x19, 0x41, 0x09}},
			brand: "UNKNOWN", typ: "EARBUD", addrK: "PRIVATE", label: "EARBUD 6A:11:22"},
		{name: "mfr kind beats name kind", addr: priv, random: true,
			ads:   [][]byte{apple(0x10, 0x05, 1, 2, 3, 4, 5), nameAD("IPHONE")},
			brand: "APPLE", typ: "NEARBY", addrK: "PRIVATE", label: "IPHONE"},
		{name: "name kind beats service kind", addr: priv, random: true,
			ads:   [][]byte{nameAD("JABRA ELITE"), svcAD(0x180D)},
			brand: "JABRA", typ: "HEADSET", addrK: "PRIVATE", label: "JABRA ELITE"},
		{name: "name OTHER kind falls to service kind", addr: priv, random: true,
			ads:   [][]byte{nameAD("HUAWEI P30"), svcAD(0x180D)},
			brand: "HUAWEI", typ: "HEART RATE", addrK: "PRIVATE", label: "HUAWEI P30"},
		{name: "swapped unknown company keeps ID fallback", addr: priv, random: true,
			ads:   [][]byte{mfr(0x1234, 1)},
			brand: "ID 1234", typ: "OTHER", addrK: "PRIVATE", label: "ID 1234 DEVICE"},
	}
	for _, tc := range tests {
		d := observeAd(t, tc.addr, tc.random, tc.ads...)
		if d.Brand != tc.brand || d.Type != tc.typ || d.Model != tc.model || d.AddrKind != tc.addrK ||
			d.Label != tc.label || d.BeaconInfo != tc.beacon {
			t.Errorf("%s:\n got brand=%q type=%q model=%q addr=%q label=%q beacon=%q\nwant brand=%q type=%q model=%q addr=%q label=%q beacon=%q",
				tc.name, d.Brand, d.Type, d.Model, d.AddrKind, d.Label, d.BeaconInfo,
				tc.brand, tc.typ, tc.model, tc.addrK, tc.label, tc.beacon)
		}
		if tc.maker != "" && (d.Maker != tc.maker || d.MakerFull == "") {
			t.Errorf("%s: maker %q full %q", tc.name, d.Maker, d.MakerFull)
		}
		if d.Maker != "" && d.Maker != d.Brand {
			t.Errorf("%s: maker %q != brand %q", tc.name, d.Maker, d.Brand)
		}
	}
}

func TestClassifyRealPacketB(t *testing.T) {
	got := ParseLEAdvertEvent(hx(t, realB))
	tr := NewBLETracker(time.Minute)
	tr.Observe(got[0], t0)
	d := tr.Devices(t0)[0]
	// The captured device has a public address whose OUI is registered to
	// Espressif; that identifies it where the unassigned id 0xB5B5 cannot.
	if d.Brand != "ESPRESSIF" || d.AddrKind != "PUBLIC" || d.MakerFull == "" {
		t.Errorf("%+v", d)
	}
}

func TestClassifyUnknownIDNeverUsesIDWhenNameKnown(t *testing.T) {
	d := observeAd(t, "6A:11:22:33:44:55", true, mfr(0xB5B5, 1), nameAD("Tile Mate"))
	if d.Brand != "TILE" || d.Type != "TRACKER" {
		t.Errorf("%+v", d)
	}
}

func TestClassifyServicesAndMakerFull(t *testing.T) {
	d := observeAd(t, "6A:11:22:33:44:55", true, svcAD(0x180D, 0x180F, 0x1812, 0x1800, 0x1801), mfr(0x4C, 0x10, 1, 0))
	if len(d.Services) != 3 || !strings.Contains(d.Services[0], "HEART RATE") {
		t.Errorf("services %v", d.Services)
	}
	if d.Brand != "APPLE" || d.MakerFull == "" {
		t.Errorf("%+v", d)
	}
	for _, s := range d.Services {
		if s != strings.ToUpper(s) {
			t.Errorf("service %q not upper case", s)
		}
	}
}

func TestAdvertServiceUUIDsCappedAndDeduped(t *testing.T) {
	var u []int
	for i := 0; i < 12; i++ {
		u = append(u, 0x1800+i)
	}
	a := parseOne(t, append(svcAD(0x1800, 0x1800), svcAD(u...)...))
	if len(a.ServiceUUIDs) != 8 || a.ServiceUUIDs[0] != 0x1800 || a.ServiceUUIDs[1] != 0x1801 {
		t.Errorf("%v", a.ServiceUUIDs)
	}
}

func TestEddystoneFrames(t *testing.T) {
	for b, want := range map[byte]string{0x00: "EDDYSTONE UID", 0x10: "EDDYSTONE URL", 0x20: "EDDYSTONE TLM", 0x30: "EDDYSTONE EID", 0x40: ""} {
		a := parseOne(t, []byte{0x04, 0x16, 0xAA, 0xFE, b})
		if a.BeaconInfo != want || a.Kind != "EDDYSTONE" {
			t.Errorf("%#x: %+v", b, a)
		}
	}
}

func TestMalformedModelsNeverPanic(t *testing.T) {
	ads := [][]byte{
		mfr(0x4C, 0x07, 0x19, 0x01),       // overrunning pairing TLV
		mfr(0x4C, 0x07, 0x02, 0x01, 0x14), // too short for a model
		mfr(0x4C, 0x02, 0x15, 1, 2, 3),    // truncated iBeacon
		mfr(0x4C, 0x02, 0x04, 1, 2, 3, 4), // short iBeacon
		mfr(0x06, 0x01),                   // CDP without type byte
		mfr(0x06, 0x01, 0xFF),             // unknown CDP type
		{0x03, 0x16, 0xAA, 0xFE},          // eddystone without frame
		{0x02, 0x03, 0xAA},                // half a uuid
	}
	for _, ad := range ads {
		a := parseOne(t, ad)
		if a.BeaconInfo != "" && !strings.HasPrefix(a.BeaconInfo, "IBEACON") {
			t.Errorf("%x: %+v", ad, a)
		}
	}
}

func TestEntryNotReclassifiedWhenInputsUnchanged(t *testing.T) {
	tr := NewBLETracker(time.Minute)
	a := Advert{Addr: "6A:11:22:33:44:55", Random: true, RSSI: -60, Company: 0x4C, MfrKind: "NEARBY", Appearance: -1,
		ServiceUUIDs: []int{0x180D}}
	tr.Observe(a, t0)
	e := tr.devs[a.Addr]
	gen := e.gen
	for i := 1; i < 5; i++ {
		a.RSSI = -50 - i
		tr.Observe(a, t0.Add(time.Duration(i)*time.Second))
	}
	if e.gen != gen {
		t.Errorf("reclassified on unchanged inputs: gen %d -> %d", gen, e.gen)
	}
	a.Name = "MY WATCH"
	tr.Observe(a, t0.Add(10*time.Second))
	if e.gen == gen {
		t.Error("name change must reclassify")
	}
	if d := tr.Devices(t0.Add(10 * time.Second))[0]; d.Label != "MY WATCH" {
		t.Errorf("%+v", d)
	}
	// A new service also reclassifies; services stay unique and capped.
	a.ServiceUUIDs = []int{0x180D, 0x1812}
	g := e.gen
	tr.Observe(a, t0.Add(11*time.Second))
	if e.gen == g || !reflect.DeepEqual(e.services, []int{0x180D, 0x1812}) {
		t.Errorf("services %v gen %d", e.services, e.gen)
	}
}

func TestStickyModelAndNameClassification(t *testing.T) {
	tr := NewBLETracker(time.Minute)
	pods := append([]byte{0x07, 0x19, 0x01, 0x0E, 0x20}, make([]byte, 22)...)
	a := parseOne(t, apple(pods...))
	a.Addr, a.Random = "6A:11:22:33:44:55", true
	tr.Observe(a, t0)
	b := Advert{Addr: a.Addr, Random: true, RSSI: -70, Company: -1, Appearance: -1}
	tr.Observe(b, t0.Add(time.Second))
	d := tr.Devices(t0.Add(time.Second))[0]
	if d.Model != "AIRPODS PRO" || d.Brand != "APPLE" || d.Type != "AIRPODS" {
		t.Errorf("%+v", d)
	}
}

func TestSlowClassifierDoesNotBlockReaders(t *testing.T) {
	// Observe must not hold the tracker lock while it runs the (possibly slow,
	// first-load) database classification: readers get a provisional answer.
	release, entered := make(chan struct{}), make(chan struct{})
	old := fullClassify
	fullClassify = func(in bleClassIn) bleClass {
		close(entered)
		<-release
		return classifyBLE(in, true)
	}
	defer func() { fullClassify = old }()
	tr := NewBLETracker(time.Minute)
	obs := make(chan struct{})
	go func() {
		tr.Observe(Advert{Addr: "F8:FF:C2:00:00:01", RSSI: -60, Company: 0x4C, Appearance: -1}, t0)
		close(obs)
	}()
	<-entered
	done := make(chan []BLEDevice)
	go func() { done <- tr.Devices(t0) }()
	select {
	case ds := <-done:
		if len(ds) != 1 || ds[0].Brand != "APPLE" {
			t.Errorf("provisional answer: %+v", ds)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Devices blocked behind a running classification")
	}
	close(release)
	<-obs
}
