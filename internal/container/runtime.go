package container

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
)

// ContainerState represents the state of a container as reported by inspect.
type ContainerState struct {
	Name    string
	Running bool
}

// Runtime abstracts the container CLI (docker/podman/etc).
type Runtime interface {
	Inspect(name string) (*ContainerState, error)
	Create(args []string) error
	Start(name string) error
	ExecReplace(name string, cmd []string) error
	RunEphemeral(args []string) error
	Build(contextDir, tag string) error
	Binary() string
}

// CommandRunner executes a command and returns its output.
// Used to abstract exec.Command for testing.
type CommandRunner interface {
	Output(name string, args ...string) ([]byte, error)
	Run(name string, args ...string) error
	RunInteractive(name string, args ...string) error
}

// realRunner implements CommandRunner using os/exec.
type realRunner struct{}

func (r *realRunner) Output(name string, args ...string) ([]byte, error) {
	return exec.Command(name, args...).Output()
}

func (r *realRunner) Run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func (r *realRunner) RunInteractive(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// CLIRuntime implements Runtime by shelling out to a container CLI binary.
type CLIRuntime struct {
	binary string
	execFn func(binary string, args []string, env []string) error
	runner CommandRunner
}

// inspectJSON matches the relevant fields from `docker inspect` output.
type inspectJSON struct {
	Name  string `json:"Name"`
	State struct {
		Running bool `json:"Running"`
	} `json:"State"`
}

// lookPath is a variable for testing.
var lookPath = exec.LookPath

// DetectRuntime finds the container runtime binary.
// Priority: SAFECLAUDE_RUNTIME env > docker > podman.
func DetectRuntime(execFn func(string, []string, []string) error) (*CLIRuntime, error) {
	if rt := os.Getenv("SAFECLAUDE_RUNTIME"); rt != "" {
		path, err := lookPath(rt)
		if err != nil {
			return nil, fmt.Errorf("SAFECLAUDE_RUNTIME=%q: %w", rt, err)
		}
		return &CLIRuntime{binary: path, execFn: execFn, runner: &realRunner{}}, nil
	}

	for _, name := range []string{"docker", "podman"} {
		path, err := lookPath(name)
		if err == nil {
			return &CLIRuntime{binary: path, execFn: execFn, runner: &realRunner{}}, nil
		}
	}

	return nil, fmt.Errorf("no container runtime found: install docker or podman")
}

// NewCLIRuntime creates a CLIRuntime with the given binary, exec function, and command runner.
// Exported for testing.
func NewCLIRuntime(binary string, execFn func(string, []string, []string) error, runner CommandRunner) *CLIRuntime {
	return &CLIRuntime{binary: binary, execFn: execFn, runner: runner}
}

func (r *CLIRuntime) Binary() string {
	return r.binary
}

// Inspect returns the state of a container, or nil if it does not exist.
func (r *CLIRuntime) Inspect(name string) (*ContainerState, error) {
	out, err := r.runner.Output(r.binary, "inspect", "--format", "{{json .}}", name)
	if err != nil {
		// Exit code non-zero means container doesn't exist
		return nil, nil
	}

	var info inspectJSON
	if err := json.Unmarshal(out, &info); err != nil {
		return nil, fmt.Errorf("parsing inspect output: %w", err)
	}

	return &ContainerState{
		Name:    info.Name,
		Running: info.State.Running,
	}, nil
}

// Create runs `<runtime> create` with the given args.
func (r *CLIRuntime) Create(args []string) error {
	cmdArgs := append([]string{"create"}, args...)
	return r.runner.Run(r.binary, cmdArgs...)
}

// Start runs `<runtime> start <name>`.
func (r *CLIRuntime) Start(name string) error {
	return r.runner.Run(r.binary, "start", name)
}

// ExecReplace replaces the current process with `<runtime> exec -it <name> <cmd...>`.
func (r *CLIRuntime) ExecReplace(name string, command []string) error {
	args := append([]string{r.binary, "exec", "-it", name}, command...)
	return r.execFn(r.binary, args, os.Environ())
}

// RunEphemeral runs `<runtime> run` with the given args (blocking, for ephemeral containers).
func (r *CLIRuntime) RunEphemeral(args []string) error {
	cmdArgs := append([]string{"run"}, args...)
	return r.runner.RunInteractive(r.binary, cmdArgs...)
}

// Build runs `<runtime> build -t <tag> <contextDir>`.
func (r *CLIRuntime) Build(contextDir, tag string) error {
	return r.runner.RunInteractive(r.binary, "build", "-t", tag, contextDir)
}
