package main

import (
	"os"
	"strconv"
	"strings"
	"time"
)

// posixFixedZone parses the standard-offset part of a POSIX TZ string such as
// "UTC-8" or "<+0530>-5:30". The POSIX sign is inverted (UTC-8 is UTC+8).
// Any DST part after the offset is ignored.
func posixFixedZone(tz string) (*time.Location, bool) {
	s := strings.TrimSpace(tz)
	if s == "" || strings.Contains(s, "/") {
		return nil, false
	}
	var name string
	if s[0] == '<' {
		end := strings.IndexByte(s, '>')
		if end < 2 {
			return nil, false
		}
		name, s = s[1:end], s[end+1:]
	} else {
		i := 0
		for i < len(s) && (s[i] >= 'A' && s[i] <= 'Z' || s[i] >= 'a' && s[i] <= 'z') {
			i++
		}
		if i < 3 {
			return nil, false
		}
		name, s = s[:i], s[i:]
	}
	sign := 1
	if s != "" && (s[0] == '+' || s[0] == '-') {
		if s[0] == '-' {
			sign = -1
		}
		s = s[1:]
	}
	var parts [3]int
	n := 0
	for n < 3 {
		j := 0
		for j < len(s) && s[j] >= '0' && s[j] <= '9' {
			j++
		}
		if j == 0 {
			return nil, false
		}
		v, err := strconv.Atoi(s[:j])
		if err != nil {
			return nil, false
		}
		parts[n] = v
		n++
		s = s[j:]
		if s == "" || s[0] != ':' {
			break
		}
		s = s[1:]
	}
	if parts[0] > 24 || parts[1] > 59 || parts[2] > 59 {
		return nil, false
	}
	secs := parts[0]*3600 + parts[1]*60 + parts[2]
	return time.FixedZone(name, -sign*secs), true
}

// setLocalZone makes time.Local honour the device timezone when Go cannot,
// because the firmware ships no zoneinfo database. It uses $TZ if set, else
// /etc/TZ, and only overrides when the value is POSIX-style or unloadable.
func setLocalZone(readFile func(string) ([]byte, error)) {
	tz := os.Getenv("TZ")
	if tz == "" {
		if b, err := readFile("/etc/TZ"); err == nil {
			tz = strings.TrimSpace(string(b))
		}
	}
	if tz == "" {
		return
	}
	if _, err := time.LoadLocation(tz); err == nil {
		return
	}
	if loc, ok := posixFixedZone(tz); ok {
		time.Local = loc
	}
}
