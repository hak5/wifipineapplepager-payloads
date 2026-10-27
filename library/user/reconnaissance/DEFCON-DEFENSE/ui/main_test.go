package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/color"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

type memoryReadWriteSeeker struct {
	data   []byte
	reader *bytes.Reader
	writes int
}

func newMemoryReadWriteSeeker(data []byte) *memoryReadWriteSeeker {
	copyData := append([]byte(nil), data...)
	return &memoryReadWriteSeeker{data: copyData, reader: bytes.NewReader(copyData)}
}

func (m *memoryReadWriteSeeker) Read(p []byte) (int, error) {
	return m.reader.Read(p)
}

func (m *memoryReadWriteSeeker) Write(p []byte) (int, error) {
	m.writes++
	position, _ := m.reader.Seek(0, io.SeekCurrent)
	end := int(position) + len(p)
	if end > len(m.data) {
		m.data = append(m.data, make([]byte, end-len(m.data))...)
	}
	copy(m.data[int(position):end], p)
	m.reader = bytes.NewReader(m.data)
	_, _ = m.reader.Seek(int64(end), io.SeekStart)
	return len(p), nil
}

func (m *memoryReadWriteSeeker) Seek(offset int64, whence int) (int64, error) {
	return m.reader.Seek(offset, whence)
}

type countingWriteSeeker struct {
	writes int
}

func (w *countingWriteSeeker) Write(p []byte) (int, error) {
	w.writes++
	return len(p), nil
}

func (w *countingWriteSeeker) Seek(int64, int) (int64, error) {
	return 0, nil
}

var _ io.WriteSeeker = (*countingWriteSeeker)(nil)

func TestCanvasToFramebufferRotationAndRGB565(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, screenWidth, screenHeight))
	img.SetRGBA(0, 0, red)
	img.SetRGBA(screenWidth-1, screenHeight-1, green)
	frame := canvasToFramebuffer(img)
	if len(frame) != frameBytes {
		t.Fatalf("frame length = %d, want %d", len(frame), frameBytes)
	}
	redIndex := (0*fbWidth + (fbWidth - 1)) * 2
	if frame[redIndex] == 0 && frame[redIndex+1] == 0 {
		t.Fatal("top-left canvas pixel did not map to rotated framebuffer")
	}
	greenIndex := ((screenWidth-1)*fbWidth + 0) * 2
	if frame[greenIndex] == 0 && frame[greenIndex+1] == 0 {
		t.Fatal("bottom-right canvas pixel did not map to rotated framebuffer")
	}
}

func TestPreviewStateExercisesAllPrimaryScreens(t *testing.T) {
	s := previewState()
	if len(s.Threats) < 2 {
		t.Fatalf("preview threats = %d, want at least 2", len(s.Threats))
	}
	if len(s.Evidence) < 3 {
		t.Fatalf("preview evidence = %d, want at least 3", len(s.Evidence))
	}
	if len(s.APs) < 3 || len(s.WatchList) < 2 {
		t.Fatalf("preview AP/watch rows = %d/%d, want at least 3/2", len(s.APs), len(s.WatchList))
	}
	if got := eventHeadline(s.Threats[0].Event, s.Threats[0].Deauth); got != "DEAUTHENTICATION ATTACK DETECTED" {
		t.Fatalf("headline = %q", got)
	}
}

