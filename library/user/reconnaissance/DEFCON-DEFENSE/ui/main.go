// DEFCON Defense custom full-screen UI for the WiFi Pineapple Pager.
//
// The Pager exposes a 222x480 RGB565 framebuffer rotated counter-clockwise
// onto its 480x222 landscape LCD. This application renders a 480x222 canvas,
// maps it into the device framebuffer, and receives physical buttons directly
// from evdev plus Virtual Pager buttons through the local HTTP bridge.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"io"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/image/font"
	"golang.org/x/image/font/inconsolata"
	"golang.org/x/image/math/fixed"
)

const (
	screenWidth   = 480
	screenHeight  = 222
	fbWidth       = 222
	fbHeight      = 480
	frameBytes    = fbWidth * fbHeight * 2
	textCellWidth = 8

	frameRowBytes         = fbWidth * 2
	ownershipSampleBytes  = 512
	ownershipPollInterval = 250 * time.Millisecond
	ownershipGuardWindow  = 8 * time.Second
	inputStartupDelay     = 250 * time.Millisecond
	inputReadTimeout      = 250 * time.Millisecond
	inputRetryDelay       = 500 * time.Millisecond
	inputDeviceLease      = 10 * time.Minute
	screenLongPollTimeout = 5 * time.Second
	monitorStaleAfter     = 45 * time.Second
	maxObservedAPs        = 256
	maxThreats            = 128
	maxWatchedAPs         = 256
	maxEvidenceRows       = 100

	passiveCaptureLabel   = "PASSIVE CAPTURE:"
	passiveCaptureLabelX  = 244
	passiveCaptureIconGap = 8
)

var (
	black  = color.RGBA{0x00, 0x00, 0x00, 0xff}
	white  = color.RGBA{0xf4, 0xf4, 0xee, 0xff}
	cyan   = color.RGBA{0x69, 0xd5, 0xf1, 0xff}
	cyan2  = color.RGBA{0x2d, 0xa8, 0xc4, 0xff}
	yellow = color.RGBA{0xff, 0xd5, 0x1f, 0xff}
	green  = color.RGBA{0x5d, 0xe1, 0x42, 0xff}
	red    = color.RGBA{0xff, 0x3f, 0x2f, 0xff}
	dim    = color.RGBA{0x75, 0x82, 0x87, 0xff}
)

type screenKind int

const (
	screenGeneral screenKind = iota
	screenThreat
	screenAPWatch
	screenWatchList
	screenEvidence
	screenEvidenceDetail
	screenClearSession
)

type AP struct {
	BSSID, SSID, Channel, Frequency, Signal, Seen, Packets, Band string
}

type WatchedAP struct {
	BSSID, SSID, Channel, Band string
}

type Threat struct {
	BSSID, SSID, Channel, Band, Signal, Packets, Event, Deauth, Level string
}

type Evidence struct {
	Epoch, ID, Event, Severity, SSID, BSSID, Band, Channel, Signal string
	Duration, Size                                                 int64
	Hash, Status, Trigger, Path                                    string
}

type Capture struct {
	Status, ID, Epoch, Path, Event, Severity, SSID, BSSID string
	Band, Channel, Signal, Duration, Trigger              string
}

type liveState struct {
	Now          time.Time
	Battery      int
	Monitoring   string
	UpdatedEpoch int64
	APs          []AP
	Threats      []Threat
	Evidence     []Evidence
	Capture      Capture
	Watched      int
	WatchList    []WatchedAP
	WatchedAPs   map[string]bool
	UsedBytes    int64
	StorageMax   int64
}

type renderer struct{}

type fileStamp struct {
	size    int64
	mtime   int64
	present bool
}

type stateFingerprint [4]fileStamp

type app struct {
	dataDir, pcapDir, actionFile, muteFile string
	framebuffer, previewDir                string
	inputDevice, readyFile                 string
	virtualListen, virtualTokenFile        string
	portalListen, portalRoot               string
	virtualToken                           string
	preview                                bool
	renderer                               *renderer
	webMu                                  sync.RWMutex
	webPNG                                 []byte
	webETag                                string
	webSession                             string
	webRevision                            uint64
	webUpdated                             chan struct{}

	mu               sync.Mutex
	screen           screenKind
	generalSelected  int
	threatSelected   int
	apSelected       int
	watchSelected    int
	evidenceSelected int
	evidencePage     int
	muted            bool
	toast            string
	toastUntil       time.Time
	lastButton       string
	lastButtonAt     time.Time
	clearArmedUntil  time.Time
	displayedFrame   []byte
	frameScratch     []byte
	canvas           *image.RGBA
}

