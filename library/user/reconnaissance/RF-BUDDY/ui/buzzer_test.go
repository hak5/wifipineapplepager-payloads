package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fakeBuzzerDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for name, v := range map[string]string{"brightness": "0\n", "max_brightness": "255\n", "frequency": "523\n", "volume": "0\n"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(v), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func readTrim(t *testing.T, dir, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(b))
}

func TestBuzzerBeepAndRestore(t *testing.T) {
	dir := fakeBuzzerDir(t)
	b, err := OpenBuzzer(dir, 2000, 60)
	if err != nil {
		t.Fatal(err)
	}
	b.Beep(time.Millisecond)
	if got := readTrim(t, dir, "brightness"); got != "0" {
		t.Fatalf("brightness after beep = %q", got)
	}
	if readTrim(t, dir, "frequency") != "2000" {
		t.Fatal("beep must set frequency")
	}
	if readTrim(t, dir, "volume") != "0" {
		t.Fatal("beep must not write volume (driver derives it from brightness)")
	}
	raw, _ := os.ReadFile(filepath.Join(dir, "frequency"))
	if string(raw) != "2000\n" {
		t.Fatalf("frequency raw = %q, want decimal with newline", raw)
	}
	b.Close()
	if readTrim(t, dir, "frequency") != "523" || readTrim(t, dir, "volume") != "0" || readTrim(t, dir, "brightness") != "0" {
		t.Fatal("close must restore frequency/volume and leave brightness 0")
	}
}

func TestOpenBuzzerMissing(t *testing.T) {
	if _, err := OpenBuzzer(filepath.Join(t.TempDir(), "nope"), 2000, 128); err == nil {
		t.Fatal("missing dir must error")
	}
	dir := fakeBuzzerDir(t)
	os.Remove(filepath.Join(dir, "brightness"))
	if _, err := OpenBuzzer(dir, 2000, 60); err == nil {
		t.Fatal("missing brightness must error")
	}
	dir = fakeBuzzerDir(t)
	os.Remove(filepath.Join(dir, "max_brightness"))
	if _, err := OpenBuzzer(dir, 2000, 60); err == nil {
		t.Fatal("missing max_brightness must error")
	}
}

func TestBuzzerNilSafe(t *testing.T) {
	var b *Buzzer
	b.Beep(time.Millisecond)
	b.Close()
}

func TestBuzzerBrightnessFromVolume(t *testing.T) {
	for in, want := range map[int]string{60: "153", 100: "255", 1: "2", 150: "255", 0: "0", -5: "0"} {
		dir := fakeBuzzerDir(t)
		b, err := OpenBuzzer(dir, 2000, in)
		if err != nil {
			t.Fatal(err)
		}
		b.on()
		if got := readTrim(t, dir, "brightness"); got != want {
			t.Fatalf("volume %d: brightness while on = %q, want %q", in, got, want)
		}
		b.off()
		if got := readTrim(t, dir, "brightness"); got != "0" {
			t.Fatalf("brightness after off = %q", got)
		}
		b.Close()
	}
}

func TestBuzzerVolumeZeroStaysSilent(t *testing.T) {
	dir := fakeBuzzerDir(t)
	b, _ := OpenBuzzer(dir, 2000, 0)
	b.Beep(time.Millisecond)
	if readTrim(t, dir, "brightness") != "0" || readTrim(t, dir, "frequency") != "523" {
		t.Fatal("volume 0 must not touch the buzzer")
	}
}
