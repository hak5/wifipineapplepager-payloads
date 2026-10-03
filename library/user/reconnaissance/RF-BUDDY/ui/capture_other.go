//go:build !linux

package main

// OpenCapturer is Linux-only; host builds (macOS tests) have no capture.
func OpenCapturer(iface string) (Capturer, error) { return nil, errCaptureUnavailable }