func TestPortalHandlerServesIndexAndAssetsWithoutDirectoryListings(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "index.html"), []byte("<html>bridge-ready</html>"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "bridge.js"), []byte("window.bridgeReady=true;"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "private"), 0o700); err != nil {
		t.Fatal(err)
	}
	handler := portalHandler(root)

	indexReq := httptest.NewRequest(http.MethodGet, "/", nil)
	indexRes := httptest.NewRecorder()
	handler.ServeHTTP(indexRes, indexReq)
	if indexRes.Code != http.StatusOK || !strings.Contains(indexRes.Body.String(), "bridge-ready") {
		t.Fatalf("portal index status/body = %d/%q", indexRes.Code, indexRes.Body.String())
	}
	if got := indexRes.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("portal index cache policy = %q", got)
	}

	assetReq := httptest.NewRequest(http.MethodGet, "/bridge.js", nil)
	assetRes := httptest.NewRecorder()
	handler.ServeHTTP(assetRes, assetReq)
	if assetRes.Code != http.StatusOK || !strings.Contains(assetRes.Body.String(), "bridgeReady") {
		t.Fatalf("portal asset status/body = %d/%q", assetRes.Code, assetRes.Body.String())
	}

	dirReq := httptest.NewRequest(http.MethodGet, "/private/", nil)
	dirRes := httptest.NewRecorder()
	handler.ServeHTTP(dirRes, dirReq)
	if dirRes.Code != http.StatusNotFound {
		t.Fatalf("portal directory status = %d, want 404", dirRes.Code)
	}
}

func TestObservedAPAndUserWatchListNavigationAndActions(t *testing.T) {
	actionFile := filepath.Join(t.TempDir(), "ui_action.psv")
	a := &app{screen: screenGeneral, generalSelected: 1, actionFile: actionFile}
	state := previewState()

	if a.handleButton("A", state) || a.screen != screenAPWatch {
		t.Fatalf("Live RF row opened screen %d, want observed APs", a.screen)
	}
	a.apSelected = 1 // HOTEL-WIFI is observed but not watched in preview state.
	a.lastButton = ""
	if a.handleButton("A", state) {
		t.Fatal("watching an observed AP unexpectedly exited")
	}
	queued, err := os.ReadFile(actionFile)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(queued), "WATCH|ADD|HOTEL-WIFI|10:20:30:40:50:60|5GHz|44|-58\n"; got != want {
		t.Fatalf("observed AP action = %q, want %q", got, want)
	}

	a.lastButton = ""
	if a.handleButton("B", state) || a.screen != screenGeneral {
		t.Fatalf("B returned to screen %d, want general", a.screen)
	}
	a.generalSelected = 2
	a.lastButton = ""
	if a.handleButton("A", state) || a.screen != screenWatchList {
		t.Fatalf("Monitored Networks opened screen %d, want user watch list", a.screen)
	}
	a.watchSelected = 0
	a.lastButton = ""
	if a.handleButton("A", state) {
		t.Fatal("removing a saved AP unexpectedly exited")
	}
	queued, err = os.ReadFile(actionFile)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(queued), "WATCH|REMOVE|DEFCON-GUEST|AA:BB:CC:DD:EE:FF|2.4GHz|6|\n"; got != want {
		t.Fatalf("saved-list action = %q, want %q", got, want)
	}
	a.lastButton = ""
	if a.handleButton("RIGHT", state) || a.screen != screenAPWatch {
		t.Fatalf("RIGHT from user list opened screen %d, want observed APs", a.screen)
	}

	a.screen = screenWatchList
	a.lastButton = ""
	empty := state
	empty.WatchList = nil
	empty.WatchedAPs = map[string]bool{}
	empty.Watched = 0
	if a.handleButton("A", empty) || a.screen != screenAPWatch {
		t.Fatalf("A from empty user list opened screen %d, want observed APs", a.screen)
	}
}

