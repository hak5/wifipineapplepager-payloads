// RF-BUDDY full-screen Pager application.
//
// Locks Recon to one channel at a time, passively measures Wi-Fi airtime,
// retries, AP crowding, and nearby Bluetooth, renders the 480x222 UI to the
// Pager framebuffer and Virtual Pager, and logs a survey session.
package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type options struct {
	framebuffer, inputDevice, readyFile, virtualListen, previewDir string
	iface, btIface, lootDir, tickFile, officeSSID, buzzerDir       string
	dwellMS, logMaxMB, minFreeMB, tickFreqHz, tickVolume           int
	thresholds                                                     Thresholds
}

func parseOptions(args []string) (options, error) {
	fs := flag.NewFlagSet("rf-buddy-ui", flag.ContinueOnError)
	o := options{thresholds: DefaultThresholds()}
	fs.StringVar(&o.framebuffer, "framebuffer", "/dev/fb0", "Pager framebuffer")
	fs.StringVar(&o.inputDevice, "input-device", "/dev/input/event0", "Pager evdev button device")
	fs.StringVar(&o.readyFile, "ready-file", "", "written after the first frame is on screen")
	// USB-management address only: the viewer has no login, so it must not be
	// reachable from Wi-Fi networks the Pager joins.
	fs.StringVar(&o.virtualListen, "virtual-listen", "172.16.52.1:1474", "viewer listen address (USB management network only)")
	fs.StringVar(&o.previewDir, "preview-dir", "", "render preview PNGs and exit")
	fs.StringVar(&o.iface, "iface", "wlan1mon", "monitor interface")
	fs.StringVar(&o.btIface, "bt-iface", "hci0", "Bluetooth adapter")
	fs.StringVar(&o.lootDir, "loot-dir", "/root/loot/rf_buddy", "session log root")
	fs.StringVar(&o.tickFile, "tick-file", "", "deprecated no-op; the lock-on tick is now played by the buzzer ticker")
	fs.StringVar(&o.buzzerDir, "buzzer-dir", "/sys/class/leds/buzzer", "buzzer sysfs directory")
	fs.IntVar(&o.tickFreqHz, "tick-freq-hz", 2000, "lock-on tick tone frequency")
	fs.IntVar(&o.tickVolume, "tick-volume", 60, "lock-on tick volume (0-100)")
	fs.StringVar(&o.officeSSID, "office-ssid", "", "office SSID for WEAK COVERAGE")
	fs.IntVar(&o.dwellMS, "dwell-ms", 250, "overview dwell per channel")
	fs.IntVar(&o.logMaxMB, "log-max-mb", 20, "per-session log cap")
	fs.IntVar(&o.minFreeMB, "min-free-mb", 64, "pause logging below this free space")
	fs.Float64Var(&o.thresholds.RetryHighPct, "retry-high-pct", o.thresholds.RetryHighPct, "retry % for INTERFERENCE")
	fs.Float64Var(&o.thresholds.AirtimeHighPct, "airtime-high-pct", o.thresholds.AirtimeHighPct, "airtime % for CONGESTION")
	fs.IntVar(&o.thresholds.OverlapMinDBm, "overlap-min-dbm", o.thresholds.OverlapMinDBm, "neighbour AP signal for CHANNEL OVERLAP")
	fs.IntVar(&o.thresholds.BTDenseCount, "bt-dense-count", o.thresholds.BTDenseCount, "BLE devices for BT DENSE")
	fs.IntVar(&o.thresholds.WeakSignalDBm, "weak-signal-dbm", o.thresholds.WeakSignalDBm, "office AP below this is WEAK COVERAGE")
	if err := fs.Parse(args); err != nil {
		return o, err
	}
	if o.dwellMS < 50 {
		return o, errors.New("dwell-ms must be at least 50")
	}
	return o, nil
}

