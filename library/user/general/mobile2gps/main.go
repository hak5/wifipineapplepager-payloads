// mobile2gps - Relay mobile GPS to gpsd via fake serial device
// Converts browser geolocation data to NMEA sentences for gpsd
package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
)

const (
	httpsPort  = 1993
	gpsdPort   = 2947
	indexFile  = "index.html"
	certFile   = "cert.pem"
	keyFile    = "key.pem"
	writePadMs = 33
)

var (
	ptmx       *os.File     // master side of pty
	server     *http.Server // HTTP server for graceful shutdown
	bufferPool = sync.Pool{
		New: func() any {
			return new(bytes.Buffer)
		},
	}
)

func main() {
	// Load or generate TLS certificate
	tlsCert, err := loadOrGenerateCert()
	if err != nil {
		log.Fatal("Failed to load/generate certificate:", err)
	}

	// Create PTY for fake GPS device
	master, slave, err := pty.Open()
	if err != nil {
		log.Fatal("Failed to open pty:", err)
	}
	ptmx = master
	slaveName := slave.Name()

	// Make slave device accessible to gpsd
	if err := os.Chmod(slaveName, 0666); err != nil {
		log.Println("Warning: chmod on pty failed:", err)
	}

	log.Println("Created fake GPS device:", slaveName)

	// Kill any existing gpsd to free the port
	exec.Command("killall", "gpsd").Run()

	// Start gpsd
	gpsd := exec.Command("gpsd", "-N", "-G",
		"-S", strconv.Itoa(gpsdPort),
		slaveName)
	gpsd.Stdout = os.Stdout
	gpsd.Stderr = os.Stderr

	if err := gpsd.Start(); err != nil {
		log.Fatal("Failed to start gpsd:", err)
	}
	log.Println("Started gpsd on port", gpsdPort)

	// Keep slave open - closing it can cause permission issues
	// Don't defer close here - handle in shutdown

	// HTTPS server
	http.HandleFunc("/", handleRequest)

	server = &http.Server{
		Addr: fmt.Sprintf(":%d", httpsPort),
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{tlsCert},
		},
	}

	// Handle shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigChan
		log.Println("Shutting down...")

		// Gracefully shutdown HTTP server with 5 second timeout
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(ctx); err != nil {
			log.Printf("HTTP server shutdown error: %v\n", err)
		}

		// Cleanup gpsd - graceful shutdown then force kill
		if gpsd.Process != nil {
			gpsd.Process.Signal(syscall.SIGTERM)
			done := make(chan error, 1)
			go func() { done <- gpsd.Wait() }()
			select {
			case <-done:
				// gpsd exited cleanly
			case <-time.After(2 * time.Second):
				gpsd.Process.Kill()
				<-done
			}
		}

		// Close PTY
		ptmx.Close()
		slave.Close()
		os.Exit(0)
	}()

	log.Printf("HTTPS server listening on port %d\n", httpsPort)
	if err := server.ListenAndServeTLS("", ""); err != http.ErrServerClosed {
		log.Fatal("HTTPS server error:", err)
	}
}

// loadOrGenerateCert loads existing cert files or generates new ones
func loadOrGenerateCert() (tls.Certificate, error) {
	// Try to load existing certificate
	if _, err := os.Stat(certFile); err == nil {
		if _, err := os.Stat(keyFile); err == nil {
			log.Println("Loading existing certificate...")
			return tls.LoadX509KeyPair(certFile, keyFile)
		}
	}

	// Generate new certificate
	log.Println("Generating self-signed certificate...")

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}

	// Get hostname for certificate subject
	hostname, err := os.Hostname()
	if err != nil {
		hostname = "mobile2gps"
	}

	serialNumber, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("failed to generate serial number: %w", err)
	}

	template := x509.Certificate{
		SerialNumber: serialNumber,
		Subject:      pkix.Name{CommonName: hostname},
		NotBefore:    time.Now(),
		NotAfter:     time.Now().AddDate(10, 0, 0), // 10 years
		KeyUsage:     x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{hostname, "localhost"},
		IPAddresses:  []net.IP{net.ParseIP("172.16.52.1"), net.ParseIP("127.0.0.1")},
	}

	certDER, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}

	// Save certificate
	certOut, err := os.Create(certFile)
	if err != nil {
		return tls.Certificate{}, err
	}
	if err := pem.Encode(certOut, &pem.Block{Type: "CERTIFICATE", Bytes: certDER}); err != nil {
		certOut.Close()
		return tls.Certificate{}, fmt.Errorf("failed to encode certificate: %w", err)
	}
	if err := certOut.Close(); err != nil {
		return tls.Certificate{}, fmt.Errorf("failed to close certificate file: %w", err)
	}

	// Save private key
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return tls.Certificate{}, err
	}
	keyOut, err := os.Create(keyFile)
	if err != nil {
		return tls.Certificate{}, err
	}
	if err := pem.Encode(keyOut, &pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}); err != nil {
		keyOut.Close()
		return tls.Certificate{}, fmt.Errorf("failed to encode private key: %w", err)
	}
	if err := keyOut.Close(); err != nil {
		return tls.Certificate{}, fmt.Errorf("failed to close key file: %w", err)
	}

	log.Printf("Saved certificate to %s and %s\n", certFile, keyFile)

	return tls.Certificate{
		Certificate: [][]byte{certDER},
		PrivateKey:  key,
	}, nil
}

