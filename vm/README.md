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

Egress is enforced **entirely on the host**, where guest-root can't reach it.
Two independent gates must BOTH pass (either alone is bypassable):

1. **Destination-IP pin (nftables set)** — only `:80/:443` to an allowlisted,
   **SSRF-filtered** IP (from `resolve-allowlist.sh`, dropping loopback/RFC1918/
   link-local+metadata `169.254.169.254`/CGNAT/multicast) is DNATed to the proxy.
   Defeats `curl --resolve <allowed-sni>:443:<evil-ip>` and host-side SSRF.
2. **SNI/Host allowlist (Squid peek-and-splice)** — allowlists HTTPS by TLS SNI
   / HTTP Host, no decryption, no MITM CA. Allowlist is **domain names**.
3. **`input` chain** — the guest can reach only DHCP/DNS/Squid on the bridge IP,
   nothing else on the host (sshd, Incus API, …).
4. **Allowlist-only DNS (dnsmasq)** — resolves only allowlisted domains, else
   NXDOMAIN; no default upstream → DNS can't tunnel. Needs `dns.mode=none` on the
   Incus network (driver sets it) so it doesn't collide with Incus's dnsmasq.
5. **`forward` default-deny** on the VM subnet — only the DNATed proxy paths
   survive; all other direct egress dropped.

Clone-only: `devvm` reads the current folder's git remote and the guest clones it
into `/root/workspace`; nothing is mounted from the host. Edit via **VS Code
Remote-SSH**. Private repos: `export GH_TOKEN=…` before `devvm up`.

## Finish / validate on a real Incus host (VERIFY markers inline)

No KVM/Incus on the build box, so the host-egress + driver paths are unrun and
unverified. What's been checked on the build box: the SSRF filter
(`resolve-allowlist.sh`) and the CLI parsing/sanitization (`devvm.sh`). To
finish:

1. Install **`squid-openssl`** (stock `squid` is GnuTLS and lacks `ssl-bump`) +
   `dnsmasq` + Incus (`incus admin init`). Install `host-egress.sh` root-owned.
2. Generate the Squid splice cert (command in `proxy/squid.conf`); confirm the
   `conf.d` include lands before the default `http_access`.
3. Confirm `devvmbr0` subnet matches `DEVVM_SUBNET`; confirm the allowlist-only
   dnsmasq runs as a dedicated instance (with `dns.mode=none`) and the guest
   still gets DHCP + gateway.
4. Host nested virt on (`kvm_intel/amd nested=1`) for minikube `kvm2`.
5. `cd` into a project, `devvm` — verify boot + clone, then the egress smoke test
   from inside: `curl https://example.com` FAILS, `curl https://api.github.com/zen`
   SUCCEEDS, and the bypass `curl --resolve api.github.com:443:1.2.3.4 https://api.github.com`
   is BLOCKED.
6. `minikube start --driver=docker` inside the guest.

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