// ensurePath gives the process a default PATH when the payload runner starts
// it with none, so exec lookups of iw, hcitool and friends still resolve.
func ensurePath() {
	if os.Getenv("PATH") == "" {
		_ = os.Setenv("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
	}
}

func main() {
	ensurePath()
	setLocalZone(os.ReadFile)
	o, err := parseOptions(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if o.previewDir != "" {
		if err := renderPreviews(o.previewDir); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if err := run(o); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func sessionText(o options, c Capabilities, started time.Time) string {
	t := o.thresholds
	lines := []string{
		"started: " + started.Format(time.RFC3339),
		"iface: " + o.iface,
		"office_ssid: " + o.officeSSID,
		fmt.Sprintf("dwell_ms: %d", o.dwellMS),
		fmt.Sprintf("retry_high_pct: %.0f", t.RetryHighPct),
		fmt.Sprintf("airtime_high_pct: %.0f", t.AirtimeHighPct),
		fmt.Sprintf("overlap_min_dbm: %d", t.OverlapMinDBm),
		fmt.Sprintf("bt_dense_count: %d", t.BTDenseCount),
		fmt.Sprintf("weak_signal_dbm: %d", t.WeakSignalDBm),
		fmt.Sprintf("capture: %t", c.Capture),
		fmt.Sprintf("channel_lock: %t", c.Tune),
		fmt.Sprintf("bluetooth: %t", c.Bluetooth),
		"unavailable: " + strings.Join(c.Unavailable(), ", "),
		"fatal: " + c.FatalReason,
	}
	return strings.Join(lines, "\n") + "\n"
}

func run(o options) error {
	fb, err := os.OpenFile(o.framebuffer, os.O_RDWR, 0)
	if err != nil {
		return fmt.Errorf("open framebuffer: %w", err)
	}
	defer fb.Close()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer cancel()

	started := time.Now()
	logger, err := OpenLogger(o.lootDir, started, int64(o.logMaxMB)<<20, uint64(o.minFreeMB)<<20, freeBytes, time.Now)
	if err != nil {
		return fmt.Errorf("open survey log: %w", err)
	}
	defer logger.Close()

	var capturer Capturer
	if opened, err := OpenCapturer(o.iface); err != nil {
		capturer = failedCapturer{err: err}
	} else if opened != nil {
		capturer = opened
		defer opened.Close()
	}
	radio := NewPagerRadio(o.iface, execRunner, capturer, 30*time.Millisecond)
	// Always hand the channel back to Recon, even after a fatal probe.
	defer func() { _ = radio.Release(context.Background()) }()

	cfg := DefaultEngineConfig()
	cfg.Dwell = time.Duration(o.dwellMS) * time.Millisecond
	cfg.Thresholds = o.thresholds
	cfg.OfficeSSID = o.officeSSID
	ble := NewBLETracker(30 * time.Second)
	engine := NewEngine(cfg, radio, NewInventory(nil), ble, logger, time.Now)
	view := newUI(engine, logger, time.Now)
	// Registered first among these three so it runs LAST (defers are LIFO):
	// the buzzer must outlive the ticker worker, which Beeps until the workers
	// are joined below, and only then be silenced and restored.
	buzzer, buzzerErr := OpenBuzzer(o.buzzerDir, o.tickFreqHz, o.tickVolume)
	if buzzerErr == nil {
		defer buzzer.Close()
	}
	// Registered after the radio/capturer/logger defers so it runs before them:
	// stop the workers and wait for them to return before releasing the channel
	// and closing the capture socket and logger they use.
	var workers sync.WaitGroup
	defer func() {
		cancel()
		workers.Wait()
	}()

	// Current lock-on tick interval in nanoseconds (0 = off), set by the main loop.
	var tickNS atomic.Int64
	if buzzerErr == nil {
		workers.Add(1)
		go func() {
			defer workers.Done()
			tickLoop(ctx, buzzer, &tickNS)
		}()
	}

	mir := newMirror()
	// A viewer that cannot listen (USB address not up) must not stop the
	// payload; the reason lands in session.txt instead.
	viewerErr := make(chan error, 1)
	var sessionBase, viewerNote string
	// Keep only one unhandled press so double clicks cannot skip a screen.
	buttons := make(chan string, 1)
	if o.virtualListen != "" {
		go func() {
			if err := mir.serve(ctx, o.virtualListen, buttons); err != nil && ctx.Err() == nil {
				viewerErr <- err
			}
		}()
	}
	go func() {
		// Let the A press that confirmed the payload launch finish first.
		timer := time.NewTimer(inputStartupDelay)
		defer timer.Stop()
		select {
		case <-timer.C:
			readButtons(ctx, o.inputDevice, buttons)
		case <-ctx.Done():
		}
	}()

	var displayedPixels, displayedFrame, scratch, frameBuf []byte
	redraw := func() error {
		canvas := view.Render(engine.Snapshot(), time.Now())
		if bytes.Equal(displayedPixels, canvas.Pix) {
			return nil
		}
		displayedPixels = append(displayedPixels[:0], canvas.Pix...)
		frameBuf = canvasToFramebufferInto(frameBuf, canvas)
		if err := writeFramebuffer(fb, frameBuf); err != nil {
			return err
		}
		displayedFrame = append(displayedFrame[:0], frameBuf...)
		mir.publish(canvas)
		return nil
	}
	if err := redraw(); err != nil {
		return err
	}
	if o.readyFile != "" {
		if err := os.WriteFile(o.readyFile, []byte("ready\n"), 0o600); err != nil {
			return fmt.Errorf("write ready file: %w", err)
		}
		defer os.Remove(o.readyFile)
	}

	probeDone := make(chan Capabilities, 1)
	workers.Add(1)
	go func() {
		defer workers.Done()
		probeDone <- Probe(ctx, ProbeDeps{
			Radio: radio, Bluetooth: func() bool { return BluetoothAvailable(o.btIface) },
			Settle: 500 * time.Millisecond, CaptureWindow: 300 * time.Millisecond,
		})
	}()

	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	owner := time.NewTicker(ownershipPollInterval)
	defer owner.Stop()
	minute := time.Now().Minute()
	var btRedrawSec int64
	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-viewerErr:
			viewerNote = "viewer: " + err.Error() + "\n"
			if sessionBase != "" {
				_ = logger.WriteSession(sessionBase + viewerNote)
			}
		case caps := <-probeDone:
			view.SetProbe(caps)
			text := sessionText(o, caps, started)
			if buzzerErr != nil {
				text += "buzzer: " + buzzerErr.Error() + "\n"
			}
			sessionBase = text
			_ = logger.WriteSession(sessionBase + viewerNote)
			if caps.Fatal() {
				// Nothing to measure: hand the channel back right away.
				_ = radio.Release(ctx)
			} else {
				engine.SetCapabilities(caps)
				if caps.Bluetooth {
					scanner := &BLEScanner{Iface: o.btIface, Tracker: ble, Now: time.Now, RestartDelay: 2 * time.Second}
					workers.Add(1)
					go func() {
						defer workers.Done()
						scanner.Run(ctx)
					}()
				}
				workers.Add(1)
				go func() {
					defer workers.Done()
					engine.Run(ctx)
				}()
			}
			if err := redraw(); err != nil {
				return err
			}
		case b := <-buttons:
			if view.HandleButton(b, engine.Snapshot()) {
				return nil
			}
			if err := redraw(); err != nil {
				return err
			}
		case <-engine.Updates():
			tickNS.Store(int64(view.TickInterval(engine.Snapshot())))
			// BT screens show no Wi-Fi sweep data and already refresh once a
			// second; redrawing on every sweep update cost the Pager ~25% CPU.
			if view.LiveBT() {
				continue
			}
			if err := redraw(); err != nil {
				return err
			}
		case now := <-ticker.C:
			changed := view.Advance(now)
			if view.LiveBT() && now.Unix() != btRedrawSec {
				// BT screens refresh once a second even when Wi-Fi publishes nothing.
				btRedrawSec, changed = now.Unix(), true
			}
			tickNS.Store(int64(view.TickInterval(engine.Snapshot())))
			if changed || now.Minute() != minute {
				minute = now.Minute()
				if err := redraw(); err != nil {
					return err
				}
			}
		case <-owner.C:
			// The native payload runner can repaint after launch; reclaim the
			// display only when our frame has been displaced.
			if err := maintainDisplayOwnership(fb, displayedFrame, &scratch); err != nil {
				return err
			}
		}
	}
}

// tickLoop beeps 30 ms every interval while lock-on is active (interval > 0),
// polling every 250 ms when idle, until ctx is cancelled.
func tickLoop(ctx context.Context, b *Buzzer, interval *atomic.Int64) {
	for {
		wait := 250 * time.Millisecond
		if d := time.Duration(interval.Load()); d > 0 {
			b.Beep(30 * time.Millisecond)
			wait = d
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}
