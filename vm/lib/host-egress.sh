#!/usr/bin/env bash
# Host-side egress enforcement for devvm (Linux/Incus). Runs on the HOST as root,
# from a ROOT-OWNED install dir (see install-host.sh) — never from the checkout,
# so a user/agent that can write the repo can't change what runs as root.
#
# Two layered gates that BOTH must pass (either alone is bypassable):
#   1. nftables dest-IP pin — only :80/:443 to an allowlisted, bogon-filtered IP
#      is DNATed to the proxy (defeats `--resolve <allowed-sni>:443:<evil-ip>`
#      and host SSRF to 169.254.169.254 / RFC1918).
#   2. Squid SNI/Host allowlist — only allowlisted domains are spliced through.
# Plus an `input` chain (guest can't reach host services) and an allowlist-only
# resolver. Known residual exfil (shared-CDN domain fronting, subdomain DNS) is
# the same trade-off as the container — see vm/README.md.
#
# STATUS: designed, NOT run (no Incus/KVM on the build box). VERIFY markers flag
# spots needing a live check.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET="${DEVVM_NET:-devvmbr0}"
SUBNET="${DEVVM_SUBNET:-10.63.0.0/24}"     # VERIFY: must match the Incus network ipv4.address
PROXY_IP="${DEVVM_PROXY_IP:-10.63.0.1}"
SQUID_HTTP=3129; SQUID_HTTPS=3130

# Refuse to run from a non-root-owned or group/world-writable dir (anti-tamper).
owner="$(stat -c '%U' "$HERE")"; perm="$(stat -c '%a' "$HERE")"
if [ "$owner" != root ] || [ $((8#$perm & 8#022)) -ne 0 ]; then
  echo "refusing: $HERE must be root-owned and not group/world-writable; run install-host.sh" >&2
  exit 1
fi

# Config lives alongside this script in the install dir (fallback to checkout layout).
CONF="$HERE/allowlist.conf";      [ -f "$CONF" ] || CONF="$HERE/../allowlist.conf"
SQUIDCONF="$HERE/squid.conf";     [ -f "$SQUIDCONF" ] || SQUIDCONF="$HERE/../proxy/squid.conf"
RESOLVE="$HERE/resolve-allowlist.sh"; [ -x "$RESOLVE" ] || RESOLVE="$HERE/resolve-allowlist.sh"

domains="$(grep -vE '^\s*#|^\s*$' "$CONF" | sed 's/^cidr://' | sort -u)"
allowed4="$("$RESOLVE" | grep -v ':' || true)"
elems="$(printf '%s\n' $allowed4 | sed '/^$/d' | paste -sd, -)"   # comma-joined, no trailing comma

# 1) Squid allowlist + config.
install -d /etc/squid
printf '%s\n' "$domains" > /etc/squid/devvm-allowed-domains
install -D "$SQUIDCONF" /etc/squid/conf.d/devvm.conf   # VERIFY conf.d order; needs squid-openssl
systemctl reload squid 2>/dev/null || systemctl restart squid

# 2) Allowlist-only DNS. Needs dns.mode=none on the Incus net (driver sets it) so
#    this doesn't collide with Incus's dnsmasq. NOTE: server=/d/ forwards all
#    subdomains of d, so a slow DNS tunnel under an allowlisted zone is still
#    possible (documented). VERIFY this is a dedicated instance, not a system one.
{
  echo "no-resolv"; echo "bind-interfaces"
  echo "interface=$NET"; echo "listen-address=$PROXY_IP"
  while IFS= read -r d; do [ -n "$d" ] && echo "server=/$d/1.1.1.1"; done <<< "$domains"
} > /etc/dnsmasq.d/devvm.conf
systemctl restart dnsmasq   # VERIFY dedicated instance

# 3) nftables — applied as ONE atomic transaction (add-before-delete so it never
#    leaves the table gone / fails open). An empty allowed4 => empty set => every
#    egress is dropped (fail CLOSED). Policy stays accept; only the VM subnet is
#    clamped. Squid is bound to $PROXY_IP (see squid.conf).
set_line="  set allowed4 { type ipv4_addr; flags interval; auto-merge; }"
[ -n "$elems" ] && set_line="  set allowed4 { type ipv4_addr; flags interval; auto-merge; elements = { $elems } }"
nft -f - <<EOF
add table inet devvm
delete table inet devvm
table inet devvm {
$set_line
  chain prerouting {
    type nat hook prerouting priority dstnat;
    ip saddr $SUBNET ip daddr @allowed4 tcp dport 80  dnat ip to $PROXY_IP:$SQUID_HTTP
    ip saddr $SUBNET ip daddr @allowed4 tcp dport 443 dnat ip to $PROXY_IP:$SQUID_HTTPS
  }
  chain input {
    type filter hook input priority filter; policy accept;
    iifname != "$NET" accept
    ct state established,related accept
    iifname "$NET" udp dport { 53, 67 } accept
    iifname "$NET" tcp dport { 53, $SQUID_HTTP, $SQUID_HTTPS } accept
    iifname "$NET" drop
  }
  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname != "$NET" accept
    ct state established,related accept
    ip saddr $SUBNET counter reject
  }
}
EOF
echo "devvm host egress on $NET ($SUBNET): dest-IP pin + SNI proxy + allowlist DNS + default-deny"
