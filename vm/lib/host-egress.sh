#!/usr/bin/env bash
# Host-side egress enforcement for devvm (Linux/Incus). Runs on the HOST as root,
# from the ROOT-OWNED install dir only (install-host.sh) — never the checkout,
# so a user/agent that can write the repo can't change what runs as root.
#
# Layered gates (each closes a bypass the others don't):
#   1. nftables dest-IP pin — only :80/:443 to an allowlisted, bogon-filtered IP
#      is DNATed to the proxy (defeats `--resolve <allowed-sni>:443:<evil-ip>`
#      and host SSRF to 169.254.169.254 / RFC1918).
#   2. Squid SNI/Host allowlist — only allowlisted domains spliced through.
#   3. input chain — guest can't reach host services beyond DNS/DHCP/Squid.
#   4. dedicated allowlist-only dnsmasq — non-allowlisted names NXDOMAIN.
# Residual exfil (shared-CDN fronting, subdomain DNS) is documented in README as
# accepted (same posture as the container).
#
# STATUS: designed, NOT run (no Incus/KVM on the build box). VERIFY markers flag
# spots needing a live check.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET="${DEVVM_NET:-devvmbr0}"
SUBNET="${DEVVM_SUBNET:-10.63.0.0/24}"     # VERIFY: must match the Incus network ipv4.address
PROXY_IP="${DEVVM_PROXY_IP:-10.63.0.1}"
SQUID_HTTP=3129; SQUID_HTTPS=3130

# Config lives alongside this script in the root-owned install dir. No checkout
# fallback — require the installed copy, and verify each file is root-owned and
# not group/world-writable (anti-tamper).
CONF="$HERE/allowlist.conf"; SQUIDCONF="$HERE/squid.conf"; RESOLVE="$HERE/resolve-allowlist.sh"
for f in "$HERE" "$CONF" "$SQUIDCONF" "$RESOLVE"; do
  [ -e "$f" ] || { echo "missing $f — run install-host.sh" >&2; exit 1; }
  o="$(stat -c '%U' "$f")"; p="$(stat -c '%a' "$f")"
  { [ "$o" = root ] && [ $((8#$p & 8#022)) -eq 0 ]; } \
    || { echo "refusing: $f must be root-owned and not group/world-writable" >&2; exit 1; }
done

domains="$(grep -vE '^\s*#|^\s*$' "$CONF" | sed 's/^cidr://' | sort -u)"
mapfile -t allowed4 < <("$RESOLVE" | grep -v ':' || true)       # no word-splitting
elems="$(printf '%s\n' "${allowed4[@]:-}" | sed '/^$/d' | paste -sd, -)"

# 1) Squid allowlist + config.
install -d /etc/squid
printf '%s\n' "$domains" > /etc/squid/devvm-allowed-domains
install -D "$SQUIDCONF" /etc/squid/conf.d/devvm.conf   # VERIFY conf.d order; needs squid-openssl
systemctl reload squid 2>/dev/null || systemctl restart squid

# 2) DEDICATED allowlist-only dnsmasq (does NOT touch the host's own dnsmasq).
#    Needs dns.mode=none on the Incus net (driver sets it). NOTE: server=/d/
#    forwards all subdomains of d — a slow DNS tunnel under an allowlisted zone
#    is still possible (documented).
dconf=/run/devvm-dnsmasq.conf
{
  echo "no-resolv"; echo "bind-interfaces"
  echo "interface=$NET"; echo "listen-address=$PROXY_IP"; echo "except-interface=lo"
  echo "pid-file=/run/devvm-dnsmasq.pid"
  while IFS= read -r d; do [ -n "$d" ] && echo "server=/$d/1.1.1.1"; done <<< "$domains"
} > "$dconf"
[ -f /run/devvm-dnsmasq.pid ] && kill "$(cat /run/devvm-dnsmasq.pid)" 2>/dev/null || true
dnsmasq --conf-file="$dconf"   # VERIFY: own instance; survives via a systemd unit in prod

# 3) nftables — ONE atomic transaction (add-before-delete; never leaves the
#    table gone / fails open). Empty allowed4 => empty set => all egress dropped
#    (fail CLOSED). Policy accept so the host's other traffic is untouched; only
#    the VM subnet/interface is clamped. Squid is bound to $PROXY_IP.
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
    ct state established,related accept
    oifname "$NET" ct state new drop          # no new inbound to guests (LAN/other ifaces)
    iifname "$NET" counter reject             # no direct guest egress (only DNATed proxy, which hits input)
  }
}
EOF
echo "devvm host egress on $NET ($SUBNET): dest-IP pin + SNI proxy + allowlist DNS + default-deny"
