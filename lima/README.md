# safeclaude VM profile (Lima) — minimal scaffold

The **full-VM lane** that complements the container: real kernel + full device
model, so Docker and minikube run natively (no DinD, no host-socket mount), and
with host nested virt even minikube's `kvm2` driver works. For **human-driven
dev that needs k8s-in-sandbox or a hard isolation boundary**.

## Model (decided)

- **One VM per project**, named `safeclaude-<basename>` — mirrors the
  container+volume model. Per-project isolation is the whole point of the VM, so
  no shared multi-project VM.
- **Bind-mount the project dir by default** (scoped hole, like the container) so
  "walk up and boot" keeps your uncommitted edits in place. The hermetic
  clone-at-startup model (no host mount) is the *fleet* lane — see bottom.
- The VM is a **lane, not a replacement**: container for the fast edit-loop
  (instant attach, low overhead), VM for k8s / strong isolation.

## Files

| File | Role |
|------|------|
| `safeclaude.yaml` | Minimal bootable Lima template (Ubuntu 24.04, Docker + Claude Code). |
| `vm-firewall.sh` | **Host-side** nftables egress, applied to the VM's interface. |
| `allowlist.conf` | Canonical domain allowlist, shared source of truth. |
| `safeclaude-vm.zsh` | Walk-up-and-boot wrapper (`safeclaude-vm`). |

## Why host-side egress

In the container, the firewall is safe only because the agent has no sudo. A VM
needs guest-root for Docker, so an in-guest firewall is no boundary. Enforcing on
the host's `FORWARD` chain for the VM interface puts the allowlist where a
compromised guest-root agent can't reach it — a stronger posture than today.

## Finish + test from inside the container

This scaffold boots and proves the model; the rest is yours to complete on a
KVM host (this build box has no virt tooling). Checklist:

1. **Host prereqs**: `limactl`, `socket_vmnet`, nested virt
   (`kvm_intel nested=1` / `kvm_amd nested=1`), `nftables`.
2. **Boot**: `cd` into a project, `safeclaude-vm`. Confirm the VM comes up and
   the `socket_vmnet` host interface name (the wrapper assumes `lima0`; override
   with `SAFECLAUDE_VM_IF`).
3. **Firewall smoke test** (mirrors `init-firewall.sh`): from inside the guest,
   `curl https://example.com` must FAIL and `curl https://api.github.com/zen`
   must SUCCEED.
4. **k8s check**: `minikube start --driver=docker` inside the guest.
5. **Finish provisioning**: port the remaining Dockerfile toolchain
   (zsh/dotzsh, fnm+node, bun, codex, gstack, `yolo-*`, `safeclaude-doctor`).

## Open wrinkles

1. **socket_vmnet / interface name.** Host-side filtering needs a real host
   interface; Lima's default SLIRP NAT has none. Verify the `networks: lima:
   shared` interface name feeds `vm-firewall.sh`.
2. **Allowlist drift.** `allowlist.conf` is the canonical source; the container's
   `init-firewall.sh` still inlines its copy — switch it to read this file in a
   follow-up so they can't diverge.
3. **DNS posture.** Egress allows `udp/53` anywhere (matches the container);
   pinning a resolver IP is a possible hardening.
4. **Wrapper integration.** Currently a separate `safeclaude-vm`. Decide whether
   to fold it into `safeclaude --vm` and map `stop/rm/recreate` onto `limactl`.
5. **`--clone` flag.** Add the hermetic (no-mount, git-clone) path as an opt-in.

## Not the substrate for an agent *fleet*

For many autonomous agents that only need isolated code execution (no
Docker/minikube), **Firecracker** is the better substrate — microVM density,
~125 ms boot, snapshot/restore, minimal VMM attack surface — via
firecracker-containerd or Kata-on-Firecracker. The **host-side egress model here
is the same**; it scales to one tap per microVM. That's the Muse/Instinct/Dot
lane, separate from this dev box.
