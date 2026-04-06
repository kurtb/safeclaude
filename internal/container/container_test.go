package container

import (
	"fmt"
	"testing"

	"github.com/kurtb/safeclaude/internal/config"
)

// testRuntime records all calls for verification.
type testRuntime struct {
	inspectState *ContainerState
	inspectErr   error
	createArgs   []string
	createErr    error
	startName    string
	startErr     error
	startCount   int
	execName     string
	execCmd      []string
	execErr      error
	execCount    int
	runArgs      []string
	runErr       error
	buildDir     string
	buildTag     string
	buildErr     error
	binary       string
}

func (r *testRuntime) Inspect(name string) (*ContainerState, error) {
	return r.inspectState, r.inspectErr
}

func (r *testRuntime) Create(args []string) error {
	r.createArgs = args
	return r.createErr
}

func (r *testRuntime) Start(name string) error {
	r.startName = name
	r.startCount++
	return r.startErr
}

func (r *testRuntime) ExecReplace(name string, cmd []string) error {
	r.execName = name
	r.execCmd = cmd
	r.execCount++
	return r.execErr
}

func (r *testRuntime) RunEphemeral(args []string) error {
	r.runArgs = args
	return r.runErr
}

func (r *testRuntime) Build(contextDir, tag string) error {
	r.buildDir = contextDir
	r.buildTag = tag
	return r.buildErr
}

func (r *testRuntime) Binary() string {
	return r.binary
}

// --- Ephemeral mode tests ---

func TestLaunchEphemeral(t *testing.T) {
	rt := &testRuntime{}
	opts := LaunchOptions{
		WorkDir: "/home/user/myproject",
		Config:  nil,
	}

	err := Launch(rt, opts)
	if err != nil {
		t.Fatalf("Launch() error = %v", err)
	}
	if rt.runArgs == nil {
		t.Fatal("RunEphemeral was not called")
	}
	// Should contain -it, --rm, volume mount, working dir, image
	assertContains(t, rt.runArgs, "-it")
	assertContains(t, rt.runArgs, "--rm")
	assertContains(t, rt.runArgs, "/home/user/myproject:/home/ubuntu/workspace/myproject")
	assertContains(t, rt.runArgs, ImageName)
}

func TestLaunchEphemeralError(t *testing.T) {
	rt := &testRuntime{runErr: fmt.Errorf("run failed")}
	opts := LaunchOptions{
		WorkDir: "/home/user/myproject",
		Config:  nil,
	}

	err := Launch(rt, opts)
	if err == nil {
		t.Fatal("Launch() expected error")
	}
}

// --- Persistent mode: container running ---

func TestLaunchPersistentRunning(t *testing.T) {
	rt := &testRuntime{
		inspectState: &ContainerState{Name: "/safeclaude-myproject", Running: true},
	}
	opts := LaunchOptions{
		WorkDir: "/home/user/myproject",
		Config:  &config.Config{},
	}

	err := Launch(rt, opts)
	if err != nil {
		t.Fatalf("Launch() error = %v", err)
	}
	// Should only exec, not create or start
	if rt.execCount != 1 {
		t.Errorf("ExecReplace called %d times, want 1", rt.execCount)
	}
	if rt.startCount != 0 {
		t.Errorf("Start called %d times, want 0", rt.startCount)
	}
	if rt.createArgs != nil {
		t.Error("Create should not have been called")
	}
	if rt.execName != "safeclaude-myproject" {
		t.Errorf("ExecReplace name = %q, want safeclaude-myproject", rt.execName)
	}
}

func TestLaunchPersistentRunningExecError(t *testing.T) {
	rt := &testRuntime{
		inspectState: &ContainerState{Running: true},
		execErr:      fmt.Errorf("exec failed"),
	}
	opts := LaunchOptions{
		WorkDir: "/home/user/myproject",
		Config:  &config.Config{},
	}

	err := Launch(rt, opts)
	if err == nil {
		t.Fatal("Launch() expected error")
	}
}

// --- Persistent mode: container stopped ---

