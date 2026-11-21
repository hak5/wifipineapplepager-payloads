//go:build darwin

package main

// grabInput is a no-op on development hosts, which have no evdev devices.
func grabInput(int) error { return nil }
