#!/usr/bin/env bash
# safeclaude installer — install the host wrapper and point it at the published
# image (no clone needed; clone only to build/hack). The wrapper is fetched over
# HTTPS from GitHub and sourced into your shell rc — there is no checksum, so
# trust the source. https://github.com/kurtb/safeclaude
#
#   curl -fsSL https://github.com/kurtb/safeclaude/releases/latest/download/install.sh | bash
#
# Env: SAFECLAUDE_VERSION  pin wrapper + image to a release (e.g. 0.2.0), or a
#                          branch name for the wrapper. Default: the newest
#                          release, re-resolved on each run (wrapper + image move
#                          together, both pinned to that release version).
#      SAFECLAUDE_IMAGE    a CUSTOM (non-ghcr) image ref. A value pointing at
#                          ghcr.io/kurtb/safeclaude is ignored as a stale
#                          prior-install value — pin with SAFECLAUDE_VERSION.
#      SAFECLAUDE_HOME / SAFECLAUDE_RC  install dir / shell rc
set -euo pipefail

REPO="kurtb/safeclaude"
DEST="${SAFECLAUDE_HOME:-$HOME/.local/share/safeclaude}"
RC="${SAFECLAUDE_RC:-$HOME/.zshrc}"
WRAPPER="$DEST/safeclaude.zsh"
say() { printf 'safeclaude-install: %s\n' "$*" >&2; }

command -v curl >/dev/null || { say "curl is required"; exit 1; }

# Resolve the wrapper ref and image tag — they move together, both tracking a
# RELEASE (not the moving :latest, which follows main).
#   SAFECLAUDE_VERSION set → pin both to that release.
#   unset                  → both track the newest release, RE-RESOLVED on every
#                            install/upgrade (so upgrade bumps wrapper + image
#                            together). A branch name pins the wrapper to that
#                            branch with image :latest.
sel="${SAFECLAUDE_VERSION:-}"
pinned=0
if [ -n "$sel" ]; then
    pinned=1
else
    sel="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
             "https://github.com/$REPO/releases/latest" 2>/dev/null \
             | sed -n 's#.*/releases/tag/##p' || true)"
    [ -n "$sel" ] || sel="main"
fi
if [[ "$sel" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ref="v${sel#v}"; tag="${sel#v}"          # pin wrapper + image to this release
elif [ "$pinned" = 1 ] && [[ "$sel" =~ ^v?[0-9]+(\.[0-9]+)?$ ]]; then
    say "SAFECLAUDE_VERSION must be a full X.Y.Z (e.g. 0.3.0)"
    exit 1
else
    ref="$sel"; tag="latest"                 # a branch (e.g. main)
fi

# Image: a genuine custom SAFECLAUDE_IMAGE (not our own ghcr repo) wins;
# otherwise ghcr.io/$REPO:$tag. A SAFECLAUDE_IMAGE that points at our ghcr repo
# is IGNORED — it was written into the rc by a prior install, and honoring it
# would freeze the image at an old version on upgrade (the bug this fixes).
# The image is re-resolved each run, so `safeclaude upgrade` moves it forward.
if [ "$pinned" = 0 ] && [ -n "${SAFECLAUDE_IMAGE:-}" ] && [[ "$SAFECLAUDE_IMAGE" != ghcr.io/"$REPO":* ]]; then
    IMAGE="$SAFECLAUDE_IMAGE"
else
    IMAGE="ghcr.io/$REPO:$tag"
fi
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
