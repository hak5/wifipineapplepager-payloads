package main

import (
	"context"
	"errors"
	"math"
	"testing"
	"time"
)

const testDwell = 100 * time.Millisecond

func newTestEngine(r *fakeRadio, clock *fakeClock, sink SampleSink, office string) *Engine {
	cfg := DefaultEngineConfig()
	cfg.Dwell = testDwell
	cfg.OfficeSSID = office
	cfg.RetryBackoff = time.Millisecond
	e := NewEngine(cfg, r, NewInventory(nil), NewBLETracker(30*time.Second), sink, clock.Now)
	e.SetCapabilities(Capabilities{Tune: true, Capture: true})
	return e
}

func steps(e *Engine, n int) {
	for i := 0; i < n; i++ {
		e.Step(context.Background())
	}
}

// framesFor builds n frames of 120 us airtime each (75 bytes at 6 Mb/s),
// the first `retries` of them with the retry bit set.
func framesFor(n, retries int) []Frame {
	out := make([]Frame, n)
	for i := range out {
		out[i] = Frame{TA: "AA:00:00:00:00:02", SignalDBm: -65, HasSignal: true, Length: 75, RateKbps: 6000, Retry: i < retries}
	}
	return out
}

func TestEngineSweepMeasuresEvery24GHzChannel(t *testing.T) {
	clock := newFakeClock()
	r := newFakeRadio(clock)
	ch6 := Channel{Band24, 6}
	r.setFrames(ch6, framesFor(10, 5)) // 1.2 % airtime, 50 % retry
	e := newTestEngine(r, clock, nil, "")
	steps(e, 11)
	s := e.Snapshot()
	for _, v := range s.Channels24 {
		if !v.Measured {
			t.Fatalf("channel %d not measured", v.Channel.Number)
		}
	}
	m := s.Channels24[5].Metrics
	if math.Abs(m.AirtimePct-1.2) > 0.001 || !m.HasRetry || m.RetryPct != 50 || math.Abs(m.FramesPerSec-100) > 0.001 {
		t.Fatalf("ch6 metrics = %+v", m)
	}
	if s.Channels24[5].Likely != CauseInterference {
		t.Fatalf("ch6 likely = %s", s.Channels24[5].Likely)
	}
}

func TestEngineRefreshesInventoryFromRecon(t *testing.T) {
	clock := newFakeClock()
	r := newFakeRadio(clock)
	r.recon = []AP{{BSSID: "AA:00:00:00:00:06", SSID: "OfficeNet", Channel: Channel{Band24, 6}, SignalDBm: -50}}
	e := newTestEngine(r, clock, nil, "")
	steps(e, 6)
	if r.reconCalls() != 1 {
		t.Fatalf("recon calls = %d, want 1 at start", r.reconCalls())
	}
	if got := e.Snapshot().Channels24[5].Metrics.CoChannelAPs; got != 1 {
		t.Fatalf("ch6 co-channel APs = %d, want 1 from Recon", got)
	}
	clock.Advance(31 * time.Second)
	steps(e, 1)
	if r.reconCalls() != 2 {
		t.Fatalf("recon calls = %d, want a refresh after 30 s", r.reconCalls())
	}
}

func TestEngineSkipsChannelThatFailsToTune(t *testing.T) {
	clock := newFakeClock()
	r := newFakeRadio(clock)
	ch11 := Channel{Band24, 11}
	r.failTune[ch11] = true
	e := newTestEngine(r, clock, nil, "")
	steps(e, 11) // cycle 1: first failure
	if e.Snapshot().Channels24[10].Skipped {
		t.Fatal("channel 11 must not be skipped after one failure")
	}
	for r.attemptCount(ch11) < 3 {
		steps(e, 1)
	}
	if !e.Snapshot().Channels24[10].Skipped {
		t.Fatal("channel 11 must be skipped after three consecutive failures")
	}
	steps(e, 40) // finish cycle 3 and run all of cycle 4
	if got := r.attemptCount(ch11); got != 3 {
		t.Fatalf("channel 11 tune attempts = %d, want 3 (skipped afterwards)", got)
	}
}

