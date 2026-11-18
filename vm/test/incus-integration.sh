#!/usr/bin/env bash
# Exercise the installed CLI on a disposable, initialized Incus host.
# Container mode pre-creates a stopped instance on the driver's legacy bridge.
# This exercises normal migration and start without a container switch in devvm.
set -euo pipefail
mode=${1:?usage: incus-integration.sh vm|container}
case "$mode" in vm) test -c /dev/kvm ;; container) ;; *) exit 2 ;; esac
root=$(cd "$(dirname "$0")/../.." && pwd)
project=$(mktemp -d)
cd "$project"
git init -q
git remote add origin https://github.com/kurtb/safeclaude.git
# Use the same project identity as the installed command.
name=$(source /usr/local/lib/devvm/devvm.sh && _devvm_name "")
net=dvmp-${name##*-}
if incus info "$name" &>/dev/null || incus network show "$net" &>/dev/null; then
  echo "Test project already exists" >&2; exit 1
fi
cleanup() {
  if [[ $? != 0 ]]; then incus info "$name" --show-log >&2 || true; fi
  devvm rm
  rm -rf "$project"
}
trap cleanup EXIT
export DEVVM_MEMORY=3GiB DEVVM_CPUS=2 DEVVM_DISK=10GiB
if [[ $mode == container ]]; then
  devvm allow --refresh
  incus init images:ubuntu/24.04/cloud "$name" --network devvmbr0 -c boot.autostart=false
fi
devvm up </dev/null
case "$mode" in
  vm) type=virtual-machine ;;
  container) type=container ;;
esac
incus list --format json | jq -e --arg n "$name" --arg t "$type" 'any(.[]; .name==$n and .type==$t and .status=="Running")'
[[ $(incus config device get "$name" eth0 network) == "$net" ]]
[[ $(incus network get "$net" ipv4.nat) == false ]]
incus exec "$name" -T -- bash -se <<'GUEST'
curl -fsSL --retry 3 --max-time 30 https://github.com/robots.txt >/dev/null
curl -fsSL --max-time 30 --resolve github.com:443:192.0.2.1 https://github.com/robots.txt >/dev/null
if getent ahostsv4 example.com; then echo "off-list DNS answered" >&2; exit 1; fi
if timeout 5 bash -c 'exec 3<>/dev/tcp/github.com/22'; then echo "SSH egress allowed" >&2; exit 1; fi
GUEST
if [[ $mode == vm ]]; then
  devvm upgrade
  incus exec "$name" -- su - dev -c 'claude --version && docker --version'
  devvm up </dev/null
  incus exec "$name" -- test -d /home/dev/workspace/safeclaude/.git
  if [[ ${DEVVM_TEST_GUEST_TOOLS:-0} == 1 ]]; then
    "$root/vm/test/guest-tools-live.sh" "$name"
  fi
fi
devvm stop
devvm rm
if incus info "$name" &>/dev/null || incus network show "$net" &>/dev/null; then
  echo "Project resources survived removal" >&2; exit 1
fi
trap - EXIT
rm -rf "$project"
