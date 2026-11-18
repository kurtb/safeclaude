#!/usr/bin/env bash
# Exercise failure reporting deterministically. No root, Incus or network.
set -euo pipefail
doctor="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/guest-doctor.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

cat > "$fixture/su" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$fixture/getent" <<'SH'
#!/bin/sh
case "$2" in
  dns-failure.test) exit 2 ;;
  example.com) test "${DENIED_DNS_RESOLVES:-}" = yes ;;
  *) exit 0 ;;
esac
SH
cat > "$fixture/curl" <<'SH'
#!/usr/bin/env bash
case "${!#}" in
  https://example.com/) exit 6 ;;
  https://tls-failure.test/) exit 35 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$fixture"/{su,getent,curl}
export PATH="$fixture:$PATH"

bash "$doctor" reachable.test > "$fixture/output"
grep -Fq 'OK    HTTPS response from all 1 allowlisted domains' "$fixture/output"
if bash "$doctor" reachable.test dns-failure.test tls-failure.test > "$fixture/output" 2>&1; then
  echo 'missed failures on allowlisted names' >&2; exit 1
fi
grep -Fq 'FAIL  DNS: dns-failure.test' "$fixture/output"
grep -Fq 'FAIL  HTTPS: tls-failure.test (resolved, curl exit 35)' "$fixture/output"
if DENIED_DNS_RESOLVES=yes bash "$doctor" reachable.test > "$fixture/output" 2>&1; then
  echo 'missed an answer for a denied name' >&2; exit 1
fi
grep -Fq 'FAIL  denied name resolved or returned a response: example.com' "$fixture/output"
echo 'Guest doctor fixtures passed'
