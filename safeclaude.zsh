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

_SAFECLAUDE_DIR="${${(%):-%x}:A:h}"

# Published image, used when running without the repo (see image resolution).
_SAFECLAUDE_GHCR="ghcr.io/kurtb/safeclaude:latest"

# Image to run, resolved in priority order:
#   1. $SAFECLAUDE_IMAGE if set (explicit override).
#   2. Local build tag `safeclaud:latest` when sourced from a checkout (there's
#      a Dockerfile next to this script, so `safeclaude build` makes sense).
#   3. The published GHCR image otherwise (installed standalone, no repo) — the
#      wrapper pulls it on `recreate`/`pull`, and docker run auto-pulls on first
#      use.
if [[ -n "${SAFECLAUDE_IMAGE:-}" ]]; then
  _SAFECLAUDE_IMAGE="$SAFECLAUDE_IMAGE"
elif [[ -f "$_SAFECLAUDE_DIR/Dockerfile" ]]; then
  _SAFECLAUDE_IMAGE="safeclaud:latest"
else
  _SAFECLAUDE_IMAGE="$_SAFECLAUDE_GHCR"
fi

# Pull the image when it's a registry reference (contains a '/'); the local
# build tag `safeclaud:latest` has no registry path and nothing to pull.
_safeclaude_maybe_pull() {
  case "$_SAFECLAUDE_IMAGE" in
    */*)
      echo "safeclaude: pulling ${_SAFECLAUDE_IMAGE}"
      docker pull "$_SAFECLAUDE_IMAGE" \
        || echo "safeclaude: pull failed; using local image if present" >&2
      ;;
  esac
}

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
    recreate)
      shift
      _safeclaude_recreate "$@"
      ;;
    pull|update)
      _safeclaude_maybe_pull
      ;;
    upgrade|self-update)
      _safeclaude_upgrade
      ;;
    allow)
      shift
      _safeclaude_allow "$@"
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

  # Host-controlled extra firewall allowlist (see `safeclaude allow`), mounted
  # READ-ONLY so the sandboxed agent can't widen its own egress. Global across
  # projects; init-firewall.sh reads /etc/safeclaude/allowed-domains at start.
  local allow_dir="$HOME/.config/safeclaude"
  mkdir -p "$allow_dir"

  echo "safeclaude: launching new container '${container}' (workspace=${workspace})"
  # --init runs tini as PID 1 so orphaned processes (e.g. agent subprocesses
  # left behind by docker exec sessions) get reaped instead of piling up as
  # zombies — the entrypoint's `exec sleep infinity` would never reap them.
  docker run -d \
    --init \
    --name "$container" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    -v "${volume}:/home/ubuntu" \
    -v "${workspace}:${container_workspace}" \
    -v "${allow_dir}:/etc/safeclaude:ro" \
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
  if [[ ! -f "$_SAFECLAUDE_DIR/Dockerfile" ]]; then
    echo "safeclaude: no Dockerfile at ${_SAFECLAUDE_DIR} — installed standalone." >&2
    echo "  You're running the published image (${_SAFECLAUDE_IMAGE})." >&2
    echo "  Update it with:  safeclaude recreate   (pulls latest, keeps your volume)" >&2
    echo "  To build locally, clone https://github.com/kurtb/safeclaude and source its safeclaude.zsh." >&2
    return 1
  fi
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

# --- recreate --------------------------------------------------------------

_safeclaude_recreate() {
  # Pull the latest image (if it's a registry reference), then remove the
  # container (preserving its volume) and run again from that image. This is the
  # update path for both flows: after `safeclaude build` locally, or to pick up
  # a newly published GHCR image — without losing auth/history.
  local name_arg="${1:-}"
  local name="${name_arg:-$(_safeclaude_name_for_pwd)}"
  local container="$(_safeclaude_container "$name")"
  local volume="$(_safeclaude_volume "$name")"

  _safeclaude_maybe_pull

  if docker ps -a --format '{{.Names}}' | grep -qx "$container"; then
    echo "safeclaude: removing container '${container}' (volume '${volume}' preserved)"
    docker rm -f "$container" >/dev/null || return $?
  else
    echo "safeclaude: no container '${container}' to remove; will create fresh"
  fi

  if [[ -n "$name_arg" ]]; then
    _safeclaude_run --name "$name_arg"
  else
    _safeclaude_run
  fi
}

# --- upgrade ---------------------------------------------------------------

_safeclaude_upgrade() {
  # Update the safeclaude WRAPPER itself (the host script) — not a container
  # image; use `safeclaude recreate` for that. A checkout (Dockerfile present,
  # like `build`) updates via git pull; a standalone install re-runs the
  # installer. Re-source your shell afterward to load the new wrapper.
  if [[ -f "$_SAFECLAUDE_DIR/Dockerfile" ]]; then
    echo "safeclaude: updating checkout at ${_SAFECLAUDE_DIR}"
    git -C "$_SAFECLAUDE_DIR" pull --ff-only || return $?
    echo "safeclaude: re-source it (or open a new shell):  source ${_SAFECLAUDE_DIR}/safeclaude.zsh"
    echo "safeclaude: rebuild the image with:  safeclaude build"
  else
    echo "safeclaude: re-running the installer (set SAFECLAUDE_VERSION to pin)"
    # Download first, then run — piping curl into bash would hide a failed
    # download (bash reads empty stdin and exits 0). Forward SAFECLAUDE_VERSION
    # explicitly so an unexported value still reaches the installer.
    local tmp; tmp="$(mktemp)"
    if ! curl -fsSL https://raw.githubusercontent.com/kurtb/safeclaude/main/install.sh -o "$tmp"; then
      rm -f "$tmp"; echo "safeclaude: failed to download the installer" >&2; return 1
    fi
    SAFECLAUDE_VERSION="${SAFECLAUDE_VERSION:-}" bash "$tmp"; local rc=$?
    rm -f "$tmp"
    (( rc == 0 )) || return $rc
    echo "safeclaude: re-source your shell (or open a new shell) to load the new wrapper"
  fi
}

# --- allow (extra firewall domains) ----------------------------------------

_safeclaude_allow() {
  # Add domain(s) to the host-controlled extra firewall allowlist and re-apply.
  # The file is mounted READ-ONLY into containers, so only the host (this
  # command) can edit it — the sandboxed agent can't widen its own egress.
  local dir="$HOME/.config/safeclaude" file
  file="$dir/allowed-domains"
  mkdir -p "$dir"; touch "$file"

  if [[ $# -eq 0 ]]; then
    echo "extra firewall allowlist (${file}):"
    if [[ -s "$file" ]]; then sed 's/^/  /' "$file"; else echo "  (empty)"; fi
    return 0
  fi

  local d
  for d in "$@"; do
    d="${d#http://}"; d="${d#https://}"; d="${d%%/*}"   # tolerate a pasted URL
    if grep -qxF "$d" "$file" 2>/dev/null; then
      echo "safeclaude: already allowed: $d"
    else
      print -r -- "$d" >> "$file"
      echo "safeclaude: added: $d"
    fi
  done

  # Apply by (re)starting the container so the firewall re-initialises at a
  # clean boot. We deliberately do NOT re-run init-firewall.sh in a live
  # container: it's a boot-only script (a re-run can't reach GitHub through the
  # already-DROP policy and would leave the firewall broken), and any "reset the
  # policy to fetch" workaround would open an egress window the sandboxed agent
  # could exploit. A restart re-applies it before the agent is running.
  local running
  running=(${(f)"$(docker ps --format '{{.Names}}' 2>/dev/null | grep '^safeclaude-' || true)"})
  if (( ${#running} )); then
    echo "safeclaude: apply to running containers with:  docker restart ${running}"
    echo "safeclaude: (or 'safeclaude recreate' — needed once for containers predating the allowlist mount)"
  else
    echo "safeclaude: saved. Applied on next container start (or 'safeclaude recreate')."
  fi
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
  build [docker-args...]    Rebuild the image (checkout only; pass-through args)
  pull                      Pull the latest published image (if using GHCR)
  upgrade                   Update the wrapper itself (git pull, or re-run installer)
  allow [domain...]         Add host-controlled firewall allowlist domains (no args: list)
  list                      Show all safeclaude containers + volumes
  stop     [name]           Stop a container (default: current dir's)
  recreate [name]           Update image (pull if remote) + replace container, keep volume
  rm       [name]           Destroy container + volume (default: current dir's)
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
  gh-auth-setup # configure GitHub auth (run it yourself when you need it)
  tailscale-up  # connect to your tailnet (userspace mode; proxy on :1055)
  safeclaude-doctor  # smoke-test the build (tools, gstack, gh, firewall)
EOF
}
