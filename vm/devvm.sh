#!/usr/bin/env bash
# devvm — platform-neutral per-project dev VM.
#
# Walk up to a folder, boot an isolated VM, enforce a default-deny egress
# allowlist (host-side), shell in. One VM per project, named devvm-<basename>.
# Substrate is per-OS (drivers/); UX, guest image, and allowlist are shared.
#
# CLONE-ONLY model: no host filesystem is mounted into the VM. devvm reads the
# current folder's git remote and the guest clones it; edit in-VM via VS Code
# Remote-SSH. (Keeps the host unreachable from a guest-root agent.)
#
#   source ~/.../vm/devvm.sh   # safe to source: no top-level `set -e`
#   devvm [up|shell|stop|rm] [--name X]
#
# NOTE: no `set -euo pipefail` at file scope — that would kill an interactive
# shell when sourced. It's scoped to the run subshell inside devvm() instead.

_DEVVM_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Incus-safe instance name: lowercase, [a-z0-9-] only, leading letter, <=63 chars.
_devvm_sanitize() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  [[ "$s" =~ ^[a-z] ]] || s="vm-$s"
  printf 'devvm-%s' "${s:0:56}"        # "devvm-" (6) + 56 = 62 <= 63
}

# --name may appear anywhere; default to the current dir's basename.
_devvm_name() {
  local n="" prev=""
  for a in "$@"; do [ "$prev" = --name ] && { n="$a"; break; }; prev="$a"; done
  [ -n "$n" ] || n="$(basename "$PWD")"
  _devvm_sanitize "$n"
}

# Verb = first up|shell|stop|rm token, skipping --name <value>; default up.
_devvm_verb() {
  local v="up" skip=0
  for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in --name) skip=1 ;; up|shell|stop|rm) v="$a"; break ;; esac
  done
  printf '%s' "$v"
}

_devvm_driver() {
  case "$(uname -s)" in
    Linux)
      if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null
      then echo "$_DEVVM_HERE/drivers/windows-wsl2.sh"
      else echo "$_DEVVM_HERE/drivers/linux-incus.sh"; fi ;;
    Darwin) echo "$_DEVVM_HERE/drivers/darwin-lima.sh" ;;
    *) echo "unsupported OS: $(uname -s)" >&2; return 1 ;;
  esac
}

devvm() {
  local verb name drv repo
  verb="$(_devvm_verb "$@")"
  name="$(_devvm_name "$@")"
  drv="$(_devvm_driver)" || return 1
  [ -x "$drv" ] || { echo "driver not available/executable: $drv" >&2; return 1; }
  # Clone-only: hand the driver the repo to clone (empty => guest starts bare).
  repo="$(git -C "$PWD" remote get-url origin 2>/dev/null || true)"
  (
    set -euo pipefail
    case "$verb" in
      up)    "$drv" ensure "$name" "$repo" "$_DEVVM_HERE" && "$drv" shell "$name" "$repo" "$_DEVVM_HERE" ;;
      shell) "$drv" shell  "$name" "$repo" "$_DEVVM_HERE" ;;
      stop)  "$drv" stop   "$name" "$repo" "$_DEVVM_HERE" ;;
      rm)    "$drv" rm     "$name" "$repo" "$_DEVVM_HERE" ;;
    esac
  )
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then devvm "$@"; fi
