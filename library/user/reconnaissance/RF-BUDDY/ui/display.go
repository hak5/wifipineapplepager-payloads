// Display, input, and Virtual Pager plumbing for the RF-BUDDY UI.
//
// Copied from DEFCON-DEFENSE/ui/main.go rather than shared so the stabilized
// DEFCON Defense application stays untouched. The Pager exposes a 222x480
// RGB565 framebuffer rotated counter-clockwise onto its 480x222 landscape LCD.
package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
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
	ownershipPollInterval = 50 * time.Millisecond
	inputStartupDelay     = 1200 * time.Millisecond
)

var (
	black  = color.RGBA{0x00, 0x00, 0x00, 0xff}
	white  = color.RGBA{0xf4, 0xf4, 0xee, 0xff}
	cyan   = color.RGBA{0x69, 0xd5, 0xf1, 0xff}
	cyan2  = color.RGBA{0x2d, 0xa8, 0xc4, 0xff}
	yellow = color.RGBA{0xff, 0xd5, 0x1f, 0xff}
	green  = color.RGBA{0x5d, 0xe1, 0x42, 0xff}
	amber  = color.RGBA{0xff, 0xb0, 0x20, 0xff}
	red    = color.RGBA{0xff, 0x3f, 0x2f, 0xff}
	dim    = color.RGBA{0x75, 0x82, 0x87, 0xff}
)

func canvasToFramebuffer(img *image.RGBA) []byte {
	return canvasToFramebufferInto(nil, img)
}

// canvasToFramebufferInto converts the landscape canvas to the rotated RGB565
// framebuffer layout, reusing out when it is already frame-sized. It walks Pix
// directly: per-pixel RGBAAt was a top CPU cost on the Pager.
func canvasToFramebufferInto(out []byte, img *image.RGBA) []byte {
	if len(out) != frameBytes {
		out = make([]byte, frameBytes)
	}
	for y := 0; y < screenHeight; y++ {
		row := img.Pix[y*img.Stride : y*img.Stride+screenWidth*4]
		// The physical landscape canvas is the device framebuffer rotated
		// counter-clockwise: fb(x=221-y, y=x) == canvas(x,y).
		i := (fbWidth - 1 - y) * 2
		for x := 0; x < screenWidth; x++ {
			p := row[x*4 : x*4+3]
			v := uint16(p[0]>>3)<<11 | uint16(p[1]>>2)<<5 | uint16(p[2]>>3)
			out[i] = byte(v)
			out[i+1] = byte(v >> 8)
			i += fbWidth * 2
		}
	}
	return out
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

func maintainDisplayOwnership(fb io.ReadWriteSeeker, expected []byte, scratch *[]byte) error {
	if len(expected) == 0 {
		return nil
	}
	// One raw framebuffer row maps to one full-height canvas column. Sampling
	// the center row checks title, content, and footer in one small read.
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

// mirror publishes the rendered canvas to the Virtual Pager bridge on :1474.
// publish only copies pixels; the PNG is encoded on the first request for that
// frame, so the Pager spends no CPU on encoding while nobody is watching.
type mirror struct {
	mu       sync.RWMutex
	img      *image.RGBA
	png      []byte
	etag     string
	revision uint64
	updated  chan struct{}
}

func newMirror() *mirror { return &mirror{updated: make(chan struct{})} }

func (m *mirror) publish(img *image.RGBA) {
	m.mu.Lock()
	if m.img == nil || m.img.Bounds() != img.Bounds() {
		m.img = image.NewRGBA(img.Bounds())
	}
	copy(m.img.Pix, img.Pix)
	m.png = m.png[:0]
	m.revision++
	m.etag = fmt.Sprintf("\"rf-buddy-%x\"", m.revision)
	close(m.updated)
	m.updated = make(chan struct{})
	m.mu.Unlock()
}

// encodedLocked returns the PNG for the current frame, encoding it once.
// The caller holds m.mu for writing.
func (m *mirror) encodedLocked() []byte {
	if len(m.png) == 0 && m.img != nil {
		var b bytes.Buffer
		// Avoid spending scarce Pager CPU on compression; USB transfer is
		// faster than the MIPS encoder.
		encoder := png.Encoder{CompressionLevel: png.NoCompression}
		if encoder.Encode(&b, m.img) == nil {
			m.png = append(m.png[:0], b.Bytes()...)
		}
	}
	return m.png
}

func (m *mirror) handler(buttons chan<- string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = io.WriteString(w, viewerHTML)
	})
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "RF-BUDDY UI active\n")
	})
	mux.HandleFunc("/screen.png", m.serveScreen)
	mux.HandleFunc("/button", virtualButtonHandler(buttons))
	return mux
}

