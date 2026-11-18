#!/usr/bin/env bash
# Local test rig for the devvm egress stack — NO Incus, NO KVM needed.
#
# Stands up what the Linux driver gives a guest, on any Linux box (including
# inside a devvm guest, or a CI runner):
#   - a bridge with the proxy IP on it            (Incus: the devvm bridge)
#   - a network namespace on that bridge          (Incus: the guest VM)
#   - an allowlist-only dnsmasq on the bridge IP  (Incus: its own dnsmasq + raw.dnsmasq)
#   - the REAL install-host.sh + lib/host-egress.sh + proxy/haproxy.cfg
#
# So everything egress-related is the production code path; only the Incus
# plumbing (network create, raw.dnsmasq) is replaced.
#
#   sudo vm/test/egress-rig.sh up        # build it (re-run to re-apply after edits)
#   sudo vm/test/egress-rig.sh run CMD   # run CMD as the "guest"
#   sudo vm/test/egress-rig.sh down      # remove everything it made
#
# Uses its own names/subnet so it can't collide with a real devvm bridge.
# Needs: haproxy nftables dnsmasq-base iproute2 curl (and systemd, for the
# devvm-proxy unit). It installs the egress files to /usr/local/lib/devvm and
# /etc/devvm like a real host, so it REFUSES to run on a machine that already
# has a devvm install it didn't make (it would overwrite and then remove it).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0 $*" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; VM="$(dirname "$HERE")"

export DEVVM_NET="${RIG_NET:-devvmrig0}"
export DEVVM_SUBNET="${RIG_SUBNET:-10.99.0.0/24}"
export DEVVM_PROXY_IP="${RIG_PROXY_IP:-10.99.0.1}"
GUEST_IP="${RIG_GUEST_IP:-10.99.0.2}"
RIG_V6="${RIG_V6:-fd00:99::1}"
RIG_HOSTPUB="${RIG_HOSTPUB:-192.0.9.1}"
NS=devvmrig
RUN=/run/devvm-rig
MARK=/usr/local/lib/devvm/.egress-rig     # "this install belongs to the rig"
# Where the rig's dnsmasq forwards allowlisted names. Production uses 1.1.1.1;
# inside a devvm guest only the outer resolver is reachable, so default to
# whatever this machine resolves through.
UPSTREAM="${RIG_DNS_UPSTREAM:-$(awk '/^nameserver/{print $2; exit}' /run/systemd/resolve/resolv.conf 2>/dev/null || true)}"
UPSTREAM="${UPSTREAM:-1.1.1.1}"

# True when this machine has a devvm install that the rig did not create.
real_install() {
  [ ! -e "$MARK" ] && { [ -e /usr/local/lib/devvm ] || [ -e /etc/devvm ] \
    || [ -e /etc/systemd/system/devvm-proxy.service ] \
    || nft list table inet devvm >/dev/null 2>&1; }
}

down() {
  if real_install; then
    echo "refusing: this machine has a devvm install the rig did not create; not touching it" >&2
    exit 1
  fi
  if [ -f "$RUN/dnsmasq.pid" ]; then kill "$(cat "$RUN/dnsmasq.pid")" 2>/dev/null || true; fi
  if [ -f "$RUN/proxydns.pid" ]; then kill "$(cat "$RUN/proxydns.pid")" 2>/dev/null || true; fi
  if [ -e "$RUN/made-local" ]; then rm -f /etc/devvm/allowlist.local; fi
  systemctl disable --now devvm-proxy.service >/dev/null 2>&1 || true
  ip netns del "$NS" 2>/dev/null || true
  ip link del "$DEVVM_NET" 2>/dev/null || true
  nft delete table inet devvm 2>/dev/null || true
  rm -f /etc/systemd/system/devvm-proxy.service /etc/devvm/haproxy.cfg /etc/devvm/allowed-domains /etc/devvm/bogons
  rm -rf "$RUN" "/etc/netns/$NS" /usr/local/lib/devvm /run/devvm-proxy-applied
  rmdir /etc/devvm 2>/dev/null || true      # kept if it holds allowlist.local
  systemctl daemon-reload
}

