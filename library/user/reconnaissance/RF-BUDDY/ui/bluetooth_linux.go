//go:build linux

package main

import (
	"os/exec"
	"syscall"
)

// setChildDeathSignal makes the child receive SIGINT if this process dies
// (even by SIGKILL), so an orphaned hcitool disables scanning and exits.
func setChildDeathSignal(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGINT}
}