func main() {
	var materialPath string
	a := &app{webUpdated: make(chan struct{}), webSession: newWebSession()}
	flag.StringVar(&a.dataDir, "data-dir", "/root/loot/defcon_defense", "DEFCON Defense state directory")
	flag.StringVar(&a.pcapDir, "pcap-dir", "/root/loot/pcap", "managed PCAP directory")
	flag.StringVar(&a.actionFile, "action-file", "", "action queue file")
	flag.StringVar(&a.muteFile, "mute-file", "", "alert mute state file")
	flag.StringVar(&a.framebuffer, "framebuffer", "/dev/fb0", "Pager framebuffer")
	flag.StringVar(&a.inputDevice, "input-device", "/dev/input/event0", "Pager evdev button device")
	flag.StringVar(&a.readyFile, "ready-file", "", "write after the first physical and Virtual Pager frames are ready")
	flag.StringVar(&a.previewDir, "preview-dir", "", "render the reference states as PNG files")
	flag.StringVar(&a.virtualListen, "virtual-listen", "172.16.52.1:1472", "Virtual Pager bridge listen address")
	flag.StringVar(&a.virtualTokenFile, "virtual-token-file", "", "file containing the Virtual Pager access token")
	flag.StringVar(&a.portalListen, "portal-listen", "172.16.52.1:1471", "Virtual Pager static portal listen address")
	flag.StringVar(&a.portalRoot, "portal-root", "/pineapple/ui", "Virtual Pager static portal root")
	flag.StringVar(&materialPath, "material-font", "/pineapple/ui/MaterialIcons-Regular.ttf", "Material Icons font path")
	flag.BoolVar(&a.preview, "preview", false, "use deterministic reference data")
	flag.Parse()

	if a.actionFile == "" {
		a.actionFile = filepath.Join(a.dataDir, "ui_action.psv")
	}
	if a.muteFile == "" {
		a.muteFile = filepath.Join(a.dataDir, "ui_muted")
	}
	if a.virtualTokenFile != "" {
		if token, err := os.ReadFile(a.virtualTokenFile); err == nil {
			a.virtualToken = strings.TrimSpace(string(token))
		}
	}
	a.renderer = newRenderer(materialPath)

	if a.previewDir != "" {
		if err := a.renderPreviews(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if err := a.run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func newWebSession() string {
	return fmt.Sprintf("%x-%x", time.Now().UnixNano(), os.Getpid())
}

func newRenderer(materialPath string) *renderer {
	// Keep the flag for command-line compatibility with older launchers. Icons
	// are drawn from the bundled bitmap face now, avoiding a multi-megabyte
	// TrueType parser and font allocation on the 256 MB Pager.
	_ = materialPath
	return &renderer{}
}

func (a *app) renderPreviews() error {
	if err := os.MkdirAll(a.previewDir, 0o755); err != nil {
		return err
	}
	a.preview = true
	state := a.loadState()
	clearState := state
	clearState.Threats = nil
	clearState.Capture = Capture{Status: "IDLE"}
	emptyEvidenceState := clearState
	emptyEvidenceState.Evidence = nil
	emptyEvidenceState.UsedBytes = 0
	emptyAPState := clearState
	emptyAPState.APs = nil
	emptyAPState.WatchList = nil
	emptyAPState.WatchedAPs = map[string]bool{}
	emptyAPState.Watched = 0

	stressState := previewState()
	stressState.Monitoring = "RECONNECTING TO MONITOR SERVICE"
	stressState.Threats = append([]Threat(nil), stressState.Threats...)
	stressState.Threats[0].SSID = "DEFCON-CONFERENCE-GUEST-NETWORK-WITH-A-LONG-NAME"
	stressState.Threats[0].Event = "UNRECOGNIZED_SECURITY_EVENT_WITH_A_VERY_LONG_NAME"
	stressState.Evidence = append([]Evidence(nil), stressState.Evidence...)
	stressState.Evidence[0].SSID = "DEFCON-CONFERENCE-GUEST-NETWORK-WITH-A-LONG-NAME"
	stressState.Evidence[0].Event = "UNRECOGNIZED_SECURITY_EVENT_WITH_A_VERY_LONG_NAME"
	stressState.Evidence[0].Status = "VERIFICATION_PENDING"
	stressState.Evidence[0].Size = 9876543210
	views := []struct {
		name   string
		screen screenKind
		state  liveState
		toast  string
	}{
		{"01-general.png", screenGeneral, state, ""},
		{"02-threat.png", screenThreat, state, ""},
		{"03-evidence.png", screenEvidence, state, ""},
		{"04-evidence-detail.png", screenEvidenceDetail, state, ""},
		{"05-threat-clear.png", screenThreat, clearState, ""},
		{"06-evidence-empty.png", screenEvidence, emptyEvidenceState, ""},
		{"07-stress-general.png", screenGeneral, stressState, ""},
		{"08-stress-threat.png", screenThreat, stressState, ""},
		{"09-stress-evidence.png", screenEvidence, stressState, ""},
		{"10-stress-evidence-detail.png", screenEvidenceDetail, stressState, ""},
		{"11-stress-toast.png", screenGeneral, stressState, "A VERY LONG OPERATOR MESSAGE THAT MUST REMAIN INSIDE THE TOAST PANEL WITHOUT OVERLAP"},
		{"12-ap-watch-list.png", screenAPWatch, state, ""},
		{"13-stress-ap-watch-list.png", screenAPWatch, stressState, ""},
		{"14-my-watch-list.png", screenWatchList, state, ""},
		{"15-observed-aps-empty.png", screenAPWatch, emptyAPState, ""},
		{"16-my-watch-list-empty.png", screenWatchList, emptyAPState, ""},
		{"17-clear-session.png", screenClearSession, state, ""},
	}
	for _, view := range views {
		a.screen = view.screen
		a.toast = view.toast
		if view.toast != "" {
			a.toastUntil = time.Now().Add(time.Minute)
		} else {
			a.toastUntil = time.Time{}
		}
		img := a.render(view.state)
		f, err := os.Create(filepath.Join(a.previewDir, view.name))
		if err != nil {
			return err
		}
		err = png.Encode(f, img)
		closeErr := f.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
	}
	return nil
}

func (a *app) run() error {
	fb, err := os.OpenFile(a.framebuffer, os.O_RDWR, 0)
	if err != nil {
		return fmt.Errorf("open framebuffer: %w", err)
	}
	defer fb.Close()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer cancel()
	// Keep only one unhandled press. The browser bridge also waits for the next
	// rendered revision before accepting another control, so accidental double
	// clicks cannot skip a screen or leave navigation apparently stuck.
	buttons := make(chan string, 1)
	if a.virtualListen != "" {
		go a.serveVirtualPager(ctx, buttons)
	}
	if a.portalListen != "" && a.portalRoot != "" {
		go a.servePortal(ctx)
	}
	go func() {
		// The A press that confirms the native payload launch can still be in the
		// Pager service's input path when this process opens evdev. Let that launch
		// gesture finish so every new session reliably starts on General instead
		// of accidentally opening Threat Details.
		timer := time.NewTimer(inputStartupDelay)
		defer timer.Stop()
		select {
		case <-timer.C:
			readButtons(ctx, a.inputDevice, buttons)
		case <-ctx.Done():
		}
	}()

	stateTicker := time.NewTicker(time.Second)
	defer stateTicker.Stop()
	ownershipTicker := time.NewTicker(ownershipPollInterval)
	ownershipDeadline := time.NewTimer(ownershipGuardWindow)
	ownershipC := ownershipTicker.C
	ownershipDeadlineC := ownershipDeadline.C
	defer func() {
		ownershipTicker.Stop()
		ownershipDeadline.Stop()
	}()

	state := a.loadState()
	stateFingerprint := a.stateFingerprint()
	displayedMinute := state.Now.Format("15:04")
	var framebufferScratch []byte
	if err := a.updateDisplay(fb, state); err != nil {
		return err
	}
	if a.readyFile != "" {
		if err := os.WriteFile(a.readyFile, []byte("ready\n"), 0o600); err != nil {
			return fmt.Errorf("write ready file: %w", err)
		}
		defer os.Remove(a.readyFile)
	}
	for {
		select {
		case <-ctx.Done():
			return nil
		case button := <-buttons:
			if a.handleButton(button, state) {
				return nil
			}
			if err := a.updateDisplay(fb, state); err != nil {
				return err
			}
		case <-stateTicker.C:
			now := time.Now()
			nextFingerprint := a.stateFingerprint()
			minuteChanged := now.Format("15:04") != displayedMinute
			stateChanged := nextFingerprint != stateFingerprint
			if stateChanged || minuteChanged {
				state = a.loadState()
				stateFingerprint = nextFingerprint
			} else {
				state.Now = now
			}
			if stateChanged || minuteChanged || a.timedRefreshNeeded(state, now) {
				if err := a.updateDisplay(fb, state); err != nil {
					return err
				}
				displayedMinute = state.Now.Format("15:04")
			}
		case <-ownershipDeadlineC:
			// The stock payload renderer can only race us during the launch
			// transition. It is already stopped before this process starts, so
			// continuing framebuffer reads forever just adds I/O to a long-lived
			// session and puts that I/O in the main input/render event loop.
			ownershipTicker.Stop()
			ownershipC = nil
			ownershipDeadlineC = nil
		case <-ownershipC:
			// The native payload runner paints its completion screen after this
			// application starts. Reclaim the display only when that renderer (or
			// another process) has displaced our already-rendered RGB565 frame.
			// A failed probe disables this startup-only guard instead of freezing
			// or terminating the operator interface.
			if err := maintainDisplayOwnership(fb, a.displayedFrame, &framebufferScratch); err != nil {
				ownershipTicker.Stop()
				ownershipC = nil
			}
		}
	}
}

func portalHandler(root string) http.Handler {
	files := http.FileServer(http.Dir(root))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		if r.URL.Path == "/" || r.URL.Path == "/index.html" {
			w.Header().Set("Cache-Control", "no-store")
			http.ServeFile(w, r, filepath.Join(root, "index.html"))
			return
		}
		// The bridge needs static files, never filesystem directory indexes.
		if strings.HasSuffix(r.URL.Path, "/") {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Cache-Control", "public, max-age=3600")
		files.ServeHTTP(w, r)
	})
}

func (a *app) servePortal(ctx context.Context) {
	server := &http.Server{
		Addr:              a.portalListen,
		Handler:           portalHandler(a.portalRoot),
		ReadHeaderTimeout: 2 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       15 * time.Second,
		MaxHeaderBytes:    8 << 10,
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	_ = server.ListenAndServe()
}

func (a *app) stateFingerprint() stateFingerprint {
	paths := []string{
		filepath.Join(a.dataDir, "ui_state.psv"),
		filepath.Join(a.dataDir, "pcap_index.tsv"),
		filepath.Join(a.dataDir, "pcap_capture.psv"),
		a.muteFile,
	}
	var fingerprint stateFingerprint
	for i, path := range paths {
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		fingerprint[i] = fileStamp{size: info.Size(), mtime: info.ModTime().UnixNano(), present: true}
	}
	return fingerprint
}

func (a *app) timedRefreshNeeded(state liveState, now time.Time) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.toast != "" {
		if !now.Before(a.toastUntil) {
			a.toast = ""
		}
		return true
	}
	return state.Capture.Status == "CAPTURING"
}

func (a *app) updateDisplay(fb io.WriteSeeker, state liveState) error {
	canvas := a.render(state)
	frame := canvasToFramebufferInto(canvas, a.frameScratch)
	if bytes.Equal(a.displayedFrame, frame) {
		a.frameScratch = frame
		return nil
	}
	if err := writeFramebuffer(fb, frame); err != nil {
		return err
	}
	a.displayedFrame, a.frameScratch = frame, a.displayedFrame
	// The physical display is the operator's primary surface. Commit it before
	// encoding the Virtual Pager image so a slow CPU can never strand the user
	// on the stock Payload Running/Complete screen.
	a.publishPNG(canvas)
	return nil
}

func maintainDisplayOwnership(fb io.ReadWriteSeeker, expected []byte, scratch *[]byte) error {
	if len(expected) == 0 {
		return nil
	}
	// One raw framebuffer row maps to one full-height canvas column. Sampling
	// the center row therefore checks the title, content, controls, and footer
	// in one small read while remaining sensitive to a stock full-screen repaint.
	offset := (screenWidth / 2) * frameRowBytes
	if cap(*scratch) < ownershipSampleBytes {
		*scratch = make([]byte, ownershipSampleBytes)
	} else {
		*scratch = (*scratch)[:ownershipSampleBytes]
	}
	if _, err := fb.Seek(int64(offset), io.SeekStart); err != nil {
		return fmt.Errorf("seek framebuffer for ownership check: %w", err)
	}
	if _, err := io.ReadFull(fb, *scratch); err != nil {
		return fmt.Errorf("read framebuffer for ownership check: %w", err)
	}
	if !bytes.Equal(*scratch, expected[offset:offset+ownershipSampleBytes]) {
		return writeFramebuffer(fb, expected)
	}
	return nil
}

func writeFramebuffer(fb io.WriteSeeker, frame []byte) error {
	if _, err := fb.Seek(0, io.SeekStart); err != nil {
		return fmt.Errorf("seek framebuffer: %w", err)
	}
	written, err := fb.Write(frame)
	if err != nil {
		return fmt.Errorf("write framebuffer: %w", err)
	}
	if written != len(frame) {
		return io.ErrShortWrite
	}
	return nil
}

func (a *app) publishPNG(img image.Image) {
	var b bytes.Buffer
	// The screen is tiny and only changes on interaction/state updates. Avoid
	// spending scarce Pager CPU on compression; USB transfer is faster than the
	// MIPS encoder and this makes the Virtual Pager frame available promptly.
	encoder := png.Encoder{CompressionLevel: png.NoCompression}
	if encoder.Encode(&b, img) != nil {
		return
	}
	// Each published byte slice is immutable. Screen handlers can therefore
	// retain the current slice after releasing webMu instead of allocating and
	// copying a 320 KB PNG on every long-poll response. The old slice remains
	// alive naturally until its final in-flight writer completes.
	encoded := b.Bytes()
	a.webMu.Lock()
	if a.webSession == "" {
		a.webSession = newWebSession()
	}
	a.webPNG = encoded
	a.webRevision++
	a.webETag = fmt.Sprintf("\"defcon-%s-%x\"", a.webSession, a.webRevision)
	if a.webUpdated != nil {
		close(a.webUpdated)
	}
	a.webUpdated = make(chan struct{})
	a.webMu.Unlock()
}

func (a *app) serveVirtualPager(ctx context.Context, buttons chan<- string) {
	mux := http.NewServeMux()
	screenClients := make(chan struct{}, 4)
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "DEFCON Defense UI active\n")
	})
	mux.HandleFunc("/screen.png", func(w http.ResponseWriter, r *http.Request) {
		if !virtualRequestAuthorized(r, a.virtualToken) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		select {
		case screenClients <- struct{}{}:
			defer func() { <-screenClients }()
		default:
			http.Error(w, "too many screen clients", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Expose-Headers", "ETag")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Content-Type", "image/png")
		clientETag := r.Header.Get("If-None-Match")
		if clientETag == "" {
			clientETag = r.URL.Query().Get("rev")
		}
		for {
			a.webMu.RLock()
			etag := a.webETag
			updated := a.webUpdated
			if etag == "" || clientETag != etag {
				b := a.webPNG
				a.webMu.RUnlock()
				if len(b) == 0 {
					http.Error(w, "screen not ready", http.StatusServiceUnavailable)
					return
				}
				w.Header().Set("ETag", etag)
				_, _ = w.Write(b)
				return
			}
			a.webMu.RUnlock()
			if r.URL.Query().Get("wait") == "1" && updated != nil {
				timer := time.NewTimer(screenLongPollTimeout)
				select {
				case <-updated:
					timer.Stop()
					continue
				case <-timer.C:
				case <-r.Context().Done():
					timer.Stop()
					return
				}
			}
			w.Header().Set("ETag", etag)
			w.WriteHeader(http.StatusNotModified)
			return
		}
	})
	mux.HandleFunc("/button", virtualButtonHandler(buttons, a.virtualToken))
	server := &http.Server{
		Addr:              a.virtualListen,
		Handler:           mux,
		ReadHeaderTimeout: 2 * time.Second,
		WriteTimeout:      screenLongPollTimeout + 3*time.Second,
		IdleTimeout:       15 * time.Second,
		MaxHeaderBytes:    8 << 10,
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	_ = server.ListenAndServe()
}

func virtualRequestAuthorized(r *http.Request, token string) bool {
	return token != "" && r.URL.Query().Get("token") == token
}

func virtualButtonHandler(buttons chan<- string, token string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
		w.Header().Set("Cache-Control", "no-store")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.Method != http.MethodPost {
			http.Error(w, "POST required", http.StatusMethodNotAllowed)
			return
		}
		if !virtualRequestAuthorized(r, token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		button := normalizeButton(r.URL.Query().Get("name"))
		switch button {
		case "A", "B", "UP", "DOWN", "LEFT", "RIGHT":
		default:
			http.Error(w, "invalid button", http.StatusBadRequest)
			return
		}
		select {
		case buttons <- button:
			w.WriteHeader(http.StatusNoContent)
		default:
			http.Error(w, "button queue busy", http.StatusServiceUnavailable)
		}
	}
}

func readButtons(ctx context.Context, inputDevice string, out chan<- string) {
	for ctx.Err() == nil {
		err := readButtonDevice(ctx, inputDevice, out)
		if ctx.Err() != nil {
			return
		}
		if err == nil || errors.Is(err, errInputLeaseExpired) {
			continue
		}
		timer := time.NewTimer(inputRetryDelay)
		select {
		case <-timer.C:
		case <-ctx.Done():
			timer.Stop()
			return
		}
	}
}

func readButtonDevice(ctx context.Context, inputDevice string, out chan<- string) error {
	f, err := os.Open(inputDevice)
	if err != nil {
		return err
	}
	defer f.Close()
	// Best effort: without the grab, buttons still work but the frozen
	// firmware menu may replay them after exit.
	_ = grabInput(int(f.Fd()))
	return readButtonFile(ctx, f, out, time.Now())
}

var errInputLeaseExpired = errors.New("input device lease expired")

func readButtonFile(ctx context.Context, f *os.File, out chan<- string, openedAt time.Time) error {
	fd := int(f.Fd())
	if err := syscall.SetNonblock(fd, true); err != nil {
		return fmt.Errorf("set input nonblocking: %w", err)
	}

	// Linux input_event is 16 bytes on the Pager's 32-bit MIPS userspace and
	// 24 bytes on a 64-bit test host because timeval follows native word size.
	eventSize, typeOffset := 16, 8
	if strconv.IntSize == 64 {
		eventSize, typeOffset = 24, 16
	}
	event := make([]byte, eventSize)
	offset := 0
	for {
		if err := waitForInput(ctx, fd, openedAt); err != nil {
			return err
		}
		n, readErr := syscall.Read(fd, event[offset:])
		if n > 0 {
			offset += n
		}
		if readErr != nil {
			if errors.Is(readErr, syscall.EINTR) || errors.Is(readErr, syscall.EAGAIN) || errors.Is(readErr, syscall.EWOULDBLOCK) {
				continue
			}
			return readErr
		}
		if n == 0 {
			return io.EOF
		}
		if offset < eventSize {
			continue
		}
		offset = 0
		eventType := binary.LittleEndian.Uint16(event[typeOffset : typeOffset+2])
		code := binary.LittleEndian.Uint16(event[typeOffset+2 : typeOffset+4])
		value := int32(binary.LittleEndian.Uint32(event[typeOffset+4 : typeOffset+8]))
		if eventType != 1 || value != 1 {
			continue
		}
		button := buttonForLinuxKey(code)
		if button == "" {
			continue
		}
		select {
		case out <- button:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func waitForInput(ctx context.Context, fd int, openedAt time.Time) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		if time.Since(openedAt) >= inputDeviceLease {
			return errInputLeaseExpired
		}
		var readSet syscall.FdSet
		if !setFD(fd, &readSet) {
			return fmt.Errorf("input descriptor %d exceeds select capacity", fd)
		}
		timeout := syscall.NsecToTimeval(inputReadTimeout.Nanoseconds())
		ready, err := selectReadable(fd, &readSet, &timeout)
		if err != nil {
			if errors.Is(err, syscall.EINTR) {
				continue
			}
			return err
		}
		if ready > 0 {
			return nil
		}
	}
}

func buttonForLinuxKey(code uint16) string {
	switch code {
	case 304: // BTN_SOUTH - physical red/B on the Pager
		return "B"
	case 305: // BTN_EAST - physical green/A on the Pager
		return "A"
	case 103: // KEY_UP
		return "UP"
	case 108: // KEY_DOWN
		return "DOWN"
	case 105: // KEY_LEFT
		return "LEFT"
	case 106: // KEY_RIGHT
		return "RIGHT"
	case 116: // KEY_POWER - same gpio-keys device, so our grab hides it from the stock app
		return "POWER"
	default:
		return ""
	}
}

func normalizeButton(raw string) string {
	button := strings.ToUpper(strings.TrimSpace(raw))
	button = strings.NewReplacer(" ", "", "_", "", "-", "").Replace(button)
	switch button {
	case "ENTER", "RETURN":
		return "A"
	case "ESC", "ESCAPE", "BACK":
		return "B"
	case "ARROWUP":
		return "UP"
	case "ARROWDOWN":
		return "DOWN"
	case "ARROWLEFT":
		return "LEFT"
	case "ARROWRIGHT":
		return "RIGHT"
	default:
		return button
	}
}

func (a *app) handleButton(button string, s liveState) (exit bool) {
	if button == "POWER" {
		// Exit and hand the power button back to the stock Pager app, whose
		// Power Menu performs the graceful shutdown.
		return true
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now()
	if button == a.lastButton && now.Sub(a.lastButtonAt) < 170*time.Millisecond {
		return false
	}
	a.lastButton, a.lastButtonAt = button, now

	switch a.screen {
	case screenGeneral:
		switch button {
		case "UP":
			a.generalSelected = (a.generalSelected + 3) % 4
		case "DOWN":
			a.generalSelected = (a.generalSelected + 1) % 4
		case "LEFT", "RIGHT":
			a.screen = screenEvidence
		case "A":
			switch a.generalSelected {
			case 0:
				a.screen = screenThreat
			case 1:
				a.screen = screenAPWatch
			case 2:
				a.screen = screenWatchList
			case 3:
				a.screen = screenClearSession
			}
		case "B":
			return true
		}
	case screenThreat:
		n := len(s.Threats)
		if n < 1 {
			n = 1
		}
		switch button {
		case "UP":
			a.threatSelected = (a.threatSelected + n - 1) % n
		case "DOWN":
			a.threatSelected = (a.threatSelected + 1) % n
		case "LEFT":
			a.screen = screenGeneral
		case "RIGHT":
			a.screen = screenEvidence
		case "A":
			if len(s.Threats) > 0 {
				t := s.Threats[a.threatSelected%len(s.Threats)]
				a.queueCapture(t)
				a.toast = "PASSIVE PCAP CAPTURE REQUESTED"
				a.toastUntil = now.Add(2 * time.Second)
			} else {
				a.toast = "NO ACTIVE THREAT TO CAPTURE"
				a.toastUntil = now.Add(2 * time.Second)
			}
		case "B":
			a.screen = screenGeneral
		}
	case screenAPWatch:
		n := len(s.APs)
		if n < 1 {
			n = 1
		}
		switch button {
		case "UP":
			a.apSelected = (a.apSelected + n - 1) % n
		case "DOWN":
			a.apSelected = (a.apSelected + 1) % n
		case "LEFT", "RIGHT":
			if len(s.APs) > 3 {
				pages := (len(s.APs) + 2) / 3
				page := a.apSelected / 3
				if button == "LEFT" {
					page = (page + pages - 1) % pages
				} else {
					page = (page + 1) % pages
				}
				a.apSelected = page * 3
			}
		case "A":
			if len(s.APs) == 0 {
				a.toast = "NO AP OBSERVATIONS AVAILABLE"
				a.toastUntil = now.Add(2 * time.Second)
				break
			}
			ap := s.APs[a.apSelected%len(s.APs)]
			operation := "ADD"
			message := "WATCH REQUESTED"
			if s.WatchedAPs[normalizeBSSID(ap.BSSID)] {
				operation = "REMOVE"
				message = "UNWATCH REQUESTED"
			}
			a.queueAction("WATCH", operation, ap.SSID, ap.BSSID, ap.Band, ap.Channel, ap.Signal)
			a.toast = fmt.Sprintf("%s: %s", message, trimCells(displaySSID(ap.SSID), 28))
			a.toastUntil = now.Add(2 * time.Second)
		case "B":
			a.screen = screenGeneral
		}
	case screenWatchList:
		n := len(s.WatchList)
		if n < 1 {
			n = 1
		}
		switch button {
		case "UP":
			a.watchSelected = (a.watchSelected + n - 1) % n
		case "DOWN":
			a.watchSelected = (a.watchSelected + 1) % n
		case "LEFT", "RIGHT":
			a.screen = screenAPWatch
		case "A":
			if len(s.WatchList) == 0 {
				a.screen = screenAPWatch
				break
			}
			watched := s.WatchList[a.watchSelected%len(s.WatchList)]
			a.queueAction("WATCH", "REMOVE", watched.SSID, watched.BSSID, watched.Band, watched.Channel, "")
			a.toast = fmt.Sprintf("UNWATCH REQUESTED: %s", trimCells(displaySSID(watched.SSID), 26))
			a.toastUntil = now.Add(2 * time.Second)
		case "B":
			a.screen = screenGeneral
		}
	case screenEvidence:
		n := len(s.Evidence)
		if n < 1 {
			n = 1
		}
		switch button {
		case "UP":
			a.evidenceSelected = (a.evidenceSelected + n - 1) % n
		case "DOWN":
			a.evidenceSelected = (a.evidenceSelected + 1) % n
		case "LEFT":
			if len(s.Evidence) <= 3 || a.evidencePage == 0 {
				a.screen = screenGeneral
			} else {
				a.evidencePage--
				a.evidenceSelected = a.evidencePage * 3
			}
		case "RIGHT":
			pages := (len(s.Evidence) + 2) / 3
			if pages > 1 {
				a.evidencePage = (a.evidencePage + 1) % pages
				a.evidenceSelected = a.evidencePage * 3
			} else {
				a.screen = screenGeneral
			}
		case "A":
			if len(s.Evidence) > 0 {
				a.screen = screenEvidenceDetail
			}
		case "B":
			a.screen = screenGeneral
		}
	case screenEvidenceDetail:
		switch button {
		case "A":
			if len(s.Evidence) > 0 {
				e := s.Evidence[a.evidenceSelected%len(s.Evidence)]
				a.queueAction("VERIFY", e.ID)
				a.toast = "SHA-256 VERIFICATION REQUESTED"
				a.toastUntil = now.Add(2 * time.Second)
			}
		case "B", "LEFT":
			a.screen = screenEvidence
		case "RIGHT":
			a.screen = screenGeneral
		}
	case screenClearSession:
		switch button {
		case "A":
			if !now.Before(a.clearArmedUntil) {
				a.toast = "PRESS RIGHT TO ARM SESSION CLEAR"
				a.toastUntil = now.Add(2 * time.Second)
				break
			}
			a.queueAction("CLEAR_SESSION")
			a.screen = screenGeneral
			a.generalSelected = 0
			a.threatSelected = 0
			a.evidenceSelected = 0
			a.evidencePage = 0
			a.clearArmedUntil = time.Time{}
			a.toast = "CLEARING ALERTS + PCAPS"
			a.toastUntil = now.Add(2 * time.Second)
		case "RIGHT":
			a.clearArmedUntil = now.Add(3 * time.Second)
			a.toast = "CLEAR ARMED: PRESS A WITHIN 3 SECONDS"
			a.toastUntil = a.clearArmedUntil
		case "B", "LEFT":
			a.clearArmedUntil = time.Time{}
			a.screen = screenGeneral
		}
	}
	return false
}

func (a *app) queueCapture(t Threat) {
	a.queueAction("CAPTURE", t.Event, t.SSID, t.BSSID, t.Band, t.Channel, t.Signal)
}

func (a *app) queueAction(fields ...string) {
	for i := range fields {
		fields[i] = cleanField(fields[i])
	}
	tmp := a.actionFile + ".tmp"
	_ = os.MkdirAll(filepath.Dir(a.actionFile), 0o755)
	if os.WriteFile(tmp, []byte(strings.Join(fields, "|")+"\n"), 0o600) == nil {
		_ = os.Rename(tmp, a.actionFile)
	}
}

func cleanField(s string) string {
	s = strings.Map(func(r rune) rune {
		switch r {
		case '|', '\t', '\r', '\n':
			return ' '
		}
		return r
	}, s)
	if len(s) > 128 {
		s = s[:128]
	}
	return s
}

func (a *app) loadState() liveState {
	if a.preview {
		return previewState()
	}
	s := liveState{Now: time.Now(), Battery: 0, Monitoring: "ACTIVE", StorageMax: 256 * 1024 * 1024}
	s.Battery = readIntFile("/sys/class/power_supply/bq27546-0/capacity")
	if s.Battery < 0 || s.Battery > 100 {
		s.Battery = 0
	}
	ui := readKeyValues(filepath.Join(a.dataDir, "ui_state.psv"))
	if ui["monitoring"] != "" {
		s.Monitoring = strings.ToUpper(ui["monitoring"])
	}
	s.UpdatedEpoch, _ = strconv.ParseInt(ui["updated_epoch"], 10, 64)
	s.APs = loadAPs(filepath.Join(a.dataDir, "latest_snapshot.tsv"))
	s.Threats = loadThreats(filepath.Join(a.dataDir, "latest_threats.tsv"))
	s.Evidence = loadEvidence(filepath.Join(a.dataDir, "pcap_index.tsv"))
	s.Capture = loadCapture(filepath.Join(a.dataDir, "pcap_capture.psv"))
	s.WatchList = loadWatchedAPs(filepath.Join(a.dataDir, "watched_aps.tsv"))
	s.WatchedAPs = watchedAPSet(s.WatchList)
	s.Watched = len(s.WatchList)
	for _, e := range s.Evidence {
		s.UsedBytes += e.Size
	}
	a.muted = fileExists(a.muteFile)
	return s
}

func previewState() liveState {
	now := time.Date(2026, 8, 10, 14, 32, 23, 0, time.Local)
	return liveState{
		Now: now, Battery: 83, Monitoring: "ACTIVE", Watched: 2,
		WatchedAPs: map[string]bool{
			"AA:BB:CC:DD:EE:FF": true,
			"DE:AD:BE:EF:00:01": true,
		},
		WatchList: []WatchedAP{
			{"AA:BB:CC:DD:EE:FF", "DEFCON-GUEST", "6", "2.4GHz"},
			{"DE:AD:BE:EF:00:01", "CONFERENCE", "11", "2.4GHz"},
		},
		StorageMax: 512 * 1024 * 1024, UsedBytes: 48 * 1024 * 1024,
		APs: []AP{
			{"AA:BB:CC:DD:EE:FF", "DEFCON-GUEST", "6", "2437", "-41", "", "1522", "2.4GHz"},
			{"10:20:30:40:50:60", "HOTEL-WIFI", "44", "5220", "-58", "", "812", "5GHz"},
			{"DE:AD:BE:EF:00:01", "CONFERENCE", "11", "2462", "-65", "", "390", "2.4GHz"},
		},
		Threats: []Threat{
			{"AA:BB:CC:DD:EE:FF", "DEFCON-GUEST", "6", "2.4GHz", "-41", "1522", "DEAUTH_ACTIVITY", "4", "red"},
			{"10:20:30:40:50:60", "HOTEL-WIFI", "44", "5GHz", "-58", "812", "TRUSTED_SSID_NEW_BSSID", "0", "red"},
		},
		Capture: Capture{"CAPTURING", "preview", strconv.FormatInt(now.Unix(), 10), "/root/loot/pcap/preview.pcap", "DEAUTH_ACTIVITY", "HIGH", "DEFCON-GUEST", "AA:BB:CC:DD:EE:FF", "2.4GHz", "6", "-41", "30", "automatic"},
		Evidence: []Evidence{
			{strconv.FormatInt(now.Unix(), 10), "1", "DEAUTH_ACTIVITY", "HIGH", "DEFCON-GUEST", "AA:BB:CC:DD:EE:FF", "2.4GHz", "6", "-41", 23, 18 * 1024 * 1024, "pending", "SAVED", "automatic", "/root/loot/pcap/deauth.pcap"},
			{strconv.FormatInt(now.Add(-84*time.Minute).Unix(), 10), "2", "TRUSTED_SSID_NEW_BSSID", "HIGH", "HOTEL-WIFI", "10:20:30:40:50:60", "5GHz", "44", "-58", 30, 22 * 1024 * 1024, "pending", "SAVED", "automatic", "/root/loot/pcap/twin.pcap"},
			{strconv.FormatInt(now.Add(-165*time.Minute).Unix(), 10), "3", "NEW_BSSID", "REVIEW", "CONFERENCE", "DE:AD:BE:EF:00:01", "2.4GHz", "11", "-65", 30, 8 * 1024 * 1024, "pending", "SAVED", "manual", "/root/loot/pcap/probe.pcap"},
		},
	}
}

func loadAPs(path string) []AP {
	rows := readTSV(path, maxObservedAPs, false)
	out := make([]AP, 0, len(rows))
	for _, row := range rows {
		if len(row) < 8 {
			continue
		}
		out = append(out, AP{row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7]})
	}
	return out
}

func loadWatchedAPs(path string) []WatchedAP {
	out := []WatchedAP{}
	for _, row := range readTSV(path, maxWatchedAPs, false) {
		if len(row) < 1 {
			continue
		}
		for len(row) < 4 {
			row = append(row, "")
		}
		if bssid := normalizeBSSID(row[0]); bssid != "" {
			out = append(out, WatchedAP{bssid, row[1], row[2], row[3]})
		}
	}
	return out
}

func watchedAPSet(watched []WatchedAP) map[string]bool {
	out := make(map[string]bool, len(watched))
	for _, ap := range watched {
		if bssid := normalizeBSSID(ap.BSSID); bssid != "" {
			out[bssid] = true
		}
	}
	return out
}

func normalizeBSSID(bssid string) string {
	return strings.ToUpper(strings.TrimSpace(bssid))
}

func loadThreats(path string) []Threat {
	rows := readTSV(path, maxThreats, false)
	out := make([]Threat, 0, len(rows))
	for _, row := range rows {
		if len(row) < 9 || row[0] == "" {
			continue
		}
		out = append(out, Threat{row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8]})
	}
	sort.SliceStable(out, func(i, j int) bool {
		return out[i].Level == "red" && out[j].Level != "red"
	})
	return out
}

func loadEvidence(path string) []Evidence {
	rows := readTSV(path, maxEvidenceRows, true)
	out := make([]Evidence, 0, len(rows))
	for _, row := range rows {
		if len(row) < 15 || row[0] == "epoch" || row[12] != "SAVED" {
			continue
		}
		duration, _ := strconv.ParseInt(row[9], 10, 64)
		size, _ := strconv.ParseInt(row[10], 10, 64)
		out = append(out, Evidence{row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8], duration, size, row[11], row[12], row[13], row[14]})
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, _ := strconv.ParseInt(out[i].Epoch, 10, 64)
		b, _ := strconv.ParseInt(out[j].Epoch, 10, 64)
		return a > b
	})
	return out
}

