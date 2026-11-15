#!/usr/bin/env bash
# Linux driver: Incus VM, CLONE-ONLY, host-enforced egress via dest-IP pin +
# SNI proxy (lib/host-egress.sh) + allowlist-only DNS (Incus's own dnsmasq,
# made allowlist-only here via the network's raw.dnsmasq).
#
# Strongest of the OS drivers. No host filesystem is mounted (clone-only), and
# all egress is enforced host-side where guest-root can't reach it. Edit the
# in-VM clone via `devvm shell`/`incus exec` (VS Code Remote-SSH is a planned
# follow-up; the cloud image ships no sshd/host key yet).
#
# Verbs (from ../devvm.sh):  ensure <name> <repo> <vmdir> | shell | stop | rm
#
# STATUS: validated live on ARM Incus 7.5.1 + KVM (create, boot, clone, egress
# smoke test). Spots still needing a live check are marked VERIFY.
set -euo pipefail
verb="${1:?}"; name="${2:?}"; repo="${3:-}"; VMDIR="${4:?}"
IMAGE="images:ubuntu/24.04/cloud"
NET="devvmbr0"

need() { command -v incus >/dev/null || { echo "incus not installed" >&2; exit 1; }; }

# Build allowlist-only DNS config for Incus's OWN dnsmasq (it owns :53 on the
# bridge and serves DHCP — a second dnsmasq can't bind the port; confirmed on a
# live host). `no-resolv` kills the default upstream; one server=/<domain>/<up>
# per allowlisted host means only allowlisted zones resolve — everything else
# gets no upstream => NXDOMAIN. Sourced from the installed root-owned allowlist
# so DNS shares one list with the nft/Squid layers. Fails loud if absent.
build_raw_dnsmasq() {
  local c conf=""
  for c in /usr/local/lib/devvm/allowlist.conf "$VMDIR/allowlist.conf"; do
    [ -r "$c" ] && { conf="$c"; break; }
  done
  [ -n "$conf" ] || { echo "no allowlist.conf found for DNS (run install-host.sh)" >&2; return 1; }
  echo "no-resolv"
  grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$conf" | sed 's/^cidr://' | sort -u \
    | while IFS= read -r d; do [ -n "$d" ] && echo "server=/$d/${DEVVM_DNS_UPSTREAM:-1.1.1.1}"; done
}

ensure_network() {
  if ! incus network show "$NET" >/dev/null 2>&1; then
    # Dedicated bridge; Incus firewalling OFF (our nftables own egress), nat=false
    # (Squid originates on the host, so the guest needs no NAT — a forward-chain
    # hole isn't real egress), dns.mode=none (no auto instance DNS records; the
    # DNS *content* comes from raw.dnsmasq, set just below).
    # VERIFY subnet matches DEVVM_SUBNET in host-egress.sh (10.63.0.0/24).
    incus network create "$NET" \
      ipv4.address=10.63.0.1/24 ipv4.nat=false ipv4.firewall=false \
      dns.mode=none ipv6.address=none
  fi
  # Make Incus's own dnsmasq allowlist-only, every run (so the list can't drift).
  local raw; raw="$(build_raw_dnsmasq)" || { echo "DNS allowlist build failed" >&2; return 1; }
  # key=value form (the "key value" form is deprecated); $raw carries real
  # newlines from the command substitution, preserved as one argument.
  incus network set "$NET" "raw.dnsmasq=$raw"
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
  # Don't auto-start on host boot: nft rules aren't persisted, so an autostarted
  # VM could come up before egress is applied. `devvm`
  # re-applies egress on every ensure before starting.
  incus config set "$name" boot.autostart=false
  # Nested virt for minikube's kvm2 depends on HOST nested virt being on
  # (kvm_intel/amd nested=1); there's no per-instance VM flag. docker driver
  # needs no nesting. VERIFY on the target host.
}

is_running() { local s; s="$(incus info "$name" 2>/dev/null)"; printf '%s' "$s" | grep -qi 'Status: RUNNING'; }

clone_repo() {
  [ -n "$repo" ] || { echo "no git origin in \$PWD; starting empty workspace"; return 0; }
  # Only https:// is cloneable (SSH has no keys/egress; reject ext::/git:: etc.).
  case "$repo" in
    https://*) ;;
    *) echo "origin '$repo' is not https://; skipping clone (use the HTTPS URL)." >&2; return 0 ;;
  esac
  # Strip any embedded userinfo (user:token@host) so creds don't reach the guest/argv.
  repo="$(printf '%s' "$repo" | sed -E 's#^https://[^/@]*@#https://#')"
  local base; base="$(basename "${repo%.git}")"
  [[ "$base" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$base" != . ] && [ "$base" != .. ] \
    || { echo "refusing odd repo dir name derived from origin: '$base'" >&2; return 1; }
  local dir="/root/workspace/$base"
  incus exec "$name" -- test -d "$dir/.git" >/dev/null 2>&1 && return 0
  # Wait for cloud-init to finish (git/gh/docker come from it), not just the agent.
  incus exec "$name" -- cloud-init status --wait >/dev/null 2>&1 || true
  # gh auth via stdin (never in argv/logs). The token is handed to a guest-root
  # agent and persisted there, so use a FINE-GRAINED, READ-ONLY, repo-scoped
  # token — treat it as compromised-on-use. Failures are reported, not swallowed.
  if [ -n "${GH_TOKEN:-}" ]; then
    if printf '%s' "$GH_TOKEN" | incus exec "$name" -- gh auth login --with-token; then
      incus exec "$name" -- gh auth setup-git || echo "WARNING: gh auth setup-git failed" >&2
    else
      echo "WARNING: gh auth login failed (token invalid/expired?)" >&2
    fi
  fi
  echo "Cloning into the guest ..."
  # repo/dir passed as positional args ($1/$2), never spliced into the string.
  incus exec "$name" -- bash -lc 'install -d /root/workspace && git clone -- "$1" "$2"' _ "$repo" "$dir" \
    || { echo "clone failed (private repo? set GH_TOKEN before 'devvm up')" >&2; return 1; }
}

wait_agent() {
  for _ in $(seq 1 60); do incus exec "$name" -- true >/dev/null 2>&1 && return 0; sleep 2; done
  echo "WARNING: guest agent not ready; cloud-init may still be running" >&2
}

cmd_ensure() {
  need; ensure_network; create_if_absent
  # Run the ROOT-OWNED installed copy, not the checkout.
  local egress=/usr/local/lib/devvm/host-egress.sh
  [ -x "$egress" ] || { echo "host egress not installed; run: sudo \"$VMDIR/install-host.sh\"" >&2; exit 1; }
  sudo "$egress"                                # host egress re-applied every run (never fail open)
  is_running || incus start "$name"
  wait_agent; clone_repo
}

cmd_shell() {
  need
  # cd into the single clone if there's exactly one, else the workspace root.
  exec incus exec "$name" -- bash -lc 'd=(/root/workspace/*/); [ ${#d[@]} -eq 1 ] && [ -d "${d[0]}" ] && cd "${d[0]}" || cd /root/workspace; exec bash -l'
}

case "$verb" in
  ensure) cmd_ensure ;;
  shell)  cmd_shell ;;
  stop)   need; incus stop "$name" ;;
  rm)     need; incus delete -f "$name" ;;
  *) echo "unknown verb: $verb" >&2; exit 1 ;;
esac
