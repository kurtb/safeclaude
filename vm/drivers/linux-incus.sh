#!/usr/bin/env bash
# Linux driver: Incus VM, CLONE-ONLY, host-enforced egress via a by-name proxy
# (lib/host-egress.sh + proxy/haproxy.cfg) + allowlist-only DNS (Incus's own dnsmasq,
# made allowlist-only here via the network's raw.dnsmasq).
#
# Strongest of the OS drivers. No host filesystem is mounted (clone-only), and
# all egress is enforced host-side where guest-root can't reach it. Edit the
# in-VM clone via devvm shell, SSH over Incus, or explicit file copies.
# New VMs boot bare. devvm upgrade installs the guest base.
#
# Verbs (from ../devvm.sh):  ensure <name> <repo> <vmdir> | shell | stop | rm
#                            | refresh (re-apply the allowlist; no VM touched)
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
# so DNS shares one list with the proxy. Fails loud if absent.
# Same normalisation as lib/host-egress.sh, so DNS and the proxy can't end up
# with different names for one line: drop comments/blanks, trim whitespace and
# CRs, drop a legacy cidr: prefix, lower-case, de-duplicate.
normalise_allowlist() {
  { grep -vE '^[[:space:]]*#|^[[:space:]]*$' || true; } \
    | sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' -e 's/^cidr://' \
    | tr '[:upper:]' '[:lower:]' | LC_ALL=C sort -u
}

build_raw_dnsmasq() {
  local c conf=""
  for c in /usr/local/lib/devvm/allowlist.conf "$VMDIR/allowlist.conf"; do
    [ -r "$c" ] && { conf="$c"; break; }
  done
  [ -n "$conf" ] || { echo "no allowlist.conf found for DNS (run install-host.sh)" >&2; return 1; }
  # Plus this host's own extras (`devvm allow`), the same file host-egress.sh
  # merges, so DNS and the proxy stay on one list.
  local extra=/etc/devvm/allowlist.local
  echo "no-resolv"
  { cat "$conf"; echo; if [ -r "$extra" ]; then cat "$extra"; fi; } \
    | normalise_allowlist \
    | while IFS= read -r d; do [ -n "$d" ] && echo "server=/$d/${DEVVM_DNS_UPSTREAM:-1.1.1.1}"; done
}