func loadCapture(path string) Capture {
	b, err := os.ReadFile(path)
	if err != nil {
		return Capture{Status: "IDLE"}
	}
	f := strings.Split(strings.TrimSpace(string(b)), "|")
	for len(f) < 13 {
		f = append(f, "")
	}
	return Capture{f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12]}
}

func readTSV(path string, maxRows int, keepLast bool) [][]string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	rows := make([][]string, 0, maxRows)
	next := 0
	wrapped := false
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		row := strings.Split(scanner.Text(), "\t")
		if maxRows <= 0 || len(rows) < maxRows {
			rows = append(rows, row)
			continue
		}
		if !keepLast {
			break
		}
		rows[next] = row
		next = (next + 1) % maxRows
		wrapped = true
	}
	if scanner.Err() != nil {
		return nil
	}
	if wrapped && next != 0 {
		ordered := make([][]string, 0, len(rows))
		ordered = append(ordered, rows[next:]...)
		ordered = append(ordered, rows[:next]...)
		return ordered
	}
	return rows
}

func readKeyValues(path string) map[string]string {
	out := map[string]string{}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		key, value, ok := strings.Cut(s.Text(), "=")
		if ok {
			out[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	return out
}

func readIntFile(path string) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return -1
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		return -1
	}
	return n
}

