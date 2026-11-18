#!/usr/bin/env bash
# Optional, inside the guest as dev, after guest-tools.sh base node.
# These repos' installers run with dev's privileges. Review them first.
set -euo pipefail

usage() {
  echo "Usage: bash guest-personal.sh GROUP [...]   (dotzsh | dotvim | dotclaude | gstack)"
  echo "Override a source with GROUP_REPO (credential-free HTTPS) and GROUP_REF (branch/tag), e.g. DOTVIM_REF=main."
}
die() { echo "guest-personal: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "missing $1; run guest-tools.sh base node, then open a new guest shell"; }

case ${1:-} in -h|--help) usage; exit 0 ;; esac
(( $# )) || { usage >&2; exit 2; }
for group in "$@"; do
  case $group in dotzsh|dotvim|dotclaude|gstack) ;; *) usage >&2; exit 2 ;; esac
done
(( EUID != 0 )) || die "run inside the guest as dev, not root"
need git

# Reuse only the requested checkout. Never pull, switch refs or replace a
# user's existing directory as a side effect of installing personal settings.
checkout() {
  local dir=$1 repo=$2 ref=$3 commit
  local -a args=(--depth 1 --single-branch)
  [[ $repo =~ ^https://[a-zA-Z0-9.-]+/[^?#@[:space:]]+$ ]] ||
    die "use an HTTPS repository URL without credentials (authenticate in the guest)"
  if [[ -n $ref ]]; then
    git check-ref-format "refs/heads/$ref" || die "invalid branch or tag"
    args+=(--branch "$ref")
  fi
  if [[ -e $dir || -L $dir ]]; then
    [[ ! -L $dir && -d $dir/.git && $(git -C "$dir" config --get remote.origin.url) == "$repo" ]] ||
      die "not the requested checkout: $dir; move it aside or select its source"
    if [[ -n $ref ]]; then
      commit=$(git -C "$dir" rev-parse --verify --quiet "refs/heads/$ref^{commit}" ||
               git -C "$dir" rev-parse --verify --quiet "refs/tags/$ref^{commit}") ||
        die "$dir is not at requested branch/tag $ref"
      [[ $(git -C "$dir" rev-parse HEAD) == "$commit" ]] || die "$dir is not at $ref"
    fi
  else
    mkdir -p "$(dirname "$dir")"
    GIT_TERMINAL_PROMPT=0 git clone "${args[@]}" -- "$repo" "$dir" ||
      die "clone failed; check the repo/ref, egress and guest-local GitHub auth"
  fi
}

for group in "$@"; do
  echo "==> $group"
  key=${group^^}_REPO; refkey=${group^^}_REF
  if [[ $group == gstack ]]; then
    need bun; need node; need sudo
    dir=$HOME/.claude/skills/gstack
    checkout "$dir" "${!key:-https://github.com/garrytan/gstack}" "${!refkey:-}"
    (
      cd "$dir"
      # Upstream setup treats a failed browser bootstrap as success. Install
      # with this checkout's Playwright, including its matching runtime libs,
      # then require gstack's own offline render check.
      ./setup --host claude --no-browser
      node node_modules/playwright/cli.js install-deps chromium
      node node_modules/playwright/cli.js install chromium
      [[ -x browse/dist/browse ]] || die "gstack browse binary is missing"
      bin/gstack-browser-ensure --check
      # The readiness probe and the actual skill use different browser launch
      # options. Prove the latter works, without touching a running session.
      tmp=$(mktemp -d)
      export BROWSE_STATE_FILE="$tmp/.gstack/browse.json"
      browse=$dir/browse/dist/browse
      trap '[[ ! -f $BROWSE_STATE_FILE ]] || "$browse" stop >/dev/null 2>&1 || :; rm -rf -- "$tmp"' EXIT
      cd "$tmp"
      "$browse" goto about:blank || die "gstack browse cannot launch; see vm/PERSONAL.md (Chromium sandbox)"
    )
  else
    case $group in dotzsh) need zsh ;; dotvim) need nvim ;; esac
    dir=$HOME/dev/$group
    default_ref=
    [[ $group != dotclaude ]] || default_ref=main
    checkout "$dir" "${!key:-https://github.com/kurtb/$group}" "${!refkey:-$default_ref}"
    [[ -x $dir/install.sh ]] || die "$dir/install.sh is missing or not executable"
    # Oh My Zsh must not replace .zshrc (guest-tools' PATH/aliases live there).
    (cd "$dir" && KEEP_ZSHRC=yes CHSH=no RUNZSH=no ./install.sh)
  fi
done
