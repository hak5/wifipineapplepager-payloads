package main

// Model decoding for manufacturer-specific adverts.

type appleModelInfo struct {
	name  string
	beats bool // Beats-branded: the kind is BEATS rather than AIRPODS
}

// appleModels maps the Apple proximity-pairing model id (the two bytes after
// the prefix byte, as conventionally written) to a model name.
var appleModels = map[uint16]appleModelInfo{
	0x0220: {"AIRPODS", false},
	0x0F20: {"AIRPODS 2", false},
	0x1320: {"AIRPODS 3", false},
	0x0E20: {"AIRPODS PRO", false},
	0x1420: {"AIRPODS PRO 2", false},
	0x2420: {"AIRPODS PRO 2", false},
	0x0A20: {"AIRPODS MAX", false},
	0x0320: {"POWERBEATS 3", true},
	0x0B20: {"POWERBEATS PRO", true},
	0x0C20: {"BEATS SOLO PRO", true},
	0x1120: {"BEATS STUDIO BUDS", true},
	0x1620: {"STUDIO BUDS+", true},
	0x1020: {"BEATS FLEX", true},
	0x0520: {"BEATSX", true},
	0x0620: {"BEATS SOLO 3", true},
	0x0920: {"BEATS STUDIO 3", true},
	0x1220: {"BEATS FIT PRO", true},
}

// msDeviceTypes names the Microsoft CDP beacon device type (low 5 bits of
// the second payload byte).
var msDeviceTypes = map[byte]string{
	1: "XBOX ONE", 6: "IPHONE", 7: "IPAD", 8: "ANDROID", 9: "WINDOWS DESKTOP",
	11: "WINDOWS PHONE", 12: "LINUX", 13: "WINDOWS IOT", 14: "SURFACE HUB",
	15: "WINDOWS LAPTOP", 16: "WINDOWS TABLET",
}

// msModel decodes a Microsoft CDP beacon (d[0]==0x01) device type, or "".
func msModel(d []byte) string {
	if len(d) < 2 || d[0] != 0x01 {
		return ""
	}
	return msDeviceTypes[d[1]&0x1F]
}

// eddystoneFrame names an Eddystone frame type byte, or "".
func eddystoneFrame(b byte) string {
	switch b {
	case 0x00:
		return "UID"
	case 0x10:
		return "URL"
	case 0x20:
		return "TLM"
	case 0x30:
		return "EID"
	}
	return ""
}
