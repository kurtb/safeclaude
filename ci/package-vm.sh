#!/usr/bin/env bash
# Build the two release assets from the checked-out commit.
set -euo pipefail
dest=$(cd "${1:?usage: package-vm.sh OUTPUT_DIRECTORY}" && pwd)
repo=$(cd "$(dirname "$0")/.." && pwd)
git -C "$repo" archive --format=tar.gz --prefix=devvm/ -o "$dest/devvm.tar.gz" HEAD:vm
(cd "$dest" && sha256sum devvm.tar.gz > devvm.tar.gz.sha256)
