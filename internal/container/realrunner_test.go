package container

import (
	"strings"
	"testing"
)

func TestRealRunnerOutput(t *testing.T) {
	r := &realRunner{}
	out, err := r.Output("echo", "hello")
	if err != nil {
		t.Fatalf("Output() error = %v", err)
	}
	if !strings.Contains(string(out), "hello") {
		t.Errorf("Output() = %q, want to contain 'hello'", out)
	}
}

func TestRealRunnerRun(t *testing.T) {
	r := &realRunner{}
	err := r.Run("true")
	if err != nil {
		t.Fatalf("Run() error = %v", err)
	}
}

func TestRealRunnerRunInteractive(t *testing.T) {
	r := &realRunner{}
	err := r.RunInteractive("true")
	if err != nil {
		t.Fatalf("RunInteractive() error = %v", err)
	}
}
