#!/usr/bin/env bash
# Container entrypoint for safeclaude.
#
# Initializes the egress firewall (allowlist-only) before handing control to
# the user shell. Requires NET_ADMIN and NET_RAW capabilities on the container.
# Without them, iptables calls fail and the container exits — which is the
# desired behavior, since running without the firewall defeats the whole point.

set -euo pipefail

if [[ "${SAFECLAUDE_SKIP_FIREWALL:-0}" == "1" ]]; then
    echo "safeclaude: SAFECLAUDE_SKIP_FIREWALL=1 — egress firewall NOT initialized" >&2
else
    sudo /usr/local/bin/init-firewall.sh
fi

if [[ $# -eq 0 ]]; then
    exec /usr/bin/zsh
else
    exec "$@"
fi
