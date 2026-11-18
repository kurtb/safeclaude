#!/bin/bash
# Offline GitHub release fixture for the bootstrap tests. The real host install
# gets the system PATH, so APT and package setup still use the real network.
set -eu
url=${!#}
base=https://github.com/kurtb/safeclaude/releases
if [[ $url == "$base/latest" ]]; then
  cat "${fixture:?}/latest"
  exit 0
fi
while [[ $1 != --output ]]; do shift; done
[[ $url == "$base/download/"* ]] || exit 1
cp "${fixture:?}/${url#"$base/download/"}" "$2"
