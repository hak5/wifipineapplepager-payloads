package main

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"time"
)

// Runner executes a command and returns its standard output.
type Runner func(ctx context.Context, name string, args ...string) ([]byte, error)

func execRunner(ctx context.Context, name string, args ...string) ([]byte, error) {
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return exec.CommandContext(cctx, name, args...).Output()
}

// Capturer delivers raw monitor-mode packets for a duration. It never sends.
type Capturer interface {
	Capture(ctx context.Context, d time.Duration, fn func([]byte)) error
	Close() error
}

// failedCapturer stands in when the capture socket could not be opened, so the
// probe reports the real open error instead of a generic one.
type failedCapturer struct{ err error }

func (f failedCapturer) Capture(context.Context, time.Duration, func([]byte)) error {
	return fmt.Errorf("open capture: %w", f.err)
}

func (f failedCapturer) Close() error { return nil }

var errCaptureUnavailable = errors.New("frame capture unavailable")

// Radio is wlan1mon as the engine and probe see it.
type Radio interface {
	Tune(ctx context.Context, ch Channel) error
	Release(ctx context.Context) error
	CurrentFreq(ctx context.Context) (int, error)
	Capture(ctx context.Context, d time.Duration, fn func(Frame)) error
	ReconAPs(ctx context.Context) ([]AP, error)
}

// examineLockSeconds bounds each channel lock so a crashed RF-BUDDY cannot
// leave Recon parked for long.
const examineLockSeconds = "300"

// pagerRadio tunes through PineAP's EXAMINE lock so pineapd, not RF-BUDDY,
// owns the channel and Recon keeps running.
type pagerRadio struct {
	iface  string
	run    Runner
	cap    Capturer
	settle time.Duration
}

func NewPagerRadio(iface string, run Runner, cap Capturer, settle time.Duration) Radio {
	return &pagerRadio{iface: iface, run: run, cap: cap, settle: settle}
}

func (r *pagerRadio) Tune(ctx context.Context, ch Channel) error {
	if _, err := r.run(ctx, "_pineap", "EXAMINE", "CHANNEL", strconv.Itoa(ch.Number), examineLockSeconds); err != nil {
		return fmt.Errorf("examine channel %d: %w", ch.Number, err)
	}
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			sleepCtx(ctx, r.settle)
		}
		if freq, err := r.CurrentFreq(ctx); err == nil && freq == ch.FreqMHz() {
			return nil
		}
	}
	return fmt.Errorf("channel %d did not lock", ch.Number)
}

func (r *pagerRadio) Release(ctx context.Context) error {
	_, err := r.run(ctx, "_pineap", "EXAMINE", "CANCEL")
	return err
}

var iwInfoChannel = regexp.MustCompile(`channel \d+ \((\d+) MHz\)`)

func (r *pagerRadio) CurrentFreq(ctx context.Context) (int, error) {
	out, err := r.run(ctx, "iw", "dev", r.iface, "info")
	if err != nil {
		return 0, fmt.Errorf("iw info: %w", err)
	}
	m := iwInfoChannel.FindStringSubmatch(string(out))
	if m == nil {
		return 0, fmt.Errorf("iw info: no channel line for %s", r.iface)
	}
	return strconv.Atoi(m[1])
}

func (r *pagerRadio) Capture(ctx context.Context, d time.Duration, fn func(Frame)) error {
	if r.cap == nil {
		return errCaptureUnavailable
	}
	return r.cap.Capture(ctx, d, func(pkt []byte) {
		if f, ok := ParseFrame(pkt); ok {
			fn(f)
		}
	})
}

func (r *pagerRadio) ReconAPs(ctx context.Context) ([]AP, error) {
	out, err := r.run(ctx, "_pineap", "RECON", "APS", "format=json")
	if err != nil {
		return nil, fmt.Errorf("recon aps: %w", err)
	}
	return ParseRecon(out)
}

func sleepCtx(ctx context.Context, d time.Duration) {
	if d <= 0 {
		return
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
	case <-ctx.Done():
	}
}
