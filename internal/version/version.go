package version

import "fmt"

// Set via ldflags at build time.
var (
	Version = "dev"
	Commit  = "unknown"
)

func String() string {
	return fmt.Sprintf("safeclaude %s (%s)", Version, Commit)
}
