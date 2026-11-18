#!/usr/bin/env bash
# Boundary tests for the devvm egress stack, run against the local rig
# (egress-rig.sh). Each test is a thing a guest must — or must not — be able to
# do. Exits non-zero if any fails.
#
#   sudo vm/test/egress-test.sh           # brings the rig up, tests, leaves it up
#   sudo vm/test/egress-test.sh --down    # ...and tears it down afterwards
#
# Needs real network access to a few allowlisted hosts (pypi.org,
# registry.npmjs.org, api.github.com, archive.ubuntu.com), plus dig and python3,
# and port 80 free on this machine's loopback.
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RIG="$HERE/egress-rig.sh"
PROXY_IP="${RIG_PROXY_IP:-10.99.0.1}"
V6="${RIG_V6:-fd00:99::1}"

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
# Raw requests: curl folds repeated Host headers into one, so it can't send these.
raw() { g python3 -c 'import socket,sys
s=socket.create_connection(("1.2.3.4",80),timeout=8); s.sendall(sys.argv[1].encode()); print(s.recv(64).split()[1].decode())' "$1" 2>/dev/null; }
expect_raw() { local got; got="$(raw "$3")"; if [ "${got:-000}" = "$2" ]; then ok "$1"; else bad "$1" "expected HTTP $2, got ${got:-000}"; fi; }
expect_raw "two Host headers, allowed then not"                400 $'GET / HTTP/1.1\r\nHost: archive.ubuntu.com\r\nHost: example.com\r\nConnection: close\r\n\r\n'
expect_raw "two Host headers, not allowed then allowed"        400 $'GET / HTTP/1.1\r\nHost: example.com\r\nHost: archive.ubuntu.com\r\nConnection: close\r\n\r\n'
expect_raw "request line naming a different host than Host"    400 $'GET http://example.com/ HTTP/1.1\r\nHost: archive.ubuntu.com\r\nConnection: close\r\n\r\n'
expect_raw "no Host header"                                    400 $'GET / HTTP/1.1\r\nConnection: close\r\n\r\n'
expect "using the HTTP port as a CONNECT proxy"                blocked -p -x http://archive.ubuntu.com:80 https://example.com/

echo "An allowlisted name cannot be used to reach private addresses (SSRF)"
# A canary web server on the HOST's loopback. If the proxy ever connected to a
# name's private address, the canary would be hit.
canary="$(mktemp -d)"; echo canary > "$canary/index.html"
( cd "$canary" && exec python3 -m http.server 80 --bind 127.0.0.1 >"$canary/log" 2>&1 ) & cpid=$!
( cd "$canary" && exec python3 -m http.server 80 --bind "$V6" >"$canary/log6" 2>&1 ) & cpid6=$!
sleep 1
if kill -0 "$cpid" 2>/dev/null && kill -0 "$cpid6" 2>/dev/null; then ok "canary web servers started on host loopback (IPv4 and a private IPv6)"
else bad "canary web servers started" "port 80 on host loopback is in use; the canary check below proves nothing"; fi
expect "HTTP name resolving to loopback"                       403 --resolve ssrf-loopback.test:80:1.2.3.4 http://ssrf-loopback.test/
expect "HTTP name resolving to the bridge IP"                  403 --resolve ssrf-bridge.test:80:1.2.3.4 http://ssrf-bridge.test/
expect "HTTP name resolving to the metadata IP"                403 --resolve ssrf-metadata.test:80:1.2.3.4 http://ssrf-metadata.test/
expect "HTTPS name resolving to loopback"                      blocked --resolve ssrf-loopback.test:443:1.2.3.4 https://ssrf-loopback.test/
expect "HTTPS name resolving to the metadata IP"               blocked --resolve ssrf-metadata.test:443:1.2.3.4 https://ssrf-metadata.test/
expect "HTTP name with only a (private) IPv6 address"         403 --resolve ssrf-v6.test:80:1.2.3.4 http://ssrf-v6.test/
expect "HTTPS name with only a (private) IPv6 address"        blocked --resolve ssrf-v6.test:443:1.2.3.4 https://ssrf-v6.test/
kill "$cpid" "$cpid6" 2>/dev/null
if grep -q '"GET' "$canary/log" "$canary/log6" 2>/dev/null; then bad "canary on host loopback was never contacted" "it received a request"; else ok "canary on host loopback was never contacted"; fi
rm -rf "$canary"

echo "Nothing but web traffic leaves, and the host is not reachable"
tcp() { g timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
if tcp 140.82.112.3 22;   then bad "SSH (port 22) to the internet" "connected"; else ok "SSH (port 22) to the internet is blocked"; fi
if tcp 151.101.64.223 8443; then bad "port 8443 to the internet" "connected"; else ok "other ports to the internet are blocked"; fi
if tcp "$PROXY_IP" 22;    then bad "host SSH via the bridge IP" "connected"; else ok "host services on the bridge IP are blocked"; fi
# A real query both times: the first shows the guest's dig works at all, so
# the second failing means the path is blocked, not that the probe is broken.
if [ -n "$(g dig +short +tries=1 +time=3 @"$PROXY_IP" pypi.org A 2>/dev/null)" ]; then ok "DNS through the allowlist resolver answers"; else bad "DNS through the allowlist resolver" "no answer"; fi
if g dig +tries=1 +time=3 @1.1.1.1 pypi.org A >/dev/null 2>&1; then bad "direct DNS to 1.1.1.1" "got a reply"; else ok "direct DNS (UDP) to an outside resolver is blocked"; fi
if g dig +tcp +tries=1 +time=3 @1.1.1.1 pypi.org A >/dev/null 2>&1; then bad "direct DNS over TCP to 1.1.1.1" "got a reply"; else ok "direct DNS (TCP) to an outside resolver is blocked"; fi

echo "Allowlist changes reach the running proxy"
# The rig's apply, as `devvm allow` would run it.
apply() { DEVVM_NET="${RIG_NET:-devvmrig0}" DEVVM_SUBNET="${RIG_SUBNET:-10.99.0.0/24}" DEVVM_PROXY_IP="$PROXY_IP" \
  DEVVM_PROXY_DNS=127.0.0.1:5399 /usr/local/lib/devvm/host-egress.sh >/dev/null 2>&1; }
started() { systemctl show -p ActiveEnterTimestampMonotonic --value devvm-proxy.service; }
# hpid: a guest connection that stays open (TLS handshake done, then idle).
t0="$(started)"; apply
if [ "$(started)" = "$t0" ]; then ok "re-applying an unchanged list leaves the proxy alone"; else bad "unchanged re-apply" "proxy was restarted"; fi
g timeout 60 openssl s_client -connect 1.2.3.4:443 -servername pypi.org -quiet < <(sleep 55) >/dev/null 2>&1 & hpid=$!
sleep 3
echo example.org >> /etc/devvm/allowlist.local; apply; sleep 1
if [ "$(started)" = "$t0" ] && kill -0 "$hpid" 2>/dev/null; then ok "adding a host reloads; an open connection survives"; else bad "adding a host" "proxy restarted or the open connection died"; fi
sed -i '/^example\.org$/d' /etc/devvm/allowlist.local; apply; sleep 2
if [ "$(started)" != "$t0" ]; then ok "removing a host restarts the proxy"; else bad "removing a host" "proxy was not restarted"; fi
if kill -0 "$hpid" 2>/dev/null; then bad "removing a host cuts open connections" "the connection is still open"; kill "$hpid" 2>/dev/null; else ok "removing a host cuts open connections"; fi
expect "the proxy works after the restart"                     200 https://pypi.org/simple/pip/
# An apply that dies after publishing the files but before the proxy picks
# them up (here: a bad subnet makes nft fail) must not lose the change.
echo example.org >> /etc/devvm/allowlist.local; apply
sed -i '/^example\.org$/d' /etc/devvm/allowlist.local
t1="$(started)"
if DEVVM_NET="${RIG_NET:-devvmrig0}" DEVVM_SUBNET=not-a-subnet DEVVM_PROXY_IP="$PROXY_IP" DEVVM_PROXY_DNS=127.0.0.1:5399 \
     /usr/local/lib/devvm/host-egress.sh >/dev/null 2>&1; then bad "apply with a broken firewall step" "it reported success"; fi
apply; sleep 1
if [ "$(started)" != "$t1" ]; then ok "a removal interrupted by a failed apply still restarts the proxy on retry"; else bad "removal after a failed apply" "proxy still runs the old list"; fi
expect "and the removed host is refused by the proxy"          blocked --resolve example.org:443:1.2.3.4 https://example.org/
if DEVVM_NET=x DEVVM_PROXY_DNS=127.0.0.1:5399 bash -c 'rm -f /usr/local/lib/devvm/.egress-rig; /usr/local/lib/devvm/host-egress.sh' >/dev/null 2>&1; then bad "DEVVM_PROXY_DNS outside the rig" "accepted"; else ok "DEVVM_PROXY_DNS is refused outside the rig"; fi
touch /usr/local/lib/devvm/.egress-rig

echo "Fails closed"
systemctl stop devvm-proxy.service
expect "with the proxy stopped, an allowed host is unreachable" blocked https://pypi.org/simple/pip/
systemctl start devvm-proxy.service; sleep 1
expect "and reachable again once it is back"                    200 https://pypi.org/simple/pip/

echo
echo "$pass passed, $fail failed"
[ "${1:-}" != --down ] || "$RIG" down
[ "$fail" = 0 ]
