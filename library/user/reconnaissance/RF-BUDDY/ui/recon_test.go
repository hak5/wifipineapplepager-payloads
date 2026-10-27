package main

import "testing"

const reconFixture = `[
 {"mac":"aa:bb:cc:00:00:01","packets":10,
  "beacon":[{"ssid":"","channel":6,"freq":2437,"signal":-44},{"ssid":"OfficeNet","channel":6,"freq":2437,"signal":-45}],
  "response":{"1":{"ssid":"OfficeNet","channel":6,"freq":2437,"signal":-43}}},
 {"mac":"AA:BB:CC:00:00:02","beacon":[{"ssid":"OfficeNet","channel":"36","freq":"5180","signal":"-50"}]},
 {"mac":"not-a-mac","beacon":[{"ssid":"Bad","channel":1,"freq":2412,"signal":-30}]},
 {"mac":"AA:BB:CC:00:00:03","beacon":[{"ssid":"Neighbor\u0007","channel":4,"signal":-60}]}
]`

func TestParseRecon(t *testing.T) {
	aps, err := ParseRecon([]byte(reconFixture))
	if err != nil {
		t.Fatal(err)
	}
	want := []AP{
		{BSSID: "AA:BB:CC:00:00:01", SSID: "OfficeNet", Channel: Channel{Band24, 6}, SignalDBm: -43},
		{BSSID: "AA:BB:CC:00:00:02", SSID: "OfficeNet", Channel: Channel{Band5, 36}, SignalDBm: -50},
		{BSSID: "AA:BB:CC:00:00:03", SSID: "Neighbor", Channel: Channel{Band24, 4}, SignalDBm: -60},
	}
	if len(aps) != len(want) {
		t.Fatalf("aps = %+v, want %d", aps, len(want))
	}
	for i := range want {
		if aps[i] != want[i] {
			t.Errorf("ap %d = %+v, want %+v", i, aps[i], want[i])
		}
	}
	if _, err := ParseRecon([]byte("{")); err == nil {
		t.Fatal("invalid JSON must error")
	}
}

func TestInventoryQueries(t *testing.T) {
	aps, _ := ParseRecon([]byte(reconFixture))
	inv := NewInventory(aps)
	ch6 := Channel{Band24, 6}
	if got := inv.CoChannel(ch6); got != 1 {
		t.Fatalf("CoChannel(6) = %d, want 1", got)
	}
	if all, strong := inv.Overlap(ch6, -70); all != 1 || strong != 1 {
		t.Fatalf("Overlap(6) = %d,%d, want 1,1", all, strong)
	}
	if all, strong := inv.Overlap(ch6, -55); all != 1 || strong != 0 {
		t.Fatalf("Overlap(6,-55) = %d,%d, want 1,0", all, strong)
	}
	if all, _ := inv.Overlap(Channel{Band5, 36}, -70); all != 0 {
		t.Fatal("5 GHz has no overlap accounting")
	}
	if sig, ok := inv.OfficeBest(Band5, "OfficeNet"); !ok || sig != -50 {
		t.Fatalf("OfficeBest(5) = %d %v", sig, ok)
	}
	if _, ok := inv.OfficeBest(Band24, "Missing"); ok {
		t.Fatal("missing SSID must not be heard")
	}
	inv.Observe(AP{BSSID: "AA:BB:CC:00:00:01", Channel: ch6, SignalDBm: -70})
	if got := inv.SSIDFor("AA:BB:CC:00:00:01"); got != "OfficeNet" {
		t.Fatalf("hidden re-observation dropped SSID: %q", got)
	}
	if got := Channels5(inv.All()); len(got) != 1 || got[0].Number != 36 {
		t.Fatalf("Channels5 from inventory = %+v", got)
	}
}
