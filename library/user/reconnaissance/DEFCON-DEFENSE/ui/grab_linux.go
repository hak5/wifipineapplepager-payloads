//go:build linux

package main

import (
	"runtime"
	"syscall"
)

// grabInput takes exclusive delivery of the Pager buttons (EVIOCGRAB). The
// stock firmware UI is frozen while DEFCON Defense runs; without the grab its
// evdev queue would collect every in-app press and replay them into the menu
// when it resumes. The kernel drops the grab when this descriptor closes.
func grabInput(fd int) error {
	// _IOW('E', 0x90, int): MIPS encodes the write direction as bit 31, while
	// the generic Linux ioctl layout uses bit 30.
	request := uintptr(0x40044590)
	switch runtime.GOARCH {
	case "mips", "mipsle", "mips64", "mips64le":
		request = 0x80044590
	}
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), request, 1); errno != 0 {
		return errno
	}
	return nil
}
