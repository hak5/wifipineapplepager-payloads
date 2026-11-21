package main

import (
	"runtime"
	"testing"
)

func TestGrabInputBestEffort(t *testing.T) {
	if runtime.GOOS == "linux" {
		// An invalid descriptor must fail cleanly rather than panic.
		if err := grabInput(-1); err == nil {
			t.Fatal("grabInput(-1) on linux should report EBADF")
		}
		return
	}
	if err := grabInput(-1); err != nil {
		t.Fatalf("grabInput on %s = %v, want nil", runtime.GOOS, err)
	}
}
