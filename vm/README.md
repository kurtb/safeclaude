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
| `allowlist.conf` — egress allowlist (domain names) | `drivers/linux-incus.sh` ✅ |
| `cloud-init.yaml` — guest provisioning | `drivers/darwin-lima.sh` (stub) |
| `lib/resolve-allowlist.sh` — domains → SSRF-filtered CIDRs | `drivers/windows-wsl2.sh` (stub) |
| `lib/host-egress.sh` + `proxy/squid.conf` — SNI proxy + DNS + nftables | |
| `devvm.sh` — CLI + OS detection/dispatch | |

```
devvm [up|shell|stop|rm] [--name X]
```

## Boundary model (Linux driver)

Egress is enforced **entirely on the host**, where guest-root can't reach it:

1. **Transparent SNI proxy (Squid peek-and-splice)** — allowlists HTTPS by TLS
   SNI / HTTP Host, no decryption, no MITM CA. Allowlist is **domain names**, so
   CDN IP rotation is a non-issue. Host nftables DNAT the VM's :80/:443 into it,
   so a guest ignoring `HTTP_PROXY` can't bypass it.
2. **Allowlist-only DNS (dnsmasq)** — resolves only allowlisted domains,
   everything else NXDOMAIN (no default upstream) → closes DNS-tunnel exfil.
3. **nftables default-deny** on the VM subnet — only proxy + DNS reachable; all
   other direct egress dropped.
4. **SSRF filter** in `resolve-allowlist.sh` (for the optional IP-level ACL) —
   drops loopback/RFC1918/link-local+metadata (169.254.169.254)/CGNAT/multicast
   before any allow rule, so a repointed/poisoned domain can't open a path to
   host or cloud-metadata services.

Clone-only: `devvm` reads the current folder's git remote and the guest clones
it into `/root/workspace`; nothing is mounted from the host. Edit via **VS Code
Remote-SSH** into the VM. Private repos: `export GH_TOKEN=…` before `devvm up`.

## How this resolves the PR #25 review

- **SSRF via resolved IPs (blocking)** — filtered in `resolve-allowlist.sh`; tested.
- **DNS-tunnel claim (blocking)** — now actually true: allowlist-only dnsmasq.
- **`--name x rm` booted instead (blocking)** — verb/`--name` parsed in any order; tested.
- **`set -euo` broke sourcing (blocking)** — scoped to the run subshell; file is source-safe.
- **Invalid Incus names** — `_devvm_sanitize`: `[a-z0-9-]`, leading letter, ≤63; tested.
- **Writable host mount (host-escape)** — removed: clone-only, no mount.
- **CDN resolve-vs-guest drift** — gone: proxy filters by domain, not IP.
- **docker.io not a registry host** — dropped from the allowlist.
- **word-splitting / temp-file / trap** — resolver uses `while read`; no temp file.

## Finish / validate on a real Incus host (VERIFY markers inline)

No KVM/Incus on the build box, so the host-egress + driver paths are unrun:

1. Install Incus + `incus admin init`; install `squid` + `dnsmasq` on the host.
2. Host nested virt on (`kvm_intel/amd nested=1`) for minikube `kvm2`.
3. Confirm `devvmbr0` subnet matches `DEVVM_SUBNET` in `host-egress.sh`; generate
   the Squid splice cert (command in `proxy/squid.conf`); confirm the `conf.d`
   path and that our dnsmasq instance doesn't clobber Incus's.
4. `cd` into a project, `devvm` — verify boot + clone, then the egress smoke test
   from inside: `curl https://example.com` must FAIL, `curl https://api.github.com/zen`
   must SUCCEED.
5. `minikube start --driver=docker` inside the guest.

## Fleet note

For many autonomous agents (no Docker/minikube), the substrate is **Firecracker**
(microVM density, snapshot/restore). The egress model — netns/veth/tap + an SNI
allowlist proxy + default-deny — is the same control plane, one design across
dev box and fleet.
