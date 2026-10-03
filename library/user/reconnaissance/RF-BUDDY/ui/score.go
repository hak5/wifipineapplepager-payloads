package main

import "math"

// Metrics are the measurements for one channel during one dwell. The Pager's
// monitor radio exposes no survey counters, so everything here comes from
// passively captured frames, the AP inventory, and the BLE scan.
type Metrics struct {
	AirtimePct       float64
	HasAirtime       bool
	RetryPct         float64
	HasRetry         bool
	FramesPerSec     float64
	CoChannelAPs     int
	OverlapAPs       int
	StrongOverlapAPs int
	BTCount          int
	HasBT            bool
	OfficeConfigured bool
	OfficeHeard      bool
	OfficeSignalDBm  int
}

type Thresholds struct {
	RetryHighPct   float64
	AirtimeHighPct float64
	OverlapMinDBm  int
	BTDenseCount   int
	WeakSignalDBm  int
}

func DefaultThresholds() Thresholds {
	return Thresholds{RetryHighPct: 25, AirtimeHighPct: 50, OverlapMinDBm: -70, BTDenseCount: 30, WeakSignalDBm: -70}
}

const (
	CauseInterference = "INTERFERENCE"
	CauseCongestion   = "CONGESTION"
	CauseOverlap      = "CHANNEL OVERLAP"
	CauseBTDense      = "BT DENSE"
	CauseWeak         = "WEAK COVERAGE"
	CauseClean        = "CLEAN"
)

func normalize(v, lo, hi float64) float64 {
	return math.Max(0, math.Min(100, (v-lo)/(hi-lo)*100))
}

// Score combines the available metrics into 0-100; missing metrics drop out
// and the remaining weights are renormalised.
func Score(m Metrics) int {
	sum := normalize(float64(m.CoChannelAPs+m.OverlapAPs), 0, 12) * 20
	weight := 20.0
	if m.HasAirtime {
		sum += normalize(m.AirtimePct, 0, 80) * 45
		weight += 45
	}
	if m.HasRetry {
		sum += normalize(m.RetryPct, 0, 50) * 35
		weight += 35
	}
	return int(math.Round(sum / weight))
}

func Level(score int) string {
	switch {
	case score >= 70:
		return "HIGH"
	case score >= 40:
		return "MEDIUM"
	default:
		return "LOW"
	}
}

// Likely names the most probable cause; the first matching rule wins and
// rules whose inputs are N/A are skipped.
func Likely(m Metrics, band Band, t Thresholds) string {
	crowded := m.HasAirtime && m.AirtimePct >= t.AirtimeHighPct
	// Frames failing on a channel that is not busy with Wi-Fi point to non-Wi-Fi
	// RF (microwaves, wireless cameras, heavy Bluetooth).
	if m.HasRetry && m.RetryPct >= t.RetryHighPct && !crowded {
		return CauseInterference
	}
	if crowded {
		return CauseCongestion
	}
	if band == Band24 && m.StrongOverlapAPs > 0 {
		return CauseOverlap
	}
	if band == Band24 && m.HasBT && m.BTCount >= t.BTDenseCount {
		return CauseBTDense
	}
	if m.OfficeConfigured && (!m.OfficeHeard || m.OfficeSignalDBm < t.WeakSignalDBm) {
		return CauseWeak
	}
	return CauseClean
}
