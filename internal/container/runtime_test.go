package container

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"testing"
)

func mockExecFn(binary string, args []string, env []string) error {
	return nil
}

// mockRunner records calls and returns configured responses.
type mockRunner struct {
	outputResult []byte
	outputErr    error
	runErr       error
	interactErr  error
	lastCmd      string
	lastArgs     []string
}

func (m *mockRunner) Output(name string, args ...string) ([]byte, error) {
	m.lastCmd = name
	m.lastArgs = args
	return m.outputResult, m.outputErr
}

func (m *mockRunner) Run(name string, args ...string) error {
	m.lastCmd = name
	m.lastArgs = args
	return m.runErr
}

func (m *mockRunner) RunInteractive(name string, args ...string) error {
	m.lastCmd = name
	m.lastArgs = args
	return m.interactErr
}

// --- DetectRuntime tests ---

func TestDetectRuntimeFromEnv(t *testing.T) {
	origLookPath := lookPath
	t.Cleanup(func() { lookPath = origLookPath })

	lookPath = func(name string) (string, error) {
		if name == "custom-runtime" {
			return "/usr/bin/custom-runtime", nil
		}
		return "", &exec.Error{Name: name, Err: exec.ErrNotFound}
	}

	t.Setenv("SAFECLAUDE_RUNTIME", "custom-runtime")

	rt, err := DetectRuntime(mockExecFn)
	if err != nil {
		t.Fatalf("DetectRuntime() error = %v", err)
	}
	if rt.Binary() != "/usr/bin/custom-runtime" {
		t.Errorf("Binary() = %q, want %q", rt.Binary(), "/usr/bin/custom-runtime")
	}
}

func TestDetectRuntimeFromEnvNotFound(t *testing.T) {
	origLookPath := lookPath
	t.Cleanup(func() { lookPath = origLookPath })

	lookPath = func(name string) (string, error) {
		return "", &exec.Error{Name: name, Err: exec.ErrNotFound}
	}

	t.Setenv("SAFECLAUDE_RUNTIME", "nonexistent-runtime")

	_, err := DetectRuntime(mockExecFn)
	if err == nil {
		t.Fatal("DetectRuntime() expected error for non-existent runtime")
	}
}

func TestDetectRuntimeDockerFirst(t *testing.T) {
	origLookPath := lookPath
	t.Cleanup(func() { lookPath = origLookPath })

	lookPath = func(name string) (string, error) {
		switch name {
		case "docker":
			return "/usr/bin/docker", nil
		case "podman":
			return "/usr/bin/podman", nil
		}
		return "", &exec.Error{Name: name, Err: exec.ErrNotFound}
	}

	t.Setenv("SAFECLAUDE_RUNTIME", "")

	rt, err := DetectRuntime(mockExecFn)
	if err != nil {
		t.Fatalf("DetectRuntime() error = %v", err)
	}
	if rt.Binary() != "/usr/bin/docker" {
		t.Errorf("Binary() = %q, want docker", rt.Binary())
	}
}

func TestDetectRuntimePodmanFallback(t *testing.T) {
	origLookPath := lookPath
	t.Cleanup(func() { lookPath = origLookPath })

	lookPath = func(name string) (string, error) {
		if name == "podman" {
			return "/usr/bin/podman", nil
		}
		return "", &exec.Error{Name: name, Err: exec.ErrNotFound}
	}

	t.Setenv("SAFECLAUDE_RUNTIME", "")

	rt, err := DetectRuntime(mockExecFn)
	if err != nil {
		t.Fatalf("DetectRuntime() error = %v", err)
	}
	if rt.Binary() != "/usr/bin/podman" {
		t.Errorf("Binary() = %q, want podman", rt.Binary())
	}
}

func TestDetectRuntimeNoneFound(t *testing.T) {
	origLookPath := lookPath
	t.Cleanup(func() { lookPath = origLookPath })

	lookPath = func(name string) (string, error) {
		return "", &exec.Error{Name: name, Err: exec.ErrNotFound}
	}

	t.Setenv("SAFECLAUDE_RUNTIME", "")

	_, err := DetectRuntime(mockExecFn)
	if err == nil {
		t.Fatal("DetectRuntime() expected error when no runtime found")
	}
}

// --- CLIRuntime method tests ---

func TestInspectRunning(t *testing.T) {
	info := inspectJSON{Name: "/mycontainer"}
	info.State.Running = true
	data, _ := json.Marshal(info)

	mr := &mockRunner{outputResult: data}
	rt := NewCLIRuntime("/usr/bin/docker", mockExecFn, mr)

	state, err := rt.Inspect("mycontainer")
	if err != nil {
		t.Fatalf("Inspect() error = %v", err)
	}
	if state == nil {
		t.Fatal("Inspect() returned nil state")
	}
	if !state.Running {
		t.Error("state.Running = false, want true")
	}
	if state.Name != "/mycontainer" {
		t.Errorf("state.Name = %q, want %q", state.Name, "/mycontainer")
	}
}

func TestInspectStopped(t *testing.T) {
	info := inspectJSON{Name: "/stopped"}
	info.State.Running = false
	data, _ := json.Marshal(info)

	mr := &mockRunner{outputResult: data}
	rt := NewCLIRuntime("/usr/bin/docker", mockExecFn, mr)

	state, err := rt.Inspect("stopped")
	if err != nil {
		t.Fatalf("Inspect() error = %v", err)
	}
	if state == nil {
		t.Fatal("Inspect() returned nil state")
	}
	if state.Running {
		t.Error("state.Running = true, want false")
	}
}

