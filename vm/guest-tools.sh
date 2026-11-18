#!/usr/bin/env bash
# devvm guest toolbox — run this BY HAND, inside the VM, as `dev`, AFTER
# guest-setup.sh. It installs what the container image used to bake in: the
# everyday dev tools and the other agent CLIs.
#
#   bash ~/workspace/safeclaude/vm/guest-tools.sh          # everything
#   bash ~/workspace/safeclaude/vm/guest-tools.sh agents   # one group
#
# Groups:  base    shell tools, compilers, Python venv/pip, linters, neovim
#          node    Node.js (via fnm) + Bun
#          agents  Codex, Gemini and Cursor CLIs, yolo-* aliases   (needs node)
#          git     delta as pager; user.name/user.email from GIT_USER_NAME/EMAIL
#
# IDEMPOTENT: re-run it any time; finished steps are skipped. To upgrade one
# tool, delete it and re-run. Everything it downloads goes through the host
# egress allowlist — "Could not resolve host" means that host isn't on it (run
# `devvm allow <host>` on the HOST).
#
# Optional on purpose: guest-setup.sh stays the small "every project needs this"
# step; this is the comfortable-workstation layer on top.
set -euo pipefail

[ "$(id -u)" != 0 ] || { echo "run as dev, not root (it uses sudo where needed): bash $0" >&2; exit 1; }
command -v sudo >/dev/null || { echo "sudo not found — run guest-setup.sh first" >&2; exit 1; }

NODE_MAJOR="${NODE_MAJOR:-24}"
HADOLINT_VERSION="${HADOLINT_VERSION:-2.12.0}"
BIN="$HOME/.local/bin"
RC="$HOME/.config/devvm/shellrc.sh"     # sourced from ~/.bashrc and ~/.zshrc
FNM_DIR="$HOME/.local/share/fnm"
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
mkdir -p "$BIN" "$(dirname "$RC")"

step() { printf '\n==> %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
# Download to a temp file first, so a failed fetch never leaves a half-written
# binary on PATH (and never pipes an empty script into a shell).
fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

case "$(uname -m)" in
  x86_64)  A_GNU=x86_64;  A_ALT=x86_64; A_FNM=linux ;;
  aarch64) A_GNU=aarch64; A_ALT=arm64;  A_FNM=arm64 ;;
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
  # shellcheck disable=SC1090
  . "$RC"
}

group_base() {
  step "Base packages (shell tools, compilers, Python, shellcheck)"
  sudo env DEBIAN_FRONTEND=noninteractive apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg git openssh-client rsync \
    zsh fzf ripgrep jq unzip wget xz-utils less tmux tree htop lsof file \
    build-essential python3 python3-venv python3-dev python3-pip \
    shellcheck git-delta

  step "hadolint ${HADOLINT_VERSION}"
  if have hadolint; then echo "already installed"; else
    t="$(mktemp)"
    fetch "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-${A_ALT}" "$t"
    install -m 0755 "$t" "$BIN/hadolint"; rm -f "$t"
  fi

  step "Neovim (latest stable)"
  if have nvim; then echo "already installed"; else
    t="$(mktemp)"
    fetch "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${A_ALT}.tar.gz" "$t"
    mkdir -p "$HOME/.local/opt"
    rm -rf "$HOME/.local/opt/nvim-linux-${A_ALT}"
    tar -xzf "$t" -C "$HOME/.local/opt"; rm -f "$t"
    ln -sf "$HOME/.local/opt/nvim-linux-${A_ALT}/bin/nvim" "$BIN/nvim"
  fi
}

