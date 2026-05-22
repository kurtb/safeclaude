FROM ubuntu:24.04

ARG NODE_MAJOR=24
ARG PYTHON_VERSION=3.12
ARG GIT_USER_NAME="Kurt Berglund"
ARG GIT_USER_EMAIL="kurtberglund@hotmail.com"

# Personal skills/dotfiles repo. Override at build time:
#   docker build --build-arg DOTCLAUDE_REPO=https://github.com/you/dotclaude
ARG DOTCLAUDE_REPO=https://github.com/kurtb/dotclaude
ARG DOTCLAUDE_REF=main

ENV DEBIAN_FRONTEND=noninteractive
ENV SHELL=/usr/bin/zsh
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

ENV FNM_DIR=/home/ubuntu/.local/share/fnm
ENV NPM_CONFIG_PREFIX=/home/ubuntu/.npm-global
ENV PATH=/home/ubuntu/.local/bin:${NPM_CONFIG_PREFIX}/bin:${FNM_DIR}/aliases/default/bin:${PATH}

# ── Core packages (main only — no universe) ──────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg git openssh-client sudo rsync \
    zsh fzf ripgrep jq unzip wget xz-utils \
    tmux \
    tree htop lsof file \
    build-essential \
    iptables ipset iproute2 dnsutils aggregate \
    python${PYTHON_VERSION} python${PYTHON_VERSION}-venv python${PYTHON_VERSION}-dev python3-pip \
    && rm -rf /var/lib/apt/lists/*

# ── shellcheck (from upstream GitHub release; universe lags) ─────────
RUN ARCH=$(uname -m) \
    && curl -fsSL -o /tmp/shellcheck.tar.xz \
       "https://github.com/koalaman/shellcheck/releases/download/stable/shellcheck-stable.linux.${ARCH}.tar.xz" \
    && tar -xJf /tmp/shellcheck.tar.xz -C /tmp \
    && install -m 0755 /tmp/shellcheck-stable/shellcheck /usr/local/bin/shellcheck \
    && rm -rf /tmp/shellcheck.tar.xz /tmp/shellcheck-stable

# ── hadolint (Dockerfile linter) ─────────────────────────────────────
ARG HADOLINT_VERSION=2.12.0
RUN ARCH=$(uname -m) \
    && case "$ARCH" in \
         x86_64)  HL_ARCH=x86_64 ;; \
         aarch64) HL_ARCH=arm64  ;; \
         *) echo "unsupported arch for hadolint: $ARCH" && exit 1 ;; \
       esac \
    && curl -fsSL -o /usr/local/bin/hadolint \
       "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-${HL_ARCH}" \
    && chmod +x /usr/local/bin/hadolint

RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PYTHON_VERSION} 1 \
    && update-alternatives --install /usr/bin/python python /usr/bin/python${PYTHON_VERSION} 1

# ── Neovim (latest stable) ────────────────────────────────────────────
RUN ARCH=$(uname -m) \
    && case "$ARCH" in \
         x86_64)  NVIM_ARCH=x86_64 ;; \
         aarch64) NVIM_ARCH=arm64  ;; \
         *) echo "unsupported arch for neovim: $ARCH" && exit 1 ;; \
       esac \
    && curl -fsSL "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-${NVIM_ARCH}.tar.gz" \
    | tar -xz -C /opt \
    && ln -sf /opt/nvim-linux-${NVIM_ARCH}/bin/nvim /usr/local/bin/nvim

# ── git-delta (better diffs; from Anthropic devcontainer pattern) ────
ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL -o /tmp/git-delta.deb \
       "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" \
    && dpkg -i /tmp/git-delta.deb \
    && rm /tmp/git-delta.deb

# ── GitHub CLI ────────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ── Google Cloud CLI ─────────────────────────────────────────────────
RUN curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
      > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update && apt-get install -y --no-install-recommends google-cloud-cli \
    && rm -rf /var/lib/apt/lists/*

# ── Pulumi (system path; doesn't self-update) ────────────────────────
RUN curl -fsSL https://get.pulumi.com | HOME=/opt bash -s -- --install-root /opt/pulumi --no-edit-path \
    && ln -sf /opt/pulumi/bin/pulumi /usr/local/bin/pulumi

# ── Codex CLI (Rust binary from GitHub releases) ──────────────────────
# OpenAI ships Codex as a Rust binary; the npm package is a thin wrapper
# that downloads the same artifact. Pulling the binary directly avoids the
# npm indirection and lets `safeclaude build` upgrade Codex.
RUN ARCH=$(uname -m) \
    && curl -fsSL -o /tmp/codex.tar.gz \
       "https://github.com/openai/codex/releases/latest/download/codex-${ARCH}-unknown-linux-musl.tar.gz" \
    && tar -xzf /tmp/codex.tar.gz -C /tmp \
    && install -m 0755 /tmp/codex-${ARCH}-unknown-linux-musl /usr/local/bin/codex \
    && rm -rf /tmp/codex.tar.gz /tmp/codex-${ARCH}-unknown-linux-musl

# ── Firewall script + sudoers exception ───────────────────────────────
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY entrypoint.sh    /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh \
    && echo "ubuntu ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" \
       > /etc/sudoers.d/ubuntu-firewall \
    && chmod 0440 /etc/sudoers.d/ubuntu-firewall

# ── Configure existing ubuntu user ────────────────────────────────────
# IMPORTANT: ubuntu has NO general sudo. The only privileged operation it can
# perform is /usr/local/bin/init-firewall.sh (see sudoers entry above). This
# is what makes the firewall an actual security boundary — a YOLO-mode agent
# running as ubuntu cannot flush iptables or destroy the ipset allowlist.
# If you need to install OS packages, add them to this Dockerfile and rebuild.
RUN chsh -s /usr/bin/zsh ubuntu

USER ubuntu
WORKDIR /home/ubuntu

# ── Node.js (fnm) ─────────────────────────────────────────────────────
# All tooling lives in /home/ubuntu and is seeded into the named volume on
# first container start. Image rebuilds don't refresh tools on existing
# volumes — rely on each tool's self-update, or `safeclaude rm` for a
# clean reset.
RUN curl -fsSL https://fnm.vercel.app/install | bash \
    && export PATH="${FNM_DIR}:$PATH" \
    && fnm install ${NODE_MAJOR} \
    && fnm default ${NODE_MAJOR}

ENV PATH=/home/ubuntu/.local/bin:${FNM_DIR}/aliases/default/bin:${PATH}

# ── Agent CLIs (vendor-blessed paths) ─────────────────────────────────
#   - Claude Code: native installer (auto-updates in background)
#   - Cursor:      native installer (auto-updates by default)
#   - Codex:       Rust binary from GitHub releases (installed above; system path)
#   - Gemini:      npm global — Google's only documented Linux path,
#                  no compiled binary exists. Manual `@latest` upgrade.
# Native installers drop binaries in ~/.local/bin; the npm install goes to
# ~/.npm-global/bin (NPM_CONFIG_PREFIX set above). Both are on PATH.
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && curl -fsS https://cursor.com/install | bash \
    && npm install -g @google/gemini-cli \
    && npm cache clean --force

# ── Git config ────────────────────────────────────────────────────────
RUN git config --global user.name  "${GIT_USER_NAME}" \
    && git config --global user.email "${GIT_USER_EMAIL}" \
    && git config --global init.defaultBranch main \
    && git config --global core.pager "delta" \
    && git config --global interactive.diffFilter "delta --color-only" \
    && git config --global delta.navigate true

# ── Shell setup via dotzsh ────────────────────────────────────────────
RUN git clone https://github.com/kurtb/dotzsh ${HOME}/dev/dotzsh \
    && cp /etc/zsh/newuser.zshrc.recommended ${HOME}/.zshrc \
    && ${HOME}/dev/dotzsh/install.sh

# ── Vim setup via dotvim ──────────────────────────────────────────────
RUN git clone https://github.com/kurtb/dotvim ${HOME}/dev/dotvim \
    && ${HOME}/dev/dotvim/install.sh

# ── Personal skills/dotfiles (dotclaude) ──────────────────────────────
# Cloned best-effort; build still succeeds if the repo doesn't exist yet.
RUN git clone --depth 1 --branch ${DOTCLAUDE_REF} ${DOTCLAUDE_REPO} ${HOME}/dev/dotclaude \
    && if [ -x ${HOME}/dev/dotclaude/install.sh ]; then \
         ${HOME}/dev/dotclaude/install.sh; \
       fi \
 || echo "dotclaude repo (${DOTCLAUDE_REPO}@${DOTCLAUDE_REF}) not available; skipping"

# ── gstack (Garry Tan's Claude skills) ────────────────────────────────
RUN mkdir -p ${HOME}/.claude/skills \
    && git clone --single-branch --depth 1 https://github.com/garrytan/gstack \
         ${HOME}/.claude/skills/gstack \
    && (cd ${HOME}/.claude/skills/gstack && ./setup) \
 || echo "gstack install failed; skipping"

# ── YOLO aliases for all three agents ─────────────────────────────────
RUN { \
      echo ''; \
      echo '# safeclaude: YOLO aliases — only use inside the safeclaude container.'; \
      echo 'alias yolo-claude="claude --dangerously-skip-permissions"'; \
      echo 'alias yolo-codex="codex --dangerously-bypass-approvals-and-sandbox"'; \
      echo 'alias yolo-gemini="gemini --yolo"'; \
      echo 'alias yolo-cursor="agent --force"'; \
    } >> ${HOME}/.zshrc

# ── Pre-accept Claude Code's bypass-permissions prompt ────────────────
# `claude --dangerously-skip-permissions` (yolo-claude) otherwise shows a
# one-time "bypass permissions mode" acceptance screen on first run. This
# pre-accepts it so yolo-claude starts immediately. Merged into any existing
# settings so dotclaude config is preserved. Seeded into fresh volumes on
# first container start; existing volumes keep their current settings.
RUN mkdir -p ${HOME}/.claude \
    && if [ -f ${HOME}/.claude/settings.json ]; then \
         jq '. + {skipDangerousModePermissionPrompt: true}' ${HOME}/.claude/settings.json > ${HOME}/.claude/settings.json.tmp \
         && mv ${HOME}/.claude/settings.json.tmp ${HOME}/.claude/settings.json; \
       else \
         echo '{"skipDangerousModePermissionPrompt": true}' > ${HOME}/.claude/settings.json; \
       fi

# Workspace mount point (host source code goes here).
RUN mkdir -p ${HOME}/workspace
WORKDIR /home/ubuntu/workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
