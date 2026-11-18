#!/usr/bin/env bash
# Called inside run.sh's isolated root mount and network namespaces.
set -euo pipefail
installer=$(cd "$(dirname "$0")/.." && pwd)/install.sh
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
export fixture
cd "$fixture"
mkdir bin devvm
cat >bin/curl <<'CURL'
#!/bin/bash
set -eu
url=${!#}
base=https://github.com/kurtb/safeclaude/releases
if [[ $url == "$base/latest" ]]; then
  cat "$fixture/latest"
  exit 0
fi
while [[ $1 != --output ]]; do shift; done
[[ $url == "$base/download/"* ]] || exit 1
cp "$fixture/${url#"$base/download/"}" "$2"
CURL
chmod +x bin/curl
export PATH="$fixture/bin:$PATH"
base=https://github.com/kurtb/safeclaude/releases
for version in v1.0.0 v1.1.0; do
  mkdir "$version"
  printf '#!/bin/sh\necho %s >> "$fixture/installed"\n' "$version" >devvm/install-host.sh
  chmod +x devvm/install-host.sh
  tar -czf "$version/devvm.tar.gz" devvm
  (cd "$version" && sha256sum devvm.tar.gz >devvm.tar.gz.sha256)
  echo "$base/tag/$version" >latest
  "$installer"
done
# The same saved installer applies the newest bundle and supports reinstallation.
"$installer"
printf '%s\n' v1.0.0 v1.1.0 v1.1.0 >expected
cmp expected installed

expect_failure() {
  if "$installer"; then echo "Unexpectedly installed: $1" >&2; exit 1; fi
  cmp expected installed
}
echo bad >>v1.1.0/devvm.tar.gz
expect_failure 'corrupt archive'
rm v1.1.0/devvm.tar.gz.sha256
expect_failure 'missing checksum'
echo "$base/tag/v1.1.0-rc.1" >latest
expect_failure 'unexpected latest tag'
