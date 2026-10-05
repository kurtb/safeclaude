# devvm — platform-neutral per-project dev VM

The VM lane that complements the container: a real-kernel VM with native
Docker/minikube and a **host-enforced default-deny egress allowlist**. One VM
per project (`devvm-<basename>`), walk-up-and-boot.

## Why not one tool everywhere

The VM substrate is inherently OS-specific — no single VM manager spans
Linux/Mac/Windows. So `devvm` is a **thin neutral contract + per-OS driver
backends**. Everything that *can* be shared is:

| Shared (all OS) | Per-OS driver |
|---|---|
| `allowlist.conf` — the egress allowlist | `drivers/linux-incus.sh` |
| `cloud-init.yaml` — guest provisioning | `drivers/darwin-lima.sh` (stub) |
| `lib/resolve-allowlist.sh` — domains → CIDRs | `drivers/windows-wsl2.sh` (stub) |
| `devvm.sh` — CLI + OS detection/dispatch | |

```
devvm up            # create+boot (first run) or shell in; enforces egress first
devvm shell|stop|rm
devvm --name X ...
```

## Boundary strength is NOT equal across OSes (be honest about this)

| OS | Driver | Enforcement | Strength |
|----|--------|-------------|----------|
| **Linux** | Incus VM + per-instance **network ACL** | Host owns the bridge; egress enforced outside the guest; guest-root can't touch it | **Strongest** ✅ |
| **macOS** | Lima (vz) + vmnet + **pf** | Host-side pf on the vmnet interface | Good |
| **Windows** | WSL2 (nested) + Incus/nftables **inside** | Enforced inside the WSL2 VM; Windows/HNS is the outer layer | Weakest |

## Linux driver (implemented)

Incus is the LinuxContainers community fork of LXD (vendor-neutral governance,
in Debian/Fedora/openSUSE/NixOS, LTS 7.0). The driver:

- `incus init` (create **stopped**) → apply egress ACL → `incus start`, so the
  VM never boots without the allowlist.
- Per-instance ACL `devvm-egress-<name>`: default-deny egress/ingress, allow the
  resolved allowlist CIDRs, and DNS only to the bridge resolver (no udp/53
  anywhere).
- Project dir shared writable via virtiofs; nested virt for minikube.

### How this answers the Lima review (PR #23)

- #1/#2 (SLIRP bypass, `socket_vmnet` is macOS-only) — **gone**: Incus uses a
  host-owned managed bridge, not a Lima add-on NIC.
- #3 (fail-open) — egress applied pre-boot and re-applied every `ensure`.
- #4 (no INPUT filtering) — ACL default-drops ingress too.
- #6/#7 (IPv6 crashes v4 set / nft overlaps) — ACLs take overlapping/dual-family
  allow rules; resolver filters IPv6 out of any v4-only path and dedupes.
- DNS-tunnel — restricted to the bridge resolver.
- #5 (writable mount host-escape) — still a documented tradeoff; `readonly` or
  clone-only mode is the hardening.

## Finish / validate on a real Incus host

I can't run Incus/KVM on the build box, so the Linux driver is structurally
complete but unverified. Spots marked `VERIFY` in `linux-incus.sh`:

1. Install Incus (`incus` CLI), `incus admin init`, confirm `incusbr0`.
2. Host nested virt on (`kvm_intel/amd nested=1`) for minikube `kvm2`.
3. `cd` into a project, `devvm` — confirm boot, then the egress smoke test:
   `example.com` must FAIL and `api.github.com/zen` must SUCCEED from inside.
4. `minikube start --driver=docker` inside the guest.
5. Exact ACL rule schema (`destination_port` quoting, `override` semantics) on
   Incus 7.0.

## Fleet note

For many autonomous agents (no Docker/minikube), the substrate is still
**Firecracker** (microVM density, snapshot/restore). The egress model is the
same netns/veth/tap + default-deny idea — one control plane across dev box and
fleet.
