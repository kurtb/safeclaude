package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

const FileName = ".safeclaude.yaml"

// Config represents the per-project safeclaude configuration.
type Config struct {
	Sources []string `yaml:"sources,omitempty"`
	Ports   []string `yaml:"ports,omitempty"`
}

var portRegexp = regexp.MustCompile(`^\d+:\d+(/(?:tcp|udp))?$`)

// Load reads .safeclaude.yaml from dir. Returns (nil, nil) if the file does not exist.
func Load(dir string) (*Config, error) {
	path := filepath.Join(dir, FileName)
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}
	return &cfg, nil
}

// Validate checks that source paths exist and port formats are valid.
// Source paths are expanded (tilde resolution) before checking.
func (c *Config) Validate() error {
	for i, src := range c.Sources {
		expanded := ExpandTilde(src)
		c.Sources[i] = expanded
		info, err := os.Stat(expanded)
		if err != nil {
			return fmt.Errorf("source %q: %w", src, err)
		}
		if !info.IsDir() {
			return fmt.Errorf("source %q: not a directory", src)
		}
	}
	for _, port := range c.Ports {
		if !portRegexp.MatchString(port) {
			return fmt.Errorf("invalid port mapping %q: expected host:container or host:container/tcp|udp", port)
		}
	}
	return nil
}

// userHomeDir is a function variable for testing.
var userHomeDir = os.UserHomeDir

// ExpandTilde replaces a leading ~ with the user's home directory.
func ExpandTilde(path string) string {
	if path == "~" || strings.HasPrefix(path, "~/") {
		home, err := userHomeDir()
		if err != nil {
			return path
		}
		return filepath.Join(home, path[1:])
	}
	return path
}
