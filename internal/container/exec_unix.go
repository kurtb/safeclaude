//go:build !windows

package container

import "syscall"

// ExecReplaceProcess replaces the current process using execve.
func ExecReplaceProcess(binary string, args []string, env []string) error {
	return syscall.Exec(binary, args, env)
}
