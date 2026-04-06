# SafeClaude Design Document

## Overview

SafeClaude is a Docker-based sandbox for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) without granting it direct access to your host machine. The CLI manages container lifecycle, per-project configuration, and source code mounting.

## Goals

1. **Isolation** — Claude Code runs inside a Docker container with no host access beyond explicitly mounted directories
2. **Simplicity** — `safeclaude` in a project directory is all you need
3. **Persistence** — containers survive restarts; auth, packages, and history persist for the container's lifetime
4. **Portability** — single binary for Linux, macOS, and Windows; works with Docker and Podman

## Non-Goals

- Shared credential management across containers (each container authenticates independently)
- Docker image registry / distribution (users build locally)
- Multi-container orchestration (one container per project)

## Architecture

```
┌─────────────────────────────────────────────┐
│  safeclaude CLI (Go binary)                 │
│                                             │
│  ┌──────────┐  ┌───────────┐  ┌──────────┐ │
│  │  config   │  │ container │  │ version  │ │
│  │  package  │  │  package  │  │ package  │ │
│  └──────────┘  └───────────┘  └──────────┘ │
│                      │                      │
│              ┌───────┴────────┐             │
│              │ Runtime iface  │             │
│              └───────┬────────┘             │
│           ┌──────────┼──────────┐           │
│           ▼          ▼          ▼           │
│        docker     podman     nerdctl        │
│         CLI        CLI        CLI           │
└─────────────────────────────────────────────┘
                     │
          ┌──────────┴──────────┐
          ▼                     ▼
   ┌─────────────┐      ┌─────────────┐
   │  Ephemeral   │      │ Persistent  │
   │  Container   │      │ Container   │
   │  (--rm)      │      │ (named)     │
   └─────────────┘      └─────────────┘
```

## Dependencies

