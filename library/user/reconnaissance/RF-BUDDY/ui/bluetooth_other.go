//go:build !linux

package main

import "os/exec"

func setChildDeathSignal(cmd *exec.Cmd) {}
