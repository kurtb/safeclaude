# safeclaud

Isolated Docker environment for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) without granting it direct access to your host machine. Source code is volume-mounted in at runtime.

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

## Zsh Helper

Source `safeclaude.zsh` in your `.zshrc` for a convenient wrapper:

```zsh
source ~/dev/safeclaude/safeclaude.zsh
```

### Build the image

```zsh
safeclaude build
```

### Run with an environment

Environments are named profiles (e.g. `personal`, `work`) whose config is stored in `~/.config/safeclaude/<env>` on your host and mounted into the container at the same path. `CLAUDE_CONFIG_DIR` is set to that path so Claude credentials and config are isolated per environment.

The current directory (or a path you specify) is mounted into `/home/ubuntu/workspace/<dirname>` inside the container.

```zsh
safeclaude personal                    # current dir, personal account
safeclaude work ~/dev/my-project       # specific path, work account
safeclaude list                        # list configured environments
safeclaude --help                      # show usage
```

The first time you use an environment, authenticate inside the container:

```zsh
claude login
```

Credentials persist in `~/.config/safeclaude/<env>` on your host across container restarts.

## Manual Docker Usage

```bash
docker run -it --rm \
  -v ~/.config/safeclaude/personal:~/.config/safeclaude/personal \
  -e CLAUDE_CONFIG_DIR=~/.config/safeclaude/personal \
  -v ~/dev/my-project:/home/ubuntu/workspace/my-project \
  -w /home/ubuntu/workspace/my-project \
  safeclaud:latest
```
