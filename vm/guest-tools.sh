#!/usr/bin/env bash
# devvm guest toolbox — run this BY HAND, inside the VM, as `dev`, AFTER
# guest-setup.sh. It installs what the container image used to bake in: the
# everyday dev tools and the other agent CLIs.
#
#   bash ~/workspace/safeclaude/vm/guest-tools.sh          # everything
#   bash ~/workspace/safeclaude/vm/guest-tools.sh agents   # one group
#
# Groups:  base    shell tools, compilers, Python venv/pip, linters, neovim
#          node    Node.js (via fnm; current LTS unless NODE_VERSION says) + Bun
#          mise    mise, for per-project tool versions (mise.toml / .tool-versions)
#          agents  Codex, Gemini and Cursor CLIs, yolo-* aliases   (needs node)
#          git     delta as pager; user.name/user.email from GIT_USER_NAME/EMAIL
#
# IDEMPOTENT: re-run it any time; finished steps are skipped. To upgrade one
# tool, delete it and re-run. Node is the exception — re-running moves it:
#   bash guest-tools.sh node                   # newest LTS becomes the default
#   NODE_VERSION=28 bash guest-tools.sh node   # a specific line becomes the default
#   fnm install 24 && fnm use 24               # or switch just this shell
# Globally installed npm tools (gemini) live outside any one Node version, so
# they survive a switch. Everything it downloads goes through the host
# egress allowlist — "Could not resolve host" means that host isn't on it (run
# `devvm allow <host>` on the HOST).
#
# Optional on purpose: guest-setup.sh stays the small "every project needs this"
# step; this is the comfortable-workstation layer on top.
#
# TRUST: like the container image it replaces, this runs upstream installers
# (bun.sh, cursor.com) and "latest" release binaries (Neovim, fnm, mise, Codex)
# with no checksum or signature check; only hadolint, which is pinned, is
# verified against its published checksum. A compromised upstream would run code as
# `dev`, who has sudo in the guest. The egress allowlist limits where such code
# could send things, not what it does inside the VM. Don't run this in a VM
# that holds credentials you wouldn't hand to those vendors.
set -euo pipefail

[ "$(id -u)" != 0 ] || { echo "run as dev, not root (it uses sudo where needed): bash $0" >&2; exit 1; }
command -v sudo >/dev/null || { echo "sudo not found — run guest-setup.sh first" >&2; exit 1; }

NODE_VERSION="${NODE_VERSION:-lts}"     # "lts" = newest LTS line; or 26, 24.11.0, ...
HADOLINT_VERSION="${HADOLINT_VERSION:-2.12.0}"
BIN="$HOME/.local/bin"
RC="$HOME/.config/devvm/shellrc.sh"     # sourced from ~/.bashrc and ~/.zshrc
FNM_DIR="$HOME/.local/share/fnm"
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
mkdir -p "$BIN" "$(dirname "$RC")"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT   # every download lands here

step() { printf '\n==> %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
# Download to a temp file first, so a failed fetch never leaves a half-written
# binary on PATH (and never pipes an empty script into a shell).
# --retry-all-errors: the VM's egress proxy sometimes fails a TLS handshake to an
# allowed host (VEC-234), which plain --retry doesn't count as retryable.
fetch() { curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o "$2" "$1"; }

case "$(uname -m)" in
  x86_64)  A_GNU=x86_64;  A_ALT=x86_64; A_FNM=linux; A_MISE=x64 ;;
  aarch64) A_GNU=aarch64; A_ALT=arm64;  A_FNM=arm64; A_MISE=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# One rc snippet for both shells: PATH for the tools below + the aliases.
