# safeclaude.zsh — host-side helper for the safeclaude sandbox image.
#
# Usage: source /path/to/safeclaude/safeclaude.zsh
#
# Model:
#   - One container + one named volume per project directory.
#   - Container name / volume name = basename of project dir (overridable).
#   - `safeclaude` in a project dir: attach if running, start if stopped,
#     create if neither. Always drops you into zsh inside the container.
#   - State (auth, history, skills installed at runtime) lives in the named
#     volume and survives image rebuilds.

_SAFECLAUDE_IMAGE="safeclaud:latest"
_SAFECLAUDE_DIR="${${(%):-%x}:A:h}"

safeclaude() {
  local subcmd="${1:-}"

  case "$subcmd" in
    build)
      shift
      _safeclaude_build "$@"
      ;;
    list|ls)
      _safeclaude_list
      ;;
    stop)
      shift
      _safeclaude_stop "$@"
      ;;
    rm|destroy)
      shift
      _safeclaude_rm "$@"
      ;;
    --help|-h|help)
      _safeclaude_usage
      ;;
    --name)
      shift
      _safeclaude_run --name "$@"
      ;;
    "")
      _safeclaude_run
      ;;
    -*)
      echo "safeclaude: unknown option: $subcmd" >&2
      _safeclaude_usage
      return 1
      ;;
    *)
      # Treat as project name override: `safeclaude myproj`
      _safeclaude_run --name "$subcmd"
      ;;
  esac
}

# --- name resolution -------------------------------------------------------

_safeclaude_name_for_pwd() {
  # Default: basename of $PWD, lowercased, non-alnum -> -
  print -- "${${PWD:t}:l}" | sed 's/[^a-z0-9_.-]/-/g'
}

_safeclaude_resolve_name() {
  # Args: "--name foo" or nothing. Echoes the resolved name.
  if [[ "${1:-}" == "--name" && -n "${2:-}" ]]; then
    print -- "$2"
  else
    _safeclaude_name_for_pwd
  fi
}

_safeclaude_container() { print -- "safeclaude-$1"; }
_safeclaude_volume()    { print -- "safeclaude-$1"; }

# --- run -------------------------------------------------------------------

_safeclaude_run() {
  local name="$(_safeclaude_resolve_name "$@")"
  local container="$(_safeclaude_container "$name")"
  local volume="$(_safeclaude_volume "$name")"
  local workspace="$PWD"
  local container_workspace="/home/ubuntu/workspace/${name}"

  # Already running? Just exec a shell.
  if docker ps --format '{{.Names}}' | grep -qx "$container"; then
    echo "safeclaude: attaching to running container '${container}'"
    docker exec -it -w "$container_workspace" "$container" /usr/bin/zsh
    return $?
  fi

  # Exists but stopped? Start then exec.
  if docker ps -a --format '{{.Names}}' | grep -qx "$container"; then
    echo "safeclaude: starting stopped container '${container}'"
    docker start "$container" >/dev/null || return $?
    docker exec -it -w "$container_workspace" "$container" /usr/bin/zsh
    return $?
  fi

  # Fresh: create volume (idempotent), then run detached.
  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    echo "safeclaude: creating volume '${volume}'"
    docker volume create "$volume" >/dev/null
  fi

  echo "safeclaude: launching new container '${container}' (workspace=${workspace})"
  docker run -d \
    --name "$container" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    -v "${volume}:/home/ubuntu" \
    -v "${workspace}:${container_workspace}" \
    "$_SAFECLAUDE_IMAGE" >/dev/null || return $?

  # Give the entrypoint a moment to apply the firewall before we attach.
  # init-firewall.sh is fast; a short bounded wait is plenty.
  local i=0
  while (( i < 20 )); do
    if docker exec "$container" test -f /tmp/safeclaude-ready 2>/dev/null; then
      break
    fi
    sleep 0.25
    (( i++ ))
  done

  docker exec -it -w "$container_workspace" "$container" /usr/bin/zsh
}

# --- build -----------------------------------------------------------------

_safeclaude_build() {
  echo "safeclaude: building ${_SAFECLAUDE_IMAGE}"
  docker build -t "$_SAFECLAUDE_IMAGE" "$@" "$_SAFECLAUDE_DIR"
}

# --- list ------------------------------------------------------------------

_safeclaude_list() {
  echo "containers:"
  docker ps -a --filter "name=^safeclaude-" \
    --format '  {{.Names}}\t{{.Status}}' 2>/dev/null \
    | column -t -s $'\t' \
    || echo "  (none)"
  echo
  echo "volumes:"
  docker volume ls --filter "name=^safeclaude-" --format '  {{.Name}}' 2>/dev/null \
    || echo "  (none)"
}

# --- stop ------------------------------------------------------------------

_safeclaude_stop() {
  local name="${1:-$(_safeclaude_name_for_pwd)}"
  local container="$(_safeclaude_container "$name")"
  echo "safeclaude: stopping '${container}'"
  docker stop "$container"
}

# --- rm --------------------------------------------------------------------

_safeclaude_rm() {
  local name="${1:-$(_safeclaude_name_for_pwd)}"
  local container="$(_safeclaude_container "$name")"
  local volume="$(_safeclaude_volume "$name")"

  echo "safeclaude: this will destroy:"
  echo "  container: ${container}"
  echo "  volume:    ${volume}  (auth, history, runtime-installed skills)"
  printf "proceed? [y/N] "
  read -r reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "aborted"; return 1; }

  docker rm -f "$container" 2>/dev/null
  docker volume rm "$volume" 2>/dev/null
  echo "done."
}

# --- usage -----------------------------------------------------------------

_safeclaude_usage() {
  cat <<'EOF'
Usage: safeclaude [command|name]

Without args, operates on the current directory:
  safeclaude                Attach to current dir's container (start/create as needed)
  safeclaude myproj         Same, but use 'myproj' as the container/volume name
  safeclaude --name myproj  Explicit form of the above

Commands:
  build [docker-args...]    Rebuild the image (pass-through args, e.g. --no-cache)
  list                      Show all safeclaude containers + volumes
  stop [name]               Stop a container (default: current dir's)
  rm   [name]               Destroy container + volume (default: current dir's)
  help                      Show this help

Model:
  Per-project container named safeclaude-<basename>, backed by a Docker
  volume of the same name mounted at /home/ubuntu. The current directory
  is bind-mounted at /home/ubuntu/workspace/<name>. Image rebuilds upgrade
  the floor; the volume preserves auth, shell history, and skills you
  install at runtime.

Inside the container:
  yolo-claude   # claude --dangerously-skip-permissions
  yolo-codex    # codex --dangerously-bypass-approvals-and-sandbox
  yolo-gemini   # gemini --yolo
  yolo-cursor   # agent --force
EOF
}