func TestLaunchPersistentStopped(t *testing.T) {
	rt := &testRuntime{
		inspectState: &ContainerState{Name: "/safeclaude-myproject", Running: false},
	}
	opts := LaunchOptions{
		WorkDir: "/home/user/myproject",
		Config:  &config.Config{},
	}

	err := Launch(rt, opts)
	if err != nil {
		t.Fatalf("Launch() error = %v", err)
	}
	if rt.startCount != 1 {
		t.Errorf("Start called %d times, want 1", rt.startCount)
	}
	if rt.execCount != 1 {
		t.Errorf("ExecReplace called %d times, want 1", rt.execCount)
	}
	if rt.createArgs != nil {
		t.Error("Create should not have been called")
	}
}

func TestLaunchPersistentStoppedStartError(t *testing.T) {
	rt := &testRuntime{
		inspectState: &ContainerState{Running: false},
		startErr:     fmt.Errorf("start failed"),
	}
	opts := LaunchOptions{
		WorkDir: "/home/user/myproject",
		Config:  &config.Config{},
	}

	err := Launch(rt, opts)
	if err == nil {
		t.Fatal("Launch() expected error")
	}
	if rt.execCount != 0 {
		t.Error("ExecReplace should not have been called after start error")
	}
}

func TestLaunchPersistentStoppedExecError(t *testing.T) {
	rt := &testRuntime{
		inspectState: &ContainerState{Running: false},
		execErr:      fmt.Errorf("exec failed"),
	}
	opts := LaunchOptions{
		WorkDir: "/home/user/myproject",
		Config:  &config.Config{},
	}

	err := Launch(rt, opts)
	if err == nil {
		t.Fatal("Launch() expected error")
	}
}

// --- Persistent mode: container doesn't exist ---

func TestLaunchPersistentNew(t *testing.T) {
	rt := &testRuntime{
		inspectState: nil, // doesn't exist
	}
	opts := LaunchOptions{
		WorkDir: "/home/user/myproject",
		Config: &config.Config{
			Sources: []string{"/home/user/shared-lib"},
			Ports:   []string{"3000:3000", "8080:80"},
		},
	}

	err := Launch(rt, opts)
	if err != nil {
		t.Fatalf("Launch() error = %v", err)
	}
	if rt.createArgs == nil {
		t.Fatal("Create was not called")
	}
	if rt.startCount != 1 {
		t.Errorf("Start called %d times, want 1", rt.startCount)
	}
	if rt.execCount != 1 {
		t.Errorf("ExecReplace called %d times, want 1", rt.execCount)
	}

	// Verify create args contain the right mounts and ports
	assertContains(t, rt.createArgs, "--name")
	assertContains(t, rt.createArgs, "safeclaude-myproject")
	assertContains(t, rt.createArgs, "/home/user/myproject:/home/ubuntu/workspace/myproject")
	assertContains(t, rt.createArgs, "/home/user/shared-lib:/home/ubuntu/workspace/shared-lib")
	assertContains(t, rt.createArgs, "3000:3000")
	assertContains(t, rt.createArgs, "8080:80")
	assertContains(t, rt.createArgs, ImageName)
}

func TestLaunchPersistentNewCreateError(t *testing.T) {
	rt := &testRuntime{
		inspectState: nil,
		createErr:    fmt.Errorf("create failed"),
	}
	opts := LaunchOptions{
		WorkDir: "/home/user/myproject",
		Config:  &config.Config{},
	}

	err := Launch(rt, opts)
	if err == nil {
		t.Fatal("Launch() expected error")
	}
	if rt.startCount != 0 {
		t.Error("Start should not be called after create error")
	}
}

func TestLaunchPersistentNewStartError(t *testing.T) {
	rt := &testRuntime{
		inspectState: nil,
		startErr:     fmt.Errorf("start failed"),
	}
	opts := LaunchOptions{
		WorkDir: "/home/user/myproject",
		Config:  &config.Config{},
	}

	err := Launch(rt, opts)
	if err == nil {
		t.Fatal("Launch() expected error")
	}
	if rt.execCount != 0 {
		t.Error("ExecReplace should not be called after start error")
	}
}

