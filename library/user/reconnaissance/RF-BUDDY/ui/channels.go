package main

import "sort"

// Band is a Wi-Fi band RF-BUDDY sweeps.
type Band int

const (
	Band24 Band = iota
	Band5
)

func (b Band) Label() string {
	if b == Band5 {
		return "5 GHZ"
	}
	return "2.4 GHZ"
}

func (b Band) LogName() string {
	if b == Band5 {
		return "5"
	}
	return "2.4"
}

func (b Band) Other() Band {
	if b == Band5 {
		return Band24
	}
	return Band5
}

// Channel is one 20 MHz Wi-Fi channel.
type Channel struct {
	Band   Band
	Number int
}

func (c Channel) FreqMHz() int {
	if c.Band == Band5 {
		return 5000 + 5*c.Number
	}
	if c.Number == 14 {
		return 2484
	}
	return 2407 + 5*c.Number
}

func ChannelForFreq(freq int) (Channel, bool) {
	switch {
	case freq == 2484:
		return Channel{Band24, 14}, true
	case freq >= 2412 && freq <= 2472 && (freq-2407)%5 == 0:
		return Channel{Band24, (freq - 2407) / 5}, true
	case freq >= 4910 && freq <= 5895 && freq%5 == 0:
		return Channel{Band5, (freq - 5000) / 5}, true
	}
	return Channel{}, false
}

func ChannelForNumber(n int) (Channel, bool) {
	switch {
	case n >= 1 && n <= 14:
		return Channel{Band24, n}, true
	case n >= 32 && n <= 177:
		return Channel{Band5, n}, true
	}
	return Channel{}, false
}

func Channels24() []Channel {
	out := make([]Channel, 0, 11)
	for n := 1; n <= 11; n++ {
		out = append(out, Channel{Band24, n})
	}
	return out
}

// default5GHz is swept when Recon has not reported any 5 GHz networks yet.
var default5GHz = []int{36, 40, 44, 48, 149, 153, 157, 161, 165}

// Channels5 lists the 5 GHz channels with observed APs, so the overview only
// shows channels that are in use.
func Channels5(aps []AP) []Channel {
	seen := map[int]bool{}
	for _, ap := range aps {
		if ap.Channel.Band == Band5 {
			seen[ap.Channel.Number] = true
		}
	}
	if len(seen) == 0 {
		for _, n := range default5GHz {
			seen[n] = true
		}
	}
	nums := make([]int, 0, len(seen))
	for n := range seen {
		nums = append(nums, n)
	}
	sort.Ints(nums)
	out := make([]Channel, 0, len(nums))
	for _, n := range nums {
		out = append(out, Channel{Band5, n})
	}
	return out
}

// overlaps24 reports whether two different 2.4 GHz channels share spectrum.
func overlaps24(a, b int) bool { return a != b && abs(a-b) <= 4 }

// AP is one access point heard by Recon or by beacon capture.
type AP struct {
	BSSID     string
	SSID      string
	Channel   Channel
	SignalDBm int
}
