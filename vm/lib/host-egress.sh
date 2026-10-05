#!/usr/bin/env bash
# Host-side egress enforcement for devvm (Linux/Incus). Runs on the HOST as root.
#
# Two gates that BOTH must pass (the #25 review showed either alone is bypassable):
#   1. nftables dest-IP pin — only :80/:443 to an allowlisted, bogon-filtered IP
#      is DNATed to the proxy. Defeats `curl --resolve <allowed-sni>:443:<evil-ip>`
#      and host-side SSRF to 169.254.169.254 / RFC1918.
#   2. Squid SNI/Host allowlist — only allowlisted domains are spliced through.
# Plus an `input` chain so the guest can't reach host services on the bridge IP,
# and an allowlist-only resolver so DNS can't tunnel.
#
# Everything lives on the host; guest-root cannot alter it.
#
# STATUS: designed, NOT run (no Incus/KVM on the build box). VERIFY markers flag
# spots needing a live check. Install this root-owned, not from a user-writable
# checkout, before trusting it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET="${DEVVM_NET:-devvmbr0}"
SUBNET="${DEVVM_SUBNET:-10.63.0.0/24}"     # VERIFY: must match the Incus network ipv4.address
PROXY_IP="${DEVVM_PROXY_IP:-10.63.0.1}"    # bridge/host IP the VM reaches
SQUID_HTTP=3129; SQUID_HTTPS=3130

# Domain allowlist (names) for Squid + dnsmasq.
domains="$(grep -vE '^\s*#|^\s*$' "$HERE/../allowlist.conf" | sed 's/^cidr://' | sort -u)"
# Resolved, SSRF-filtered IPv4 CIDRs for the dest-IP pin (wires in resolve-allowlist).
allowed4="$("$HERE/resolve-allowlist.sh" | grep -v ':' || true)"

# 1) Squid allowlist + config.
install -d /etc/squid
printf '%s\n' "$domains" > /etc/squid/devvm-allowed-domains
install -D "$HERE/../proxy/squid.conf" /etc/squid/conf.d/devvm.conf   # VERIFY conf.d include order; needs squid-openssl (stock squid is GnuTLS, no ssl-bump)
systemctl reload squid 2>/dev/null || systemctl restart squid

# 2) Allowlist-ONLY DNS. Requires the Incus network to have dns.mode=none (set by
#    the driver) so this doesn't collide with Incus's own dnsmasq. VERIFY it runs
#    as a dedicated instance bound to $PROXY_IP and doesn't touch a system dnsmasq.
{
  echo "no-resolv"; echo "bind-interfaces"
  echo "interface=$NET"; echo "listen-address=$PROXY_IP"
  while IFS= read -r d; do [ -n "$d" ] && echo "server=/$d/1.1.1.1"; done <<< "$domains"
} > /etc/dnsmasq.d/devvm.conf
systemctl restart dnsmasq   # VERIFY: dedicated instance, not a shared system one

# 3) nftables. Replace the table each run (idempotent; never fail open or
#    duplicate rules). Policy stays accept so the host's other traffic is
#    untouched; we clamp only the VM subnet.
nft delete table inet devvm 2>/dev/null || true
nft -f - <<EOF
table inet devvm {
  set allowed4 { type ipv4_addr; flags interval; auto-merge;
    elements = { $(printf '%s,' $allowed4) 255.255.255.255/32 }
  }
  chain prerouting {
    type nat hook prerouting priority dstnat;
    # DNAT to the proxy ONLY when the ORIGINAL destination is an allowlisted IP.
    ip saddr $SUBNET ip daddr @allowed4 tcp dport 80  dnat ip to $PROXY_IP:$SQUID_HTTP
    ip saddr $SUBNET ip daddr @allowed4 tcp dport 443 dnat ip to $PROXY_IP:$SQUID_HTTPS
  }
  chain input {
    type filter hook input priority filter; policy accept;
    iifname != "$NET" accept
    ct state established,related accept
    iifname "$NET" udp dport { 53, 67 } accept                 # DNS + DHCP to the host
    iifname "$NET" tcp dport { 53, $SQUID_HTTP, $SQUID_HTTPS } accept
    iifname "$NET" drop                                        # no other host services
  }
  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname != "$NET" accept
    ct state established,related accept
    ip saddr $SUBNET counter reject                            # no direct egress; only DNATed proxy paths survive
  }
}
EOF
echo "devvm host egress on $NET ($SUBNET): dest-IP pin + SNI proxy + allowlist DNS + default-deny"
