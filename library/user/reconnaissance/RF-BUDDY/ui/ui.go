package main

import (
	"fmt"
	"image"
	"image/color"
	"math"
	"strconv"
	"time"
)

type screen int

const (
	screenProbe screen = iota
	screenOverview
	screenLock
	screenFatal
	screenBT
	screenBTTrack
)

const (
	probeResultHold = 2 * time.Second
	toastHold       = 3 * time.Second
)

type Controller interface {
	SetBand(Band)
	Lock(Channel)
	Unlock()
	TrackBT(addr string)
	UntrackBT()
}

type MarkSink interface {
	AddMark(Mark) (int, error)
}

type ui struct {
	ctrl       Controller
	marks      MarkSink
	now        func() time.Time
	screen     screen
	caps       Capabilities
	probed     bool
	probeUntil time.Time
	band       Band
	btLevel    int
	btBrand    string
	btType     string
	btAddr     string
	selected   [2]int
	audio      bool
	toast      string
	toastUntil time.Time
}

func newUI(ctrl Controller, marks MarkSink, now func() time.Time) *ui {
	u := &ui{ctrl: ctrl, marks: marks, now: now, screen: screenProbe, audio: true}
	u.selected[Band24] = 5 // channel 6
	return u
}

func (u *ui) SetProbe(c Capabilities) {
	u.caps, u.probed = c, true
	if c.Fatal() {
		u.screen = screenFatal
		return
	}
	u.screen = screenProbe
	u.probeUntil = u.now().Add(probeResultHold)
}

// LiveBT reports whether a BT screen is showing and needs periodic redraws.
func (u *ui) LiveBT() bool { return u.screen == screenBT || u.screen == screenBTTrack }

// Advance applies time-based transitions and reports whether the screen changed.
func (u *ui) Advance(now time.Time) bool {
	changed := false
	if u.screen == screenProbe && u.probed && !u.caps.Fatal() && !now.Before(u.probeUntil) {
		u.screen, changed = screenOverview, true
	}
	if u.toast != "" && !now.Before(u.toastUntil) {
		u.toast, changed = "", true
	}
	return changed
}

func (u *ui) HandleButton(button string, s Snapshot) (exit bool) {
	if button == "POWER" {
		// Exit and hand the power button back to the stock Pager app, whose
		// Power Menu performs the graceful shutdown.
		return true
	}
	switch u.screen {
	case screenProbe, screenFatal:
		return button == "B"
	case screenOverview:
		list := s.Channels(u.band)
		switch button {
		case "B":
			return true
		case "LEFT":
			u.moveSelection(list, -1)
		case "RIGHT":
			u.moveSelection(list, 1)
		case "UP":
			u.cycleTab(1)
		case "DOWN":
			u.cycleTab(-1)
		case "A":
			if v, ok := u.selectedView(list); ok && !v.Skipped {
				u.ctrl.Lock(v.Channel)
				u.screen = screenLock
			}
		}
	case screenBT:
		return u.handleBT(button, s)
	case screenBTTrack:
		return u.handleBTTrack(button, s)
	case screenLock:
		list := s.Channels(u.band)
		switch button {
		case "B":
			u.ctrl.Unlock()
			u.screen = screenOverview
		case "LEFT", "RIGHT":
			delta := 1
			if button == "LEFT" {
				delta = -1
			}
			if u.moveSelection(list, delta) {
				if v, ok := u.selectedView(list); ok {
					u.ctrl.Lock(v.Channel)
				}
			}
		case "UP":
			u.audio = !u.audio
		case "A":
			u.mark(s)
		}
	}
	return false
}

// cycleTab moves through the tabs 2.4 GHz -> 5 GHz -> BT. Wi-Fi tabs retune the
// sweep; the BT tab leaves it alone.
func (u *ui) cycleTab(delta int) {
	cur := int(u.band)
	if u.screen == screenBT {
		cur = 2
	}
	next := (cur + delta + 3) % 3
	if next == 2 {
		u.setBTLevel(btLevelBrands)
		return
	}
	u.screen, u.band = screenOverview, Band(next)
	u.ctrl.SetBand(u.band)
}

func (u *ui) moveSelection(list []ChannelView, delta int) bool {
	if len(list) == 0 {
		return false
	}
	i := clampIndex(u.selected[u.band], len(list))
	for next := i + delta; next >= 0 && next < len(list); next += delta {
		if !list[next].Skipped {
			u.selected[u.band] = next
			return true
		}
	}
	return false
}

