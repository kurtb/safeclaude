#!/usr/bin/env bash
# safeclaude-doctor — smoke-test a safeclaude container after a build.
#
# Verifies the tools and wiring this image is supposed to provide, then exits
# non-zero if any hard check fails, so it doubles as a CI-style gate. Run it
# inside the container:
#
#   safeclaude-doctor
#
# Note: some things (gstack skills, the yolo-* functions in ~/.zshrc) are seeded
# into the /home/ubuntu volume on first container start, so a rebuilt image only
# shows them in a FRESH volume — test those under a throwaway name/dir, e.g.
#   cd /tmp && safeclaude dr-test && safeclaude-doctor && exit && safeclaude rm dr-test
set -u

pass=0; fail=0; warn=0
ok()    { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
warns() { printf '  \033[33mwarn\033[0m %s\n' "$1"; warn=$((warn + 1)); }
have()  { command -v "$1" >/dev/null 2>&1; }

echo "safeclaude-doctor"
echo

echo "tools on PATH:"
for t in bun node python3 git gh claude codex gemini agent pulumi gcloud \
         nvim rg fzf jq delta shellcheck hadolint less gh-auth-setup; do
    if have "$t"; then ok "$t"; else bad "$t missing"; fi
done
echo

echo "versions:"
have bun     && echo "  bun    $(bun --version 2>/dev/null)"
have node    && echo "  node   $(node --version 2>/dev/null)"
have python3 && echo "  python $(python3 --version 2>&1 | awk '{print $2}')"
have gh      && echo "  gh     $(gh --version 2>/dev/null | head -1 | awk '{print $3}')"
echo

echo "yolo wrappers (in ~/.zshrc):"
for f in yolo-claude yolo-codex yolo-gemini yolo-cursor; do
    if grep -q "^${f}()" "$HOME/.zshrc" 2>/dev/null; then ok "$f defined"; else bad "$f not in ~/.zshrc"; fi
done
echo

echo "gstack:"
if [ -f "$HOME/.claude/skills/gstack/SKILL.md" ]; then ok "skills cloned"; else bad "skills missing"; fi
if [ -x "$HOME/.claude/skills/gstack/browse/dist/browse" ]; then
    ok "browse binary built"
else
    warns "browse binary not built (bun build may have failed)"
fi
if [ -d "$HOME/.cache/ms-playwright" ]; then
    ok "Playwright Chromium installed ($(du -sh "$HOME/.cache/ms-playwright" 2>/dev/null | cut -f1))"
else
    warns "Playwright Chromium not installed (gstack browser skills unavailable)"
fi
echo

echo "github auth:"
if gh auth token >/dev/null 2>&1; then
    ok "gh authenticated as $(gh api user --jq .login 2>/dev/null || echo '?')"
else
    warns "gh not authenticated yet — run gh-auth-setup (or a yolo-* wrapper)"
fi
echo

echo "firewall (egress from inside the container):"
if curl -sS --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    bad "reached https://example.com — firewall is NOT enforcing"
else
    ok "https://example.com blocked"
fi
if curl -sS --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    ok "https://api.github.com reachable (allowlist working)"
else
    bad "cannot reach https://api.github.com — allowlist may be broken"
fi
echo

echo "summary: ${pass} ok, ${warn} warn, ${fail} fail"
[ "$fail" -eq 0 ]
