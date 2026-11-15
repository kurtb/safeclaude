# devvm — platform-neutral per-project dev VM

The VM lane that complements the container: a real-kernel VM with native
Docker/minikube and a **host-enforced, default-deny egress allowlist**. One VM
per project (`devvm-<basename>`), walk-up-and-boot, **clone-only** (no host
filesystem mounted into the guest).

## Why not one tool everywhere

The VM substrate is OS-specific — no single manager spans Linux/Mac/Windows. So
`devvm` is a **neutral contract + per-OS driver backends**, sharing everything
that can be shared.

| Shared (all OS) | Per-OS driver |
|---|---|
| `allowlist.conf` — egress allowlist (domain names) | `drivers/linux-incus.sh` (implemented) |
| `cloud-init.yaml` — guest provisioning | `drivers/darwin-lima.sh` (stub) |
| `lib/resolve-allowlist.sh` — domains → SSRF-filtered CIDRs | `drivers/windows-wsl2.sh` (stub) |
| `lib/host-egress.sh` + `proxy/squid.conf` — dest-IP pin + SNI proxy + DNS + nftables | |
| `devvm.sh` — CLI + OS detection/dispatch | |

```
devvm [up|shell|stop|rm] [--name X]
```

## Boundary model (Linux driver)

Egress is enforced **entirely on the host** (from a root-owned install dir, see
below), where guest-root can't reach it. Layered gates, each closing a bypass the
others don't:

1. **Destination-IP pin (nftables set)** — only `:80/:443` to an allowlisted,
   **SSRF-filtered** IP (from `resolve-allowlist.sh`, dropping loopback/RFC1918/
   link-local+metadata `169.254.169.254`/CGNAT/multicast) is DNATed to the proxy.
   Defeats `curl --resolve <allowed-sni>:443:<evil-ip>` and host-side SSRF.
2. **SNI/Host allowlist (Squid peek-and-splice)** — allowlists HTTPS by TLS SNI
   / HTTP Host, no decryption, no MITM CA. Allowlist is **domain names**.
3. **`input` chain** — the guest can reach only DHCP/DNS/Squid on the bridge IP,
   nothing else on the host (sshd, Incus API, …).