func TestEngineRetriesSkippedChannelsWhenAllFail(t *testing.T) {
	clock := newFakeClock()
	r := newFakeRadio(clock)
	all := Channels24()
	for _, n := range default5GHz {
		all = append(all, Channel{Band5, n})
	}
	for _, ch := range all {
		r.failTune[ch] = true
	}
	e := newTestEngine(r, clock, nil, "")
	backoff := 20 * time.Millisecond
	e.cfg.RetryBackoff = backoff
	ch1 := Channel{Band24, 1}
	steps(e, 11+11+len(all)) // cycles 1-3: every channel reaches three failures
	if got := r.attemptCount(ch1); got != 3 {
		t.Fatalf("channel 1 attempts = %d, want 3", got)
	}
	start := time.Now()
	steps(e, 1) // plan is empty: clear skips and back off
	if took := time.Since(start); took < backoff {
		t.Fatalf("empty plan step took %v, want >= %v", took, backoff)
	}
	steps(e, 1)
	if got := r.attemptCount(ch1); got <= 3 {
		t.Fatalf("channel 1 attempts = %d, want a retry after the skips were cleared", got)
	}
}

func TestEngineSweepsOtherBandEveryThirdCycle(t *testing.T) {
	clock := newFakeClock()
	r := newFakeRadio(clock)
	ch36 := Channel{Band5, 36}
	r.recon = []AP{{BSSID: "AA:00:00:00:00:36", Channel: ch36, SignalDBm: -60}}
	e := newTestEngine(r, clock, nil, "")
	steps(e, 22)
	if got := r.attemptCount(ch36); got != 0 {
		t.Fatalf("5 GHz swept during cycles 1-2: %d", got)
	}
	steps(e, 12)
	if got := r.attemptCount(ch36); got != 1 {
		t.Fatalf("5 GHz attempts after cycle 3 = %d, want 1", got)
	}
}

func TestEngineLockTracksPeakHistoryAndTrend(t *testing.T) {
	clock := newFakeClock()
	r := newFakeRadio(clock)
	ch := Channel{Band24, 6}
	e := newTestEngine(r, clock, nil, "")
	e.Lock(ch)
	busy := make([]Frame, 50)
	for i := range busy {
		busy[i] = Frame{Length: 7500, RateKbps: 6000} // 10.02 ms each -> ~50 % of 1 s
	}
	for i := 0; i < 10; i++ {
		if i < 5 {
			r.setFrames(ch, nil)
		} else {
			r.setFrames(ch, busy)
		}
		e.Step(context.Background())
	}
	l := e.Snapshot().Lock
	if l == nil || l.Channel != ch || len(l.History) != 10 || l.Trend != TrendRising {
		t.Fatalf("lock = %+v", l)
	}
	if l.Peak != l.Raw || l.Score >= l.Peak {
		t.Fatalf("peak %d raw %d smoothed %d: peak must track raw and smoothing must lag", l.Peak, l.Raw, l.Score)
	}
	for c, n := range r.attempts {
		if c != ch && n > 0 {
			t.Fatalf("lock-on tuned another channel: %+v", c)
		}
	}
	e.Unlock()
	if e.Snapshot().Lock != nil {
		t.Fatal("unlock must clear the lock view")
	}
}

func TestEngineObservesBeaconsAndOfficeCoverage(t *testing.T) {
	clock := newFakeClock()
	r := newFakeRadio(clock)
	ch6 := Channel{Band24, 6}
	frames := append([]Frame{{Beacon: true, TA: "AA:00:00:00:00:01", SSID: "OfficeNet", BeaconChannel: 6, SignalDBm: -50, HasSignal: true, Length: 75, RateKbps: 6000}}, framesFor(9, 0)...)
	r.setFrames(ch6, frames)
	e := newTestEngine(r, clock, nil, "OfficeNet")
	steps(e, 6)
	s := e.Snapshot()
	v := s.Channels24[5]
	if v.Metrics.CoChannelAPs != 1 || !v.Metrics.OfficeHeard || v.Metrics.OfficeSignalDBm != -50 {
		t.Fatalf("metrics = %+v", v.Metrics)
	}
	if len(v.Top) == 0 || v.Top[0].SSID != "OfficeNet" {
		t.Fatalf("top = %+v", v.Top)
	}
	if s.Channels24[0].Likely != CauseWeak {
		t.Fatalf("ch1 measured before the office beacon was heard: likely %s, want WEAK COVERAGE", s.Channels24[0].Likely)
	}
}