group_node() {
  step "fnm + Node.js ${NODE_MAJOR}"
  # fnm's own installer lives on fnm.vercel.app, which isn't allowlisted; the
  # release zip on GitHub is the same binary.
  if [ ! -x "$FNM_DIR/fnm" ]; then
    have unzip || { echo "unzip missing — run the 'base' group first" >&2; exit 1; }
    t="$(mktemp)"
    fetch "https://github.com/Schniz/fnm/releases/latest/download/fnm-${A_FNM}.zip" "$t"
    mkdir -p "$FNM_DIR"; unzip -oq "$t" fnm -d "$FNM_DIR"; rm -f "$t"
    chmod 0755 "$FNM_DIR/fnm"
  fi
  export FNM_DIR
  if [ -x "$FNM_DIR/aliases/default/bin/node" ]; then
    echo "already installed: node $("$FNM_DIR/aliases/default/bin/node" --version)"
  else
    "$FNM_DIR/fnm" install "$NODE_MAJOR"
    "$FNM_DIR/fnm" default "$NODE_MAJOR"
  fi

  step "Bun"
  if [ -x "$HOME/.bun/bin/bun" ]; then echo "already installed"; else
    have unzip || { echo "unzip missing — run the 'base' group first" >&2; exit 1; }
    t="$(mktemp)"; fetch https://bun.sh/install "$t"
    # The installer appends PATH lines to the rc files; ours are in $RC already.
    BUN_INSTALL="$HOME/.bun" SHELL=/bin/false bash "$t" >/dev/null 2>&1; rm -f "$t"
    [ -x "$HOME/.bun/bin/bun" ] || { echo "FAILED: bun did not install" >&2; exit 1; }
  fi
}

group_agents() {
  step "Codex CLI"
  if have codex; then echo "already installed"; else
    t="$(mktemp -d)"
    fetch "https://github.com/openai/codex/releases/latest/download/codex-${A_GNU}-unknown-linux-musl.tar.gz" "$t/codex.tgz"
    tar -xzf "$t/codex.tgz" -C "$t"
    install -m 0755 "$t/codex-${A_GNU}-unknown-linux-musl" "$BIN/codex"; rm -rf "$t"
  fi

  step "Gemini CLI"
  if have gemini; then echo "already installed"; else
    have npm || { echo "npm missing — run the 'node' group first" >&2; exit 1; }
    npm install -g @google/gemini-cli
  fi

  step "Cursor CLI"
  if have agent || have cursor-agent; then echo "already installed"; else
    t="$(mktemp)"; fetch https://cursor.com/install "$t"; bash "$t"; rm -f "$t"
  fi

  step "Claude Code: pre-accept the bypass-permissions prompt"
  # Merged into any existing settings, so nothing you set is lost.
  s="$HOME/.claude/settings.json"; mkdir -p "$HOME/.claude"
  if [ -s "$s" ]; then
    have jq || { echo "jq missing — run the 'base' group first" >&2; exit 1; }
    if [ "$(jq -r '.skipDangerousModePermissionPrompt // false' "$s")" = true ]; then
      echo "already set"
    else
      t="$(mktemp)"; jq '. + {skipDangerousModePermissionPrompt: true}' "$s" > "$t" && mv "$t" "$s"
    fi
  else
    echo '{"skipDangerousModePermissionPrompt": true}' > "$s"
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
[ $# -gt 0 ] || set -- base node agents git
# Re-source after each group: a later group needs the PATH entries (node, npm,
# bun) that only exist once an earlier one has run.
# shellcheck disable=SC1090
for g in "$@"; do
  case "$g" in
    base|node|agents|git) "group_$g"; . "$RC" ;;
    *) echo "unknown group: $g (base | node | agents | git)" >&2; exit 1 ;;
  esac
done
write_rc   # again: picks up directories that exist only now

step "Done"
for t in zsh rg fzf jq tmux nvim delta shellcheck hadolint node npm bun claude codex gemini agent; do
  if have "$t"; then printf '  %-11s %s\n' "$t" "$(command -v "$t")"; else printf '  %-11s MISSING\n' "$t"; fi
done
echo "Open a new shell (or: . $RC) to pick up PATH and the yolo-* aliases."