write_rc() {
  cat > "$RC" <<'RCEOF'
# Managed by vm/guest-tools.sh — re-running it overwrites this file.
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
export FNM_DIR="$HOME/.local/share/fnm"
for _d in "$HOME/.local/bin" "$NPM_CONFIG_PREFIX/bin" "$FNM_DIR" \
          "$FNM_DIR/aliases/default/bin" "$HOME/.bun/bin"; do
  case ":$PATH:" in *":$_d:"*) ;; *) if [ -d "$_d" ]; then PATH="$_d:$PATH"; fi ;; esac
done
unset _d
export PATH
# fnm needs its per-shell environment for `fnm use` / `fnm install` to switch
# versions. Its path goes ahead of the default-version entry added above.
if [ -x "$FNM_DIR/fnm" ]; then
  if [ -n "${ZSH_VERSION:-}" ]; then eval "$("$FNM_DIR/fnm" env --shell zsh)"
  elif [ -n "${BASH_VERSION:-}" ]; then eval "$("$FNM_DIR/fnm" env --shell bash)"
  fi
fi
# mise: activates per-project tool versions as you cd. It only takes over a tool
# (node included) in a directory whose mise config names it; elsewhere the fnm
# default above stays in charge.
if command -v mise >/dev/null 2>&1; then
  if [ -n "${ZSH_VERSION:-}" ]; then eval "$(mise activate zsh)"
  elif [ -n "${BASH_VERSION:-}" ]; then eval "$(mise activate bash)"
  fi
fi

# YOLO launchers — fine HERE: egress is capped on the host and the host
# filesystem isn't mounted. Never copy these to a machine without that.
alias yolo-claude="claude --dangerously-skip-permissions"
alias yolo-codex="codex --dangerously-bypass-approvals-and-sandbox"
alias yolo-gemini="gemini --yolo"
alias yolo-cursor="agent --force"
RCEOF
  local f line="[ -r \"$RC\" ] && . \"$RC\"   # devvm guest-tools"
  for f in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    # .profile too: a login shell that isn't interactive bash (e.g. `su - dev
    # -c ...`, or zsh without a .zshrc yet) still gets the PATH.
    grep -qF "$RC" "$f" 2>/dev/null || printf '\n%s\n' "$line" >> "$f"
  done
  load_rc
}

# Source the rc snippet without -e/-u: it evals fnm's and mise's shell hooks,
# which aren't written for a strict shell and must not be able to abort setup.
load_rc() {
  set +eu
  # shellcheck disable=SC1090
  . "$RC"
  set -eu
}

group_base() {
  step "Base packages (shell tools, compilers, Python, shellcheck)"
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg git openssh-client rsync \
    zsh fzf ripgrep jq unzip wget xz-utils less tmux tree htop lsof file \
    build-essential python3 python3-venv python3-dev python3-pip \
    shellcheck
  # git-delta is only packaged from Ubuntu 24.04 on; don't fail the group on an
  # older guest.
  if apt-cache show git-delta >/dev/null 2>&1; then
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git-delta
  else
    echo "NOTE: git-delta isn't packaged for this release; skipping (git keeps its default pager)"
  fi

  step "hadolint ${HADOLINT_VERSION}"
  if have hadolint; then echo "already installed"; else
    local u="https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-${A_ALT}"
    fetch "$u" "$TMP/hadolint-Linux-${A_ALT}"
    fetch "$u.sha256" "$TMP/hadolint.sha256"
    (cd "$TMP" && sha256sum -c --status hadolint.sha256) \
      || { echo "FAILED: hadolint checksum mismatch — not installing it" >&2; exit 1; }
    install -m 0755 "$TMP/hadolint-Linux-${A_ALT}" "$BIN/hadolint"
  fi

  step "Neovim (latest stable)"
  if have nvim; then echo "already installed"; else
    fetch "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${A_ALT}.tar.gz" "$TMP/nvim.tgz"
    mkdir -p "$HOME/.local/opt"
    rm -rf "$HOME/.local/opt/nvim-linux-${A_ALT}"
    tar -xzf "$TMP/nvim.tgz" -C "$HOME/.local/opt"
    ln -sf "$HOME/.local/opt/nvim-linux-${A_ALT}/bin/nvim" "$BIN/nvim"
  fi
}

