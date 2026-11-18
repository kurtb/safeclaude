#!/usr/bin/env bash
# Run against two running project VMs on a configured Incus host.
# Each guest needs the stock Ubuntu cloud image's python3, ip and curl.
set -euo pipefail
[[ $# == 2 ]] || { echo "usage: $0 PROJECT_VM_A PROJECT_VM_B" >&2; exit 2; }
a=$1 b=$2
bridge_a=$(incus config device get "$a" eth0 network)
bridge_b=$(incus config device get "$b" eth0 network)
[[ $bridge_a =~ ^dvmp-[0-9a-f]{8}$ && $bridge_b =~ ^dvmp-[0-9a-f]{8}$ && $bridge_a != "$bridge_b" ]] ||
  { echo "expected two distinct project bridges" >&2; exit 1; }

for vm in "$a" "$b"; do
  incus exec "$vm" -- curl -4fsS --max-time 20 -o /dev/null https://github.com/robots.txt
done

check_isolation() {
  local server=$1 client=$2 addr port listener_pid result
  addr=$(incus exec "$server" -- ip -j -4 route show default | jq -er '.[0].prefsrc')
  # A single-connection TCP echo server on an unused port. A host connection
  # after the guest probe confirms the test actually hit a working service.
  coproc LISTENER { incus exec "$server" --mode non-interactive -- python3 -uc '
import socket, sys
with socket.socket() as sock:
    sock.bind((sys.argv[1], 0))
    sock.listen()
    sock.settimeout(20)
    print(sock.getsockname()[1], flush=True)
    conn, _ = sock.accept()
    with conn:
        conn.sendall(b"devvm\n")
' "$addr"; }
  listener_pid=$!
  read -r port <&"${LISTENER[0]}"
  incus exec "$client" -- python3 -c '
import errno, socket, sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=3).close()
except OSError as exc:
    if isinstance(exc, TimeoutError) or exc.errno in (errno.ECONNREFUSED, errno.EHOSTUNREACH, errno.ENETUNREACH):
        sys.exit(0)
    raise
sys.exit("cross-project connection succeeded")
' "$addr" "$port"
  result=$(python3 -c '
import socket, sys
with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=3) as sock:
    print(sock.makefile().readline().strip())
' "$addr" "$port")
  wait "$listener_pid"
  [[ $result == devvm ]]
}

check_isolation "$a" "$b"
check_isolation "$b" "$a"
echo "Both VMs reached GitHub and denied connections to the other VM's test service."
