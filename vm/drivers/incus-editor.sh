#!/usr/bin/env bash
# Linux driver extension: VERB NAME VMDIR [operands...]. Requires a running VM.
set -euo pipefail
die() { echo "devvm: $*" >&2; exit 1; }
verb="${1:?}"; name="${2:?}"; vmdir="${3:?}"; shift 3
# The instance name is also emitted in an SSH config / ProxyCommand.
[[ "$name" =~ ^devvm-[a-z0-9-]+$ ]] || die 'invalid devvm instance name'

ssh_config() {
  [ "$#" = 0 ] || die 'usage: devvm ssh-config [--name NAME]'
  local state="$HOME/.ssh/devvm/$name" pub hostkey pin
  umask 077
  mkdir -p -- "$state"
  exec 9>"$state/.lock"; flock -x 9
  if [ ! -f "$state/identity" ]; then
    ssh-keygen -q -t ed25519 -N '' -C '' -f "$state/identity" </dev/null
  fi
  pub="$(cut -d' ' -f1-2 < "$state/identity.pub")"
  [[ "$pub" =~ ^ssh-ed25519\ [A-Za-z0-9+/]{68}$ ]] || die 'invalid devvm public key'
  hostkey="$(incus exec -T "$name" -- bash -s -- "$pub" < "$vmdir/lib/guest-editor-setup.sh")"
  [[ "$hostkey" =~ ^ssh-ed25519\ [A-Za-z0-9+/]{68}$ ]] || die 'invalid guest SSH host key'
  ssh-keygen -lf - <<< "$hostkey" >/dev/null || die 'invalid guest SSH host key'
  pin="$name $hostkey"
  if [ -e "$state/known_hosts" ]; then
    [ "$(cat "$state/known_hosts")" = "$pin" ] ||
      die "SSH host key changed for $name. If you verified the VM was replaced, remove '$state/known_hosts' and rerun."
  else
    printf '%s\n' "$pin" > "$state/known_hosts"
  fi
  cat <<CONFIG
Host $name
    User dev
    ProxyCommand incus exec -T $name -- /usr/sbin/sshd -i -f /etc/ssh/devvm_sshd_config
    IdentityFile ~/.ssh/devvm/$name/identity
    IdentitiesOnly yes
    IdentityAgent none
    ForwardAgent no
    ForwardX11 no
    PreferredAuthentications publickey
    HostKeyAlias $name
    UserKnownHostsFile ~/.ssh/devvm/$name/known_hosts
    GlobalKnownHostsFile none
    StrictHostKeyChecking yes
    UpdateHostKeys no
CONFIG
}

copy_file() (
  local usage='usage: devvm cp push HOST_FILE /GUEST_FILE | devvm cp pull /GUEST_FILE HOST_FILE'
  [ "$#" = 3 ] || die "$usage"
  local direction="$1" host guest uid gid
  case "$direction" in
    push) host="$2"; guest="$3" ;;
    pull) guest="$2"; host="$3" ;;
    *) die "$usage" ;;
  esac
  [[ "$guest" = /* && "$guest" != */ && -n "$host" && "$host" != - && "$host" != */ ]] ||
    die "$usage"
  if [ "$direction" = push ]; then
    [[ -f "$host" && ! -L "$host" ]] || die 'push requires a regular host file, not a symlink'
    # shellcheck disable=SC2016 # Positional parameter in the guest shell.
    incus exec -T "$name" -- sh -c 'test ! -e "$1" && test ! -L "$1"' _ "$guest" ||
      die 'cannot push: guest destination must be a new file in the running VM'
    uid="$(incus exec -T "$name" -- id -u dev)"; gid="$(incus exec -T "$name" -- id -g dev)"
    [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || die 'invalid guest dev UID/GID'
    incus file push --mode 0600 --uid "$uid" --gid "$gid" -- "$host" "$name$guest"
  else
    [[ ! -e "$host" && ! -L "$host" ]] || die 'pull destination must be a new host file'
    # Some Incus releases follow a command-line symlink by default.
    # shellcheck disable=SC2016 # Positional parameter in the guest shell.
    incus exec -T "$name" -- sh -c 'test -f "$1" && test ! -L "$1"' _ "$guest" ||
      die 'pull requires a regular guest file, not a directory or symlink'
    # Stage in a private directory. Never install a symlink, mode or recursive
    # tree supplied by the guest, and never overwrite a file on the host.
    local tmp
    tmp="$(mktemp -d -- "$(dirname -- "$host")/.devvm-pull.XXXXXXXX")"
    trap 'rm -rf -- "$tmp"' EXIT
    incus file pull -- "$name$guest" "$tmp/file"
    [[ -f "$tmp/file" && ! -L "$tmp/file" ]] || die 'pull requires a regular file'
    chmod 0600 "$tmp/file"
    ln -T -- "$tmp/file" "$host"
  fi
)

case "$verb" in
  ssh-config) ssh_config "$@" ;;
  cp) copy_file "$@" ;;
  *) die "unknown editor command: $verb" ;;
esac
