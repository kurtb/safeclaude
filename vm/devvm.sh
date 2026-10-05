#!/usr/bin/env bash
# devvm — platform-neutral per-project dev VM.
#
# Walk up to a folder, boot an isolated VM, enforce a default-deny egress
# allowlist, shell in. One VM per project directory, named devvm-<basename>.
# The VM substrate is per-OS (drivers/), but the UX, guest image (cloud-init),
# and allowlist are shared.
#
#   source this, or run directly:
#   devvm              # create+boot (first run) or shell in (later runs)
#   devvm --name x     # explicit name
#   devvm stop | rm    # stop / destroy this dir's VM
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

_devvm_name() {
  if [[ "${1:-}" == --name && -n "${2:-}" ]]; then printf 'devvm-%s' "$2"; return; fi
  printf 'devvm-%s' "$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.-]/-/g')"
}

_devvm_driver() {
  case "$(uname -s)" in
    Linux)
      if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
        echo "$HERE/drivers/windows-wsl2.sh"
      else
        echo "$HERE/drivers/linux-incus.sh"
      fi ;;
    Darwin) echo "$HERE/drivers/darwin-lima.sh" ;;
    *) echo "unsupported OS: $(uname -s)" >&2; return 1 ;;
  esac
}

devvm() {
  local verb="up"
  case "${1:-}" in up|shell|stop|rm) verb="$1"; shift ;; esac
  local nm drv; nm="$(_devvm_name "$@")"; drv="$(_devvm_driver)" || return 1
  [ -x "$drv" ] || { echo "driver not available/executable: $drv" >&2; return 1; }
  case "$verb" in
    up)    "$drv" ensure "$nm" "$PWD" "$HERE" && "$drv" shell "$nm" "$PWD" "$HERE" ;;
    shell) "$drv" shell "$nm" "$PWD" "$HERE" ;;
    stop)  "$drv" stop  "$nm" "$PWD" "$HERE" ;;
    rm)    "$drv" rm    "$nm" "$PWD" "$HERE" ;;
  esac
}

# Allow running as a script as well as sourcing.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then devvm "$@"; fi
