#!/bin/bash
# Host-side egress firewall for the safeclaude VM.
#
# Runs on the HOST (needs root there), NOT in the guest. That's the point: the
# guest has root for Docker, so a guest-side firewall is no boundary the agent
# can't undo. Enforcing on the host's FORWARD path for the VM's interface keeps
# the allowlist outside the agent's reach.
#
# Allowlist content comes from lima/allowlist.conf (the canonical source, shared
# with the container's init-firewall.sh). Only the enforcement point differs.
#
# Usage:  sudo ./vm-firewall.sh <vm-host-interface>   # e.g. lima0
#
# Note: unlike the container (iptables OUTPUT policy DROP), the host must NOT
# flip a global FORWARD drop — that would break the host's other networking.
# We govern ONLY the VM interface and leave everything else on policy accept.
set -euo pipefail

VM_IF="${1:?usage: vm-firewall.sh <vm-host-interface>}"
TABLE="safeclaude"
ALLOWLIST="$(dirname "$0")/allowlist.conf"
[ -f "$ALLOWLIST" ] || { echo "ERROR: $ALLOWLIST not found"; exit 1; }

cidrs=()

# --- dynamic sources (same as init-firewall.sh) ----------------------------
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
echo "$gh_ranges" | jq -e '.web and .api and .git and .pages' >/dev/null \
  || { echo "ERROR: bad GitHub meta response"; exit 1; }
while read -r c; do cidrs+=("$c"); done \
  < <(echo "$gh_ranges" | jq -r '(.web + .api + .git + .pages)[]')

echo "Fetching Tailscale DERP server IPs..."
derp=$(curl -s https://login.tailscale.com/derpmap/default || true)
if echo "$derp" | jq -e '.Regions' >/dev/null 2>&1; then
  while read -r ip; do cidrs+=("$ip/32"); done \
    < <(echo "$derp" | jq -r '.Regions[].Nodes[].IPv4 // empty')
fi

# --- allowlist.conf: resolve domains (and /24-widen cidr: hosts) ------------
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"; line="${line//[[:space:]]/}"
  [ -z "$line" ] && continue
  if [[ "$line" == cidr:* ]]; then
    host="${line#cidr:}"
    while read -r ip; do cidrs+=("${ip%.*}.0/24"); done \
      < <(dig +short A "$host" | grep -E '^[0-9.]+$' || true)
  else
    while read -r ip; do cidrs+=("$ip/32"); done \
      < <(dig +short A "$line" | grep -E '^[0-9.]+$' || true)
  fi
done < "$ALLOWLIST"

# --- apply with nftables ----------------------------------------------------
nft delete table inet "$TABLE" 2>/dev/null || true
nft add table inet "$TABLE"
nft add set inet "$TABLE" allowed '{ type ipv4_addr; flags interval; }'
elems=$(IFS=,; echo "${cidrs[*]}")
nft add element inet "$TABLE" allowed "{ $elems }"

# FORWARD hook, policy accept so the host's own forwarding is untouched; we only
# clamp traffic originating from the VM interface.
nft add chain inet "$TABLE" forward \
  '{ type filter hook forward priority filter; policy accept; }'
nft add rule inet "$TABLE" forward iifname "!= $VM_IF" accept
nft add rule inet "$TABLE" forward ct state established,related accept
nft add rule inet "$TABLE" forward udp dport 53 accept           # DNS (matches container posture)
nft add rule inet "$TABLE" forward ip daddr @allowed accept
nft add rule inet "$TABLE" forward iifname "$VM_IF" counter reject

echo "Host-side egress firewall applied to $VM_IF (${#cidrs[@]} entries)."

# Smoke test (run INSIDE the guest after applying) — mirrors init-firewall.sh:
#   limactl shell safeclaude-<name> -- sh -c '! curl -sS --connect-timeout 5 https://example.com >/dev/null'
#   limactl shell safeclaude-<name> -- sh -c '  curl -sS --connect-timeout 5 https://api.github.com/zen >/dev/null'
