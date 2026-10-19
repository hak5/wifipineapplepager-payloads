package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

var leScanAddr = regexp.MustCompile(`^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$`)

// ParseLEScanLine extracts the device address from one `hcitool lescan` line.
func ParseLEScanLine(line string) (string, bool) {
	fields := strings.Fields(line)
	if len(fields) == 0 || !leScanAddr.MatchString(fields[0]) {
		return "", false
	}
	return strings.ToUpper(fields[0]), true
}

// BLEScanner keeps a passive `hcitool lescan` running and, when hcidump is
// available, decodes its btsnoop stream into the tracker.
type BLEScanner struct {
	Iface        string
	Tracker      *BLETracker
	Now          func() time.Time
	RestartDelay time.Duration
}

// leScanArgs returns the hcitool arguments for a passive LE scan.
func leScanArgs(iface string) []string {
	return []string{"-i", iface, "lescan", "--passive", "--duplicates"}
}

// hcidumpArgs returns the hcidump arguments that stream btsnoop to stdout.
func hcidumpArgs(iface string) []string {
	return []string{"-i", iface, "-w", "/dev/stdout"}
}

// scanDisableArgs returns the hcitool arguments for LE Set Scan Enable = off.
func scanDisableArgs(iface string) []string {
	return []string{"-i", iface, "cmd", "0x08", "0x000c", "00", "00"}
}

// disableScan turns controller scanning off; errors are ignored.
func (s *BLEScanner) disableScan(ctx context.Context) {
	_ = exec.CommandContext(ctx, "hcitool", scanDisableArgs(s.Iface)...).Run()
}

// startDump launches hcidump as a sibling child (same SIGINT cancel, 2 s
// WaitDelay and child-death signal as lescan) and returns a stop function that
// signals it and waits for the child and the decoder goroutine. nil when
// hcidump is missing or fails to start.
func (s *BLEScanner) startDump(ctx context.Context) (stop func()) {
	path, err := exec.LookPath("hcidump")
	if err != nil {
		return nil
	}
	dctx, cancel := context.WithCancel(ctx)
	cmd := exec.CommandContext(dctx, path, hcidumpArgs(s.Iface)...)
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.WaitDelay = 2 * time.Second
	setChildDeathSignal(cmd)
	stdout, err := cmd.StdoutPipe()
	if err != nil || cmd.Start() != nil {
		cancel()
		return nil
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		s.consumeDump(stdout)
	}()
	return func() {
		cancel() // SIGINT via cmd.Cancel; SIGKILL after WaitDelay
		<-done   // the decoder must drain the pipe before Wait closes it
		_ = cmd.Wait()
	}
}

func (s *BLEScanner) Run(ctx context.Context) {
	// The first identification lookup parses the embedded OUI table (slow on
	// the Pager); do it now in the background so it never lands on the render
	// loop. The decoder goroutine may block on it, nothing else does.
	go warmBTDB()
	for ctx.Err() == nil {
		_ = exec.CommandContext(ctx, "hciconfig", s.Iface, "up").Run()
		s.disableScan(ctx)
		// hcidump first so no advert is missed once scanning starts.
		stopDump := s.startDump(ctx)
		cmd := exec.CommandContext(ctx, "hcitool", leScanArgs(s.Iface)...)
		// SIGINT lets hcitool disable scanning itself before Go force-kills.
		cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
		cmd.WaitDelay = 2 * time.Second
		// if the UI is SIGKILLed, hcitool still gets SIGINT and disables scanning.
		setChildDeathSignal(cmd)
		if stdout, err := cmd.StdoutPipe(); err == nil && cmd.Start() == nil {
			s.consume(stdout)
			_ = cmd.Wait()
			if stopDump != nil {
				stopDump()
				stopDump = nil
			}
			stopCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			s.disableScan(stopCtx)
			cancel()
		}
		if stopDump != nil {
			stopDump()
		}
		timer := time.NewTimer(s.RestartDelay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}

func (s *BLEScanner) consume(r io.Reader) {
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		if addr, ok := ParseLEScanLine(sc.Text()); ok {
			s.Tracker.ObserveAddr(addr, s.Now())
		}
	}
}

// consumeDump decodes a btsnoop stream into the tracker until EOF or error.
func (s *BLEScanner) consumeDump(r io.Reader) {
	br := bufio.NewReader(r)
	if skipToBTSnoop(br, 4096) != nil {
		_, _ = io.Copy(io.Discard, br) // keep draining so hcidump never blocks
		return
	}
	_ = ReadBTSnoop(br, func(a Advert) { s.Tracker.Observe(a, s.Now()) })
}

// skipToBTSnoop discards bytes up to the btsnoop magic; hcidump writes its
// "HCI sniffer" banner to stdout before the capture when -w is /dev/stdout.
func skipToBTSnoop(br *bufio.Reader, limit int) error {
	for skipped := 0; skipped <= limit; skipped++ {
		head, err := br.Peek(len(btsnoopMagic))
		if err != nil {
			return err
		}
		if bytes.Equal(head, btsnoopMagic) {
			return nil
		}
		if _, err := br.Discard(1); err != nil {
			return err
		}
	}
	return errors.New("btsnoop: no header in hcidump output")
}

// BluetoothAvailable reports whether hcitool and the adapter both exist.
func BluetoothAvailable(iface string) bool {
	if _, err := exec.LookPath("hcitool"); err != nil {
		return false
	}
	_, err := os.Stat("/sys/class/bluetooth/" + iface)
	return err == nil
}
