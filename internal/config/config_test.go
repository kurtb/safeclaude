package config

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadValidConfig(t *testing.T) {
	dir := t.TempDir()
	content := `sources:
  - /tmp/src1
  - /tmp/src2
ports:
  - "3000:3000"
  - "8080:80"
`
	if err := os.WriteFile(filepath.Join(dir, FileName), []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(dir)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg == nil {
		t.Fatal("Load() returned nil config")
	}
	if len(cfg.Sources) != 2 {
		t.Errorf("Sources = %v, want 2 items", cfg.Sources)
	}
	if cfg.Sources[0] != "/tmp/src1" {
		t.Errorf("Sources[0] = %q, want %q", cfg.Sources[0], "/tmp/src1")
	}
	if len(cfg.Ports) != 2 {
		t.Errorf("Ports = %v, want 2 items", cfg.Ports)
	}
	if cfg.Ports[1] != "8080:80" {
		t.Errorf("Ports[1] = %q, want %q", cfg.Ports[1], "8080:80")
	}
}

func TestLoadEmptyFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, FileName), []byte(""), 0644); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(dir)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg == nil {
		t.Fatal("Load() returned nil for empty file")
	}
	if len(cfg.Sources) != 0 {
		t.Errorf("Sources = %v, want empty", cfg.Sources)
	}
	if len(cfg.Ports) != 0 {
		t.Errorf("Ports = %v, want empty", cfg.Ports)
	}
}

func TestLoadMissingFile(t *testing.T) {
	dir := t.TempDir()
	cfg, err := Load(dir)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg != nil {
		t.Errorf("Load() = %v, want nil for missing file", cfg)
	}
}

func TestLoadMalformedYAML(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, FileName), []byte(":::bad\nyaml{{{"), 0644); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(dir)
	if err == nil {
		t.Fatal("Load() expected error for malformed YAML")
	}
	if cfg != nil {
		t.Errorf("Load() config = %v, want nil on error", cfg)
	}
}

func TestLoadUnreadableFile(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("skipping: root can read any file")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, FileName)
	if err := os.WriteFile(path, []byte("sources: []"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(path, 0644) })

	_, err := Load(dir)
	if err == nil {
		t.Fatal("Load() expected error for unreadable file")
	}
}

func TestValidateValidConfig(t *testing.T) {
	dir1 := t.TempDir()
	dir2 := t.TempDir()

	cfg := &Config{
		Sources: []string{dir1, dir2},
		Ports:   []string{"3000:3000", "8080:80", "443:443/tcp", "53:53/udp"},
	}
	if err := cfg.Validate(); err != nil {
		t.Errorf("Validate() error = %v", err)
	}
}

func TestValidateEmptyConfig(t *testing.T) {
	cfg := &Config{}
	if err := cfg.Validate(); err != nil {
		t.Errorf("Validate() error = %v", err)
	}
}

func TestValidateNonExistentSource(t *testing.T) {
	cfg := &Config{
		Sources: []string{"/nonexistent/path/that/does/not/exist"},
	}
	if err := cfg.Validate(); err == nil {
		t.Error("Validate() expected error for non-existent source")
	}
}

func TestValidateSourceIsFile(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "afile.txt")
	if err := os.WriteFile(file, []byte("hello"), 0644); err != nil {
		t.Fatal(err)
	}

	cfg := &Config{Sources: []string{file}}
	err := cfg.Validate()
	if err == nil {
		t.Error("Validate() expected error when source is a file, not directory")
	}
}

func TestValidateInvalidPort(t *testing.T) {
	tests := []struct {
		name string
		port string
	}{
		{"bare port", "3000"},
		{"text", "http:https"},
		{"missing container", "3000:"},
		{"missing host", ":3000"},
		{"invalid protocol", "3000:3000/sctp"},
		{"spaces", "3000 : 3000"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := &Config{Ports: []string{tt.port}}
			if err := cfg.Validate(); err == nil {
				t.Errorf("Validate() expected error for port %q", tt.port)
			}
		})
	}
}

func TestValidateTildeExpansion(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("cannot determine home dir")
	}

	// Create a real directory under home to validate against
	dir := filepath.Join(home, ".safeclaude-test-validate")
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(dir) })

	cfg := &Config{Sources: []string{"~/.safeclaude-test-validate"}}
	if err := cfg.Validate(); err != nil {
		t.Errorf("Validate() error = %v", err)
	}

	// After validation, the path should be expanded
	if cfg.Sources[0] != dir {
		t.Errorf("Sources[0] = %q, want %q", cfg.Sources[0], dir)
	}
}

func TestExpandTilde(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("cannot determine home dir")
	}

	tests := []struct {
		input string
		want  string
	}{
		{"~/foo", filepath.Join(home, "foo")},
		{"~", home},
		{"/absolute/path", "/absolute/path"},
		{"relative/path", "relative/path"},
		{"~user/foo", "~user/foo"}, // only bare ~ is expanded
		{"", ""},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got := ExpandTilde(tt.input)
			if got != tt.want {
				t.Errorf("ExpandTilde(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestExpandTildeHomeDirError(t *testing.T) {
	orig := userHomeDir
	userHomeDir = func() (string, error) {
		return "", fmt.Errorf("no home")
	}
	t.Cleanup(func() { userHomeDir = orig })

	got := ExpandTilde("~/foo")
	if got != "~/foo" {
		t.Errorf("ExpandTilde(~/foo) = %q, want %q (should return unchanged on error)", got, "~/foo")
	}

	got2 := ExpandTilde("~")
	if got2 != "~" {
		t.Errorf("ExpandTilde(~) = %q, want %q", got2, "~")
	}
}

func TestLoadReadError(t *testing.T) {
	// Point Load at a directory where FileName exists as a directory (can't ReadFile a dir)
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, FileName), 0755); err != nil {
		t.Fatal(err)
	}

	_, err := Load(dir)
	if err == nil {
		t.Fatal("Load() expected error when config path is a directory")
	}
}

func TestLoadSourcesOnly(t *testing.T) {
	dir := t.TempDir()
	content := `sources:
  - /tmp/only-sources
`
	if err := os.WriteFile(filepath.Join(dir, FileName), []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(dir)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if len(cfg.Sources) != 1 {
		t.Errorf("Sources = %v, want 1 item", cfg.Sources)
	}
	if len(cfg.Ports) != 0 {
		t.Errorf("Ports = %v, want empty", cfg.Ports)
	}
}

func TestLoadPortsOnly(t *testing.T) {
	dir := t.TempDir()
	content := `ports:
  - "9090:9090"
`
	if err := os.WriteFile(filepath.Join(dir, FileName), []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(dir)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if len(cfg.Sources) != 0 {
		t.Errorf("Sources = %v, want empty", cfg.Sources)
	}
	if len(cfg.Ports) != 1 {
		t.Errorf("Ports = %v, want 1 item", cfg.Ports)
	}
}
