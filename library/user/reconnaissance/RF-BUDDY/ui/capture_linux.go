//go:build linux

package main

import (
	"context"
	"errors"
	"net"
	"syscall"
	"time"
)

// packetCapturer is a receive-only AF_PACKET socket bound to the monitor
// interface. It never writes to the socket.
type packetCapturer struct{ fd int }

func htons(v uint16) uint16 { return v<<8 | v>>8 }

func OpenCapturer(iface string) (Capturer, error) {
	ifi, err := net.InterfaceByName(iface)
	if err != nil {
		return nil, err
	}
	fd, err := syscall.Socket(syscall.AF_PACKET, syscall.SOCK_RAW, int(htons(syscall.ETH_P_ALL)))
	if err != nil {
		return nil, err
	}
	if err := syscall.Bind(fd, &syscall.SockaddrLinklayer{Protocol: htons(syscall.ETH_P_ALL), Ifindex: ifi.Index}); err != nil {
		syscall.Close(fd)
		return nil, err
	}
	tv := syscall.NsecToTimeval(int64(100 * time.Millisecond))
	if err := syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv); err != nil {
		syscall.Close(fd)
		return nil, err
	}
	return &packetCapturer{fd: fd}, nil
}

// drain discards packets queued before the radio settled on the new channel.
func (p *packetCapturer) drain() {
	buf := make([]byte, 64)
	for i := 0; i < 10000; i++ {
		if _, _, err := syscall.Recvfrom(p.fd, buf, syscall.MSG_DONTWAIT); err != nil {
			return
		}
	}
}

func (p *packetCapturer) Capture(ctx context.Context, d time.Duration, fn func([]byte)) error {
	p.drain()
	buf := make([]byte, 8192)
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if err := ctx.Err(); err != nil {
			return err
		}
		n, _, err := syscall.Recvfrom(p.fd, buf, 0)
		if err != nil {
			if isTransientRecvErr(err) {
				if errors.Is(err, syscall.ENETDOWN) {
					// One-shot sk_err after pineapd bounces the interface.
					wait := 20 * time.Millisecond
					if rem := time.Until(deadline); rem < wait {
						wait = rem
					}
					sleepCtx(ctx, wait)
				}
				continue
			}
			return err
		}
		fn(buf[:n])
	}
	return nil
}

func (p *packetCapturer) Close() error { return syscall.Close(p.fd) }
