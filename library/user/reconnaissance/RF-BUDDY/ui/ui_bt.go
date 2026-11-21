package main

import (
	"fmt"
	"image"
	"image/color"
	"strconv"
	"time"
)

const btVisibleRows = 9

// BT browser levels: brands -> types -> devices -> track.
const (
	btLevelBrands = iota
	btLevelTypes
	btLevelDevices
	btLevelTrack
)

// btIndex returns the index of the selected device, falling back to 0 when the
// remembered address is gone. ok is false for an empty list.
func (u *ui) btIndex(list []BLEDevice) (int, bool) {
	if len(list) == 0 {
		return 0, false
	}
	for i, d := range list {
		if d.Addr == u.btAddr {
			return i, true
		}
	}
	return 0, true
}

func (u *ui) btSelected(list []BLEDevice) (BLEDevice, bool) {
	i, ok := u.btIndex(list)
	if !ok {
		return BLEDevice{}, false
	}
	return list[i], true
}

// moveBT selects the neighbouring device and reports whether the address changed.
func (u *ui) moveBT(list []BLEDevice, delta int) bool {
	i, ok := u.btIndex(list)
	if !ok {
		return false
	}
	prev := u.btAddr
	u.btAddr = list[clampIndex(i+delta, len(list))].Addr
	return u.btAddr != prev
}

func btDelta(button string) int {
	if button == "LEFT" || button == "UP" {
		return -1
	}
	return 1
}

// groupIndex returns the index of the group called name, 0 when it is gone.
func groupIndex(groups []BTGroup, name string) int {
	for i, g := range groups {
		if g.Name == name {
			return i
		}
	}
	return 0
}

// moveGroup selects the neighbouring group and returns its name.
func moveGroup(groups []BTGroup, cur string, delta int) string {
	if len(groups) == 0 {
		return cur
	}
	return groups[clampIndex(groupIndex(groups, cur)+delta, len(groups))].Name
}

func (u *ui) setBTLevel(level int) {
	u.btLevel = level
	if level == btLevelTrack {
		u.screen = screenBTTrack
	} else {
		u.screen = screenBT
	}
}

// btDevices lists the devices of the browsed brand and type.
func (u *ui) btDevices(s Snapshot) []BLEDevice {
	return DevicesOf(s.BT, u.btBrand, u.btType)
}

func (u *ui) handleBT(button string, s Snapshot) bool {
	switch u.btLevel {
	case btLevelBrands:
		groups := GroupByBrand(s.BT)
		switch button {
		case "B":
			return true
		case "LEFT", "RIGHT":
			u.btBrand = moveGroup(groups, u.btBrand, btDelta(button))
		case "UP":
			u.cycleTab(1)
		case "DOWN":
			u.cycleTab(-1)
		case "A":
			if len(groups) > 0 {
				u.btBrand = groups[groupIndex(groups, u.btBrand)].Name
				u.btType, u.btAddr = "", ""
				u.setBTLevel(btLevelTypes)
			}
		}
	case btLevelTypes:
		groups := GroupByType(s.BT, u.btBrand)
		switch button {
		case "B":
			u.setBTLevel(btLevelBrands)
		case "LEFT", "RIGHT", "UP", "DOWN":
			u.btType = moveGroup(groups, u.btType, btDelta(button))
		case "A":
			if len(groups) > 0 {
				u.btType = groups[groupIndex(groups, u.btType)].Name
				u.btAddr = ""
				u.setBTLevel(btLevelDevices)
			}
		}
	default:
		list := u.btDevices(s)
		switch button {
		case "B":
			u.setBTLevel(btLevelTypes)
		case "LEFT", "RIGHT", "UP", "DOWN":
			u.moveBT(list, btDelta(button))
		case "A":
			if d, ok := u.btSelected(list); ok {
				u.btAddr = d.Addr
				u.ctrl.TrackBT(d.Addr)
				u.setBTLevel(btLevelTrack)
			}
		}
	}
	return false
}

func (u *ui) handleBTTrack(button string, s Snapshot) bool {
	switch button {
	case "B":
		u.ctrl.UntrackBT()
		u.setBTLevel(btLevelDevices)
	case "LEFT", "RIGHT":
		if u.moveBT(u.btDevices(s), btDelta(button)) {
			u.ctrl.TrackBT(u.btAddr)
		}
	case "UP":
		u.audio = !u.audio
	case "A":
		u.markBT(s)
	}
	return false
}

func (u *ui) markBT(s Snapshot) {
	t := s.BTTrack
	if t == nil || u.marks == nil {
		return
	}
	now := u.now()
	n, err := u.marks.AddMark(Mark{At: now, BT: true, BTAddr: t.Addr, BTLabel: t.Label, RSSI: t.RSSI})
	if err != nil {
		u.showToast("MARK NOT SAVED: LOG PAUSED", now)
		return
	}
	u.showToast(fmt.Sprintf("MARK %d @ %s - %d DBM", n, now.Format("15:04"), t.RSSI), now)
}

// btTickScore maps RSSI -90 dBm -> 20 and -35 dBm -> 100 onto the tick score scale.
func btTickScore(rssi int) int {
	return min(100, max(20, 20+(rssi+90)*80/55))
}

// proximity maps a smoothed RSSI to a walk-around hint.
func proximity(rssi int) (string, color.RGBA) {
	switch {
	case rssi >= -50:
		return "VERY CLOSE", red
	case rssi >= -65:
		return "CLOSE", amber
	case rssi >= -80:
		return "NEAR", yellow
	default:
		return "FAR", green
	}
}

func fmtRSSI(rssi int) string {
	if rssi <= -100 {
		return "--"
	}
	return strconv.Itoa(rssi)
}

