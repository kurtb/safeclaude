#!/usr/bin/env bash
# Called inside run.sh's isolated root mount and network namespaces.
set -euo pipefail
installer=$(cd "$(dirname "$0")/.." && pwd)/install.sh
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
export fixture
cd "$fixture"
mkdir bin devvm
ln -s "$(dirname "$installer")/test/release-curl.sh" bin/curl
export PATH="$fixture/bin:$PATH"
base=https://github.com/kurtb/safeclaude/releases
for version in v1.0.0 v1.1.0; do
  mkdir "$version"
  printf '#!/bin/sh\necho %s >> "%s/installed"\n' "$version" "$fixture" >devvm/install-host.sh
  chmod +x devvm/install-host.sh
  tar -czf "$version/devvm.tar.gz" devvm
  (cd "$version" && sha256sum devvm.tar.gz >devvm.tar.gz.sha256)
  echo "$base/tag/$version" >latest
  "$installer"
done
# The same saved installer applies the newest bundle and supports reinstallation.
bash < "$installer"
printf '%s\n' v1.0.0 v1.1.0 v1.1.0 >expected
cmp expected installed
# A truncated download cannot reach the entry point. An older concurrent
# download cannot replace a newer successful install.
sed '$d' "$installer" | bash
cmp expected installed

expect_failure() {
  if "$installer"; then echo "Unexpectedly installed: $1" >&2; exit 1; fi
  cmp expected installed
}
echo "$base/tag/v1.0.0" >latest
expect_failure 'stale release'
echo "$base/tag/v1.1.0" >latest
echo bad >>v1.1.0/devvm.tar.gz
expect_failure 'corrupt archive'
rm v1.1.0/devvm.tar.gz.sha256
expect_failure 'missing checksum'
echo "$base/tag/v1.1.0-rc.1" >latest
expect_failure 'unexpected latest tag'
