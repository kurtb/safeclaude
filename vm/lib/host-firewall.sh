#!/usr/bin/env bash
# Restore the last complete policy before Incus starts, even when its bridges
# do not exist yet. nft's interface-name matches do not need kernel ifindices.
set -euo pipefail
NET="${DEVVM_NET:-devvmbr0}"
SUBNET="${DEVVM_SUBNET:-10.63.0.0/24}"
PROXY_IP="${DEVVM_PROXY_IP:-10.63.0.1}"
state=/etc/devvm/firewall.nft

# Keep the kernel's normalized rules (without counters) for devvm doctor.
snapshot() {
  local dir=/run/devvm-firewall-applied family
  install -d -o root -g root -m 0755 "$dir"
  for family in inet bridge; do
    nft -s list table "$family" devvm >"$dir/$family.new"
    mv -f "$dir/$family.new" "$dir/$family"
  done
}

exec 8>/run/devvm-firewall.lock
flock -w 120 8
if [[ ${1:-} == --restore && -f $state ]]; then
  nft -f "$state"
  snapshot
  exit 0
fi

install -d -o root -g root -m 0755 /etc/devvm
rules=$(mktemp /etc/devvm/.firewall.XXXXXX)
trap 'rm -f "$rules"' EXIT
# The coordinator bridge retains the proxy address used by older releases.
# Each project bridge has its own Incus DHCP/DNS server. Permit DNS only to
# that particular gateway. A newly created bridge matches the default deny
# immediately and gets its DNS rule on the next apply, before starting a VM.
bridges=$(ip -j -4 addr show | jq -r '
  .[] | select(.ifname // "" | test("^dvmp-[a-f0-9]{8}$")) |
  .ifname as $bridge | .addr_info[] | select(.family == "inet" and .scope == "global") |
  "\($bridge) \(.local)"')
{
  cat <<NFT
add table inet devvm
delete table inet devvm
table inet devvm {
  chain prerouting {
    type nat hook prerouting priority dstnat;
    iifname "$NET" ip saddr $SUBNET tcp dport 80 dnat ip to $PROXY_IP:3129
    iifname "$NET" ip saddr $SUBNET tcp dport 443 dnat ip to $PROXY_IP:3130
    iifname "dvmp-*" tcp dport 80 dnat ip to $PROXY_IP:3129
    iifname "dvmp-*" tcp dport 443 dnat ip to $PROXY_IP:3130
  }
  chain input {
    type filter hook input priority filter; policy accept;
    iifname "$NET" jump guest
    iifname "dvmp-*" jump guest
  }
  chain guest {
    ct state established,related accept
    udp dport 67 accept
    iifname "$NET" ip daddr $PROXY_IP udp dport 53 accept
    iifname "$NET" ip daddr $PROXY_IP tcp dport 53 accept
NFT
  while read -r bridge gateway; do
    [[ -n $bridge ]] || continue
    printf '    iifname "%s" ip daddr %s udp dport 53 accept\n' "$bridge" "$gateway"
    printf '    iifname "%s" ip daddr %s tcp dport 53 accept\n' "$bridge" "$gateway"
  done <<< "$bridges"
  cat <<NFT
    ip daddr $PROXY_IP ct status dnat tcp dport { 3129, 3130 } accept
    counter drop
  }
  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname "$NET" counter reject
    iifname "dvmp-*" counter reject
    oifname "$NET" drop
    oifname "dvmp-*" drop
  }
}
# Protect existing guests on the legacy shared segment during migration.
add table bridge devvm
delete table bridge devvm
table bridge devvm {
  chain forward {
    type filter hook forward priority filter; policy accept;
    meta ibrname "$NET" drop
    meta ibrname "dvmp-*" drop
  }
}
NFT
} >"$rules"
nft -f "$rules"
mv -f "$rules" "$state"
snapshot