func countRows(path string) int {
	f, err := os.Open(path)
	if err != nil {
		return 0
	}
	defer f.Close()
	n := 0
	s := bufio.NewScanner(f)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line != "" && !strings.HasPrefix(line, "#") {
			n++
		}
	}
	return n
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func (a *app) render(s liveState) *image.RGBA {
	if a.canvas == nil {
		a.canvas = image.NewRGBA(image.Rect(0, 0, screenWidth, screenHeight))
	}
	img := a.canvas
	draw.Draw(img, img.Bounds(), image.NewUniform(black), image.Point{}, draw.Src)
	a.mu.Lock()
	defer a.mu.Unlock()
	switch a.screen {
	case screenThreat:
		a.renderThreat(img, s)
	case screenAPWatch:
		a.renderAPWatch(img, s)
	case screenWatchList:
		a.renderWatchList(img, s)
	case screenEvidence:
		a.renderEvidence(img, s)
	case screenEvidenceDetail:
		a.renderEvidenceDetail(img, s)
	case screenClearSession:
		a.renderClearSession(img, s)
	default:
		a.renderGeneral(img, s)
	}
	if a.toast != "" && time.Now().Before(a.toastUntil) {
		r := image.Rect(0, 92, screenWidth, 123)
		fill(img, r, black)
		stroke(img, r, 1, green)
		drawCentered(img, 99, trimCells(a.toast, 56), green, true)
	}
	return img
}

