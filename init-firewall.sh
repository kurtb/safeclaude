#!/bin/bash
# Adapted from anthropics/claude-code/.devcontainer/init-firewall.sh
# Extended allowlist for multi-agent use (Claude, Codex, Gemini) plus
# the tools baked into the safeclaude image (gcloud, Pulumi, PyPI, etc.).
#
# Runs at container start via entrypoint.sh as root (via sudoers exception).
# Sets iptables to DROP-by-default OUTPUT, then ACCEPTs an ipset allowlist.
#
# The allowlist ipset is populated two ways: provider IP ranges (GitHub/Tailscale)
# added directly, and domain names resolved LIVE by a local dnsmasq that inserts
# each answer IP into the set as names are looked up — so CDN/registry hosts that
# rotate IPs (e.g. *.jfrog.io) can't outrun a boot-time snapshot.
set -euo pipefail
IFS=$'\n\t'

# dnsmasq upstream: capture the pre-existing resolver (Docker's embedded DNS at
# 127.0.0.11) BEFORE we point resolv.conf at our own dnsmasq below — excluding
# 127.0.0.1 so a re-run doesn't make dnsmasq forward to itself. Kill any prior
# dnsmasq so the ipset it holds can be destroyed/recreated.
UPSTREAM_NS=$(grep -E '^[[:space:]]*nameserver' /etc/resolv.conf 2>/dev/null \
    | awk '{print $2}' | grep -v '^127\.0\.0\.1$' || true)
[ -n "$UPSTREAM_NS" ] || UPSTREAM_NS="127.0.0.11"
pkill -x dnsmasq 2>/dev/null || true

# 1. Preserve Docker DNS NAT rules so name resolution inside the container
#    still works after we flush.
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# Baseline: DNS, SSH, loopback.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT   # dnsmasq→upstream can fall back to TCP
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT  -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

ipset create allowed-domains hash:net

# GitHub's published IP ranges (web, api, git, pages). `.pages` covers GitHub
# Pages (*.github.io and Pages custom domains) — needed for e.g. project docs
# hosted there. Note: Pages sites share one IP pool and the firewall matches by
# IP, so allowlisting Pages is inherently all-or-nothing across *.github.io.
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi
if ! echo "$gh_ranges" | jq -e '.web and .api and .git and .pages' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    ipset add allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git + .pages)[]' | aggregate -q)

