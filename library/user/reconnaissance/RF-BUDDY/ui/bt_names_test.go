package main

import "testing"

func TestNameKeywordTable(t *testing.T) {
	tests := []struct{ name, brand, kind string }{
		{"AIRPODS PRO", "APPLE", "AIRPODS"}, {"BEATS STUDIO", "BEATS", "AUDIO"},
		{"JOHN'S IPHONE", "APPLE", "PHONE"}, {"IPAD AIR", "APPLE", "TABLET"},
		{"MACBOOK PRO", "APPLE", "COMPUTER"}, {"MAGIC KEYBOARD", "APPLE", "KEYBOARD"},
		{"MAGIC MOUSE 2", "APPLE", "MOUSE"}, {"MAGIC TRACKPAD", "APPLE", "TRACKPAD"},
		{"APPLE WATCH 7", "APPLE", "WATCH"},
		{"GALAXY BUDS2 PRO", "SAMSUNG", "EARBUDS"}, {"GALAXY WATCH4", "SAMSUNG", "WATCH"},
		{"GALAXY TAB S8", "SAMSUNG", "TABLET"}, {"GALAXY S23", "SAMSUNG", "PHONE"},
		{"[TV] SAMSUNG 7 SERIES", "SAMSUNG", "TV"}, {"SAMSUNG TV Q80", "SAMSUNG", "TV"}, {"[TV]LIVING ROOM", "SAMSUNG", "TV"},
		{"[LG] WEBOS TV", "LG", "TV"}, {"LG TV 55", "LG", "TV"}, {"WEBOS TV", "LG", "TV"},
		{"SAMSUNG SOUNDBAR", "SAMSUNG", "OTHER"},
		{"JBL FLIP 5", "HARMAN JBL", "SPEAKER"},
		{"BOSE QC35", "BOSE", "AUDIO"}, {"LE-BOSE SOUNDLINK", "BOSE", "AUDIO"},
		{"SONY XM4", "SONY", "AUDIO"}, {"WH-1000XM4", "SONY", "AUDIO"}, {"WF-1000XM4", "SONY", "AUDIO"},
		{"LE_WH-1000XM5", "SONY", "AUDIO"}, {"LE_WF-C500", "SONY", "AUDIO"},
		{"PIXEL BUDS A", "GOOGLE", "EARBUDS"}, {"PIXEL 7", "GOOGLE", "PHONE"},
		{"NEST HUB", "GOOGLE", "SMART HOME"}, {"GOOGLE HOME MINI", "GOOGLE", "SPEAKER"},
		{"CHROMECAST", "GOOGLE", "TV"},
		{"FIRE TV STICK", "AMAZON", "TV"}, {"FIRETV CUBE", "AMAZON", "TV"}, {"AFTMM", "AMAZON", "TV"},
		{"ECHO DOT", "AMAZON", "SPEAKER"}, {"KINDLE 123", "AMAZON", "TABLET"},
		{"FITBIT", "FITBIT", "FITNESS"}, {"CHARGE 5", "FITBIT", "FITNESS"}, {"CHARGE 6", "FITBIT", "FITNESS"},
		{"VERSA 3", "FITBIT", "FITNESS"}, {"INSPIRE 2", "FITBIT", "FITNESS"},
		{"GARMIN EDGE", "GARMIN", "WATCH"}, {"FORERUNNER 245", "GARMIN", "WATCH"}, {"FENIX 7", "GARMIN", "WATCH"},
		{"VENU 2", "GARMIN", "WATCH"}, {"VIVOACTIVE 4", "GARMIN", "WATCH"},
		{"MI BAND 6", "XIAOMI", "FITNESS"}, {"SMART BAND 7", "XIAOMI", "FITNESS"},
		{"AMAZFIT GTS", "ZEPP", "WATCH"},
		{"HUAWEI P30", "HUAWEI", "OTHER"}, {"HONOR 50", "HONOR", "OTHER"},
		{"ONEPLUS 9", "ONEPLUS", "PHONE"}, {"OPPO A5", "OPPO", "PHONE"},
		{"REDMI NOTE", "XIAOMI", "PHONE"}, {"XIAOMI SPEAKER", "XIAOMI", "OTHER"},
		{"MX MASTER 3", "LOGITECH", "INPUT"}, {"MX KEYS", "LOGITECH", "INPUT"}, {"MX ANYWHERE 3", "LOGITECH", "INPUT"},
		{"LOGI M590", "LOGITECH", "INPUT"},
		{"JABRA ELITE", "JABRA", "HEADSET"},
		{"POLY VOYAGER", "POLY", "HEADSET"}, {"PLANTRONICS 5200", "POLY", "HEADSET"}, {"BACKBEAT PRO", "POLY", "HEADSET"},
		{"SENNHEISER HD", "SENNHEISER", "AUDIO"}, {"MOMENTUM 3", "SENNHEISER", "AUDIO"},
		{"SOUNDCORE LIFE", "ANKER", "AUDIO"}, {"ANKER A3", "ANKER", "AUDIO"},
		{"SKULLCANDY CRUSHER", "SKULLCANDY", "AUDIO"}, {"MARSHALL EMBERTON", "MARSHALL", "SPEAKER"},
		{"UE BOOM 3", "LOGITECH", "SPEAKER"}, {"WONDERBOOM 2", "LOGITECH", "SPEAKER"}, {"MEGABOOM 3", "LOGITECH", "SPEAKER"},
		{"SONOS ROAM", "SONOS", "SPEAKER"},
		{"TILE", "TILE", "TRACKER"}, {"CHIPOLO ONE", "CHIPOLO", "TRACKER"}, {"SMARTTAG2", "SAMSUNG", "TRACKER"}, {"GALAXY SMARTTAG", "SAMSUNG", "TRACKER"},
		{"AFTKA", "AMAZON", "TV"}, {"AFTSSS", "AMAZON", "TV"}, {"SWITCH", "NINTENDO", "GAME"}, {"LOGITECH K380", "LOGITECH", "INPUT"},
		{"NANOLEAF STRIP FCE", "NANOLEAF", "LIGHT"}, {"PHILIPS HUE LAMP", "PHILIPS", "LIGHT"}, {"HUE LIGHTSTRIP", "PHILIPS", "LIGHT"},
		{"GOVEE H6001", "GOVEE", "LIGHT"}, {"IHOSTER_1234", "GOVEE", "LIGHT"}, {"GVH5075_AB12", "GOVEE", "LIGHT"},
		{"WYZE LOCK", "WYZE", "SMART HOME"}, {"RING DOORBELL", "AMAZON", "SMART HOME"},
		{"TESLA MODEL 3", "TESLA", "CAR"}, {"OURA", "OURA", "RING"},
		{"WHOOP 4", "WHOOP", "FITNESS"}, {"POLAR H10", "POLAR", "FITNESS"}, {"PELOTON BIKE", "PELOTON", "FITNESS"},
		{"XBOX WIRELESS", "MICROSOFT", "GAME"}, {"SURFACE PRO", "MICROSOFT", "COMPUTER"},
		{"NINTENDO SWITCH", "NINTENDO", "GAME"}, {"JOY-CON (L)", "NINTENDO", "GAME"}, {"PRO CONTROLLER", "NINTENDO", "GAME"},
		{"DUALSENSE", "SONY", "GAME"}, {"DUALSHOCK 4", "SONY", "GAME"}, {"WIRELESS CONTROLLER", "SONY", "GAME"},
		{"HP LASERJET", "HP", "PRINTER"}, {"DIRECT-5A-HP OFFICEJET", "HP", "PRINTER"},
		{"CANON TS5000", "CANON", "PRINTER"}, {"EPSON XP-440", "EPSON", "PRINTER"}, {"BROTHER HL", "BROTHER", "PRINTER"},
		{"ROKU ULTRA", "ROKU", "TV"}, {"VIZIO SOUNDBAR", "VIZIO", "TV"}, {"TCL 55", "TCL", "TV"}, {"HISENSE U7", "HISENSE", "TV"},
		{"YEALINK T54", "YEALINK", "PHONE"},
		{"META QUEST", "META", "VR"}, {"QUEST 2", "META", "VR"}, {"OCULUS GO", "META", "VR"},
		{"RAY-BAN STORIES", "META", "GLASSES"},
	}
	for _, tc := range tests {
		if b, k := nameKeyword(tc.name); b != tc.brand || k != tc.kind {
			t.Errorf("%q: got %s/%s want %s/%s", tc.name, b, k, tc.brand, tc.kind)
		}
	}
}

