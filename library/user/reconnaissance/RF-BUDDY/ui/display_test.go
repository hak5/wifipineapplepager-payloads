package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"image"
	"image/color"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type memoryReadWriteSeeker struct {
	data   []byte
	reader *bytes.Reader
}

func newMemoryReadWriteSeeker(data []byte) *memoryReadWriteSeeker {
	copyData := append([]byte(nil), data...)
	return &memoryReadWriteSeeker{data: copyData, reader: bytes.NewReader(copyData)}
}

func (m *memoryReadWriteSeeker) Read(p []byte) (int, error) { return m.reader.Read(p) }

func (m *memoryReadWriteSeeker) Write(p []byte) (int, error) {
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

func TestCanvasToFramebufferRotatesCounterClockwise(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, screenWidth, screenHeight))
	img.SetRGBA(0, 0, color.RGBA{0xff, 0, 0, 0xff})
	img.SetRGBA(screenWidth-1, screenHeight-1, color.RGBA{0, 0, 0xff, 0xff})
	fb := canvasToFramebuffer(img)
	if len(fb) != frameBytes {
		t.Fatalf("frame length = %d, want %d", len(fb), frameBytes)
	}
	if got := binary.LittleEndian.Uint16(fb[(fbWidth-1)*2:]); got != 0xf800 {
		t.Fatalf("canvas (0,0) -> fb = %#04x, want red 0xf800", got)
	}
	if got := binary.LittleEndian.Uint16(fb[((screenWidth-1)*fbWidth)*2:]); got != 0x001f {
		t.Fatalf("canvas (479,221) -> fb = %#04x, want blue 0x001f", got)
	}
}

func TestMaintainDisplayOwnershipRewritesDisplacedFrame(t *testing.T) {
	expected := bytes.Repeat([]byte{0xab}, frameBytes)
	fb := newMemoryReadWriteSeeker(make([]byte, frameBytes))
	var scratch []byte
	if err := maintainDisplayOwnership(fb, expected, &scratch); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(fb.data, expected) {
		t.Fatal("displaced frame was not rewritten")
	}
}

