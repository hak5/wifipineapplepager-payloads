package main

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"sync"
	"unicode"
)

// flexInt accepts Recon numbers encoded as JSON numbers or strings.
type flexInt struct {
	v  int
	ok bool
}

func (f *flexInt) UnmarshalJSON(b []byte) error {
	s := strings.Trim(string(b), "\"")
	if s == "" || s == "null" {
		return nil
	}
	if v, err := strconv.ParseFloat(s, 64); err == nil {
		f.v, f.ok = int(math.Round(v)), true
	}
	return nil
}

type reconObservation struct {
	SSID    string  `json:"ssid"`
	Channel flexInt `json:"channel"`
	Freq    flexInt `json:"freq"`
	Signal  flexInt `json:"signal"`
}

type reconAP struct {
	MAC      string          `json:"mac"`
	Beacon   json.RawMessage `json:"beacon"`
	Response json.RawMessage `json:"response"`
}

// decodeObservations accepts both the array and the keyed-object forms that
// PineAP Recon uses for beacon/response lists.
func decodeObservations(raw json.RawMessage) []reconObservation {
	if len(raw) == 0 {
		return nil
	}
	var list []reconObservation
	if json.Unmarshal(raw, &list) == nil {
		return list
	}
	var byKey map[string]reconObservation
	if json.Unmarshal(raw, &byKey) != nil {
		return nil
	}
	keys := make([]string, 0, len(byKey))
	for k := range byKey {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		list = append(list, byKey[k])
	}
	return list
}

// ParseRecon reads `_pineap RECON APS format=json` into one best AP per BSSID,
// preferring a visible SSID, then the strongest signal.
func ParseRecon(data []byte) ([]AP, error) {
	var raw []reconAP
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("parse recon json: %w", err)
	}
	var out []AP
	for _, r := range raw {
		bssid := normalizeMAC(r.MAC)
		if bssid == "" {
			continue
		}
		var best AP
		have := false
		for _, o := range append(decodeObservations(r.Beacon), decodeObservations(r.Response)...) {
			ch, ok := observationChannel(o)
			if !ok {
				continue
			}
			ap := AP{BSSID: bssid, SSID: cleanSSID(o.SSID), Channel: ch, SignalDBm: -100}
			if o.Signal.ok {
				ap.SignalDBm = o.Signal.v
			}
			if !have || betterObservation(ap, best) {
				best, have = ap, true
			}
		}
		if have {
			out = append(out, best)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].BSSID < out[j].BSSID })
	return out, nil
}

func observationChannel(o reconObservation) (Channel, bool) {
	if o.Freq.ok {
		if ch, ok := ChannelForFreq(o.Freq.v); ok {
			return ch, true
		}
	}
	if o.Channel.ok {
		return ChannelForNumber(o.Channel.v)
	}
	return Channel{}, false
}

func betterObservation(a, b AP) bool {
	if (a.SSID != "") != (b.SSID != "") {
		return a.SSID != ""
	}
	return a.SignalDBm > b.SignalDBm
}

func normalizeMAC(s string) string {
	s = strings.ToUpper(strings.TrimSpace(s))
	parts := strings.Split(s, ":")
	if len(parts) != 6 {
		return ""
	}
	for _, p := range parts {
		if len(p) != 2 || strings.Trim(p, "0123456789ABCDEF") != "" {
			return ""
		}
	}
	return s
}

// cleanSSID drops control characters and commas so SSIDs cannot corrupt the
// screen or the CSV log.
func cleanSSID(s string) string {
	return strings.TrimSpace(strings.Map(func(r rune) rune {
		if !unicode.IsPrint(r) || r == ',' {
			return -1
		}
		return r
	}, s))
}

// Inventory is the set of APs known from Recon plus beacons heard while
// sweeping. It is safe for concurrent use.
type Inventory struct {
	mu  sync.Mutex
	aps map[string]AP
}

func NewInventory(aps []AP) *Inventory {
	inv := &Inventory{aps: map[string]AP{}}
	for _, ap := range aps {
		inv.Observe(ap)
	}
	return inv
}

func (inv *Inventory) Observe(ap AP) {
	if ap.BSSID == "" {
		return
	}
	inv.mu.Lock()
	defer inv.mu.Unlock()
	if old, ok := inv.aps[ap.BSSID]; ok && ap.SSID == "" {
		ap.SSID = old.SSID
	}
	inv.aps[ap.BSSID] = ap
}

func (inv *Inventory) All() []AP {
	inv.mu.Lock()
	defer inv.mu.Unlock()
	out := make([]AP, 0, len(inv.aps))
	for _, ap := range inv.aps {
		out = append(out, ap)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].BSSID < out[j].BSSID })
	return out
}

func (inv *Inventory) CoChannel(ch Channel) int {
	n := 0
	for _, ap := range inv.All() {
		if ap.Channel == ch {
			n++
		}
	}
	return n
}

// Overlap counts 2.4 GHz APs on different channels within 4 of ch; strong
// counts those louder than minDBm.
func (inv *Inventory) Overlap(ch Channel, minDBm int) (all, strong int) {
	if ch.Band != Band24 {
		return 0, 0
	}
	for _, ap := range inv.All() {
		if ap.Channel.Band == Band24 && overlaps24(ap.Channel.Number, ch.Number) {
			all++
			if ap.SignalDBm > minDBm {
				strong++
			}
		}
	}
	return all, strong
}

func (inv *Inventory) OfficeBest(band Band, ssid string) (int, bool) {
	best, ok := -200, false
	for _, ap := range inv.All() {
		if ap.Channel.Band == band && ap.SSID == ssid && ap.SignalDBm > best {
			best, ok = ap.SignalDBm, true
		}
	}
	return best, ok
}

func (inv *Inventory) SSIDFor(bssid string) string {
	inv.mu.Lock()
	defer inv.mu.Unlock()
	return inv.aps[bssid].SSID
}
