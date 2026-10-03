package main

import (
	"encoding/binary"
	"math"
	"testing"
	"time"
)

var testTA = [6]byte{0xaa, 0xbb, 0xcc, 0x00, 0x11, 0x22}

// radiotapFrame builds a radiotap header with Flags, Rate, and dBm signal.
func radiotapFrame(flags, rateUnits byte, signal int8, dot11 []byte) []byte {
	hdr := []byte{0, 0, 11, 0, 0x26, 0, 0, 0, flags, rateUnits, byte(signal)}
	return append(hdr, dot11...)
}

// radiotapHeader builds a header from present bits and pre-laid-out field bytes.
func radiotapHeader(present uint32, fields []byte) []byte {
	hdr := make([]byte, 8)
	binary.LittleEndian.PutUint32(hdr[4:], present)
	hdr = append(hdr, fields...)
	binary.LittleEndian.PutUint16(hdr[2:], uint16(len(hdr)))
	return hdr
}

func dataFrame(ta [6]byte, retry bool) []byte {
	fc1 := byte(0x01) // ToDS
	if retry {
		fc1 |= 0x08
	}
	f := []byte{0x08, fc1, 0, 0}
	f = append(f, make([]byte, 6)...) // addr1
	f = append(f, ta[:]...)           // addr2 = transmitter
	f = append(f, make([]byte, 8)...) // addr3 + sequence
	return append(f, []byte("payload-bytes")...)
}

func beaconFrame(ta [6]byte, ssid string, channel byte) []byte {
	f := []byte{0x80, 0x00, 0, 0}
	f = append(f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff)
	f = append(f, ta[:]...)
	f = append(f, ta[:]...)
	f = append(f, 0, 0)                // sequence
	f = append(f, make([]byte, 12)...) // timestamp, interval, capabilities
	f = append(f, 0, byte(len(ssid)))
	f = append(f, ssid...)
	return append(f, 3, 1, channel)
}

func TestParseDataFrame(t *testing.T) {
	f, ok := ParseFrame(radiotapFrame(0, 12, -55, dataFrame(testTA, true)))
	if !ok || !f.Retry || f.TA != "AA:BB:CC:00:11:22" || !f.HasSignal || f.SignalDBm != -55 || f.RateKbps != 6000 || f.Beacon {
		t.Fatalf("frame = %+v ok=%v", f, ok)
	}
}

func TestParseBeaconFrame(t *testing.T) {
	f, ok := ParseFrame(radiotapFrame(0, 2, -40, beaconFrame(testTA, "OfficeNet", 6)))
	if !ok || !f.Beacon || f.SSID != "OfficeNet" || f.BeaconChannel != 6 || f.TA != "AA:BB:CC:00:11:22" {
		t.Fatalf("beacon = %+v ok=%v", f, ok)
	}
}

func TestParseAckHasNoTransmitter(t *testing.T) {
	ack := []byte{0xd4, 0x00, 0, 0, 1, 2, 3, 4, 5, 6}
	f, ok := ParseFrame(radiotapFrame(0, 2, -60, ack))
	if !ok || f.TA != "" {
		t.Fatalf("ack = %+v ok=%v", f, ok)
	}
}

func TestParseFCSAndBadFCS(t *testing.T) {
	withFCS := append(dataFrame(testTA, false), 0xde, 0xad, 0xbe, 0xef)
	f, ok := ParseFrame(radiotapFrame(0x10, 2, -50, withFCS))
	if !ok || f.BadFCS || f.TA != "AA:BB:CC:00:11:22" || f.Length != len(withFCS) {
		t.Fatalf("fcs frame = %+v ok=%v", f, ok)
	}
	if f, ok = ParseFrame(radiotapFrame(0x50, 2, -50, withFCS)); !ok || !f.BadFCS {
		t.Fatalf("bad fcs frame = %+v ok=%v", f, ok)
	}
}

func TestParseTSFTAlignmentAndExtendedPresent(t *testing.T) {
	// TSFT | Flags | dBm signal: TSFT at offset 8 (already 8-aligned).
	fields := append(make([]byte, 8), 0, 0xc3) // tsft, flags, -61
	f, ok := ParseFrame(append(radiotapHeader(0x23, fields), dataFrame(testTA, false)...))
	if !ok || f.SignalDBm != -61 {
		t.Fatalf("tsft frame = %+v ok=%v", f, ok)
	}
	// dBm signal with the extension bit, then a second, empty present word.
	ext := []byte{0, 0, 13, 0, 0x20, 0, 0, 0x80, 0, 0, 0, 0, 0xc4} // -60
	if f, ok = ParseFrame(append(ext, dataFrame(testTA, false)...)); !ok || f.SignalDBm != -60 {
		t.Fatalf("extended present frame = %+v ok=%v", f, ok)
	}
}

