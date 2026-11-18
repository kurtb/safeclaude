# devvm quickstart (Linux + Incus) — a learning runbook

Stand up one project VM with host-enforced egress, verify the boundary, then run
Claude inside it. Runs on a **Linux host with KVM** (not inside a container).
Each step says *what* and *why*; run them yourself and read the output.

> Status: experimental. Read the known limitations in [`README.md`](README.md)
> before relying on it.

## Phase 0 — host prerequisites (one-time)

```bash
# 0a. Confirm hardware virt + nested virt (needed for minikube's kvm2 inside).
ls -l /dev/kvm                                  # must exist
cat /sys/module/kvm_intel/parameters/nested 2>/dev/null \
  || cat /sys/module/kvm_amd/parameters/nested  # want Y or 1
#   If it's N: echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm.conf
#   then: sudo modprobe -r kvm_intel && sudo modprobe kvm_intel   (AMD: kvm_amd)

# 0b. Install Incus + the egress tooling.
sudo apt update
sudo apt install -y incus haproxy dnsmasq-base nftables curl git
sudo incus admin init --minimal                 # accept the minimal defaults

# 0c. Let your user drive Incus without sudo.
sudo usermod -aG incus-admin "$USER"            # log out/in (or: newgrp incus-admin)

# 0d. Get the code.
git clone https://github.com/kurtb/safeclaude.git
cd safeclaude
```

Why: Incus is the VM manager; HAProxy/dnsmasq/nftables are the host-side egress
gates; `vm/` carries the tooling.

## Phase 1 — install the egress enforcement root-owned (one-time)

```bash
sudo ./vm/install-host.sh      # copies the egress script + config to
                               # /usr/local/lib/devvm (root-owned) and installs
                               # the devvm-proxy service
```

Why: the driver runs the **root-owned installed copy**, never your checkout, so
nothing a repo-writer (or an agent) changes can run as root.

## Phase 2 — boot a project VM

```bash
source ./vm/devvm.sh           # provides the `devvm` function (safe to source)
cd ~/path/to/your-project      # a git repo; a public https origin is cloned inside
devvm                          # create network+VM (first run), apply egress, boot, shell in (bare VM, root)
```

What happens, in order: create `devvmbr0` (Incus firewall off, NAT off, DNS
off — we own all three) → `incus init` the VM stopped → `sudo` the host egress
(by-name proxy + allowlist DNS + default-deny) → start → root shell in
a **bare** VM. Nothing is installed at boot.

Set the VM up by hand, in that root shell:

```bash
apt-get update && apt-get install -y git      # skip if git is already there
git clone https://github.com/kurtb/safeclaude.git
bash safeclaude/vm/guest-setup.sh             # git, gh, Docker, Claude Code + the `dev` user
exit
```

The script runs in the foreground, so you see every step and any failure, and it
is safe to re-run. Back on the host, `devvm shell` now logs you in as `dev`, and
later `devvm` runs also clone a public https origin into
`/home/dev/workspace/<repo>`.

## Phase 3 — verify the boundary (do this before trusting it)

```bash
# From INSIDE the VM shell:
curl -sS --max-time 5 https://example.com            && echo UNEXPECTED || echo "blocked (good)"
curl -sS --max-time 5 https://api.github.com/zen     && echo "allowed (good)"
# A non-allowlisted name aimed at an allowed host's address — must be BLOCKED:
curl -sS --max-time 5 --resolve example.com:443:"$(getent hosts api.github.com | awk '{print $1}')" \
  https://example.com/ && echo UNEXPECTED || echo "blocked (good)"
# An allowed name aimed at a bogus address — WORKS, and that is the point: the
# proxy ignores 1.2.3.4 and connects to the real api.github.com (valid cert).
curl -sS --max-time 5 --resolve api.github.com:443:1.2.3.4 https://api.github.com/zen \
  && echo "reached the real host (good)"
# Nothing but web traffic leaves:
timeout 5 bash -c 'exec 3<>/dev/tcp/github.com/22' && echo UNEXPECTED || echo "ssh blocked (good)"
exit

# From the HOST — look at what's enforcing it:
sudo nft list table inet devvm        # DNAT to the proxy + input/forward chains
systemctl status devvm-proxy          # the by-name proxy
journalctl -u devvm-proxy -n 20       # one line per connection: name -> address
incus network show devvmbr0           # firewall/nat/dns all off (we own them)
incus list                            # your VM
```

Why: this is the whole point — confirm that only allowlisted *names* get out,
and that the guest cannot choose where a connection really goes.

## Phase 4 — log in and start Claude inside

Treat the VM as a fresh dev machine. `devvm` never handles your credentials — you
log in inside the VM, as the `dev` user, with what *that VM* should hold:

