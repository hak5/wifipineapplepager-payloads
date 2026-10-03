//go:build linux

package main

import "syscall"

func selectReadable(fd int, readSet *syscall.FdSet, timeout *syscall.Timeval) (int, error) {
	return syscall.Select(fd+1, readSet, nil, nil, timeout)
}