func (a *app) renderGeneral(img *image.RGBA, s liveState) {
	drawTextWide(img, 10, 8, "DEFCON DEFENSE", yellow, true)
	a.drawStatus(img, s, 296)
	hLine(img, 9, 471, 33, cyan2)

	redCount := 0
	for _, t := range s.Threats {
		if t.Level == "red" {
			redCount++
		}
	}
	state, stateColor := "CLEAR", green
	if redCount > 0 {
		state, stateColor = "HIGH THREAT", red
	} else if len(s.Threats) > 0 {
		state, stateColor = "REVIEW", yellow
	}
	drawText(img, 12, 44, "THREAT STATE:", cyan, false, 1)
	drawText(img, 145, 44, state, stateColor, true, 1)
	drawText(img, 292, 44, "MONITORING:", cyan, false, 1)
	monitoring, monitoringColor := effectiveMonitoring(s)
	drawTextBox(img, image.Rect(405, 40, 471, 62), 405, 44, trimCells(monitoring, 8), monitoringColor, true, 1)
	drawText(img, 12, 67, "BANDS:", cyan, false, 1)
	drawText(img, 80, 67, "2.4 GHZ + 5 GHZ", green, true, 1)
	hLine(img, 9, 471, 90, cyan2)

	rows := []struct{ left, right string }{
		{"1. Threats", fmt.Sprintf("%d active", len(s.Threats))},
		{"2. AP Watch List", fmt.Sprintf("%d discovered", len(s.APs))},
		{"3. Monitored Networks", fmt.Sprintf("%d watched", s.Watched)},
		{"4. Clear Session", "alerts + PCAPs"},
	}
	y := []int{93, 116, 139, 162}
	for i, row := range rows {
		fg := cyan
		if i == a.generalSelected {
			fill(img, image.Rect(9, y[i]-1, 471, y[i]+21), yellow)
			fg = black
			drawText(img, 15, y[i]+2, ">", black, true, 1)
		}
		drawText(img, 38, y[i]+2, row.left, fg, i == a.generalSelected, 1)
		drawTextRightBox(img, image.Rect(300, y[i], 453, y[i]+19), y[i]+2, row.right, fg, i == a.generalSelected)
	}
	hLine(img, 9, 471, 188, cyan2)
	// Match the physical Pager: red B is left of green A.
	drawText(img, 14, 199, "B", red, true, 1)
	drawText(img, 35, 199, "EXIT", white, true, 1)
	drawText(img, 145, 199, "A", green, true, 1)
	drawText(img, 165, 199, "OPEN", white, true, 1)
	drawText(img, 263, 199, "LEFT/RIGHT", yellow, true, 1)
	drawText(img, 386, 199, "PAGE", white, true, 1)
}

func (a *app) renderClearSession(img *image.RGBA, s liveState) {
	drawTextWide(img, 10, 8, "CLEAR SESSION", yellow, true)
	a.drawStatus(img, s, 296)
	hLine(img, 9, 471, 33, cyan2)

	armed := time.Now().Before(a.clearArmedUntil)
	if armed {
		drawCentered(img, 48, "CLEAR ARMED - PRESS A NOW", red, true)
	} else {
		drawCentered(img, 48, "DELETION LOCKED - PRESS RIGHT TO ARM", yellow, true)
	}
	drawText(img, 38, 79, "THIS REMOVES:", cyan, true, 1)
	drawText(img, 58, 102, "CURRENT ALERT HISTORY", white, true, 1)
	drawText(img, 58, 124, "ALL MANAGED PCAP FILES", white, true, 1)
	drawText(img, 38, 153, "WATCHED APS, BASELINE, AND TRUSTED RULES STAY SAVED", green, true, 1)

	stroke(img, image.Rect(4, 188, 476, 219), 1, cyan2)
	vLine(img, 112, 188, 219, cyan2)
	vLine(img, 322, 188, 219, cyan2)
	drawButtonHint(img, 14, 196, "B", "CANCEL", white)
	if armed {
		drawButtonHint(img, 128, 196, "A", "CONFIRM CLEAR", red)
	} else {
		drawButtonHint(img, 128, 196, "A", "LOCKED", dim)
	}
	drawTextBox(img, image.Rect(330, 189, 474, 218), 334, 197, "RIGHT ARM (3 SEC)", yellow, true, 1)
}