func (u *ui) selectedView(list []ChannelView) (ChannelView, bool) {
	if len(list) == 0 {
		return ChannelView{}, false
	}
	return list[clampIndex(u.selected[u.band], len(list))], true
}

func clampIndex(i, n int) int {
	if i < 0 {
		return 0
	}
	if i >= n {
		return n - 1
	}
	return i
}

func (u *ui) mark(s Snapshot) {
	if s.Lock == nil || u.marks == nil {
		return
	}
	now := u.now()
	n, err := u.marks.AddMark(Mark{At: now, Channel: s.Lock.Channel, Score: s.Lock.Score, Likely: s.Lock.Likely})
	if err != nil {
		u.showToast("MARK NOT SAVED: LOG PAUSED", now)
		return
	}
	u.showToast(fmt.Sprintf("MARK %d @ %s - SCORE %d", n, now.Format("15:04"), s.Lock.Score), now)
}

func (u *ui) showToast(text string, now time.Time) {
	u.toast, u.toastUntil = text, now.Add(toastHold)
}

func (u *ui) TickInterval(s Snapshot) time.Duration {
	if u.screen == screenBTTrack {
		t := s.BTTrack
		if !u.audio || t == nil || t.Lost || t.RSSI <= -100 {
			return 0
		}
		return TickInterval(btTickScore(t.RSSI))
	}
	if u.screen != screenLock || !u.audio || s.Lock == nil || !s.Lock.Measured {
		return 0
	}
	return TickInterval(s.Lock.Score)
}

// TickInterval maps score to the lock-on tick period: off below 20, 2 s at 20,
// 0.3 s at 100.
func TickInterval(score int) time.Duration {
	if score < 20 {
		return 0
	}
	if score > 100 {
		score = 100
	}
	return time.Duration(2000-(score-20)*1700/80) * time.Millisecond
}

func (u *ui) Render(s Snapshot, now time.Time) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, screenWidth, screenHeight))
	fill(img, img.Bounds(), black)
	switch u.screen {
	case screenProbe:
		u.renderProbe(img, now)
	case screenOverview:
		u.renderOverview(img, s, now)
	case screenLock:
		u.renderLock(img, s, now)
	case screenFatal:
		u.renderFatal(img, now)
	case screenBT:
		u.renderBT(img, s, now)
	case screenBTTrack:
		u.renderBTTrack(img, s, now)
	}
	if u.toast != "" {
		fill(img, image.Rect(6, 172, 474, 196), black)
		stroke(img, image.Rect(6, 172, 474, 196), 1, yellow)
		drawTextBox(img, image.Rect(8, 174, 472, 194), 12, 176, trimCells(u.toast, 56), yellow, true, 1)
	} else if s.RadioError != "" && (u.screen == screenOverview || u.screen == screenLock) {
		fill(img, image.Rect(6, 172, 474, 196), black)
		stroke(img, image.Rect(6, 172, 474, 196), 1, red)
		drawTextBox(img, image.Rect(8, 174, 472, 194), 12, 176, trimCells("RADIO ERROR: "+s.RadioError, 56), red, true, 1)
	}
	return img
}

func renderTitle(img *image.RGBA, title string, maxX int) {
	drawTextBox(img, image.Rect(6, 3, maxX, 20), 6, 3, trimCells(title, (maxX-6)/textCellWidth), yellow, true, 1)
	hLine(img, 4, 476, 21, cyan2)
}

func renderClock(img *image.RGBA, now time.Time, paused bool) {
	if paused {
		drawTextRightBox(img, image.Rect(394, 3, 474, 20), 3, "LOG PAUSED", red, true)
		return
	}
	drawTextRightBox(img, image.Rect(400, 3, 474, 20), 3, now.Format("15:04"), cyan, true)
}

type hint struct{ key, label string }

// renderFooter keeps B on the left and A on the right, like the physical buttons.
func renderFooter(img *image.RGBA, left hint, mid1, mid2 string, right hint) {
	hLine(img, 4, 476, 200, cyan2)
	drawButtonHint(img, 6, 204, left.key, left.label, white)
	if mid1 != "" {
		drawText(img, 130, 204, mid1, yellow, true, 1)
	}
	if mid2 != "" {
		drawText(img, 250, 204, mid2, yellow, true, 1)
	}
	if right.key != "" {
		drawButtonHint(img, 474-(23+textPixelWidth(right.label, 1)), 204, right.key, right.label, white)
	}
}