group_node() {
  step "fnm + Node.js (${NODE_VERSION})"
  # fnm's own installer lives on fnm.vercel.app, which isn't allowlisted; the
  # release zip on GitHub is the same binary.
  if [ ! -x "$FNM_DIR/fnm" ]; then
    have unzip || { echo "unzip missing — run the 'base' group first" >&2; exit 1; }
    fetch "https://github.com/Schniz/fnm/releases/latest/download/fnm-${A_FNM}.zip" "$TMP/fnm.zip"
    mkdir -p "$FNM_DIR"; unzip -oq "$TMP/fnm.zip" fnm -d "$FNM_DIR"
    chmod 0755 "$FNM_DIR/fnm"
  fi
  export FNM_DIR
  # Not skipped when a Node is already there: this is how you move up (or to a
  # chosen line). `fnm install` is a no-op for a version that is already
  # installed, and older versions stay installed for `fnm use`.
  local before=""
  [ ! -x "$FNM_DIR/aliases/default/bin/node" ] || before="$("$FNM_DIR/aliases/default/bin/node" --version)"
  if [ "$NODE_VERSION" = lts ]; then
    "$FNM_DIR/fnm" install --lts
    "$FNM_DIR/fnm" default lts-latest
  else
    "$FNM_DIR/fnm" install "$NODE_VERSION"
    "$FNM_DIR/fnm" default "$NODE_VERSION"
  fi
  echo "default node: $("$FNM_DIR/aliases/default/bin/node" --version)${before:+ (was $before)}"

  step "Bun"
  if [ -x "$HOME/.bun/bin/bun" ]; then echo "already installed"; else
    have unzip || { echo "unzip missing — run the 'base' group first" >&2; exit 1; }
    fetch https://bun.sh/install "$TMP/bun-install.sh"
    # SHELL=/bin/false: the installer would otherwise append PATH lines to the rc
    # files; ours are in $RC already. Its progress bar is noise, so the output is
    # kept in a log and shown only if the install fails.
    if ! BUN_INSTALL="$HOME/.bun" SHELL=/bin/false bash "$TMP/bun-install.sh" >"$TMP/bun.log" 2>&1 \
       || [ ! -x "$HOME/.bun/bin/bun" ]; then
      cat "$TMP/bun.log" >&2
      echo "FAILED: bun did not install (installer output above)" >&2; exit 1
    fi
  fi
}

bypass_note() {
  echo "NOTE: set skipDangerousModePermissionPrompt in ~/.claude/settings.json — Claude Code will no"
  echo "  longer show its one-time bypass-permissions warning in this VM. To undo, remove that key;"
  echo "  to keep the warning on future runs, set DEVVM_KEEP_BYPASS_PROMPT=1."
}

group_mise() {
  step "mise"
  # mise's own installer lives on mise.run, which isn't allowlisted; the release
  # binary on GitHub is the same thing. Its file name carries the version, so
  # resolve the latest tag first.
  if have mise; then echo "already installed: $(mise --version | head -1)"; else
    local tag
    tag="$(curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o /dev/null -w '%{url_effective}' \
             https://github.com/jdx/mise/releases/latest)"
    tag="${tag##*/}"
    [[ "$tag" =~ ^v[0-9][0-9.]*$ ]] || { echo "FAILED: couldn't resolve the latest mise release (got '$tag')" >&2; exit 1; }
    fetch "https://github.com/jdx/mise/releases/download/${tag}/mise-${tag}-linux-${A_MISE}" "$TMP/mise"
    install -m 0755 "$TMP/mise" "$BIN/mise"
  fi
}

