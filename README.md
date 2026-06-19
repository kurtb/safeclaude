# safeclaude

Isolated Docker sandbox for running coding agents (Claude Code, Codex, Gemini) in YOLO mode — `--dangerously-skip-permissions` is fine here because the container has no path to your host filesystem outside the project you mounted, and a default-deny firewall restricts outbound network to an allowlist (Anthropic, OpenAI, Google AI, GitHub, npm, PyPI, gcloud, Pulumi, Kubernetes/Helm, container registries, Tailscale).

## What's included

| Layer | Details |
|-------|---------|
| Base | Ubuntu 24.04 |
| Node | v24 via fnm (installed in `~/.local/share/fnm`, lives in the volume) |
| Python | 3.12 |
| Shell | Zsh (via [dotzsh](https://github.com/kurtb/dotzsh)) |
| Editors | Neovim (latest stable), Vim (via [dotvim](https://github.com/kurtb/dotvim)) |
| Agents | Claude Code + Cursor (native installers, auto-update, in `~/.local/bin`); Codex (Rust binary from GitHub release, in `/usr/local/bin`, refreshed by `safeclaude build`); Gemini (npm global in `~/.npm-global`, manual `@latest` upgrade) |
| Skills | [gstack](https://github.com/garrytan/gstack) baked in; personal skills via configurable [`dotclaude`](#personal-skills-dotclaude) repo |
| Cloud | Google Cloud CLI, Pulumi (both in system paths) |
| Tools | git, git-delta, gh (GitHub CLI), ripgrep, fzf, jq, build-essential, tmux |
| Linters | shellcheck, hadolint |
| Network | iptables/ipset default-deny firewall (allowlist applied at container start) |
| User | `ubuntu` (uid 1000), **no general sudo** — only `init-firewall.sh`, zsh login shell |

## Model

One container + one Docker volume per project directory.

- Container name and volume name = `safeclaude-<basename-of-PWD>` (override with `safeclaude <name>` or `--name`).
- The named volume is mounted at `/home/ubuntu` and seeded from the image on first run. It persists auth tokens, shell history, project memory, and any skills you install at runtime. Rebuilding the image upgrades the *floor* of tool versions; the volume keeps your state.
- The current directory is bind-mounted at `/home/ubuntu/workspace/<name>` so the agent can edit your source. Nothing else on your host is reachable.
- The firewall (`init-firewall.sh`) runs at every container start because iptables state is per-runtime. Requires `--cap-add NET_ADMIN --cap-add NET_RAW`.

## Quickstart

Source the helper in your `.zshrc`:

```zsh
source ~/dev/safeclaude/safeclaude.zsh
```

Build the image once:

```zsh
safeclaude build
```

Use it:

```zsh
cd ~/dev/my-project
safeclaude              # creates container+volume on first run, attaches on later runs
```

Inside the container:

```zsh
claude login            # first time only — auth persists in the volume
yolo-claude             # claude --dangerously-skip-permissions
yolo-codex              # codex --dangerously-bypass-approvals-and-sandbox
yolo-gemini             # gemini --yolo
yolo-cursor             # agent --force  (Cursor's CLI binary is named `agent`)
```

`yolo-claude` skips Claude Code's one-time "bypass permissions mode" acceptance
prompt — the image ships `~/.claude/settings.json` with
`skipDangerousModePermissionPrompt: true`. This is seeded into fresh volumes on
first run; existing volumes keep their current settings (add the key by hand or
`safeclaude rm` to reset).

Open a second shell into the same container (e.g. parallel worker):

```zsh
safeclaude              # same project dir; reuses the running container via docker exec
```

## Commands

```
safeclaude                       Start/attach for the current dir
safeclaude <name>                Same, with explicit container/volume name
safeclaude build [args...]       Rebuild the image (pass-through, e.g. --no-cache)
safeclaude list                  Show all safeclaude containers + volumes
safeclaude stop     [name]       Stop a container (default: current dir's)
safeclaude recreate [name]       Replace container from current image, preserving volume
safeclaude rm       [name]       Destroy container + volume (default: current dir's)
safeclaude help                  Show usage
```

## Personal skills (dotclaude)

Skills and slash commands that follow you across projects belong in a personal repo, modeled on `dotzsh`/`dotvim`. The Dockerfile clones it at build time and runs `install.sh` if present.

Default: `https://github.com/kurtb/dotclaude` (may not exist yet — build is non-fatal).

Override with your own:

```zsh
safeclaude build --build-arg DOTCLAUDE_REPO=https://github.com/you/dotclaude \
                 --build-arg DOTCLAUDE_REF=main
```

Suggested repo layout:

```
dotclaude/
  install.sh         # symlinks skills/ into ~/.claude/skills/personal/, etc.
  skills/            # SKILL.md files (Claude format)
  commands/          # slash commands
  AGENTS.md          # cross-agent guidance (symlinked to ~/AGENTS.md, ~/GEMINI.md)
```

## Firewall

`init-firewall.sh` (adapted from [anthropics/claude-code/.devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer)) sets iptables `OUTPUT` policy to `DROP`, then allows:

- GitHub's published IP ranges (from `api.github.com/meta`)
- Anthropic, OpenAI, Google AI / gcloud endpoints
- npm, PyPI, Ubuntu apt mirrors
- Pulumi, GitHub auxiliary CDNs (objects, raw, codeload), GitHub Pages
- Kubernetes (`dl.k8s.io`, `registry.k8s.io`) and Helm (`get.helm.sh`)
- Container registries (`ghcr.io`, `quay.io`, `docker.io`)
- Tailscale package mirror
- Localhost, your Docker host network, DNS, SSH

Egress to anything else is rejected. To allowlist more domains, edit `init-firewall.sh` and rebuild.

## State and upgrades

Three upgrade paths, depending on tool:

- **Image-controlled** (gh, gcloud, neovim, hadolint, shellcheck, pulumi, codex, firewall script, OS packages) live in `/usr` or `/opt`. `safeclaude build` produces a new image; `safeclaude recreate` replaces the running container with one from that image while preserving the volume. (`safeclaude` alone reattaches the existing container and won't pick up image changes.)
- **Self-updating** (Claude Code, Cursor) live in `~/.local/bin` and are seeded into the volume on first container start. They auto-update in the background. `safeclaude build` does NOT refresh them on existing volumes — they keep themselves current, or use `safeclaude rm` for a clean reset (costs a re-auth).
- **Manual** (Gemini CLI, fnm-managed node) live in the volume but neither auto-update nor are refreshed by image rebuilds. Upgrade via `npm install -g @google/gemini-cli@latest` / `fnm install <version>` inside the container, or wipe with `safeclaude rm`.

## Manual docker invocation

If you don't want to use the wrapper:

```bash
docker volume create safeclaude-myproj
docker run -d --name safeclaude-myproj \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  -v safeclaude-myproj:/home/ubuntu \
  -v "$PWD:/home/ubuntu/workspace/myproj" \
  safeclaud:latest

docker exec -it -w /home/ubuntu/workspace/myproj safeclaude-myproj zsh
```