func TestNameKeywordFalsePositives(t *testing.T) {
	for _, n := range []string{"SPRINGFIELD", "TILES", "MY NESTLE", "POLYGON", "METAL", "VENUE", "HUEY", "ECHOES",
		"MENTOS", "AFTERSHOKZ OPENMOVE", "CRAFT", "OPPORTUNITY", "STILE", "QUESTION", "VERSATILE", "INSPIRED",
		"THEIRING", "BOSEBALL", "MESSONY", "", "XBOXES", "TCLX", "AFTER", "AFTERWORK", "LOGIC BOARD", "NETWORK SWITCH", "DISHONOR", "SURFACES", "POLARIS", "JBLX"} {
		if b, k := nameKeyword(n); b != "" || k != "" {
			t.Errorf("%q wrongly matched %s/%s", n, b, k)
		}
	}
	for n, want := range map[string]string{"TILE MATE": "TILE", "MY-TILE": "TILE", "RING": "AMAZON", "FRONT RING 2": "AMAZON"} {
		if b, _ := nameKeyword(n); b != want {
			t.Errorf("%q: %q want %q", n, b, want)
		}
	}
}

func TestNameKeywordOrder(t *testing.T) {
	// First matching row wins.
	for n, want := range map[string]string{
		"JBL CHARGE 5":   "HARMAN JBL", // before FITBIT's CHARGE 5
		"BEATS AIRPODS":  "APPLE",      // AIRPODS row precedes BEATS
		"GALAXY BUDS":    "SAMSUNG",
		"SAMSUNG TV":     "SAMSUNG",
		"SONY WH-1000":   "SONY",
		"[LG] SAMSUNG X": "LG",
	} {
		if b, _ := nameKeyword(n); b != want {
			t.Errorf("%q: %q want %q", n, b, want)
		}
	}
}
