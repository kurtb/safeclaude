#!/usr/bin/env bash
# Host-side egress enforcement for devvm (Linux/Incus). Runs on the HOST as root,
# from the ROOT-OWNED install dir only (install-host.sh) — never the checkout,
# so a user/agent that can write the repo can't change what runs as root.
#
# Layered gates (each closes a bypass the others don't):
#   1. nftables — ALL of the guest's :80/:443 is DNATed to the proxy, whatever
#      IP it aimed at; every other new connection from the guest is rejected.
#      The guest has no direct route out.
#   2. The proxy (proxy/haproxy.cfg) — allows a connection only if its server
#      name (TLS SNI / HTTP Host) is on the allowlist, then RESOLVES THAT NAME
#      ITSELF and connects there. The guest's chosen IP is never used, which
#      defeats `--resolve <allowed-name>:443:<evil-ip>`, and a name that
#      resolves to a private/loopback/metadata address is refused (SSRF).
#   3. input chain — guest can't reach host services beyond DNS/DHCP/the proxy.
#   4. allowlist-only DNS — Incus's own dnsmasq, made allowlist-only by the
#      driver via the network's raw.dnsmasq (no-resolv + per-domain upstream);
#      non-allowlisted names get no upstream => no answer.
#
# There is deliberately NO list of allowed IPs any more: the old design pinned a
# resolve-time snapshot, which went stale whenever a CDN rotated (VEC-231), and
# its proxy rejected connections whenever guest and proxy DNS disagreed
# (VEC-234). Names are the only thing configured; addresses are looked up per
# connection by the proxy.
#
# Residual exfil (shared-CDN fronting, subdomain DNS) is documented in README as
# accepted.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET="${DEVVM_NET:-devvmbr0}"
SUBNET="${DEVVM_SUBNET:-10.63.0.0/24}"     # must match the Incus network ipv4.address
PROXY_IP="${DEVVM_PROXY_IP:-10.63.0.1}"
PORT_HTTP=3129; PORT_HTTPS=3130
ETC=/etc/devvm

