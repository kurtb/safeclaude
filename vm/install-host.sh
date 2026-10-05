#!/usr/bin/env bash
# Install the host-side egress enforcement root-owned, so a user/agent that can
# write the checkout can NOT alter what runs as root.
# Run once as root:  sudo ./install-host.sh
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST=/usr/local/lib/devvm

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

install -d -o root -g root -m 0755 "$DEST"
# Flatten the files host-egress.sh needs into one root-owned dir.
install -o root -g root -m 0755 "$SRC/lib/host-egress.sh"        "$DEST/host-egress.sh"
install -o root -g root -m 0755 "$SRC/lib/resolve-allowlist.sh"  "$DEST/resolve-allowlist.sh"
install -o root -g root -m 0644 "$SRC/allowlist.conf"            "$DEST/allowlist.conf"
install -o root -g root -m 0644 "$SRC/proxy/squid.conf"          "$DEST/squid.conf"

# Squid splice cert (never presented to clients on a splice; required by the
# ssl-bump port). Generate once so the first `devvm up` doesn't fail on reload.
cert=/etc/squid/devvm-proxy.pem
if [ ! -s "$cert" ]; then
  install -d -m 0755 /etc/squid
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$cert" -out "$cert" -subj "/CN=devvm-proxy" >/dev/null 2>&1
  chmod 600 "$cert"
  echo "Generated Squid splice cert at $cert"
fi

echo "Installed to $DEST (root-owned). The driver runs $DEST/host-egress.sh via sudo."
echo "Requires: squid-openssl (stock squid lacks ssl-bump) + dnsmasq + openssl."
echo "For reboot persistence, enable a systemd unit that runs it before incus.service"
echo "(or set boot.autostart=false on instances — the driver already does)."