4. **Allowlist-only DNS (Incus's own dnsmasq)** — resolves only allowlisted
   domains, else NXDOMAIN; `no-resolv` means no default upstream → DNS can't
   tunnel to arbitrary names. Incus's managed-bridge dnsmasq owns `:53` and does
   DHCP, so the driver makes *it* allowlist-only via the network's `raw.dnsmasq`
   (one `server=/<domain>/<upstream>` per allowlisted host) instead of running a
   second, competing dnsmasq.
5. **`forward` default-deny** on the VM subnet — only the DNATed proxy paths
   survive; all other direct egress dropped.

Clone-only: `devvm` reads the current folder's git remote and the guest clones it
into `/root/workspace`; nothing is mounted from the host. Edit the clone in-guest with `devvm shell` / `incus exec` (or move files with
`incus file`). *(VS Code Remote-SSH is a planned follow-up — the cloud image
ships no SSH server or host key yet.)* Private repos: `export GH_TOKEN=…` before `devvm up`.

## Known limitations (accepted — same posture as the container)

These are inherent to a name/IP allowlist and are **not** fixable without a
full MITM forward proxy or an app-layer gateway. Called out honestly rather than
claimed solved:

- **Shared-CDN domain fronting.** An allowlisted IP + allowlisted SNI with a
  different Host can still exfil to another tenant on the same CDN
  (`claude.ai`, `chatgpt.com`, Cloudflare-fronted hosts). `host_verify_strict`
  only covers plaintext HTTP.
- **Subdomain DNS tunneling.** `server=/<zone>/…` resolves any subdomain of an
  allowlisted zone, so a slow DNS tunnel under such a zone is possible.
- **General-purpose allowlisted hosts** (`github.com`, `sentry.io`,
  `statsig.com`, gists/raw) are usable as exfil channels by a hostile agent.
- **CDN drift vs. the dest-IP pin.** The pin is a `dig` snapshot; CDN-fronted
  hosts (e.g. `*.jfrog.io`) can rotate to IPs not in the set and get dropped
  intermittently. Fails *closed* (blocks, never leaks). Fix in progress:
  re-resolve the allowlisted name in the proxy per connection so rotation is
  tracked live (VEC-231).
- **Cross-project network isolation.** All project VMs currently share one
  bridge (`devvmbr0`) with Incus firewalling off; the nft `forward` chain filters
  routed egress but not intra-bridge L2, so VMs on the bridge can reach each
  other's services. Fix in progress: a per-project bridge (VEC-230). Until then,
  treat concurrently-running project VMs as mutually reachable.
- **Stock Squid `:3128` reachable from localhost.** devvm installs its SNI filter
  as a conf.d drop-in and does not modify Debian's stock `squid.conf`, which keeps
  its own `:3128` explicit proxy. That port is reachable **from the host's loopback
  only** (stock `allow localhost`; `allow localnet` is commented out) and the nft
  `input` chain blocks the guest from it — so it is **not** an egress path for the
  guest or the LAN. A host-local process could use it to reach non-allowlisted
  hosts, but host processes already have unrestricted egress (the nft rules clamp
  only the guest subnet), so it grants no reach they lack. Closed in a follow-up
  that runs devvm's Squid as a **dedicated instance** and retires the stock :3128.
- **`GH_TOKEN`** is persisted inside a guest-root VM — use a fine-grained,
  read-only, repo-scoped token.

This is the same boundary the container accepts: it stops *accidental* and
*broad* egress, not a determined exfil via an allowlisted service.

## Validation status — egress boundary proven live

Validated on a real **ARM Incus 7.5.1 + KVM** host. The in-guest egress smoke
test passes end to end:

- **Allowed:** `curl https://api.github.com/zen` → succeeds; Squid splices
  (access.log `TCP_TUNNEL`, guest sees GitHub's real cert, `verify ok`).
- **Denied:** `curl https://example.com` → `Could not resolve host` (allowlist-only
  DNS NXDOMAIN).
- **Bypass:** `curl --resolve api.github.com:443:1.2.3.4 https://api.github.com` →
  `Failed to connect` (the nft dest-IP pin defeats the SNI-spoof).

Two never-run host-path bugs were found and fixed getting there: the splice cert
was generated with `-keyout X -out X` (one file, truncated twice → missing cert →
ssl-bump port FATAL), and the intercepted TLS `CONNECT` was denied by a
`dstdomain` ACL that can't match the dest IP (fixed by allowing the CONNECT
through to `ssl_bump`, scoped to our intercept listener with **`myportname`** —
`localport` is unreliable on intercept ports, where Squid reports the original
destination port, not the port it listens on). Scoping removes the *global*
CONNECT allow; the stock Debian `:3128` explicit proxy still exists but is
reachable from localhost only (see Known limitations), retired in a follow-up.

### Host setup (prerequisites)

0. `sudo ./install-host.sh` — installs the egress enforcement root-owned to
   `/usr/local/lib/devvm` (the driver runs that copy, never the checkout) and
   generates the Squid splice cert.
1. Install **`squid-openssl`** (stock `squid` is GnuTLS and lacks `ssl-bump`) +
   Incus (`incus admin init`). Incus pulls in `dnsmasq-base` and runs its own
   dnsmasq on the managed bridge. For reboot persistence, add a systemd unit
   running the egress script before `incus.service`.
2. Ensure your shell is in the `incus-admin` group (`newgrp incus-admin` or
   re-login) so `devvm` can talk to the Incus socket.

### Still to verify (non-egress)

- Host nested virt on (`kvm_intel/amd nested=1`) for minikube `kvm2`, then
  `minikube start --driver=docker` inside the guest.

## Allowlist / posture

Adding this lane is a **minor** bump (new capability + a new egress surface) per
CLAUDE.md. `allowlist.conf` is broad (GitHub, package registries, container
registries, telemetry) and should be diffed against the container's
`init-firewall.sh`; the long-term fix is a single shared source (TODO).

## Fleet note

For many autonomous agents (no Docker/minikube), the substrate is **Firecracker**
(microVM density, snapshot/restore). The egress model — dest-IP pin + SNI
allowlist proxy + default-deny — is the same control plane across dev box and
fleet.
