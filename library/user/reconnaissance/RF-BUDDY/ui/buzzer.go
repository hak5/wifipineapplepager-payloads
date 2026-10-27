package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Buzzer pulses the Pager's LED-class buzzer with plain sysfs file writes.
// The pre-existing frequency and volume are saved on open and restored on
// Close so other payloads see the buzzer unchanged.
type Buzzer struct {
	dir                 string
	freq, vol           int
	maxBrightness       string
	savedFreq, savedVol string
}

func OpenBuzzer(dir string, freqHz, volume int) (*Buzzer, error) {
	read := func(name string) (string, error) {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return "", err
		}
		return strings.TrimSpace(string(b)), nil
	}
	// the driver clamps volume to 0-100
	if volume < 0 {
		volume = 0
	} else if volume > 100 {
		volume = 100
	}
	b := &Buzzer{dir: dir, freq: freqHz, vol: volume}
	var err error
	if _, err = read("brightness"); err != nil {
		return nil, fmt.Errorf("buzzer: %w", err)
	}
	if b.maxBrightness, err = read("max_brightness"); err != nil {
		return nil, fmt.Errorf("buzzer: %w", err)
	}
	// frequency and volume are optional on some firmware; restore only if present.
	b.savedFreq, _ = read("frequency")
	b.savedVol, _ = read("volume")
	return b, nil
}

func (b *Buzzer) write(name, value string) {
	_ = os.WriteFile(filepath.Join(b.dir, name), []byte(value+"\n"), 0o644)
}

// brightnessFor is the brightness that makes the driver derive the wanted
// volume (volume = brightness*100/max_brightness); 0 means stay silent.
func (b *Buzzer) brightnessFor() int {
	if b.vol <= 0 {
		return 0
	}
	max, err := strconv.Atoi(b.maxBrightness)
	if err != nil || max < 1 {
		max = 1
	}
	br := max * b.vol / 100
	if br < 1 {
		br = 1
	}
	return br
}

// on starts the tone. The driver derives `volume` from `brightness`, so
// loudness is set through brightness and `volume` is never written here.
func (b *Buzzer) on() {
	br := b.brightnessFor()
	if br == 0 {
		return
	}
	b.write("frequency", strconv.Itoa(b.freq))
	b.write("brightness", strconv.Itoa(br))
}

func (b *Buzzer) off() { b.write("brightness", "0") }

// Beep sounds the buzzer for d, then silences it. Volume 0 only sleeps.
func (b *Buzzer) Beep(d time.Duration) {
	if b == nil {
		return
	}
	b.on()
	time.Sleep(d)
	b.off()
}

// Close silences the buzzer and restores the saved frequency and volume.
func (b *Buzzer) Close() {
	if b == nil {
		return
	}
	b.write("brightness", "0")
	if b.savedFreq != "" {
		b.write("frequency", b.savedFreq)
	}
	if b.savedVol != "" {
		b.write("volume", b.savedVol)
	}
}