ensure_network() {
  if ! incus network show "$NET" >/dev/null 2>&1; then
    # Dedicated bridge; Incus firewalling OFF (our nftables own egress), nat=false
    # (the proxy originates on the host, so the guest needs no NAT — a forward-chain
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

# Linux interface names are limited to 15 bytes. The project name ends with
# the stable eight-digit hash from devvm.sh. The owner tag detects collisions.
project_bridge() {
  local hash=${name##*-}
  [[ $hash =~ ^[0-9a-f]{8}$ ]] || { echo "invalid project name: $name" >&2; return 1; }
  printf 'dvmp-%s' "$hash"
}

ensure_project_network() {
  local net=$1 raw
  raw="$(build_raw_dnsmasq)"
  if ! incus network show "$net" >/dev/null 2>&1; then
    # Incus selects a free subnet from its IPv4 pool and persists the choice.
    incus network create "$net" ipv4.address=auto ipv4.nat=false ipv4.firewall=false \
      ipv6.address=none dns.mode=none "user.devvm.owner=$name" "raw.dnsmasq=$raw" ||
      incus network show "$net" >/dev/null
  fi
  [[ $(incus network get "$net" user.devvm.owner) == "$name" ]] || {
    echo "bridge $net is owned by another project" >&2; return 1;
  }
  incus network set "$net" "raw.dnsmasq=$raw"
}

refresh_project_dns() {
  local nets raw net
  raw="$(build_raw_dnsmasq)"
  nets="$(incus network list --format json | jq -r '.[] |
    select(.name | test("^dvmp-[0-9a-f]{8}$")) |
    select(.config["user.devvm.owner"] != null) | .name')"
  while IFS= read -r net; do
    [[ -n $net ]] && incus network set "$net" "raw.dnsmasq=$raw"
  done <<< "$nets"
  return 0
}

ensure_project_nic() {
  local net=$1 current
  current="$(incus config device get "$name" eth0 network)"
  [[ $current != "$net" ]] || return 0
  if [[ $current != "$NET" ]]; then
    echo "$name has an unexpected eth0 network '$current'; check its NIC before starting it" >&2
    return 1
  fi
  if is_running; then
    echo "Stop $name once with devvm stop, then run devvm up to migrate its legacy network." >&2
    return 1
  fi
  incus config device set "$name" eth0 "network=$net"
}

remove_project() {
  local net
  net="$(project_bridge)"
  if incus info "$name" >/dev/null 2>&1; then incus delete -f "$name"; fi
  if incus network show "$net" >/dev/null 2>&1; then
    [[ $(incus network get "$net" user.devvm.owner) == "$name" ]] || {
      echo "leaving bridge $net owned by another project" >&2; return 1;
    }
    incus network delete "$net"
  fi
}

create_if_absent() {
  incus info "$name" >/dev/null 2>&1 && return 0
  echo "Creating $name (stopped) ..."
  # init (not launch) so egress is enforced before first boot. CLONE-ONLY: no
  # disk device, so the host FS is never reachable from the guest.
  incus init "$IMAGE" "$name" --vm \
    -c "limits.cpu=${DEVVM_CPUS:-4}" -c "limits.memory=${DEVVM_MEMORY:-8GiB}" \
    -d "root,size=${DEVVM_DISK:-40GiB}" -c boot.autostart=false \
    --network "$1"
  # Project VMs remain stopped until requested. The firewall unit also
  # protects a guest started directly through Incus after a host reboot.
  # Nested virt for minikube's kvm2 depends on HOST nested virt being on
  # (kvm_intel/amd nested=1); there's no per-instance VM flag. docker driver
  # needs no nesting. VERIFY on the target host.
}

is_running() { local s; s="$(incus info "$name" 2>/dev/null)"; printf '%s' "$s" | grep -qi 'Status: RUNNING'; }

# The account work happens under in the guest: `dev` once guest-setup.sh has run
# (Claude's --dangerously-skip-permissions and minikube's docker driver both
# refuse root), root in a bare VM.
guest_user() { incus exec "$name" -- id -u dev >/dev/null 2>&1 && echo dev || echo root; }

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
  # Bare VM (guest-setup.sh not run yet): no dev user/git to clone with. The
  # next `devvm` clones once it has.
  [ "$(guest_user)" = dev ] || return 0
  local uid gid home=/home/dev
  uid="$(incus exec "$name" -- id -u dev)"; gid="$(incus exec "$name" -- id -g dev)"
  local dir="$home/workspace/$base"
  incus exec "$name" -- test -d "$dir/.git" >/dev/null 2>&1 && return 0
  echo "Cloning into the guest ($dir) ..."
  # NO credentials are passed in: devvm never handles a GitHub token. A public
  # repo clones here; a private one fails, which is NOT fatal — you authenticate
  # inside the VM with whatever scoped token that VM should hold, then clone.
  # repo/dir are positional args ($1..), never spliced into the string.
  incus exec "$name" --user "$uid" --group "$gid" --env "HOME=$home" --cwd "$home" -- \
    sh -c 'mkdir -p "$1" && GIT_TERMINAL_PROMPT=0 git clone -- "$2" "$3"' _ "$home/workspace" "$repo" "$dir" \
    || echo "clone skipped (private repo?). In the VM: gh auth login --with-token && gh auth setup-git && git clone $repo" >&2
  return 0
}

wait_agent() {
  for _ in $(seq 1 60); do incus exec "$name" -- true >/dev/null 2>&1 && return 0; sleep 2; done
  echo "guest agent not ready after 120s (check incus list)" >&2
  return 1
}

# Re-apply the allowlist to DNS + the proxy + the nft rules. Touches no VM, so
# running guests pick the change up live.
apply_egress() {
  # Run the ROOT-OWNED installed copy, not the checkout.
  local egress=/usr/local/lib/devvm/host-egress.sh
  [ -x "$egress" ] || { echo "host egress not installed; from a trusted safeclaude checkout run sudo ./vm/install-host.sh" >&2; exit 1; }
  sudo "$egress"
}

prepare_project() {
  local net
  need; ensure_network
  net="$(project_bridge)"
  ensure_project_network "$net"
  if [[ $verb == ensure ]]; then create_if_absent "$net"; fi
  ensure_project_nic "$net"
  apply_egress
}

start_with_egress() {
  prepare_project
  is_running || incus start "$name"
  wait_agent
}

cmd_ensure() {
  start_with_egress
  # Nothing is installed at boot: a new VM is a bare machine. Say how to set it up.
  [ "$(guest_user)" = dev ] \
    || echo "NOTE: $name is a bare VM (root shell). Exit and run devvm upgrade from this project on the host to install the base setup." >&2
  clone_repo
}

cmd_upgrade() {
  need
  incus info "$name" >/dev/null                  # upgrade only an existing instance
  start_with_egress
  # Stage only named distribution files; never copy a project clone or host
  # environment. Keep companion scripts next to guest-setup as in a checkout.
  local files=(guest-setup.sh)
  if [ -f "$VMDIR/gh-auth-setup" ]; then files+=(gh-auth-setup); fi
  tar -C "$VMDIR" -cf - "${files[@]}" | incus exec "$name" -T -- bash -ceu '
    stage=$(mktemp -d)
    cleanup() { rm -rf -- "$stage"; }
    trap cleanup EXIT
    tar -xf - -C "$stage"
    bash "$stage/guest-setup.sh"
  '

  # Setup's idempotent install steps skip an existing Docker or Claude. Bring
  # those forward too, preserving the locally installed Docker package family.
  incus exec "$name" -T -- bash -se <<'GUEST'
packages=()
for pkg in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io; do
  if [ "$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null)" = installed ]; then
    packages+=("$pkg")
  fi
done
if [ "${#packages[@]}" -gt 0 ]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade "${packages[@]}"
fi
su - dev -s /bin/bash -c 'exec "$HOME/.local/bin/claude" update'
GUEST
}

cmd_shell() {
  need
  # Login shell as the unprivileged `dev` user (docker group + passwordless sudo;
  # the egress boundary is on the host, so guest sudo can't weaken it). The guest's
  # /etc/profile.d/devvm-workspace.sh cd's into the clone. Plain `su -` (no -c)
  # keeps the tty and job control.
  if [ "$(guest_user)" = dev ]; then exec incus exec "$name" -- su - dev; fi
  # No dev user: root shell. A bare VM lands in /root; a VM from before the dev
  # user existed still lands in its single clone under /root/workspace.
  exec incus exec "$name" -- bash -lc 'd=(/root/workspace/*/); [ ${#d[@]} -eq 1 ] && [ -d "${d[0]}" ] && cd "${d[0]}"; exec bash -l'
}

case "$verb" in
  ensure) cmd_ensure ;;
  refresh) need; ensure_network; refresh_project_dns; apply_egress ;;
  shell)  cmd_shell ;;
  list)   need; incus list 'devvm-' type=virtual-machine -c ns --format compact ;;
  upgrade) cmd_upgrade ;;
  snapshot) need; incus snapshot create "$name" "${5:?missing snapshot label}" </dev/null ;;
  restore)
    need
    label="${5:?missing snapshot label}"
    incus snapshot show "$name" "$label" >/dev/null
    # A running VM may restart during restore. Reapply enforcement first,
    # and keep today's NICs, boot policy and sizing even for legacy snapshots.
    prepare_project
    incus snapshot restore "$name" "$label" --diskonly
    if is_running; then
      wait_agent
      # The Incus agent can answer while Ubuntu is still booting and an
      # immediate graceful stop can miss its ACPI shutdown request.
      incus exec "$name" -- sh -c '
        state=$(timeout 120 systemctl is-system-running --wait)
        case "$state" in running|degraded) exit 0 ;; esac
        echo "guest boot did not finish after restore (state: ${state:-unknown})" >&2
        exit 1
      '
    fi ;;
  doctor) need
    # shellcheck source=/dev/null
    source "$VMDIR/lib/doctor.sh"
    cmd_doctor "$name" ;;
  ssh-config|cp) exec "$VMDIR/drivers/incus-editor.sh" "$verb" "$name" "$VMDIR" "${@:5}" ;;
  stop)   need; incus stop "$name" ;;
  rm)     need; remove_project ;;
  *) echo "unknown verb: $verb" >&2; exit 1 ;;
esac
