//go:build !linux

package main

// grabInput is a no-op away from the Pager's Linux kernel.
func grabInput(fd int) error { return nil }
