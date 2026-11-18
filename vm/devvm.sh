#!/usr/bin/env bash
# devvm — platform-neutral per-project dev VM.
#
# Walk up to a folder, boot an isolated VM, enforce a default-deny egress
# allowlist (host-side), shell in. One VM per project, named
# devvm-<basename>-<hash>. Substrate is per-OS (drivers/); UX, guest image, and
# allowlist are shared.
#
# CLONE-ONLY model: no host filesystem is mounted into the VM. devvm reads the
# current folder's git remote and the guest clones it; edit in-VM via
# `devvm shell`. (Keeps the host unreachable from a guest-root agent.)
#
#   source ~/.../vm/devvm.sh   # safe to source: no top-level `set -e`
#   devvm [up|shell|stop|rm] [--name X]
#   devvm allow [host ...]     # add hosts to this machine's egress allowlist
#   devvm allow --rm host ...  # remove them again
#   devvm allow --refresh      # just re-resolve (fixes stale pinned IPs)
#
# NOTE: no `set -euo pipefail` at file scope — that would kill an interactive
# shell when sourced. It's scoped to the run subshell inside devvm() instead.

_DEVVM_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Incus-safe instance name: lowercase, [a-z0-9-] only, leading letter, <=63 chars.
# Build an Incus-valid name: devvm-<slug48>-<hash6>. The hash of the full
# identity (abs path, or the explicit --name) disambiguates two projects that
# share a basename (e.g. ~/a/web and ~/b/web) — review #25 nit.
_devvm_sanitize() {
  local s="$1" h="$2"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  [[ "$s" =~ ^[a-z] ]] || s="vm-$s"   # leading letter FIRST (digit-prefixed names)
  s="${s:0:48}"; s="${s%-}"           # cap AFTER, so the "vm-" prefix can't push past 63
  [ -n "$s" ] || s="vm"
  printf 'devvm-%s-%s' "$s" "$h"       # 6 + <=48 + 1 + 6 = <=61 <= 63
}

# Short stable hash, portable across Linux (sha1sum) and macOS (shasum); cksum
# is the last-resort fallback.
_devvm_hash() {
  if command -v sha1sum >/dev/null 2>&1; then printf '%s' "$1" | sha1sum | cut -c1-8
  elif command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum | cut -c1-8
  else printf '%08x' "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; fi
}

# --name may appear anywhere; default to the current dir's basename.
_devvm_name() {
  local a raw="" prev=""
  for a in "$@"; do [ "$prev" = --name ] && { raw="$a"; break; }; prev="$a"; done
  local slug ident
  if [ -n "$raw" ]; then slug="$raw"; ident="name:$raw"; else slug="$(basename "$PWD")"; ident="$PWD"; fi
  _devvm_sanitize "$slug" "$(_devvm_hash "$ident")"
}

