#!/usr/bin/env bash
# Release asset. Keep the only entry point at EOF so an incomplete pipe cannot start an install.

apply_archive() (
  set -euo pipefail
  local tag=$1 digest=$2 previous stage
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  # Concurrent callers may finish downloading out of order. Remember the newest
  # successful install under the lock for this boot.
  exec 9<>/run/devvm-release-install.lock
  flock --exclusive 9
  if read -r previous <&9 && dpkg --compare-versions "${previous#v}" gt "${tag#v}"; then
    echo "A newer release ($previous) was installed. Rerun the installer." >&2
    exit 1
  fi

  stage=$(mktemp -d /var/lib/devvm-install.XXXXXXXXXX)
  trap 'rm -rf -- "$stage"' EXIT
  cd "$stage"
  # stdin is the archive already opened by the caller. Recheck the private copy
  # before running any root code from it. Never execute from a user-writable tree.
  cat > devvm.tar.gz
  printf '%s  devvm.tar.gz\n' "$digest" | sha256sum --check --status
  tar -xzf devvm.tar.gz --no-same-owner
  ./devvm/install-host.sh 9>&- </dev/null
  printf '%s\n' "$tag" > /run/devvm-release-install.lock
)

main() (
  set -euo pipefail
  [[ $# == 0 ]] || { echo "usage: bash install.sh" >&2; exit 2; }
  local work resolved tag asset manifest
  work=$(mktemp -d /tmp/devvm-release.XXXXXXXXXX)
  trap 'rm -rf -- "$work"' EXIT
  cd "$work"

  local releases=https://github.com/kurtb/safeclaude/releases
  local -a fetch=(curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https'
                  --connect-timeout 15 --max-time 180 --retry 3)
  resolved=$("${fetch[@]}" --head --output /dev/null --write-out '%{url_effective}' "$releases/latest")
  tag=${resolved#"$releases/tag/"}
  if [[ $resolved != "$releases/tag/$tag" || ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Could not resolve the latest stable SafeClaude release: $resolved" >&2
    exit 1
  fi
  for asset in devvm.tar.gz devvm.tar.gz.sha256; do
    "${fetch[@]}" --output "$asset" "$releases/download/$tag/$asset"
  done
  manifest=$(sha256sum devvm.tar.gz)
  if ! printf '%s\n' "$manifest" | cmp -s - devvm.tar.gz.sha256; then
    echo "SafeClaude $tag archive checksum verification failed" >&2
    exit 1
  fi

  echo "Verified the $tag archive checksum. Installing host packages, devvm and systemd firewall services."
  echo "The host installer configures the signed Zabbly stable APT source for Incus if needed."
  if (( EUID == 0 )); then
    apply_archive "$tag" "${manifest%% *}"
  else
    # Send only this fixed function as code. Tag and digest are positional
    # arguments, and sudo obtains any password from the controlling terminal.
    sudo -- /bin/bash -c "$(declare -f apply_archive)"$'\napply_archive "$@"' \
      devvm-install "$tag" "${manifest%% *}"
  fi < devvm.tar.gz
  echo "Installed SafeClaude $tag on the host"
)
main "$@"
