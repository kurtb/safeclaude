#!/usr/bin/env bash
# gh-auth-setup — ensure the GitHub CLI is authenticated inside the sandbox.
#
# A manual command — nothing runs it for you. Run it when you need GitHub access.
#   - If gh already has a token, it's a quiet no-op.
#   - Otherwise it obtains a GitHub PAT from, in order: stdin (piped),
#     $GH_TOKEN, $GITHUB_TOKEN, or an interactive hidden prompt — then runs
#     `gh auth login --with-token` + `gh auth setup-git`.
#
# Auth is stored under ~/.config/gh, which lives in the persistent volume, so
# you normally only do this once per volume. Pressing Enter at the prompt skips
# setup (exit 0).
set -uo pipefail

# Already configured? Nothing to do. (Checks for a stored token without a
# network round-trip, so it's cheap to call on every launch.)
if gh auth token >/dev/null 2>&1; then
    exit 0
fi

token=""
# stdin is not a tty => something was piped/redirected in; read it.
if [ ! -t 0 ]; then
    token="$(cat || true)"
fi
[ -z "$token" ] && token="${GH_TOKEN:-}"
[ -z "$token" ] && token="${GITHUB_TOKEN:-}"

# Still nothing and we have a terminal? Prompt for it.
if [ -z "$token" ] && [ -t 1 ] && [ -r /dev/tty ]; then
    echo "GitHub CLI is not authenticated." >&2
    printf "Paste a GitHub PAT to configure it (or press Enter to skip): " >&2
    read -rs token < /dev/tty || true
    echo >&2
fi

token="$(printf '%s' "$token" | tr -d '[:space:]')"
if [ -z "$token" ]; then
    echo "gh-auth-setup: skipped — GitHub CLI is not configured." >&2
    exit 0
fi

# `gh auth login --with-token` refuses to run while GH_TOKEN/GITHUB_TOKEN are
# set in the environment, so clear them for this process first.
unset GH_TOKEN GITHUB_TOKEN
if printf '%s' "$token" | gh auth login --with-token; then
    gh auth setup-git
    who="$(gh api user --jq .login 2>/dev/null || echo '?')"
    echo "gh-auth-setup: authenticated to GitHub as ${who}; git credential helper configured." >&2
else
    echo "gh-auth-setup: gh auth login failed." >&2
    exit 1
fi
