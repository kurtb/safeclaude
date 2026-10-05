#!/usr/bin/env bash
# Linux driver: Incus VM + per-instance network ACL egress allowlist.
#
# Strongest boundary of the three OS drivers: the Incus managed bridge is owned
# by the host, so egress is enforced OUTSIDE the guest and guest-root cannot
# alter it. The ACL path also sidesteps the nftables interval-set pitfalls from
# the Lima sketch (overlaps/IPv6 are fine as separate allow rules).
#
# Verbs (called by ../devvm.sh):  ensure <name> <proj> <vmdir> | shell | stop | rm
#
# STATUS: structurally complete; validate on a real Incus 7.0 host (I can't run
# Incus here). Spots that need a live check are marked VERIFY.
set -euo pipefail
verb="${1:?}"; name="${2:?}"; proj="${3:-}"; VMDIR="${4:-}"
ACL="devvm-egress-$name"           # per-instance ACL so instances stay separate
IMAGE="images:ubuntu/24.04/cloud"  # cloud variant => cloud-init support
NET="incusbr0"                     # default managed bridge

need() { command -v incus >/dev/null || { echo "incus not installed" >&2; exit 1; }; }

create_if_absent() {
  incus info "$name" >/dev/null 2>&1 && return 0
  echo "Creating $name (stopped) ..."
  # init (not launch) so we can apply the egress ACL BEFORE first boot — the VM
  # never runs even briefly without the allowlist (fixes the Lima fail-open).
  incus init "$IMAGE" "$name" --vm \
    -c limits.cpu=4 -c limits.memory=8GiB \
    -c cloud-init.user-data="$(cat "$VMDIR/cloud-init.yaml")"
  # Nested virt for minikube's kvm2 driver. VERIFY: requires host nested virt;
  # the docker driver works without this.
  incus config set "$name" limits.kernel.modules=kvm || true
  # Share the project dir (virtiofs via incus-agent). Writable = walk-up-and-edit,
  # a host-FS path like the container bind mount. For hard isolation set
  # readonly=true or switch to a clone-only flow (review finding #5).
  [ -n "$proj" ] && incus config device add "$name" workspace disk \
    source="$proj" path=/root/workspace
}

apply_egress() {
  # Re-applied on EVERY ensure (never fail open — review finding #3).
  incus network acl show "$ACL" >/dev/null 2>&1 || incus network acl create "$ACL"

  local gw tmp
  gw="$(incus network get "$NET" ipv4.address | cut -d/ -f1)"   # bridge DNS/gateway
  tmp="$(mktemp)"
  {
    echo "name: $ACL"
    echo "egress:"
    # DNS only to the bridge resolver — not udp/53 to anywhere (review: closes
    # the DNS-tunnel hole the Lima sketch left open).
    printf '  - action: allow\n    destination: %s/32\n    protocol: udp\n    destination_port: "53"\n    state: enabled\n' "$gw"
    printf '  - action: allow\n    destination: %s/32\n    protocol: tcp\n    destination_port: "53"\n    state: enabled\n' "$gw"
    # Resolved allowlist (IPv4; ACLs accept overlaps so no auto-merge needed).
    "$VMDIR/lib/resolve-allowlist.sh" | grep -v ':' | while read -r cidr; do
      printf '  - action: allow\n    destination: %s\n    state: enabled\n' "$cidr"
    done
    echo "ingress: []"
  } > "$tmp"
  incus network acl edit "$ACL" < "$tmp"
  rm -f "$tmp"

  # Bind the ACL to the instance NIC with default-deny egress (and ingress, so
  # the guest can't reach host services — review finding #4). `override` lifts
  # the inherited profile NIC into an instance device we can set ACLs on.
  incus config device override "$name" eth0 2>/dev/null || true
  incus config device set "$name" eth0 \
    security.acls="$ACL" \
    security.acls.default.egress.action=drop \
    security.acls.default.ingress.action=drop
}

wait_agent() {
  echo "Waiting for guest agent ..."
  for _ in $(seq 1 60); do
    incus exec "$name" -- true >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "WARNING: guest agent not ready; cloud-init may still be running" >&2
}

case "$verb" in
  ensure)
    need
    create_if_absent
    apply_egress                                   # while stopped, pre-boot
    incus info "$name" | grep -qi 'Status: RUNNING' || incus start "$name"
    wait_agent
    ;;
  shell)
    need
    exec incus exec "$name" -- bash -lc 'cd /root/workspace 2>/dev/null; exec bash -l'
    ;;
  stop) need; incus stop "$name" ;;
  rm)   need; incus delete -f "$name"; incus network acl delete "$ACL" 2>/dev/null || true ;;
  *) echo "unknown verb: $verb" >&2; exit 1 ;;
esac
