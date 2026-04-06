package container

import (
	"path/filepath"
	"regexp"
	"strings"
)

const (
	containerPrefix = "safeclaude-"
	maxNameLength   = 64
)

var invalidChars = regexp.MustCompile(`[^a-zA-Z0-9_.-]`)

// ContainerName returns a deterministic Docker container name for a workspace directory.
func ContainerName(dir string) string {
	base := filepath.Base(dir)
	name := containerPrefix + sanitize(base)
	if len(name) > maxNameLength {
		name = name[:maxNameLength]
	}
	return name
}

// sanitize replaces characters that are invalid in Docker container names.
func sanitize(name string) string {
	s := invalidChars.ReplaceAllString(name, "-")
	s = strings.Trim(s, "-.")
	if s == "" {
		return "unnamed"
	}
	return s
}
