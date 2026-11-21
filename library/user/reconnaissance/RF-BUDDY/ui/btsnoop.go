package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"strings"
)

// Advert is one decoded BLE advertising report.
type Advert struct {
	Addr       string // "AA:BB:CC:DD:EE:FF", display order (wire order reversed)
	Random     bool
	RSSI       int
	Name       string
	TxPower    int
	HasTx      bool
	Company    int    // -1 when absent
	Kind       string // legacy single kind: mfr > service > appearance
	Appearance int    // GAP appearance value, -1 when absent
	BrandHint  string

	MfrKind      string // kind from manufacturer data (Apple / Microsoft)
	SvcKind      string // kind from advertised services
	ServiceUUIDs []int  // 16-bit service UUIDs (AD 0x02/0x03 and service data), max advMaxServices
	Model        string // decoded device model, e.g. "AIRPODS PRO 2"
	BeaconInfo   string // e.g. "IBEACON 1234/5678", "EDDYSTONE URL"
}

const advMaxServices = 8

const (
	btsnoopHdrLen    = 16
	btsnoopRecLen    = 24
	btsnoopMaxPkt    = 1 << 16
	dlHCIUnenc       = 1001
	dlHCIUART        = 1002
	hciEvtLEMeta     = 0x3E
	hciSubLEAdv      = 0x02
	hciSubLEExtAdv   = 0x0D
	hciPktEvent      = 0x04
	extAdvHdrLen     = 24
	extTxUnavailable = 127
)

var btsnoopMagic = []byte("btsnoop\x00")

// ReadBTSnoop decodes a btsnoop stream and calls fn per LE advertising report.
func ReadBTSnoop(r io.Reader, fn func(Advert)) error {
	var hdr [btsnoopHdrLen]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return eofNil(err)
	}
	if !bytes.Equal(hdr[:8], btsnoopMagic) {
		return errors.New("btsnoop: bad magic")
	}
	dl := binary.BigEndian.Uint32(hdr[12:16])
	if dl != dlHCIUnenc && dl != dlHCIUART {
		return fmt.Errorf("btsnoop: unsupported datalink %d", dl)
	}
	var rec [btsnoopRecLen]byte
	var buf []byte
	for {
		if _, err := io.ReadFull(r, rec[:]); err != nil {
			return eofNil(err)
		}
		incl := binary.BigEndian.Uint32(rec[4:8])
		flags := binary.BigEndian.Uint32(rec[8:12])
		if incl > btsnoopMaxPkt {
			return errors.New("btsnoop: oversized record")
		}
		if cap(buf) < int(incl) {
			buf = make([]byte, incl)
		}
		buf = buf[:incl]
		if _, err := io.ReadFull(r, buf); err != nil {
			return err
		}
		pkt := buf
		if dl == dlHCIUART {
			if len(pkt) < 1 || pkt[0] != hciPktEvent {
				continue
			}
			pkt = pkt[1:]
		} else if flags&2 == 0 {
			continue // not a command/event record
		}
		for _, a := range ParseLEAdvertEvent(pkt) {
			fn(a)
		}
	}
}

func eofNil(err error) error {
	if err == io.EOF {
		return nil
	}
	return err
}

// ParseLEAdvertEvent decodes one HCI event (starting at the event code byte).
// Malformed or truncated input returns nil.
func ParseLEAdvertEvent(pkt []byte) []Advert {
	if len(pkt) < 4 || pkt[0] != hciEvtLEMeta || len(pkt) < 2+int(pkt[1]) {
		return nil
	}
	body := pkt[2 : 2+int(pkt[1])]
	if len(body) < 2 {
		return nil
	}
	sub, n, p := body[0], int(body[1]), body[2:]
	var out []Advert
	for i := 0; i < n; i++ {
		var a Advert
		var ad []byte
		switch sub {
		case hciSubLEAdv:
			// event_type, addr_type, addr[6], data_len, data, rssi
			if len(p) < 9 || len(p) < 9+int(p[8])+1 {
				return nil
			}
			dl := int(p[8])
			a.Random = p[1] != 0
			a.Addr = fmtAddr(p[2:8])
			ad = p[9 : 9+dl]
			a.RSSI = int(int8(p[9+dl]))
			p = p[9+dl+1:]
		case hciSubLEExtAdv:
			if len(p) < extAdvHdrLen || len(p) < extAdvHdrLen+int(p[extAdvHdrLen-1]) {
				return nil
			}
			dl := int(p[extAdvHdrLen-1])
			a.Random = p[2] != 0
			a.Addr = fmtAddr(p[3:9])
			if tx := int8(p[12]); tx != extTxUnavailable {
				a.TxPower, a.HasTx = int(tx), true
			}
			a.RSSI = int(int8(p[13]))
			ad = p[extAdvHdrLen : extAdvHdrLen+dl]
			p = p[extAdvHdrLen+dl:]
		default:
			return nil
		}
		parseAD(ad, &a)
		out = append(out, a)
	}
	return out
}

