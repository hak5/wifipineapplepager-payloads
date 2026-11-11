// Mobile2GPS - Relay mobile GPS to gpsd via fake serial device
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
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
)

const (
	httpsPort = 1993
	indexFile = "index.html"
	certFile  = "cert.pem"
	keyFile   = "key.pem"
	fixMaxAge = 3 * time.Second
	// Empty time/date makes gpsd report the invalid fix immediately.
	noFixSentence = "$GPRMC,,V,,,,,,,,,,N*53\r\n"
)

var (
	ptmx        *os.File     // master side of pty
	server      *http.Server // HTTP server for graceful shutdown
	fixMu       sync.Mutex   // serialize live fixes and expiry writes
	fixTimer    *time.Timer
	fixExpires  time.Time
	lastFixTime int64
	bufferPool  = sync.Pool{
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
	defer master.Close()
	defer slave.Close()

	// Make slave device accessible to gpsd
	if err := os.Chmod(slaveName, 0666); err != nil {
		log.Println("Warning: chmod on pty failed:", err)
	}

	log.Println("Created fake GPS device:", slaveName)

	previousGPS, err := gpsRestoreArgs()
	if err != nil {
		log.Fatal("Failed to read GPS configuration:", err)
	}

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
	shutdownDone := make(chan struct{})
	go func() {
		defer close(shutdownDone)
		<-sigChan
		log.Println("Shutting down...")

		// Gracefully shutdown HTTP server with 5 second timeout
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(ctx); err != nil {
			log.Printf("HTTP server shutdown error: %v\n", err)
			server.Close()
		}
	}()

	// Restore the user's GPS selection on shutdown or failed startup.
	defer func() {
		fixMu.Lock()
		if fixTimer != nil {
			fixTimer.Stop()
		}
		fixExpires = time.Time{}
		fixMu.Unlock()
		if err := configureGPS(previousGPS...); err != nil {
			log.Println("Failed to restore GPS configuration:", err)
		}
	}()

	// Stop the managed service and any gpsd left by older Mobile2GPS versions.
	if output, err := exec.Command("/etc/init.d/gpsd", "stop").CombinedOutput(); err != nil {
		log.Printf("Failed to stop gpsd: %v: %s", err, output)
		return
	}
	exec.Command("/usr/bin/killall", "gpsd").Run()
	time.Sleep(200 * time.Millisecond)
	exec.Command("/usr/bin/killall", "-KILL", "gpsd").Run()

	// The firmware selects gpsd for PineAP and manages the daemon on this PTY.
	if err := configureGPS("GPSD", slaveName, "9600"); err != nil {
		log.Println("Failed to configure GPS:", err)
		return
	}
	// procd may still be starting gpsd when GPS_CONFIGURE returns.
	deadline := time.Now().Add(3 * time.Second)
	for {
		conn, err := net.DialTimeout("tcp", "127.0.0.1:2947", 200*time.Millisecond)
		if err == nil {
			conn.Close()
			break
		}
		if time.Now().After(deadline) {
			log.Println("Configured gpsd did not become available:", err)
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	log.Println("Configured Pager GPS to use", slaveName, "through gpsd")

	log.Printf("HTTPS server listening on port %d\n", httpsPort)
	if err := server.ListenAndServeTLS("", ""); err != http.ErrServerClosed {
		log.Println("HTTPS server error:", err)
		return
	}
	// ListenAndServeTLS returns before Shutdown finishes; wait before restoring GPS.
	<-shutdownDone
}

func configureGPS(args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/bin/GPS_CONFIGURE", args...)
	cmd.WaitDelay = time.Second
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("GPS_CONFIGURE: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}

// Save only the GPS selection, leaving unrelated PineAP settings alone.
func gpsRestoreArgs() ([]string, error) {
	native, err := exec.Command("/sbin/uci", "-q", "get", "pineapd.@pineapd[0].pineapgps").Output()
	if err != nil {
		return nil, err
	}
	mode, deviceKey := "GPSD", "gpsd.core.device"
	switch strings.TrimSpace(string(native)) {
	case "1", "on", "true", "yes", "enabled":
		mode, deviceKey = "PINEAP", "pineapd.@pineapd[0].gpsdevice"
	}
	device, err := exec.Command("/sbin/uci", "-q", "get", deviceKey).Output()
	if err != nil || strings.TrimSpace(string(device)) == "" {
		return nil, fmt.Errorf("cannot read %s", deviceKey)
	}
	args := []string{mode, strings.TrimSpace(string(device))}
	if mode == "GPSD" {
		speed := "9600"
		if output, err := exec.Command("/bin/stty", "-F", args[1], "speed").Output(); err == nil && len(bytes.TrimSpace(output)) > 0 {
			speed = strings.TrimSpace(string(output))
		}
		args = append(args, speed)
	}
	return args, nil
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
		hostname = "Mobile2GPS"
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

	// The phone sends one live fix, never a batch of historical positions.
	if len(lats) != 1 || len(lons) != 1 || len(accs) != 1 || len(times) != 1 {
		http.Error(w, "Expected one GPS fix", http.StatusBadRequest)
		return
	}

	lat, err := strconv.ParseFloat(lats[0], 64)
	if err != nil {
		http.Error(w, "Invalid latitude", http.StatusBadRequest)
		return
	}
	lon, err := strconv.ParseFloat(lons[0], 64)
	if err != nil {
		http.Error(w, "Invalid longitude", http.StatusBadRequest)
		return
	}
	acc, err := strconv.ParseFloat(accs[0], 64)
	if err != nil {
		http.Error(w, "Invalid accuracy", http.StatusBadRequest)
		return
	}
	msec, err := strconv.ParseInt(times[0], 10, 64)
	if err != nil || msec <= 0 {
		http.Error(w, "Invalid timestamp", http.StatusBadRequest)
		return
	}

	fixMu.Lock()
	defer fixMu.Unlock()
	if r.Context().Err() != nil {
		return
	}
	if msec <= lastFixTime {
		http.Error(w, "GPS fix is not newer", http.StatusConflict)
		return
	}

	// Get a buffer from the pool
	buf := bufferPool.Get().(*bytes.Buffer)
	defer func() {
		buf.Reset()
		bufferPool.Put(buf)
	}()

	valid := acc >= 0 && acc <= 100
	if valid {
		buildGPRMC(buf, lat, lon, time.UnixMilli(msec), "A", "A")
	} else {
		buf.WriteString(noFixSentence)
	}
	if _, err := ptmx.Write(buf.Bytes()); err != nil {
		log.Printf("Error writing to PTY: %v\n", err)
		http.Error(w, "GPS write failed", http.StatusInternalServerError)
		return
	}
	log.Print(buf.String()[:buf.Len()-2])
	lastFixTime = msec
	if fixTimer != nil {
		fixTimer.Stop()
	}
	fixExpires = time.Time{}
	if valid {
		// Use elapsed time since receipt, independent of the phone/Pager clock offset.
		fixExpires = time.Now().Add(fixMaxAge)
		if fixTimer == nil {
			fixTimer = time.AfterFunc(fixMaxAge, expireFix)
		} else {
			fixTimer.Reset(fixMaxAge)
		}
	}

	w.WriteHeader(http.StatusOK)
}

func expireFix() {
	fixMu.Lock()
	defer fixMu.Unlock()
	// An older timer callback must not invalidate a newer fix.
	if fixExpires.IsZero() || time.Now().Before(fixExpires) {
		return
	}
	if _, err := ptmx.Write([]byte(noFixSentence)); err != nil {
		log.Printf("Error invalidating GPS fix: %v\n", err)
	}
	fixExpires = time.Time{}
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