func TestClearSessionRequiresRightThenAAndQueuesAction(t *testing.T) {
	actionFile := filepath.Join(t.TempDir(), "ui_action.psv")
	a := &app{screen: screenGeneral, generalSelected: 3, actionFile: actionFile}
	state := previewState()

	if a.handleButton("A", state) || a.screen != screenClearSession {
		t.Fatalf("Clear Session row opened screen %d, want confirmation", a.screen)
	}
	if _, err := os.Stat(actionFile); !os.IsNotExist(err) {
		t.Fatalf("clear action was queued before confirmation: %v", err)
	}
	if a.handleButton("B", state) || a.screen != screenGeneral {
		t.Fatalf("B returned to screen %d, want general", a.screen)
	}

	a.generalSelected = 3
	a.lastButton = ""
	if a.handleButton("A", state) || a.screen != screenClearSession {
		t.Fatalf("Clear Session row reopened screen %d, want confirmation", a.screen)
	}
	a.lastButton = ""
	if a.handleButton("A", state) || a.screen != screenClearSession {
		t.Fatalf("unarmed A returned to screen %d, want locked confirmation", a.screen)
	}
	if _, err := os.Stat(actionFile); !os.IsNotExist(err) {
		t.Fatalf("duplicate A queued clear without arming: %v", err)
	}
	if a.toast != "PRESS RIGHT TO ARM SESSION CLEAR" {
		t.Fatalf("unarmed A toast = %q", a.toast)
	}
	a.lastButton = ""
	if a.handleButton("RIGHT", state) || a.screen != screenClearSession {
		t.Fatalf("RIGHT arm returned to screen %d, want confirmation", a.screen)
	}
	if !time.Now().Before(a.clearArmedUntil) {
		t.Fatal("RIGHT did not arm the time-limited clear action")
	}
	a.lastButton = ""
	if a.handleButton("A", state) || a.screen != screenGeneral {
		t.Fatalf("armed A returned to screen %d, want general", a.screen)
	}
	queued, err := os.ReadFile(actionFile)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(queued), "CLEAR_SESSION\n"; got != want {
		t.Fatalf("clear action = %q, want %q", got, want)
	}
	if a.generalSelected != 0 || a.toast != "CLEARING ALERTS + PCAPS" {
		t.Fatalf("confirmed clear state = row %d, toast %q", a.generalSelected, a.toast)
	}
	if !a.clearArmedUntil.IsZero() {
		t.Fatal("clear arming state was not reset after confirmation")
	}
}

func TestGeneralMenuNavigationIncludesClearSession(t *testing.T) {
	a := &app{screen: screenGeneral}
	state := previewState()
	if a.handleButton("UP", state) || a.generalSelected != 3 {
		t.Fatalf("UP from first row selected %d, want Clear Session row 3", a.generalSelected)
	}
	a.lastButton = ""
	if a.handleButton("DOWN", state) || a.generalSelected != 0 {
		t.Fatalf("DOWN from Clear Session selected %d, want first row", a.generalSelected)
	}
}

