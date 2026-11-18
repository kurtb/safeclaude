#!/usr/bin/env bash
# Build the release assets from the checked-out commit.
set -euo pipefail
dest=$(cd "${1:?usage: package-vm.sh OUTPUT_DIRECTORY}" && pwd)
repo=$(cd "$(dirname "$0")/.." && pwd)
git -C "$repo" archive --format=tar.gz --prefix=devvm/ -o "$dest/devvm.tar.gz" HEAD:vm
git -C "$repo" show HEAD:vm/install.sh > "$dest/install.sh"
chmod 0755 "$dest/install.sh"
(cd "$dest" && sha256sum devvm.tar.gz > devvm.tar.gz.sha256)
