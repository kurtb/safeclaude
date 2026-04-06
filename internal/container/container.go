package container

import (
	"fmt"
	"path/filepath"

	"github.com/kurtb/safeclaude/internal/config"
)

const (
	ImageName      = "safeclaude:latest"
	containerUser  = "ubuntu"
	workspaceBase  = "/home/ubuntu/workspace"
	containerShell = "/usr/bin/zsh"
)

// LaunchOptions configures how a container is launched.
type LaunchOptions struct {
	WorkDir string
	Config  *config.Config // nil for ephemeral mode
}

// Launch manages the container lifecycle: create, start, or exec into a container.
func Launch(rt Runtime, opts LaunchOptions) error {
	if opts.Config == nil {
		return launchEphemeral(rt, opts)
	}
	return launchPersistent(rt, opts)
}

func launchEphemeral(rt Runtime, opts LaunchOptions) error {
	args := buildEphemeralArgs(opts)
	return rt.RunEphemeral(args)
}

func launchPersistent(rt Runtime, opts LaunchOptions) error {
	name := ContainerName(opts.WorkDir)

	state, err := rt.Inspect(name)
	if err != nil {
		return fmt.Errorf("inspecting container %q: %w", name, err)
	}

	if state != nil && state.Running {
		fmt.Printf("safeclaude: attaching to running container %s\n", name)
		return rt.ExecReplace(name, []string{containerShell})
	}

	if state != nil && !state.Running {
		fmt.Printf("safeclaude: starting stopped container %s\n", name)
		if err := rt.Start(name); err != nil {
			return fmt.Errorf("starting container %q: %w", name, err)
		}
		return rt.ExecReplace(name, []string{containerShell})
	}

	// Container doesn't exist — create, start, exec
	fmt.Printf("safeclaude: creating container %s\n", name)
	createArgs := buildCreateArgs(name, opts)
	if err := rt.Create(createArgs); err != nil {
		return fmt.Errorf("creating container %q: %w", name, err)
	}
	if err := rt.Start(name); err != nil {
		return fmt.Errorf("starting container %q: %w", name, err)
	}
	return rt.ExecReplace(name, []string{containerShell})
}

// buildEphemeralArgs constructs args for `docker run -it --rm ...`.
func buildEphemeralArgs(opts LaunchOptions) []string {
	workspaceName := filepath.Base(opts.WorkDir)
	containerWorkspace := filepath.Join(workspaceBase, workspaceName)

	args := []string{
		"-it", "--rm",
		"-v", fmt.Sprintf("%s:%s", opts.WorkDir, containerWorkspace),
		"-w", containerWorkspace,
	}

	args = append(args, ImageName)
	return args
}

// buildCreateArgs constructs args for `docker create --name ...`.
func buildCreateArgs(name string, opts LaunchOptions) []string {
	workspaceName := filepath.Base(opts.WorkDir)
	containerWorkspace := filepath.Join(workspaceBase, workspaceName)

	args := []string{
		"--name", name,
		"-it",
		"-v", fmt.Sprintf("%s:%s", opts.WorkDir, containerWorkspace),
		"-w", containerWorkspace,
	}

	if opts.Config != nil {
		for _, src := range opts.Config.Sources {
			srcBase := filepath.Base(src)
			containerPath := filepath.Join(workspaceBase, srcBase)
			args = append(args, "-v", fmt.Sprintf("%s:%s", src, containerPath))
		}

		for _, port := range opts.Config.Ports {
			args = append(args, "-p", port)
		}
	}

	args = append(args, ImageName)
	return args
}