// btAddrText returns the address; short drops the first octet to fit the
// 16-cell metric value box.
// btRowText is the device-level row text: the name if advertised, else the
// address (brand and type are already in the breadcrumb).
func btRowText(d BLEDevice) string {
	if d.Name != "" {
		return d.Name
	}
	return btAddrText(d, true)
}

func btAddrText(d BLEDevice, short bool) string {
	a := d.Addr
	if short && len(a) > 3 {
		a = a[3:]
	}
	if d.Random {
		a += " R"
	}
	return a
}

func secondsAgo(at, now time.Time) int {
	return max(0, int(now.Sub(at)/time.Second))
}

// lastSeenText is the "N S AGO" caption, or "-- S AGO" when never seen.
func lastSeenText(at, now time.Time) string {
	if at.IsZero() {
		return "-- S AGO"
	}
	return fmt.Sprintf("%d S AGO", secondsAgo(at, now))
}

func (u *ui) renderBTTrack(img *image.RGBA, s Snapshot, now time.Time) {
	t := s.BTTrack
	if t == nil {
		d, _ := u.btSelected(u.btDevices(s))
		if d.Addr == "" {
			d = BLEDevice{Addr: u.btAddr, Label: "UNKNOWN", RSSI: -100}
		}
		t = &BLETrackView{BLEDevice: d, Lost: true, Trend: TrendSteady}
	}
	drawTextBox(img, image.Rect(6, 3, 300, 20), 6, 3, trimCells("TRACKING: "+t.Label, 36), yellow, true, 1)
	if u.audio {
		drawTextBox(img, image.Rect(300, 3, 390, 20), 300, 3, "AUDIO ON", cyan, true, 1)
	} else {
		drawTextBox(img, image.Rect(300, 3, 390, 20), 300, 3, "AUDIO OFF", dim, true, 1)
	}
	renderClock(img, now, s.LogPaused)
	hLine(img, 4, 476, 21, cyan2)

	c, num, level := dim, "--", "SIGNAL LOST"
	switch {
	case t.Lost:
	case t.RSSI <= -100:
		level = "NO RSSI"
	default:
		level, c = proximity(t.RSSI)
		num = strconv.Itoa(t.RSSI)
	}
	stroke(img, image.Rect(6, 26, 132, 196), 1, c)
	drawTextBox(img, image.Rect(7, 27, 131, 100), 69-textPixelWidth(num, 4)/2, 32, num, c, true, 4)
	drawCenteredIn(img, 7, 131, 100, level, c)
	trend, tc := "- STEADY", white
	switch t.Trend {
	case TrendRising:
		trend, tc = "^ CLOSER", red
	case TrendFalling:
		trend, tc = "v FARTHER", green
	}
	drawCenteredIn(img, 7, 131, 120, trend, tc)
	peakAt := "--"
	if !t.PeakAt.IsZero() {
		peakAt = "@" + t.PeakAt.Format("15:04")
	}
	drawCenteredIn(img, 7, 131, 146, "PEAK "+fmtRSSI(t.Peak), dim)
	drawCenteredIn(img, 7, 131, 164, peakAt, dim)

	inline := func(x int, label, value string, vc color.RGBA) {
		drawText(img, x, 26, label, white, true, 1)
		vx := x + textPixelWidth(label, 1) + 8
		drawTextBox(img, image.Rect(vx, 26, 476, 42), vx, 26, value, vc, true, 1)
	}
	tx, maker := "--", btMakerText(t.BLEDevice)
	if t.HasTx {
		tx = strconv.Itoa(t.TxPower)
	}
	inline(142, "ADV/S", fmt.Sprintf("%.1f", t.AdvPerSec), cyan)
	inline(252, "TX", tx, cyan)
	inline(322, "MAKER", trimCells(maker, 12), cyan)

	drawText(img, 142, 44, "LAST 60 S", dim, true, 1)
	vLine(img, 142, 62, 111, dim)
	hLine(img, 142, 474, 110, dim)
	h := t.History
	point := func(i int) (int, int) {
		pct := min(100, max(0, (h[i]+100)*100/70))
		return 143 + i*330/(lockHistoryLen-1), 109 - pct*46/100
	}
	pc := func(i int) color.RGBA {
		if h[i] <= -100 {
			return dim
		}
		return signalColor(h[i])
	}
	for i := range h {
		if i >= lockHistoryLen {
			break
		}
		x, y := point(i)
		if i == 0 {
			img.SetRGBA(x, y, pc(i))
			continue
		}
		px, py := point(i - 1)
		drawLine(img, px, py, x, y, pc(i))
	}

	drawTextBox(img, image.Rect(142, 114, 476, 130), 142, 114, "ADDR", white, true, 1)
	drawTextBox(img, image.Rect(190, 114, 476, 130), 190, 114, btAddrText(t.BLEDevice, false), cyan, true, 1)
	kl, kv := "KIND", btKindText(t.BLEDevice)
	if t.Name != "" {
		kl, kv = "NAME", t.Name
	}
	if kv == "" {
		kv = "--"
	}
	drawText(img, 142, 132, kl, white, true, 1)
	drawTextBox(img, image.Rect(190, 132, 476, 148), 190, 132, trimCells(kv, 35), cyan, true, 1)
	drawText(img, 142, 150, "SEEN", white, true, 1)
	drawTextBox(img, image.Rect(190, 150, 476, 166), 190, 150, lastSeenText(t.LastSeen, now), cyan, true, 1)
	drawTextBox(img, image.Rect(142, 176, 476, 192), 142, 176, trimCells("HITS WI-FI CH "+FormatChannelRuns(HitsWiFi()), 41), dim, true, 1)
	renderFooter(img, hint{"B", "BACK"}, "LEFT/RIGHT DEV", "UP AUDIO", hint{"A", "MARK SPOT"})
}