func scoreColor(score int) color.RGBA {
	switch {
	case score >= 70:
		return red
	case score >= 40:
		return amber
	default:
		return green
	}
}

func likelyColor(cause string) color.RGBA {
	switch cause {
	case CauseClean:
		return green
	case CauseInterference:
		return red
	default:
		return amber
	}
}

func signalColor(dbm int) color.RGBA {
	switch {
	case dbm > -60:
		return green
	case dbm > -75:
		return amber
	default:
		return red
	}
}

func levelColor(v, amberAt, redAt float64) color.RGBA {
	switch {
	case v >= redAt:
		return red
	case v >= amberAt:
		return amber
	default:
		return green
	}
}

func fmtPct(has bool, v float64) string {
	if !has {
		return "N/A"
	}
	return fmt.Sprintf("%.0f%%", v)
}

func airtimeColor(m Metrics) color.RGBA {
	if !m.HasAirtime {
		return dim
	}
	return levelColor(m.AirtimePct, 30, 50)
}

func retryColor(m Metrics) color.RGBA {
	if !m.HasRetry {
		return dim
	}
	return levelColor(m.RetryPct, 10, 25)
}

func (u *ui) renderProbe(img *image.RGBA, now time.Time) {
	renderTitle(img, "RF-BUDDY", 240)
	renderClock(img, now, false)
	if !u.probed {
		drawCentered(img, 90, "CHECKING RADIO...", cyan, true)
		drawCentered(img, 112, "RECON STAYS ON", dim, true)
	} else {
		rows := []struct {
			label string
			ok    bool
		}{{"FRAME CAPTURE", u.caps.Capture}, {"CHANNEL LOCK", u.caps.Tune}, {"BLUETOOTH", u.caps.Bluetooth}}
		y := 34
		for _, r := range rows {
			drawText(img, 30, y, r.label, white, true, 1)
			status, c := "OK", green
			if !r.ok {
				status, c = "N/A", amber
			}
			drawText(img, 300, y, status, c, true, 1)
			y += 22
		}
		drawTextBox(img, image.Rect(6, 110, 476, 196), 30, 118, trimCells("RECON STAYS ON; LOCKED TO ONE CHANNEL AT A TIME", 55), cyan, true, 1)
	}
	hLine(img, 4, 476, 200, cyan2)
	drawButtonHint(img, 6, 204, "B", "EXIT", white)
}

func (u *ui) renderFatal(img *image.RGBA, now time.Time) {
	renderTitle(img, "RF-BUDDY", 240)
	renderClock(img, now, false)
	drawCentered(img, 40, "CANNOT START RF-BUDDY", red, true)
	for i, line := range wrapCells(u.caps.FatalReason, 56, 6) {
		drawCentered(img, 70+i*18, line, white, true)
	}
	hLine(img, 4, 476, 200, cyan2)
	drawButtonHint(img, 6, 204, "B", "EXIT", white)
}

// renderTabs draws the three header tabs; the active one is yellow-filled.
func renderTabs(img *image.RGBA, active int) {
	for i, t := range []struct {
		x     int
		label string
	}{{130, Band24.Label()}, {200, Band5.Label()}, {254, "BT"}} {
		if i == active {
			fill(img, image.Rect(t.x, 3, t.x+textPixelWidth(t.label, 1)+6, 19), yellow)
			drawText(img, t.x+3, 3, t.label, black, true, 1)
		} else {
			drawText(img, t.x+3, 3, t.label, dim, true, 1)
		}
	}
}