up() {
  if real_install; then
    echo "refusing: this machine already has a devvm install (/usr/local/lib/devvm, /etc/devvm," >&2
    echo "devvm-proxy.service or the 'inet devvm' nft table). The rig would replace it." >&2
    exit 1
  fi
  install -d -o root -g root -m 0755 /usr/local/lib/devvm; touch "$MARK"
  mkdir -p "$RUN" "/etc/netns/$NS"
  # Bridge + "guest" namespace.
  if ! ip link show "$DEVVM_NET" >/dev/null 2>&1; then
    ip link add "$DEVVM_NET" type bridge
    ip addr add "$DEVVM_PROXY_IP/24" dev "$DEVVM_NET"
    ip link set "$DEVVM_NET" up
    # A private IPv6 address on the host, for the "name with only an IPv6
    # answer" test (see ssrf-v6.test below).
    ip -6 addr add "$RIG_V6/64" dev "$DEVVM_NET" nodad
    # A PUBLIC-range address held by the host, for the "name resolving to the
    # host's own public address" test. Local to this bridge; never routed.
    ip addr add "$RIG_HOSTPUB/32" dev "$DEVVM_NET"
  fi
  if ! ip netns list | grep -qw "$NS"; then
    ip netns add "$NS"
    ip link add rigveth0 type veth peer name rigveth1
    ip link set rigveth0 master "$DEVVM_NET" up
    ip link set rigveth1 netns "$NS"
    ip -n "$NS" addr add "$GUEST_IP/24" dev rigveth1
    ip -n "$NS" link set rigveth1 up
    ip -n "$NS" link set lo up
    ip -n "$NS" route add default via "$DEVVM_PROXY_IP"
  fi
  echo "nameserver $DEVVM_PROXY_IP" > "/etc/netns/$NS/resolv.conf"

  # Install the egress files root-owned, exactly as on a real host.
  "$VM/install-host.sh" >/dev/null

  # Allowlist-only DNS: the same lines the Incus driver puts in raw.dnsmasq.
  if [ -f "$RUN/dnsmasq.pid" ]; then kill "$(cat "$RUN/dnsmasq.pid")" 2>/dev/null || true; fi
  {
    echo "no-resolv"
    { cat /usr/local/lib/devvm/allowlist.conf; echo
      if [ -r /etc/devvm/allowlist.local ]; then cat /etc/devvm/allowlist.local; fi; } \
      | grep -vE '^[[:space:]]*#|^[[:space:]]*$' | sed 's/^cidr://' | LC_ALL=C sort -u \
      | while IFS= read -r d; do echo "server=/$d/$UPSTREAM"; done
  } > "$RUN/dnsmasq.conf"
  dnsmasq --conf-file="$RUN/dnsmasq.conf" --pid-file="$RUN/dnsmasq.pid" \
    --interface="$DEVVM_NET" --bind-interfaces --except-interface=lo \
    --listen-address="$DEVVM_PROXY_IP" --no-hosts --no-dhcp-interface="$DEVVM_NET"

  # The proxy's resolver: a second dnsmasq that forwards everything upstream
  # but answers five test names with addresses the proxy must REFUSE to
  # connect to. They are put on the allowlist (below) so that the only thing
  # standing between the guest and those addresses is the proxy's bogon check.
  if [ -f "$RUN/proxydns.pid" ]; then kill "$(cat "$RUN/proxydns.pid")" 2>/dev/null || true; fi
  dnsmasq --pid-file="$RUN/proxydns.pid" --no-resolv --no-hosts --server="$UPSTREAM" \
    --listen-address=127.0.0.1 --port=5399 --bind-interfaces --cache-size=0 \
    --address=/ssrf-loopback.test/127.0.0.1 \
    --address=/ssrf-bridge.test/"$DEVVM_PROXY_IP" \
    --address=/ssrf-metadata.test/169.254.169.254 \
    --address=/ssrf-v6.test/"$RIG_V6" \
    --address=/ssrf-hostpub.test/"$RIG_HOSTPUB"
  install -d -o root -g root -m 0755 /etc/devvm
  if [ ! -e /etc/devvm/allowlist.local ]; then touch "$RUN/made-local"; fi
  if [ -e "$RUN/made-local" ]; then
    printf '%s\n' ssrf-loopback.test ssrf-bridge.test ssrf-metadata.test ssrf-v6.test ssrf-hostpub.test > /etc/devvm/allowlist.local
    chmod 0644 /etc/devvm/allowlist.local
  fi

  DEVVM_PROXY_DNS=127.0.0.1:5399 /usr/local/lib/devvm/host-egress.sh
  echo "rig up: guest $GUEST_IP on $DEVVM_NET, DNS upstream $UPSTREAM"
}

case "${1:-}" in
  up)   up ;;
  down) down ;;
  run)  shift; exec ip netns exec "$NS" "$@" ;;
  *) echo "usage: $0 up | down | run CMD..." >&2; exit 1 ;;
esac
