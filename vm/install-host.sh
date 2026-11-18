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

install -d -o root -g root -m 0755 "$DEST"
# Flatten the files host-egress.sh needs into one root-owned dir.
install -o root -g root -m 0755 "$SRC/lib/host-egress.sh"   "$DEST/host-egress.sh"
install -o root -g root -m 0644 "$SRC/allowlist.conf"       "$DEST/allowlist.conf"
install -o root -g root -m 0644 "$SRC/proxy/haproxy.cfg"    "$DEST/haproxy.cfg"
# Files from the Squid-based design, no longer used.
rm -f "$DEST/squid.conf" "$DEST/resolve-allowlist.sh"

# The dedicated proxy instance. host-egress.sh writes its config and starts it;
# it is not started here because the bridge it binds to may not exist yet.
install -o root -g root -m 0644 "$SRC/proxy/devvm-proxy.service" /etc/systemd/system/devvm-proxy.service
systemctl daemon-reload

echo "Installed to $DEST (root-owned). The driver runs $DEST/host-egress.sh via sudo."
echo "Requires: haproxy + nftables. DNS is served by Incus's own dnsmasq (dnsmasq-base)"
echo "— do NOT install the full dnsmasq service. The distro's haproxy.service is not"
echo "used or modified: devvm runs its own instance, devvm-proxy.service."
echo "Apply now with:  devvm allow --refresh   (or the next 'devvm up')."
