package main

import (
	"errors"
	"testing"
	"time"
)

func TestPosixFixedZone(t *testing.T) {
	cases := []struct {
		in   string
		ok   bool
		name string
		off  int
	}{
		{"UTC-8", true, "UTC", 28800},
		{"CST-8", true, "CST", 28800},
		{"EST5EDT,M3.2.0,M11.1.0", true, "EST", -18000},
		{"<+0530>-5:30", true, "+0530", 19800},
		{"UTC0", true, "UTC", 0},
		{"", false, "", 0},
		{"Asia/Taipei", false, "", 0},
		{"garbage", false, "", 0},
	}
	for _, c := range cases {
		loc, ok := posixFixedZone(c.in)
		if ok != c.ok {
			t.Errorf("%q ok=%v want %v", c.in, ok, c.ok)
			continue
		}
		if !ok {
			continue
		}
		name, off := time.Unix(0, 0).In(loc).Zone()
		if name != c.name || off != c.off {
			t.Errorf("%q = %s %d, want %s %d", c.in, name, off, c.name, c.off)
		}
	}
}

func TestSetLocalZoneFromEtcTZ(t *testing.T) {
	old := time.Local
	defer func() { time.Local = old }()
	t.Setenv("TZ", "")
	setLocalZone(func(p string) ([]byte, error) {
		if p != "/etc/TZ" {
			return nil, errors.New("unexpected path")
		}
		return []byte("UTC-8\n"), nil
	})
	if _, off := time.Unix(0, 0).In(time.Local).Zone(); off != 8*3600 {
		t.Fatalf("offset = %d, want 28800", off)
	}
}
