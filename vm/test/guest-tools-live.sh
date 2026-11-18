#!/usr/bin/env bash
# Nightly test on the disposable VM created by incus-integration.sh.
set -euo pipefail
name=${1:?expected a disposable instance name}
vm=$(cd "$(dirname "$0")/.." && pwd)
stage=$(incus exec "$name" -- mktemp -d)
trap 'incus exec "$name" -- rm -rf -- "$stage"' EXIT
tar -C "$vm" -cf - guest-setup.sh gh-auth-setup guest-tools.sh |
  incus exec "$name" -T -- tar -C "$stage" -xf -
incus exec "$name" -- chmod 0755 "$stage"
incus exec "$name" -- bash "$stage/guest-setup.sh"
as_dev() { incus exec "$name" -T -- su - dev -s /bin/bash -c "$1"; }
as_dev 'mkdir -p ~/.claude; printf "%s\n" "{}" > ~/.claude/settings.json'
for run in 1 2; do
  echo "Guest tool installation, pass $run"
  as_dev "DEVVM_KEEP_BYPASS_PROMPT=1 bash '$stage/guest-tools.sh'"
  as_dev 'set -e
    for tool in zsh rg fzf jq tmux nvim delta shellcheck hadolint node npm bun mise claude codex gemini agent; do command -v "$tool"; done
    alias yolo-claude yolo-codex yolo-gemini yolo-cursor
    sudo -n true
    id -nG | tr " " "\n" | grep -Fx docker
    grep -Fx "{}" ~/.claude/settings.json
    node -e "process.exit(process.release.lts ? 0 : 1)"'
done
original=$(as_dev 'node --version')
major=22
[[ $original != v22.* ]] || major=24
as_dev "NODE_VERSION=$major bash '$stage/guest-tools.sh' node"
[[ $(as_dev 'node --version') == v"$major".* ]]
as_dev "fnm exec --using '$original' node --version" | grep -Fx "$original"
