package main

import (
	"errors"
	"syscall"
)

// isTransientRecvErr reports whether a recvfrom error is safe to ride out.
// ENETDOWN is a one-shot sk_err set on AF_PACKET sockets when the interface
// bounces (e.g. pineapd retuning wlan1mon); the socket works again afterwards.
func isTransientRecvErr(err error) bool {
	return errors.Is(err, syscall.EAGAIN) || errors.Is(err, syscall.EINTR) || errors.Is(err, syscall.ENETDOWN)
}