func fmtAddr(b []byte) string {
	return fmt.Sprintf("%02X:%02X:%02X:%02X:%02X:%02X", b[5], b[4], b[3], b[2], b[1], b[0])
}

// parseAD walks the [len][type][data] structures of an advert payload.
// Kind precedence is order independent: manufacturer data > service > appearance.
func parseAD(ad []byte, a *Advert) {
	a.Company = -1
	a.Appearance = -1
	short, mfr, svc := "", "", ""
	fastPair := false
	service := func(uuid int, data []byte) {
		kind, hint := "", ""
		if len(a.ServiceUUIDs) < advMaxServices {
			dup := false
			for _, u := range a.ServiceUUIDs {
				dup = dup || u == uuid
			}
			if !dup {
				a.ServiceUUIDs = append(a.ServiceUUIDs, uuid)
			}
		}
		switch uuid {
		case 0xFEED, 0xFEEC:
			kind, hint = "TRACKER", "TILE"
		case 0xFD5A:
			kind, hint = "SMARTTAG", "SAMSUNG"
		case 0xFEAA:
			kind = "EDDYSTONE"
			if len(data) >= 1 && a.BeaconInfo == "" {
				if f := eddystoneFrame(data[0]); f != "" {
					a.BeaconInfo = "EDDYSTONE " + f
				}
			}
		case 0xFE2C:
			kind, fastPair = "FAST PAIR", true
		case 0xFD6F:
			kind = "EXPOSURE NOTIF"
		case 0xFE9F:
			hint = "GOOGLE"
		default:
			kind = serviceKind(uuid)
		}
		if kind != "" && svc == "" {
			svc = kind
		}
		if hint != "" && a.BrandHint == "" {
			a.BrandHint = hint
		}
	}
	for len(ad) >= 2 {
		l := int(ad[0])
		if l == 0 || len(ad) < 1+l {
			break
		}
		typ, d := ad[1], ad[2:1+l]
		ad = ad[1+l:]
		switch typ {
		case 0x09:
			a.Name = sanitize(string(d))
		case 0x08:
			short = sanitize(string(d))
		case 0x0A:
			if len(d) >= 1 {
				a.TxPower, a.HasTx = int(int8(d[0])), true
			}
		case 0x19:
			if len(d) >= 2 {
				a.Appearance = int(d[0]) | int(d[1])<<8
			}
		case 0xFF:
			if len(d) >= 2 {
				a.Company = int(d[0]) | int(d[1])<<8
				if k, m, b := mfrInfo(a.Company, d[2:]); mfr == "" && k != "" {
					mfr = k
					if a.Model == "" {
						a.Model = m
					}
					if a.BeaconInfo == "" {
						a.BeaconInfo = b
					}
				}
			}
		case 0x16:
			if len(d) >= 2 {
				service(int(d[0])|int(d[1])<<8, d[2:])
			}
		case 0x02, 0x03:
			for i := 0; i+1 < len(d); i += 2 {
				service(int(d[i])|int(d[i+1])<<8, nil)
			}
		}
	}
	if a.Name == "" {
		a.Name = short
	}
	if fastPair && a.Company < 0 && a.BrandHint == "" {
		a.BrandHint = "GOOGLE"
	}
	a.MfrKind, a.SvcKind = mfr, svc
	switch {
	case mfr != "":
		a.Kind = mfr
	case svc != "":
		a.Kind = svc
	default:
		a.Kind = AppearanceType(a.Appearance)
	}
}

// AppearanceType names the GAP appearance value, or "" when unknown.
func AppearanceType(v int) string {
	if v < 0 {
		return ""
	}
	switch v {
	case 0x0940:
		return "AUDIO"
	case 0x0941:
		return "EARBUD"
	case 0x0942:
		return "HEADSET"
	case 0x0943:
		return "HEADPHONES"
	case 0x0944:
		return "NECKBAND"
	case 0x03C1:
		return "KEYBOARD"
	case 0x03C2:
		return "MOUSE"
	case 0x03C3:
		return "JOYSTICK"
	case 0x03C4:
		return "GAMEPAD"
	case 0x03C5:
		return "TABLET"
	}
	names := [...]string{1: "PHONE", 2: "COMPUTER", 3: "WATCH", 4: "CLOCK", 5: "DISPLAY",
		6: "REMOTE", 7: "GLASSES", 8: "TAG", 9: "KEYRING", 10: "MEDIA PLAYER",
		11: "BARCODE SCANNER", 12: "THERMOMETER", 13: "HEART RATE", 14: "BLOOD PRESSURE",
		15: "HID", 16: "GLUCOSE METER", 17: "RUNNING SENSOR", 18: "CYCLING SENSOR"}
	if c := v >> 6; c >= 1 && c < len(names) {
		return names[c]
	}
	return ""
}

