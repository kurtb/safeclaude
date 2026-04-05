package container

import (
	"strings"
	"testing"
)

func TestContainerName(t *testing.T) {
	tests := []struct {
		dir  string
		want string
	}{
		{"/home/user/myproject", "safeclaude-myproject"},
		{"/home/user/my-project", "safeclaude-my-project"},
		{"/home/user/my.project", "safeclaude-my.project"},
		{"/home/user/my_project", "safeclaude-my_project"},
		{"myproject", "safeclaude-myproject"},
	}
	for _, tt := range tests {
		t.Run(tt.dir, func(t *testing.T) {
			got := ContainerName(tt.dir)
			if got != tt.want {
				t.Errorf("ContainerName(%q) = %q, want %q", tt.dir, got, tt.want)
			}
		})
	}
}

func TestContainerNameSpecialChars(t *testing.T) {
	tests := []struct {
		name string
		dir  string
		want string
	}{
		{"spaces", "/home/user/my project", "safeclaude-my-project"},
		{"at sign", "/home/user/@scope", "safeclaude-scope"},
		{"multiple special", "/home/user/a b!c@d", "safeclaude-a-b-c-d"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ContainerName(tt.dir)
			if got != tt.want {
				t.Errorf("ContainerName(%q) = %q, want %q", tt.dir, got, tt.want)
			}
		})
	}
}

func TestContainerNameTruncation(t *testing.T) {
	longName := "/home/user/" + strings.Repeat("a", 100)
	got := ContainerName(longName)
	if len(got) > maxNameLength {
		t.Errorf("ContainerName() len = %d, want <= %d", len(got), maxNameLength)
	}
	if !strings.HasPrefix(got, containerPrefix) {
		t.Errorf("ContainerName() = %q, should start with %q", got, containerPrefix)
	}
}

func TestSanitize(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"simple", "simple"},
		{"with spaces", "with-spaces"},
		{"with.dots", "with.dots"},
		{"with_under", "with_under"},
		{"with-dash", "with-dash"},
		{"UPPER", "UPPER"},
		{"!!!special!!!", "special"},
		{"-leading", "leading"},
		{"trailing-", "trailing"},
		{".leading", "leading"},
		{"trailing.", "trailing"},
		{"", "unnamed"},
		{"!!!", "unnamed"},
		{"---", "unnamed"},
		{"...", "unnamed"},
	}
	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got := sanitize(tt.input)
			if got != tt.want {
				t.Errorf("sanitize(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}
