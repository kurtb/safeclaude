package version

import (
	"testing"
)

func TestString(t *testing.T) {
	Version = "1.0.0"
	Commit = "abc1234"
	got := String()
	want := "safeclaude 1.0.0 (abc1234)"
	if got != want {
		t.Errorf("String() = %q, want %q", got, want)
	}
}

func TestStringDefaults(t *testing.T) {
	Version = "dev"
	Commit = "unknown"
	got := String()
	want := "safeclaude dev (unknown)"
	if got != want {
		t.Errorf("String() = %q, want %q", got, want)
	}
}
