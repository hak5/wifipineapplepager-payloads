package main

import (
	"encoding/binary"
	"fmt"
	"math"
	"sort"
	"time"
)

const (
	minRetryFrames = 10
	// defaultRateKbps is assumed when a frame's PHY rate is unknown (e.g. HE).
	defaultRateKbps = 24000
)

// Frame is the subset of a captured radiotap + 802.11 frame RF-BUDDY uses.
type Frame struct {
	SignalDBm     int
	HasSignal     bool
	RateKbps      int
	Retry         bool
	TA            string
	Beacon        bool
	SSID          string
	BeaconChannel int
	Length        int
	BadFCS        bool
}

// radiotapFields gives alignment and size for present bits 0-21.
var radiotapFields = [22]struct{ align, size int }{
	{8, 8},  // 0 TSFT
	{1, 1},  // 1 Flags
	{1, 1},  // 2 Rate
	{2, 4},  // 3 Channel
	{2, 2},  // 4 FHSS
	{1, 1},  // 5 dBm antenna signal
	{1, 1},  // 6 dBm antenna noise
	{2, 2},  // 7 Lock quality
	{2, 2},  // 8 TX attenuation
	{2, 2},  // 9 dB TX attenuation
	{1, 1},  // 10 dBm TX power
	{1, 1},  // 11 Antenna
	{1, 1},  // 12 dB antenna signal
	{1, 1},  // 13 dB antenna noise
	{2, 2},  // 14 RX flags
	{2, 2},  // 15 TX flags
	{1, 1},  // 16 RTS retries
	{1, 1},  // 17 Data retries
	{4, 8},  // 18 XChannel
	{1, 3},  // 19 MCS
	{4, 8},  // 20 A-MPDU status
	{2, 12}, // 21 VHT
}

// ParseFrame decodes a monitor-mode packet. It only reads; nothing is sent.
func ParseFrame(pkt []byte) (Frame, bool) {
	var f Frame
	if len(pkt) < 8 || pkt[0] != 0 {
		return f, false
	}
	rtLen := int(binary.LittleEndian.Uint16(pkt[2:4]))
	if rtLen < 8 || rtLen > len(pkt) {
		return f, false
	}
	present := binary.LittleEndian.Uint32(pkt[4:8])
	off := 8
	for word := present; word&(1<<31) != 0; {
		if off+4 > rtLen {
			return f, false
		}
		word = binary.LittleEndian.Uint32(pkt[off : off+4])
		off += 4
	}
	// Walk the first present word's fields in order; each is aligned to its
	// natural size from the start of the header.
	var at [22]int
	for bit := 0; bit < len(radiotapFields); bit++ {
		at[bit] = -1
		if present&(1<<bit) == 0 {
			continue
		}
		spec := radiotapFields[bit]
		off = (off + spec.align - 1) &^ (spec.align - 1)
		if off+spec.size > rtLen {
			return f, false
		}
		at[bit] = off
		off += spec.size
	}
	var flags byte
	if i := at[1]; i >= 0 {
		flags = pkt[i]
	}
	if i := at[2]; i >= 0 {
		f.RateKbps = int(pkt[i]) * 500
	}
	if i := at[5]; i >= 0 {
		f.SignalDBm, f.HasSignal = int(int8(pkt[i])), true
	}
	if i := at[19]; i >= 0 {
		if r := htRateKbps(pkt[i+2], pkt[i+1]); r > 0 {
			f.RateKbps = r
		}
	}
	if i := at[21]; i >= 0 {
		if r := vhtRateKbps(pkt[i+3], pkt[i+2], pkt[i+4]); r > 0 {
			f.RateKbps = r
		}
	}

	dot11 := pkt[rtLen:]
	f.Length = len(dot11)
	f.BadFCS = flags&0x40 != 0
	if flags&0x10 != 0 { // frame includes FCS
		if len(dot11) < 4 {
			return f, false
		}
		dot11 = dot11[:len(dot11)-4]
	}
	if len(dot11) < 10 {
		return f, false
	}
	fc0, fc1 := dot11[0], dot11[1]
	frameType := (fc0 >> 2) & 0x3
	subtype := fc0 >> 4
	f.Retry = fc1&0x08 != 0
	ackOrCTS := frameType == 1 && (subtype == 12 || subtype == 13)
	if len(dot11) >= 16 && !ackOrCTS {
		f.TA = formatMAC(dot11[10:16])
	}
	if frameType == 0 && subtype == 8 && len(dot11) >= 36 {
		f.Beacon = true
		parseBeaconIEs(dot11[36:], &f)
	}
	return f, true
}

// 1 spatial stream, 20 MHz, long GI, Mb/s.
var htBase20 = [8]float64{6.5, 13, 19.5, 26, 39, 52, 58.5, 65}
var vhtBase20 = [10]float64{6.5, 13, 19.5, 26, 39, 52, 58.5, 65, 78, 86.7}

