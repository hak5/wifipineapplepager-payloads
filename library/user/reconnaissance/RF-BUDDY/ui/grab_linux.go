//go:build linux

package main

import (
	"runtime"
	"syscall"
)

// grabInput takes an exclusive EVIOCGRAB on an evdev fd so the stock Pager UI
// stops seeing button presses. The kernel drops the grab when the fd closes.
// EVIOCGRAB is _IOW('E', 0x90, int): the direction bits differ on MIPS.
func grabInput(fd int) error {
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