# Config lives alongside this script in the root-owned install dir. No checkout
# fallback — require the installed copy, and verify each file is root-owned and
# not group/world-writable (anti-tamper).
CONF="$HERE/allowlist.conf"; PROXYCONF="$HERE/haproxy.cfg"; BOGONS="$HERE/bogons.lst"
check_owned() {
  local o p
  o="$(stat -c '%U' "$1")"; p="$(stat -c '%a' "$1")"
  { [ "$o" = root ] && [ $((8#$p & 8#022)) -eq 0 ]; } \
    || { echo "refusing: $1 must be root-owned and not group/world-writable" >&2; exit 1; }
}
for f in "$HERE" "$CONF" "$PROXYCONF" "$BOGONS"; do
  [ -e "$f" ] || { echo "missing $f — run install-host.sh" >&2; exit 1; }
  check_owned "$f"
done
command -v haproxy >/dev/null || { echo "haproxy is not installed (apt install haproxy)" >&2; exit 1; }
[ -e /etc/systemd/system/devvm-proxy.service ] || { echo "devvm-proxy.service missing — run install-host.sh" >&2; exit 1; }

# One apply at a time, machine-wide: every project's `devvm up` and every
# `devvm allow` runs this script against the same files, table and proxy.
exec 9>/run/devvm-egress.lock
flock -w 120 9 || { echo "another devvm egress apply is still running (waited 120s)" >&2; exit 1; }

# Effective allowlist = the installed base list + this host's own extras
# (`devvm allow`). The extras file lives outside the install dir so re-running
# install-host.sh doesn't wipe it, and gets the same anti-tamper check (the
# directory too: a writable parent would let the file be swapped). It is
# written only by root on the host, never by anything in a guest.
LOCAL="$ETC/allowlist.local"
install -d -o root -g root -m 0755 "$ETC"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat "$CONF" > "$tmp/list"
if [ -e "$LOCAL" ]; then
  check_owned "$ETC"; check_owned "$LOCAL"
  { echo; cat "$LOCAL"; } >> "$tmp/list"
fi
# One exact host name per line. A legacy `cidr:` prefix (it used to widen the IP
# pin) is accepted and ignored. Anything that isn't a plain host name is fatal:
# this file is matched verbatim by the proxy, so never let junk through.
if grep -qE '^cidr:' "$tmp/list"; then
  echo "note: 'cidr:' prefixes in the allowlist are ignored (there is no IP pin to widen any more)" >&2
fi
grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$tmp/list" | sed 's/^cidr://' \
  | tr '[:upper:]' '[:lower:]' | sort -u > "$tmp/domains"
bad="$(grep -vE '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$' "$tmp/domains" || true)"
[ -z "$bad" ] || { echo "FATAL: not a plain host name in the allowlist (no inline comments, wildcards or IPs):" >&2; echo "$bad" >&2; exit 1; }
[ -s "$tmp/domains" ] || { echo "FATAL: the allowlist is empty; refusing to apply" >&2; exit 1; }

# 1) Proxy config. Validate the new config BEFORE installing it, so a bad edit
#    leaves the running proxy and its rules untouched.
sed -e "s/@PROXY_IP@/$PROXY_IP/g" -e "s#@DOMAINS@#$ETC/allowed-domains#g" \
    -e "s#@BOGONS@#$BOGONS#g" "$PROXYCONF" > "$tmp/haproxy.cfg"
# By default the proxy resolves through the host's /etc/resolv.conf. Set
# DEVVM_PROXY_DNS=ip:port to pin it to one resolver instead (the test rig does,
# to feed it names that resolve to private addresses).
if [ -n "${DEVVM_PROXY_DNS:-}" ]; then
  [[ "$DEVVM_PROXY_DNS" =~ ^[0-9.]+:[0-9]+$ ]] || { echo "DEVVM_PROXY_DNS must be ip:port" >&2; exit 1; }
  sed -i "s/^  parse-resolv-conf\$/  nameserver pinned $DEVVM_PROXY_DNS/" "$tmp/haproxy.cfg"
fi
install -o root -g root -m 0644 "$tmp/domains" "$ETC/allowed-domains.new"
sed "s#$ETC/allowed-domains#$ETC/allowed-domains.new#g" "$tmp/haproxy.cfg" > "$tmp/check.cfg"
haproxy -c -q -f "$tmp/check.cfg" \
  || { rm -f "$ETC/allowed-domains.new"; echo "FATAL: generated proxy config is invalid; keeping the existing one" >&2; exit 1; }
mv "$ETC/allowed-domains.new" "$ETC/allowed-domains"
install -o root -g root -m 0644 "$tmp/haproxy.cfg" "$ETC/haproxy.cfg"

# Upgrade from the Squid-based design: drop its drop-in so it releases the
# ports. Squid itself is no longer used by devvm and can be uninstalled.
if [ -e /etc/squid/conf.d/devvm.conf ]; then
  rm -f /etc/squid/conf.d/devvm.conf /etc/squid/devvm-allowed-domains /etc/squid/devvm-proxy.pem
  systemctl reload squid 2>/dev/null || systemctl restart squid 2>/dev/null || true
  echo "note: removed the old Squid drop-in; squid is no longer used by devvm (apt remove squid-openssl if nothing else needs it)"
fi

# 2) DNS is served by Incus's OWN dnsmasq (it owns :53 on the bridge and does
#    DHCP), made allowlist-only by the driver via the network's raw.dnsmasq
#    (no-resolv + one server=/<domain>/<upstream> per allowlisted host). NOTE:
#    server=/d/ forwards every subdomain of d — a slow DNS tunnel under an
#    allowlisted zone remains possible (documented, accepted).

# 3) nftables — ONE atomic transaction (add-before-delete; never leaves the
#    table gone / fails open). Policy accept so the host's other traffic is
#    untouched; only the VM subnet/interface is clamped. Applied BEFORE the
#    proxy is (re)started: with the rules in place and no proxy listening, the
#    guest gets "connection refused" — closed, never open.
nft -f - <<NFT
add table inet devvm
delete table inet devvm
table inet devvm {
  chain prerouting {
    type nat hook prerouting priority dstnat;
    # Every guest web connection goes to the proxy, whatever address it aimed
    # at. The proxy decides by NAME and picks the address itself.
    ip saddr $SUBNET tcp dport 80  dnat ip to $PROXY_IP:$PORT_HTTP
    ip saddr $SUBNET tcp dport 443 dnat ip to $PROXY_IP:$PORT_HTTPS
  }
  chain input {
    type filter hook input priority filter; policy accept;
    iifname != "$NET" accept
    ct state established,related accept
    # DNS + proxy are pinned to the bridge IP: the input hook sees traffic to ANY
    # host-local address, so an unpinned accept would also let the guest query a
    # resolver bound to another host address (e.g. the default incusbr0 dnsmasq,
    # which forwards every name — an unrestricted DNS path around gate 4). DNATed
    # proxy traffic already carries daddr $PROXY_IP by the time it reaches input.
    # DHCP stays unpinned (DISCOVER/REQUEST are broadcast).
    iifname "$NET" udp dport 67 accept
    iifname "$NET" ip daddr $PROXY_IP udp dport 53 accept
    iifname "$NET" ip daddr $PROXY_IP tcp dport { 53, $PORT_HTTP, $PORT_HTTPS } accept
    iifname "$NET" drop
  }
  chain forward {
    type filter hook forward priority filter; policy accept;
    ct state established,related accept
    oifname "$NET" ct state new drop          # no new inbound to guests (LAN/other ifaces)
    iifname "$NET" counter reject             # no direct guest egress at all
  }
}
NFT

# 4) (Re)start the dedicated proxy. reload-or-restart keeps established tunnels
#    alive when it is already running.
systemctl daemon-reload
systemctl enable devvm-proxy.service >/dev/null 2>&1 || true
systemctl reload-or-restart devvm-proxy.service \
  || { echo "FATAL: devvm-proxy failed to start (journalctl -u devvm-proxy). Guest egress is CLOSED until it runs." >&2; exit 1; }

echo "devvm host egress on $NET ($SUBNET): by-name proxy ($(wc -l < "$ETC/allowed-domains") hosts) + allowlist DNS + default-deny"
