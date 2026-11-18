# devvm — platform-neutral per-project dev VM

The VM lane that complements the container: a real-kernel VM with native
Docker/minikube and a **host-enforced, default-deny egress allowlist**. One VM
per project (`devvm-<basename>-<hash>`), walk-up-and-boot, **clone-only** (no host
filesystem mounted into the guest).

## Why not one tool everywhere

The VM substrate is OS-specific — no single manager spans Linux/Mac/Windows. So
`devvm` is a **neutral contract + per-OS driver backends**, sharing everything
that can be shared.

| Shared (all OS) | Per-OS driver |
|---|---|
| `allowlist.conf` — egress allowlist (domain names) | `drivers/linux-incus.sh` (implemented) |
| `guest-setup.sh` — guest setup, run by hand inside the VM | `drivers/darwin-lima.sh` (stub) |
| `test/` — local rig + boundary tests for the egress stack (no Incus needed) | `drivers/windows-wsl2.sh` (stub) |
| `guest-tools.sh` — optional dev toolbox + agent CLIs, run by hand as `dev` | |
| `lib/host-egress.sh` + `proxy/haproxy.cfg` — by-name proxy + nftables (DNS is the driver's) | |
| `devvm.sh` — CLI + OS detection/dispatch | |

```
devvm [up|shell|stop|rm] [--name X]
```

## Boundary model (Linux driver)

Egress is enforced **entirely on the host** (from a root-owned install dir, see
below), where guest-root can't reach it. Layered gates, each closing a bypass the
others don't:

1. **Everything web goes through the proxy (nftables)** — all of the guest's
   `:80`/`:443` traffic is DNATed to the proxy on the bridge IP, whatever address
   the guest aimed at.
2. **By-name proxy (a dedicated HAProxy, [`proxy/haproxy.cfg`](proxy/haproxy.cfg))**
   — reads the server name (TLS SNI, or HTTP Host), drops the connection unless
   that exact name is allowlisted, then **resolves the name itself and connects
   there**. No decryption, no MITM CA; the guest sees the real certificate.
   - The address the guest chose is never used, so
     `curl --resolve <allowed-name>:443:<evil-ip>` reaches the real
     `<allowed-name>` or nothing.
   - A name that resolves to a loopback, private, link-local (cloud metadata
     `169.254.169.254`), CGNAT or multicast address is refused
     ([`proxy/bogons.lst`](proxy/bogons.lst)), so an allowlisted name can't be
     turned on the host or the LAN.
   - The proxy connects over **IPv4 only**. A name with only IPv6 addresses is
     refused, so there is no second, IPv6 list of private ranges to get wrong.
   - There is **no list of allowed IPs**. Addresses are looked up per
     connection, so rotating CDN addresses need no refresh.
3. **`input` chain** — the guest can reach only DHCP/DNS/the proxy on the bridge
   IP, nothing else on the host (sshd, Incus API, resolvers on other host
   addresses, …).
4. **Allowlist-only DNS (Incus's own dnsmasq)** — resolves only allowlisted
   domains; `no-resolv` means no default upstream → DNS can't tunnel to
   arbitrary names. Incus's managed-bridge dnsmasq owns `:53` and does DHCP, so
   the driver makes *it* allowlist-only via the network's `raw.dnsmasq` (one
   `server=/<domain>/<upstream>` per allowlisted host) instead of running a
   second, competing dnsmasq.
5. **`forward` default-deny** on the VM subnet — nothing but the proxied web
   traffic leaves; every other direct connection is rejected.

The proxy is its own service, `devvm-proxy.service`, with its config in
`/etc/devvm/`; the distro's `haproxy.service` is neither used nor modified. Its
log is the audit trail — one line per connection, with the name and the address
it connected to: `journalctl -u devvm-proxy`.

Clone-only: `devvm` reads the current folder's git remote and the guest clones it
into `/home/dev/workspace`; nothing is mounted from the host. Edit the clone
in-guest with `devvm shell` (or move files with `incus file`). *(VS Code
Remote-SSH is a planned follow-up — the cloud image ships no SSH server or host
key yet.)*

**The guest is a fresh dev machine.** A new VM boots **bare** — nothing is
installed at boot, and `devvm` drops you into a root shell. You set it up by
hand: clone this repo inside the VM and run [`guest-setup.sh`](guest-setup.sh)
as root (see [`QUICKSTART.md`](QUICKSTART.md)). It runs in the foreground and
installs only what every project needs (git, `gh`, Docker, Claude Code) and
creates the unprivileged **`dev`** user (in the `docker` group, with passwordless
`sudo`). It is idempotent, so re-run it if a step fails. After that `devvm shell`
logs you in as `dev` — not root, because Claude Code's
`--dangerously-skip-permissions` and minikube's docker driver both refuse to run
as root. Guest `sudo` is fine here, unlike in the container: the egress boundary
is enforced on the host, where guest root can't reach it. A project's own
toolchain is the project's job — give the repo a bootstrap command.

**devvm never handles credentials.** Once setup has run, a public repo is cloned
for you. For a private one the clone is skipped (not fatal): inside the VM run
`gh auth login --with-token` with a token scoped to what *that VM* should be
able to do, then `gh auth setup-git` and `git clone`. Same for `claude login`.

## Known limitations (accepted — same posture as the container)

These are inherent to a name/IP allowlist and are **not** fixable without a
full MITM forward proxy or an app-layer gateway. Called out honestly rather than
claimed solved:

- **Shared-CDN domain fronting.** The proxy sees only the SNI. A TLS session to
  an allowlisted name on a shared CDN can carry a different Host inside the
  encryption and so reach another tenant of that CDN (`claude.ai`,
  `chatgpt.com`, Cloudflare-fronted hosts).
- **Subdomain DNS tunneling.** `server=/<zone>/…` resolves any subdomain of an
  allowlisted zone, so a slow DNS tunnel under such a zone is possible.
- **General-purpose allowlisted hosts** (`github.com`, `sentry.io`,
  `statsig.com`, gists/raw) are usable as exfil channels by a hostile agent.
- **Cross-project network isolation.** All project VMs currently share one
  bridge (`devvmbr0`) with Incus firewalling off; the nft `forward` chain filters
  routed egress but not intra-bridge L2, so VMs on the bridge can reach each
  other's services. Fix in progress: a per-project bridge (VEC-230). Until then,
  treat concurrently-running project VMs as mutually reachable.
- **Credentials you put in the guest** (a `gh` token, the Claude login) are
  readable by the agent running there — it is `dev` with `sudo`. Give each VM a
  fine-grained token scoped to its repos and to the least it needs (read-only
  unless the agent should push).

This is the same boundary the container accepts: it stops *accidental* and
*broad* egress, not a determined exfil via an allowlisted service.

## Validation status

The egress stack was redesigned around the by-name proxy (VEC-231, VEC-234).
The earlier Squid design pinned a snapshot of allowed IPs, which went stale as
CDNs rotated, and Squid refused any TLS connection where the guest's DNS answer
differed from its own — which for round-robin names such as `github.com` was
most of them. Neither can be configured away in Squid's intercept mode.

**Validated in the local rig** ([`test/egress-rig.sh`](test/egress-rig.sh)): the
real `install-host.sh`, `host-egress.sh` and `haproxy.cfg`, with a network
namespace standing in for the guest. [`test/egress-test.sh`](test/egress-test.sh)
checks 25 things a guest must or must not be able to do, including:

- an allowed name works over HTTPS and HTTP;
- aiming an allowed name at any other IP (`--resolve`) still reaches the real
  host — 10 out of 10 with random addresses;
- a non-allowlisted SNI, a missing SNI and non-TLS data on `:443` are dropped;
- an allowlisted name resolving to loopback, the bridge IP or the metadata
  address is refused, and a canary server on the host's loopback is never hit;
- SSH, other ports, host services and outside DNS are unreachable;
- with the proxy stopped, nothing gets out.

**Not yet validated on a real Incus host.** The rig replaces only Incus's
plumbing (the bridge and `raw.dnsmasq`), which this change does not touch, but
run Phase 3 of the [QUICKSTART](QUICKSTART.md) after upgrading.

### Host setup (prerequisites)

0. Install **`haproxy`** (2.2 or newer; tested on 2.8, which Ubuntu 24.04
   ships) and **`nftables`**, plus Incus (`incus admin init`).
   Incus pulls in `dnsmasq-base` and runs its own dnsmasq on the managed bridge.
   Squid is no longer used.
1. `sudo ./install-host.sh` — installs the egress enforcement root-owned to
   `/usr/local/lib/devvm` (the driver runs that copy, never the checkout) and
   the `devvm-proxy.service` unit. For reboot persistence, add a systemd unit
   running the egress script before `incus.service` (VEC-243).
2. Ensure your shell is in the `incus-admin` group (`newgrp incus-admin` or
   re-login) so `devvm` can talk to the Incus socket.

### Still to verify (non-egress)

- Host nested virt on (`kvm_intel/amd nested=1`) for minikube `kvm2`, then
  `minikube start --driver=docker` inside the guest.

## Guest toolbox

`guest-setup.sh` (root, required) installs the minimum: git, `gh`, Docker, Claude
Code and the `dev` user. `guest-tools.sh` (as `dev`, optional) adds what the
container image bakes in — shell tools, compilers, Python, Node (current LTS,
switchable), Bun, mise, linters, Neovim, the Codex/Gemini/Cursor CLIs and the
`yolo-*` aliases — in five groups (`base`, `node`, `mise`, `agents`, `git`).
Both are idempotent and are run by hand inside the VM; see
[QUICKSTART.md](QUICKSTART.md). Everything `guest-tools.sh`
downloads is on `allowlist.conf`, which also carries the two hosts mise itself
needs (`mise-versions.jdx.dev`, `tuf-repo-cdn.sigstore.dev`).

## Adding hosts

Sooner or later a build wants a host that isn't on `allowlist.conf`. The symptom
inside the VM is `Could not resolve host` (allowlist-only DNS). On the **host**:

```bash
devvm allow crates.io static.crates.io   # add + apply live
devvm allow                              # list your extras
devvm allow --rm crates.io               # remove
devvm allow --refresh                    # re-apply the list, change nothing
```

- Extras go in `/etc/devvm/allowlist.local` — root-owned, on the host, outside
  the checkout — and are merged with `allowlist.conf` by both layers (DNS and
  the proxy). Nothing in a guest can reach that file, so an agent can
  tell you which host it needs but cannot allow it itself. The file survives
  `install-host.sh` re-runs.
- It applies **live**: no VM restart, and it never touches a VM. It is
  **machine-wide** — every devvm VM shares the one bridge and the one list.
- **Exact host names only**, no wildcards: each layer works per name. A pasted
  URL is trimmed to its host.
- A download often needs a *second* host — the one it redirects to (a blob CDN,
  a regional mirror). `curl -sIL <url> | grep -i '^location'` in the VM shows
  it. Example: `registry.k8s.io` redirects manifests to a regional
  `<region>-docker.pkg.dev`, which depends on where you are and so isn't on the
  base list.
- A host everyone needs — including a redirect target like the blob CDNs above —
  belongs in `allowlist.conf` via a PR (a **minor** bump), followed by
  `sudo ./install-host.sh`.
- "Already allowed" is judged against the **installed** list
  (`/usr/local/lib/devvm/allowlist.conf`), not the checkout: after pulling a
  newer `allowlist.conf`, re-run `sudo ./install-host.sh` to put it in force.

## Allowlist / posture

Adding this lane is a **minor** bump (new capability + a new egress surface) per
CLAUDE.md. `allowlist.conf` is broad (GitHub, package registries, container
registries, telemetry) and should be diffed against the container's
`init-firewall.sh`; the long-term fix is a single shared source (TODO).

## Fleet note

For many autonomous agents (no Docker/minikube), the substrate is **Firecracker**
(microVM density, snapshot/restore). The egress model — by-name allowlist
proxy + default-deny — is the same control plane across dev box and
fleet.
