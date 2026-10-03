package main

import (
	"testing"
	"time"
)

func TestLastSeenText(t *testing.T) {
	now := time.Date(2026, 1, 1, 12, 0, 10, 0, time.UTC)
	if got := lastSeenText(time.Time{}, now); got != "-- S AGO" {
		t.Errorf("never seen = %q", got)
	}
	if got := lastSeenText(now.Add(-4*time.Second), now); got != "4 S AGO" {
		t.Errorf("seen = %q", got)
	}
}
