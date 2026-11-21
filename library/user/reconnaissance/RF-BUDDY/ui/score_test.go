package main

import "testing"

func TestChannelFrequencies(t *testing.T) {
	cases := []struct {
		ch   Channel
		freq int
	}{
		{Channel{Band24, 1}, 2412}, {Channel{Band24, 6}, 2437}, {Channel{Band24, 14}, 2484},
		{Channel{Band5, 36}, 5180}, {Channel{Band5, 149}, 5745}, {Channel{Band5, 165}, 5825},
	}
	for _, c := range cases {
		if got := c.ch.FreqMHz(); got != c.freq {
			t.Errorf("%+v FreqMHz = %d, want %d", c.ch, got, c.freq)
		}
		back, ok := ChannelForFreq(c.freq)
		if !ok || back != c.ch {
			t.Errorf("ChannelForFreq(%d) = %+v %v, want %+v", c.freq, back, ok, c.ch)
		}
	}
	if _, ok := ChannelForFreq(5955); ok {
		t.Error("6 GHz frequency must not map to a channel")
	}
	if ch, ok := ChannelForNumber(44); !ok || ch != (Channel{Band5, 44}) {
		t.Errorf("ChannelForNumber(44) = %+v %v", ch, ok)
	}
}

func TestChannelLists(t *testing.T) {
	if got := Channels24(); len(got) != 11 || got[0].Number != 1 || got[10].Number != 11 {
		t.Fatalf("Channels24 = %+v", got)
	}
	aps := []AP{{Channel: Channel{Band5, 149}}, {Channel: Channel{Band5, 36}}, {Channel: Channel{Band5, 36}}, {Channel: Channel{Band24, 6}}}
	got := Channels5(aps)
	if len(got) != 2 || got[0].Number != 36 || got[1].Number != 149 {
		t.Fatalf("Channels5 = %+v, want [36 149]", got)
	}
	if def := Channels5(nil); len(def) != 9 || def[0].Number != 36 {
		t.Fatalf("default Channels5 = %+v", def)
	}
	if !overlaps24(6, 4) || overlaps24(6, 6) || overlaps24(1, 6) {
		t.Fatal("overlaps24 must mean a different channel within 4")
	}
}

func TestScoreWeightsAndClamping(t *testing.T) {
	worst := Metrics{AirtimePct: 95, HasAirtime: true, RetryPct: 60, HasRetry: true, CoChannelAPs: 20}
	if got := Score(worst); got != 100 {
		t.Fatalf("worst case = %d, want 100", got)
	}
	quiet := Metrics{HasAirtime: true, HasRetry: true}
	if got := Score(quiet); got != 0 {
		t.Fatalf("quiet = %d, want 0", got)
	}
	// airtime 40 -> 50, retry 24 -> 48, crowding 20 -> 100:
	// (50*45 + 48*35 + 100*20) / 100 = 59.3
	office := Metrics{AirtimePct: 40, HasAirtime: true, RetryPct: 24, HasRetry: true, CoChannelAPs: 14, OverlapAPs: 6}
	if got := Score(office); got != 59 {
		t.Fatalf("office example = %d, want 59", got)
	}
}

func TestScoreRenormalisesMissingRetry(t *testing.T) {
	// airtime (45) + crowding (20) only: (50*45 + 0*20) / 65 = 34.6
	if got := Score(Metrics{AirtimePct: 40, HasAirtime: true}); got != 35 {
		t.Fatalf("no retry = %d, want 35", got)
	}
	if got := Score(Metrics{CoChannelAPs: 6}); got != 50 {
		t.Fatalf("crowding only = %d, want 50", got)
	}
}

func TestLevel(t *testing.T) {
	for score, want := range map[int]string{0: "LOW", 39: "LOW", 40: "MEDIUM", 69: "MEDIUM", 70: "HIGH", 100: "HIGH"} {
		if got := Level(score); got != want {
			t.Errorf("Level(%d) = %q, want %q", score, got, want)
		}
	}
}

func TestLikelyRulesInOrder(t *testing.T) {
	th := DefaultThresholds()
	cases := []struct {
		name string
		m    Metrics
		band Band
		want string
	}{
		{"retries on a quiet channel", Metrics{RetryPct: 30, HasRetry: true, AirtimePct: 20, HasAirtime: true}, Band24, CauseInterference},
		{"interference beats overlap and bt", Metrics{RetryPct: 40, HasRetry: true, AirtimePct: 10, HasAirtime: true, StrongOverlapAPs: 2, BTCount: 50, HasBT: true}, Band24, CauseInterference},
		{"retries on a crowded channel are congestion", Metrics{RetryPct: 30, HasRetry: true, AirtimePct: 60, HasAirtime: true}, Band24, CauseCongestion},
		{"congestion", Metrics{AirtimePct: 55, HasAirtime: true}, Band5, CauseCongestion},
		{"retry N/A is not interference", Metrics{AirtimePct: 10, HasAirtime: true}, Band24, CauseClean},
		{"overlap on 2.4", Metrics{StrongOverlapAPs: 1, HasAirtime: true}, Band24, CauseOverlap},
		{"overlap ignored on 5", Metrics{StrongOverlapAPs: 3, HasAirtime: true}, Band5, CauseClean},
		{"bt dense on 2.4", Metrics{BTCount: 30, HasBT: true}, Band24, CauseBTDense},
		{"bt dense ignored on 5", Metrics{BTCount: 90, HasBT: true}, Band5, CauseClean},
		{"weak office signal", Metrics{OfficeConfigured: true, OfficeHeard: true, OfficeSignalDBm: -78}, Band24, CauseWeak},
		{"office not heard on band", Metrics{OfficeConfigured: true}, Band5, CauseWeak},
		{"office strong", Metrics{OfficeConfigured: true, OfficeHeard: true, OfficeSignalDBm: -50}, Band24, CauseClean},
		{"office rule skipped when not configured", Metrics{}, Band24, CauseClean},
	}
	for _, c := range cases {
		if got := Likely(c.m, c.band, th); got != c.want {
			t.Errorf("%s: Likely = %q, want %q", c.name, got, c.want)
		}
	}
}