func TestEngineWritesOneSamplePerMeasurementAndReportsPaused(t *testing.T) {
	clock := newFakeClock()
	r := newFakeRadio(clock)
	sink := &recordingSink{paused: true}
	e := newTestEngine(r, clock, sink, "")
	steps(e, 3)
	if len(sink.samples) != 3 || sink.samples[0].Mode != ModeOverview || sink.samples[2].Channel.Number != 3 {
		t.Fatalf("samples = %+v", sink.samples)
	}
	if !e.Snapshot().LogPaused {
		t.Fatal("snapshot must surface paused logging")
	}
}

func TestEngineCaptureErrorLeavesChannelUnmeasured(t *testing.T) {
	clock := newFakeClock()
	r := newFakeRadio(clock)
	r.captureErr = errors.New("recvfrom: network is down")
	e := newTestEngine(r, clock, nil, "")
	steps(e, 1)
	if v := e.Snapshot().Channels24[0]; v.Measured || v.Skipped {
		t.Fatalf("view = %+v", v)
	}
}

func TestEngineCaptureErrorBacksOffAndSurfacesError(t *testing.T) {
	clock := newFakeClock()
	r := newFakeRadio(clock)
	r.captureErr = errors.New("recvfrom: network is down")
	e := newTestEngine(r, clock, nil, "")
	e.cfg.RetryBackoff = 30 * time.Millisecond
	start := time.Now()
	steps(e, 1)
	if el := time.Since(start); el < 30*time.Millisecond {
		t.Fatalf("Step returned after %v, want >= 30ms backoff", el)
	}
	if got := e.Snapshot().RadioError; got != "FRAME CAPTURE FAILED" {
		t.Fatalf("RadioError = %q", got)
	}
	r.captureErr = nil
	steps(e, 1)
	if got := e.Snapshot().RadioError; got != "" {
		t.Fatalf("RadioError after recovery = %q", got)
	}
}

func TestEngineLockedChannelTuneFailureBacksOffWithoutSkipping(t *testing.T) {
	clock := newFakeClock()
	r := newFakeRadio(clock)
	ch := Channel{Band24, 6}
	r.failTune[ch] = true
	e := newTestEngine(r, clock, nil, "")
	e.cfg.RetryBackoff = 30 * time.Millisecond
	e.Lock(ch)
	start := time.Now()
	steps(e, 1)
	if el := time.Since(start); el < 30*time.Millisecond {
		t.Fatalf("Step returned after %v, want >= 30ms backoff", el)
	}
	s := e.Snapshot()
	if s.RadioError != "CANNOT LOCK CH 6" {
		t.Fatalf("RadioError = %q", s.RadioError)
	}
	if s.Lock == nil || s.Lock.Skipped {
		t.Fatalf("locked view must not be skipped: %+v", s.Lock)
	}
	steps(e, 1)
	if n := r.attemptCount(ch); n != 2 {
		t.Fatalf("tune attempts = %d, want 2", n)
	}
}

func TestEngineSnapshotCarriesBT(t *testing.T) {
	clock := newFakeClock()
	e := newTestEngine(&fakeRadio{}, clock, nil, "")
	tr := e.ble
	tr.Observe(Advert{Addr: "AA:BB:CC:DD:EE:01", RSSI: -50, Company: -1}, clock.Now())
	tr.Observe(Advert{Addr: "AA:BB:CC:DD:EE:02", RSSI: -70, Company: -1}, clock.Now())

	if s := e.Snapshot(); s.HasBT || s.BT != nil || s.BTTrack != nil {
		t.Fatalf("BT present without capability: %+v", s)
	}
	e.SetCapabilities(Capabilities{Tune: true, Capture: true, Bluetooth: true})
	s := e.Snapshot()
	if !s.HasBT || s.BTCount != 2 || len(s.BT) != 2 || s.BT[0].Addr != "AA:BB:CC:DD:EE:01" || s.BTTrack != nil {
		t.Fatalf("snapshot BT = %+v", s)
	}
	rev := s.Revision
	e.TrackBT("AA:BB:CC:DD:EE:02")
	s = e.Snapshot()
	if s.BTTrack == nil || s.BTTrack.Addr != "AA:BB:CC:DD:EE:02" || s.Revision == rev {
		t.Fatalf("track = %+v rev %d", s.BTTrack, s.Revision)
	}
	e.UntrackBT()
	if s = e.Snapshot(); s.BTTrack != nil {
		t.Fatalf("still tracking: %+v", s.BTTrack)
	}
}
