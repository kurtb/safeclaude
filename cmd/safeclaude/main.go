package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/kurtb/safeclaude/internal/config"
	"github.com/kurtb/safeclaude/internal/container"
	"github.com/kurtb/safeclaude/internal/version"
	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"
)

func main() {
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

var rootCmd = &cobra.Command{
	Use:   "safeclaude",
	Short: "Isolated Docker environment for Claude Code",
	Long:  "SafeClaude runs Claude Code in an isolated Docker container with optional source mounts and port forwarding.",
	RunE:  runRoot,
}

var initCmd = &cobra.Command{
	Use:   "init",
	Short: "Create a .safeclaude.yaml config file",
	RunE:  runInit,
}

var buildCmd = &cobra.Command{
	Use:   "build",
	Short: "Build the safeclaude Docker image",
	RunE:  runBuild,
}

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Print version information",
	Run: func(cmd *cobra.Command, args []string) {
		fmt.Println(version.String())
	},
}

func init() {
	rootCmd.AddCommand(initCmd, buildCmd, versionCmd)
}

func runRoot(cmd *cobra.Command, args []string) error {
	cwd, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("getting working directory: %w", err)
	}

	rt, err := container.DetectRuntime(container.ExecReplaceProcess)
	if err != nil {
		return err
	}

	cfg, err := config.Load(cwd)
	if err != nil {
		return err
	}

	if cfg != nil {
		if err := cfg.Validate(); err != nil {
			return fmt.Errorf("invalid config: %w", err)
		}
	}

	return container.Launch(rt, container.LaunchOptions{
		WorkDir: cwd,
		Config:  cfg,
	})
}

func runInit(cmd *cobra.Command, args []string) error {
	cwd, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("getting working directory: %w", err)
	}

	cfgPath := filepath.Join(cwd, config.FileName)
	if _, err := os.Stat(cfgPath); err == nil {
		fmt.Printf("%s already exists. Overwrite? [y/N]: ", config.FileName)
		scanner := bufio.NewScanner(os.Stdin)
		if scanner.Scan() {
			answer := strings.TrimSpace(strings.ToLower(scanner.Text()))
			if answer != "y" && answer != "yes" {
				fmt.Println("Aborted.")
				return nil
			}
		}
	}

	fmt.Printf("Creating %s in %s\n\n", config.FileName, cwd)

	scanner := bufio.NewScanner(os.Stdin)
	cfg := config.Config{}

	fmt.Println("Additional source directories to mount (empty line to finish):")
	for {
		fmt.Print("  Path: ")
		if !scanner.Scan() {
			break
		}
		path := strings.TrimSpace(scanner.Text())
		if path == "" {
			break
		}
		cfg.Sources = append(cfg.Sources, path)
	}

	fmt.Println("\nPort forwards (e.g. 3000:3000, empty line to finish):")
	for {
		fmt.Print("  Port: ")
		if !scanner.Scan() {
			break
		}
		port := strings.TrimSpace(scanner.Text())
		if port == "" {
			break
		}
		cfg.Ports = append(cfg.Ports, port)
	}

	data, err := yaml.Marshal(&cfg)
	if err != nil {
		return fmt.Errorf("marshaling config: %w", err)
	}

	if err := os.WriteFile(cfgPath, data, 0644); err != nil {
		return fmt.Errorf("writing %s: %w", config.FileName, err)
	}

	fmt.Printf("\nWrote %s\n", cfgPath)
	return nil
}

func runBuild(cmd *cobra.Command, args []string) error {
	rt, err := container.DetectRuntime(container.ExecReplaceProcess)
	if err != nil {
		return err
	}

	// Find the Dockerfile directory — look for Dockerfile relative to the binary,
	// or fall back to current directory
	contextDir, err := findDockerfileDir()
	if err != nil {
		return err
	}

	fmt.Printf("safeclaude: building %s from %s\n", container.ImageName, contextDir)
	return rt.Build(contextDir, container.ImageName)
}

func findDockerfileDir() (string, error) {
	// Try current directory first
	cwd, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("getting working directory: %w", err)
	}

	if _, err := os.Stat(filepath.Join(cwd, "Dockerfile")); err == nil {
		return cwd, nil
	}

	// Try the directory of the executable
	exe, err := os.Executable()
	if err == nil {
		exeDir := filepath.Dir(exe)
		if _, err := os.Stat(filepath.Join(exeDir, "Dockerfile")); err == nil {
			return exeDir, nil
		}
	}

	return "", fmt.Errorf("Dockerfile not found in current directory or executable directory")
}
