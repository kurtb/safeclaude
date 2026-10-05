#!/usr/bin/env bash
# Linux driver: Incus VM, CLONE-ONLY, host-enforced egress via SNI proxy.
#
# Strongest of the OS drivers. No host filesystem is mounted into the guest
# (clone-only), and all egress is forced host-side through a transparent SNI
# allowlist proxy + allowlist-only DNS (see lib/host-egress.sh) that guest-root
# cannot touch. Edit the in-VM clone via VS Code Remote-SSH.
#
# Verbs (from ../devvm.sh):  ensure <name> <repo> <vmdir> | shell | stop | rm
#
# STATUS: structurally complete; validate on a real Incus 7.0 + KVM host (no
# virt on the build box). Spots needing a live check are marked VERIFY.
set -euo pipefail
verb="${1:?}"; name="${2:?}"; repo="${3:-}"; VMDIR="${4:?}"
IMAGE="images:ubuntu/24.04/cloud"
NET="devvmbr0"

need() { command -v incus >/dev/null || { echo "incus not installed" >&2; exit 1; }; }

ensure_network() {
  incus network show "$NET" >/dev/null 2>&1 && return 0
  # Dedicated bridge with Incus's own firewalling DISABLED, so our nftables in
  # host-egress.sh own the policy without Incus fighting them. VERIFY subnet
  # matches DEVVM_SUBNET in host-egress.sh (10.63.0.0/24).
  incus network create "$NET" \
    ipv4.address=10.63.0.1/24 ipv4.nat=true ipv4.firewall=false ipv6.address=none
}

create_if_absent() {
  incus info "$name" >/dev/null 2>&1 && return 0
  echo "Creating $name (stopped) ..."
  # init (not launch) so egress is enforced before first boot. CLONE-ONLY: no
  # disk device, so the host FS is never reachable from the guest.
  incus init "$IMAGE" "$name" --vm \
    -c limits.cpu=4 -c limits.memory=8GiB \
    -c cloud-init.user-data="$(cat "$VMDIR/cloud-init.yaml")" \
    --network "$NET"
  incus config set "$name" limits.kernel.modules=kvm || true   # nested virt; VERIFY
}

clone_repo() {
  [ -n "$repo" ] || { echo "no git origin in \$PWD; starting empty workspace"; return 0; }
  local dir; dir="/root/workspace/$(basename "${repo%.git}")"
  incus exec "$name" -- test -d "$dir/.git" >/dev/null 2>&1 && return 0
  # gh auth inside the guest (token via stdin, never in argv/logs). Out-of-band,
  # like the container's gh-auth-setup.
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' "$GH_TOKEN" | incus exec "$name" -- gh auth login --with-token \
      && incus exec "$name" -- gh auth setup-git || true
  fi
  echo "Cloning $repo into the guest ..."
  incus exec "$name" -- bash -lc "install -d /root/workspace && git clone '$repo' '$dir'" \
    || echo "clone failed (private repo? set GH_TOKEN before 'devvm up')" >&2
}

wait_agent() {
  for _ in $(seq 1 60); do incus exec "$name" -- true >/dev/null 2>&1 && return 0; sleep 2; done
  echo "WARNING: guest agent not ready; cloud-init may still be running" >&2
}

case "$verb" in
  ensure)
    need; ensure_network; create_if_absent
    # Host egress re-applied EVERY run (never fail open).
    sudo "$VMDIR/lib/host-egress.sh"
    incus info "$name" | grep -qi 'Status: RUNNING' || incus start "$name"
    wait_agent; clone_repo
    ;;
  shell)
    need
    exec incus exec "$name" -- bash -lc 'cd /root/workspace/* 2>/dev/null || cd /root/workspace; exec bash -l'
    ;;
  stop) need; incus stop "$name" ;;
  rm)   need; incus delete -f "$name" ;;
  *) echo "unknown verb: $verb" >&2; exit 1 ;;
esac
