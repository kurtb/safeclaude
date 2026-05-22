#!/bin/bash
# Container PID 1. Initializes the firewall (iptables state is per-runtime,
# so this runs every container start), then sleeps forever so the host
# `safeclaude` wrapper can `docker exec` into us for interactive shells.
set -euo pipefail

if [ -x /usr/local/bin/init-firewall.sh ]; then
    sudo /usr/local/bin/init-firewall.sh
else
    echo "WARNING: init-firewall.sh not found; container is running WITHOUT firewall."
fi

# Readiness flag for the host wrapper to poll.
touch /tmp/safeclaude-ready

exec sleep infinity
