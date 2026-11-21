package main

import (
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Mode is whether a sample came from the overview sweep or lock-on.
type Mode int

const (
	ModeOverview Mode = iota
	ModeLock
)

func (m Mode) LogName() string {
	if m == ModeLock {
		return "lock"
	}
	return "overview"
}

type Sample struct {
	At      time.Time
	Mode    Mode
	Channel Channel
	Metrics Metrics
	Score   int
	Likely  string
}

type Mark struct {
	At      time.Time
	Channel Channel
	Score   int
	Likely  string
	// BT marks (BT == true) come from the BT track screen.
	BT      bool
	BTAddr  string
	BTLabel string
	RSSI    int
}

type SampleSink interface {
	WriteSample(Sample)
	Paused() bool
}

const (
	samplesHeader     = "epoch,mode,band,channel,airtime_pct,retry_pct,frames_per_s,aps,overlap_aps,bt_count,score,likely\n"
	marksHeader       = "mark,epoch,band,channel,score,likely\n"
	freeCheckInterval = 10 * time.Second
)

var errLogPaused = errors.New("logging paused: low storage")

// Logger writes one session directory of CSVs with a size cap and a
// free-space reserve.
type Logger struct {
	mu             sync.Mutex
	dir            string
	samples, marks *os.File
	written        int64
	maxBytes       int64
	minFree        uint64
	free           func(string) (uint64, error)
	now            func() time.Time
	lastFreeCheck  time.Time
	lowSpace, full bool
	markCount      int
}

func OpenLogger(root string, started time.Time, maxBytes int64, minFree uint64, free func(string) (uint64, error), now func() time.Time) (*Logger, error) {
	dir := filepath.Join(root, started.Format("20060102-150405"))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	samples, err := os.Create(filepath.Join(dir, "samples.csv"))
	if err != nil {
		return nil, err
	}
	marks, err := os.Create(filepath.Join(dir, "marks.csv"))
	if err != nil {
		samples.Close()
		return nil, err
	}
	l := &Logger{dir: dir, samples: samples, marks: marks, maxBytes: maxBytes, minFree: minFree, free: free, now: now}
	n, err := io.WriteString(samples, samplesHeader)
	if err != nil {
		l.Close()
		return nil, err
	}
	l.written = int64(n)
	if _, err := io.WriteString(marks, marksHeader); err != nil {
		l.Close()
		return nil, err
	}
	return l, nil
}

func (l *Logger) Dir() string { return l.dir }

func (l *Logger) WriteSession(text string) error {
	return os.WriteFile(filepath.Join(l.dir, "session.txt"), []byte(text), 0o644)
}

func (l *Logger) checkSpaceLocked() {
	now := l.now()
	if !l.lastFreeCheck.IsZero() && now.Sub(l.lastFreeCheck) < freeCheckInterval {
		return
	}
	l.lastFreeCheck = now
	if l.free == nil {
		return
	}
	if free, err := l.free(l.dir); err == nil {
		l.lowSpace = free < l.minFree
	}
}

func (l *Logger) WriteSample(s Sample) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.checkSpaceLocked()
	if l.lowSpace || l.full {
		return
	}
	line := formatSample(s)
	if l.written+int64(len(line)) > l.maxBytes {
		l.full = true
		return
	}
	if n, err := io.WriteString(l.samples, line); err == nil {
		l.written += int64(n)
	}
}

func (l *Logger) Paused() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.checkSpaceLocked()
	return l.lowSpace || l.full
}

func (l *Logger) AddMark(m Mark) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.checkSpaceLocked()
	if l.lowSpace {
		return 0, errLogPaused
	}
	l.markCount++
	line := fmt.Sprintf("%d,%d,%s,%d,%d,%s\n", l.markCount, m.At.Unix(), m.Channel.Band.LogName(), m.Channel.Number, m.Score, m.Likely)
	if m.BT {
		line = fmt.Sprintf("%d,%d,bt,%s,%d,%s\n", l.markCount, m.At.Unix(), csvSafe(m.BTAddr), m.RSSI, csvSafe(m.BTLabel))
	}
	if _, err := io.WriteString(l.marks, line); err != nil {
		l.markCount--
		return 0, err
	}
	return l.markCount, nil
}

// csvSafe makes a stranger-controlled string safe as one CSV field: no
// separators, quotes or control characters, and no leading formula trigger.
func csvSafe(s string) string {
	s = strings.Map(func(r rune) rune {
		switch {
		case r == '\n' || r == '\r':
			return ' '
		case r == ',' || r == '"' || r < 0x20 || r == 0x7f:
			return -1
		}
		return r
	}, s)
	if s != "" && strings.ContainsRune("=+-@", rune(s[0])) {
		s = "'" + s
	}
	return s
}

func (l *Logger) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	var first error
	for _, f := range []*os.File{l.samples, l.marks} {
		if f != nil {
			if err := f.Close(); err != nil && first == nil {
				first = err
			}
		}
	}
	l.samples, l.marks = nil, nil
	return first
}

func formatSample(s Sample) string {
	m := s.Metrics
	opt := func(has bool, v float64) string {
		if !has {
			return ""
		}
		return strconv.FormatFloat(math.Round(v), 'f', 0, 64)
	}
	bt := ""
	if m.HasBT {
		bt = strconv.Itoa(m.BTCount)
	}
	return fmt.Sprintf("%d,%s,%s,%d,%s,%s,%s,%d,%d,%s,%d,%s\n",
		s.At.Unix(), s.Mode.LogName(), s.Channel.Band.LogName(), s.Channel.Number,
		opt(m.HasAirtime, m.AirtimePct), opt(m.HasRetry, m.RetryPct), opt(m.HasAirtime, m.FramesPerSec),
		m.CoChannelAPs, m.OverlapAPs, bt, s.Score, s.Likely)
}