// htRateKbps converts a radiotap MCS field (flags bit 0-1 bandwidth, bit 2
// short GI) to a PHY rate. Returns 0 when unknown.
func htRateKbps(mcs, flags byte) int {
	if mcs > 31 {
		return 0
	}
	r := htBase20[mcs%8] * float64(mcs/8+1)
	if flags&0x03 == 1 {
		r *= 2.077 // 40 MHz
	}
	if flags&0x04 != 0 {
		r *= 10.0 / 9.0
	}
	return int(math.Round(r * 1000))
}

// vhtRateKbps converts radiotap VHT bandwidth, flags (bit 2 short GI), and the
// first user's mcs_nss byte to a PHY rate. Returns 0 when unknown.
func vhtRateKbps(bandwidth, flags, mcsNss byte) int {
	mcs, nss := int(mcsNss>>4), int(mcsNss&0x0f)
	if nss == 0 || mcs > 9 {
		return 0
	}
	mult := 1.0
	switch {
	case bandwidth >= 11 && bandwidth <= 25:
		mult = 9
	case bandwidth >= 4 && bandwidth <= 10:
		mult = 4.5
	case bandwidth >= 1 && bandwidth <= 3:
		mult = 2.077
	}
	r := vhtBase20[mcs] * float64(nss) * mult
	if flags&0x04 != 0 {
		r *= 10.0 / 9.0
	}
	return int(math.Round(r * 1000))
}

func parseBeaconIEs(ies []byte, f *Frame) {
	for len(ies) >= 2 {
		id, n := ies[0], int(ies[1])
		if 2+n > len(ies) {
			return
		}
		body := ies[2 : 2+n]
		switch id {
		case 0:
			f.SSID = cleanSSID(string(body))
		case 3:
			if n >= 1 {
				f.BeaconChannel = int(body[0])
			}
		}
		ies = ies[2+n:]
	}
}

func formatMAC(b []byte) string {
	return fmt.Sprintf("%02X:%02X:%02X:%02X:%02X:%02X", b[0], b[1], b[2], b[3], b[4], b[5])
}

// Transmitter is one nearby radio heard on the measured channel.
type Transmitter struct {
	Addr      string
	SSID      string
	SignalDBm int
}

// DwellStats accumulates frames heard during one dwell on one channel.
type DwellStats struct {
	frames, retries int
	airtimeUs       float64
	defaultRateKbps int
	tx              map[string]*Transmitter
	beacons         map[string]Frame
}

type DwellResult struct {
	Frames       int
	FramesPerSec float64
	RetryPct     float64
	HasRetry     bool
	AirtimePct   float64
	Top          []Transmitter
	Beacons      []Frame
}

func NewDwellStats(defaultRateKbps int) *DwellStats {
	return &DwellStats{defaultRateKbps: defaultRateKbps, tx: map[string]*Transmitter{}, beacons: map[string]Frame{}}
}

func (d *DwellStats) Add(f Frame) {
	if f.BadFCS {
		return
	}
	d.frames++
	if f.Retry {
		d.retries++
	}
	rate := f.RateKbps
	if rate <= 0 {
		rate = d.defaultRateKbps
	}
	d.airtimeUs += float64(f.Length*8)*1000/float64(rate) + 20
	if f.TA == "" {
		return
	}
	t, ok := d.tx[f.TA]
	if !ok {
		t = &Transmitter{Addr: f.TA, SignalDBm: -127}
		d.tx[f.TA] = t
	}
	if f.HasSignal && f.SignalDBm > t.SignalDBm {
		t.SignalDBm = f.SignalDBm
	}
	if f.Beacon {
		if f.SSID != "" {
			t.SSID = f.SSID
		}
		d.beacons[f.TA] = f
	}
}

func (d *DwellStats) Result(dwell time.Duration) DwellResult {
	r := DwellResult{Frames: d.frames}
	if s := dwell.Seconds(); s > 0 {
		r.FramesPerSec = float64(d.frames) / s
	}
	if d.frames >= minRetryFrames {
		r.RetryPct = float64(d.retries) * 100 / float64(d.frames)
		r.HasRetry = true
	}
	if us := float64(dwell.Microseconds()); us > 0 {
		r.AirtimePct = math.Min(100, d.airtimeUs*100/us)
	}
	for _, t := range d.tx {
		if t.SignalDBm > -127 {
			r.Top = append(r.Top, *t)
		}
	}
	sort.Slice(r.Top, func(i, j int) bool {
		if r.Top[i].SignalDBm != r.Top[j].SignalDBm {
			return r.Top[i].SignalDBm > r.Top[j].SignalDBm
		}
		return r.Top[i].Addr < r.Top[j].Addr
	})
	if len(r.Top) > 3 {
		r.Top = r.Top[:3]
	}
	for _, f := range d.beacons {
		r.Beacons = append(r.Beacons, f)
	}
	sort.Slice(r.Beacons, func(i, j int) bool { return r.Beacons[i].TA < r.Beacons[j].TA })
	return r
}