func TestLaunchPersistentNewExecError(t *testing.T) {
	rt := &testRuntime{
		inspectState: nil,
		execErr:      fmt.Errorf("exec failed"),
	}
	opts := LaunchOptions{
		WorkDir: "/home/user/myproject",
		Config:  &config.Config{},
	}

	err := Launch(rt, opts)
	if err == nil {
		t.Fatal("Launch() expected error")
	}
}

func TestLaunchPersistentInspectError(t *testing.T) {
	rt := &testRuntime{
		inspectErr: fmt.Errorf("inspect failed"),
	}
	opts := LaunchOptions{
		WorkDir: "/home/user/myproject",
		Config:  &config.Config{},
	}

	err := Launch(rt, opts)
	if err == nil {
		t.Fatal("Launch() expected error")
	}
}

// --- buildEphemeralArgs tests ---

func TestBuildEphemeralArgs(t *testing.T) {
	opts := LaunchOptions{WorkDir: "/home/user/myproject"}
	args := buildEphemeralArgs(opts)

	assertContains(t, args, "-it")
	assertContains(t, args, "--rm")
	assertContains(t, args, "/home/user/myproject:/home/ubuntu/workspace/myproject")
	assertContains(t, args, "-w")
	assertContains(t, args, "/home/ubuntu/workspace/myproject")
	assertContains(t, args, ImageName)
}

// --- buildCreateArgs tests ---

func TestBuildCreateArgsNoConfig(t *testing.T) {
	opts := LaunchOptions{
		WorkDir: "/home/user/myproject",
		Config:  nil,
	}
	args := buildCreateArgs("safeclaude-myproject", opts)

	assertContains(t, args, "--name")
	assertContains(t, args, "safeclaude-myproject")
	assertContains(t, args, "/home/user/myproject:/home/ubuntu/workspace/myproject")
	assertContains(t, args, ImageName)
	assertNotContains(t, args, "-p")
}

func TestBuildCreateArgsWithSources(t *testing.T) {
	opts := LaunchOptions{
		WorkDir: "/home/user/myproject",
		Config: &config.Config{
			Sources: []string{"/home/user/lib1", "/home/user/lib2"},
		},
	}
	args := buildCreateArgs("safeclaude-myproject", opts)

	assertContains(t, args, "/home/user/lib1:/home/ubuntu/workspace/lib1")
	assertContains(t, args, "/home/user/lib2:/home/ubuntu/workspace/lib2")
}

func TestBuildCreateArgsWithPorts(t *testing.T) {
	opts := LaunchOptions{
		WorkDir: "/home/user/myproject",
		Config: &config.Config{
			Ports: []string{"3000:3000", "8080:80"},
		},
	}
	args := buildCreateArgs("safeclaude-myproject", opts)

	// Verify port flags
	for i, arg := range args {
		if arg == "-p" {
			if i+1 < len(args) {
				port := args[i+1]
				if port != "3000:3000" && port != "8080:80" {
					t.Errorf("unexpected port mapping: %s", port)
				}
			}
		}
	}
	assertContains(t, args, "3000:3000")
	assertContains(t, args, "8080:80")
}

func TestBuildCreateArgsEmptyConfig(t *testing.T) {
	opts := LaunchOptions{
		WorkDir: "/home/user/myproject",
		Config:  &config.Config{},
	}
	args := buildCreateArgs("safeclaude-myproject", opts)

	assertContains(t, args, "--name")
	assertContains(t, args, ImageName)
	assertNotContains(t, args, "-p")
}

// --- helpers ---

func assertContains(t *testing.T, args []string, want string) {
	t.Helper()
	for _, arg := range args {
		if arg == want {
			return
		}
	}
	t.Errorf("args %v does not contain %q", args, want)
}

func assertNotContains(t *testing.T, args []string, unwanted string) {
	t.Helper()
	for _, arg := range args {
		if arg == unwanted {
			t.Errorf("args %v should not contain %q", args, unwanted)
			return
		}
	}
}
