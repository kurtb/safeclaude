#!/usr/bin/env bash
# Resolve the shared allowlist (allowlist.conf) + dynamic sources into a
# deduped list of CIDRs, one per line, on stdout. Platform-neutral: each driver
# expresses these in its own firewall syntax (Incus ACL / nftables set / pf
# table).
#
# Emits BOTH IPv4 and IPv6. A driver that handles only one family filters by
# ':' (e.g. the nftables path keeps IPv4 with `grep -v ':'`). `sort -u` dedupes
# (review finding #7: overlapping/duplicate entries). IPv6 is kept separate from
# any IPv4-only set so it can't crash it (review finding #6).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${1:-$HERE/../allowlist.conf}"

collect() {
  # GitHub published ranges (IPv4 + IPv6).
  local gh
  gh="$(curl -fsS https://api.github.com/meta)" || { echo "github meta fetch failed" >&2; exit 1; }
  echo "$gh" | jq -e '.web and .api and .git and .pages' >/dev/null \
    || { echo "github meta missing fields" >&2; exit 1; }
  echo "$gh" | jq -r '(.web + .api + .git + .pages)[]'

  # Tailscale DERP relay IPs (best-effort).
  local derp
  derp="$(curl -fsS https://login.tailscale.com/derpmap/default || true)"
  if echo "$derp" | jq -e '.Regions' >/dev/null 2>&1; then
    echo "$derp" | jq -r '.Regions[].Nodes[] | (.IPv4 // empty), (.IPv6 // empty)' \
      | sed -E 's#^([0-9.]+)$#\1/32#; s#^([0-9a-fA-F:]+)$#\1/128#'
  fi

  # allowlist.conf: resolve each host. 'cidr:' widens IPv4 to /24.
  local line host widen ip
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    [ -z "$line" ] && continue
    widen=0; host="$line"
    [[ "$line" == cidr:* ]] && { widen=1; host="${line#cidr:}"; }
    for ip in $(dig +short A "$host" | grep -E '^[0-9.]+$' || true); do
      if [ "$widen" = 1 ]; then echo "${ip%.*}.0/24"; else echo "$ip/32"; fi
    done
    for ip in $(dig +short AAAA "$host" | grep -E '^[0-9a-fA-F:]+$' || true); do
      echo "$ip/128"
    done
  done < "$CONF"
}

collect | sort -u