func handleRequest(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		serveIndex(w, r)
	case http.MethodPost:
		handleGPSData(w, r)
	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func serveIndex(w http.ResponseWriter, r *http.Request) {
	// Only serve index.html for root or /index.html
	if r.URL.Path == "/" || r.URL.Path == "/index.html" {
		http.ServeFile(w, r, indexFile)
	} else {
		http.NotFound(w, r)
	}
}

func handleGPSData(w http.ResponseWriter, r *http.Request) {
	// Ensure request body is closed and form data is cleaned up
	defer r.Body.Close()
	defer func() {
		r.Form = nil
		r.PostForm = nil
	}()

	if err := r.ParseForm(); err != nil {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}

	lats := r.Form["Lat"]
	lons := r.Form["Lon"]
	accs := r.Form["Acc"]
	times := r.Form["Time"]

	if len(lats) == 0 {
		http.Error(w, "No GPS data", http.StatusBadRequest)
		return
	}

	log.Printf("Received %d GPS update(s)\n", len(lats))

	// Get a buffer from the pool
	buf := bufferPool.Get().(*bytes.Buffer)
	defer func() {
		buf.Reset()
		bufferPool.Put(buf)
	}()

	for i := range lats {
		if i >= len(lons) {
			continue
		}
		lat, err := strconv.ParseFloat(lats[i], 64)
		if err != nil {
			continue
		}
		lon, err := strconv.ParseFloat(lons[i], 64)
		if err != nil {
			continue
		}

		// Parse timestamp (milliseconds since epoch)
		var ts time.Time
		if i < len(times) {
			if msec, err := strconv.ParseInt(times[i], 10, 64); err == nil {
				ts = time.UnixMilli(msec)
			} else {
				ts = time.Now()
			}
		} else {
			ts = time.Now()
		}

		// Determine validity from accuracy
		valid := "V"
		faa := "N"
		if i < len(accs) {
			if acc, err := strconv.ParseFloat(accs[i], 64); err == nil && acc <= 100 {
				valid = "A"
				faa = "A"
			}
		}

		// Build NMEA sentence directly into buffer
		buf.Reset()
		buildGPRMC(buf, lat, lon, ts, valid, faa)

		// Log NMEA sentence for debugging (trim \r\n for cleaner output)
		nmea := buf.String()
		log.Print(nmea[:len(nmea)-2])

		// Feed to fake GPS (buffer contents already have \r\n)
		if _, err := ptmx.Write(buf.Bytes()); err != nil {
			log.Printf("Error writing to PTY: %v\n", err)
			// Continue processing other updates even if one fails
		}
		time.Sleep(writePadMs * time.Millisecond)
	}

	w.WriteHeader(http.StatusOK)
}

// buildGPRMC creates an NMEA GPRMC sentence from coordinates and writes it to the buffer
func buildGPRMC(buf *bytes.Buffer, lat, lon float64, ts time.Time, valid, faa string) {
	buf.WriteByte('$')

	// Start building the sentence body (for checksum calculation)
	bodyStart := buf.Len()

	buf.WriteString("GPRMC,")

	// Convert time to NMEA format: HHMMSS.ss
	buf.WriteString(ts.Format("150405"))
	buf.WriteByte('.')
	fmt.Fprintf(buf, "%02d", ts.Nanosecond()/10000000)
	buf.WriteByte(',')

	buf.WriteString(valid)
	buf.WriteByte(',')

	// Convert latitude to NMEA format: DDMM.MMMMMM,N/S
	latHemi := "N"
	if lat < 0 {
		latHemi = "S"
		lat = -lat
	}
	latDeg := int(lat)
	latMin := (lat - float64(latDeg)) * 60.0
	fmt.Fprintf(buf, "%02d%09.6f,%s,", latDeg, latMin, latHemi)

	// Convert longitude to NMEA format: DDDMM.MMMMMM,E/W
	lonHemi := "E"
	if lon < 0 {
		lonHemi = "W"
		lon = -lon
	}
	lonDeg := int(lon)
	lonMin := (lon - float64(lonDeg)) * 60.0
	fmt.Fprintf(buf, "%03d%09.6f,%s,,,", lonDeg, lonMin, lonHemi)

	// Date
	buf.WriteString(ts.Format("020106"))
	buf.WriteString(",,,")
	buf.WriteString(faa)

	// Calculate XOR checksum on the body (everything after '$')
	bodyBytes := buf.Bytes()[bodyStart:]
	checksum := byte(0)
	for i := 0; i < len(bodyBytes); i++ {
		checksum ^= bodyBytes[i]
	}

	// Write checksum
	fmt.Fprintf(buf, "*%02X\r\n", checksum)
}