func (u *ui) renderOverview(img *image.RGBA, s Snapshot, now time.Time) {
	renderTitle(img, "RF-BUDDY", 120)
	renderTabs(img, int(u.band))
	bt := "BT N/A"
	if s.HasBT {
		bt = fmt.Sprintf("BT %d", s.BTCount)
	}
	drawTextBox(img, image.Rect(290, 3, 392, 20), 290, 3, trimCells(bt, 12), cyan, true, 1)
	renderClock(img, now, s.LogPaused)

	list := s.Channels(u.band)
	sel := clampIndex(u.selected[u.band], len(list))
	drawText(img, 6, 24, "AIRTIME %", dim, true, 1)
	const barsTop, barsBottom = 44, 150
	hLine(img, 6, 254, barsBottom, dim)
	if len(list) == 0 {
		drawText(img, 6, 90, "NO CHANNELS YET", dim, true, 1)
	} else {
		slot := 248 / len(list)
		for i, v := range list {
			x0 := 6 + i*slot
			x1 := x0 + max(1, slot-3)
			if v.Skipped || !v.Measured {
				hLine(img, x0, x1, barsBottom-2, dim)
			} else {
				value := int(math.Round(v.Metrics.AirtimePct))
				h := max(1, (barsBottom-barsTop)*min(100, max(0, value))/100)
				fill(img, image.Rect(x0, barsBottom-h, x1, barsBottom), scoreColor(v.Score))
			}
			if i == sel {
				stroke(img, image.Rect(x0-2, barsTop-4, x1+2, barsBottom+2), 1, yellow)
			}
			num := strconv.Itoa(v.Channel.Number)
			if slot >= textPixelWidth(num, 1) || i == sel {
				c := dim
				if i == sel {
					c = yellow
				}
				cx := (x0+x1)/2 - textPixelWidth(num, 1)/2
				drawTextBox(img, image.Rect(4, 152, 256, 170), cx, 152, num, c, true, 1)
			}
		}
		if worst, best, ok := worstBest(list); ok {
			line := fmt.Sprintf("WORST: CH %d  BEST: CH %d", worst.Channel.Number, best.Channel.Number)
			drawTextBox(img, image.Rect(6, 174, 256, 192), 6, 174, trimCells(line, 31), white, true, 1)
		}
	}
	vLine(img, 260, 24, 198, cyan2)
	if v, ok := u.selectedView(list); ok {
		renderChannelPanel(img, v)
	}
	renderFooter(img, hint{"B", "EXIT"}, "LEFT/RIGHT CH", "UP/DN BAND", hint{"A", "LOCK ON"})
}

func worstBest(list []ChannelView) (worst, best ChannelView, ok bool) {
	for _, v := range list {
		if !v.Measured || v.Skipped {
			continue
		}
		if !ok || v.Score > worst.Score {
			worst = v
		}
		if !ok || v.Score < best.Score {
			best = v
		}
		ok = true
	}
	return worst, best, ok
}

func metricRow(img *image.RGBA, y int, label, value string, c color.RGBA) {
	drawText(img, 266, y, label, white, true, 1)
	drawTextBox(img, image.Rect(346, y, 476, y+16), 346, y, trimCells(value, 16), c, true, 1)
}

func renderChannelPanel(img *image.RGBA, v ChannelView) {
	box := image.Rect(266, 24, 476, 198)
	head := fmt.Sprintf("CH %d", v.Channel.Number)
	drawTextBox(img, box, 266, 26, head, yellow, true, 1)
	drawTextBox(img, box, 266+textPixelWidth(head, 1)+8, 26, fmt.Sprintf("%d MHZ", v.Channel.FreqMHz()), dim, true, 1)
	if v.Skipped {
		drawTextBox(img, box, 266, 60, "CHANNEL UNAVAILABLE", dim, true, 1)
		return
	}
	if !v.Measured {
		drawTextBox(img, box, 266, 60, "MEASURING...", dim, true, 1)
		return
	}
	c := scoreColor(v.Score)
	drawTextBox(img, box, 266, 44, strconv.Itoa(v.Score), c, true, 2)
	drawTextBox(img, box, 324, 52, Level(v.Score), c, true, 1)
	m := v.Metrics
	metricRow(img, 80, "AIRTIME", fmtPct(m.HasAirtime, m.AirtimePct), airtimeColor(m))
	metricRow(img, 96, "RETRY", fmtPct(m.HasRetry, m.RetryPct), retryColor(m))
	metricRow(img, 112, "APS", fmt.Sprintf("%d (+%d OVERLAP)", m.CoChannelAPs, m.OverlapAPs), cyan)
	metricRow(img, 128, "FRAMES/S", fmt.Sprintf("%.0f", m.FramesPerSec), cyan)
	drawTextBox(img, box, 266, 150, "LIKELY:", dim, true, 1)
	drawTextBox(img, box, 266, 166, trimCells(v.Likely, 26), likelyColor(v.Likely), true, 1)
}