func TestInspectNotFound(t *testing.T) {
	mr := &mockRunner{outputErr: fmt.Errorf("exit code 1")}
	rt := NewCLIRuntime("/usr/bin/docker", mockExecFn, mr)

	state, err := rt.Inspect("nonexistent")
	if err != nil {
		t.Fatalf("Inspect() error = %v", err)
	}
	if state != nil {
		t.Errorf("Inspect() = %v, want nil for non-existent container", state)
	}
}

func TestInspectBadJSON(t *testing.T) {
	mr := &mockRunner{outputResult: []byte("not json")}
	rt := NewCLIRuntime("/usr/bin/docker", mockExecFn, mr)

	_, err := rt.Inspect("badcontainer")
	if err == nil {
		t.Fatal("Inspect() expected error for bad JSON")
	}
}

func TestCreate(t *testing.T) {
	mr := &mockRunner{}
	rt := NewCLIRuntime("/usr/bin/docker", mockExecFn, mr)

	err := rt.Create([]string{"--name", "mycontainer", "image:latest"})
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}
	if mr.lastArgs[0] != "create" {
		t.Errorf("first arg = %q, want 'create'", mr.lastArgs[0])
	}
}

func TestCreateError(t *testing.T) {
	mr := &mockRunner{runErr: fmt.Errorf("create failed")}
	rt := NewCLIRuntime("/usr/bin/docker", mockExecFn, mr)

	err := rt.Create([]string{"--name", "fail"})
	if err == nil {
		t.Fatal("Create() expected error")
	}
}

func TestStart(t *testing.T) {
	mr := &mockRunner{}
	rt := NewCLIRuntime("/usr/bin/docker", mockExecFn, mr)

	err := rt.Start("mycontainer")
	if err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	if mr.lastArgs[0] != "start" || mr.lastArgs[1] != "mycontainer" {
		t.Errorf("args = %v, want [start mycontainer]", mr.lastArgs)
	}
}

func TestStartError(t *testing.T) {
	mr := &mockRunner{runErr: fmt.Errorf("start failed")}
	rt := NewCLIRuntime("/usr/bin/docker", mockExecFn, mr)

	err := rt.Start("fail")
	if err == nil {
		t.Fatal("Start() expected error")
	}
}

func TestExecReplace(t *testing.T) {
	var calledBinary string
	var calledArgs []string

	rt := NewCLIRuntime("/usr/bin/docker", func(binary string, args []string, env []string) error {
		calledBinary = binary
		calledArgs = args
		return nil
	}, &mockRunner{})

	err := rt.ExecReplace("mycontainer", []string{"/usr/bin/zsh"})
	if err != nil {
		t.Fatalf("ExecReplace() error = %v", err)
	}
	if calledBinary != "/usr/bin/docker" {
		t.Errorf("binary = %q, want /usr/bin/docker", calledBinary)
	}
	expected := []string{"/usr/bin/docker", "exec", "-it", "mycontainer", "/usr/bin/zsh"}
	if len(calledArgs) != len(expected) {
		t.Fatalf("args = %v, want %v", calledArgs, expected)
	}
	for i, arg := range expected {
		if calledArgs[i] != arg {
			t.Errorf("args[%d] = %q, want %q", i, calledArgs[i], arg)
		}
	}
}

func TestExecReplaceError(t *testing.T) {
	rt := NewCLIRuntime("/usr/bin/docker", func(binary string, args []string, env []string) error {
		return fmt.Errorf("exec failed")
	}, &mockRunner{})

	err := rt.ExecReplace("mycontainer", []string{"/usr/bin/zsh"})
	if err == nil {
		t.Fatal("ExecReplace() expected error")
	}
}

func TestRunEphemeral(t *testing.T) {
	mr := &mockRunner{}
	rt := NewCLIRuntime("/usr/bin/docker", mockExecFn, mr)

	err := rt.RunEphemeral([]string{"-it", "--rm", "image:latest"})
	if err != nil {
		t.Fatalf("RunEphemeral() error = %v", err)
	}
	if mr.lastArgs[0] != "run" {
		t.Errorf("first arg = %q, want 'run'", mr.lastArgs[0])
	}
}

func TestRunEphemeralError(t *testing.T) {
	mr := &mockRunner{interactErr: fmt.Errorf("run failed")}
	rt := NewCLIRuntime("/usr/bin/docker", mockExecFn, mr)

	err := rt.RunEphemeral([]string{"-it", "--rm", "image:latest"})
	if err == nil {
		t.Fatal("RunEphemeral() expected error")
	}
}

func TestBuild(t *testing.T) {
	mr := &mockRunner{}
	rt := NewCLIRuntime("/usr/bin/docker", mockExecFn, mr)

	err := rt.Build("/path/to/ctx", "myimage:latest")
	if err != nil {
		t.Fatalf("Build() error = %v", err)
	}
	if mr.lastArgs[0] != "build" {
		t.Errorf("first arg = %q, want 'build'", mr.lastArgs[0])
	}
}

func TestBuildError(t *testing.T) {
	mr := &mockRunner{interactErr: fmt.Errorf("build failed")}
	rt := NewCLIRuntime("/usr/bin/docker", mockExecFn, mr)

	err := rt.Build("/path/to/ctx", "myimage:latest")
	if err == nil {
		t.Fatal("Build() expected error")
	}
}
