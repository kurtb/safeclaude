#!/usr/bin/env bash
# Exercise the release archive on a disposable GitHub-hosted Ubuntu runner.
set -euo pipefail
ci=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${RUNNER_TEMP:?}/devvm-XXXXXX")
trap 'rm -rf "$work"' EXIT
"$ci/package-vm.sh" "$work"
cd "$work"
sha256sum -c devvm.tar.gz.sha256
tar -xzf devvm.tar.gz

# python-apt needs a URI with a site to check the package origin.
mirror=http://azure.archive.ubuntu.com/ubuntu/
if [[ $(dpkg --print-architecture) == arm64 ]]; then mirror=http://ports.ubuntu.com/ubuntu-ports/; fi
sudo sed -i "s|mirror+file:/etc/apt/apt-mirrors.txt|$mirror|g" /etc/apt/sources.list.d/ubuntu.sources
# The runner grants write access to local tool dirs. The installer requires
# root-owned parent paths for its privileged runtime.
sudo chown root:root /usr/local /usr/local/lib /usr/local/bin
sudo chmod go-w /usr/local /usr/local/lib /usr/local/bin
sudo ./devvm/install-host.sh
sudo ./devvm/install-host.sh --check
