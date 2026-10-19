package main

import (
	"errors"
	"fmt"
	"syscall"
	"testing"
)

func TestIsTransientRecvErr(t *testing.T) {
	for _, e := range []error{syscall.EAGAIN, syscall.EINTR, syscall.ENETDOWN, fmt.Errorf("wrap: %w", syscall.ENETDOWN)} {
		if !isTransientRecvErr(e) {
			t.Errorf("%v should be transient", e)
		}
	}
	for _, e := range []error{syscall.EBADF, errors.New("x"), nil} {
		if isTransientRecvErr(e) {
			t.Errorf("%v should not be transient", e)
		}
	}
}
