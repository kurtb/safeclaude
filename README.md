# safeclaud

Isolated Docker environment for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) without granting it direct access to your host machine. Source code is volume-mounted in at runtime.

## What's Included

| Layer | Details |
|-------|---------|
| Base | Ubuntu 24.04 |
| Node | v22 (nvm) |
| Python | 3.12 |
| Shell | Zsh + Oh My Zsh |
| Zsh plugins | autosuggestions, syntax-highlighting, completions, fzf |
| Tools | git, ripgrep, fzf, jq, build-essential |
| Claude Code | Latest (official installer) |
| User | `ubuntu` (uid 1000) with passwordless sudo |

## Build

```bash
docker build -t safeclaud:latest .
```

## Run

Mount your source code into `/home/ubuntu/workspace` and use a **named volume** for `/home/ubuntu/.claude` to persist authentication and config across container restarts.

### Account setup

If the shared mount directory is done by Docker it is setup as root and claude code had issues reading it. Instead create these ahead of time.

### Personal account

```bash
docker run -it --rm \
  -v ~/dev/my-project:/home/ubuntu/workspace \
  -v claude-personal-config:/home/ubuntu/.claude \
  safeclaud:latest
```

### Work account

```bash
docker run -it --rm \
  -v ~/dev/my-project:/home/ubuntu/workspace \
  -v claude-work-config:/home/ubuntu/.claude \
  safeclaud:latest
```

Using separate named volumes (`claude-personal-config` vs `claude-work-config`) keeps the two accounts fully isolated.

### Custom config directory

Instead of mounting to `/home/ubuntu/.claude`, you can use the `CLAUDE_CONFIG_DIR` environment variable to store Claude Code's config wherever you like:

```bash
docker run -it --rm \
  -e CLAUDE_CONFIG_DIR=/config \
  -v ~/my-claude-config:/config \
  -v ~/dev/my-project:/home/ubuntu/workspace \
  safeclaud:latest
```

## Authentication

The first time you launch a container for a given profile, authenticate inside it:

```bash
claude login
```

Credentials are stored in `/home/ubuntu/.claude`, which is backed by the named volume, so they persist across container restarts. Each profile's volume is independent -- logging into one does not affect the other.

To re-authenticate at any time, run `claude login` again.