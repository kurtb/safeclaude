#!/usr/bin/env bash
# Standalone release asset. A saved copy always installs GitHub's latest release.
set -euo pipefail
[[ $# == 0 ]] || { echo "usage: sudo bash $0" >&2; exit 2; }
(( EUID == 0 )) || { echo "run on the Linux host: sudo bash $0" >&2; exit 1; }

# Serialize latest resolution and installation, including concurrent upgrades.
exec 9>/run/devvm-release-install.lock
flock --exclusive 9
work=$(mktemp -d /tmp/devvm-release.XXXXXXXXXX)
trap 'rm -rf -- "$work"' EXIT
cd "$work"

releases=https://github.com/kurtb/safeclaude/releases
fetch=(curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https'
       --connect-timeout 15 --max-time 180 --retry 3)
resolved=$("${fetch[@]}" --head --output /dev/null --write-out '%{url_effective}' "$releases/latest")
tag=${resolved#"$releases/tag/"}
if [[ $resolved != "$releases/tag/$tag" || ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Could not resolve the latest stable SafeClaude release: $resolved" >&2
  exit 1
fi
echo "Installing SafeClaude $tag on the host"
for asset in devvm.tar.gz devvm.tar.gz.sha256; do
  "${fetch[@]}" --output "$asset" "$releases/download/$tag/$asset"
done
# Match the exact single-file manifest written by ci/package-vm.sh.
if ! sha256sum devvm.tar.gz | cmp -s - devvm.tar.gz.sha256; then
  echo "SafeClaude $tag archive checksum verification failed" >&2
  exit 1
fi
tar -xzf devvm.tar.gz --no-same-owner
./devvm/install-host.sh 9>&-
echo "Installed SafeClaude $tag on the host"