# Verb = first up|shell|stop|rm token, skipping --name <value>; default up.
_devvm_verb() {
  local a v="up" skip=0
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

# `devvm allow` — this host's own additions to the egress allowlist.
#
# Extras live in a root-owned file on the HOST (outside the checkout and the
# install dir), merged with vm/allowlist.conf by host-egress.sh and the driver.
# Global to the machine: every devvm VM shares one bridge and one list. Run it
# on the host — nothing inside a guest can reach this file, by design.
_DEVVM_LOCAL_ALLOW="/etc/devvm/allowlist.local"

_devvm_allow() {
  local drv mode=add h bare esc hosts=() file="$_DEVVM_LOCAL_ALLOW"
  # The INSTALLED base list is what is actually enforced; the checkout's copy
  # may be newer (pulled, not yet re-installed), so never judge "already
  # allowed" from the checkout.
  local base="${DEVVM_INSTALL_DIR:-/usr/local/lib/devvm}/allowlist.conf"
  drv="$(_devvm_driver)" || return 1
  case "${1:-}" in
    --rm)      mode=rm; shift ;;
    --refresh) mode=refresh; shift ;;
    -h|--help) echo "usage: devvm allow [host ...] | --rm host ... | --refresh"; return 0 ;;
    -*)        echo "devvm allow: unknown option: $1" >&2; return 1 ;;
  esac

  if [ "$mode" = refresh ]; then
    [ $# -eq 0 ] || { echo "devvm allow --refresh takes no hosts (it changes nothing, only re-resolves)" >&2; return 1; }
    "$drv" refresh _ "" "$_DEVVM_HERE"
    return
  fi

  if [ "$mode" = add ] && [ $# -eq 0 ]; then
    echo "extra egress allowlist ($file):"
    if [ -s "$file" ]; then sed 's/^/  /' "$file"; else echo "  (none)"; fi
    echo "base list: $base"
    return 0
  fi
  [ $# -gt 0 ] || { echo "devvm allow --rm: name at least one host" >&2; return 1; }
  [ -r "$base" ] || { echo "devvm allow: no installed allowlist at $base — run: sudo \"$_DEVVM_HERE/install-host.sh\"" >&2; return 1; }

  # Exact host names only: every layer (DNS, SNI proxy, IP pin) works per name,
  # so a wildcard can't be expressed. Accept a pasted URL by trimming it down.
  # SECURITY: this regex is the only thing between user input and a root-owned
  # config file (and the sed pattern in --rm below). Keep it strict — letters,
  # digits, '-' and '.' only.
  for h in "$@"; do
    h="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')"
    h="${h#http://}"; h="${h#https://}"; h="${h%%/*}"; h="${h%.}"
    bare="${h#cidr:}"
    if ! [[ "$bare" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]]; then
      echo "devvm allow: not a host name: '$h' (exact names only — no wildcards, IPs or ports)" >&2
      return 1
    fi
    hosts+=("$h")
  done

  for h in "${hosts[@]}"; do
    bare="${h#cidr:}"; esc="${bare//./\\.}"
    if [ "$mode" = add ]; then
      # A plain request is satisfied by either form; a cidr: request only by an
      # existing cidr: entry, so it can widen a host that is already listed.
      if [ "$h" = "$bare" ]; then
        if grep -qxF -e "$bare" -e "cidr:$bare" "$file" "$base" 2>/dev/null; then
          echo "already allowed: $bare"; continue
        fi
      else
        if grep -qxF -e "cidr:$bare" "$file" "$base" 2>/dev/null; then
          echo "already allowed: $h"; continue
        fi
        echo "note: cidr: pins the whole /24 around each address $bare resolves to — a wider grant than one host" >&2
      fi
      sudo install -d -o root -g root -m 0755 "$(dirname "$file")"
      # Widening an existing plain extra replaces it rather than listing both.
      if [ "$h" != "$bare" ] && [ -e "$file" ]; then sudo sed -i -e "/^${esc}\$/d" "$file"; fi
      printf '%s\n' "$h" | sudo tee -a "$file" >/dev/null
      sudo chown root:root "$file"; sudo chmod 0644 "$file"
      echo "added: $h"
    else
      if grep -qxF -e "$bare" -e "cidr:$bare" "$file" 2>/dev/null; then
        sudo sed -i -e "/^${esc}\$/d" -e "/^cidr:${esc}\$/d" "$file"
        echo "removed: $bare"
      elif grep -qxF -e "$bare" -e "cidr:$bare" "$base" 2>/dev/null; then
        echo "$bare is on the base list (vm/allowlist.conf), not an extra — edit that file and re-run install-host.sh" >&2
      else
        echo "not in the extras: $bare"
      fi
    fi
  done

  # Always re-apply, even when the file didn't change: if an earlier apply
  # failed, the file and the live rules disagree, and a retry must fix that.
  "$drv" refresh _ "" "$_DEVVM_HERE" || {
    echo "devvm allow: the list was saved but could NOT be applied — live rules are unchanged." >&2
    echo "  Fix the error above, then run: devvm allow --refresh" >&2
    return 1
  }
}

devvm() {
  local verb name drv repo
  if [ "${1:-}" = allow ]; then shift; ( set -euo pipefail; _devvm_allow "$@" ); return; fi
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
