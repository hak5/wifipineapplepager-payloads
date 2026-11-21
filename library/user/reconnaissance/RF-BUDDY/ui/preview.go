package main

import (
	"fmt"
	"image/png"
	"os"
	"path/filepath"
	"time"
)

type previewCase struct {
	name string
	snap Snapshot
	ui   func() *ui
}

func previewSnapshot(now time.Time, stress bool) Snapshot {
	t := DefaultThresholds()
	bt := 23
	if stress {
		bt = 999
	}
	view := func(ch Channel, airtime, retry float64, aps, overlap int, hasBT bool) ChannelView {
		m := Metrics{AirtimePct: airtime, HasAirtime: true, RetryPct: retry, HasRetry: true, FramesPerSec: airtime * 4,
			CoChannelAPs: aps, OverlapAPs: overlap, BTCount: bt, HasBT: hasBT}
		score := Score(m)
		return ChannelView{Channel: ch, Metrics: m, Raw: score, Score: score, Likely: Likely(m, ch.Band, t), Measured: true, Updated: now}
	}
	var s Snapshot
	airtime24 := []float64{58, 20, 12, 18, 41, 22, 47, 24, 21, 35, 52}
	retry24 := []float64{12, 6, 4, 5, 9, 38, 11, 7, 6, 8, 14}
	for i := range airtime24 {
		s.Channels24 = append(s.Channels24, view(Channel{Band24, i + 1}, airtime24[i], retry24[i], 3+i%4, i%3, true))
	}
	nums5 := []int{36, 40, 44, 48, 149, 153, 157, 161}
	if stress {
		nums5 = []int{36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144, 149, 153, 157, 161, 165}
	}
	for i, n := range nums5 {
		s.Channels5 = append(s.Channels5, view(Channel{Band5, n}, float64(5+(i*13)%60), 4, 1+i%3, 0, true))
	}
	if stress {
		s.Channels24[2].Skipped = true
		s.Channels5[3].Skipped = true
	}
	lock := LockView{ChannelView: s.Channels24[5], Peak: 94, PeakAt: now.Add(-time.Minute), Trend: TrendRising}
	for i := 0; i < lockHistoryLen; i++ {
		lock.History = append(lock.History, 40+i*50/lockHistoryLen)
	}
	lock.Top = []Transmitter{{Addr: "70:A7:41:6C:00:2E", SSID: "NINEDTER", SignalDBm: -67}, {Addr: "02:68:EB:EC:0C:6E", SSID: "DIRECT-6E-HP M479fdw Color LJ", SignalDBm: -48}}
	if stress {
		lock.Score, lock.Raw, lock.Peak = 100, 100, 100
		lock.Top = []Transmitter{{Addr: "AA:BB:CC:00:00:09", SSID: "THIS-IS-A-VERY-LONG-GUEST-NETWORK-NAME-FOR-CONTAINMENT", SignalDBm: -100}, {Addr: "AA:BB:CC:00:00:0A", SignalDBm: -99}}
	}
	s.Lock = &lock
	s.BTCount, s.HasBT, s.LogPaused = bt, true, stress
	if stress {
		s.RadioError = "FRAME CAPTURE FAILED ON WLAN1MON - RETRYING EVERY SECOND"
	}
	return s
}

func noBluetoothSnapshot(now time.Time) Snapshot {
	s := previewSnapshot(now, false)
	for _, list := range [][]ChannelView{s.Channels24, s.Channels5} {
		for i := range list {
			list[i].Metrics.HasBT = false
			list[i].Likely = Likely(list[i].Metrics, list[i].Channel.Band, DefaultThresholds())
		}
	}
	s.HasBT = false
	return s
}