func (u *ui) renderLock(img *image.RGBA, s Snapshot, now time.Time) {
	l := s.Lock
	if l == nil {
		v, _ := u.selectedView(s.Channels(u.band))
		l = &LockView{ChannelView: v, Trend: TrendSteady}
	}
	ch := l.Channel
	drawTextBox(img, image.Rect(6, 3, 300, 20), 6, 3, trimCells(fmt.Sprintf("LOCKED: CH %d - %s", ch.Number, ch.Band.Label()), 36), yellow, true, 1)
	if u.audio {
		drawTextBox(img, image.Rect(300, 3, 390, 20), 300, 3, "AUDIO ON", cyan, true, 1)
	} else {
		drawTextBox(img, image.Rect(300, 3, 390, 20), 300, 3, "AUDIO OFF", dim, true, 1)
	}
	renderClock(img, now, s.LogPaused)
	hLine(img, 4, 476, 21, cyan2)

	c := dim
	score, level := "--", "--"
	if l.Measured {
		c = scoreColor(l.Score)
		score, level = strconv.Itoa(l.Score), Level(l.Score)
	}
	stroke(img, image.Rect(6, 26, 132, 196), 1, c)
	drawTextBox(img, image.Rect(7, 27, 131, 100), 69-textPixelWidth(score, 4)/2, 32, score, c, true, 4)
	drawCenteredIn(img, 7, 131, 100, level, c)
	trend, tc := "- STEADY", white
	switch l.Trend {
	case TrendRising:
		trend, tc = "^ RISING", red
	case TrendFalling:
		trend, tc = "v FALLING", green
	}
	drawCenteredIn(img, 7, 131, 120, trend, tc)
	peakAt := "--"
	if !l.PeakAt.IsZero() {
		peakAt = "@" + l.PeakAt.Format("15:04")
	}
	drawCenteredIn(img, 7, 131, 146, fmt.Sprintf("PEAK %d", l.Peak), dim)
	drawCenteredIn(img, 7, 131, 164, peakAt, dim)

	m := l.Metrics
	inline := func(x int, label, value string, vc color.RGBA) {
		drawText(img, x, 26, label, white, true, 1)
		vx := x + textPixelWidth(label, 1) + 8
		drawTextBox(img, image.Rect(vx, 26, min(x+110, 476), 42), vx, 26, value, vc, true, 1)
	}
	inline(142, "AIR", fmtPct(m.HasAirtime, m.AirtimePct), airtimeColor(m))
	inline(252, "RETRY", fmtPct(m.HasRetry, m.RetryPct), retryColor(m))
	inline(370, "FR/S", fmt.Sprintf("%.0f", m.FramesPerSec), cyan)

	drawText(img, 142, 44, "LAST 60 S", dim, true, 1)
	vLine(img, 142, 62, 111, dim)
	hLine(img, 142, 474, 110, dim)
	h := l.History
	point := func(i int) (int, int) {
		return 143 + i*330/(lockHistoryLen-1), 109 - min(100, max(0, h[i]))*46/100
	}
	for i := range h {
		x, y := point(i)
		if i == 0 {
			img.SetRGBA(x, y, scoreColor(h[i]))
			continue
		}
		px, py := point(i - 1)
		drawLine(img, px, py, x, y, scoreColor(h[i]))
	}

	drawTextBox(img, image.Rect(142, 114, 476, 130), 142, 114, trimCells(fmt.Sprintf("STRONGEST ON CH %d", ch.Number), 41), dim, true, 1)
	if len(l.Top) == 0 {
		drawText(img, 142, 132, "NO TRANSMITTERS HEARD", dim, true, 1)
	}
	for i, t := range l.Top {
		if i >= 2 {
			break
		}
		y := 132 + i*16
		name := t.SSID
		if name == "" {
			name = t.Addr
		}
		drawTextBox(img, image.Rect(142, y, 420, y+16), 142, y, trimCells(name, 34), white, true, 1)
		drawTextRightBox(img, image.Rect(420, y, 474, y+16), y, strconv.Itoa(t.SignalDBm), signalColor(t.SignalDBm), true)
	}
	drawText(img, 142, 170, "BT/BLE NEARBY", white, true, 1)
	bt := "N/A"
	if s.HasBT {
		bt = fmt.Sprintf("%d DEV", s.BTCount)
	}
	drawTextRightBox(img, image.Rect(300, 170, 474, 186), 170, bt, cyan, true)
	renderFooter(img, hint{"B", "BACK"}, "LEFT/RIGHT CH", "UP AUDIO", hint{"A", "MARK SPOT"})
}
