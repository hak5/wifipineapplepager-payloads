package main

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

func TestParseLEScanLine(t *testing.T) {
	if addr, ok := ParseLEScanLine("aa:bb:cc:dd:ee:01 (unknown)"); !ok || addr != "AA:BB:CC:DD:EE:01" {
		t.Fatalf("parse = %q %v", addr, ok)
	}
	for _, bad := range []string{"LE Scan ...", "", "garbage line", "AA:BB:CC:DD:EE (unknown)"} {
		if _, ok := ParseLEScanLine(bad); ok {
			t.Fatalf("parsed %q", bad)
		}
	}
}

func TestBLEScannerConsumesHcitoolOutput(t *testing.T) {
	now := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	s := &BLEScanner{Tracker: NewBLETracker(30 * time.Second), Now: func() time.Time { return now }}
	s.consume(strings.NewReader("LE Scan ...\nAA:BB:CC:DD:EE:01 (unknown)\naa:bb:cc:dd:ee:01 Phone\nAA:BB:CC:DD:EE:02 (unknown)\nnoise\n"))
	if got := s.Tracker.Count(now); got != 2 {
		t.Fatalf("unique devices = %d, want 2", got)
	}
}

func TestLEScanIsPassive(t *testing.T) {
	if got := strings.Join(leScanArgs("hci0"), " "); got != "-i hci0 lescan --passive --duplicates" {
		t.Fatalf("leScanArgs = %q", got)
	}
}

func TestScanDisableArgs(t *testing.T) {
	if got := strings.Join(scanDisableArgs("hci0"), " "); got != "-i hci0 cmd 0x08 0x000c 00 00" {
		t.Fatalf("scanDisableArgs = %q", got)
	}
}

func TestHcidumpArgs(t *testing.T) {
	if got := strings.Join(hcidumpArgs("hci0"), " "); got != "-i hci0 -w /dev/stdout" {
		t.Fatalf("hcidumpArgs = %q", got)
	}
}

func TestBLEScannerConsumesHcidumpStream(t *testing.T) {
	now := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	s := &BLEScanner{Tracker: NewBLETracker(30 * time.Second), Now: func() time.Time { return now }}
	s.consumeDump(strings.NewReader("garbage that is not btsnoop"))
	if got := s.Tracker.Count(now); got != 0 {
		t.Fatalf("devices from bad stream = %d", got)
	}
}

// hcidump prints its "HCI sniffer" banner to stdout before the btsnoop header
// when writing to /dev/stdout (seen on the Pager).
func TestBLEScannerSkipsHcidumpBanner(t *testing.T) {
	now := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	s := &BLEScanner{Tracker: NewBLETracker(30 * time.Second), Now: func() time.Time { return now }}
	stream := []byte("HCI sniffer - Bluetooth packet analyzer ver 5.72\n")
	stream = append(stream, header(dlHCIUART)...)
	stream = append(stream, record(3, append([]byte{0x04}, hx(t, realA)...))...)
	s.consumeDump(bytes.NewReader(stream))
	devs := s.Tracker.Devices(now)
	if len(devs) != 1 || devs[0].Addr != "02:68:EB:EC:8C:6E" || devs[0].RSSI != -77 {
		t.Fatalf("devices = %+v", devs)
	}
}