func (a *app) renderAPWatch(img *image.RGBA, s liveState) {
	drawText(img, 10, 7, "OBSERVED APS", yellow, true, 1)
	page, pages := 1, 1
	if len(s.APs) > 0 {
		if a.apSelected >= len(s.APs) {
			a.apSelected = 0
		}
		pages = (len(s.APs) + 2) / 3
		page = a.apSelected/3 + 1
	}
	total := fmt.Sprintf("%d SEEN | %d WATCHED | PAGE %d/%d", len(s.APs), s.Watched, page, pages)
	drawTextRightBox(img, image.Rect(180, 4, 471, 25), 9, trimCells(total, 35), cyan, true)
	hLine(img, 4, 476, 27, cyan2)
	drawText(img, 12, 34, "STATE", cyan, true, 1)
	drawText(img, 104, 34, "NETWORK / BSSID", cyan, true, 1)
	drawText(img, 316, 34, "BAND / CH", cyan, true, 1)
	drawText(img, 416, 34, "SIGNAL", cyan, true, 1)
	hLine(img, 4, 476, 49, cyan2)

	if len(s.APs) == 0 {
		drawCentered(img, 84, "NO AP OBSERVATIONS YET", white, true)
		drawCentered(img, 106, "WAIT FOR THE NEXT PASSIVE RECON UPDATE", cyan, false)
		a.apSelected = 0
	} else {
		start := (page - 1) * 3
		for row := 0; row < 3 && start+row < len(s.APs); row++ {
			i := start + row
			ap := s.APs[i]
			y := 54 + row*37
			selected := i == a.apSelected
			fg := white
			stateColor := dim
			stateLabel := "AVAILABLE"
			if s.WatchedAPs[normalizeBSSID(ap.BSSID)] {
				stateColor = green
				stateLabel = "WATCHED"
			}
			if selected {
				fill(img, image.Rect(4, y-3, 476, y+30), yellow)
				fg = black
				stateColor = black
				drawText(img, 8, y, ">", black, true, 1)
			}
			drawTextBox(img, image.Rect(24, y-2, 101, y+15), 25, y, stateLabel, stateColor, true, 1)
			drawTextBox(img, image.Rect(104, y-2, 313, y+15), 104, y, trimCells(displaySSID(ap.SSID), 25), fg, true, 1)
			drawTextBox(img, image.Rect(316, y-2, 412, y+15), 316, y, trimCells(ap.Band+" / "+ap.Channel, 11), fg, true, 1)
			drawTextRightBox(img, image.Rect(416, y-2, 471, y+15), y, trimCells(ap.Signal+"dBm", 7), fg, true)
			drawTextBox(img, image.Rect(104, y+14, 313, y+30), 104, y+15, trimCells(ap.BSSID, 22), fg, false, 1)
		}
	}

	hLine(img, 4, 476, 165, cyan2)
	drawText(img, 10, 172, "A TOGGLES PASSIVE MONITORING FOR THE SELECTED AP", green, true, 1)
	stroke(img, image.Rect(4, 188, 476, 219), 1, cyan2)
	for _, x := range []int{91, 255, 390} {
		vLine(img, x, 188, 219, cyan2)
	}
	drawButtonHint(img, 12, 196, "B", "BACK", white)
	drawButtonHint(img, 101, 196, "A", "WATCH / UNWATCH", white)
	drawTextBox(img, image.Rect(262, 189, 388, 218), 265, 197, "UP/DOWN SELECT", white, true, 1)
	drawTextBox(img, image.Rect(397, 189, 474, 218), 398, 197, "L/R PAGE", white, true, 1)
}

func (a *app) renderWatchList(img *image.RGBA, s liveState) {
	drawText(img, 10, 7, "MY WATCH LIST", yellow, true, 1)
	page, pages := 1, 1
	if len(s.WatchList) > 0 {
		if a.watchSelected >= len(s.WatchList) {
			a.watchSelected = 0
		}
		pages = (len(s.WatchList) + 2) / 3
		page = a.watchSelected/3 + 1
	}
	total := fmt.Sprintf("%d SAVED AP%s | PAGE %d/%d", len(s.WatchList), pluralS(len(s.WatchList)), page, pages)
	drawTextRightBox(img, image.Rect(250, 4, 471, 25), 9, total, cyan, true)
	hLine(img, 4, 476, 27, cyan2)
	drawText(img, 12, 34, "NETWORK / BSSID", cyan, true, 1)
	drawText(img, 318, 34, "BAND / CH", cyan, true, 1)
	drawText(img, 424, 34, "STATE", cyan, true, 1)
	hLine(img, 4, 476, 49, cyan2)

	if len(s.WatchList) == 0 {
		drawCentered(img, 81, "YOUR WATCH LIST IS EMPTY", white, true)
		drawCentered(img, 104, "PRESS A OR RIGHT TO ADD FROM OBSERVED APS", green, true)
		a.watchSelected = 0
	} else {
		start := (page - 1) * 3
		for row := 0; row < 3 && start+row < len(s.WatchList); row++ {
			i := start + row
			ap := s.WatchList[i]
			y := 54 + row*37
			selected := i == a.watchSelected
			fg := white
			stateColor := green
			if selected {
				fill(img, image.Rect(4, y-3, 476, y+30), yellow)
				fg = black
				stateColor = black
				drawText(img, 8, y, ">", black, true, 1)
			}
			drawTextBox(img, image.Rect(25, y-2, 314, y+15), 25, y, trimCells(displaySSID(ap.SSID), 34), fg, true, 1)
			drawTextBox(img, image.Rect(318, y-2, 420, y+15), 318, y, trimCells(ap.Band+" / "+ap.Channel, 12), fg, true, 1)
			drawTextBox(img, image.Rect(424, y-2, 474, y+15), 424, y, "ON", stateColor, true, 1)
			drawTextBox(img, image.Rect(25, y+14, 314, y+30), 25, y+15, trimCells(ap.BSSID, 34), fg, false, 1)
		}
	}

	hLine(img, 4, 476, 165, cyan2)
	drawText(img, 10, 172, "EDIT SAVED APS OR ADD FROM CURRENT OBSERVATIONS", green, true, 1)
	stroke(img, image.Rect(4, 188, 476, 219), 1, cyan2)
	for _, x := range []int{91, 251, 388} {
		vLine(img, x, 188, 219, cyan2)
	}
	drawButtonHint(img, 12, 196, "B", "BACK", white)
	drawButtonHint(img, 101, 196, "A", "REMOVE", white)
	drawTextBox(img, image.Rect(258, 189, 386, 218), 260, 197, "UP/DOWN SELECT", white, true, 1)
	drawTextBox(img, image.Rect(395, 189, 474, 218), 396, 197, "RIGHT ADD", white, true, 1)
}

func pluralS(n int) string {
	if n == 1 {
		return ""
	}
	return "S"
}

func effectiveMonitoring(s liveState) (string, color.RGBA) {
	status := strings.ToUpper(strings.TrimSpace(s.Monitoring))
	if status == "" {
		status = "STARTING"
	}
	if s.UpdatedEpoch > 0 && s.Now.Sub(time.Unix(s.UpdatedEpoch, 0)) > monitorStaleAfter {
		status = "STALE"
	}
	switch status {
	case "ACTIVE":
		return status, green
	case "DEGRADED", "STARTING", "STALE":
		return status, yellow
	default:
		return status, red
	}
}

func (a *app) renderThreat(img *image.RGBA, s liveState) {
	drawText(img, 7, 4, "DEFCON DEFENSE", yellow, true, 1)
	a.drawStatus(img, s, 210)
	hLine(img, 5, 475, 22, white)

	var t Threat
	hasThreat := len(s.Threats) > 0
	if hasThreat {
		if a.threatSelected >= len(s.Threats) {
			a.threatSelected = 0
		}
		t = s.Threats[a.threatSelected]
	}
	fillColor := red
	cardTitle, cardSub := "HIGH", "THREAT"
	mainTitle, affected := "NO ACTIVE THREAT DETECTED", "ALL MONITORED NETWORKS"
	if hasThreat {
		mainTitle = eventHeadline(t.Event, t.Deauth)
		affected = displaySSID(t.SSID)
	} else {
		fillColor, cardTitle, cardSub = green, "CLEAR", "STATE"
	}
	stroke(img, image.Rect(7, 30, 87, 87), 2, fillColor)
	drawTextFitted(img, image.Rect(9, 31, 85, 65), 14, 37, cardTitle, fillColor, true, 2)
	drawTextBox(img, image.Rect(9, 64, 85, 85), 14, 65, cardSub, fillColor, true, 1)
	if hasThreat {
		a.renderer.drawIcon(img, 99, 32, "\ue002", 28, red)
	}
	drawText(img, 136, 32, trimCells(mainTitle, 41), fillColor, true, 1)
	drawText(img, 136, 57, "AFFECTED NETWORK:", white, true, 1)
	drawText(img, 136, 72, trimCells(affected, 36), fillColor, true, 1)
	hLine(img, 5, 475, 94, white)
	vLine(img, 232, 96, 171, white)

	bssid, channel, signal, auth := "--", "--", "--", "0/0"
	if hasThreat {
		bssid, channel, signal = t.BSSID, t.Channel+" ("+strings.TrimSuffix(t.Band, "GHz")+"GHz)", t.Signal+"dBm"
		auth = fmt.Sprintf("1/%d", max(1, countSSID(s.APs, t.SSID)))
	}
	drawMetric(img, 9, 104, "BSSID:", bssid, cyan)
	drawMetric(img, 9, 122, "CHANNEL:", channel, cyan)
	drawMetric(img, 9, 140, "SIGNAL:", signal, green)
	drawMetric(img, 9, 158, "AUTH APS:", auth, yellow)

	eventTime := s.Now.Format("15:04")
	duration := "ACTIVE"
	evidenceStatus := captureLabel(s.Capture, t.BSSID, s.Evidence)
	if s.Capture.Status == "CAPTURING" {
		if epoch, err := strconv.ParseInt(s.Capture.Epoch, 10, 64); err == nil {
			elapsed := int64(s.Now.Sub(time.Unix(epoch, 0)).Seconds())
			if elapsed < 0 {
				elapsed = 0
			}
			duration = fmt.Sprintf("00:%02d", elapsed)
		}
	}
	drawMetricAt(img, 244, 356, 104, "EVENT TIME:", eventTime, cyan)
	drawMetricAt(img, 244, 356, 122, "DURATION:", duration, cyan)
	drawMetricAt(img, 244, 356, 140, "EVIDENCE:", trimCells(evidenceStatus, 14), red)
	drawTextBox(img, image.Rect(244, 156, 374, 173), passiveCaptureLabelX, 158, passiveCaptureLabel, white, true, 1)
	passiveIconX := passiveCaptureLabelX + textPixelWidth(passiveCaptureLabel, 1) + passiveCaptureIconGap
	a.renderer.drawIcon(img, passiveIconX, 156, "\ue1da", 16, green)

	stroke(img, image.Rect(4, 173, 476, 202), 1, white)
	for _, x := range []int{94, 225, 350} {
		vLine(img, x, 173, 202, white)
	}
	drawButtonHint(img, 12, 180, "B", "BACK", white)
	drawButtonHint(img, 103, 180, "A", "INVESTIGATE", cyan)
	a.renderer.drawIcon(img, 239, 178, "\ue5c4", 20, cyan)
	drawText(img, 263, 181, "GENERAL", cyan, true, 1)
	a.renderer.drawIcon(img, 360, 178, "\ue5c8", 20, cyan)
	drawText(img, 385, 181, "EVIDENCE", cyan, true, 1)
	hLine(img, 7, 140, 212, green)
	hLine(img, 343, 475, 212, green)
	drawCentered(img, 205, "UP/DOWN: NEXT/PREV ALERT", green, true)
}