| Package | Stars | Description |
|---------|-------|-------------|
| [github.com/spf13/cobra](https://github.com/spf13/cobra) | ~43.6k | CLI framework with subcommands, flags, and shell completion |
| [gopkg.in/yaml.v3](https://github.com/go-yaml/yaml) | ~7k | YAML 1.2 parser and encoder for Go |
| [goreleaser](https://github.com/goreleaser/goreleaser) | ~15.7k | Release automation — builds cross-platform binaries and publishes to GitHub Releases |

All other dependencies are Go stdlib: `os/exec`, `syscall`, `encoding/json`, `path/filepath`, `bufio`, `regexp`.

### Why these choices

- **Cobra** over alternatives (urfave/cli, kong): Cobra is the de facto standard for Go CLIs (used by kubectl, docker, hugo). Best documentation, largest community.
- **yaml.v3** over alternatives: The canonical Go YAML library. No reason to use anything else.
- **No Docker SDK**: We shell out to the `docker`/`podman` CLI instead of using `github.com/docker/docker/client`. The SDK pulls in ~50 transitive dependencies for operations that are one-liners via CLI. Since we need `docker exec -it` with TTY passthrough anyway (which the SDK handles poorly), going CLI-only is simpler and keeps the binary small.

## Config Format

Per-project configuration lives in `.safeclaude.yaml` at the project root:

```yaml
# .safeclaude.yaml
sources:
  - ~/dev/shared-lib
  - ~/dev/proto-definitions
ports:
  - "3000:3000"
  - "8080:8080"
```

| Field | Type | Description |
|-------|------|-------------|
| `sources` | `[]string` | Additional host directories to mount into `/home/ubuntu/workspace/<basename>`. The project directory is always mounted implicitly. Supports `~` expansion. |
| `ports` | `[]string` | Docker port mappings in `host:container` or `host:container/tcp\|udp` format. |

**Design decisions:**
- No `name` field — container name is always derived deterministically from the directory name (`safeclaude-<dirname>`). This prevents configuration drift.
- No `image` field — always uses `safeclaude:latest`. Customization happens via the Dockerfile.
- No `env` field — the old environment concept is removed. Each container authenticates independently.

## CLI Commands

| Command | Description |
|---------|-------------|
| `safeclaude` | Default action: run or attach to a container based on CWD |
| `safeclaude init` | Interactive wizard to create `.safeclaude.yaml` |
| `safeclaude build` | Build the Docker image (`safeclaude:latest`) |
| `safeclaude version` | Print version and commit hash |

### Default command behavior

```
safeclaude (no args)
    │
    ├── .safeclaude.yaml exists? ──── No ──→ Ephemeral mode
    │         │                              docker run -it --rm
    │        Yes                             (CWD mounted, removed on exit)
    │         │
    │         ▼
    │   Container exists?
    │         │
    │    ┌────┼────┐
    │    │    │    │
    │  Running Stopped  Missing
    │    │    │         │
    │    ▼    ▼         ▼
    │  exec  start    create
    │  -it   + exec   + start
    │         -it     + exec -it
    │
    └── All paths end with an interactive shell in the container
```

## Container Runtime Abstraction

The `Runtime` interface abstracts all container operations:

```go
type Runtime interface {
    Inspect(name string) (*ContainerState, error)
    Create(args []string) error
    Start(name string) error
    ExecReplace(name string, cmd []string) error
    RunEphemeral(args []string) error
    Build(contextDir, tag string) error
    Binary() string
}
```

**Auto-detection priority:**
1. `SAFECLAUDE_RUNTIME` env var → use that binary path
2. `docker` on `PATH`
3. `podman` on `PATH`
4. Error with install instructions

This works because Podman is CLI-compatible with Docker for the commands we use (`run`, `exec`, `create`, `start`, `inspect`, `build`).

## TTY Handling

The critical design challenge is attaching an interactive terminal to a container. We use `syscall.Exec()` (Unix `execve`) for the final `docker exec -it` call:

```go
// exec_unix.go
func ExecReplaceProcess(binary string, args []string, env []string) error {
    return syscall.Exec(binary, args, env)
}
```

This **replaces the Go process entirely** with the docker process:
- Same PID, same terminal session
- Perfect signal handling (Ctrl-C goes to the container, not Go)
- Zero overhead — no Go runtime lingering
- Works identically on Linux and macOS (both are Unix)

On Windows, `syscall.Exec` doesn't exist, so we fall back to `os/exec` with stdin/stdout/stderr piped through.

## Container Naming

Container names follow the pattern `safeclaude-<sanitized-dirname>`:

- Invalid Docker name characters (`[^a-zA-Z0-9_.-]`) are replaced with `-`
- Leading/trailing `-` and `.` are trimmed
- Names are truncated to 64 characters
- Empty results after sanitization become `unnamed`

**Name collisions:** If two directories have the same basename (e.g., `/a/myproject` and `/b/myproject`), they share the container name. This is acceptable — the user would see the existing container and can remove it. A future enhancement could add path-based disambiguation.

## Testability

### Design principle: Interface-based dependency injection

All external dependencies are behind interfaces. Tests use mocks — no Docker daemon needed for unit tests.

| Layer | Testability approach |
|-------|---------------------|
| `config.Load()` | Temp directories with various `.safeclaude.yaml` contents |
| `config.Validate()` | Temp directories for source path validation |
| `config.ExpandTilde()` | Injectable `userHomeDir` function variable |
| Container lifecycle | Mock `Runtime` interface records calls and returns configured responses |
| `CLIRuntime` methods | Injectable `CommandRunner` interface wraps `exec.Command` |
| Runtime detection | Injectable `lookPath` function variable |
| `syscall.Exec` | Injectable `execFn` function parameter |

### Coverage targets

| Package | Achieved | Notes |
|---------|----------|-------|
| `internal/config` | 100% | All branches covered via temp dirs |
| `internal/container` | 98.9% | Only `ExecReplaceProcess` (1 line, `syscall.Exec` wrapper) uncovered |
| `internal/version` | 100% | Trivial string formatting |
| `cmd/safeclaude` | 0% | Thin CLI wiring — cobra handlers delegate to internal packages |

## Project Structure

```
safeclaude/
├── cmd/safeclaude/main.go          # Entry point, cobra commands (thin wiring)
├── internal/
│   ├── config/
│   │   ├── config.go               # Config types, Load(), Validate(), ExpandTilde()
│   │   └── config_test.go
│   ├── container/
│   │   ├── container.go            # Launch(), lifecycle logic
│   │   ├── container_test.go
│   │   ├── runtime.go              # Runtime interface, CLIRuntime, DetectRuntime()
│   │   ├── runtime_test.go
│   │   ├── exec_unix.go            # syscall.Exec (build-tagged !windows)
│   │   ├── exec_windows.go         # os/exec fallback (build-tagged windows)
│   │   ├── names.go                # ContainerName(), sanitize()
│   │   ├── names_test.go
│   │   └── realrunner_test.go
│   └── version/
│       ├── version.go              # Version, Commit (ldflags)
│       └── version_test.go
├── .github/workflows/
│   ├── ci.yaml                     # PR and merge checks
│   └── release.yaml                # goreleaser on tag push
├── Dockerfile
├── Makefile
├── .goreleaser.yaml
├── go.mod / go.sum
├── README.md
└── CLAUDE.md
```

## Build & Release

### Local development

```bash
make build          # Binary to bin/safeclaude (with version/commit via ldflags)
make test           # Run tests with coverage
make test-coverage  # Generate HTML coverage report
make docker         # Build Docker image
```

### Release process (automated via conventional commits)

Releases are fully automated using [release-please](https://github.com/googleapis/release-please) and [goreleaser](https://github.com/goreleaser/goreleaser):

```
Push to main with conventional commit messages
        │
        ▼
  CI runs (build + vet + test + coverage gate)
        │
        ▼
  release-please analyzes commits since last tag
        │
        ├── feat: ... → MINOR bump
        ├── fix: ...  → PATCH bump
        ├── feat!: .. → MAJOR bump
        ├── docs: ... → no release
        │
        ▼
  Opens/updates a "Release PR" with:
    - Version bump
    - CHANGELOG.md update
        │
        ▼
  Merge the Release PR
        │
        ▼
  release-please creates git tag (v1.2.3)
        │
        ▼
  Tag triggers release.yaml workflow
        │
        ▼
  GoReleaser builds 6 binaries:
    {linux,darwin,windows} × {amd64,arm64}
        │
        ▼
  Published as GitHub Release with archives:
    .tar.gz (Linux/macOS), .zip (Windows)
```

**Commit message conventions:**

| Prefix | Meaning | Version bump |
|--------|---------|--------------|
| `feat:` | New feature | MINOR (0.1.0 → 0.2.0) |
| `fix:` | Bug fix | PATCH (0.2.0 → 0.2.1) |
| `feat!:` or `BREAKING CHANGE:` | Breaking change | MAJOR (0.2.1 → 1.0.0) |
| `docs:`, `chore:`, `test:`, `ci:` | Non-user-facing | No release |

The version is never stored in the repo — it's derived entirely from git tags.

### Installation methods

| Method | Command |
|--------|---------|
| GitHub Release | Download binary from releases page |
| Go install | `go install github.com/kurtb/safeclaude/cmd/safeclaude@latest` |
| Build from source | `git clone && make build` |

## Security Considerations

- **No host credentials shared** — each container authenticates independently
- **Explicit mounts only** — only the project directory and configured sources are mounted
- **Non-root container user** — runs as `ubuntu` (uid 1000) with passwordless sudo
- **No network restrictions** — containers have full network access (needed for `claude login`, package installs, etc.)
- **Dockerfile trust** — the image pulls from official sources (Ubuntu, GitHub, Google, Pulumi, Claude) with GPG verification where available

## Future Considerations

- **Multi-arch Docker images** — build for both amd64 and arm64 (Apple Silicon native)
- **Container name disambiguation** — hash-based suffix when directories share a basename
- **`safeclaude ps`** — list all safeclaude containers with status
- **`safeclaude stop` / `safeclaude rm`** — manage container lifecycle
- **Shell completion** — cobra supports bash/zsh/fish completion generation
- **Config inheritance** — global `~/.config/safeclaude/config.yaml` merged with per-project config
