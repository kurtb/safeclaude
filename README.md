# safeclaude

Isolated Docker sandbox for running coding agents (Claude Code, Codex, Gemini) in YOLO mode — `--dangerously-skip-permissions` is fine here because the container has no path to your host filesystem outside the project you mounted, and a default-deny firewall restricts outbound network to an allowlist (Anthropic, OpenAI, Google AI, GitHub, npm, PyPI, gcloud, Pulumi, Kubernetes/Helm, container registries, Tailscale).

## What's included

| Layer | Details |
|-------|---------|
| Base | Ubuntu 24.04 (apt packages upgraded at build time) |
| Node | v24 via fnm (installed in `~/.local/share/fnm`, lives in the volume) |
| Bun | Pinned release in `/opt/bun` (system path, refreshed by `safeclaude build`; `bun upgrade` self-updates the volume copy) |
| Python | 3.12 |
| Shell | Zsh (via [dotzsh](https://github.com/kurtb/dotzsh)) |
| Editors | Neovim (latest stable), Vim (via [dotvim](https://github.com/kurtb/dotvim)) |
| Agents | Claude Code + Cursor (native installers, auto-update, in `~/.local/bin`); Codex (Rust binary from GitHub release, in `/usr/local/bin`, refreshed by `safeclaude build`); Gemini (npm global in `~/.npm-global`, manual `@latest` upgrade) |
| Skills | [gstack](https://github.com/garrytan/gstack) baked in — bun and Playwright Chromium (plus its runtime libraries) are included so the full suite works, including the browser-driven skills; personal skills via configurable [`dotclaude`](#personal-skills-dotclaude) repo |
| Cloud | Google Cloud CLI, Pulumi (both in system paths) |
| Tools | git, git-delta, gh (GitHub CLI), ripgrep, fzf, jq, less, build-essential, tmux |
| Linters | shellcheck, hadolint |
| Network | iptables/ipset default-deny firewall (allowlist applied at container start) |
| User | `ubuntu` (uid 1000), **no general sudo** — only `init-firewall.sh`, zsh login shell |

## Model

One container + one Docker volume per project directory.

- Container name and volume name = `safeclaude-<basename-of-PWD>` (override with `safeclaude <name>` or `--name`).
- The named volume is mounted at `/home/ubuntu` and seeded from the image on first run. It persists auth tokens, shell history, project memory, and any skills you install at runtime. Rebuilding the image upgrades the *floor* of tool versions; the volume keeps your state.
- The current directory is bind-mounted at `/home/ubuntu/workspace/<name>` so the agent can edit your source. Nothing else on your host is reachable.
- The firewall (`init-firewall.sh`) runs at every container start because iptables state is per-runtime. Requires `--cap-add NET_ADMIN --cap-add NET_RAW`.
- Containers run with `--init` (tini as PID 1) so orphaned agent subprocesses are reaped instead of accumulating as zombies — the entrypoint is `sleep infinity`, which never would.

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

Need GitHub access (clone, push, `gh`)? Run `gh-auth-setup` — a manual,
one-time-per-volume step, not wired into anything (see
[Credentials](#credentials-github-pat)).

Verify the image is wired up correctly with the built-in smoke test (see
[Testing a build](#testing-a-build)):

```zsh
safeclaude-doctor       # checks tools, yolo wrappers, gstack, gh auth, firewall
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

## Credentials (GitHub PAT)

Coding agents usually need GitHub access (clone, push, `gh`). This is handled by
an **in-container** script, `gh-auth-setup` — there's no host-side token
plumbing and nothing is baked into the image or the container's environment.

It's a manual command — nothing runs it for you, so nothing prompts unless you
ask. Run it whenever you need GitHub access:

- If gh already has a token (stored in the volume), it's a quiet no-op.
- Otherwise it prompts you to paste a GitHub PAT, then runs
  `gh auth login --with-token` + `gh auth setup-git`. Press Enter to skip.

You can also feed it a token non-interactively:

```zsh
gh-auth-setup                    # prompts if gh isn't configured yet
echo "$PAT" | gh-auth-setup      # or pipe a token in
GH_TOKEN=ghp_xxx gh-auth-setup   # or via $GH_TOKEN / $GITHUB_TOKEN
```

Auth is stored under `~/.config/gh` in the persistent volume, so it survives
`recreate` and image rebuilds — you normally configure it once per volume
(re-run any time to rotate). The token is only ever read from stdin, env, or the
hidden prompt; it never lands in the container's env or `docker inspect`.

## Commands

```
safeclaude                       Start/attach for the current dir
safeclaude <name>                Same, with explicit container/volume name
safeclaude build [args...]       Rebuild the image (checkout only; pass-through, e.g. --no-cache)
safeclaude pull                  Pull the latest published image (if using GHCR)
safeclaude list                  Show all safeclaude containers + volumes
safeclaude stop     [name]       Stop a container (default: current dir's)
safeclaude recreate [name]       Update image (pull if remote) + replace container, keep volume
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
- npm, PyPI, Bun, Ubuntu apt mirrors
- Pulumi, GitHub auxiliary CDNs (objects, raw, codeload), GitHub Pages
- Kubernetes (`dl.k8s.io`, `registry.k8s.io`) and Helm (`get.helm.sh`)
- Container registries (`ghcr.io`, `quay.io`, `docker.io`)
- Tailscale: package mirror, coordination/login (`controlplane`/`login.tailscale.com`), and the DERP relay IPs (fetched from the published DERP map — see [Tailscale](#tailscale))
- Localhost, your Docker host network, DNS, SSH

Egress to anything else is rejected. To allowlist more domains, edit `init-firewall.sh` and rebuild.

## Tailscale

Tailscale is installed and runs in **userspace-networking mode** — as the
`ubuntu` user, with no root, no TUN device, and no new sudo — so it preserves
the container's "only `init-firewall` is privileged" boundary. Connect with:

```zsh
tailscale-up                       # prints a login URL to open in your browser
TS_AUTHKEY=tskey-… tailscale-up    # or connect non-interactively with an auth key
```

`tailscale-up` starts `tailscaled` and runs `tailscale up` (extra args pass
through, e.g. `--hostname`, `--ssh`, `--accept-routes`). Auth state lives in
`~/.tailscale` on the volume, so you normally connect once.

Because it's userspace mode, there's no transparent `tailscale0` interface —
instead you get a **SOCKS5 + HTTP proxy on `localhost:1055`**. Point tools at it
to reach tailnet hosts:

```zsh
ALL_PROXY=socks5://localhost:1055 curl http://my-tailnet-host/
HTTPS_PROXY=http://localhost:1055 gh api ...
```

The `tailscale` CLI is aliased in `~/.zshrc` to talk to the userspace daemon's
socket, so `tailscale status` etc. just work.

Egress works because the firewall allowlists Tailscale's coordination/login
hosts and DERP relay IPs. In this locked-down environment direct peer
connections (UDP to arbitrary IPs) are blocked, so traffic **relays through
DERP** over `:443` — reliable, just not the lowest-latency direct path.

> **Want transparent routing instead?** That needs a real TUN device
> (`--device /dev/net/tun` on `docker run`) **and** running `tailscaled` as root
> (a sudoers exception) — which widens the privilege boundary this sandbox
> deliberately keeps narrow. It's intentionally not the default; ask if you want
> that variant wired up.

## State and upgrades

**Which image does the wrapper run?** It resolves in this order: `$SAFECLAUDE_IMAGE`
if set; else the local build tag `safeclaud:latest` when sourced from a checkout
(there's a `Dockerfile` next to `safeclaude.zsh`); else the published
`ghcr.io/kurtb/safeclaude:latest`. So a cloned repo uses your local build, while
a standalone install rides the published image.

**Updating the image** — `safeclaude recreate` is the update path for both flows.
When the image is a registry reference (GHCR), it **pulls the latest first**,
then replaces the container while preserving the volume. `safeclaude pull` pulls
without replacing. For the local flow, `safeclaude build` produces a new
`safeclaud:latest` and `recreate` (no pull — nothing remote) rolls onto it.
(`safeclaude` alone reattaches the existing container and won't pick up image
changes.)

Three upgrade paths, depending on tool:

- **Image-controlled** (gh, gcloud, neovim, hadolint, shellcheck, pulumi, codex, bun, tailscale, firewall script, OS packages) live in `/usr` or `/opt`. Refreshed by a new image — `safeclaude build` (checkout) or a new GHCR publish — applied with `safeclaude recreate`.
- **Self-updating** (Claude Code, Cursor) live in `~/.local/bin` and are seeded into the volume on first container start. They auto-update in the background. `safeclaude build` does NOT refresh them on existing volumes — they keep themselves current, or use `safeclaude rm` for a clean reset (costs a re-auth).
- **Manual** (Gemini CLI, fnm-managed node) live in the volume but neither auto-update nor are refreshed by image rebuilds. Upgrade via `npm install -g @google/gemini-cli@latest` / `fnm install <version>` inside the container, or wipe with `safeclaude rm`.

## Testing a build

After `safeclaude build`, verify the image from inside a container with the
bundled smoke test:

```zsh
safeclaude-doctor
```

It checks that the expected tools are on `PATH`, the `yolo-*` wrappers are
defined, gstack is cloned (and its `browse` binary built), Playwright Chromium
is installed, GitHub auth status, and — crucially — that the firewall both
**blocks** an unlisted host and **allows** GitHub. It exits non-zero if any hard
check fails, so it works as a CI-style gate.

Mind the [state model](#state-and-upgrades) when testing: system-path additions
(bun, `less`, `gh-auth-setup`, `safeclaude-doctor`) show up after
`safeclaude recreate`, but volume-seeded changes (gstack skills, the `yolo-*`
functions in `~/.zshrc`) only appear in a **fresh volume**. To exercise a build
end-to-end without disturbing a project's volume, use a throwaway name:

```zsh
cd /tmp
safeclaude dr-test        # fresh container + volume from the new image
safeclaude-doctor         # run the checks inside it
exit
safeclaude rm dr-test     # clean up
```

## Published image (GHCR)

A GitHub Actions workflow ([`.github/workflows/publish.yml`](.github/workflows/publish.yml))
builds a multi-arch (amd64 + arm64) image and pushes it to
`ghcr.io/kurtb/safeclaude`, so you can skip the ~10-minute local build:

```zsh
docker pull ghcr.io/kurtb/safeclaude:latest
export SAFECLAUDE_IMAGE=ghcr.io/kurtb/safeclaude:latest   # tell the wrapper to use it
safeclaude
```

`SAFECLAUDE_IMAGE` overrides the image the wrapper runs (default:
`safeclaud:latest`, your local build). `docker run` auto-pulls it if it's not
present. Each arch is built on its own **native** runner (not QEMU) because
gstack's setup launches Chromium during the build.

Tags / release process:

| Trigger | Tags published |
|---------|----------------|
| push to `main` | `:latest`, `:sha-<short>` |
| a `vX.Y.Z` tag | `:X.Y.Z`, `:X.Y`, `:X` (SemVer, rolling) |
| "Run workflow" button | same as the ref it runs from |

Every merge to `main` keeps `:latest` current and adds an immutable
`:sha-<short>`. **Cut a named release** with the **Release** workflow
([`.github/workflows/release.yml`](.github/workflows/release.yml)) — from the
Actions tab, "Run workflow", pick a bump (`patch`/`minor`/`major`) or type an
explicit version. It computes the next SemVer tag, creates the git tag + a
GitHub Release with generated notes, and triggers the publish. (For the first
release pick `minor` → `v0.1.0`.) Versioning follows SemVer: **patch** = fixes /
tool bumps, **minor** = new capability (tool/command), **major** = a change to
how you use it (removed/renamed command, changed volume model). You can still
tag by hand (`git tag v0.1.0 && git push origin v0.1.0`) if you prefer.

> The first successful publish creates the GHCR package as **private** — flip it
> to Public once under Packages → `safeclaude` → Settings to match the repo.

Pull requests are gated by a separate build check
([`.github/workflows/build.yml`](.github/workflows/build.yml)) that builds the
image for both arches **without publishing**, so a broken Dockerfile can't reach
`main`.

## Manual docker invocation

If you don't want to use the wrapper:

```bash
docker volume create safeclaude-myproj
docker run -d --name safeclaude-myproj \
  --init \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  -v safeclaude-myproj:/home/ubuntu \
  -v "$PWD:/home/ubuntu/workspace/myproj" \
  safeclaud:latest

docker exec -it -w /home/ubuntu/workspace/myproj safeclaude-myproj zsh
```
