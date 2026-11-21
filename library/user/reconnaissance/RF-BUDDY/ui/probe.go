package main

import (
	"context"
	"fmt"
	"time"
)

// Capabilities records what RF-BUDDY can measure on this Pager.
type Capabilities struct {
	Tune        bool
	Capture     bool
	Bluetooth   bool
	FatalReason string
}

func (c Capabilities) Fatal() bool { return c.FatalReason != "" }

// Unavailable lists the metrics that will show N/A.
func (c Capabilities) Unavailable() []string {
	if !c.Bluetooth {
		return []string{"BT"}
	}
	return nil
}

type ProbeDeps struct {
	Radio         Radio
	Bluetooth     func() bool
	Settle        time.Duration
	CaptureWindow time.Duration
}

var probeChannel = Channel{Band: Band24, Number: 6}

// Probe locks channel 6, confirms frames can be captured, then confirms the
// channel stayed put. Capture and the channel lock are required; Bluetooth is
// optional.
func Probe(ctx context.Context, d ProbeDeps) Capabilities {
	var c Capabilities
	if err := d.Radio.Tune(ctx, probeChannel); err != nil {
		c.FatalReason = fmt.Sprintf("WLAN1MON CANNOT LOCK TO A CHANNEL (%v)", err)
		return c
	}
	c.Tune = true
	var err error
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			sleepCtx(ctx, 200*time.Millisecond)
		}
		if err = d.Radio.Capture(ctx, d.CaptureWindow, func(Frame) {}); err == nil {
			break
		}
	}
	if err != nil {
		c.FatalReason = fmt.Sprintf("CANNOT CAPTURE FRAMES ON WLAN1MON (%v)", err)
		return c
	}
	c.Capture = true
	sleepCtx(ctx, d.Settle)
	if freq, err := d.Radio.CurrentFreq(ctx); err == nil && freq != probeChannel.FreqMHz() {
		c.FatalReason = "SOMETHING ELSE IS MOVING WLAN1MON OFF THE LOCKED CHANNEL. CLOSE OTHER RECON PAYLOADS, THEN RELAUNCH RF-BUDDY."
		return c
	}
	if d.Bluetooth != nil {
		c.Bluetooth = d.Bluetooth()
	}
	return c
}
