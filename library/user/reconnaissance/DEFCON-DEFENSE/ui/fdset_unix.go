//go:build darwin || linux

package main

import (
	"syscall"
	"unsafe"
)

// setFD is deliberately byte-based because syscall.FdSet uses int32 words on
// Darwin and 32-bit MIPS Linux, but int64 words on common 64-bit Linux hosts.
// DEFCON Defense supports little-endian Darwin development hosts and the
// Pager's little-endian Linux target, where a byte view preserves fd bit order.
func setFD(fd int, set *syscall.FdSet) bool {
	if fd < 0 {
		return false
	}
	bits := unsafe.Slice((*byte)(unsafe.Pointer(set)), int(unsafe.Sizeof(*set)))
	if fd/8 >= len(bits) {
		return false
	}
	bits[fd/8] |= byte(1 << uint(fd%8))
	return true
}

func isFDSet(fd int, set *syscall.FdSet) bool {
	if fd < 0 {
		return false
	}
	bits := unsafe.Slice((*byte)(unsafe.Pointer(set)), int(unsafe.Sizeof(*set)))
	return fd/8 < len(bits) && bits[fd/8]&byte(1<<uint(fd%8)) != 0
}
