# devvm quickstart (Linux + Incus) — a learning runbook

Stand up one project VM with host-enforced egress, verify the boundary, then run
Claude inside it. Runs on a **Linux host with KVM** (not inside a container).
Each step says *what* and *why*; run them yourself and read the output.

> Status: experimental, not merged. Use the `sketch/incus-vm-lane` branch.

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

# 0d. Get the code (the branch, not main — this isn't merged).
git clone https://github.com/kurtb/safeclaude.git
cd safeclaude && git checkout sketch/incus-vm-lane
```

Why: Incus is the VM manager; Squid/dnsmasq/nftables are the host-side egress
gates; the branch carries the `vm/` tooling.

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
cd ~/path/to/your-project      # a git repo; its https origin is cloned inside
# Private repo? export a fine-grained, READ-ONLY token first:
#   export GH_TOKEN=github_pat_...
devvm                          # create network+VM (first run), apply egress, boot, clone, shell in
```

What happens, in order: create `devvmbr0` (Incus firewall off, NAT off, DNS
off — we own all three) → `incus init` the VM stopped → `sudo` the host egress
(dest-IP pin + SNI proxy + allowlist DNS + default-deny) → start → clone your
repo inside → drop you into a shell in `/root/workspace/<repo>`.

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

## Phase 4 — bootstrap Claude inside

Claude Code is installed by cloud-init. Inside the VM shell:

```bash
claude --version                       # confirm it installed
claude login                           # browser/device login; endpoints are allowlisted
#   (or copy auth like the container's model if you prefer)
claude                                 # start it; --dangerously-skip-permissions is
                                       # safe here — egress is capped and the host FS isn't mounted
```

Edit with a real editor via **VS Code Remote-SSH**: `incus list` for the VM's
IP, add it to `~/.ssh/config`, then "Remote-SSH: Connect to Host" in VS Code and
open `/root/workspace/<repo>`.

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
