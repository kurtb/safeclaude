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

# From a trusted checkout or the unpacked release tarball, run the VM installer.
# In a checkout:
sudo ./vm/install-host.sh
# In the release tarball: sudo ./devvm/install-host.sh

# On a new Incus host, create a storage pool and default profile.
sudo incus admin init --minimal
# incus-admin grants host administrator privileges. Add your own trusted user.
sudo usermod -aG incus-admin "$USER"
# Log out and back in to activate the group.
```

The installer refreshes APT and installs the latest stable Incus and required host packages on Ubuntu 24.04/26.04 and Debian 13 (amd64 or arm64). It uses the [signed Zabbly stable channel](https://github.com/zabbly/incus#stable-repository) as a host package publisher. The installer checks the provenance of Incus, HAProxy and the named enforcement packages. APT resolves their dependencies using the host’s configured repositories. A configured Incus host can keep its existing storage and profile. Run `incus storage list` before initializing an existing host.

Use `./vm/install-host.sh --check` for a read-only check against local APT metadata. On another supported Debian/Ubuntu configuration with manually provisioned packages, `sudo ./vm/install-host.sh --skip-packages` checks the same requirements and installs the CLI. The minimum versions are Incus 7.5.1 and HAProxy 2.8.

## Phase 2 — boot a project VM

```bash
cd ~/path/to/your-project      # a git repo; a public https origin is cloned inside
devvm                          # create network+VM (first run), apply egress, boot, shell in (bare VM, root)
```

The driver creates a dedicated bridge and subnet for the project, configures its DNS allowlist, and initializes the VM stopped. It applies the host firewall and proxy before starting the VM. A fresh VM opens a root shell.

Exit that shell and run the installed guest setup from the host:

```bash
devvm upgrade
devvm shell
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

If *every* allowed host starts failing after the host changed networks or DNS
settings, the proxy is still using the old resolver: on the host, run
`sudo systemctl restart devvm-proxy`.

## Edit from the host

Run `devvm ssh-config` in the project directory after guest setup. It prints an OpenSSH host entry with a dedicated identity and a pinned guest host key. Save it in a per-project SSH config fragment and include that file from `~/.ssh/config` before any `Host *` defaults. Connect with VS Code Remote-SSH using the printed host name. Set `remote.SSH.localServerDownload` to `always` for host-side VS Code Server downloads. SSH runs over the local Incus socket. The guest needs no network SSH listener.

For one file, use `devvm cp push HOST_FILE /absolute/guest/path` or `devvm cp pull /absolute/guest/path HOST_FILE`. Choose a new destination path. Both commands work without configuring SSH.

## Optional cloud tools

Inside the guest as `dev`, run `bash ~/workspace/safeclaude/vm/guest-cloud-tools.sh` from a SafeClaude clone, then `minikube start --driver=docker`. The installer supplies gcloud, Pulumi, kubectl, Helm and minikube. If a registry pull fails, inspect the Location header with `curl -sSI https://registry.k8s.io/v2/pause/manifests/3.10`. Run `devvm allow HOSTNAME` on the host for the exact regional redirect destination if the project needs it.

## Personal tools and logins

Guest setup installs `gh-auth-setup`. Run it as `dev` inside the guest for a VM-scoped GitHub login. Dotfiles and gstack are optional. See the [personal setup guide](PERSONAL.md) for installation groups, Chromium requirements and the decision on Tailscale.

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
