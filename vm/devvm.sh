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
#   devvm help                # commands and new VM sizing
#   devvm allow [host ...]     # add hosts to this machine's egress allowlist
#   devvm allow --rm host ...  # remove them again
#   devvm allow --refresh      # re-apply the allowlist (DNS + proxy + rules)
#
# NOTE: no `set -euo pipefail` at file scope — that would kill an interactive
# shell when sourced. It's scoped to the run subshell inside devvm() instead.

_DEVVM_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Incus-safe instance name: lowercase, [a-z0-9-] only, leading letter, <=63 chars.
# Build an Incus-valid name: devvm-<slug48>-<hash8>. The hash of the full
# identity (abs path, or the explicit --name) disambiguates two projects that
# share a basename (e.g. ~/a/web and ~/b/web) — review #25 nit.
_devvm_sanitize() {
  local s="$1" h="$2"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  [[ "$s" =~ ^[a-z] ]] || s="vm-$s"   # leading letter FIRST (digit-prefixed names)
  s="${s:0:48}"; s="${s%-}"           # cap AFTER, so the "vm-" prefix can't push past 63
  [ -n "$s" ] || s="vm"
  printf 'devvm-%s-%s' "$s" "$h"       # 6 + <=48 + 1 + 8 = <=63
}

# Short stable hash, portable across Linux (sha1sum) and macOS (shasum); cksum
# is the last-resort fallback.
_devvm_hash() {
  if command -v sha1sum >/dev/null 2>&1; then printf '%s' "$1" | sha1sum | cut -c1-8
  elif command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum | cut -c1-8
  else printf '%08x' "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; fi
}

_devvm_name() {
  local raw="$1" slug ident
  if [ -n "$raw" ]; then slug="$raw"; ident="name:$raw"; else slug="$(basename "$PWD")"; ident="$PWD"; fi
  _devvm_sanitize "$slug" "$(_devvm_hash "$ident")"
}

