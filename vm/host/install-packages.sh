#!/usr/bin/env bash
# Install the current stable Incus from its signed APT channel.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. /etc/os-release
arch=$(dpkg --print-architecture)
case "$ID:${VERSION_CODENAME:-}:$arch" in
  ubuntu:noble:amd64|ubuntu:noble:arm64|ubuntu:resolute:amd64|ubuntu:resolute:arm64|debian:trixie:amd64|debian:trixie:arm64) ;;
  *) echo "Automatic package setup supports Ubuntu 24.04/26.04 and Debian 13 on amd64/arm64. For a manually provisioned host use --skip-packages." >&2; exit 1 ;;
esac
export DEBIAN_FRONTEND=noninteractive
apt_update() { apt-get -o APT::Update::Error-Mode=any update; }
apt_install() { apt-get --no-remove install -y "$@"; }
apt_update
apt_install ca-certificates curl gpg python3-apt

# Reuse a configured stable repository (including a site-specific Signed-By
# path). Otherwise configure the publisher's repository with a scoped key.
indexes=$(apt-get indextargets --format '$(URI)')
if ! grep -q '^https://pkgs\.zabbly\.com/incus/stable/' <<<"$indexes"; then
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  key=/etc/apt/keyrings/zabbly-incus-stable.asc
  source_file=/etc/apt/sources.list.d/zabbly-incus-stable.sources
  curl --proto '=https' --proto-redir '=https' -fsSL https://pkgs.zabbly.com/key.asc -o "$work/key.asc"
  fingerprints=$(gpg --batch --homedir "$work" --with-colons --show-keys "$work/key.asc" |
    awk -F: '$1=="pub"{primary=1} $1=="fpr" && primary{print $10; primary=0}')
  [[ $fingerprints == 4EFC590696CB15B87C73A3AD82CC8797C838DCFD ]] || {
    echo "Unexpected Zabbly signing key" >&2; exit 1;
  }
  cat >"$work/repo" <<REPO
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $VERSION_CODENAME
Components: main
Architectures: $arch
Signed-By: $key
REPO
  if [[ -e $source_file ]] && ! cmp -s "$work/repo" "$source_file"; then
    echo "Check existing APT source $source_file before retrying" >&2; exit 1
  fi
  install -d -m 0755 /etc/apt/keyrings
  install -m 0644 "$work/key.asc" "$key"
  install -m 0644 "$work/repo" "$source_file"
  apt_update
fi
/usr/bin/python3 -IB "$here/check-packages.py" --candidates
packages=(incus incus-client haproxy nftables dnsmasq-base jq bind9-dnsutils)
command -v git >/dev/null || packages+=(git)
apt_install "${packages[@]}"
