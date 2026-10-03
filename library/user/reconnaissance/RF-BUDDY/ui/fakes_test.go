package main

import (
	"context"
	"errors"
	"sync"
	"time"
)

type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{t: time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)}
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

// fakeRadio simulates wlan1mon. Capture replays the frames configured for the
// current channel and advances the fake clock by the dwell.
type fakeRadio struct {
	mu         sync.Mutex
	clock      *fakeClock
	current    Channel
	attempts   map[Channel]int
	failTune   map[Channel]bool
	frames     map[Channel][]Frame
	captureErr error
	// captureFailures > 0 limits captureErr to the first N Capture calls.
	captureFailures int
	captureCalls    int
	reportFreq      int
	recon           []AP
	reconN          int
	releaseN        int
}

func newFakeRadio(clock *fakeClock) *fakeRadio {
	return &fakeRadio{clock: clock, attempts: map[Channel]int{}, failTune: map[Channel]bool{}, frames: map[Channel][]Frame{}}
}

func (r *fakeRadio) setFrames(ch Channel, frames []Frame) {
	r.mu.Lock()
	r.frames[ch] = frames
	r.mu.Unlock()
}

func (r *fakeRadio) attemptCount(ch Channel) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.attempts[ch]
}

func (r *fakeRadio) reconCalls() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.reconN
}

func (r *fakeRadio) released() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.releaseN
}

func (r *fakeRadio) Tune(_ context.Context, ch Channel) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.attempts[ch]++
	if r.failTune[ch] {
		return errors.New("channel did not lock")
	}
	r.current = ch
	return nil
}

func (r *fakeRadio) Release(context.Context) error {
	r.mu.Lock()
	r.releaseN++
	r.mu.Unlock()
	return nil
}

func (r *fakeRadio) CurrentFreq(context.Context) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.reportFreq != 0 {
		return r.reportFreq, nil
	}
	return r.current.FreqMHz(), nil
}

func (r *fakeRadio) Capture(_ context.Context, d time.Duration, fn func(Frame)) error {
	r.mu.Lock()
	err := r.captureErr
	r.captureCalls++
	if r.captureFailures > 0 && r.captureCalls > r.captureFailures {
		err = nil
	}
	frames := append([]Frame(nil), r.frames[r.current]...)
	r.mu.Unlock()
	if err != nil {
		return err
	}
	for _, f := range frames {
		fn(f)
	}
	if r.clock != nil {
		r.clock.Advance(d)
	}
	return nil
}

func (r *fakeRadio) ReconAPs(context.Context) ([]AP, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.reconN++
	return append([]AP(nil), r.recon...), nil
}

type recordingSink struct {
	mu      sync.Mutex
	samples []Sample
	paused  bool
}

func (s *recordingSink) WriteSample(x Sample) {
	s.mu.Lock()
	s.samples = append(s.samples, x)
	s.mu.Unlock()
}

func (s *recordingSink) Paused() bool { return s.paused }