func TestLoadWatchedAPsKeepsUserEntriesNotInCurrentObservations(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watched_aps.tsv")
	if err := os.WriteFile(path, []byte("aa:bb:cc:dd:ee:99\tManual AP\t165\t5GHz\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	list := loadWatchedAPs(path)
	if len(list) != 1 || list[0].BSSID != "AA:BB:CC:DD:EE:99" || list[0].SSID != "Manual AP" {
		t.Fatalf("loaded user list = %#v", list)
	}
	if !watchedAPSet(list)["AA:BB:CC:DD:EE:99"] {
		t.Fatal("manual user entry was not represented in watched-state lookup")
	}
}

func TestNormalizeButton(t *testing.T) {
	tests := map[string]string{
		"A\n":        "A",
		"Enter":      "A",
		"Escape":     "B",
		"ESC":        "B",
		"ArrowRight": "RIGHT",
		"arrow_left": "LEFT",
	}
	for input, want := range tests {
		if got := normalizeButton(input); got != want {
			t.Fatalf("normalizeButton(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestPagerLinuxKeyMapping(t *testing.T) {
	tests := map[uint16]string{
		304: "B",
		305: "A",
		103: "UP",
		108: "DOWN",
		105: "LEFT",
		106: "RIGHT",
		116: "POWER", // KEY_POWER: our input grab hides it from the stock app
		1:   "",
	}
	for code, want := range tests {
		if got := buttonForLinuxKey(code); got != want {
			t.Fatalf("buttonForLinuxKey(%d) = %q, want %q", code, got, want)
		}
	}
}

func TestDirectPagerInputAndFullNavigationFlow(t *testing.T) {
	inputPath := filepath.Join(t.TempDir(), "event0")
	eventSize, typeOffset := 16, 8
	if strconv.IntSize == 64 {
		eventSize, typeOffset = 24, 16
	}
	event := func(code uint16, value int32) []byte {
		b := make([]byte, eventSize)
		binary.LittleEndian.PutUint16(b[typeOffset:typeOffset+2], 1)
		binary.LittleEndian.PutUint16(b[typeOffset+2:typeOffset+4], code)
		binary.LittleEndian.PutUint32(b[typeOffset+4:typeOffset+8], uint32(value))
		return b
	}
	data := append(event(305, 1), event(305, 0)...)
	data = append(data, event(108, 1)...)
	data = append(data, event(108, 0)...)
	data = append(data, event(304, 1)...)
	if err := os.WriteFile(inputPath, data, 0o600); err != nil {
		t.Fatal(err)
	}
	buttons := make(chan string, 3)
	if err := readButtonDevice(context.Background(), inputPath, buttons); err != io.EOF {
		t.Fatalf("readButtonDevice error = %v, want EOF", err)
	}
	for i, want := range []string{"A", "DOWN", "B"} {
		select {
		case got := <-buttons:
			if got != want {
				t.Fatalf("button %d = %q, want %q", i, got, want)
			}
		default:
			t.Fatalf("button %d missing, want %q", i, want)
		}
	}

	a := &app{screen: screenGeneral}
	state := previewState()
	if a.handleButton("DOWN", state) || a.generalSelected != 1 {
		t.Fatalf("DOWN selected %d, want 1", a.generalSelected)
	}
	if a.handleButton("UP", state) || a.generalSelected != 0 {
		t.Fatalf("UP selected %d, want 0", a.generalSelected)
	}
	if a.handleButton("A", state) || a.screen != screenThreat {
		t.Fatalf("A opened screen %d, want threat", a.screen)
	}
	if a.handleButton("B", state) || a.screen != screenGeneral {
		t.Fatalf("B returned to screen %d, want general", a.screen)
	}
	if a.handleButton("A", state) || a.screen != screenThreat {
		t.Fatalf("A reopened screen %d, want threat", a.screen)
	}
	if a.handleButton("RIGHT", state) || a.screen != screenEvidence {
		t.Fatalf("RIGHT opened screen %d, want evidence", a.screen)
	}
	if a.handleButton("A", state) || a.screen != screenEvidenceDetail {
		t.Fatalf("A opened screen %d, want evidence detail", a.screen)
	}
	if a.handleButton("B", state) || a.screen != screenEvidence {
		t.Fatalf("B returned to screen %d, want evidence", a.screen)
	}
	a.lastButton = ""
	if a.handleButton("B", state) || a.screen != screenGeneral {
		t.Fatalf("B returned to screen %d, want general", a.screen)
	}
	a.lastButton = ""
	if !a.handleButton("B", state) {
		t.Fatal("B on general did not exit")
	}
}

func TestIdleInputReaderStopsOnContextCancellation(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- readButtonFile(ctx, reader, make(chan string, 1), time.Now())
	}()
	time.Sleep(20 * time.Millisecond)
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("idle input reader error = %v, want context canceled", err)
		}
	case <-time.After(time.Second):
		t.Fatal("idle input reader did not stop within its bounded select timeout")
	}
}

func TestEffectiveMonitoringExposesStaleAndDegradedState(t *testing.T) {
	now := time.Now()
	status, statusColor := effectiveMonitoring(liveState{Now: now, Monitoring: "ACTIVE", UpdatedEpoch: now.Unix()})
	if status != "ACTIVE" || statusColor != green {
		t.Fatalf("fresh status = %q/%#v, want ACTIVE/green", status, statusColor)
	}
	status, statusColor = effectiveMonitoring(liveState{Now: now, Monitoring: "ACTIVE", UpdatedEpoch: now.Add(-time.Minute).Unix()})
	if status != "STALE" || statusColor != yellow {
		t.Fatalf("stale status = %q/%#v, want STALE/yellow", status, statusColor)
	}
	status, statusColor = effectiveMonitoring(liveState{Now: now, Monitoring: "DEGRADED", UpdatedEpoch: now.Unix()})
	if status != "DEGRADED" || statusColor != yellow {
		t.Fatalf("failed status = %q/%#v, want DEGRADED/yellow", status, statusColor)
	}
}

func TestVirtualButtonHandlerQueuesPagerNavigation(t *testing.T) {
	buttons := make(chan string, 1)
	req := httptest.NewRequest(http.MethodPost, "/button?name=ArrowDown&token=test-token", nil)
	res := httptest.NewRecorder()
	virtualButtonHandler(buttons, "test-token").ServeHTTP(res, req)

	if res.Code != http.StatusNoContent {
		t.Fatalf("button status = %d, want %d", res.Code, http.StatusNoContent)
	}
	select {
	case got := <-buttons:
		if got != "DOWN" {
			t.Fatalf("queued button = %q, want DOWN", got)
		}
	default:
		t.Fatal("virtual button was not queued")
	}
}

func TestVirtualButtonHandlerRejectsMissingToken(t *testing.T) {
	buttons := make(chan string, 1)
	req := httptest.NewRequest(http.MethodPost, "/button?name=ArrowDown", nil)
	res := httptest.NewRecorder()
	virtualButtonHandler(buttons, "test-token").ServeHTTP(res, req)
	if res.Code != http.StatusUnauthorized {
		t.Fatalf("button status = %d, want %d", res.Code, http.StatusUnauthorized)
	}
	select {
	case button := <-buttons:
		t.Fatalf("unauthorized button was queued: %q", button)
	default:
	}
}

func TestUpdateDisplaySkipsIdenticalFrames(t *testing.T) {
	a := &app{renderer: newRenderer("")}
	state := previewState()
	writer := &countingWriteSeeker{}

	if err := a.updateDisplay(writer, state); err != nil {
		t.Fatal(err)
	}
	if err := a.updateDisplay(writer, state); err != nil {
		t.Fatal(err)
	}
	if writer.writes != 1 {
		t.Fatalf("identical frames wrote %d times, want 1", writer.writes)
	}
	if a.webRevision != 1 {
		t.Fatalf("identical frames published %d revisions, want 1", a.webRevision)
	}

	a.screen = screenThreat
	if err := a.updateDisplay(writer, state); err != nil {
		t.Fatal(err)
	}
	if writer.writes != 2 || a.webRevision != 2 {
		t.Fatalf("changed frame writes/revisions = %d/%d, want 2/2", writer.writes, a.webRevision)
	}
	if a.canvas == nil || len(a.displayedFrame) != frameBytes || len(a.frameScratch) != frameBytes {
		t.Fatal("renderer did not retain its reusable canvas and two framebuffer buffers")
	}
}

func TestRenderReusesCanvasAllocation(t *testing.T) {
	a := &app{renderer: newRenderer("")}
	first := a.render(previewState())
	a.screen = screenAPWatch
	second := a.render(previewState())
	if first != second {
		t.Fatal("render allocated a replacement full-screen canvas")
	}
}

func TestStateLoadersBoundCrowdedVenueMemory(t *testing.T) {
	dir := t.TempDir()
	var aps strings.Builder
	for i := 0; i < maxObservedAPs+25; i++ {
		fmt.Fprintf(&aps, "BSSID-%03d\tAP-%03d\t6\t2437\t-50\t1\t1\t2.4GHz\n", i, i)
	}
	apPath := filepath.Join(dir, "aps.tsv")
	if err := os.WriteFile(apPath, []byte(aps.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	loadedAPs := loadAPs(apPath)
	if len(loadedAPs) != maxObservedAPs || loadedAPs[0].BSSID != "BSSID-000" {
		t.Fatalf("bounded AP load = %d rows starting %q", len(loadedAPs), loadedAPs[0].BSSID)
	}

	var evidence strings.Builder
	evidence.WriteString("epoch\tid\tevent\tseverity\tssid\tbssid\tband\tchannel\tsignal_dbm\tduration_seconds\tsize_bytes\tsha256\tstatus\ttrigger\tpath\n")
	for i := 0; i < maxEvidenceRows+25; i++ {
		fmt.Fprintf(&evidence, "%d\t%d\tEVENT\tINFO\tAP\tBSSID\t2.4GHz\t6\t-50\t1\t1\tpending\tSAVED\tmanual\t/tmp/%d.pcap\n", 1000+i, i, i)
	}
	evidencePath := filepath.Join(dir, "evidence.tsv")
	if err := os.WriteFile(evidencePath, []byte(evidence.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	loadedEvidence := loadEvidence(evidencePath)
	if len(loadedEvidence) != maxEvidenceRows || loadedEvidence[0].Epoch != "1124" {
		t.Fatalf("bounded evidence load = %d rows newest %q", len(loadedEvidence), loadedEvidence[0].Epoch)
	}
}

func TestVirtualFrameRevisionIsUniqueAcrossRuns(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 2, 2))
	first := &app{webSession: "run-one"}
	second := &app{webSession: "run-two"}
	first.publishPNG(img)
	second.publishPNG(img)
	if first.webETag == second.webETag {
		t.Fatalf("separate UI runs reused ETag %q", first.webETag)
	}
}

func TestMaintainDisplayOwnershipOnlyRewritesDisplacedFrame(t *testing.T) {
	expected := bytes.Repeat([]byte{0x5a}, frameBytes)
	framebuffer := newMemoryReadWriteSeeker(expected)
	var scratch []byte

	if err := maintainDisplayOwnership(framebuffer, expected, &scratch); err != nil {
		t.Fatal(err)
	}
	if framebuffer.writes != 0 {
		t.Fatalf("owned frame wrote %d times, want 0", framebuffer.writes)
	}

	framebuffer.data[frameBytes/2] = 0x00
	framebuffer.reader = bytes.NewReader(framebuffer.data)
	if err := maintainDisplayOwnership(framebuffer, expected, &scratch); err != nil {
		t.Fatal(err)
	}
	if framebuffer.writes != 1 {
		t.Fatalf("displaced frame wrote %d times, want 1", framebuffer.writes)
	}
	if !bytes.Equal(framebuffer.data, expected) {
		t.Fatal("displaced framebuffer was not restored exactly")
	}
}

func TestRenderPreviewsCoverEveryTextLayoutState(t *testing.T) {
	dir := t.TempDir()
	a := &app{renderer: newRenderer(""), previewDir: dir}
	if err := a.renderPreviews(); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{
		"01-general.png",
		"02-threat.png",
		"03-evidence.png",
		"04-evidence-detail.png",
		"05-threat-clear.png",
		"06-evidence-empty.png",
		"07-stress-general.png",
		"08-stress-threat.png",
		"09-stress-evidence.png",
		"10-stress-evidence-detail.png",
		"11-stress-toast.png",
		"12-ap-watch-list.png",
		"13-stress-ap-watch-list.png",
		"14-my-watch-list.png",
		"17-clear-session.png",
		"15-observed-aps-empty.png",
		"16-my-watch-list-empty.png",
	} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Errorf("missing preview %s: %v", name, err)
		}
	}
}

func TestClearBadgeAndCaptureIconHaveDedicatedSpace(t *testing.T) {
	a := &app{renderer: newRenderer(""), screen: screenThreat}
	state := previewState()
	state.Threats = nil
	state.Capture = Capture{Status: "IDLE"}
	img := a.render(state)

	for y := 30; y < 87; y++ {
		for x := 87; x < 136; x++ {
			if got := img.RGBAAt(x, y); got != black {
				t.Fatalf("CLEAR badge escaped into title gutter at (%d,%d): %#v", x, y, got)
			}
		}
	}
	labelRight := passiveCaptureLabelX + textPixelWidth(passiveCaptureLabel, 1)
	iconX := labelRight + passiveCaptureIconGap
	if iconX-labelRight < passiveCaptureIconGap {
		t.Fatalf("capture icon gap = %d, want at least %d", iconX-labelRight, passiveCaptureIconGap)
	}
	if iconX+16 > 476 {
		t.Fatalf("capture icon right edge = %d, outside detail panel", iconX+16)
	}
}

func TestPanelTextDoesNotOverwriteBorders(t *testing.T) {
	a := &app{renderer: newRenderer("")}
	state := previewState()
	state.Evidence[0].Status = "VERIFICATION_PENDING"
	state.Evidence[0].Size = 9876543210

	a.screen = screenThreat
	threat := a.render(state)
	for _, x := range []int{4, 94, 225, 350, 475} {
		assertVerticalColor(t, threat, x, 173, 202, white)
	}

	a.screen = screenEvidence
	evidence := a.render(state)
	for _, x := range []int{4, 86, 170, 241, 323, 402, 475} {
		assertVerticalColor(t, evidence, x, 190, 219, cyan2)
	}
}

func TestRenderedButtonHintsMatchPhysicalPagerOrder(t *testing.T) {
	a := &app{renderer: newRenderer("")}
	state := previewState()
	tests := []struct {
		name   string
		screen screenKind
		y1     int
		y2     int
	}{
		{"general", screenGeneral, 194, 216},
		{"threat", screenThreat, 176, 197},
		{"observed APs", screenAPWatch, 192, 216},
		{"my watch list", screenWatchList, 192, 216},
		{"evidence", screenEvidence, 194, 215},
		{"evidence detail", screenEvidenceDetail, 190, 213},
		{"clear session", screenClearSession, 192, 216},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			a.screen = tt.screen
			img := a.render(state)
			redX := firstColorX(img, red, tt.y1, tt.y2)
			greenX := firstColorX(img, green, tt.y1, tt.y2)
			if redX < 0 || greenX < 0 {
				t.Fatalf("button colors missing: red x=%d green x=%d", redX, greenX)
			}
			if redX >= greenX {
				t.Fatalf("physical button order reversed: red B x=%d, green A x=%d", redX, greenX)
			}
		})
	}
}

func firstColorX(img *image.RGBA, want color.RGBA, y1, y2 int) int {
	for x := 0; x < img.Bounds().Dx(); x++ {
		for y := y1; y < y2; y++ {
			if img.RGBAAt(x, y) == want {
				return x
			}
		}
	}
	return -1
}

func assertVerticalColor(t *testing.T, img *image.RGBA, x, y1, y2 int, want color.RGBA) {
	t.Helper()
	for y := y1; y < y2; y++ {
		if got := img.RGBAAt(x, y); got != want {
			t.Fatalf("panel border overwritten at (%d,%d): got %#v want %#v", x, y, got, want)
		}
	}
}

// A power press exits from every screen, handing the button back to the stock
// Pager app, whose Power Menu performs the graceful shutdown.
func TestPowerExitsFromEveryScreen(t *testing.T) {
	for sc := screenGeneral; sc <= screenClearSession; sc++ {
		a := &app{screen: sc, actionFile: filepath.Join(t.TempDir(), "ui_action.psv")}
		if !a.handleButton("POWER", previewState()) {
			t.Fatalf("screen %d: POWER did not exit", sc)
		}
	}
}