group_agents() {
  step "Codex CLI"
  if have codex; then echo "already installed"; else
    fetch "https://github.com/openai/codex/releases/latest/download/codex-${A_GNU}-unknown-linux-musl.tar.gz" "$TMP/codex.tgz"
    tar -xzf "$TMP/codex.tgz" -C "$TMP"
    install -m 0755 "$TMP/codex-${A_GNU}-unknown-linux-musl" "$BIN/codex"
  fi

  step "Gemini CLI"
  if have gemini; then echo "already installed"; else
    have npm || { echo "npm missing — run the 'node' group first" >&2; exit 1; }
    npm install -g @google/gemini-cli
  fi

  step "Cursor CLI"
  if have cursor-agent || have agent; then echo "already installed"; else
    fetch https://cursor.com/install "$TMP/cursor-install.sh"; bash "$TMP/cursor-install.sh"
  fi

  # `yolo-claude` otherwise stops on a one-time "bypass permissions mode"
  # acceptance screen. This is a security-relevant default, so it is skippable:
  # DEVVM_KEEP_BYPASS_PROMPT=1 leaves Claude Code's settings alone.
  step "Claude Code: pre-accept the bypass-permissions prompt"
  local s="$HOME/.claude/settings.json"
  if [ -n "${DEVVM_KEEP_BYPASS_PROMPT:-}" ]; then
    echo "skipped (DEVVM_KEEP_BYPASS_PROMPT is set)"
  elif [ ! -s "$s" ]; then
    mkdir -p "$HOME/.claude"
    echo '{"skipDangerousModePermissionPrompt": true}' > "$s"
    bypass_note
  elif ! have jq; then
    echo "NOTE: jq isn't installed, so $s was left alone. Run the 'base' group, then 'agents' again." >&2
  elif ! jq -e . "$s" >/dev/null 2>&1; then
    echo "NOTE: $s isn't valid JSON; leaving it alone. Fix it and re-run to pre-accept the prompt." >&2
  elif [ "$(jq -r '.skipDangerousModePermissionPrompt // false' "$s")" = true ]; then
    echo "already set"
  else
    # Merged into the existing settings, so nothing you set is lost.
    # cat, not mv: keeps the file's own mode and owner.
    jq '. + {skipDangerousModePermissionPrompt: true}' "$s" > "$TMP/settings.json" && cat "$TMP/settings.json" > "$s"
    bypass_note
  fi
}

group_git() {
  step "Git defaults"
  git config --global init.defaultBranch main
  if have delta; then
    git config --global core.pager delta
    git config --global interactive.diffFilter "delta --color-only"
    git config --global delta.navigate true
  fi
  # Identity is yours to supply — the VM is never handed one by the host.
  [ -z "${GIT_USER_NAME:-}" ]  || git config --global user.name  "$GIT_USER_NAME"
  [ -z "${GIT_USER_EMAIL:-}" ] || git config --global user.email "$GIT_USER_EMAIL"
  if [ -z "$(git config --global user.email || true)" ]; then
    echo "NOTE: no git identity yet, so commits will fail. Set one:"
    echo "  git config --global user.name 'Your Name'; git config --global user.email you@example.com"
    echo "  (or re-run with GIT_USER_NAME=... GIT_USER_EMAIL=... set)"
  fi
}

write_rc
[ $# -gt 0 ] || set -- base node mise agents git
# Re-source after each group: a later group needs the PATH entries (node, npm,
# bun) that only exist once an earlier one has run.
for g in "$@"; do
  case "$g" in
    base|node|mise|agents|git) "group_$g"; load_rc ;;
    *) echo "unknown group: $g (base | node | mise | agents | git)" >&2; exit 1 ;;
  esac
done

step "Done"
for t in zsh rg fzf jq tmux nvim delta shellcheck hadolint node npm bun mise claude codex gemini agent; do
  if have "$t"; then printf '  %-11s %s\n' "$t" "$(type -P "$t" || command -v "$t")"; else printf '  %-11s MISSING\n' "$t"; fi
done
echo "Open a new shell (or: . $RC) to pick up PATH and the yolo-* aliases."
