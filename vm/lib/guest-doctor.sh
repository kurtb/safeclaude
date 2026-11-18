#!/usr/bin/env bash
# Run via incus exec with the verified list of exact host names as arguments.
# Never load a curlrc, follow redirects, log in, or send guest credentials.
set -uo pipefail
failed=0
if ! su - dev -s /bin/bash -c '
  missing=0
  for tool in git gh curl jq docker claude; do
    command -v "$tool" >/dev/null || { echo "FAIL  missing guest tool: $tool" >&2; missing=1; }
  done
  exit "$missing"
'; then
  echo 'FAIL  base guest setup for dev (run devvm upgrade)' >&2
  failed=1
else
  echo 'OK    base guest tools for dev'
fi

for tool in getent timeout curl xargs; do
  command -v "$tool" >/dev/null || { echo "FAIL  guest check needs $tool" >&2; exit 1; }
done

# Use a real, normally resolvable public name outside this machine's list.
# An ordinary DNS query and HTTPS request suffice; no spoofed traffic.
denied=""
for candidate in example.com example.org example.net iana.org; do
  if ! printf '%s\n' "$@" | grep -Fx "$candidate" >/dev/null; then denied="$candidate"; break; fi
done
if [ -z "$denied" ]; then
  echo 'FAIL  every denied-test domain is explicitly allowed; cannot verify denial' >&2
  failed=1
elif timeout 8 getent ahostsv4 "$denied" >/dev/null ||
     curl -q --ipv4 --noproxy '*' -sI --max-time 8 --output /dev/null "https://$denied/"; then
  echo "FAIL  denied name resolved or returned a response: $denied" >&2
  failed=1
else
  echo "OK    denied name blocked: $denied"
fi

probe_domain() {
  local domain="$1" rc
  if ! timeout 8 getent ahostsv4 "$domain" >/dev/null; then
    echo "FAIL  DNS: $domain (no IPv4 answer)" >&2
    return 1
  fi
  # HTTP status codes, including 401, 403 and 405, prove reachability. A
  # connection, certificate or timeout error is separate from lookup failure.
  curl -q --ipv4 --noproxy '*' -sI --max-time 12 --output /dev/null "https://$domain/" && return 0
  rc=$?
  echo "FAIL  HTTPS: $domain (resolved, curl exit $rc)" >&2
  return 1
}
export -f probe_domain
if printf '%s\0' "$@" | xargs -0 -r -n1 -P8 bash -c 'probe_domain "$1"' _; then
  echo "OK    HTTPS response from all $# allowlisted domains"
else
  failed=1
fi
exit "$failed"
