# safeclaude

Isolated Docker environment for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) without granting it direct access to your host machine. Source code is volume-mounted at runtime.

## What's Included

| Layer | Details |
|-------|---------|
| Base | Ubuntu 24.04 |
| Node | v24 (fnm) |
| Python | 3.12 |
| Shell | Zsh (via [dotzsh](https://github.com/kurtb/dotzsh)) |
| Editors | Neovim (latest stable), Vim (via [dotvim](https://github.com/kurtb/dotvim)) |
| Cloud | Google Cloud CLI, Pulumi (latest) |
| Tools | git, gh (GitHub CLI), ripgrep, fzf, jq, build-essential |
| Claude Code | Latest (official installer) |
| User | `ubuntu` (uid 1000) with passwordless sudo |

## Installation

Download the latest binary from [GitHub Releases](https://github.com/kurtb/safeclaude/releases) for your platform (Linux, macOS, Windows × amd64/arm64).

Or build from source:

```bash
go install github.com/kurtb/safeclaude/cmd/safeclaude@latest
```

## Quick Start

### Build the Docker image

```bash
safeclaude build
```

### Run in any project directory

```bash
cd ~/dev/my-project
safeclaude
```

Without a config file, this launches an ephemeral container with your current directory mounted. The container is removed when you exit.

### Persistent containers with config

Create a `.safeclaude.yaml` in your project root:

```bash
safeclaude init
```

Or create it manually:

```yaml
# .safeclaude.yaml
sources:
  - ~/dev/shared-lib
  - ~/dev/proto-definitions
ports:
  - "3000:3000"
  - "8080:8080"
```

- **sources** — additional directories mounted into `/home/ubuntu/workspace/<dirname>` (your project dir is always mounted)
- **ports** — Docker port mappings (`host:container` or `host:container/tcp|udp`)

With a config file present, `safeclaude` creates a persistent named container. Running `safeclaude` again attaches to the existing container instead of creating a new one. State (installed packages, auth tokens, shell history) persists for the lifetime of the container.

### Authenticate inside the container

The first time you enter a container, authenticate:

```bash
claude login
```

Credentials live inside the container — isolated from your host and from other containers.

## Commands

| Command | Description |
|---------|-------------|
| `safeclaude` | Run/attach container (ephemeral without config, persistent with config) |
| `safeclaude init` | Interactive wizard to create `.safeclaude.yaml` |
| `safeclaude build` | Build the Docker image |
| `safeclaude version` | Print version |

## Container Runtime

safeclaude works with Docker and Podman. It auto-detects which is available:

1. `SAFECLAUDE_RUNTIME` env var (if set, uses that binary)
2. `docker` on PATH
3. `podman` on PATH

```bash
# Force podman
SAFECLAUDE_RUNTIME=podman safeclaude
```

## Container Lifecycle

| Scenario | Behavior |
|----------|----------|
| No config file | Ephemeral: `docker run -it --rm` — removed on exit |
| Config file, no existing container | Creates persistent container, starts it, attaches |
| Config file, container stopped | Starts the existing container, attaches |
| Config file, container running | Attaches a new shell to the running container |

Container names are derived from the directory name: `safeclaude-<dirname>`.

## Development

```bash
make build          # Build binary to bin/safeclaude
make test           # Run tests with coverage report
make test-coverage  # Generate HTML coverage report
make docker         # Build Docker image
make clean          # Remove build artifacts
```

## Manual Docker Usage

```bash
docker run -it --rm \
  -v ~/dev/my-project:/home/ubuntu/workspace/my-project \
  -w /home/ubuntu/workspace/my-project \
  safeclaude:latest
```
