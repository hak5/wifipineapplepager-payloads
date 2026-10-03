package main

import (
	"reflect"
	"testing"
)

func gdev(brand, typ string, rssi int, label string) BLEDevice {
	return BLEDevice{Brand: brand, Type: typ, RSSI: rssi, Label: label, AdvPerSec: 1}
}

func testDevs() []BLEDevice {
	return []BLEDevice{
		gdev("UNKNOWN", "OTHER", -40, "U1"),
		gdev("APPLE", "NEARBY", -45, "A1"),
		gdev("TILE", "TRACKER", -50, "T1"),
		gdev("APPLE", "FIND MY", -55, "A2"),
		gdev("APPLE", "NEARBY", -60, "A3"),
		gdev("UNKNOWN", "OTHER", -65, "U2"),
		gdev("UNKNOWN", "OTHER", -70, "U3"),
		gdev("BOSE", "EARBUD", -52, "B1"),
		gdev("APPLE", "OTHER", -42, "A4"),
		gdev("APPLE", "AIRPLAY", -80, "A5"),
	}
}

func TestGroupByBrand(t *testing.T) {
	g := GroupByBrand(testDevs())
	var names []string
	for _, x := range g {
		names = append(names, x.Name)
	}
	// APPLE 5; then count 1 by strongest: TILE -50, BOSE -52; UNKNOWN (3) forced last.
	if want := []string{"APPLE", "TILE", "BOSE", "UNKNOWN"}; !reflect.DeepEqual(names, want) {
		t.Fatalf("order %v want %v", names, want)
	}
	if g[0].Count != 5 || g[0].Strongest != -42 || g[0].Top != "A4" || g[0].AdvPerSec != 5 {
		t.Errorf("apple %+v", g[0])
	}
	if GroupByBrand(nil) != nil {
		t.Error("empty")
	}
}

func TestGroupByBrandNameTiebreak(t *testing.T) {
	g := GroupByBrand([]BLEDevice{gdev("ZED", "X", -50, "z"), gdev("ACE", "X", -50, "a")})
	if g[0].Name != "ACE" || g[1].Name != "ZED" {
		t.Errorf("%+v", g)
	}
}

func TestGroupByType(t *testing.T) {
	g := GroupByType(testDevs(), "APPLE")
	var names []string
	for _, x := range g {
		names = append(names, x.Name)
	}
	// NEARBY 2; FIND MY -55 before AIRPLAY -80 (count 1); OTHER last despite -42.
	if want := []string{"NEARBY", "FIND MY", "AIRPLAY", "OTHER"}; !reflect.DeepEqual(names, want) {
		t.Fatalf("order %v want %v", names, want)
	}
	if g[0].Count != 2 || g[0].Strongest != -45 || g[0].Top != "A1" {
		t.Errorf("nearby %+v", g[0])
	}
	if len(GroupByType(testDevs(), "NOPE")) != 0 {
		t.Error("unknown brand")
	}
}

func TestDevicesOf(t *testing.T) {
	got := DevicesOf(testDevs(), "APPLE", "NEARBY")
	if len(got) != 2 || got[0].Label != "A1" || got[1].Label != "A3" {
		t.Errorf("%+v", got)
	}
	if n := len(DevicesOf(testDevs(), "UNKNOWN", "OTHER")); n != 3 {
		t.Errorf("unknown %d", n)
	}
	if len(DevicesOf(testDevs(), "APPLE", "EARBUD")) != 0 {
		t.Error("no match")
	}
}

func TestTypeBreakdown(t *testing.T) {
	d := testDevs()
	if got, want := TypeBreakdown(d, "APPLE", 2), "NEARBY 2, FIND MY 1, +2"; got != want {
		t.Errorf("got %q want %q", got, want)
	}
	if got, want := TypeBreakdown(d, "APPLE", 10), "NEARBY 2, FIND MY 1, AIRPLAY 1, OTHER 1"; got != want {
		t.Errorf("got %q want %q", got, want)
	}
	if got := TypeBreakdown(d, "BOSE", 3); got != "EARBUD 1" {
		t.Errorf("got %q", got)
	}
	if got := TypeBreakdown(d, "NOPE", 3); got != "" {
		t.Errorf("got %q", got)
	}
}
