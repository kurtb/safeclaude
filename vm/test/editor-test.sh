#!/usr/bin/env bash
# Live test of the driver extension against a DISPOSABLE running, egress-clamped
# VM with the dev account. Run as the Incus user: editor-test.sh <devvm-name>.
set -euo pipefail
name="${1:?usage: editor-test.sh devvm-DISPOSABLE-VM}"; [[ "$name" =~ ^devvm-[a-z0-9-]+$ ]]
vmdir="$(cd "$(dirname "$0")/.." && pwd)"
editor() { "$vmdir/drivers/incus-editor.sh" "$1" "$name" "$vmdir" "${@:2}"; }
tmp="$(mktemp -d)"; guest=""
cleanup() {
  if [[ "$guest" =~ ^/tmp/devvm-editor\.[a-zA-Z0-9]+$ ]]; then incus exec "$name" -- rm -rf -- "$guest"; fi
  rm -rf -- "$tmp"
}
trap cleanup EXIT
ssh_vm() { ssh -F "$tmp/config" -o BatchMode=yes "$@" "$name"; }
must_fail() { if "$@"; then echo 'unexpected success' >&2; exit 1; fi; }

editor ssh-config > "$tmp/config"
editor ssh-config | cmp - "$tmp/config"
ssh -F "$tmp/config" -o BatchMode=yes "$name" \
  'test "$(id -un)" = dev && test -z "${SSH_AUTH_SOCK:-}" && cd ~/workspace'
[[ -z "$(incus exec "$name" -- ss -H -ltn 'sport = :22')" ]]
ssh-keygen -q -t ed25519 -N '' -f "$tmp/unrelated"
printf '%s %s\n' "$name" "$(cat "$tmp/unrelated.pub")" > "$tmp/wrong-pin"
must_fail ssh_vm -o "UserKnownHostsFile=$tmp/wrong-pin" -T -n
must_fail ssh_vm -o ExitOnForwardFailure=yes -R 0:127.0.0.1:22 -T -n
incus exec "$name" -- /usr/sbin/sshd -T -f /etc/ssh/devvm_sshd_config -C user=dev |
  grep -Fx 'allowstreamlocalforwarding no' >/dev/null
echo 'PASS: SSH as dev, no agent or TCP/22 listener, wrong pin, reverse and socket forwards refused'

guest="$(incus exec "$name" -- su -s /bin/sh dev -c 'mktemp -d /tmp/devvm-editor.XXXXXXXX')"
[[ "$guest" =~ ^/tmp/devvm-editor\.[a-zA-Z0-9]+$ ]]
printf 'one-off\0payload\377\n' > "$tmp/input"
editor cp push "$tmp/input" "$guest/has space"
editor cp pull "$guest/has space" "$tmp/output"
cmp "$tmp/input" "$tmp/output"
[ "$(stat -c '%a' "$tmp/output")" = 600 ]
[ "$(incus exec "$name" -- stat -c '%a %U' "$guest/has space")" = '600 dev' ]
must_fail editor cp pull "$guest/has space" "$tmp/output"
must_fail editor cp push "$tmp/input" "$guest/has space"
incus exec "$name" -- ln -s 'has space' "$guest/symlink"
must_fail editor cp pull "$guest/symlink" "$tmp/not-created"
[[ ! -e "$tmp/not-created" && ! -L "$tmp/not-created" ]]
echo 'PASS: binary round trip, dev ownership, private modes, no overwrite or symlink import'