func TestParseHTRateAfterAlignedFields(t *testing.T) {
	// Flags(1) | dBm signal(5) | RX flags(14, align 2) | XChannel(18, align 4) | MCS(19)
	present := uint32(1<<1 | 1<<5 | 1<<14 | 1<<18 | 1<<19)
	fields := []byte{
		0,    // flags @8
		0xc8, // signal -56 @9
		0, 0, // rx flags @10
		0, 0, 0, 0, 0, 0, 0, 0, // xchannel @12
		0x07, 0x01, 7, // mcs known, flags (40 MHz), mcs 7 @20
	}
	f, ok := ParseFrame(append(radiotapHeader(present, fields), dataFrame(testTA, false)...))
	if !ok || f.SignalDBm != -56 || f.RateKbps != 135005 {
		t.Fatalf("HT frame = %+v ok=%v, want -56 dBm and 135005 kb/s", f, ok)
	}
}

func TestParseVHTRate(t *testing.T) {
	// Flags(1) | dBm signal(5) | VHT(21, align 2)
	present := uint32(1<<1 | 1<<5 | 1<<21)
	vht := []byte{0x44, 0x00, 0x00, 4, 0x92, 0, 0, 0, 0, 0, 0, 0} // 80 MHz, MCS 9, 2 streams
	fields := append([]byte{0, 0xc0}, vht...)                     // flags, -64, vht @10
	f, ok := ParseFrame(append(radiotapHeader(present, fields), dataFrame(testTA, false)...))
	if !ok || f.SignalDBm != -64 || f.RateKbps != 780300 {
		t.Fatalf("VHT frame = %+v ok=%v, want 780300 kb/s", f, ok)
	}
}

func TestRateTables(t *testing.T) {
	if got := htRateKbps(15, 0x04); got != 144444 {
		t.Fatalf("HT MCS15 20 MHz short GI = %d, want 144444", got)
	}
	if got := htRateKbps(40, 0); got != 0 {
		t.Fatalf("invalid HT MCS = %d, want 0", got)
	}
	if got := vhtRateKbps(0, 0, 0x01); got != 6500 {
		t.Fatalf("VHT MCS0 1ss 20 MHz = %d, want 6500", got)
	}
	if got := vhtRateKbps(11, 0, 0x01); got != 58500 {
		t.Fatalf("VHT MCS0 1ss 160 MHz = %d, want 58500", got)
	}
}

func TestParseRejectsTruncated(t *testing.T) {
	for _, pkt := range [][]byte{nil, {0, 0, 40, 0, 0, 0, 0, 0}, radiotapFrame(0, 2, -50, []byte{0x08, 0x00})} {
		if _, ok := ParseFrame(pkt); ok {
			t.Fatalf("truncated packet parsed: %v", pkt)
		}
	}
}

func TestDwellStats(t *testing.T) {
	d := NewDwellStats(defaultRateKbps)
	d.Add(Frame{Beacon: true, TA: "AA:00:00:00:00:01", SSID: "OfficeNet", SignalDBm: -40, HasSignal: true, Length: 100})
	for i := 0; i < 9; i++ {
		d.Add(Frame{TA: "AA:00:00:00:00:02", SignalDBm: -60, HasSignal: true, Retry: i < 3, Length: 100})
	}
	d.Add(Frame{BadFCS: true, Retry: true, Length: 100})
	r := d.Result(250 * time.Millisecond)
	if r.Frames != 10 || !r.HasRetry || math.Abs(r.RetryPct-30) > 0.001 || math.Abs(r.FramesPerSec-40) > 0.001 {
		t.Fatalf("result = %+v", r)
	}
	if len(r.Top) != 2 || r.Top[0].SSID != "OfficeNet" || r.Top[0].SignalDBm != -40 || r.Top[1].SignalDBm != -60 {
		t.Fatalf("top = %+v", r.Top)
	}
	if len(r.Beacons) != 1 || r.Beacons[0].SSID != "OfficeNet" {
		t.Fatalf("beacons = %+v", r.Beacons)
	}
}

func TestDwellStatsAirtime(t *testing.T) {
	d := NewDwellStats(defaultRateKbps)
	d.Add(Frame{Length: 750, RateKbps: 6000}) // 1000 us + 20 us
	d.Add(Frame{Length: 3000})                // unknown rate -> 24 Mb/s: 1000 us + 20 us
	r := d.Result(10 * time.Millisecond)
	if math.Abs(r.AirtimePct-20.4) > 0.001 {
		t.Fatalf("airtime = %v, want 20.4", r.AirtimePct)
	}
	if r.HasRetry {
		t.Fatal("retry % needs at least 10 frames")
	}
}