func (m *mirror) serveScreen(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Content-Type", "image/png")
	clientETag := r.Header.Get("If-None-Match")
	if clientETag == "" {
		clientETag = r.URL.Query().Get("rev")
	}
	for {
		m.mu.Lock()
		etag := m.etag
		updated := m.updated
		if etag == "" || clientETag != etag {
			b := append([]byte(nil), m.encodedLocked()...)
			m.mu.Unlock()
			if len(b) == 0 {
				http.Error(w, "screen not ready", http.StatusServiceUnavailable)
				return
			}
			w.Header().Set("ETag", etag)
			_, _ = w.Write(b)
			return
		}
		m.mu.Unlock()
		if r.URL.Query().Get("wait") == "1" && updated != nil {
			timer := time.NewTimer(5 * time.Second)
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
}

// serve runs the viewer until ctx ends. It returns the listen error (for
// example when the USB address is not up yet), nil on a clean shutdown.
func (m *mirror) serve(ctx context.Context, listen string, buttons chan<- string) error {
	server := &http.Server{Addr: listen, Handler: m.handler(buttons), ReadHeaderTimeout: 2 * time.Second}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func virtualButtonHandler(buttons chan<- string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if r.Method != http.MethodPost {
			http.Error(w, "POST required", http.StatusMethodNotAllowed)
			return
		}
		// A custom header forces a CORS preflight from other sites, which this
		// server never approves, so only the on-page buttons can press.
		if r.Header.Get("X-RF-Buddy") != "1" {
			http.Error(w, "forbidden", http.StatusForbidden)
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
		if err := readButtonDevice(ctx, inputDevice, out); ctx.Err() != nil {
			return
		} else if err == nil {
			continue
		}
		timer := time.NewTimer(2 * time.Second)
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
	// Best effort: keep presses from reaching the stock UI while we run.
	// SyscallConn avoids Fd(), which would force the descriptor into blocking
	// mode and stop Close from unblocking the read on shutdown.
	if rc, err := f.SyscallConn(); err == nil {
		_ = rc.Control(func(fd uintptr) { _ = grabInput(int(fd)) })
	}

	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			_ = f.Close()
		case <-done:
		}
	}()

	// Linux input_event is 16 bytes on the Pager's 32-bit MIPS userspace and
	// 24 bytes on a 64-bit host because timeval follows native word size.
	eventSize, typeOffset := 16, 8
	if strconv.IntSize == 64 {
		eventSize, typeOffset = 24, 16
	}
	event := make([]byte, eventSize)
	for {
		if _, err := io.ReadFull(f, event); err != nil {
			return err
		}
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

func drawTextRightBox(img *image.RGBA, box image.Rectangle, y int, text string, c color.RGBA, bold bool) {
	text = trimCells(text, box.Dx()/textCellWidth)
	drawTextBox(img, box, box.Max.X-textPixelWidth(text, 1), y, text, c, bold, 1)
}

func drawCentered(img *image.RGBA, y int, text string, c color.RGBA, bold bool) {
	drawCenteredIn(img, 0, screenWidth, y, text, c)
}

// drawCenteredIn draws bold text centered between x0 and x1, trimmed to fit.
func drawCenteredIn(img *image.RGBA, x0, x1, y int, text string, c color.RGBA) {
	text = trimCells(text, (x1-x0)/textCellWidth)
	x := x0 + (x1-x0-textPixelWidth(text, 1))/2
	drawTextBox(img, image.Rect(x0, y, x1, y+16), x, y, text, c, true, 1)
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

// drawLine draws a 1px Bresenham line, clipped to the image.
func drawLine(img *image.RGBA, x0, y0, x1, y1 int, c color.RGBA) {
	dx, dy := abs(x1-x0), -abs(y1-y0)
	sx, sy := 1, 1
	if x0 > x1 {
		sx = -1
	}
	if y0 > y1 {
		sy = -1
	}
	err := dx + dy
	for {
		if image.Pt(x0, y0).In(img.Bounds()) {
			img.SetRGBA(x0, y0, c)
		}
		if x0 == x1 && y0 == y1 {
			return
		}
		e2 := 2 * err
		if e2 >= dy {
			err += dy
			x0 += sx
		}
		if e2 <= dx {
			err += dx
			y0 += sy
		}
	}
}

func trimCells(s string, maxCells int) string {
	r := []rune(strings.TrimSpace(s))
	if len(r) <= maxCells {
		return string(r)
	}
	if maxCells <= 1 {
		return string(r[:max(0, maxCells)])
	}
	return string(r[:maxCells-1]) + "…"
}

// wrapCells word-wraps s into lines of at most width cells. Words longer than
// width are hard-split. maxLines > 0 truncates with a trailing ellipsis.
func wrapCells(s string, width, maxLines int) []string {
	var lines []string
	cur := ""
	for _, w := range strings.Fields(s) {
		for len([]rune(w)) > width {
			if cur != "" {
				lines = append(lines, cur)
				cur = ""
			}
			r := []rune(w)
			lines = append(lines, string(r[:width]))
			w = string(r[width:])
		}
		switch {
		case w == "":
		case cur == "":
			cur = w
		case len([]rune(cur))+1+len([]rune(w)) <= width:
			cur += " " + w
		default:
			lines = append(lines, cur)
			cur = w
		}
	}
	if cur != "" {
		lines = append(lines, cur)
	}
	if maxLines > 0 && len(lines) > maxLines {
		lines = lines[:maxLines]
		last := []rune(lines[maxLines-1])
		if len(last) >= width {
			last = last[:width-1]
		}
		lines[maxLines-1] = string(last) + "…"
	}
	return lines
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}