func TestNormalizeButton(t *testing.T) {
	cases := map[string]string{"enter": "A", "Escape": "B", "ArrowUp": "UP", "arrow-left": "LEFT", " right ": "RIGHT", "a": "A"}
	for in, want := range cases {
		if got := normalizeButton(in); got != want {
			t.Errorf("normalizeButton(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestVirtualButtonHandlerQueuesOnePress(t *testing.T) {
	buttons := make(chan string, 1)
	h := virtualButtonHandler(buttons)
	post := func(name string) int {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/button?name="+name, nil)
		req.Header.Set("X-RF-Buddy", "1")
		h(rec, req)
		return rec.Code
	}
	if code := post("A"); code != http.StatusNoContent {
		t.Fatalf("first press = %d, want 204", code)
	}
	if code := post("B"); code != http.StatusServiceUnavailable {
		t.Fatalf("second press = %d, want 503 while queue is full", code)
	}
	if code := post("SELECT"); code != http.StatusBadRequest {
		t.Fatalf("invalid button = %d, want 400", code)
	}
	rec := httptest.NewRecorder()
	h(rec, httptest.NewRequest(http.MethodGet, "/button?name=A", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET = %d, want 405", rec.Code)
	}
	if got := <-buttons; got != "A" {
		t.Fatalf("queued %q, want A", got)
	}
}

func TestVirtualButtonRequiresHeaderAndNoCORS(t *testing.T) {
	buttons := make(chan string, 1)
	h := virtualButtonHandler(buttons)
	rec := httptest.NewRecorder()
	h(rec, httptest.NewRequest(http.MethodPost, "/button?name=A", nil))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("POST without X-RF-Buddy = %d, want 403", rec.Code)
	}
	if len(buttons) != 0 {
		t.Fatal("a refused press must not be queued")
	}
	rec = httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/button?name=A", nil)
	req.Header.Set("X-RF-Buddy", "1")
	h(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("POST with header = %d, want 204", rec.Code)
	}
	if v := rec.Header().Get("Access-Control-Allow-Origin"); v != "" {
		t.Fatalf("ACAO = %q, want none", v)
	}
	rec = httptest.NewRecorder()
	h(rec, httptest.NewRequest(http.MethodOptions, "/button?name=A", nil))
	if rec.Code == http.StatusNoContent || rec.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("preflight must fail without CORS headers, got %d %v", rec.Code, rec.Header())
	}
	srv := httptest.NewServer(newMirror().handler(make(chan string, 1)))
	defer srv.Close()
	for _, path := range []string{"/health", "/screen.png"} {
		resp, err := http.Get(srv.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if v := resp.Header.Get("Access-Control-Allow-Origin"); v != "" {
			t.Errorf("%s ACAO = %q, want none", path, v)
		}
	}
}

func TestMirrorServeReportsListenError(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	err = newMirror().serve(context.Background(), ln.Addr().String(), make(chan string, 1))
	if err == nil {
		t.Fatal("serve on a busy address must return the error")
	}
}

func TestViewerPageSendsHeader(t *testing.T) {
	if !strings.Contains(viewerHTML, "X-RF-Buddy") {
		t.Fatal("viewer page must send the X-RF-Buddy header")
	}
}

func TestMirrorServesFrameThenNotModified(t *testing.T) {
	m := newMirror()
	srv := httptest.NewServer(m.handler(make(chan string, 1)))
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/screen.png")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("before publish = %d, want 503", resp.StatusCode)
	}

	m.publish(image.NewRGBA(image.Rect(0, 0, 4, 4)))
	resp, err = http.Get(srv.URL + "/screen.png")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	etag := resp.Header.Get("ETag")
	if resp.StatusCode != http.StatusOK || !strings.HasPrefix(etag, "\"rf-buddy-") {
		t.Fatalf("after publish = %d etag %q", resp.StatusCode, etag)
	}

	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/screen.png", nil)
	req.Header.Set("If-None-Match", etag)
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotModified {
		t.Fatalf("matching etag = %d, want 304", resp.StatusCode)
	}
}

func TestTrimCells(t *testing.T) {
	if got := trimCells("OfficeNet", 20); got != "OfficeNet" {
		t.Fatalf("short = %q", got)
	}
	if got := trimCells("ABCDEFGHIJ", 5); got != "ABCD…" {
		t.Fatalf("long = %q", got)
	}
}

func TestWrapCells(t *testing.T) {
	got := wrapCells("RECON IS STILL HOPPING CHANNELS STOP RECON", 16, 0)
	if strings.Join(got, "|") != "RECON IS STILL|HOPPING CHANNELS|STOP RECON" {
		t.Fatalf("wrap = %q", got)
	}
	got = wrapCells("AAAAAAAAAAAAAAAAAAAA", 8, 0)
	if strings.Join(got, "|") != "AAAAAAAA|AAAAAAAA|AAAA" {
		t.Fatalf("hard split = %q", got)
	}
	got = wrapCells("one two three four five six", 9, 2)
	if len(got) != 2 || !strings.HasSuffix(got[1], "…") {
		t.Fatalf("max lines = %q", got)
	}
}

func TestViewerPageServedAtRootOnly(t *testing.T) {
	srv := httptest.NewServer(newMirror().handler(make(chan string, 1)))
	defer srv.Close()
	resp, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/html") {
		t.Fatalf("GET / = %d %q", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	for _, want := range []string{"RF-BUDDY", "/screen.png?wait=1&rev=", "/button?name=", "pixelated"} {
		if !strings.Contains(string(body), want) {
			t.Errorf("viewer missing %q", want)
		}
	}
	if strings.Contains(string(body), "http://") || strings.Contains(string(body), "https://") {
		t.Error("viewer must not reference external resources")
	}
	resp, err = http.Get(srv.URL + "/nope")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 404 {
		t.Fatalf("GET /nope = %d, want 404", resp.StatusCode)
	}
}

// On the Pager the physical red button reports BTN_SOUTH (304) and the green
// button BTN_EAST (305); the on-screen hints are red B and green A.
func TestPhysicalButtonsMatchPagerColours(t *testing.T) {
	cases := map[uint16]string{304: "B", 305: "A", 103: "UP", 108: "DOWN", 105: "LEFT", 106: "RIGHT", 1: ""}
	for code, want := range cases {
		if got := buttonForLinuxKey(code); got != want {
			t.Errorf("buttonForLinuxKey(%d) = %q, want %q", code, got, want)
		}
	}
}

// The power key shares the Pager's gpio-keys device with A/B and the arrows,
// so while RF-BUDDY holds its exclusive grab it must handle power itself.
func TestPowerKeyIsMapped(t *testing.T) {
	if got := buttonForLinuxKey(116); got != "POWER" { // KEY_POWER
		t.Fatalf("KEY_POWER mapped to %q, want POWER", got)
	}
}
