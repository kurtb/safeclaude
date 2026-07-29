#!/usr/bin/env bash
# safeclaude installer — install the host wrapper and point it at the published
# image (no clone needed; clone only to build/hack). The wrapper is fetched over
# HTTPS from GitHub and sourced into your shell rc — there is no checksum, so
# trust the source. https://github.com/kurtb/safeclaude
#
#   curl -fsSL https://github.com/kurtb/safeclaude/releases/latest/download/install.sh | bash
#
# Env: SAFECLAUDE_VERSION  pin a release (e.g. 0.2.0) or a branch (default: latest)
#      SAFECLAUDE_IMAGE / SAFECLAUDE_HOME / SAFECLAUDE_RC  overrides
set -euo pipefail

REPO="kurtb/safeclaude"
DEST="${SAFECLAUDE_HOME:-$HOME/.local/share/safeclaude}"
RC="${SAFECLAUDE_RC:-$HOME/.zshrc}"
WRAPPER="$DEST/safeclaude.zsh"
say() { printf 'safeclaude-install: %s\n' "$*" >&2; }

command -v curl >/dev/null || { say "curl is required"; exit 1; }

# Resolve ref (wrapper) + tag (image). Empty version → newest release, else main.
sel="${SAFECLAUDE_VERSION:-}"
if [ -z "$sel" ]; then
    sel="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
             "https://github.com/$REPO/releases/latest" 2>/dev/null \
             | sed -n 's#.*/releases/tag/##p' || true)"
    [ -n "$sel" ] || sel="main"
fi
if [[ "$sel" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ref="v${sel#v}"; tag="${sel#v}"          # a pinned release (X.Y.Z)
elif [[ "$sel" =~ ^v?[0-9]+(\.[0-9]+)?$ ]]; then
    say "SAFECLAUDE_VERSION must be a full X.Y.Z; for a rolling line set SAFECLAUDE_IMAGE=ghcr.io/$REPO:${sel#v}"
    exit 1
else
    ref="$sel"; tag="latest"                 # a branch (e.g. main)
fi
IMAGE="${SAFECLAUDE_IMAGE:-ghcr.io/$REPO:$tag}"
say "installing wrapper @ $ref, image $IMAGE"

# Download to a temp file; replace the wrapper only on success (a failed/404
# download never clobbers a working install).
mkdir -p "$DEST"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
curl -fsSL "https://raw.githubusercontent.com/$REPO/$ref/safeclaude.zsh" -o "$tmp"
mv "$tmp" "$WRAPPER"

# Update the rc in place (preserves a symlinked rc and its perms). Replace an
# existing block only when BOTH markers are present, else append.
S="# >>> safeclaude >>>"; E="# <<< safeclaude <<<"
block="$S
export SAFECLAUDE_IMAGE=\"$IMAGE\"
source \"$WRAPPER\"
$E"
touch "$RC"
if grep -qF "$S" "$RC" && grep -qF "$E" "$RC"; then
    kept="$(awk -v s="$S" -v e="$E" '$0==s{skip=1} !skip{print} $0==e{skip=0}' "$RC")"
    printf '%s\n%s\n' "$kept" "$block" > "$RC"
else
    printf '\n%s\n' "$block" >> "$RC"
fi

say "done → $WRAPPER"
say "open a new shell (or: source $RC), then run 'safeclaude' in a project"
command -v docker >/dev/null || say "note: docker not found — install it to use safeclaude"