func previewBTSnapshot(now time.Time) Snapshot {
	s := previewSnapshot(now, false)
	type dev struct {
		brand, typ, name string
		rssi             int
		adv              float64
		tx               int
		model, beacon    string
		makerFull, addr  string
		svc              []string
		public           bool
	}
	// a realistic office mix: lots of Apple, a Nanoleaf strip, Microsoft, randoms
	devs := []dev{
		{"APPLE", "AIRPODS", "", -42, 9.8, 0, "AIRPODS PRO 2", "", "APPLE", "", nil, false},
		{"APPLE", "FIND MY", "", -48, 2.1, 0, "", "", "", "", nil, false},
		{"NANOLEAF", "LIGHT", "NANOLEAF STRIP FCE", -55, 4.2, 12, "", "", "", "", nil, false},
		{"APPLE", "NEARBY", "", -57, 3.0, 0, "", "", "", "", nil, false},
		{"APPLE", "FIND MY", "", -59, 1.8, 0, "", "", "", "", nil, false},
		{"MICROSOFT", "SWIFT PAIR", "", -63, 2.1, 0, "", "", "", "", nil, false},
		{"APPLE", "AIRPLAY", "", -64, 1.4, 0, "", "", "", "", nil, false},
		{"APPLE", "FIND MY", "", -66, 1.6, 0, "", "", "", "", nil, false},
		{"UNKNOWN", "OTHER", "", -67, 1.5, 0, "", "", "", "", nil, false},
		{"APPLE", "HANDOFF", "", -68, 1.1, 0, "", "", "", "", nil, false},
		{"APPLE", "FIND MY", "", -70, 1.2, 0, "", "", "", "", nil, false},
		{"APPLE", "NEARBY", "", -71, 0.9, 0, "", "", "", "", nil, false},
		{"SAMSUNG", "WATCH", "GALAXY WATCH5 PRO (LIVING ROOM)", -72, 3.3, 8, "", "", "", "", nil, false},
		{"APPLE", "FIND MY", "", -73, 1.0, 0, "", "", "", "", nil, false},
		{"GOOGLE", "FAST PAIR", "", -75, 1.1, 0, "", "", "", "", nil, false},
		{"APPLE", "FIND MY", "", -76, 0.9, 0, "", "", "", "", nil, false},
		{"APPLE", "NEARBY", "", -77, 0.8, 0, "", "", "", "", nil, false},
		{"MICROSOFT", "WINDOWS", "", -78, 0.7, 0, "WINDOWS LAPTOP", "", "MICROSOFT", "", nil, false},
		{"APPLE", "FIND MY", "", -79, 0.8, 0, "", "", "", "", nil, false},
		{"ESPRESSIF", "IBEACON", "", -80, 0.6, 0, "", "IBEACON 100/7", "ESPRESSIF", "24:6F:28:5A:C3:19", nil, true},
		{"APPLE", "FIND MY", "", -81, 0.7, 0, "", "", "", "", nil, false},
		{"APPLE", "NEARBY", "", -82, 0.6, 0, "", "", "", "", nil, false},
		{"TILE", "TRACKER", "", -83, 0.5, 0, "", "", "", "", nil, false},
		{"APPLE", "FIND MY", "", -84, 0.6, 0, "", "", "", "", nil, false},
		{"GARMIN", "WATCH", "", -85, 0.7, 0, "", "", "", "", nil, false},
		{"APPLE", "NEARBY", "", -86, 0.5, 0, "", "", "", "", nil, false},
		{"MICROSOFT", "SWIFT PAIR", "", -87, 0.5, 0, "", "", "", "", nil, false},
		{"APPLE", "FIND MY", "", -88, 0.5, 0, "", "", "", "", nil, false},
		{"UNKNOWN", "OTHER", "", -89, 0.4, 0, "", "", "", "", nil, false},
		{"XIAOMI", "FITNESS", "", -90, 0.6, 0, "", "", "", "", nil, false},
		{"APPLE", "NEARBY", "", -91, 0.4, 0, "", "", "", "", nil, false},
		{"MICROSOFT", "WINDOWS", "", -92, 0.4, 0, "", "", "", "", nil, false},
		{"UNKNOWN", "OTHER", "", -93, 0.3, 0, "", "", "", "", nil, false},
		{"APPLE", "AIRPLAY", "", -94, 0.3, 0, "", "", "", "", nil, false},
		{"ESPRESSIF", "OTHER", "", -95, 0.2, 0, "", "", "", "", nil, false},
		{"APPLE", "FIND MY", "", -100, 0.2, 0, "", "", "", "", nil, false},
		{"UNKNOWN", "OTHER", "", -100, 0.2, 0, "", "", "", "", nil, false},
		{"SAMSUNG", "PHONE", "GALAXY S23", -61, 2.4, 8, "", "", "SAMSUNG ELECTRONICS", "", nil, false},
		{"BOSE", "AUDIO", "BOSE QC35 II", -66, 1.9, 0, "", "", "BOSE", "", []string{"LE AUDIO"}, false},
		{"HARMAN JBL", "SPEAKER", "JBL FLIP 5", -70, 1.7, 0, "", "", "HARMAN JBL", "", nil, false},
		{"POLAR", "HEART RATE", "POLAR H10 A1B2C3", -72, 1.0, 0, "", "", "POLAR", "", []string{"HEART RATE", "BATTERY"}, true},
		{"REALTEK", "OTHER", "", -84, 0.6, 0, "", "", "REALTEK", "", nil, true},
		{"ID B5B5", "OTHER", "", -88, 0.5, 0, "", "", "", "D1:7A:3C:09:E2:5B", nil, false},
	}
	for i, d := range devs {
		b := BLEDevice{
			Addr:   fmt.Sprintf("%02X:%02X:%02X:%02X:%02X:%02X", 0x40+i, 0x63^i, 0xB5-i, 0x11*(i%9), 0x20+3*i, 0xA0+i),
			Random: !d.public && d.brand != "BOSE" && d.brand != "HARMAN JBL",
			Brand:  d.brand, Type: d.typ, Name: d.name, Maker: d.brand, Kind: d.typ,
			Model: d.model, BeaconInfo: d.beacon, MakerFull: d.makerFull, Services: d.svc,
			RSSI: d.rssi, Peak: min(-30, d.rssi+6+i%5), AdvPerSec: d.adv, TxPower: d.tx, HasTx: d.tx != 0,
			LastSeen:  now.Add(-time.Duration(i%4) * time.Second),
			FirstSeen: now.Add(-time.Duration(60+i*47) * time.Second),
		}
		if d.rssi <= -100 {
			b.Peak = -100
		}
		if d.brand == "UNKNOWN" { // non-resolvable randoms
			b.Addr = fmt.Sprintf("%02X%s", 0x10+i, b.Addr[2:])
		}
		if d.addr != "" {
			b.Addr = d.addr
		}
		if d.brand == "UNKNOWN" {
			b.Maker = ""
		}
		b.AddrKind = bleAddrKind(b.Addr, b.Random)
		b.Label = bleLabel(b)
		s.BT = append(s.BT, b)
	}
	s.BTCount, s.HasBT, s.BTAdvPerSec = len(devs), true, 90
	return s
}