func (a *app) renderEvidence(img *image.RGBA, s liveState) {
	drawText(img, 10, 7, "EVIDENCE", yellow, true, 1)
	total := fmt.Sprintf("%d PCAPS · %s / %s", len(s.Evidence), humanBytes(s.UsedBytes), humanBytes(s.StorageMax))
	drawTextRightBox(img, image.Rect(158, 4, 471, 25), 9, trimCells(total, 38), cyan, true)
	hLine(img, 4, 476, 27, cyan2)
	columns := []struct {
		x int
		t string
	}{{25, "TIME"}, {101, "THREAT"}, {199, "SSID"}, {343, "SIZE"}, {410, "STATUS"}}
	for _, c := range columns {
		drawText(img, c.x, 35, c.t, cyan, true, 1)
	}
	hLine(img, 4, 476, 50, cyan2)

	if len(s.Evidence) == 0 {
		drawCentered(img, 87, "NO SAVED PCAP EVIDENCE", white, true)
		drawCentered(img, 108, "HIGH-CONFIDENCE THREATS CAPTURE AUTOMATICALLY", cyan, false)
	} else {
		if a.evidenceSelected >= len(s.Evidence) {
			a.evidenceSelected = 0
		}
		a.evidencePage = a.evidenceSelected / 3
		start := a.evidencePage * 3
		for row := 0; row < 3 && start+row < len(s.Evidence); row++ {
			i := start + row
			e := s.Evidence[i]
			y := 55 + row*27
			fg := white
			if i == a.evidenceSelected {
				fill(img, image.Rect(4, y-2, 476, y+21), yellow)
				fg = black
				drawText(img, 9, y+1, ">", black, true, 1)
			}
			drawText(img, 26, y+1, evidenceTime(e.Epoch), fg, true, 1)
			drawText(img, 101, y+1, trimCells(eventShort(e.Event), 12), fg, true, 1)
			drawText(img, 199, y+1, trimCells(displaySSID(e.SSID), 17), fg, true, 1)
			drawTextBox(img, image.Rect(343, y-1, 409, y+20), 343, y+1, trimCells(humanBytes(e.Size), 8), fg, true, 1)
			statusColor := green
			if i == a.evidenceSelected {
				statusColor = black
			}
			drawTextBox(img, image.Rect(410, y-1, 475, y+20), 410, y+1, trimCells(e.Status, 8), statusColor, true, 1)
		}
	}
	hLine(img, 4, 476, 164, cyan2)
	drawText(img, 11, 174, "DOWNLOAD VIA VIRTUAL PAGER", green, true, 1)
	stroke(img, image.Rect(4, 190, 476, 219), 1, cyan2)
	for _, x := range []int{86, 170, 241, 323, 402} {
		vLine(img, x, 190, 219, cyan2)
	}
	drawTextBox(img, image.Rect(5, 191, 85, 218), 9, 197, "B", red, true, 1)
	drawTextBox(img, image.Rect(5, 191, 85, 218), 26, 197, "BACK", white, true, 1)
	drawTextBox(img, image.Rect(87, 191, 169, 218), 91, 197, "A", green, true, 1)
	drawTextBox(img, image.Rect(87, 191, 169, 218), 108, 197, "DETAILS", white, true, 1)
	a.renderer.drawIcon(img, 177, 195, "\ue5c4", 18, cyan)
	drawText(img, 200, 198, "PAGE", white, true, 1)
	a.renderer.drawIcon(img, 248, 195, "\ue5c8", 18, cyan)
	drawText(img, 271, 198, "PAGE", white, true, 1)
	a.renderer.drawIcon(img, 330, 195, "\ue5d8", 18, green)
	drawText(img, 352, 198, "SELECT", white, true, 1)
	a.renderer.drawIcon(img, 405, 195, "\ue5db", 18, green)
	drawTextBox(img, image.Rect(403, 191, 475, 218), 427, 198, "SELECT", white, true, 1)
}

func (a *app) renderEvidenceDetail(img *image.RGBA, s liveState) {
	drawText(img, 10, 5, "EVIDENCE DETAIL", yellow, true, 1)
	drawTextRight(img, 470, 5, "SAVED PCAP", green, true)
	hLine(img, 4, 476, 27, cyan2)
	if len(s.Evidence) == 0 {
		drawCentered(img, 94, "NO EVIDENCE SELECTED", white, true)
		return
	}
	e := s.Evidence[a.evidenceSelected%len(s.Evidence)]
	drawMetricWide(img, 12, 42, "THREAT:", eventShort(e.Event), red)
	drawMetricWide(img, 12, 61, "NETWORK:", displaySSID(e.SSID), cyan)
	drawMetricWide(img, 12, 80, "BSSID:", e.BSSID, cyan)
	drawMetricWide(img, 12, 99, "BAND / CHANNEL:", e.Band+" / "+e.Channel, cyan)
	drawMetricWide(img, 12, 118, "TIME:", evidenceDateTime(e.Epoch), cyan)
	drawMetricWide(img, 12, 137, "DURATION / SIZE:", fmt.Sprintf("%ds / %s", e.Duration, humanBytes(e.Size)), white)
	hash := e.Hash
	if hash == "" {
		hash = "pending"
	}
	drawMetricWide(img, 12, 156, "SHA-256:", trimCells(hash, 34), yellow)
	hLine(img, 4, 476, 183, cyan2)
	drawText(img, 11, 194, "B", red, true, 1)
	drawText(img, 30, 194, "BACK", white, true, 1)
	drawText(img, 95, 194, "A", green, true, 1)
	drawText(img, 114, 194, "VERIFY SHA-256", white, true, 1)
	drawText(img, 289, 194, "DOWNLOAD: VIRTUAL PAGER", cyan, true, 1)
}

func (a *app) drawStatus(img *image.RGBA, s liveState, startX int) {
	a.renderer.drawIcon(img, startX, 3, "\ue63e", 20, cyan)
	a.renderer.drawIcon(img, startX+43, 3, "\ue050", 20, cyan)
	stroke(img, image.Rect(startX+78, 5, startX+117, 22), 1, cyan)
	drawTextBox(img, image.Rect(startX+79, 5, startX+116, 22), startX+84, 6, trimCells(fmt.Sprintf("%d%%", s.Battery), 4), green, true, 1)
	drawTextRight(img, 469, 5, s.Now.Format("15:04"), cyan, true)
}

func (r *renderer) drawIcon(img *image.RGBA, x, y int, glyph string, size int, c color.RGBA) {
	_ = r
	label := "?"
	scale := 1
	switch glyph {
	case "\ue002":
		label, scale = "!", 2
	case "\ue1da":
		label = "PC"
	case "\ue5c4":
		label = "<"
	case "\ue5c8":
		label = ">"
	case "\ue5d8":
		label = "^"
	case "\ue5db":
		label = "v"
	case "\ue63e":
		label = "RF"
	case "\ue050":
		label = "AL"
	}
	if size < 20 {
		scale = 1
	}
	drawText(img, x, y+max(0, (size-16)/2), label, c, true, scale)
}

func drawText(img *image.RGBA, x, y int, text string, c color.RGBA, bold bool, scale int) {
	face := font.Face(inconsolata.Regular8x16)
	if bold {
		face = inconsolata.Bold8x16
	}
	if scale <= 1 {
		d := font.Drawer{Dst: img, Src: image.NewUniform(c), Face: face, Dot: fixed.P(x, y+13)}
		d.DrawString(text)
		return
	}
	w := max(1, len([]rune(text))*8)
	tmp := image.NewRGBA(image.Rect(0, 0, w, 16))
	d := font.Drawer{Dst: tmp, Src: image.NewUniform(c), Face: face, Dot: fixed.P(0, 13)}
	d.DrawString(text)
	for sy := 0; sy < tmp.Bounds().Dy(); sy++ {
		for sx := 0; sx < tmp.Bounds().Dx(); sx++ {
			px := tmp.RGBAAt(sx, sy)
			if px.A == 0 || (px.R == 0 && px.G == 0 && px.B == 0) {
				continue
			}
			fill(img, image.Rect(x+sx*scale, y+sy*scale, x+(sx+1)*scale, y+(sy+1)*scale), c)
		}
	}
}

func textPixelWidth(text string, scale int) int {
	return len([]rune(text)) * textCellWidth * max(1, scale)
}

func drawTextBox(img *image.RGBA, box image.Rectangle, x, y int, text string, c color.RGBA, bold bool, scale int) {
	box = box.Intersect(img.Bounds())
	if box.Empty() {
		return
	}
	clipped, ok := img.SubImage(box).(*image.RGBA)
	if !ok {
		return
	}
	drawText(clipped, x, y, text, c, bold, scale)
}

