#!/usr/bin/env bash
# Resolve the shared allowlist (allowlist.conf) + dynamic sources into a
# deduped, SSRF-filtered list of CIDRs, one per line, on stdout.
#
# Used for the IP-level egress ACL (defense in depth). Domain-level egress is
# enforced by the SNI proxy from allowlist.conf directly, so CDN rotation is
# handled there, not here.
#
# SECURITY: every resolved address is passed through drop_bogons() first, so a
# repointed/poisoned allowlisted domain (or one carrying an internal record)
# can NEVER produce an allow rule for loopback, RFC1918, link-local/metadata
# (169.254.0.0/16, incl. 169.254.169.254), CGNAT (100.64/10), or multicast/
# reserved space — the SSRF-into-host/cloud path the review flagged.
#
# `sort -u` dedupes (overlaps). IPv6 is emitted separately from IPv4 so a v4-only
# consumer can filter by ':' without crashing.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${1:-$HERE/../allowlist.conf}"

# Drop private / loopback / link-local+metadata / CGNAT / multicast / reserved,
# for both families. Matches the address at line start, so the /NN suffix and
# /24-widened entries are covered too.
drop_bogons() {
  grep -ivE \
    -e '^(0|10|127)\.' \
    -e '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.' \
    -e '^169\.254\.' \
    -e '^172\.(1[6-9]|2[0-9]|3[01])\.' \
    -e '^192\.168\.' \
    -e '^192\.0\.0\.' \
    -e '^198\.(1[89])\.' \
    -e '^(22[4-9]|2[3-5][0-9])\.' \
    -e '^(::1|::)(/|$)' \
    -e '^::ffff:' \
    -e '^f[cd]' \
    -e '^fe[89ab]' \
    -e '^ff'
}

collect() {
  # GitHub published ranges (IPv4 + IPv6). Cache the response and reuse the last
  # good copy on failure — unauthenticated api.github.com/meta is 60 req/hr/IP
  # and this runs on every `devvm up`.
  local gh cache="${DEVVM_CACHE_DIR:-/run/devvm}/github-meta.json"
  mkdir -p "$(dirname "$cache")" 2>/dev/null || cache="${TMPDIR:-/tmp}/devvm-github-meta.json"
  if gh="$(curl -fsS https://api.github.com/meta)" && echo "$gh" | jq -e '.web and .api and .git and .pages' >/dev/null 2>&1; then
    printf '%s' "$gh" > "$cache" 2>/dev/null || true
  else
    gh="$(cat "$cache" 2>/dev/null || true)"
    [ -n "$gh" ] && echo "WARNING: github meta fetch failed; using cached copy" >&2
  fi
  echo "$gh" | jq -e '.web and .api and .git and .pages' >/dev/null 2>&1 \
    || { echo "github meta unavailable (no fetch, no cache)" >&2; exit 1; }
  echo "$gh" | jq -r '(.web + .api + .git + .pages)[]'

  # Tailscale DERP relay IPs (best-effort).
  local derp
  derp="$(curl -fsS https://login.tailscale.com/derpmap/default || true)"
  if echo "$derp" | jq -e '.Regions' >/dev/null 2>&1; then
    echo "$derp" | jq -r '.Regions[].Nodes[] | (.IPv4 // empty), (.IPv6 // empty)' \
      | sed -E 's#^([0-9.]+)$#\1/32#; s#^([0-9a-fA-F:]+)$#\1/128#'
  else
    echo "WARNING: Tailscale DERP map fetch failed; relay IPs omitted" >&2
  fi

  # allowlist.conf: resolve each host. 'cidr:' widens IPv4 to /24.
  local line host widen ip
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    [ -z "$line" ] && continue
    widen=0; host="$line"
    [[ "$line" == cidr:* ]] && { widen=1; host="${line#cidr:}"; }
    while IFS= read -r ip; do
      [ -n "$ip" ] || continue
      if [ "$widen" = 1 ]; then echo "${ip%.*}.0/24"; else echo "$ip/32"; fi
    done < <(dig +short A "$host" | grep -E '^[0-9.]+$' || true)
    while IFS= read -r ip; do
      [ -n "$ip" ] || continue
      echo "$ip/128"
    done < <(dig +short AAAA "$host" | grep -E '^[0-9a-fA-F:]+$' || true)
  done < "$CONF"
}

# `|| true` so an all-filtered (grep exit 1) or empty result doesn't abort under
# pipefail; an empty allowlist is a valid (fully-closed) outcome.
collect | { drop_bogons || true; } | sort -u
