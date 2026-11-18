#!/usr/bin/env bash
# Boundary tests for the devvm egress stack, run against the local rig
# (egress-rig.sh). Each test is a thing a guest must — or must not — be able to
# do. Exits non-zero if any fails.
#
#   sudo vm/test/egress-test.sh           # brings the rig up, tests, leaves it up
#   sudo vm/test/egress-test.sh --down    # ...and tears it down afterwards
#
# Needs real network access to a few allowlisted hosts (pypi.org,
# registry.npmjs.org, api.github.com, archive.ubuntu.com).
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RIG="$HERE/egress-rig.sh"
PROXY_IP="${RIG_PROXY_IP:-10.99.0.1}"

"$RIG" up >/dev/null || { echo "rig failed to come up" >&2; exit 1; }
g() { "$RIG" run "$@"; }                     # run as the guest
code() { g curl -sS -o /dev/null --max-time 12 -w '%{http_code}' "$@" 2>/dev/null; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s   (%s)\n' "$1" "$2"; }
# expect <description> <wanted http code, or "blocked"> <curl args...>
expect() {
  local desc="$1" want="$2" got; shift 2
  got="$(code "$@")"; got="${got:-000}"
  if [ "$want" = blocked ]; then
    if [ "$got" = 000 ]; then ok "$desc"; else bad "$desc" "expected no connection, got HTTP $got"; fi
  elif [ "$got" = "$want" ]; then ok "$desc"
  else bad "$desc" "expected HTTP $want, got $got"; fi
}

echo "Allowed names work"
expect "HTTPS to an allowlisted host"                  200 https://pypi.org/simple/pip/
expect "HTTP to an allowlisted host (apt mirror)"      200 http://archive.ubuntu.com/ubuntu/dists/noble/Release

echo "The guest's choice of IP never matters (rotation-proof, and no --resolve bypass)"
expect "allowed name aimed at a different IP of the same CDN"  200 --resolve pypi.org:443:151.101.1.63 https://pypi.org/simple/pip/
expect "allowed name aimed at an unrelated IP (1.2.3.4)"       200 --resolve pypi.org:443:1.2.3.4 https://pypi.org/simple/pip/
expect "allowed name aimed at the metadata IP"                 200 --resolve pypi.org:443:169.254.169.254 https://pypi.org/simple/pip/
expect "allowed HTTP name aimed at an unrelated IP"            200 --resolve archive.ubuntu.com:80:1.2.3.4 http://archive.ubuntu.com/ubuntu/dists/noble/Release
n=0; for _ in 1 2 3 4 5 6 7 8 9 10; do
  ip="$((RANDOM%200+11)).$((RANDOM%250)).$((RANDOM%250)).7"
  [ "$(code --resolve registry.npmjs.org:443:"$ip" https://registry.npmjs.org/)" = 200 ] && n=$((n+1))
done
if [ "$n" = 10 ]; then ok "10 connections to one name, each aimed at a random IP"; else bad "10 connections aimed at random IPs" "$n/10 succeeded"; fi

echo "Names that are not allowlisted are blocked"
expect "DNS does not resolve a non-allowlisted name"           blocked https://example.com/
expect "non-allowlisted SNI aimed at an allowed host's IP"     blocked --resolve example.com:443:151.101.64.223 https://example.com/
expect "TLS with no SNI"                                       blocked -k https://151.101.64.223/
expect "plain HTTP sent to port 443"                           blocked http://151.101.64.223:443/
expect "HTTP with a non-allowlisted Host"                      403 -H 'Host: example.com' http://archive.ubuntu.com/
expect "using the HTTP port as a CONNECT proxy"                blocked -p -x http://archive.ubuntu.com:80 https://example.com/

echo "An allowlisted name cannot be used to reach private addresses (SSRF)"
# A canary web server on the HOST's loopback. If the proxy ever connected to a
# name's private address, the canary would be hit.
canary="$(mktemp -d)"; echo canary > "$canary/index.html"
( cd "$canary" && exec python3 -m http.server 80 --bind 127.0.0.1 >"$canary/log" 2>&1 ) & cpid=$!
sleep 1
expect "HTTP name resolving to loopback"                       403 --resolve ssrf-loopback.test:80:1.2.3.4 http://ssrf-loopback.test/
expect "HTTP name resolving to the bridge IP"                  403 --resolve ssrf-bridge.test:80:1.2.3.4 http://ssrf-bridge.test/
expect "HTTP name resolving to the metadata IP"                403 --resolve ssrf-metadata.test:80:1.2.3.4 http://ssrf-metadata.test/
expect "HTTPS name resolving to loopback"                      blocked --resolve ssrf-loopback.test:443:1.2.3.4 https://ssrf-loopback.test/
expect "HTTPS name resolving to the metadata IP"               blocked --resolve ssrf-metadata.test:443:1.2.3.4 https://ssrf-metadata.test/
kill "$cpid" 2>/dev/null
if grep -q '"GET' "$canary/log" 2>/dev/null; then bad "canary on host loopback was never contacted" "it received a request"; else ok "canary on host loopback was never contacted"; fi
rm -rf "$canary"

echo "Nothing but web traffic leaves, and the host is not reachable"
tcp() { g timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
if tcp 140.82.112.3 22;   then bad "SSH (port 22) to the internet" "connected"; else ok "SSH (port 22) to the internet is blocked"; fi
if tcp 151.101.64.223 8443; then bad "port 8443 to the internet" "connected"; else ok "other ports to the internet are blocked"; fi
if tcp "$PROXY_IP" 22;    then bad "host SSH via the bridge IP" "connected"; else ok "host services on the bridge IP are blocked"; fi
if g timeout 4 bash -c "exec 3<>/dev/udp/1.1.1.1/53; printf 'x' >&3; read -t 2 -n1 <&3" 2>/dev/null; then bad "direct DNS to 1.1.1.1" "got a reply"; else ok "direct DNS to an outside resolver is blocked"; fi

echo "Fails closed"
systemctl stop devvm-proxy.service
expect "with the proxy stopped, an allowed host is unreachable" blocked https://pypi.org/simple/pip/
systemctl start devvm-proxy.service; sleep 1
expect "and reachable again once it is back"                    200 https://pypi.org/simple/pip/

echo
echo "$pass passed, $fail failed"
[ "${1:-}" != --down ] || "$RIG" down
[ "$fail" = 0 ]
