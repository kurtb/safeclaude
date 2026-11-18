#!/usr/bin/env bash
# Install the host-side egress enforcement root-owned, so a user/agent that can
# write the checkout can NOT alter what runs as root.
# Run once as root (and again after pulling changes):  sudo ./install-host.sh
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST=/usr/local/lib/devvm

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
command -v haproxy >/dev/null \
  || { echo "haproxy is not installed. Install it first:  apt install haproxy" >&2; exit 1; }
# The proxy config uses do-resolve and address matching on variables.
hv="$(haproxy -v | sed -n '1s/^HAProxy version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
read -r hmaj hmin <<<"${hv:-0 0}"
# 2.8 (Ubuntu 24.04) is the oldest version this has been tested on.
{ [ "$hmaj" -gt 2 ] || { [ "$hmaj" -eq 2 ] && [ "$hmin" -ge 8 ]; }; } \
  || { echo "haproxy 2.8 or newer is required (found: $(haproxy -v | head -1))" >&2; exit 1; }

install -d -o root -g root -m 0755 "$DEST"
# Flatten the files host-egress.sh needs into one root-owned dir.
install -o root -g root -m 0755 "$SRC/lib/host-firewall.sh" "$DEST/host-firewall.sh"
install -o root -g root -m 0755 "$SRC/lib/host-egress.sh"   "$DEST/host-egress.sh"
install -o root -g root -m 0644 "$SRC/allowlist.conf"       "$DEST/allowlist.conf"
install -o root -g root -m 0644 "$SRC/proxy/haproxy.cfg"    "$DEST/haproxy.cfg"
install -o root -g root -m 0644 "$SRC/proxy/bogons.lst"     "$DEST/bogons.lst"
# Files from the Squid-based design, no longer used.
rm -f "$DEST/squid.conf" "$DEST/resolve-allowlist.sh"
# Upgrade from the Squid-based design: remove its drop-in so Squid releases the
# ports the new proxy binds. Squid itself is no longer used by devvm.
if [ -e /etc/squid/conf.d/devvm.conf ]; then
  rm -f /etc/squid/conf.d/devvm.conf /etc/squid/devvm-allowed-domains /etc/squid/devvm-proxy.pem
  if systemctl is-active --quiet squid; then
    systemctl restart squid \
      || echo "WARNING: squid did not restart cleanly; stop it (systemctl stop squid) before the next 'devvm up'" >&2
  fi
  echo "Removed the old Squid drop-in. squid is no longer used by devvm (apt remove squid-openssl if nothing else needs it)."
fi

# The dedicated proxy instance. host-egress.sh writes its config and starts it;
# it is not started here because the bridge it binds to may not exist yet.
unit=/etc/systemd/system/devvm-proxy.service
unit_changed=1; cmp -s "$SRC/proxy/devvm-proxy.service" "$unit" && unit_changed=0
install -o root -g root -m 0644 "$SRC/proxy/devvm-proxy.service" "$unit"
# The test rig builds a temporary network and never owns Incus boot ordering.
if [ ! -e "$DEST/.egress-rig" ]; then
  install -o root -g root -m 0644 "$SRC/proxy/devvm-firewall.service" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now devvm-firewall.service
fi
systemctl daemon-reload
# A running proxy keeps its old unit settings until restarted.
if [ "$unit_changed" = 1 ]; then systemctl try-restart devvm-proxy.service || true; fi

echo "Installed to $DEST (root-owned). The driver runs $DEST/host-egress.sh via sudo."
echo "Requires: haproxy + nftables. DNS is served by Incus's own dnsmasq (dnsmasq-base)"
echo "— do NOT install the full dnsmasq service. The distro's haproxy.service is not"
echo "used or modified: devvm runs its own instance, devvm-proxy.service."
echo "Apply now with:  devvm allow --refresh   (or the next 'devvm up')."