```bash
claude --version                       # installed by guest-setup.sh
gh auth login --with-token             # paste a fine-grained token scoped to this
                                       # VM's repos (read-only unless the agent
                                       # should push), then Ctrl-D
gh auth setup-git
# Private repo (the automatic clone was skipped):
#   git clone https://github.com/<you>/<repo>.git ~/workspace/<repo> && cd ~/workspace/<repo>
claude login                           # endpoints are allowlisted
claude --dangerously-skip-permissions  # fine here: egress is capped on the host
                                       # and the host FS isn't mounted
```

You are `dev`, not root (Claude's skip-permissions mode and minikube's docker
driver both refuse root), with `docker` access and passwordless `sudo`.

`guest-setup.sh` installs only git/`gh`/Docker/Claude Code. For the everyday
toolbox the container image used to bake in, run the optional second script as
`dev` (idempotent; re-run any time):

```bash
bash ~/workspace/safeclaude/vm/guest-tools.sh          # everything, ~1 min
bash ~/workspace/safeclaude/vm/guest-tools.sh agents   # or one group
```

| Group | Installs |
| --- | --- |
| `base` | zsh, fzf, ripgrep, jq, tmux, tree, htop, build-essential, Python venv/pip, shellcheck, hadolint, git-delta, Neovim |
| `node` | Node.js (via fnm; the current LTS line by default) and Bun |
| `mise` | [mise](https://mise.jdx.dev), for per-project tool versions (`mise.toml` / `.tool-versions`) |
| `agents` | Codex, Gemini and Cursor CLIs, plus the `yolo-claude` / `yolo-codex` / `yolo-gemini` / `yolo-cursor` aliases. **Turns off Claude Code's one-time bypass-permissions warning** (see below) |
| `git` | delta as the pager; `user.name` / `user.email` if you pass `GIT_USER_NAME` / `GIT_USER_EMAIL` |

Open a new shell afterwards to pick up `PATH` and the aliases.

**Node versions.** The default is the newest LTS line. Re-running the `node`
group is how you move:

```bash
bash vm/guest-tools.sh node                   # move the default up to the newest LTS
NODE_VERSION=<major> bash vm/guest-tools.sh node   # make a specific line the default
fnm install 24 && fnm use 24                  # switch only the current shell
fnm ls                                        # what's installed
```

Older versions stay installed, and globally installed npm tools (`gemini`) live
outside any one Node version, so they survive a switch. For a version pinned
per project, put it in the repo's `mise.toml`; mise takes over Node only inside
a directory whose config names it.

Things to know:

- **It changes a Claude Code safety default.** The `agents` group sets
  `skipDangerousModePermissionPrompt` in `~/.claude/settings.json`, so
  `yolo-claude` starts without the one-time acceptance screen. Run it with
  `DEVVM_KEEP_BYPASS_PROMPT=1` to keep the prompt.
- **It trusts upstream.** It runs the Bun and Cursor installers and fetches the
  latest Neovim, fnm and Codex releases with no checksum check, as the
  container image does (hadolint and mise are checksum-verified). The egress allowlist limits where code can send data,
  not what runs inside the VM.
- **mise fetches tools from wherever they are published.** Its version index
  and the common sources (GitHub releases, `nodejs.org`, `dl.google.com`) are
  on the allowlist; a tool hosted elsewhere fails with "Could not resolve
  host" until you `devvm allow` that host.
- **Don't edit `~/.config/devvm/shellrc.sh`.** It holds the `PATH` entries and
  aliases and is rewritten on every run; put your own settings in `~/.bashrc`
  or `~/.zshrc`.

Anything beyond that is the repo's own bootstrap step.

If a download fails with "Could not resolve host", that host isn't on the
allowlist. Add it **on the host** (not in the VM):

```bash
devvm allow nodejs.org static.rust-lang.org   # add + apply live, no VM restart
devvm allow                                   # list your extras
devvm allow --rm nodejs.org                   # take one back out
devvm allow --refresh                         # re-apply, change nothing
```

Details in [README.md](README.md#adding-hosts).

Edit the clone in-guest (`devvm shell`), or move files with `incus file`. VS Code
Remote-SSH is a planned follow-up — the cloud image ships no SSH server or host
key yet.

## Teardown

```bash
devvm stop      # stop this project's VM
devvm rm        # destroy it (keeps nothing)
```

## Learning without KVM/nested virt

To practice the Incus + egress mechanics on a box without nested virt, launch an
Incus **system container** by hand (`incus launch images:ubuntu/24.04 t1`) and
apply `host-egress.sh` against its bridge — same networking model, no VM. (The
`devvm` driver itself uses `--vm`; this is just a low-cost way to see the pieces.)
