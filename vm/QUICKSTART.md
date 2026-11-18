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

# 0b. Install Incus + the egress tooling. squid-OPENSSL (stock squid lacks ssl-bump).
sudo apt update
sudo apt install -y incus squid-openssl dnsmasq-base nftables openssl \
                    bind9-dnsutils jq curl git
sudo incus admin init --minimal                 # accept the minimal defaults

# 0c. Let your user drive Incus without sudo.
sudo usermod -aG incus-admin "$USER"            # log out/in (or: newgrp incus-admin)

# 0d. Get the code.
git clone https://github.com/kurtb/safeclaude.git
cd safeclaude
```

Why: Incus is the VM manager; Squid/dnsmasq/nftables are the host-side egress
gates; `vm/` carries the tooling.

## Phase 1 — install the egress enforcement root-owned (one-time)

```bash
sudo ./vm/install-host.sh      # copies the egress script + config to
                               # /usr/local/lib/devvm (root-owned) and makes
                               # the Squid splice cert
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
(dest-IP pin + SNI proxy + allowlist DNS + default-deny) → start → root shell in
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
# The bypass test — must be BLOCKED (dest-IP pin catches the forged resolve):
curl -sS --max-time 5 --resolve api.github.com:443:1.2.3.4 https://api.github.com/ \
  && echo UNEXPECTED || echo "bypass blocked (good)"
exit

# From the HOST — look at what's enforcing it:
sudo nft list table inet devvm        # the dest-IP set + input/forward/nat chains
incus network show devvmbr0           # firewall/nat/dns all off (we own them)
incus list                            # your VM
```

Why: this is the whole point — confirm egress is allowlisted *and* the
`--resolve` front-door is shut, from outside the guest's control.

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
| `node` | Node.js (via fnm) and Bun |
| `agents` | Codex, Gemini and Cursor CLIs, plus the `yolo-claude` / `yolo-codex` / `yolo-gemini` / `yolo-cursor` aliases. Also pre-accepts Claude Code's bypass-permissions prompt |
| `git` | delta as the pager; `user.name` / `user.email` if you pass `GIT_USER_NAME` / `GIT_USER_EMAIL` |

Open a new shell afterwards to pick up `PATH` and the aliases. Things to know:

- **It changes a Claude Code safety default.** The `agents` group sets
  `skipDangerousModePermissionPrompt` in `~/.claude/settings.json`, so
  `yolo-claude` starts without the one-time acceptance screen. Run it with
  `DEVVM_KEEP_BYPASS_PROMPT=1` to keep the prompt.
- **It trusts upstream.** It runs the Bun and Cursor installers and fetches the
  latest Neovim, fnm and Codex releases with no checksum check, as the
  container image does. The egress allowlist limits where code can send data,
  not what runs inside the VM.
- **Don't edit `~/.config/devvm/shellrc.sh`.** It holds the `PATH` entries and
  aliases and is rewritten on every run; put your own settings in `~/.bashrc`
  or `~/.zshrc`.

Anything beyond that is the repo's own bootstrap step. If a download fails with "Could not resolve host", that host isn't on the
allowlist. Add it **on the host** (not in the VM):

```bash
devvm allow nodejs.org static.rust-lang.org   # add + apply live, no VM restart
devvm allow                                   # list your extras
devvm allow --rm nodejs.org                   # take one back out
devvm allow --refresh                         # re-resolve only (see below)
```

If a host that *is* allowed fails with "Couldn't connect to server", its IP has
rotated away from the pinned snapshot: `devvm allow --refresh` re-resolves the
whole list. Details in [README.md](README.md#adding-hosts).

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
