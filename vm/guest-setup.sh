#!/usr/bin/env bash
# Guest setup for a devvm VM — run by hand INSIDE the VM, as root:
#
#   apt-get update && apt-get install -y git
#   git clone https://github.com/kurtb/safeclaude.git
#   bash safeclaude/vm/guest-setup.sh
#
# A new VM is a bare Ubuntu machine: nothing is installed at boot. This script
# installs only what every project needs (git, gh, Docker, Claude Code) and
# creates the unprivileged `dev` user. A project's own toolchain is the project's
# job (a bootstrap command in the repo).
#
# Runs in the foreground so failures are visible, and is IDEMPOTENT: re-run it
# any time; finished steps are skipped. Everything it downloads goes through the
# host egress allowlist — "Could not resolve host" means that host isn't on it.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root (in the VM): sudo bash $0" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

step "Base packages (curl, git, jq, gh)"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git jq gh

step "Docker"
if command -v docker >/dev/null 2>&1; then
  echo "already installed: $(docker --version)"
else
  # NOTE: get.docker.com is an unpinned root installer (upstream provides no
  # pinned URL); the egress allowlist is the mitigation.
  curl -fsSL --retry 3 https://get.docker.com | sh
fi

# Work happens as `dev`, not root: Claude Code refuses
# --dangerously-skip-permissions as root, and minikube's docker driver refuses
# root too. Passwordless sudo is fine HERE (unlike the container): the egress
# boundary is enforced on the host, where guest root can't reach it.
step "User 'dev' (docker group, passwordless sudo)"
id dev >/dev/null 2>&1 || useradd -m -s /bin/bash dev
usermod -aG docker dev
printf 'dev ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/dev
chmod 0440 /etc/sudoers.d/dev
install -d -o dev -g dev -m 0755 /home/dev/workspace

# On login, land in the project: the single clone if there is exactly one, else
# the workspace root.
cat > /etc/profile.d/devvm-workspace.sh <<'PROFILE'
if [ "$(id -un)" = dev ] && [ -d "$HOME/workspace" ]; then
  _n=0
  for _d in "$HOME"/workspace/*/; do
    [ -d "$_d" ] && _n=$((_n+1)) && _one="$_d"
  done
  if [ "$_n" = 1 ]; then cd "$_one"; else cd "$HOME/workspace"; fi
  unset _n _d _one
fi
PROFILE
chmod 0644 /etc/profile.d/devvm-workspace.sh

step "Claude Code (for dev)"
if [ -x /home/dev/.local/bin/claude ]; then
  echo "already installed"
else
  # Same installer as the container image; lands in ~/.local/bin, which Ubuntu's
  # ~/.profile puts on PATH at login.
  su - dev -c 'curl -fsSL --retry 3 https://claude.ai/install.sh | bash'
fi

step "Done"
echo "docker: $(docker --version)"
echo "claude: $(su - dev -c 'claude --version' 2>&1 | tail -1)"
echo "Next: exit, re-enter with 'devvm shell' (now logs in as dev), then:  gh auth login --with-token && gh auth setup-git ; claude login"
