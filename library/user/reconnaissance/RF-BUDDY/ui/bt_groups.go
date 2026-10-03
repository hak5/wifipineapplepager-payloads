package main

import (
	"fmt"
	"sort"
	"strings"
)

// BTGroup summarises a set of BLE devices sharing a brand or type.
type BTGroup struct {
	Name      string  // brand or type name
	Count     int     // devices in the group
	Strongest int     // max RSSI in the group (-100 if none known)
	AdvPerSec float64 // sum
	Top       string  // Label of the strongest device
}

// groupBy buckets devs by key and orders groups Count desc, Strongest desc,
// Name asc, with the last-placed name (UNKNOWN/OTHER) always at the end.
func groupBy(devs []BLEDevice, key func(BLEDevice) string, last string) []BTGroup {
	idx := map[string]int{}
	var out []BTGroup
	for _, d := range devs {
		k := key(d)
		i, ok := idx[k]
		if !ok {
			i = len(out)
			idx[k] = i
			out = append(out, BTGroup{Name: k, Strongest: bleNoSignal})
		}
		g := &out[i]
		g.Count++
		g.AdvPerSec += d.AdvPerSec
		if g.Top == "" || d.RSSI > g.Strongest {
			g.Strongest, g.Top = d.RSSI, d.Label
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if (a.Name == last) != (b.Name == last) {
			return b.Name == last
		}
		if a.Count != b.Count {
			return a.Count > b.Count
		}
		if a.Strongest != b.Strongest {
			return a.Strongest > b.Strongest
		}
		return a.Name < b.Name
	})
	return out
}

// GroupByBrand groups devices by Brand; UNKNOWN sorts last.
func GroupByBrand(devs []BLEDevice) []BTGroup {
	return groupBy(devs, func(d BLEDevice) string { return d.Brand }, "UNKNOWN")
}

// GroupByType groups the devices of one brand by Type; OTHER sorts last.
func GroupByType(devs []BLEDevice, brand string) []BTGroup {
	return groupBy(DevicesOf(devs, brand, ""), func(d BLEDevice) string { return d.Type }, "OTHER")
}

// DevicesOf filters by brand and, when typ is non-empty, by type; input order is kept.
func DevicesOf(devs []BLEDevice, brand, typ string) []BLEDevice {
	var out []BLEDevice
	for _, d := range devs {
		if d.Brand == brand && (typ == "" || d.Type == typ) {
			out = append(out, d)
		}
	}
	return out
}

// TypeBreakdown renders the top max types of a brand, e.g. "FIND MY 8, NEARBY 5, +3".
// The "+n" counts devices in the types that did not fit.
func TypeBreakdown(devs []BLEDevice, brand string, max int) string {
	groups := GroupByType(devs, brand)
	if max < 0 {
		max = 0
	}
	var parts []string
	rest := 0
	for i, g := range groups {
		if i < max {
			parts = append(parts, fmt.Sprintf("%s %d", g.Name, g.Count))
		} else {
			rest += g.Count
		}
	}
	if rest > 0 {
		parts = append(parts, fmt.Sprintf("+%d", rest))
	}
	return strings.Join(parts, ", ")
}