# Tailscale DERP relay servers (best-effort). In this locked-down egress
# environment, direct peer connections (UDP to arbitrary peer IPs) are blocked,
# so Tailscale traffic relays through DERP over TCP 443 — allowlist those server
# IPs from the published DERP map. A failure here only limits Tailscale relaying.
echo "Fetching Tailscale DERP server IPs..."
derp_map=$(curl -s https://login.tailscale.com/derpmap/default || true)
if echo "$derp_map" | jq -e '.Regions' >/dev/null 2>&1; then
    while read -r ip; do
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            ipset add allowed-domains "$ip" 2>/dev/null || true
        fi
    done < <(echo "$derp_map" | jq -r '.Regions[].Nodes[].IPv4 // empty')
else
    echo "WARNING: could not fetch Tailscale DERP map (relay connectivity may be limited)"
fi

# Domain allowlist. Resolved LIVE by dnsmasq (see below): each name here becomes
# an ipset= rule, so lookups keep the firewall's allowed-domains set current even
# as these hosts rotate IPs — no container restart needed.
ALLOWED_DOMAINS=(
    # Anthropic / Claude Code (api + native installer auto-update)
    "api.anthropic.com"
    "downloads.claude.ai"
    "claude.ai"
    "statsig.anthropic.com"
    "statsig.com"
    "sentry.io"

    # OpenAI / Codex CLI
    "api.openai.com"
    "chatgpt.com"
    "auth.openai.com"

    # Google / Gemini CLI + gcloud
    "generativelanguage.googleapis.com"
    "cloudcode-pa.googleapis.com"
    "oauth2.googleapis.com"
    "accounts.google.com"
    "dl.google.com"
    "packages.cloud.google.com"

    # Cursor CLI (install + auto-update)
    "cursor.com"
    "api2.cursor.sh"
    "download.cursor.sh"

    # Langfuse (LLM observability — docs + both cloud regions; self-hosters add
    # their own host)
    "langfuse.com"
    "cloud.langfuse.com"
    "us.cloud.langfuse.com"

    # Package registries
    "registry.npmjs.org"
    "pypi.org"
    "files.pythonhosted.org"

    # Bun (self-update / version check; installs come from npm + GitHub)
    "bun.sh"

    # GitHub auxiliary (CDN + raw + downloads not covered by api.github.com/meta)
    "objects.githubusercontent.com"
    "codeload.github.com"
    "raw.githubusercontent.com"

    # Pulumi
    "get.pulumi.com"
    "api.pulumi.com"

    # Ubuntu / apt
    "archive.ubuntu.com"
    "security.ubuntu.com"
    "ports.ubuntu.com"

    # GitHub web + project pages
    "github.com"
    "bitnami-labs.github.io"

    # Tailscale (apt mirror + coordination/login; DERP relay IPs fetched above)
    "pkgs.tailscale.com"
    "controlplane.tailscale.com"
    "login.tailscale.com"

    # Kubernetes + Helm
    "dl.k8s.io"
    "cdn.dl.k8s.io"
    "registry.k8s.io"
    "get.helm.sh"

    # Istio (release binaries + Helm charts, hosted on GCS)
    "istio-release.storage.googleapis.com"

    # Container registries
    "ghcr.io"
    "quay.io"
    "docker.io"
)

# Extra allowlist baked into the image at build time (see the SAFECLAUDE_ALLOW
# build-arg in the Dockerfile), one domain per line; '#' comments and blank
# lines ignored. The file is root-owned and part of the image — not a volume or
# mount — so a YOLO agent running as ubuntu can't edit it to widen its own
# egress. The path is HARD-CODED (no env override) so the agent also can't
# redirect it via `SOMEVAR=… sudo init-firewall.sh`.
EXTRA_ALLOW_FILE="/etc/safeclaude/allowed-domains"
if [ -f "$EXTRA_ALLOW_FILE" ]; then
    echo "Reading extra allowlist from $EXTRA_ALLOW_FILE..."
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"                 # strip comments
        line="${line//[[:space:]]/}"       # remove all whitespace
        [ -n "$line" ] && ALLOWED_DOMAINS+=("$line")
    done < "$EXTRA_ALLOW_FILE"
fi

# ── dnsmasq: live ipset population ────────────────────────────────────────
# Point the container's resolver at a local dnsmasq that adds every resolved IP
# for an allowlisted (sub)domain into the 'allowed-domains' ipset. Because the
# set is populated at *lookup* time, a CDN/registry host that rotates its IP
# mid-session (*.jfrog.io, Azure Front Door, cloud blob stores) is allowed as
# soon as the client resolves it — no stale boot snapshot, no /24 widening.
# dnsmasq matches by domain suffix, so 'jfrog.io' also covers '*.jfrog.io'
# (incl. blob/download subdomains under the same zone); a blob host on a
# DIFFERENT zone still needs its own allowlist entry. Runs as root to retain
# CAP_NET_ADMIN for the ipset add. The config is derived from the SAME list
# above, so dnsmasq and the firewall can never disagree on what's allowed.
mkdir -p /etc/safeclaude
DNSMASQ_CONF=/etc/safeclaude/dnsmasq.conf
{
    echo "# generated by init-firewall.sh at container start — do not edit"
    echo "listen-address=127.0.0.1"
    echo "bind-interfaces"
    echo "no-resolv"      # use only the server= lines below; never read resolv.conf (no self-loop)
    echo "no-hosts"
    for ns in $UPSTREAM_NS; do echo "server=$ns"; done
    for domain in "${ALLOWED_DOMAINS[@]}"; do echo "ipset=/$domain/allowed-domains"; done
} > "$DNSMASQ_CONF"

echo "Starting dnsmasq (upstream: $UPSTREAM_NS) ..."
dnsmasq --conf-file="$DNSMASQ_CONF" --user=root --pid-file=/run/safeclaude-dnsmasq.pid \
    || { echo "FATAL: dnsmasq failed to start; refusing to continue without live DNS allowlisting" >&2; exit 1; }

# Wait for dnsmasq to answer, then take over resolv.conf so the AGENT's lookups
# flow through it (that's what keeps the ipset fresh as IPs rotate).
for _ in $(seq 1 20); do
    dig @127.0.0.1 +time=1 +tries=1 +short github.com >/dev/null 2>&1 && break
    sleep 0.3
done
printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf 2>/dev/null \
    || echo "WARNING: could not rewrite /etc/resolv.conf; agent lookups may bypass dnsmasq" >&2

# Warm up: resolve each domain THROUGH dnsmasq now (@127.0.0.1) so the ipset is
# seeded before the first real connection and never races the first lookup.
# dnsmasq is the source of truth; the explicit ipset add is a floor in case a
# warmup resolution is partial.
for domain in "${ALLOWED_DOMAINS[@]}"; do
    ips=$(dig @127.0.0.1 +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
    if [ -z "$ips" ]; then
        echo "WARNING: warmup resolve failed for $domain (dnsmasq will populate on first use)"
        continue
    fi
    while read -r ip; do
        ipset add allowed-domains "$ip" 2>/dev/null || true
    done < <(echo "$ips")
done

# (The old CDN /24-widening hack for get.helm.sh is gone: dnsmasq live-population
# above tracks the exact rotating IPs, so widening to a whole /24 is unnecessary.)

# Allow host network so docker-internal traffic still works.
HOST_IP=$(ip route | grep default | awk '{print $3}' | head -n1)
if [ -n "$HOST_IP" ]; then
    HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
    echo "Host network detected as: $HOST_NETWORK"
    iptables -A INPUT  -s "$HOST_NETWORK" -j ACCEPT
    iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT
fi

# Default-deny.
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Established connections + allowlist.
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"

# Smoke test: must NOT reach an unlisted host, MUST reach GitHub.
if curl --connect-timeout 5 -s https://example.com >/dev/null 2>&1; then
    echo "ERROR: firewall verification failed - reached https://example.com"
    exit 1
fi
if ! curl --connect-timeout 5 -s https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: firewall verification failed - cannot reach https://api.github.com"
    exit 1
fi
echo "Firewall verified."
