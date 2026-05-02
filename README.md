# safeclaud

Isolated Docker environment for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — including with `--dangerously-skip-permissions` — without granting it direct access to your host machine or the open internet. Source code is volume-mounted in at runtime; egress is restricted to an allowlist via iptables.

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
| Firewall | iptables + ipset egress allowlist (`init-firewall.sh`) |
| Claude Code | Latest (official installer) |
| User | `ubuntu` (uid 1000); passwordless sudo restricted to `init-firewall.sh` only |

## Egress Firewall

On container start the entrypoint runs `.devcontainer/init-firewall.sh` (adapted from [anthropics/claude-code](https://github.com/anthropics/claude-code/tree/main/.devcontainer)) which sets the default OUTPUT policy to `DROP` and allowlists only:

- `api.anthropic.com`
- `registry.npmjs.org`
- `api.github.com` and the GitHub IP ranges from `https://api.github.com/meta`
- `sentry.io`, `statsig.com`, `statsig.anthropic.com`
- VS Code marketplace + update endpoints
- DNS (UDP/53) and SSH (TCP/22)
- The host network on the default route

Everything else is rejected with `icmp-admin-prohibited`. The script verifies itself on exit by checking that `https://example.com` is unreachable and `https://api.github.com` is reachable.

The container needs `NET_ADMIN` and `NET_RAW` for iptables to work — `safeclaude.zsh` adds these via `--cap-add`. If you forget them (e.g. running `docker run` by hand), the entrypoint exits and the container terminates.

To bypass the firewall for debugging only, set `-e SAFECLAUDE_SKIP_FIREWALL=1`. Don't use this with `--dangerously-skip-permissions`.

### What the firewall does and doesn't protect against

It **does** stop Claude (and a malicious repo Claude is reading) from reaching arbitrary internet hosts, exfiltrating to attacker-controlled endpoints over HTTP, or pulling code from outside the allowlist.

It **does not** protect against:

- DNS-based exfiltration (port 53 has to be open to resolve allowlisted domains).
- Abuse of allowlisted services — a malicious repo can still push to a public GitHub repo, publish to npm, or burn your Anthropic API quota if creds are present in the container.
- Modifications to the mounted workspace (e.g. `.git/hooks/post-commit`) that execute later on your host.
- Tampering with the persisted `CLAUDE_CONFIG_DIR` between sessions.

The "only run trusted code with `--dangerously-skip-permissions`" caveat in Anthropic's docs is real even with the firewall in place.

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
  --cap-add NET_ADMIN --cap-add NET_RAW \
  -v ~/.config/safeclaude/personal:/home/ubuntu/.config/safeclaude/personal \
  -e CLAUDE_CONFIG_DIR=/home/ubuntu/.config/safeclaude/personal \
  -v ~/dev/my-project:/home/ubuntu/workspace/my-project \
  -w /home/ubuntu/workspace/my-project \
  safeclaud:latest
```

`--cap-add NET_ADMIN --cap-add NET_RAW` are required so the entrypoint can install the egress firewall rules. Without them the container will exit immediately.