func previewBTTrack(now time.Time, lost bool) Snapshot {
	s := previewBTSnapshot(now)
	t := BLETrackView{BLEDevice: s.BT[2], Trend: TrendRising, PeakAt: now.Add(-45 * time.Second)}
	t.Name = "NANOLEAF STRIP FCE"
	t.RSSI, t.Peak = -41, -38
	for i := 0; i < lockHistoryLen; i++ {
		v := -90 + i*50/lockHistoryLen
		if i%17 == 5 {
			v = -100
		}
		t.History = append(t.History, v)
	}
	if lost {
		t.Lost, t.Trend = true, TrendSteady
		t.LastSeen = now.Add(-9 * time.Second)
		for i := 50; i < lockHistoryLen; i++ {
			t.History[i] = -100
		}
	}
	s.BTTrack = &t
	return s
}

func previewCases(now time.Time) []previewCase {
	clock := func() time.Time { return now }
	okCaps := Capabilities{Tune: true, Capture: true, Bluetooth: true}
	noBT := Capabilities{Tune: true, Capture: true}
	fatal := Capabilities{FatalReason: "SOMETHING ELSE IS MOVING WLAN1MON OFF THE LOCKED CHANNEL. CLOSE OTHER RECON PAYLOADS, THEN RELAUNCH RF-BUDDY."}
	normal, stress := previewSnapshot(now, false), previewSnapshot(now, true)
	mk := func(caps Capabilities, probed bool, scr screen, band Band, toast string) func() *ui {
		return func() *ui {
			u := newUI(nil, nil, clock)
			u.caps, u.probed, u.screen, u.band, u.toast = caps, probed, scr, band, toast
			return u
		}
	}
	btSnap, btEmpty := previewBTSnapshot(now), previewBTSnapshot(now)
	btEmpty.BT, btEmpty.BTCount, btEmpty.BTAdvPerSec = nil, 0, 0
	btNA := previewBTSnapshot(now)
	btNA.BT, btNA.BTCount, btNA.HasBT = nil, 0, false
	mkBT := func(level int, brand, typ, addr string, audio bool) func() *ui {
		return func() *ui {
			u := newUI(nil, nil, clock)
			u.caps, u.probed, u.audio = okCaps, true, audio
			u.btBrand, u.btType, u.btAddr = brand, typ, addr
			u.setBTLevel(level)
			return u
		}
	}
	trackAddr := btSnap.BT[2].Addr
	findMy := DevicesOf(btSnap.BT, "APPLE", "FIND MY")
	findMyLast := findMy[len(findMy)-2].Addr
	find := func(pred func(BLEDevice) bool) string {
		for _, d := range btSnap.BT {
			if pred(d) {
				return d.Addr
			}
		}
		return ""
	}
	modelAddr := find(func(d BLEDevice) bool { return d.Model == "AIRPODS PRO 2" })
	beaconAddr := find(func(d BLEDevice) bool { return d.BeaconInfo != "" })
	idAddr := find(func(d BLEDevice) bool { return d.Brand == "ID B5B5" })
	return []previewCase{
		{"01-probe-checking.png", normal, mk(okCaps, false, screenProbe, Band24, "")},
		{"02-probe-result.png", normal, mk(noBT, true, screenProbe, Band24, "")},
		{"03-overview-24.png", normal, mk(okCaps, true, screenOverview, Band24, "")},
		{"04-overview-5.png", normal, mk(okCaps, true, screenOverview, Band5, "")},
		{"05-lock.png", normal, mk(okCaps, true, screenLock, Band24, "")},
		{"06-no-bluetooth-overview.png", noBluetoothSnapshot(now), mk(noBT, true, screenOverview, Band24, "")},
		{"07-fatal.png", normal, mk(fatal, true, screenFatal, Band24, "")},
		{"08-stress-overview.png", stress, mk(okCaps, true, screenOverview, Band5, "")},
		{"09-stress-lock.png", stress, mk(okCaps, true, screenLock, Band24, "MARK 12 @ 12:42 - SCORE 100 WITH A VERY LONG OPERATOR NOTE")},
		{"10-bt-brands.png", btSnap, mkBT(btLevelBrands, "SAMSUNG", "", "", true)},
		{"11-bt-types-apple.png", btSnap, mkBT(btLevelTypes, "APPLE", "FIND MY", "", true)},
		{"12-bt-devices-find-my.png", btSnap, mkBT(btLevelDevices, "APPLE", "FIND MY", findMyLast, true)},
		{"13-bt-device-long-name.png", btSnap, mkBT(btLevelDevices, "SAMSUNG", "WATCH", "", true)},
		{"14-bt-types-empty.png", btSnap, mkBT(btLevelTypes, "GONE BRAND", "", "", true)},
		{"15-bt-brands-empty.png", btEmpty, mkBT(btLevelBrands, "", "", "", true)},
		{"16-bt-na.png", btNA, mkBT(btLevelBrands, "", "", "", true)},
		{"17-bt-track.png", previewBTTrack(now, false), mkBT(btLevelTrack, "NANOLEAF", "LIGHT", trackAddr, true)},
		{"18-bt-track-lost.png", previewBTTrack(now, true), mkBT(btLevelTrack, "NANOLEAF", "LIGHT", trackAddr, false)},
		{"19-bt-device-model-private.png", btSnap, mkBT(btLevelDevices, "APPLE", "AIRPODS", modelAddr, true)},
		{"20-bt-device-beacon-public.png", btSnap, mkBT(btLevelDevices, "ESPRESSIF", "IBEACON", beaconAddr, true)},
		{"21-bt-device-id-brand-static.png", btSnap, mkBT(btLevelDevices, "ID B5B5", "OTHER", idAddr, true)},
		{"22-bt-types-services.png", btSnap, mkBT(btLevelTypes, "POLAR", "HEART RATE", "", true)},
	}
}

// renderPreviews writes deterministic PNGs of every screen state for review.
func renderPreviews(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	now := time.Date(2026, 10, 1, 12, 42, 0, 0, time.Local)
	for _, c := range previewCases(now) {
		f, err := os.Create(filepath.Join(dir, c.name))
		if err != nil {
			return err
		}
		err = png.Encode(f, c.ui().Render(c.snap, now))
		if closeErr := f.Close(); err == nil {
			err = closeErr
		}
		if err != nil {
			return err
		}
	}
	return nil
}
