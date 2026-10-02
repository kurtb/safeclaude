# safeclaude VM wrapper (Lima) — MINIMAL. Source from your .zshrc:
#   source ~/dev/safeclaude/lima/safeclaude-vm.zsh
#
# Walk up to a project folder and boot a per-project VM, mirroring the container
# wrapper's model: instance name = safeclaude-<basename of PWD>, one VM per dir.
#
#   safeclaude-vm            # create+boot (first run) or shell in (later runs)
#   safeclaude-vm --name x   # explicit name
#   safeclaude-vm stop|rm    # stop / destroy this dir's VM
#
# Requires: limactl, socket_vmnet, host nested virt. Egress is enforced on the
# HOST by vm-firewall.sh (needs sudo there) — not trusted to the guest.

_scvm_dir() { print -- "${0:A:h}"; }   # dir this file lives in (has the yaml + firewall)

_scvm_name() {
  if [[ "${1:-}" == "--name" && -n "${2:-}" ]]; then print -- "safeclaude-$2"; return; fi
  print -- "safeclaude-${${PWD:t}:l}" | sed 's/[^a-z0-9_.-]/-/g'
}

safeclaude-vm() {
  local dir="$(_scvm_dir)"
  local sub="${1:-}"
  case "$sub" in
    stop) limactl stop "$(_scvm_name)"; return ;;
    rm)   limactl delete --force "$(_scvm_name)"; return ;;
  esac

  local name; name="$(_scvm_name "$@")"

  if limactl list -q 2>/dev/null | grep -qx "$name"; then
    # Exists: ensure running, then shell in.
    limactl list "$name" --format '{{.Status}}' | grep -qi running || limactl start "$name"
  else
    # First run: create from the template, bind-mounting THIS dir.
    limactl start --tty=false --name="$name" \
      --set=".provision=.provision" \
      --param PROJECT="$PWD" \
      "$dir/safeclaude.yaml"

    # Enforce host-side egress before handing the agent the keys.
    # VM_IF defaults to lima0 (socket_vmnet shared); override via SAFECLAUDE_VM_IF.
    local vm_if="${SAFECLAUDE_VM_IF:-lima0}"
    echo "Applying host-side egress firewall on $vm_if (sudo)..."
    sudo "$dir/vm-firewall.sh" "$vm_if"
  fi

  limactl shell "$name"
}
