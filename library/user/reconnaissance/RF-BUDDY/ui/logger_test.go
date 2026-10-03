package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var logStart = time.Date(2026, 10, 1, 12, 42, 5, 0, time.UTC)

func plentyFree(string) (uint64, error) { return 1 << 40, nil }

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestLoggerWritesHeadersAndSamples(t *testing.T) {
	root := t.TempDir()
	l, err := OpenLogger(root, logStart, 1<<20, 64<<20, plentyFree, func() time.Time { return logStart })
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	if l.Dir() != filepath.Join(root, "20261001-124205") {
		t.Fatalf("dir = %s", l.Dir())
	}
	l.WriteSample(Sample{At: logStart, Mode: ModeLock, Channel: Channel{Band24, 6},
		Metrics: Metrics{AirtimePct: 41.6, HasAirtime: true, FramesPerSec: 212.4, CoChannelAPs: 14, OverlapAPs: 6, BTCount: 23, HasBT: true},
		Score:   72, Likely: CauseInterference})
	got := readFile(t, filepath.Join(l.Dir(), "samples.csv"))
	want := "epoch,mode,band,channel,airtime_pct,retry_pct,frames_per_s,aps,overlap_aps,bt_count,score,likely\n" +
		"1790858525,lock,2.4,6,42,,212,14,6,23,72,INTERFERENCE\n"
	if got != want {
		t.Fatalf("samples.csv =\n%s\nwant\n%s", got, want)
	}
	if err := l.WriteSession("probe: ok\n"); err != nil {
		t.Fatal(err)
	}
	if readFile(t, filepath.Join(l.Dir(), "session.txt")) != "probe: ok\n" {
		t.Fatal("session.txt mismatch")
	}
}

func TestLoggerMarksAreNumbered(t *testing.T) {
	l, err := OpenLogger(t.TempDir(), logStart, 1<<20, 64<<20, plentyFree, func() time.Time { return logStart })
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	for i := 1; i <= 2; i++ {
		n, err := l.AddMark(Mark{At: logStart, Channel: Channel{Band5, 36}, Score: 40 + i, Likely: CauseClean})
		if err != nil || n != i {
			t.Fatalf("mark %d = %d %v", i, n, err)
		}
	}
	got := readFile(t, filepath.Join(l.Dir(), "marks.csv"))
	if got != "mark,epoch,band,channel,score,likely\n1,1790858525,5,36,41,CLEAN\n2,1790858525,5,36,42,CLEAN\n" {
		t.Fatalf("marks.csv = %q", got)
	}
}

func TestLoggerBTMarkRow(t *testing.T) {
	l, err := OpenLogger(t.TempDir(), logStart, 1<<20, 64<<20, plentyFree, func() time.Time { return logStart })
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	if _, err := l.AddMark(Mark{At: logStart, BT: true, BTAddr: "74:4D:BD:CD:0F:C5", BTLabel: "NANO,LEAF\nSTRIP", RSSI: -55}); err != nil {
		t.Fatal(err)
	}
	got := readFile(t, filepath.Join(l.Dir(), "marks.csv"))
	if got != "mark,epoch,band,channel,score,likely\n1,1790858525,bt,74:4D:BD:CD:0F:C5,-55,NANOLEAF STRIP\n" {
		t.Fatalf("marks.csv = %q", got)
	}
	if _, err := l.AddMark(Mark{At: logStart, BT: true, BTAddr: "-1,\"A", BTLabel: "=1+1\"x,y\x01\x07", RSSI: -60}); err != nil {
		t.Fatal(err)
	}
	got = readFile(t, filepath.Join(l.Dir(), "marks.csv"))
	want := "mark,epoch,band,channel,score,likely\n1,1790858525,bt,74:4D:BD:CD:0F:C5,-55,NANOLEAF STRIP\n2,1790858525,bt,'-1A,-60,'=1+1xy\n"
	if got != want {
		t.Fatalf("marks.csv = %q, want %q", got, want)
	}
}

func TestLoggerStopsAtSizeCap(t *testing.T) {
	sample := Sample{At: logStart, Channel: Channel{Band24, 1}, Score: 10, Likely: CauseClean}
	maxBytes := int64(len(samplesHeader) + len(formatSample(sample)))
	l, err := OpenLogger(t.TempDir(), logStart, maxBytes, 0, plentyFree, func() time.Time { return logStart })
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	l.WriteSample(sample)
	if l.Paused() {
		t.Fatal("first sample fits under the cap")
	}
	l.WriteSample(sample)
	if !l.Paused() {
		t.Fatal("logger must pause when the cap is reached")
	}
	if lines := strings.Count(readFile(t, filepath.Join(l.Dir(), "samples.csv")), "\n"); lines != 2 {
		t.Fatalf("lines = %d, want header + 1", lines)
	}
}

func TestLoggerPausesOnLowStorage(t *testing.T) {
	low := func(string) (uint64, error) { return 10 << 20, nil }
	l, err := OpenLogger(t.TempDir(), logStart, 1<<20, 64<<20, low, func() time.Time { return logStart })
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	l.WriteSample(Sample{At: logStart, Channel: Channel{Band24, 1}})
	if !l.Paused() {
		t.Fatal("logger must pause below MIN_FREE_MB")
	}
	if _, err := l.AddMark(Mark{At: logStart}); !errors.Is(err, errLogPaused) {
		t.Fatalf("mark err = %v, want errLogPaused", err)
	}
}
