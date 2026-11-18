#!/usr/bin/env bash
# Called only from run.sh's private mounts with empty /run.
set -euo pipefail
vm=$1
bin=$2
[[ -f /run/test-rules && -f /run/test-systemctl ]] || exit 2
cli="$vm/devvm.sh"
cat > "$bin/incus" <<'INCUS'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> /run/incus-calls
case "$1" in
  network)
    case "$2" in
      show) test -e "/run/$3" ;;
      create)
        touch "/run/$3"
        if [[ $3 == dvmp-* ]]; then
          echo "$3" > /run/net
          for option in "${@:4}"; do
            if [[ $option == user.devvm.owner=* ]]; then echo "${option#*=}" > /run/owner; fi
          done
        fi ;;
      set) : ;;
      get) cat /run/owner ;;
      delete) rm "/run/$3" ;;
      *) exit 2 ;;
    esac ;;
  info) test -e /run/name && { cat /run/state; } ;;
  init) echo "$3" > /run/name; echo 'Status: STOPPED' > /run/state ;;
  config) [[ $2 == device && $3 == get && $5 == eth0 && $6 == network ]] && cat /run/net ;;
  start) echo 'Status: RUNNING' > /run/state ;;
  stop) echo 'Status: STOPPED' > /run/state ;;
  delete) rm /run/state ;;
  exec) [[ $* != *'id -u dev'* ]] ;;
  *) exit 2 ;;
esac
INCUS
cat > /usr/local/lib/devvm/host-egress.sh <<'EGRESS'
#!/bin/sh
echo 'apply installed egress' >> /run/incus-calls
test ! -f /run/fail-apply
EGRESS
cd /run
touch fail-apply
if "$cli" up --name driver; then echo "up ignored failed enforcement"; exit 1; fi
if grep -q '^start ' incus-calls; then exit 1; fi
grep -E '^network create dvmp-.*ipv4.nat=false ipv4.firewall=false ipv6.address=none dns.mode=none' incus-calls
grep -E '^init images:ubuntu/24.04/cloud .* --vm .*boot.autostart=false --network dvmp-' incus-calls
grep -Fx 'server=/installed-only.test/1.1.1.1' incus-calls
rm fail-apply
: > incus-calls
"$cli" up --name driver
name=$(cat name)
awk '/^apply installed egress$/{apply=NR} /^start /{start=NR} END{exit !(apply && start>apply)}' incus-calls
"$cli" shell --name driver
"$cli" stop --name driver
"$cli" rm --name driver
grep -Fx "stop $name" incus-calls
grep -Fx "delete -f $name" incus-calls
[[ ! -f $(cat net) ]]
