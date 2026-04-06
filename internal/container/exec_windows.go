//go:build windows

package container

import (
	"os"
	"os/exec"
)

// ExecReplaceProcess on Windows uses os/exec since syscall.Exec is not available.
func ExecReplaceProcess(binary string, args []string, env []string) error {
	cmd := exec.Command(binary, args[1:]...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = env
	return cmd.Run()
}
