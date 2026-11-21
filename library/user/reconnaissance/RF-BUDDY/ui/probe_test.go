package main

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func probeWith(r *fakeRadio, bt bool) Capabilities {
	return Probe(context.Background(), ProbeDeps{Radio: r, Bluetooth: func() bool { return bt }})
}

func TestProbeAllCapabilities(t *testing.T) {
	c := probeWith(newFakeRadio(nil), true)
	if c.Fatal() || !c.Tune || !c.Capture || !c.Bluetooth || len(c.Unavailable()) != 0 {
		t.Fatalf("caps = %+v unavailable = %v", c, c.Unavailable())
	}
}

func TestProbeWithoutBluetooth(t *testing.T) {
	c := probeWith(newFakeRadio(nil), false)
	if c.Fatal() || c.Bluetooth || strings.Join(c.Unavailable(), ",") != "BT" {
		t.Fatalf("caps = %+v unavailable = %v", c, c.Unavailable())
	}
}

func TestProbeFatalWhenTuneFails(t *testing.T) {
	r := newFakeRadio(nil)
	r.failTune[probeChannel] = true
	if c := probeWith(r, true); !c.Fatal() || !strings.Contains(c.FatalReason, "CANNOT LOCK") {
		t.Fatalf("caps = %+v", c)
	}
}

func TestProbeFatalWhenCaptureFails(t *testing.T) {
	r := newFakeRadio(nil)
	r.captureErr = errors.New("socket: operation not permitted")
	if c := probeWith(r, true); !c.Fatal() || !strings.Contains(c.FatalReason, "CANNOT CAPTURE") {
		t.Fatalf("caps = %+v", c)
	}
}

func TestProbeFatalWhenChannelDrifts(t *testing.T) {
	r := newFakeRadio(nil)
	r.reportFreq = 2412
	if c := probeWith(r, true); !c.Fatal() || !strings.Contains(c.FatalReason, "MOVING WLAN1MON") {
		t.Fatalf("caps = %+v", c)
	}
}

func TestProbeRetriesTransientCaptureFailure(t *testing.T) {
	r := newFakeRadio(nil)
	r.captureErr = errors.New("recvfrom: network is down")
	r.captureFailures = 2
	if c := probeWith(r, true); c.Fatal() || !c.Capture {
		t.Fatalf("caps = %+v", c)
	}
}

func TestProbeFatalAfterThreeCaptureFailures(t *testing.T) {
	r := newFakeRadio(nil)
	r.captureErr = errors.New("recvfrom: network is down")
	r.captureFailures = 3
	c := probeWith(r, true)
	if !c.Fatal() || !strings.Contains(c.FatalReason, "CANNOT CAPTURE FRAMES ON WLAN1MON (recvfrom: network is down)") {
		t.Fatalf("caps = %+v", c)
	}
}