func drawTextFitted(img *image.RGBA, box image.Rectangle, x, y int, text string, c color.RGBA, bold bool, scale int) {
	box = box.Intersect(img.Bounds())
	if box.Empty() || x >= box.Max.X || y >= box.Max.Y {
		return
	}
	face := font.Face(inconsolata.Regular8x16)
	if bold {
		face = inconsolata.Bold8x16
	}
	sourceWidth := max(1, len([]rune(text))*textCellWidth)
	tmp := image.NewRGBA(image.Rect(0, 0, sourceWidth, 16))
	d := font.Drawer{Dst: tmp, Src: image.NewUniform(c), Face: face, Dot: fixed.P(0, 13)}
	d.DrawString(text)
	destWidth := min(sourceWidth*max(1, scale), box.Max.X-x)
	destHeight := 16 * max(1, scale)
	for dy := 0; dy < destHeight && y+dy < box.Max.Y; dy++ {
		for dx := 0; dx < destWidth && x+dx < box.Max.X; dx++ {
			sx := dx * sourceWidth / destWidth
			sy := dy / max(1, scale)
			p := tmp.RGBAAt(sx, sy)
			if p.A == 0 || (p.R == 0 && p.G == 0 && p.B == 0) {
				continue
			}
			img.SetRGBA(x+dx, y+dy, c)
		}
	}
}

func drawTextWide(img *image.RGBA, x, y int, text string, c color.RGBA, bold bool) {
	face := font.Face(inconsolata.Regular8x16)
	if bold {
		face = inconsolata.Bold8x16
	}
	sourceWidth := max(1, len([]rune(text))*8)
	tmp := image.NewRGBA(image.Rect(0, 0, sourceWidth, 16))
	d := font.Drawer{Dst: tmp, Src: image.NewUniform(c), Face: face, Dot: fixed.P(0, 13)}
	d.DrawString(text)
	destWidth := (sourceWidth*5 + 3) / 4
	for dy := 0; dy < 16; dy++ {
		for dx := 0; dx < destWidth; dx++ {
			sx := dx * 4 / 5
			p := tmp.RGBAAt(sx, dy)
			if p.A == 0 || (p.R == 0 && p.G == 0 && p.B == 0) {
				continue
			}
			if x+dx < screenWidth {
				img.SetRGBA(x+dx, y+dy, c)
			}
		}
	}
}

func drawTextRight(img *image.RGBA, right, y int, text string, c color.RGBA, bold bool) {
	drawText(img, right-textPixelWidth(text, 1), y, text, c, bold, 1)
}

func drawTextRightBox(img *image.RGBA, box image.Rectangle, y int, text string, c color.RGBA, bold bool) {
	text = trimCells(text, box.Dx()/textCellWidth)
	drawTextBox(img, box, box.Max.X-textPixelWidth(text, 1), y, text, c, bold, 1)
}

func drawCentered(img *image.RGBA, y int, text string, c color.RGBA, bold bool) {
	drawText(img, (screenWidth-textPixelWidth(text, 1))/2, y, text, c, bold, 1)
}

func drawMetric(img *image.RGBA, x, y int, label, value string, valueColor color.RGBA) {
	drawText(img, x, y, label, white, true, 1)
	drawText(img, x+78, y, trimCells(value, 17), valueColor, true, 1)
}

func drawMetricAt(img *image.RGBA, labelX, valueX, y int, label, value string, valueColor color.RGBA) {
	drawText(img, labelX, y, label, white, true, 1)
	drawTextBox(img, image.Rect(valueX, y-1, 472, y+16), valueX, y, trimCells(value, (472-valueX)/textCellWidth), valueColor, true, 1)
}

func drawMetricWide(img *image.RGBA, x, y int, label, value string, valueColor color.RGBA) {
	drawText(img, x, y, label, white, true, 1)
	drawText(img, x+145, y, trimCells(value, 39), valueColor, true, 1)
}

func drawButtonHint(img *image.RGBA, x, y int, key, label string, labelColor color.RGBA) {
	keyColor := green
	if key == "B" {
		keyColor = red
	}
	drawText(img, x, y, key, keyColor, true, 1)
	drawText(img, x+23, y, label, labelColor, true, 1)
}

func fill(img *image.RGBA, rect image.Rectangle, c color.RGBA) {
	draw.Draw(img, rect.Intersect(img.Bounds()), image.NewUniform(c), image.Point{}, draw.Src)
}

func stroke(img *image.RGBA, rect image.Rectangle, width int, c color.RGBA) {
	fill(img, image.Rect(rect.Min.X, rect.Min.Y, rect.Max.X, rect.Min.Y+width), c)
	fill(img, image.Rect(rect.Min.X, rect.Max.Y-width, rect.Max.X, rect.Max.Y), c)
	fill(img, image.Rect(rect.Min.X, rect.Min.Y, rect.Min.X+width, rect.Max.Y), c)
	fill(img, image.Rect(rect.Max.X-width, rect.Min.Y, rect.Max.X, rect.Max.Y), c)
}

func hLine(img *image.RGBA, x1, x2, y int, c color.RGBA) { fill(img, image.Rect(x1, y, x2, y+1), c) }
func vLine(img *image.RGBA, x, y1, y2 int, c color.RGBA) { fill(img, image.Rect(x, y1, x+1, y2), c) }

func canvasToFramebuffer(img *image.RGBA) []byte {
	return canvasToFramebufferInto(img, nil)
}

func canvasToFramebufferInto(img *image.RGBA, out []byte) []byte {
	if cap(out) < frameBytes {
		out = make([]byte, frameBytes)
	} else {
		out = out[:frameBytes]
	}
	for y := 0; y < screenHeight; y++ {
		row := img.Pix[y*img.Stride:]
		for x := 0; x < screenWidth; x++ {
			src := x * 4
			v := uint16(row[src]>>3)<<11 | uint16(row[src+1]>>2)<<5 | uint16(row[src+2]>>3)
			// The physical landscape canvas is the device framebuffer rotated
			// counter-clockwise: fb(x=221-y, y=x) == canvas(x,y).
			i := (x*fbWidth + (fbWidth - 1 - y)) * 2
			out[i] = byte(v)
			out[i+1] = byte(v >> 8)
		}
	}
	return out
}

func eventHeadline(event, deauth string) string {
	if n, _ := strconv.Atoi(deauth); n > 0 || event == "DEAUTH_ACTIVITY" {
		return "DEAUTHENTICATION ATTACK DETECTED"
	}
	switch event {
	case "TRUSTED_SSID_NEW_BSSID", "WATCHED_SSID_NEW_BSSID":
		return "POSSIBLE EVIL TWIN DETECTED"
	case "TRUSTED_BSSID_SSID_CHANGE", "WATCHED_BSSID_SSID_CHANGE":
		return "KNOWN ACCESS POINT IDENTITY CHANGED"
	case "TRUSTED_AP_CHANNEL_CHANGE", "WATCHED_AP_CHANNEL_CHANGE":
		return "KNOWN ACCESS POINT CHANNEL CHANGED"
	case "NEW_BSSID":
		return "PERSISTENT NEW ACCESS POINT DETECTED"
	default:
		if event == "" {
			return "NO ACTIVE THREAT DETECTED"
		}
		return strings.ReplaceAll(event, "_", " ")
	}
}

func eventShort(event string) string {
	switch event {
	case "DEAUTH_ACTIVITY":
		return "DEAUTH"
	case "TRUSTED_SSID_NEW_BSSID", "WATCHED_SSID_NEW_BSSID":
		return "EVIL TWIN"
	case "TRUSTED_BSSID_SSID_CHANGE", "WATCHED_BSSID_SSID_CHANGE":
		return "SSID CHANGE"
	case "TRUSTED_AP_CHANNEL_CHANGE", "WATCHED_AP_CHANNEL_CHANGE":
		return "CHANNEL"
	case "NEW_BSSID":
		return "PROBE FLOOD"
	case "MANUAL_FOCUS", "MANUAL_INVESTIGATE":
		return "MANUAL"
	case "LEGACY_CAPTURE":
		return "LEGACY"
	default:
		return strings.ReplaceAll(event, "_", " ")
	}
}

func captureLabel(c Capture, bssid string, evidence []Evidence) string {
	if c.Status == "CAPTURING" && (bssid == "" || strings.EqualFold(c.BSSID, bssid)) {
		return "PCAP CAPTURING"
	}
	for _, e := range evidence {
		if bssid != "" && strings.EqualFold(e.BSSID, bssid) {
			return "PCAP SAVED"
		}
	}
	if c.Status != "" && c.Status != "IDLE" {
		return "PCAP " + c.Status
	}
	return "READY"
}

func displaySSID(s string) string {
	s = strings.TrimSpace(s)
	if s == "" || s == "<hidden>" || s == "<unknown>" {
		return "<HIDDEN NETWORK>"
	}
	return s
}

func evidenceTime(epoch string) string {
	v, err := strconv.ParseInt(epoch, 10, 64)
	if err != nil {
		return "--:--"
	}
	return time.Unix(v, 0).Format("15:04")
}

func evidenceDateTime(epoch string) string {
	v, err := strconv.ParseInt(epoch, 10, 64)
	if err != nil {
		return epoch
	}
	return time.Unix(v, 0).Format("2006-01-02 15:04:05")
}

func humanBytes(n int64) string {
	switch {
	case n >= 1024*1024*1024:
		return fmt.Sprintf("%.1f GB", float64(n)/(1024*1024*1024))
	case n >= 1024*1024:
		return fmt.Sprintf("%.0f MB", float64(n)/(1024*1024))
	case n >= 1024:
		return fmt.Sprintf("%.0f KB", float64(n)/1024)
	default:
		return fmt.Sprintf("%d B", n)
	}
}

func trimCells(s string, maxCells int) string {
	r := []rune(strings.TrimSpace(s))
	if len(r) <= maxCells {
		return string(r)
	}
	if maxCells <= 1 {
		return string(r[:maxCells])
	}
	return string(r[:maxCells-1]) + "…"
}

func countSSID(aps []AP, ssid string) int {
	n := 0
	for _, ap := range aps {
		if ssid != "" && ap.SSID == ssid {
			n++
		}
	}
	return n
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// Compile-time checks that keep otherwise easy-to-drop standard packages
// referenced when this file is built with older OpenWrt-oriented Go releases.
var _ = bytes.Compare
var _ = errors.Is
