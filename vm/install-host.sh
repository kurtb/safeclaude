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
# NOTE: key and cert MUST be written to separate files then concatenated — a
# single `-keyout X -out X` truncates X twice and leaves only one PEM block, so
# Squid FATALs the HTTPS port with "missing certificate". The guard also
# regenerates when the existing file has no valid certificate, so a previously
# broken pem self-heals on the next run instead of being kept.
cert=/etc/squid/devvm-proxy.pem
if [ ! -s "$cert" ] || ! openssl x509 -in "$cert" -noout >/dev/null 2>&1; then
  install -d -m 0755 /etc/squid
  k="$(mktemp)"; c="$(mktemp)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$k" -out "$c" -subj "/CN=devvm-proxy" >/dev/null 2>&1
  cat "$c" "$k" > "$cert"           # cert + key in one file (squid tls-cert= wants both)
  rm -f "$k" "$c"
  chmod 600 "$cert"
  echo "Generated Squid splice cert at $cert"
fi

echo "Installed to $DEST (root-owned). The driver runs $DEST/host-egress.sh via sudo."
echo "Requires: squid-openssl (stock squid lacks ssl-bump) + openssl. DNS is served by"
echo "Incus's own dnsmasq (dnsmasq-base) — do NOT install the full dnsmasq service."
echo "For reboot persistence, enable a systemd unit that runs it before incus.service"
echo "(or set boot.autostart=false on instances — the driver already does)."
