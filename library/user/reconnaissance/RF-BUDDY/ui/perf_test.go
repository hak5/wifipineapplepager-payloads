package main

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"net/http/httptest"
	"testing"
)

// referenceFramebuffer is the original per-pixel conversion, kept as the
// oracle for the faster canvasToFramebufferInto.
func referenceFramebuffer(img *image.RGBA) []byte {
	out := make([]byte, frameBytes)
	for y := 0; y < screenHeight; y++ {
		for x := 0; x < screenWidth; x++ {
			p := img.RGBAAt(x, y)
			v := uint16(p.R>>3)<<11 | uint16(p.G>>2)<<5 | uint16(p.B>>3)
			i := (x*fbWidth + (fbWidth - 1 - y)) * 2
			out[i] = byte(v)
			out[i+1] = byte(v >> 8)
		}
	}
	return out
}

func TestCanvasToFramebufferIntoMatchesReference(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, screenWidth, screenHeight))
	for y := 0; y < screenHeight; y++ {
		for x := 0; x < screenWidth; x++ {
			img.SetRGBA(x, y, color.RGBA{uint8(x * 7), uint8(y * 13), uint8(x ^ y), 0xff})
		}
	}
	want := referenceFramebuffer(img)
	buf := make([]byte, 3) // wrong size on purpose: must be resized
	got := canvasToFramebufferInto(buf, img)
	if !bytes.Equal(got, want) {
		t.Fatal("fast framebuffer conversion differs from the reference")
	}
	again := canvasToFramebufferInto(got, img)
	if &again[0] != &got[0] {
		t.Fatal("a correctly sized buffer must be reused, not reallocated")
	}
}

func TestMirrorEncodesLazilyAndServesLatest(t *testing.T) {
	m := newMirror()
	img := image.NewRGBA(image.Rect(0, 0, 4, 4))
	img.SetRGBA(1, 1, color.RGBA{0xff, 0, 0, 0xff})
	m.publish(img)
	m.mu.RLock()
	encoded := len(m.png)
	m.mu.RUnlock()
	if encoded != 0 {
		t.Fatal("publish must not PNG-encode until a viewer asks")
	}
	img.SetRGBA(1, 1, color.RGBA{0, 0xff, 0, 0xff}) // publish must have copied the pixels
	srv := httptest.NewServer(m.handler(make(chan string, 1)))
	defer srv.Close()
	resp, err := srv.Client().Get(srv.URL + "/screen.png")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	dec, err := png.Decode(resp.Body)
	if err != nil {
		t.Fatalf("served screen is not a PNG: %v", err)
	}
	if r, g, _, _ := dec.At(1, 1).RGBA(); r>>8 != 0xff || g != 0 {
		t.Fatalf("served pixel = %v, want the published red", dec.At(1, 1))
	}
}