// appleKinds maps Apple continuity TLV types to kinds, listed most specific first.
var appleKinds = []struct {
	typ  byte
	kind string
}{
	{0x07, "AIRPODS"}, {0x0B, "WATCH"}, {0x12, "FIND MY"}, {0x02, "IBEACON"},
	{0x05, "AIRDROP"}, {0x0C, "HANDOFF"}, {0x0D, "HOTSPOT"}, {0x0E, "HOTSPOT"},
	{0x06, "HOMEKIT"}, {0x08, "HEY SIRI"}, {0x09, "AIRPLAY"}, {0x0A, "AIRPLAY"},
	{0x0F, "NEARBY ACTION"}, {0x10, "NEARBY"},
}

// serviceKind names the kind implied by a standard SIG service UUID, or "".
// The battery service alone says nothing and is ignored.
func serviceKind(uuid int) string {
	switch uuid {
	case 0x180D:
		return "HEART RATE"
	case 0x1812:
		return "HID"
	case 0x184E, 0x184F, 0x1850, 0x1853, 0x1855, 0x1856:
		return "LE AUDIO"
	case 0x181C, 0x181D:
		return "SCALE"
	case 0x1816:
		return "CYCLING"
	case 0x1814:
		return "RUNNING"
	case 0x1809:
		return "THERMOMETER"
	case 0x1808:
		return "GLUCOSE"
	}
	return ""
}

// appleInfo walks the [type][len][data] TLVs and returns the most specific
// kind, plus the proximity-pairing model and iBeacon info when a complete TLV
// carries them. A TLV whose length overruns the buffer still counts by its type.
func appleInfo(d []byte) (kind, model, beacon string) {
	best := len(appleKinds)
	beats := false
	for len(d) >= 2 {
		for i := 0; i < best; i++ {
			if appleKinds[i].typ == d[0] {
				best = i
				break
			}
		}
		l := int(d[1])
		if len(d) < 2+l {
			break
		}
		switch {
		case d[0] == 0x07 && l >= 3 && model == "":
			if m, ok := appleModels[uint16(d[3])<<8|uint16(d[4])]; ok {
				model, beats = m.name, m.beats
			}
		case d[0] == 0x02 && l == 21 && beacon == "":
			beacon = fmt.Sprintf("IBEACON %d/%d", int(d[18])<<8|int(d[19]), int(d[20])<<8|int(d[21]))
		}
		d = d[2+l:]
	}
	if best == len(appleKinds) {
		return "", model, beacon
	}
	kind = appleKinds[best].kind
	if kind == "AIRPODS" && beats {
		kind = "BEATS"
	}
	return kind, model, beacon
}

// mfrInfo hints a kind, model and beacon info from manufacturer data (after
// the company id).
func mfrInfo(company int, d []byte) (kind, model, beacon string) {
	if len(d) < 1 {
		return "", "", ""
	}
	switch company {
	case 0x004C:
		return appleInfo(d)
	case 0x0006:
		switch d[0] {
		case 0x01:
			return "WINDOWS", msModel(d), ""
		case 0x03:
			return "SWIFT PAIR", "", ""
		}
	}
	return "", "", ""
}

// sanitize keeps printable ASCII, upper-cased and trimmed.
func sanitize(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if c := s[i]; c >= 0x20 && c <= 0x7E {
			b.WriteByte(c)
		}
	}
	return strings.ToUpper(strings.TrimSpace(b.String()))
}

var companyNames = map[int]string{
	0x004C: "APPLE", 0x0006: "MICROSOFT", 0x0075: "SAMSUNG", 0x00E0: "GOOGLE",
	0x0087: "GARMIN", 0x0157: "HUAWEI", 0x038F: "XIAOMI", 0x0059: "NORDIC",
	0x000F: "BROADCOM", 0x02E5: "ESPRESSIF", 0x0171: "AMAZON", 0x009E: "BOSE",
}

// CompanyName maps a Bluetooth company id to a short maker name.
func CompanyName(id int) string {
	if id < 0 {
		return ""
	}
	if n, ok := companyNames[id]; ok {
		return n
	}
	return fmt.Sprintf("ID %04X", id)
}
