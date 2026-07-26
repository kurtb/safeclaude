#!/usr/bin/env bash
# tailscale-up — connect the sandbox to your tailnet in userspace mode.
#
# Runs tailscaled in userspace-networking mode as the ubuntu user — no root, no
# TUN device, no new sudo — so it keeps the container's privilege boundary
# intact. Instead of a transparent interface it exposes a SOCKS5 + HTTP proxy on
# localhost:1055; point tools at that to reach tailnet hosts, e.g.:
#
#   ALL_PROXY=socks5://localhost:1055 curl http://my-tailnet-host/
#   HTTPS_PROXY=http://localhost:1055 gh api ...
#
# State (auth) lives in ~/.tailscale, which is on the persistent volume, so you
# normally connect once. Set TS_AUTHKEY to connect non-interactively; otherwise
# `tailscale up` prints a login URL to open in your browser. Extra args are
# passed through to `tailscale up` (e.g. --hostname, --ssh, --accept-routes).
#
# For the CLI afterward, ~/.zshrc aliases `tailscale` to use this socket.
set -uo pipefail

TS_DIR="$HOME/.tailscale"
SOCK="$TS_DIR/tailscaled.sock"
PROXY_PORT=1055
mkdir -p "$TS_DIR"

# Start the userspace daemon if it isn't already answering on our socket.
if ! tailscale --socket="$SOCK" status >/dev/null 2>&1; then
    echo "tailscale-up: starting tailscaled (userspace networking)..."
    nohup tailscaled \
        --tun=userspace-networking \
        --socks5-server="localhost:${PROXY_PORT}" \
        --outbound-http-proxy-listen="localhost:${PROXY_PORT}" \
        --socket="$SOCK" \
        --statedir="$TS_DIR" \
        >"$TS_DIR/tailscaled.log" 2>&1 &

    # Wait (bounded) for the control socket to appear.
    for _ in $(seq 1 40); do
        [ -S "$SOCK" ] && break
        sleep 0.25
    done
    if [ ! -S "$SOCK" ]; then
        echo "tailscale-up: tailscaled did not come up — see $TS_DIR/tailscaled.log" >&2
        exit 1
    fi
fi

if [ -n "${TS_AUTHKEY:-}" ]; then
    tailscale --socket="$SOCK" up --authkey="$TS_AUTHKEY" "$@"
else
    tailscale --socket="$SOCK" up "$@"
fi

echo "tailscale-up: connected. SOCKS5 + HTTP proxy on localhost:${PROXY_PORT}"
echo "  e.g.  ALL_PROXY=socks5://localhost:${PROXY_PORT} curl http://<tailnet-host>/"
