//go:build darwin

package main

import "syscall"

func selectReadable(fd int, readSet *syscall.FdSet, timeout *syscall.Timeval) (int, error) {
	if err := syscall.Select(fd+1, readSet, nil, nil, timeout); err != nil {
		return 0, err
	}
	if isFDSet(fd, readSet) {
		return 1, nil
	}
	return 0, nil
}