_devvm_help() {
  cat <<'HELP'
Usage: devvm [COMMAND] [--name PROJECT]
  up                 Create or start the project's VM and enter a shell (default)
  shell              Enter a running VM
  stop               Stop the VM
  rm                 Delete the VM and all of its snapshots
  list               List devvm VMs and their states in the current Incus project
  snapshot LABEL     Save a disk snapshot
  restore LABEL      Replace the VM disk with a snapshot (reboots a running VM)
  upgrade            Start the existing VM and update its base setup
  doctor             Check host enforcement, guest tools and allowlisted HTTPS
  ssh-config         Print an SSH config for the running guest
  cp push HOST_FILE /GUEST_FILE   Copy a single file into the guest
  cp pull /GUEST_FILE HOST_FILE   Copy a single file to a new host path
  help               Show this help
  allow [HOST ...]   List or add machine-wide allowlist extras
  allow --rm HOST ...  Remove extras
  allow --refresh    Reapply host egress rules

By default the current directory identifies the VM. Use the same --name on later
commands to select a named VM. For a new VM, set DEVVM_CPUS (default 4),
DEVVM_MEMORY (8GiB) or DEVVM_DISK (40GiB). Existing VMs keep their sizing.
With the installed CLI, set DEVVM_CHECKOUT to a safeclaude checkout for
doctor to compare its base allowlist against the installed one.
HELP
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
  local drv mode=add h esc hosts=() file="$_DEVVM_LOCAL_ALLOW"
  # The INSTALLED base list is what is actually enforced; the checkout's copy
  # may be newer (pulled, not yet re-installed), so never judge "already
  # allowed" from the checkout.
  local base="${DEVVM_INSTALL_DIR:-/usr/local/lib/devvm}/allowlist.conf"
  drv="$(_devvm_driver)" || return 1
  case "${1:-}" in
    --rm)      mode="rm"; shift ;;
    --refresh) mode=refresh; shift ;;
    -h|--help) echo "usage: devvm allow [host ...] | --rm host ... | --refresh"; return 0 ;;
    -*)        echo "devvm allow: unknown option: $1" >&2; return 1 ;;
  esac

  if [ "$mode" = refresh ]; then
    [ $# -eq 0 ] || { echo "devvm allow --refresh takes no hosts (it changes nothing, only re-applies)" >&2; return 1; }
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
  [ -r "$base" ] || { echo "devvm allow: no installed allowlist at $base — from a trusted safeclaude checkout run sudo ./vm/install-host.sh" >&2; return 1; }

  # Exact host names only: every layer (DNS and the proxy) works per name, so a
  # wildcard can't be expressed. Accept a pasted URL by trimming it down.
  # SECURITY: this regex is the only thing between user input and a root-owned
  # config file (and the sed pattern in --rm below). Keep it strict — letters,
  # digits, '-' and '.' only. host-egress.sh re-checks every line the same way.
  for h in "$@"; do
    h="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')"
    h="${h#http://}"; h="${h#https://}"; h="${h%%/*}"; h="${h%.}"
    if [[ "$h" == cidr:* ]]; then
      # Used to widen the IP pin to a /24. There is no IP pin any more: the
      # proxy looks the address up itself on every connection.
      echo "note: 'cidr:' is no longer needed (addresses are resolved per connection); adding ${h#cidr:} as a plain host" >&2
      h="${h#cidr:}"
    fi
    if ! [[ "$h" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]]; then
      echo "devvm allow: not a host name: '$h' (exact names only — no wildcards, IPs or ports)" >&2
      return 1
    fi
    hosts+=("$h")
  done

  for h in "${hosts[@]}"; do
    esc="${h//./\\.}"
    if [ "$mode" = add ]; then
      # `cidr:<host>` lines from before are still honoured as that host.
      if grep -qxF -e "$h" -e "cidr:$h" "$file" "$base" 2>/dev/null; then
        echo "already allowed: $h"; continue
      fi
      sudo install -d -o root -g root -m 0755 "$(dirname "$file")"
      printf '%s\n' "$h" | sudo tee -a "$file" >/dev/null
      sudo chown root:root "$file"; sudo chmod 0644 "$file"
      echo "added: $h"
    else
      if grep -qxF -e "$h" -e "cidr:$h" "$file" 2>/dev/null; then
        sudo sed -i -e "/^${esc}\$/d" -e "/^cidr:${esc}\$/d" "$file"
        echo "removed: $h"
      elif grep -qxF -e "$h" -e "cidr:$h" "$base" 2>/dev/null; then
        echo "$h is on the base list (vm/allowlist.conf), not an extra — edit that file and re-run install-host.sh" >&2
      else
        echo "not in the extras: $h"
      fi
    fi
  done

  # Always re-apply, even when the file didn't change: if an earlier apply
  # failed, the file and the live rules disagree, and a retry must fix that.
  "$drv" refresh _ "" "$_DEVVM_HERE" || {
    echo "devvm allow: the list was saved but was NOT fully applied — DNS and the proxy may now" >&2
    echo "  disagree (it still fails closed). Fix the error above, then run: devvm allow --refresh" >&2
    return 1
  }
}

devvm() (
  set -euo pipefail
  local args=() raw="" verb name drv repo=""
  if [ "${1:-}" = allow ]; then shift; _devvm_allow "$@"; return; fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name)
        if [ -z "${2:-}" ] || [ -n "$raw" ]; then
          echo "devvm: expected one --name PROJECT" >&2; return 2
        fi
        raw="$2"; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  set -- "${args[@]}"
  verb="${1:-up}"
  if [ "$#" -gt 0 ]; then shift; fi
  case "$verb" in
    snapshot|restore)
      if [ "$#" -ne 1 ] || ! [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "usage: devvm $verb LABEL [--name PROJECT] (letters, digits, dots, underscores, hyphens)" >&2
        return 2
      fi ;;
    cp) ;;  # Direction and paths are checked by the copy implementation.
    up|shell|stop|rm|list|upgrade|doctor|ssh-config|help|--help|-h)
      [ "$#" -eq 0 ] || { echo "devvm $verb: unexpected argument: $1" >&2; return 2; } ;;
    *) echo "devvm: unknown command: $verb (see devvm help)" >&2; return 2 ;;
  esac
  case "$verb" in help|-h|--help) _devvm_help; return ;; esac
  name="$(_devvm_name "$raw")"
  drv="$(_devvm_driver)" || return 1
  [ -x "$drv" ] || { echo "driver not available/executable: $drv" >&2; return 1; }
  # Clone-only: hand the driver the repo to clone (empty => guest starts bare).
  if [ "$verb" = up ]; then
    repo="$(git -C "$PWD" remote get-url origin 2>/dev/null || true)"
    "$drv" ensure "$name" "$repo" "$_DEVVM_HERE" || return
    verb=shell
  fi
  "$drv" "$verb" "$name" "" "$_DEVVM_HERE" "$@"
)

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then devvm "$@"; fi
