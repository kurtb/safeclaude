#!/usr/bin/env bash
# Host-side egress enforcement for devvm (Linux/Incus). Runs on the HOST as root.
#
# Forces the VM subnet through: a transparent SNI allowlist proxy (Squid) for
# HTTP/S, an allowlist-ONLY DNS resolver (dnsmasq) for everything else, and
# nftables that drop any other direct egress. All of this lives on the host, so
# a guest-root agent cannot alter it.
#
# STATUS: designed, NOT run (no Incus/KVM on the build box). Lines marked VERIFY
# need a live check against the actual Incus network config.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET="${DEVVM_NET:-devvmbr0}"
SUBNET="${DEVVM_SUBNET:-10.63.0.0/24}"     # VERIFY: must match the Incus network ipv4.address
PROXY_IP="${DEVVM_PROXY_IP:-10.63.0.1}"    # bridge/host IP the VM reaches
SQUID_HTTP=3129; SQUID_HTTPS=3130

# Domain allowlist (names only) from the shared file — feeds BOTH Squid + dnsmasq.
domains="$(grep -vE '^\s*#|^\s*$' "$HERE/../allowlist.conf" | sed 's/^cidr://' | sort -u)"

# 1) Squid allowlist + config.
install -d /etc/squid
printf '%s\n' "$domains" > /etc/squid/devvm-allowed-domains
install -D "$HERE/../proxy/squid.conf" /etc/squid/conf.d/devvm.conf   # VERIFY conf.d path
systemctl reload squid 2>/dev/null || systemctl restart squid

# 2) Allowlist-ONLY DNS: resolve only allowlisted domains (per-domain upstream),
#    everything else NXDOMAIN (no default upstream) — closes the DNS-tunnel hole.
{
  echo "no-resolv"; echo "bind-interfaces"
  echo "interface=$NET"; echo "listen-address=$PROXY_IP"
  while IFS= read -r d; do [ -n "$d" ] && echo "server=/$d/1.1.1.1"; done <<< "$domains"
} > /etc/dnsmasq.d/devvm.conf
systemctl restart dnsmasq   # VERIFY: or a dedicated instance so Incus's own dnsmasq isn't clobbered

# 3) nftables: VM subnet -> proxy (80/443) + allowlisted DNS only; drop the rest.
#    Policy stays accept so the host's other networking is untouched; we only
#    clamp the VM subnet.
nft -f - <<EOF
table inet devvm {
  chain prerouting {
    type nat hook prerouting priority dstnat;
    ip saddr $SUBNET tcp dport 80  dnat ip to $PROXY_IP:$SQUID_HTTP
    ip saddr $SUBNET tcp dport 443 dnat ip to $PROXY_IP:$SQUID_HTTPS
  }
  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname != "$NET" accept
    ct state established,related accept
    ip saddr $SUBNET ip daddr $PROXY_IP udp dport 53 accept
    ip saddr $SUBNET ip daddr $PROXY_IP tcp dport 53 accept
    ip saddr $SUBNET ip daddr $PROXY_IP tcp dport { $SQUID_HTTP, $SQUID_HTTPS } accept
    ip saddr $SUBNET counter reject
  }
}
EOF
echo "devvm host egress configured on $NET ($SUBNET): SNI proxy + allowlist DNS + default-deny"
