package main

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"
)

type runnerCall struct {
	name string
	args []string
}

// scriptedRunner returns outputs by "name arg arg" key and records calls.
type scriptedRunner struct {
	outputs map[string]string
	errs    map[string]error
	calls   []runnerCall
}

func (s *scriptedRunner) run(_ context.Context, name string, args ...string) ([]byte, error) {
	s.calls = append(s.calls, runnerCall{name, args})
	key := name + " " + strings.Join(args, " ")
	return []byte(s.outputs[key]), s.errs[key]
}

func (s *scriptedRunner) commands() []string {
	var out []string
	for _, c := range s.calls {
		out = append(out, c.name+" "+strings.Join(c.args, " "))
	}
	return out
}

type fakeCapturer struct{ packets [][]byte }

func (f *fakeCapturer) Capture(_ context.Context, _ time.Duration, fn func([]byte)) error {
	for _, p := range f.packets {
		fn(p)
	}
	return nil
}

func (f *fakeCapturer) Close() error { return nil }

func infoFor(ch Channel) string {
	return "Interface wlan1mon\n\ttype monitor\n\tchannel " + strconv.Itoa(ch.Number) + " (" + strconv.Itoa(ch.FreqMHz()) + " MHz), width: 20 MHz (no HT)\n"
}

func TestPagerRadioTuneLocksChannelWithExamine(t *testing.T) {
	ch := Channel{Band5, 149}
	r := &scriptedRunner{outputs: map[string]string{"iw dev wlan1mon info": infoFor(ch)}}
	radio := NewPagerRadio("wlan1mon", r.run, nil, 0)
	if err := radio.Tune(context.Background(), ch); err != nil {
		t.Fatal(err)
	}
	got := strings.Join(r.commands(), "|")
	if got != "_pineap EXAMINE CHANNEL 149 300|iw dev wlan1mon info" {
		t.Fatalf("commands = %s", got)
	}
}

func TestPagerRadioTuneFailsWhenChannelDoesNotLock(t *testing.T) {
	r := &scriptedRunner{outputs: map[string]string{"iw dev wlan1mon info": infoFor(Channel{Band24, 6})}}
	radio := NewPagerRadio("wlan1mon", r.run, nil, 0)
	err := radio.Tune(context.Background(), Channel{Band5, 52})
	if err == nil || !strings.Contains(err.Error(), "did not lock") {
		t.Fatalf("err = %v", err)
	}
}

func TestPagerRadioTuneReportsExamineError(t *testing.T) {
	key := "_pineap EXAMINE CHANNEL 6 300"
	r := &scriptedRunner{errs: map[string]error{key: errors.New("exit status 1")}}
	err := NewPagerRadio("wlan1mon", r.run, nil, 0).Tune(context.Background(), Channel{Band24, 6})
	if err == nil || !strings.Contains(err.Error(), "examine channel 6") {
		t.Fatalf("err = %v", err)
	}
}

func TestPagerRadioReleaseAndCurrentFreq(t *testing.T) {
	r := &scriptedRunner{outputs: map[string]string{"iw dev wlan1mon info": infoFor(Channel{Band24, 6})}}
	radio := NewPagerRadio("wlan1mon", r.run, nil, 0)
	if err := radio.Release(context.Background()); err != nil {
		t.Fatal(err)
	}
	if freq, err := radio.CurrentFreq(context.Background()); err != nil || freq != 2437 {
		t.Fatalf("freq = %d %v", freq, err)
	}
	if r.commands()[0] != "_pineap EXAMINE CANCEL" {
		t.Fatalf("commands = %v", r.commands())
	}
	empty := &scriptedRunner{outputs: map[string]string{"iw dev wlan1mon info": "Interface wlan1mon\n"}}
	if _, err := NewPagerRadio("wlan1mon", empty.run, nil, 0).CurrentFreq(context.Background()); err == nil {
		t.Fatal("missing channel line must error")
	}
}

func TestPagerRadioReconAPs(t *testing.T) {
	r := &scriptedRunner{outputs: map[string]string{"_pineap RECON APS format=json": reconFixture}}
	aps, err := NewPagerRadio("wlan1mon", r.run, nil, 0).ReconAPs(context.Background())
	if err != nil || len(aps) != 3 {
		t.Fatalf("aps = %+v %v", aps, err)
	}
}

func TestPagerRadioCapture(t *testing.T) {
	r := &scriptedRunner{}
	if err := NewPagerRadio("wlan1mon", r.run, nil, 0).Capture(context.Background(), time.Millisecond, func(Frame) {}); !errors.Is(err, errCaptureUnavailable) {
		t.Fatalf("nil capturer err = %v", err)
	}
	cap := &fakeCapturer{packets: [][]byte{radiotapFrame(0, 2, -50, dataFrame(testTA, true)), {0xff}}}
	var frames []Frame
	if err := NewPagerRadio("wlan1mon", r.run, cap, 0).Capture(context.Background(), time.Millisecond, func(f Frame) { frames = append(frames, f) }); err != nil {
		t.Fatal(err)
	}
	if len(frames) != 1 || !frames[0].Retry {
		t.Fatalf("frames = %+v (unparseable packets must be skipped)", frames)
	}
}

func TestOpenCapturerOnHostFailsCleanly(t *testing.T) {
	if _, err := OpenCapturer("rf-buddy-no-such-iface"); err == nil {
		t.Fatal("opening a missing interface must fail")
	}
}

func TestFailedCapturerKeepsOpenError(t *testing.T) {
	radio := NewPagerRadio("wlan1mon", func(context.Context, string, ...string) ([]byte, error) { return nil, nil },
		failedCapturer{errors.New("operation not permitted")}, 0)
	err := radio.Capture(context.Background(), time.Millisecond, func(Frame) {})
	if err == nil || !strings.Contains(err.Error(), "operation not permitted") {
		t.Fatalf("capture error = %v, want the open error", err)
	}
}
