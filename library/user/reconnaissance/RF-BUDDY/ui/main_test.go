package main

import (
	"context"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestParseOptionsDefaults(t *testing.T) {
	o, err := parseOptions(nil)
	if err != nil {
		t.Fatal(err)
	}
	if o.iface != "wlan1mon" || o.btIface != "hci0" || o.lootDir != "/root/loot/rf_buddy" || o.dwellMS != 250 ||
		o.logMaxMB != 20 || o.minFreeMB != 64 || o.virtualListen != "172.16.52.1:1474" || o.thresholds != DefaultThresholds() {
		t.Fatalf("defaults = %+v", o)
	}
}

func TestParseOptionsOverrides(t *testing.T) {
	o, err := parseOptions([]string{"--office-ssid", "OfficeNet", "--dwell-ms", "400", "--bt-dense-count", "12", "--retry-high-pct", "30", "--airtime-high-pct", "60"})
	if err != nil {
		t.Fatal(err)
	}
	if o.officeSSID != "OfficeNet" || o.dwellMS != 400 || o.thresholds.BTDenseCount != 12 || o.thresholds.RetryHighPct != 30 || o.thresholds.AirtimeHighPct != 60 {
		t.Fatalf("overrides = %+v", o)
	}
	if _, err := parseOptions([]string{"--dwell-ms", "10"}); err == nil {
		t.Fatal("dwell below 50 ms must be rejected")
	}
}

func TestParseOptionsBuzzerDefaultsAndLegacyTickFile(t *testing.T) {
	o, err := parseOptions([]string{"--tick-file", "/tmp/x"})
	if err != nil {
		t.Fatal(err)
	}
	if o.buzzerDir != "/sys/class/leds/buzzer" || o.tickFreqHz != 2000 || o.tickVolume != 60 {
		t.Fatalf("buzzer defaults = %+v", o)
	}
}

func TestTickLoopBeepsOnlyWhenActiveAndStops(t *testing.T) {
	dir := fakeBuzzerDir(t)
	b, _ := OpenBuzzer(dir, 2000, 128)
	var iv atomic.Int64
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { tickLoop(ctx, b, &iv); close(done) }()
	time.Sleep(80 * time.Millisecond)
	if readTrim(t, dir, "frequency") != "523" {
		t.Fatal("idle loop must not beep")
	}
	iv.Store(int64(20 * time.Millisecond))
	time.Sleep(400 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("tickLoop did not exit on cancel")
	}
	// Read only after the loop has exited so no write is in flight.
	if readTrim(t, dir, "frequency") != "2000" {
		t.Fatal("active loop must beep")
	}
	if readTrim(t, dir, "brightness") != "0" {
		t.Fatal("buzzer must be silent after the loop exits")
	}
}

func TestSessionTextListsConfigAndCapabilities(t *testing.T) {
	o, _ := parseOptions([]string{"--office-ssid", "OfficeNet"})
	text := sessionText(o, Capabilities{Tune: true, Capture: true}, time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC))
	for _, want := range []string{"started: 2026-10-01T12:00:00Z", "office_ssid: OfficeNet", "capture: true", "bluetooth: false", "unavailable: BT", "retry_high_pct: 25", "airtime_high_pct: 50"} {
		if !strings.Contains(text, want) {
			t.Errorf("session text missing %q:\n%s", want, text)
		}
	}
}

func TestEnsurePathDefaultsOnlyWhenEmpty(t *testing.T) {
	t.Setenv("PATH", "")
	ensurePath()
	if got := os.Getenv("PATH"); got != "/usr/sbin:/usr/bin:/sbin:/bin" {
		t.Fatalf("PATH = %q", got)
	}
	t.Setenv("PATH", "/custom/bin")
	ensurePath()
	if got := os.Getenv("PATH"); got != "/custom/bin" {
		t.Fatalf("non-empty PATH changed to %q", got)
	}
}
