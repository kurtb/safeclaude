//go:build !windows

package container

import (
	"os"
	"os/exec"
	"testing"
)

func TestExecReplaceProcess(t *testing.T) {
	// The standard Go pattern for testing functions that call syscall.Exec:
	// re-invoke the test binary as a subprocess with a sentinel env var.
	// The subprocess calls ExecReplaceProcess, which replaces itself with
	// the target command. The parent verifies the subprocess exited cleanly.
	if os.Getenv("TEST_EXEC_REPLACE") == "1" {
		// We are the subprocess — call ExecReplaceProcess.
		// This will replace us with "echo hello", which prints and exits 0.
		echoBin, err := exec.LookPath("echo")
		if err != nil {
			os.Exit(1)
		}
		// ExecReplaceProcess never returns on success (process is replaced).
		err = ExecReplaceProcess(echoBin, []string{"echo", "hello"}, os.Environ())
		// If we get here, exec failed.
		t.Fatalf("ExecReplaceProcess returned: %v", err)
	}

	// We are the parent — spawn ourselves as a subprocess.
	cmd := exec.Command(os.Args[0], "-test.run=^TestExecReplaceProcess$")
	cmd.Env = append(os.Environ(), "TEST_EXEC_REPLACE=1")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("subprocess failed: %v\noutput: %s", err, out)
	}
	if string(out) != "hello\n" {
		t.Errorf("subprocess output = %q, want %q", out, "hello\n")
	}
}

func TestExecReplaceProcessInvalidBinary(t *testing.T) {
	err := ExecReplaceProcess("/nonexistent/binary", []string{"nope"}, os.Environ())
	if err == nil {
		t.Fatal("ExecReplaceProcess() expected error for invalid binary")
	}
}
