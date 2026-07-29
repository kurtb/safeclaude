#!/usr/bin/env bash
# safeclaude installer — installs the host-side wrapper and points it at the
# published container image. No git clone required; use this to *run* safeclaude
# (clone the repo only if you want to build the image or hack on it).
#
#   curl -fsSL https://github.com/kurtb/safeclaude/releases/latest/download/install.sh | bash
#
# Env overrides:
#   SAFECLAUDE_REF     ref to fetch the wrapper from (default: latest release, else main)
#   SAFECLAUDE_IMAGE   image the wrapper runs   (default: ghcr.io/kurtb/safeclaude:latest)
#   SAFECLAUDE_HOME    install dir              (default: ~/.local/share/safeclaude)
#   SAFECLAUDE_RC      shell rc to update       (default: ~/.zshrc)
set -euo pipefail

REPO="kurtb/safeclaude"
IMAGE="${SAFECLAUDE_IMAGE:-ghcr.io/kurtb/safeclaude:latest}"
DEST_DIR="${SAFECLAUDE_HOME:-$HOME/.local/share/safeclaude}"
RC="${SAFECLAUDE_RC:-$HOME/.zshrc}"
WRAPPER="$DEST_DIR/safeclaude.zsh"

info() { printf 'safeclaude-install: %s\n' "$*"; }
err()  { printf 'safeclaude-install: %s\n' "$*" >&2; }

command -v curl >/dev/null 2>&1 || { err "curl is required"; exit 1; }

# Resolve the ref: explicit override, else the latest release tag (via the
# /releases/latest redirect), else main.
ref="${SAFECLAUDE_REF:-}"
if [ -z "$ref" ]; then
    ref="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
             "https://github.com/${REPO}/releases/latest" 2>/dev/null \
             | sed -n 's#.*/releases/tag/##p' || true)"
    [ -n "$ref" ] || ref="main"
fi
info "installing wrapper from ${REPO}@${ref}"

mkdir -p "$DEST_DIR"
curl -fsSL "https://raw.githubusercontent.com/${REPO}/${ref}/safeclaude.zsh" -o "$WRAPPER"

# Wire up the shell rc idempotently, inside a marked block we can replace.
marker_start="# >>> safeclaude >>>"
marker_end="# <<< safeclaude <<<"
block="$(printf '%s\nexport SAFECLAUDE_IMAGE=%s\nsource %s\n%s\n' \
    "$marker_start" "\"$IMAGE\"" "\"$WRAPPER\"" "$marker_end")"

touch "$RC"
if grep -qF "$marker_start" "$RC"; then
    tmp="$(mktemp)"
    awk -v s="$marker_start" -v e="$marker_end" \
        '$0==s{skip=1} !skip{print} $0==e{skip=0}' "$RC" > "$tmp"
    printf '%s\n' "$block" >> "$tmp"
    mv "$tmp" "$RC"
    info "updated safeclaude block in ${RC}"
else
    printf '\n%s\n' "$block" >> "$RC"
    info "added safeclaude to ${RC}"
fi

info "installed:"
info "  wrapper: ${WRAPPER}"
info "  image:   ${IMAGE}"
echo
info "next:"
info "  1. open a new shell (or:  source ${RC} )"
info "  2. cd into a project and run:  safeclaude"
info "     (first run pulls the image; if it's private:  docker login ghcr.io )"
command -v docker >/dev/null 2>&1 \
    || err "warning: docker not found on PATH — install Docker to use safeclaude."
