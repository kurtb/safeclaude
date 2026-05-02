# safeclaude.zsh — source this file to get helpers for running the safeclaude image
#
# Usage: source /path/to/safeclaude/safeclaude.zsh

_SAFECLAUDE_IMAGE="safeclaud:latest"
_SAFECLAUDE_DIR="${${(%):-%x}:A:h}"

safeclaude() {
  local subcmd="${1:-}"

  case "$subcmd" in
    build)
      shift
      _safeclaude_build "$@"
      return $?
      ;;
    list)
      _safeclaude_list
      return $?
      ;;
    --help|-h|help)
      _safeclaude_usage
      return 0
      ;;
    "")
      _safeclaude_usage
      return 1
      ;;
    -*)
      echo "safeclaude: unknown option: $subcmd" >&2
      _safeclaude_usage
      return 1
      ;;
    *)
      # safeclaude <env> [path]
      _safeclaude_run "$@"
      return $?
      ;;
  esac
}

_safeclaude_run() {
  local env="$1"
  local workspace="${2:-$PWD}"

  # Resolve workspace to absolute path
  workspace="$(cd "$workspace" 2>/dev/null && pwd)" || {
    echo "safeclaude: path not found: $2" >&2
    return 1
  }

  local config_dir="${HOME}/.config/safeclaude/${env}"
  local container_config_dir="/home/ubuntu/.config/safeclaude/${env}"

  # Create config dir if it doesn't exist
  if [[ ! -d "$config_dir" ]]; then
    echo "safeclaude: creating config dir: ${config_dir}"
    mkdir -p "$config_dir"
  fi

  local workspace_name="${workspace:t}"
  local container_workspace="/home/ubuntu/workspace/${workspace_name}"

  echo "safeclaude: env=${env} workspace=${workspace}"

  # NET_ADMIN + NET_RAW are required for the entrypoint to install the iptables
  # egress allowlist. Without the firewall, --dangerously-skip-permissions has
  # no meaningful blast-radius limit.
  docker run -it --rm \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    -v "${config_dir}:${container_config_dir}" \
    -v "${workspace}:${container_workspace}" \
    -e "CLAUDE_CONFIG_DIR=${container_config_dir}" \
    -w "${container_workspace}" \
    "$_SAFECLAUDE_IMAGE"
}

_safeclaude_build() {
  echo "safeclaude: building ${_SAFECLAUDE_IMAGE}"
  docker build -t "$_SAFECLAUDE_IMAGE" "$_SAFECLAUDE_DIR"
}

_safeclaude_list() {
  local config_base="${HOME}/.config/safeclaude"
  if [[ ! -d "$config_base" ]] || [[ -z "$(ls -A "$config_base" 2>/dev/null)" ]]; then
    echo "safeclaude: no environments configured (${config_base})"
    return 0
  fi
  echo "safeclaude environments:"
  for env_dir in "${config_base}"/*/; do
    echo "  ${env_dir:t}"
  done
}

_safeclaude_usage() {
  cat <<'EOF'
Usage: safeclaude <command> [args]

Commands:
  build              Build the Docker image
  <env> [path]       Run in an environment (path defaults to current directory)
  list               List configured environments
  help               Show this help

Environments are stored in ~/.config/safeclaude/<env> and mounted into the
container at the same path. CLAUDE_CONFIG_DIR is set to that path so each
environment has isolated Claude credentials and config.

Examples:
  safeclaude build
  safeclaude personal
  safeclaude work ~/dev/my-project
  safeclaude list
EOF
}
